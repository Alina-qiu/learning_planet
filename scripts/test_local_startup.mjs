import assert from 'node:assert/strict';
import {access, mkdir, mkdtemp, readFile, readdir, rm, unlink, writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {localControlInvocation, scheduleLocalSessionEnd, stopLocalSession} from './local_backend.mjs';
import {closeServer, listen, localProcess, signedJwt} from './fixtures/http_test_tools.mjs';
import {initializeLocalBucket} from './fixtures/storage_backend.mjs';
import {initializingTrialDatabase, localSessionKeys, openLocalTrial} from './fixtures/local_trial.mjs';

const daySeconds = 86400;
const claims = jwt => JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString());

test('a persistent session and its worker credential remain active after the first 24 hours', t => {
  const createdAt = 1800000000, credentials = {createdAt, secret: 'x'.repeat(64)};
  t.mock.timers.enable({apis: ['Date', 'setTimeout'], now: createdAt * 1000});
  const keys = localSessionKeys(credentials, true);
  let ended = false;
  const cancel = scheduleLocalSessionEnd(keys.expiresAt, () => { ended = true; });
  // Request at 23:55, eligible after the ten-minute cancellation window.
  t.mock.timers.tick((daySeconds + 5 * 60) * 1000);
  assert.equal(ended, false);
  const worker = claims(keys.service);
  assert.equal(worker.role, 'service_role');
  assert.ok(worker.exp > Date.now() / 1000);
  assert.equal(worker.exp, createdAt + 3650 * daySeconds);
  const restarted = localSessionKeys(credentials, true);
  assert.equal(restarted.anon, signedJwt(credentials.secret, {role: 'anon', iat: createdAt, exp: worker.exp}));
  assert.equal(restarted.anon, keys.anon);
  assert.equal(claims(restarted.service).exp, worker.exp);
  cancel();
  t.mock.timers.tick((worker.exp - createdAt) * 1000);
  assert.equal(ended, false);
});

test('bounded timer chunks recheck the fixed profile expiry across restarts', t => {
  const createdAt = 1800000000, expiresAt = createdAt + 3650 * daySeconds;
  const credentials = {createdAt, secret: 'x'.repeat(64)};
  const maxDelay = 0x7fffffff;
  t.mock.timers.enable({apis: ['Date', 'setTimeout'], now: expiresAt * 1000 - maxDelay - 30001});
  const scheduled = t.mock.method(globalThis, 'setTimeout');
  const keys = localSessionKeys(credentials, true);
  assert.equal(keys.expiresAt, expiresAt);
  let expirations = 0;
  const cancel = scheduleLocalSessionEnd(keys.expiresAt, () => { expirations++; });
  assert.equal(scheduled.mock.calls.at(-1).arguments[1], maxDelay);
  t.mock.timers.tick(maxDelay);
  assert.equal(expirations, 0);
  assert.equal(scheduled.mock.calls.at(-1).arguments[1], 30001);
  cancel(); // An operator restarts the service with only 30s remaining.
  for (const keepData of [true, false]) {
    const reopened = localSessionKeys(credentials, keepData);
    assert.equal(reopened.expiresAt, expiresAt);
    assert.equal(claims(reopened.service).exp, expiresAt);
    scheduleLocalSessionEnd(reopened.expiresAt, () => { expirations++; });
  }
  t.mock.timers.tick(30000);
  assert.equal(expirations, 0);
  t.mock.timers.tick(1);
  assert.equal(expirations, 2);
  assert.throws(() => localSessionKeys(credentials, true), /expired/);
});

test('a temporary session retains its one-day limit and the same public APK key', t => {
  const now = 1800000000, credentials = {createdAt: now - 7 * daySeconds, secret: 'x'.repeat(64)};
  t.mock.timers.enable({apis: ['Date', 'setTimeout'], now: now * 1000});
  const keys = localSessionKeys(credentials, false);
  assert.equal(keys.anon, localSessionKeys(credentials, true).anon);
  assert.equal(claims(keys.anon).role, 'anon');
  assert.equal(keys.expiresAt, now + daySeconds);
  assert.equal(claims(keys.service).exp, keys.expiresAt);
  let ended = false;
  scheduleLocalSessionEnd(keys.expiresAt, () => { ended = true; });
  t.mock.timers.tick(daySeconds * 1000 - 1);
  assert.equal(ended, false);
  t.mock.timers.tick(1);
  assert.equal(ended, true);
});

