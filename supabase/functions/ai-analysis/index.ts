import { createClient } from 'npm:@supabase/supabase-js@2.99.1';
import { boundedText, validateInput, openAiAnalyzer, executeAnalysis } from '../_shared/ai_analysis.mjs';
import { validateSimilarInput, openAiSimilar, similarPromptVersion } from '../_shared/ai_similar.mjs';
import { validateWeeklyInput, openAiWeeklyReport, weeklyPromptVersion } from '../_shared/ai_weekly_report.mjs';
declare const EdgeRuntime: { waitUntil(task: Promise<unknown>): void };
const headers = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store',
  'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const reply = (status: number, body: object) => new Response(JSON.stringify(body), { status, headers });
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (request.method !== 'POST') return reply(405, {});
  const bearer = request.headers.get('Authorization');
  if (!bearer?.startsWith('Bearer ')) return reply(401, {});
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: bearer } }, auth: { persistSession: false },
    });
    const { data, error } = await caller.auth.getUser();
    if (error || !data.user) return reply(401, {});
    // Decode only after getUser validates this exact bearer with Supabase Auth.
    const payload = bearer.slice(7).split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const claims = JSON.parse(atob(payload.padEnd(Math.ceil(payload.length / 4) * 4, '=')));
    if (claims.sub !== data.user.id || typeof claims.session_id !== 'string' || !claims.session_id) return reply(401, {});
    const body = JSON.parse(await boundedText(request.body, 12000));
    if (!uuid.test(body.request_id) || !uuid.test(body.child_id) || !(validateInput(body.input) || validateSimilarInput(body.input) || validateWeeklyInput(body.input))
      || body.consent !== true || !Number.isSafeInteger(body.generation) || body.generation < 0
      || Object.keys(body).sort().join(',') !== 'child_id,consent,generation,input,request_id') return reply(400, {});
    const key = Deno.env.get('OPENAI_API_KEY');
    if (!key) return reply(503, { error: 'AI_UNAVAILABLE' });
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const { data: claim, error: denied } = await admin.rpc('claim_ai_analysis', {
      caller_id: data.user.id, caller_session: claims.session_id, target_child_id: body.child_id,
      request_id: body.request_id, input: body.input, expected_generation: body.generation,
    });
    if (denied) {
      const code = ['AI_DISABLED', 'AI_UNAVAILABLE', 'AI_LIMIT_REACHED', 'AI_REPORT_CHANGED'].find(c => denied.message.includes(c));
      return reply(403, { error: code ?? 'AI_ACCESS_DENIED' });
    }
    if (claim.status !== 'claimed') return reply(200, claim);
    const similar = body.input.kind === 'similar';
    const weekly = body.input.kind === 'weekly_report';
    if (claim.provider !== 'openai' || claim.prompt_version !== (weekly ? weeklyPromptVersion : similar ? similarPromptVersion : 'question-structure-v1')) throw new Error('UNSUPPORTED_PROVIDER');
    EdgeRuntime.waitUntil(executeAnalysis(claim, body.input, {
      analyze: weekly ? openAiWeeklyReport(key) : similar ? openAiSimilar(key) : openAiAnalyzer(key),
      finish: async (id: string, token: string, output: object | null) => {
        const { error } = await admin.rpc('finish_ai_analysis', { request_id: id, token, output });
        if (error) throw new Error('AI_FINISH_UNKNOWN');
      },
    }).catch(() => console.error('AI_FINISH_UNKNOWN')));
    return reply(202, { request_id: claim.request_id, child_id: body.child_id, status: 'running' });
  } catch { return reply(503, { error: 'AI_INSPECT_ORIGINAL_REQUEST' }); }
});
