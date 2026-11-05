// Real-service fixtures and a loopback network gate for the installed debug APK.
// Only setup creates business data; recovery observes requests and reads state.
import assert from 'node:assert/strict';
import {randomBytes, randomUUID} from 'node:crypto';
import {createServer, request as httpRequest} from 'node:http';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {setTimeout as delay} from 'node:timers/promises';
import {realApiClient} from './fixtures/real_api_client.mjs';
import {listen, closeServer} from './fixtures/http_test_tools.mjs';

const command = process.argv[2];
assert.ok(['setup', 'probe', 'offline', 'recover', 'state', 'verify', 'stop'].includes(command),
  'Usage: local_auto_sync_scenario.mjs setup|probe|offline|recover <foreground|restart>|state|verify|stop');
const directory = '.dart_tool/local-backend', output = 'build/auto_sync_device_results';
const json = async path => JSON.parse(await readFile(path, 'utf8'));
const save = async (path, value) => writeFile(path, JSON.stringify(value, null, 2) + '\n', {mode: 0o600});
const control = await json(`${directory}/control.json`), config = await json(`${directory}/defines.json`);
assert.equal(control.url, 'http://127.0.0.1:54321');
const health = await fetch(`${control.url}/__local/health`, {signal: AbortSignal.timeout(3000)});
assert.equal(health.status, 200);
assert.equal((await health.json()).runId, control.runId, 'Local backend session changed');
const api = realApiClient({url: control.mailUrl, anon: config.SUPABASE_ANON_KEY, mailboxKey: control.mailboxKey});
const scenarioPath = `${directory}/auto-sync-scenario.json`, probePath = `${directory}/auto-sync-probe.json`;
await mkdir(output, {recursive: true});

async function probeCall(action, label) {
  const probe = await json(probePath);
  assert.equal(probe.runId, control.runId);
  const response = await fetch('http://127.0.0.1:54322/__probe/control', {
    method: 'POST', headers: {'x-probe-key': probe.key, 'Content-Type': 'application/json'},
    body: JSON.stringify({action, label}), signal: AbortSignal.timeout(3000),
  });
  assert.equal(response.status, 200);
  return response.json();
}

async function probe() {
  const key = randomBytes(32).toString('hex'), probeId = randomUUID();
  const active = new Set(), windows = [];
  let online = true, window = null, finish;
  const done = new Promise(resolve => { finish = resolve; });
  const server = createServer((incoming, outgoing) => {
    if (incoming.url === '/__probe/control') {
      if (incoming.method !== 'POST' || incoming.headers['x-probe-key'] !== key) {
        outgoing.writeHead(403); outgoing.end(); return;
      }
      let body = '';
      incoming.on('data', chunk => { body += chunk; if (body.length > 1024) incoming.destroy(); });
      incoming.on('end', () => {
        try {
          const input = JSON.parse(body);
          if (input.action === 'offline') {
            online = false; window = null;
            for (const entry of active) { entry.upstream.destroy(); entry.outgoing.destroy(); }
          } else if (input.action === 'online') {
            assert.equal(online, false, 'Start recovery from an offline gate');
            assert.ok(['foreground', 'restart'].includes(input.label));
            assert.ok(!windows.some(row => row.label === input.label), 'Use a fresh probe for another run');
            window = {id: randomUUID(), label: input.label, startedAt: new Date().toISOString(),
              monotonicStart: performance.now(), events: []};
            windows.push(window); online = true;
          } else assert.ok(['report', 'stop'].includes(input.action));
          outgoing.writeHead(200, {'Content-Type': 'application/json', 'Cache-Control': 'no-store'});
          outgoing.end(JSON.stringify({runId: control.runId, probeId, online,
            windows: windows.map(({monotonicStart, ...row}) => row)}));
          if (input.action === 'stop') finish();
        } catch {
          outgoing.writeHead(400); outgoing.end();
        }
      });
      return;
    }
    if (!online) { incoming.destroy(); return; }
    const path = new URL(incoming.url, control.url).pathname;
    if (!['/auth/v1/', '/rest/v1/', '/storage/v1/', '/functions/v1/'].some(prefix => path.startsWith(prefix))) {
      outgoing.writeHead(404); outgoing.end(); return;
    }
    const current = window;
    const kind = path === '/rest/v1/rpc/task_sync_snapshot' ? 'snapshot'
      : path === '/rest/v1/rpc/apply_task_command' ? 'apply' : null;
    const event = current && kind ? {kind, startMs: Math.round(performance.now() - current.monotonicStart), status: null} : null;
    if (event) current.events.push(event);
    // Never record authorization headers, body/answers, query parameters or OTPs.
    const upstream = httpRequest({hostname: '127.0.0.1', port: 54321, method: incoming.method,
      path: incoming.url, headers: incoming.headers}, response => {
      outgoing.writeHead(response.statusCode, response.headers);
      if (event) event.status = response.statusCode;
      response.pipe(outgoing);
    });
    const entry = {upstream, outgoing}; active.add(entry);
    upstream.setTimeout(20000, () => upstream.destroy());
    upstream.on('error', () => outgoing.destroy());
    incoming.on('aborted', () => upstream.destroy());
    outgoing.on('close', () => { active.delete(entry); upstream.destroy(); });
    outgoing.on('finish', () => { if (event) event.finishMs = Math.round(performance.now() - current.monotonicStart); });
    incoming.pipe(upstream);
  });
  await listen(server, 54322);
  await save(probePath, {runId: control.runId, probeId, key});
  const lifetime = setTimeout(finish, 3600000);
  const stop = () => finish();
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
  console.log('AUTO_SYNC_PROBE_READY 127.0.0.1:54322 -> 127.0.0.1:54321; metadata only');
  try { await done; } finally {
    clearTimeout(lifetime);
    for (const entry of active) { entry.upstream.destroy(); entry.outgoing.destroy(); }
    await closeServer(server);
    process.removeListener('SIGINT', stop); process.removeListener('SIGTERM', stop);
  }
}

