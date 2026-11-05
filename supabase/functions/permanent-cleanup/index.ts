import { createClient } from 'npm:@supabase/supabase-js@2.99.1';
import { executeCleanup } from '../_shared/cleanup_worker.mjs';
declare const EdgeRuntime: { waitUntil(task: Promise<unknown>): void };

const headers = {
  'Content-Type': 'application/json', 'Cache-Control': 'no-store',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (request.method !== 'POST') return new Response('{}', { status: 405, headers });
  const bearer = request.headers.get('Authorization');
  if (!bearer?.startsWith('Bearer ')) return new Response('{}', { status: 401, headers });
  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const secret = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const admin = createClient(url, secret, { auth: { persistSession: false } });
  const caller = createClient(url, anon, { global: { headers: { Authorization: bearer } }, auth: { persistSession: false } });
  const trusted = bearer === `Bearer ${secret}`;
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
      const { error: retentionError } = await admin.rpc('enqueue_expired_worksheets');
      if (retentionError) throw new Error('RETENTION_DISPATCH_FAILED');
      const { data: ids, error } = await admin.rpc('pending_cleanup_jobs');
      if (error) throw new Error('DISPATCH_FAILED');
      EdgeRuntime.waitUntil((async () => {
        for (const id of ids ?? []) {
          const { data: claim, error } = await admin.rpc('claim_cleanup_job', { target_job_id: id });
          if (error) continue;
          await executeCleanup(claim, admin.storage, async (job: string, token: string, code: string | null) => {
            const { error } = await admin.rpc('finish_cleanup_job', { target_job_id: job, token, failure_code: code });
            if (error) throw new Error('FINISH_FAILED');
          }).catch(() => console.error('CLEANUP_WORKER_LEASE_REQUIRES_RETRY'));
        }
      })());
      return new Response(JSON.stringify({ status: 'accepted', jobs: (ids ?? []).length }), { status: 202, headers });
    }
    if (typeof body.job_id !== 'string' || !/^[0-9a-f-]{36}$/.test(body.job_id)) {
      return new Response('{}', { status: 400, headers });
    }
    const { data: claim, error } = await (trusted ? admin : caller).rpc('claim_cleanup_job', { target_job_id: body.job_id });
    if (error) return new Response(JSON.stringify({ error: 'CLEANUP_ACCESS_DENIED' }), { status: 403, headers });
    if (claim.status !== 'claimed') return new Response(JSON.stringify({ job_id: body.job_id, status: claim.status }), { status: 200, headers });
    const work = executeCleanup(claim, admin.storage, async (id: string, token: string, code: string | null) => {
      const { error } = await admin.rpc('finish_cleanup_job', { target_job_id: id, token, failure_code: code });
      if (error) throw new Error('FINISH_FAILED');
    }).catch(() => {
      // A crashed/expired lease stays durable and can be reclaimed; do not log private paths or credentials.
      console.error('CLEANUP_WORKER_LEASE_REQUIRES_RETRY');
    });
    EdgeRuntime.waitUntil(work);
    return new Response(JSON.stringify({ job_id: body.job_id, status: 'running' }), { status: 202, headers });
  } catch {
    return new Response(JSON.stringify({ error: 'CLEANUP_FAILED_RETRY_SAME_JOB' }), { status: 503, headers });
  }
});
