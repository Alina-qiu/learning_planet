import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {test} from 'node:test';
import {closeServer, listen, localProcess} from './fixtures/http_test_tools.mjs';
import {initializeLocalBucket} from './fixtures/storage_backend.mjs';

async function withProbe(handler, check) {
  const server = createServer(handler);
  await listen(server);
  const process = localProcess(globalThis.process.execPath,
    ['-e', 'setInterval(() => {}, 1000)'], {name: 'Startup fixture'});
  try { await check(process, `http://127.0.0.1:${server.address().port}/status`); }
  finally { await process.stop(); await closeServer(server); }
}

test('readiness waits for a successful HTTP response', async () => {
  let attempts = 0;
  await withProbe((_, response) => {
    response.writeHead(++attempts < 2 ? 503 : 200); response.end();
  }, async (process, url) => {
    const result = await process.ready(url, {timeoutMs: 2000});
    assert.equal(attempts, 2);
    assert.ok(result.elapsedMs >= 200);
  });
});

test('readiness reports status and deadline without response contents', async t => {
  // Keep this diagnostic assertion independent of a final socket request racing
  // the deadline. Real HTTP retry and response timeout behavior is covered below.
  const fetch = t.mock.method(globalThis, 'fetch', async () =>
    new Response('private-response', {status: 503}));
  const process = localProcess(globalThis.process.execPath,
    ['-e', 'setInterval(() => {}, 1000)'], {name: 'Startup fixture'});
  try {
    await assert.rejects(process.ready('http://127.0.0.1:1/status', {timeoutMs: 250}), error => {
      assert.match(error.message, /last probe: HTTP 503; process alive: true/);
      assert.doesNotMatch(error.message, /private-response|127\.0\.0\.1/);
      return true;
    });
    assert.ok(fetch.mock.callCount() > 0);
  } finally { await process.stop(); }
});

test('edge readiness uses OPTIONS and requires the exact expected status', async () => {
  let attempts = 0;
  await withProbe((request, response) => {
    assert.equal(request.method, 'OPTIONS');
    response.writeHead(++attempts < 2 ? 200 : 204); response.end();
  }, async (process, url) => {
    await process.ready(url, {timeoutMs: 2000, method: 'OPTIONS', expectedStatus: 204});
    assert.equal(attempts, 2, 'Other 2xx responses do not mark the Edge function ready');
  });
});

test('readiness bounds a stalled response body', async () => {
  await withProbe((_, response) => {
    response.writeHead(200); response.write('never finishes');
  }, async (process, url) => {
    const started = performance.now();
    await assert.rejects(process.ready(url, {timeoutMs: 250}), /did not become ready/);
    assert.ok(performance.now() - started < 2000);
  });
});

test('readiness detects an exited child', async () => {
  const process = localProcess(globalThis.process.execPath, ['-e', 'process.exit(2)'], {name: 'Exited fixture'});
  await process.done;
  await assert.rejects(process.ready('http://127.0.0.1:1/'), /Exited fixture exited/);
});

test('bucket startup retries only the explicit uninitialized response', async () => {
  let attempts = 0;
  const startup = Object.assign(new Error('Starting'), {
    name: 'XMinioServerNotInitialized', $metadata: {httpStatusCode: 503},
  });
  await initializeLocalBucket(async () => { if (++attempts < 2) throw startup; });
  assert.equal(attempts, 2);
  for (const error of [new Error('AccessDenied'), Object.assign(new Error('Other'), {$metadata: {httpStatusCode: 503}})]) {
    attempts = 0;
    await assert.rejects(initializeLocalBucket(async () => { attempts++; throw error; }), value => value === error);
    assert.equal(attempts, 1);
  }
});

test('bucket startup keeps a terminal initialization failure visible', async () => {
  const error = Object.assign(new Error('Starting'), {
    name: 'XMinioServerNotInitialized', $metadata: {httpStatusCode: 503},
  });
  const started = performance.now();
  await assert.rejects(initializeLocalBucket(async () => { throw error; }, {timeoutMs: 50}), value => value === error);
  assert.ok(performance.now() - started < 1000);
});
