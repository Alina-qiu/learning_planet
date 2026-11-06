// Local Deno entrypoint adapter: callers choose isolated mocks or real loopback services; never a cloud project.
globalThis.EdgeRuntime = { waitUntil(promise) { promise.catch(() => console.error('LOCAL_EDGE_TASK_FAILED')); } };
const serve = Deno.serve;
Deno.serve = handler => serve({ hostname: '127.0.0.1', port: Number(Deno.env.get('TEST_EDGE_PORT')) }, handler);
const kind = Deno.env.get('TEST_EDGE_KIND') ?? 'worksheet';
if (kind === 'ai') {
  const fetcher = globalThis.fetch;
  globalThis.fetch = (url, options) => fetcher(url === 'https://api.openai.com/v1/responses'
    ? `${Deno.env.get('SUPABASE_URL')}/provider` : url, options);
}
if (kind === 'parent-push') {
  const fetcher=globalThis.fetch;
  globalThis.fetch=(url,options)=>fetcher(url==='https://oauth-login.cloud.huawei.com/oauth2/v3/token'
    ? `${Deno.env.get('SUPABASE_URL')}/push-auth`
    : url==='https://push-api.cloud.huawei.com/v1/123456789/messages:send'
      ? `${Deno.env.get('SUPABASE_URL')}/push-send` : url,options);
}
if (kind === 'task-push') {
  const fetcher=globalThis.fetch;
  globalThis.fetch=(url,options)=>fetcher(typeof url==='string' && url.startsWith('https://api.sandbox.push.apple.com/3/device/')
    ? `${Deno.env.get('SUPABASE_URL')}/task-push-send` : url,options);
}
await import(new URL(kind === 'account' ? '../../supabase/functions/account-deletion/index.ts'
  : kind === 'ai' ? '../../supabase/functions/ai-analysis/index.ts'
  : kind === 'cleanup' ? '../../supabase/functions/permanent-cleanup/index.ts'
  : kind === 'parent-push' ? '../../supabase/functions/parent-push/index.ts'
  : kind === 'task-push' ? '../../supabase/functions/task-push/index.ts'
  : '../../supabase/functions/worksheet-render/index.ts', import.meta.url));