async function trialPaths(t) {
  const directory = await mkdtemp(join(tmpdir(), 'learning-planet-profile-'));
  t.after(() => rm(directory, {recursive: true, force: true}));
  const generated = join(directory, 'generated'), trial = join(directory, 'trial');
  await mkdir(generated);
  return {trial, cached: join(generated, 'credentials.json'), profile: join(trial, 'profile.json'),
    open: keepData => openLocalTrial(trial, generated, keepData)};
}

test('opt-in trial adopts the APK key and recovers it after generated files are cleared', async t => {
  const {open, trial, cached, profile} = await trialPaths(t);
  const original = await open(false);
  await assert.rejects(access(trial), {code: 'ENOENT'});
  const first = await open(true);
  assert.deepEqual(first.credentials, original.credentials);
  assert.equal(first.requireExisting, false);
  assert.equal((await open(true)).requireExisting, false);
  await first.markReady();
  const saved = await readFile(profile, 'utf8');
  for (const keepData of [false, true]) {
    await unlink(cached);
    const reopened = await open(keepData);
    assert.deepEqual(reopened.credentials, original.credentials);
    assert.deepEqual(JSON.parse(await readFile(cached, 'utf8')), original.credentials);
    assert.equal(await readFile(profile, 'utf8'), saved);
    assert.equal(reopened.requireExisting, keepData ? true : undefined);
  }
});

test('a mismatched key and an incomplete trial are preserved for recovery', async t => {
  const {open, trial, cached, profile} = await trialPaths(t);
  await mkdir(trial);
  await assert.rejects(open(true), /Unrecognized local trial/);
  await assert.rejects(access(cached), {code: 'ENOENT'});
  await writeFile(profile, JSON.stringify({version: 9, ready: true}));
  await assert.rejects(open(true), /Unsupported local trial/);
  const credentials = {secret: 'x'.repeat(64), createdAt: Math.floor(Date.now() / 1000)};
  const original = JSON.stringify({version: 1, ready: true, credentials});
  await writeFile(profile, original);
  const different = JSON.stringify({...credentials, secret: 'y'.repeat(64)});
  await writeFile(cached, different);
  await assert.rejects(open(true), /signing configuration differ/);
  assert.equal(await readFile(cached, 'utf8'), different);
  assert.equal(await readFile(profile, 'utf8'), original);
});

test('retry preserves unfamiliar files, process locks and previously published family directories', async t => {
  const {open, trial} = await trialPaths(t);
  const first = await open(true), db = first.database, data = join(db, 'data');
  await mkdir(data, {recursive: true});
  const marker = join(db, 'initializing-cluster'), lock = join(data, 'postmaster.pid');
  await writeFile(marker, 'not this application');
  await assert.rejects(open(true), /Unrecognized first trial initialization/);
  await writeFile(marker, initializingTrialDatabase);
  const unknown = join(db, 'other-files');
  await writeFile(unknown, 'keep');
  await assert.rejects(open(true), /Unrecognized first trial initialization/);
  assert.equal(await readFile(unknown, 'utf8'), 'keep');
  await unlink(unknown);
  await writeFile(lock, 'still in use');
  await assert.rejects(open(true), /process lock/);
  await unlink(lock);
  await writeFile(join(data, 'customer-file'), 'keep');
  await assert.rejects(open(true), /Unrecognized unfinished PostgreSQL data/);
  assert.equal(await readFile(join(data, 'customer-file'), 'utf8'), 'keep');
  await unlink(join(data, 'customer-file'));
  await open(false);
  assert.deepEqual((await readdir(trial)).sort(), ['database', 'profile.json']);
  await first.markReady();
  assert.equal((await open(true)).requireExisting, true);
  assert.deepEqual((await readdir(trial)).sort(), ['database', 'profile.json']);
  assert.equal(await readFile(marker, 'utf8'), initializingTrialDatabase);
});

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
