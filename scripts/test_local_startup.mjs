import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {test} from 'node:test';
import {localControlInvocation, stopLocalSession} from './local_backend.mjs';
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


test('printed controls use the selected runtime with shell-safe quoting', () => {
  assert.equal(localControlInvocation("C:/family's tools/node.exe", 'win32'),
    "& 'C:/family''s tools/node.exe' scripts/local_backend.mjs");
  assert.equal(localControlInvocation("/family's tools/node", 'linux'),
    String.raw`'/family'\''s tools/node' scripts/local_backend.mjs`);
});

test('stop waits through a 503 until the local port can be reused', {timeout: 5000}, async () => {
  const saved = {runId: 'session', shutdownKey: 'test-only'};
  const draining = Promise.withResolvers();
  let accepted = false;
  const server = createServer((request, response) => {
    if (request.url === '/__local/stop') {
      assert.equal(request.headers.authorization, 'Bearer test-only');
      accepted = true;
      response.writeHead(202).end();
    } else {
      response.writeHead(accepted ? 503 : 200).end(JSON.stringify({ready: !accepted, runId: saved.runId}));
      if (accepted) draining.resolve();
    }
  });
  await listen(server);
  const port = server.address().port, origin = `http://127.0.0.1:${port}`;
  let finished = false;
  const stopping = stopLocalSession(origin, saved).then(() => { finished = true; });
  try {
    await draining.promise;
    assert.equal(finished, false);
  } finally {
    await closeServer(server);
    await stopping;
  }
  await stopLocalSession(origin, saved);
  const replacement = createServer();
  try { await listen(replacement, port); }
  finally { await closeServer(replacement); }
});

test('stop never sends its key to a replacement session or stops it during cleanup', async () => {
  let runId = 'original', posts = 0;
  const server = createServer((request, response) => {
    if (request.url === '/__local/stop') {
      posts++;
      runId = 'replacement';
      response.writeHead(202).end();
    } else {
      response.end(JSON.stringify({ready: true, runId}));
    }
  });
  await listen(server);
  const origin = `http://127.0.0.1:${server.address().port}`;
  try {
    const original = {runId, shutdownKey: 'test-only'};
    await stopLocalSession(origin, original);
    assert.equal(posts, 1);
    await assert.rejects(stopLocalSession(origin, original), /different session/);
    assert.equal(posts, 1);
  } finally { await closeServer(server); }
});

test('stop reports a deadline while the original listener remains open', async () => {
  const server = createServer((request, response) => {
    if (request.url === '/__local/stop') response.writeHead(202).end();
    else response.writeHead(503).end(JSON.stringify({ready: false, runId: 'closing'}));
  });
  await listen(server);
  try {
    await assert.rejects(stopLocalSession(`http://127.0.0.1:${server.address().port}`,
      {runId: 'closing', shutdownKey: 'test-only'}, {timeoutMs: 150}), /still in progress/);
  } finally { await closeServer(server); }
});
