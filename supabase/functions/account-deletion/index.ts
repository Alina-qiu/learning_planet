import {createClient} from 'npm:@supabase/supabase-js@2.99.1';
import {executeAccountDeletion} from '../_shared/account_deletion_worker.mjs';
declare const EdgeRuntime: {waitUntil(task: Promise<unknown>): void};

const headers = {
  'Content-Type': 'application/json', 'Cache-Control': 'no-store',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
Deno.serve(async (request) => {
  const response = (status: number, body: unknown = {}) => new Response(JSON.stringify(body), {status, headers});
  if (request.method === 'OPTIONS') return new Response(null, {status: 204, headers});
  if (request.method !== 'POST') return response(405);
  const bearer = request.headers.get('Authorization');
  if (!bearer?.startsWith('Bearer ')) return response(401);
  const secret = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const url = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(url, secret, {auth: {persistSession: false}});
  const trusted = bearer === `Bearer ${secret}`;
  const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: {headers: {Authorization: bearer}}, auth: {persistSession: false},
  });
  if (!trusted) {
    const {data, error} = await caller.auth.getUser();
    if (error || !data.user) return response(401);
  }
  try {
    const text = await request.text();
    if (text.length > 1024) return response(413);
    const body = JSON.parse(text);
    let ids: string[];
    if (body.mode === 'drain') {
      if (!trusted) return response(403);
      const {data, error} = await admin.rpc('pending_account_deletions');
      if (error) throw error;
      ids = data ?? [];
    } else {
      // Never accept a target user or arbitrary job ID from the caller.
      if (trusted) return response(400);
      const {data, error} = await caller.rpc('account_deletion_status');
      if (error || !data?.id) return response(403);
      if (data.status === 'completed') return response(200, {status: 'completed'});
      ids = [data.id];
    }
    EdgeRuntime.waitUntil((async () => {
      for (const id of ids) {
        const {data: claim, error} = await admin.rpc('claim_account_deletion', {target_job_id: id});
        if (error) continue;
        await executeAccountDeletion(claim, admin).catch(() => console.error('ACCOUNT_DELETION_LEASE_REQUIRES_RETRY'));
      }
    })());
    return response(202, {status: 'accepted', jobs: ids.length});
  } catch {
    return response(503, {error: 'ACCOUNT_DELETION_RETRY'});
  }
});