async function state(scenario) {
  const {user, family, tasks} = scenario;
  const rows = await api.api(`/rest/v1/task_instances?select=id,status&child_id=eq.${family.child}`, user.token);
  assert.equal(rows.status, 200);
  assert.deepEqual(rows.data.map(row => row.id).sort(), tasks.map(row => row.id).sort());
  const wallet = await api.rpc('wallet_overview', user.token, {target_child_id: family.child});
  const ledger = await api.api(`/rest/v1/ledger_entries?select=id,asset_type,amount,source_id&child_id=eq.${family.child}&order=id`, user.token);
  assert.equal(ledger.status, 200);
  return {tasks: rows.data, completed: rows.data.filter(row => row.status === 'completed').length,
    wallet: {coins: wallet.coin_balance, frozen: wallet.frozen_balance, xp: wallet.xp}, ledger: ledger.data};
}

function assertRewards(value, completed) {
  assert.equal(value.completed, completed);
  assert.deepEqual(value.wallet, {coins: completed * 25, frozen: 0, xp: completed * 20});
  assert.equal(value.ledger.length, completed * 2);
  const done = value.tasks.filter(row => row.status === 'completed').map(row => row.id);
  for (const task of done) {
    const rewards = value.ledger.filter(row => row.source_id === task).map(row => [row.asset_type, row.amount]).sort();
    assert.deepEqual(rewards, [['coin', 25], ['xp', 20]]);
  }
}

