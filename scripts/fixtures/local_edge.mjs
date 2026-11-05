import assert from 'node:assert/strict';
import {resolve} from 'node:path';
import {freePort, isolatedEnv, localProcess} from './http_test_tools.mjs';

export async function startLocalEdge(kind, {url, anon, service}) {
  assert.ok(['worksheet', 'cleanup', 'account'].includes(kind));
  const origin = new URL(url);
  assert.ok(origin.protocol === 'http:' && origin.hostname === '127.0.0.1');
  const port = await freePort();
  const env = isolatedEnv(['SUPABASE_', 'TEST_EDGE_']);
  Object.assign(env, {SUPABASE_URL: url, SUPABASE_ANON_KEY: anon, SUPABASE_SERVICE_ROLE_KEY: service,
    TEST_EDGE_KIND: kind, TEST_EDGE_PORT: String(port)});
  const binary = process.platform === 'win32' ? resolve('node_modules/deno/deno.exe') : resolve('node_modules/.bin/deno');
  const handle = localProcess(binary, ['run', '--cached-only', '--config', 'supabase/functions/worksheet-render/deno.json',
    '--allow-env=SUPABASE_URL,SUPABASE_ANON_KEY,SUPABASE_SERVICE_ROLE_KEY,TEST_EDGE_PORT,TEST_EDGE_KIND',
    `--allow-net=127.0.0.1:${origin.port},127.0.0.1:${port}`, `--allow-read=${resolve('supabase/functions')}`,
    'scripts/fixtures/edge_bootstrap.mjs'], {env, name: `Local Edge ${kind}`});
  const endpoint = `http://127.0.0.1:${port}`;
  try {
    const startup = await handle.ready(endpoint, {method: 'OPTIONS', expectedStatus: 204, timeoutMs: 60000});
    console.log(`Local Edge ${kind} ready in ${startup.elapsedMs} ms`);
    return {...handle, port, async post(token, body) {
      const response = await fetch(endpoint, {method: 'POST', headers: {Authorization: `Bearer ${token}`, 'Content-Type': 'application/json'},
        body: JSON.stringify(body), signal: AbortSignal.timeout(15000)});
      return {status: response.status, data: await response.json()};
    }};
  } catch (error) { await handle.stop(); throw error; }
}
