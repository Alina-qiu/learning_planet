import { createClient } from 'npm:@supabase/supabase-js@2.99.1';
import { renderWorksheet } from '../_shared/worksheet_pdf.mjs';
import { executeWorksheet } from '../_shared/worksheet_worker.mjs';
declare const EdgeRuntime: { waitUntil(task: Promise<unknown>): void };

const headers = {
  'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const hash = async (bytes: Uint8Array) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new Uint8Array(bytes).buffer))]
  .map(value => value.toString(16).padStart(2, '0')).join('');
let fontPromise: Promise<Uint8Array> | undefined;
function loadFont() {
  return fontPromise ??= (async () => {
    const bytes = await Deno.readFile(new URL('./fonts/NotoSansSC-Regular.ttf', import.meta.url));
    if (await hash(bytes) !== 'b6a3861ad594afe88f30c0eff922728198d51ac59323c922a29afc4322a7bead') throw new Error('FONT_ASSET_INVALID');
    return bytes;
  })().catch(error => { fontPromise = undefined; throw error; });
}
Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (request.method !== 'POST') return new Response('{}', { status: 405, headers });
  const bearer = request.headers.get('Authorization');
  if (!bearer?.startsWith('Bearer ')) return new Response('{}', { status: 401, headers });
  const url = Deno.env.get('SUPABASE_URL')!;
  const secret = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const trusted = bearer === `Bearer ${secret}`;
  const admin = createClient(url, secret, { auth: { persistSession: false } });
  const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: bearer } }, auth: { persistSession: false },
  });
  if (!trusted) {
    const { data, error } = await caller.auth.getUser();
    if (error || !data.user) return new Response('{}', { status: 401, headers });
  }
  try {
    const text = await request.text();
    if (text.length > 1024) return new Response('{}', { status: 413, headers });
    const body = JSON.parse(text);
    if (body.mode === 'drain') {
      if (!trusted) return new Response('{}', { status: 403, headers });
      const { data: ids, error } = await admin.rpc('pending_worksheet_jobs');
      if (error) throw new Error('DISPATCH_FAILED');
      const id = ids?.[0];
      if (!id) return new Response(JSON.stringify({ status: 'accepted', jobs: 0 }), { status: 202, headers });
      // Continue through the exact same database claim and worker as parent requests.
      // The service cannot supply snapshots: only this trusted queue result is used.
      body.worksheet_id = id;
    }
    if (typeof body.worksheet_id !== 'string' || !/^[0-9a-f-]{36}$/.test(body.worksheet_id)) return new Response('{}', { status: 400, headers });
    const { data: claim, error } = await (trusted ? admin : caller).rpc('claim_worksheet', { target_worksheet_id: body.worksheet_id });
    if (error) return new Response(JSON.stringify({ error: 'WORKSHEET_ACCESS_DENIED' }), { status: 403, headers });
    if (claim.status !== 'claimed') return new Response(JSON.stringify({ id: claim.id, status: claim.status }), { status: 200, headers });
    const work = executeWorksheet(claim, {
      render: async (snapshot: object) => renderWorksheet(snapshot, await loadFont()), hash,
      progress: async (id: string, token: string, percentage: number) => {
        const { error } = await admin.rpc('update_worksheet_progress', { target_worksheet_id: id, token, percentage });
        if (error) throw new Error('LEASE_INVALID');
      },
      upload: async (path: string, bytes: Uint8Array) => {
        // Immutable snapshots and a pinned renderer make retries produce identical bytes.
        const { error } = await admin.storage.from('worksheets').upload(path, bytes, { contentType: 'application/pdf', upsert: true });
        if (error) throw new Error('PDF_UPLOAD_FAILED');
      },
      finish: async (id: string, token: string, result: object) => {
        const { error } = await admin.rpc('finish_worksheet', { target_worksheet_id: id, token, result });
        if (error) throw new Error('FINISH_FAILED');
      },
      state: async (id: string) => {
        const { data, error } = await admin.from('worksheet_jobs').select('status,sha256').eq('id', id).maybeSingle();
        if (error) throw new Error('STATE_UNKNOWN');
        return data;
      },
      remove: async (path: string) => {
        const { error } = await admin.storage.from('worksheets').remove([path]);
        if (error) throw new Error('ORPHAN_REMOVE_FAILED');
      },
    }).catch(() => console.error('WORKSHEET_WORKER_REQUIRES_RETRY'));
    EdgeRuntime.waitUntil(work);
    return new Response(JSON.stringify({ id: claim.id, status: 'running' }), { status: 202, headers });
  } catch {
    return new Response(JSON.stringify({ error: 'WORKSHEET_RETRY_SAME_ID' }), { status: 503, headers });
  }
});