if (command === 'probe') {
  await probe();
} else if (command === 'setup') {
  for (const name of ['foreground', 'restart', 'stable', 'walkthrough']) {
    await save(`${output}/${name}.json`, {runId: control.runId, passed: false, status: 'not_run'});
  }
  const user = await api.account(), family = await api.family(user);
  const snapshot = await api.rpc('task_sync_snapshot', user.token, {target_child_id: family.child});
  const day = new Intl.DateTimeFormat('en-CA', {timeZone: snapshot.timezone, year: 'numeric', month: '2-digit', day: '2-digit'}).format(new Date(snapshot.server_at));
  for (const title of ['自动同步甲', '自动同步乙']) {
    await api.rpc('save_task_schedule', user.token, {target_child_id: family.child, config: {
      title, recurrence: 'once', starts_on: day, ends_on: day, start_time: '00:00', due_time: '23:59',
      coins: 25, xp: 20, minimum_seconds: 0,
    }});
  }
  const tasks = (await api.rpc('task_sync_snapshot', user.token, {target_child_id: family.child})).tasks;
  assert.equal(tasks.length, 2);
  const scenario = {runId: control.runId, user, family, tasks: tasks.map(({id, title}) => ({id, title}))};
  await save(scenarioPath, scenario);
  const baseline = await state(scenario); assertRewards(baseline, 0);
  await save(`${output}/baseline.json`, {runId: control.runId, ...baseline});
  console.log(JSON.stringify({email: user.email, tasks: scenario.tasks, wallet: baseline.wallet}));
} else if (command === 'offline' || command === 'stop') {
  const result = await probeCall(command);
  console.log(JSON.stringify({runId: result.runId, probeId: result.probeId, online: result.online, command}));
} else {
  const scenario = await json(scenarioPath);
  assert.equal(scenario.runId, control.runId);
  if (command === 'recover') {
    const label = process.argv[3];
    assert.ok(['foreground', 'restart'].includes(label));
    const completed = label === 'foreground' ? 1 : 2;
    const reportPath = `${output}/${label}.json`;
    await save(reportPath, {runId: control.runId, label, passed: false, status: 'running'});
    try {
      assertRewards(await state(scenario), completed - 1);
      const opened = await probeCall('online', label), watch = performance.now();
      let observed;
      do {
        observed = await state(scenario);
        if (observed.completed === completed) break;
        await delay(200);
      } while (performance.now() - watch < 45000);
      assertRewards(observed, completed);
      const evidence = await probeCall('report');
      assert.equal(evidence.probeId, opened.probeId);
      const window = evidence.windows.find(row => row.label === label);
      const snapshot = window.events.find(row => row.kind === 'snapshot' && row.status === 200);
      const apply = window.events.find(row => row.kind === 'apply' && row.status === 200);
      assert.ok(snapshot && apply, 'The APK must send actual sync requests through the gate');
      assert.ok(snapshot.startMs <= 30000 && apply.startMs <= 30000, 'Automatic sync did not reach the service within 30 seconds');
      assert.ok(window.events.filter(row => row.kind === 'apply' && row.status === 200).length >= 2);
      const result = {runId: control.runId, probeId: evidence.probeId, label, passed: true,
        firstSnapshotMs: snapshot.startMs, firstApplyMs: apply.startMs,
        confirmedByMs: Math.round(performance.now() - watch), window, ...observed,
        scope: 'Installed APK foreground polling; loopback connection failure/recovery; no manual sync. No physical phone or background guarantee.'};
      await save(reportPath, result);
      console.log(JSON.stringify(result, null, 2));
    } catch (error) {
      await save(reportPath, {runId: control.runId, label, passed: false, status: 'failed', reason: error.code ?? error.name});
      throw error;
    }
  } else {
    if (command === 'verify') {
      await save(`${output}/stable.json`, {runId: control.runId, passed: false, status: 'running'});
    }
    const current = await state(scenario);
    if (command === 'verify') {
      const previous = await json(`${output}/restart.json`);
      assert.equal(previous.passed, true); assert.equal(previous.runId, control.runId);
      assertRewards(current, 2);
      assert.deepEqual(current.wallet, previous.wallet);
      assert.deepEqual(current.ledger, previous.ledger);
      const probe = await probeCall('report');
      assert.equal(probe.probeId, previous.probeId);
      const window = probe.windows.find(row => row.label === 'restart');
      const snapshots = window.events.filter(row => row.kind === 'snapshot' && row.status === 200);
      assert.ok(snapshots.length >= 2, 'Wait for another automatic polling round before verifying stable rewards');
      assert.ok(snapshots.at(-1).startMs > previous.window.events.at(-1).startMs);
      await save(`${output}/stable.json`, {runId: control.runId, probeId: probe.probeId,
        date: new Date().toISOString(), passed: true, subsequentSnapshotMs: snapshots.at(-1).startMs,
        ...current});
    }
    console.log(JSON.stringify(current, null, 2));
  }
}
