// Real services and unmodified Edge entrypoints. No cloud credentials or user data.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createServer, request as upstreamRequest} from 'node:http';
import {resolve} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {withAuthBackend} from './fixtures/auth_backend.mjs';
import {createStorageBackend} from './fixtures/storage_backend.mjs';
import {closeServer, forwardHttp, freePort, isolatedEnv, listen, localProcess, signedJwt} from './fixtures/http_test_tools.mjs';

let checks = 0;
await withAuthBackend(async ({url, anon, mailboxKey}, {database, secret, storage}) => {
  const sql = database.client;
  // Only server-side workers receive this key. Flutter tests never receive it.
  await sql.query('grant service_role to http_authenticator');
  const service = signedJwt(secret, {role: 'service_role'});
  async function api(path, token = anon, {method = 'GET', body, type = 'application/json'} = {}) {
    const response = await fetch(`${url}${path}`, {method, headers: {apikey: anon,
      Authorization: `Bearer ${token}`, 'Content-Type': type},
    body: body === undefined ? undefined : Buffer.isBuffer(body) ? body : JSON.stringify(body),
    signal: AbortSignal.timeout(15000)});
    const text = await response.text();
    let data; try { data = JSON.parse(text); } catch { data = text; }
    return {status: response.status, data};
  }
  async function rpc(name, token, params = {}) {
    const result = await api(`/rest/v1/rpc/${name}`, token, {method: 'POST', body: params});
    assert.ok([200, 204].includes(result.status), `RPC ${name} failed (${result.status}): ${JSON.stringify(result.data)}`);
    return result.status === 204 ? null : result.data;
  }
  async function account() {
    const email = `privacy-${randomUUID()}@example.test`;
    assert.equal((await api('/auth/v1/otp', anon, {method: 'POST', body: {email, create_user: true}})).status, 200);
    const mail = await fetch(`${url}/__test/mail?email=${encodeURIComponent(email)}`, {headers: {'x-test-mailbox-key': mailboxKey}});
    assert.equal(mail.status, 200);
    const code = (await mail.json()).code;
    const response = await api('/auth/v1/verify', anon, {method: 'POST', body: {email, token: code, type: 'email'}});
    assert.equal(response.status, 200);
    return {token: response.data.access_token, refresh: response.data.refresh_token, id: response.data.user.id, email};
  }
  async function family(user) {
    await rpc('onboard_family_profile', user.token, {family_name: 'Privacy fixture', family_timezone: 'Asia/Shanghai',
      child_nickname: 'First', child_grade: 2, preferences: {textbook_labels: {}, avatar_key: 'star'}});
    const families = await api('/rest/v1/families?select=id', user.token);
    assert.equal(families.status, 200); const id = families.data[0].id;
    const children = await api(`/rest/v1/children?select=id&family_id=eq.${id}`, user.token);
    assert.equal(children.status, 200);
    await rpc('set_parent_pin', user.token, {target_family_id: id, new_pin: '2468'});
    const pin = await rpc('verify_parent_pin', user.token, {target_family_id: id, candidate_pin: '2468'});
    assert.equal(pin[0].verified, true);
    return {id, child: children.data[0].id};
  }
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');
  async function images(user, child) {
    const draft = await rpc('begin_question_media_upload', user.token, {target_child_id: child, draft_id: randomUUID(), payload_hash: 'a'.repeat(64)});
    for (const path of [draft.original_path, draft.processed_path]) {
      const upload = await api(`/storage/v1/object/wrong-question-images/${path}`, user.token,
        {method: 'POST', type: 'image/png', body: png});
      assert.equal(upload.status, 200, 'Real image upload failed');
    }
    await rpc('record_question_ocr', user.token, {target_draft_id: draft.id, result: {text: '2+2=?'}});
    draft.question = await rpc('save_review_question', user.token, {target_child_id: child,
      config: {kind: 'question', subject: 'math', prompt: '2+2=?', answers: ['4'], ocr_confirmed: true, ocr_draft_id: draft.id}});
    const signed = await api(`/storage/v1/object/sign/wrong-question-images/${draft.original_path}`, user.token,
      {method: 'POST', body: {expiresIn: 300}});
    assert.equal(signed.status, 200);
    draft.signed = `${url}/storage/v1${signed.data.signedURL}`;
    assert.equal((await fetch(draft.signed)).status, 200);
    return draft;
  }
  let blockStorage = false, loseAuthReply = false, lostAuthReplies = 0, blockedRemoves = 0;
  const claimStates = [];
  const gatewayPort = Number(new URL(url).port);
  const faultProxy = createServer((incoming, outgoing) => {
    if (incoming.url === '/rest/v1/rpc/claim_account_deletion') {
      const upstream = upstreamRequest({hostname: '127.0.0.1', port: gatewayPort, path: incoming.url,
        method: incoming.method, headers: incoming.headers}, response => {
        const chunks = [];
        response.on('data', chunk => chunks.push(chunk));
        response.on('end', () => {
          const bytes = Buffer.concat(chunks);
          if (response.statusCode === 200) claimStates.push(JSON.parse(bytes.toString()).status);
          outgoing.writeHead(response.statusCode, response.headers); outgoing.end(bytes);
        });
      });
      upstream.on('error', () => { outgoing.writeHead(502); outgoing.end(); }); incoming.pipe(upstream); return;
    }
    if (blockStorage && incoming.method === 'DELETE' && incoming.url.startsWith('/storage/v1/object/')) {
      blockedRemoves++; incoming.resume(); outgoing.writeHead(503, {'Content-Type': 'application/json'});
      outgoing.end(JSON.stringify({statusCode: '503', error: 'Unavailable', message: 'Injected local failure'})); return;
    }
    if (loseAuthReply && incoming.method === 'DELETE' && incoming.url.startsWith('/auth/v1/admin/users/')) {
      const upstream = upstreamRequest({hostname: '127.0.0.1', port: gatewayPort, path: incoming.url,
        method: incoming.method, headers: incoming.headers}, response => {
        const chunks = [];
        response.on('data', chunk => chunks.push(chunk));
        response.on('end', () => {
          if (response.statusCode === 200) {
            loseAuthReply = false; lostAuthReplies++;
            outgoing.writeHead(503, {'Content-Type': 'application/json'});
            outgoing.end(JSON.stringify({message: 'Injected lost Auth delete reply'}));
          } else { outgoing.writeHead(response.statusCode, response.headers); outgoing.end(Buffer.concat(chunks)); }
        });
      });
      upstream.on('error', () => { outgoing.writeHead(502); outgoing.end(); }); incoming.pipe(upstream); return;
    }
    forwardHttp(incoming, outgoing, gatewayPort, '');
  });
  const edges = [];
  async function edge(kind) {
    const port = await freePort();
    const proxyPort = faultProxy.address().port;
    const env = isolatedEnv(['SUPABASE_', 'TEST_EDGE_']);
    Object.assign(env, {SUPABASE_URL: `http://127.0.0.1:${proxyPort}`, SUPABASE_ANON_KEY: anon,
      SUPABASE_SERVICE_ROLE_KEY: service, TEST_EDGE_KIND: kind, TEST_EDGE_PORT: String(port)});
    const binary = process.platform === 'win32' ? resolve('node_modules/deno/deno.exe') : resolve('node_modules/.bin/deno');
    const processHandle = localProcess(binary, ['run', '--cached-only', '--config', 'supabase/functions/worksheet-render/deno.json',
      '--allow-env=SUPABASE_URL,SUPABASE_ANON_KEY,SUPABASE_SERVICE_ROLE_KEY,TEST_EDGE_PORT,TEST_EDGE_KIND',
      `--allow-net=127.0.0.1:${proxyPort},127.0.0.1:${port}`, `--allow-read=${resolve('supabase/functions')}`,
      'scripts/fixtures/edge_bootstrap.mjs'], {env, name: `Privacy Edge ${kind}`});
    edges.push(processHandle);
    const endpoint = `http://127.0.0.1:${port}`;
    let ready = false;
    for (let attempt = 0; attempt < 100; attempt++) {
      if (processHandle.child.exitCode !== null) await processHandle.successful();
      try { if ((await fetch(endpoint, {method: 'OPTIONS', signal: AbortSignal.timeout(500)})).status === 204) { ready = true; break; } } catch { /* booting */ }
      await delay(100);
    }
    assert.ok(ready, `Edge ${kind} did not start`);
    return async (token, body) => {
      const response = await fetch(endpoint, {method: 'POST', headers: {Authorization: `Bearer ${token}`, 'Content-Type': 'application/json'},
        body: JSON.stringify(body), signal: AbortSignal.timeout(10000)});
      return {status: response.status, data: await response.json()};
    };
  }
  async function state(table, id) {
    assert.ok(['cleanup_jobs', 'account_deletion_jobs'].includes(table));
    return (await sql.query(`select * from public.${table} where id=$1`, [id])).rows[0];
  }
  async function until(table, id, expected, afterAttempt = 0) {
    for (let attempt = 0; attempt < 150; attempt++) {
      const row = await state(table, id);
      if (row?.attempts > afterAttempt && row.status === expected) return row;
      if (row?.attempts > afterAttempt && row.status === 'failed' && expected !== 'failed') throw new Error(`Worker failed: ${row.error_code}`);
      await delay(100);
    }
    const row = await state(table, id);
    throw new Error(`Worker did not reach ${expected}: ${row?.status}/${row?.error_code}`);
  }
  function passed(message) { checks++; console.log(`PASS ${message}`); }
  try {
    await listen(faultProxy);
    const cleanup = await edge('cleanup'), deletion = await edge('account');
    const owner = await account(), other = await account();
    const own = await family(owner), unrelated = await family(other);
    await rpc('invite_family_parent', other.token, {target_family_id: unrelated.id, parent_email: owner.email});
    assert.equal(await rpc('accept_family_invitations', owner.token), 1);
    assert.equal((await rpc('verify_parent_pin', owner.token, {target_family_id: unrelated.id, candidate_pin: '2468'}))[0].verified, true);
    const sibling = await rpc('create_child_profile', owner.token, {target_family_id: own.id, child_nickname: 'Sibling', child_grade: 2,
      preferences: {textbook_labels: {}, avatar_key: 'star'}});
    const target = await images(owner, own.child), siblingImage = await images(owner, sibling);
    const keep = [await images(other, unrelated.child), await images(other, unrelated.child)];
    const shared = await images(owner, unrelated.child);
    const keepIds = keep.map(draft => draft.id);
    const before = await storage.inspectObjects();
    assert.equal(before.length, 10);
    const preserved = before.filter(object => keepIds.some(id => object.key.includes(id)));
    assert.equal(preserved.length, 4);
    passed('real Auth users, accepted family invitation and ten S3 images prepared through public APIs');

    const preview = await rpc('preview_child_deletion', owner.token, {target_child_id: own.child});
    const childJob = randomUUID(), request = {target_child_id: own.child, request_id: childJob, expected_counts: preview.counts, confirmation: '永久删除孩子'};
    assert.equal(await rpc('request_child_deletion', owner.token, request), childJob);
    assert.equal(await rpc('request_child_deletion', owner.token, request), childJob);
    assert.equal((await cleanup(other.token, {job_id: childJob})).status, 403);
    assert.equal((await cleanup(owner.token, {mode: 'drain'})).status, 403);
    const waiting = await cleanup(owner.token, {job_id: childJob});
    assert.equal(waiting.status, 200); assert.equal(waiting.data.status, 'queued');
    assert.deepEqual(await storage.inspectObjects(), before);
    passed('child deletion replay and permissions preserve the ten-minute upload grace window');

    // Advance only this synthetic job's clock. This is not a real 24-hour SLA test.
    await sql.query("update public.cleanup_jobs set next_attempt_at=now()-interval '1 second' where id=$1", [childJob]);
    assert.equal((await cleanup(owner.token, {job_id: childJob, manifest: [{path: keep[0].original_path}]})).status, 202);
    try { await until('cleanup_jobs', childJob, 'completed'); }
    catch (error) {
      const head = await api(`/storage/v1/object/wrong-question-images/${target.original_path}`, service, {method: 'HEAD'});
      const info = await api(`/storage/v1/object/info/wrong-question-images/${target.original_path}`, service);
      console.error('Storage absence response:', {headStatus: head.status, infoStatus: info.status, info: info.data});
      throw error;
    }
    const afterChild = await storage.inspectObjects();
    assert.equal(afterChild.length, 8);
    assert.ok(afterChild.every(object => !object.key.includes(target.id)));
    assert.ok([400, 404].includes((await fetch(target.signed)).status));
    assert.equal((await fetch(siblingImage.signed)).status, 200);
    assert.deepEqual(afterChild.filter(object => keepIds.some(id => object.key.includes(id))), preserved);
    assert.equal((await cleanup(owner.token, {job_id: childJob})).data.status, 'completed');
    passed('real cleanup removes both image bytes and metadata; sibling and other-family images survive');

    const {scope} = await rpc('preview_account_deletion', owner.token), accountJob = randomUUID();
    assert.equal(scope.shared_uploads, 1);
    assert.equal(await rpc('request_account_deletion', owner.token, {request_id: accountJob, expected_scope: scope, confirmation: '永久注销我的账号'}), accountJob);
    assert.equal((await deletion(other.token, {mode: 'drain'})).status, 403);
    const early = await deletion(owner.token, {user_id: other.id, job_id: randomUUID()});
    assert.equal(early.status, 202);
    for (let attempt = 0; attempt < 100 && !claimStates.includes('waiting'); attempt++) await delay(50);
    assert.ok(claimStates.includes('waiting'), 'The early worker must finish checking the grace window before advancing its clock');
    assert.equal((await state('account_deletion_jobs', accountJob)).status, 'queued');
    const childJobs = (await sql.query("select id from public.cleanup_jobs where family_id=$1 and status not in ('completed','superseded')", [own.id])).rows.map(row => row.id);
    assert.equal(childJobs.length, 1, 'Account deletion must enqueue the remaining child cleanup');
    await sql.query("update public.cleanup_jobs set next_attempt_at=now()-interval '1 second' where id=any($1::uuid[])", [childJobs]);
    await sql.query("update public.account_deletion_jobs set next_attempt_at=now()-interval '1 second' where id=$1", [accountJob]);
    blockStorage = true;
    assert.equal((await cleanup(service, {mode: 'drain'})).status, 202);
    const cleanupFailures = await Promise.all(childJobs.map(id => until('cleanup_jobs', id, 'failed')));
    for (const failure of cleanupFailures) assert.equal(failure.error_code, 'STORAGE_REMOVE_FAILED');
    assert.equal((await deletion(service, {mode: 'drain'})).status, 202);
    for (let attempt = 0; attempt < 100 && (await state('account_deletion_jobs', accountJob)).error_code !== 'WAITING_FILE_JOBS'; attempt++) await delay(50);
    const waitingFiles = await state('account_deletion_jobs', accountJob);
    assert.equal(waitingFiles.status, 'queued'); assert.equal(waitingFiles.error_code, 'WAITING_FILE_JOBS');
    assert.ok(blockedRemoves > 0);
    assert.equal((await sql.query('select count(*)::int n from auth.users where id=$1', [owner.id])).rows[0].n, 1);
    assert.deepEqual(await storage.inspectObjects(), afterChild);
    passed('Storage failure leaves the Auth account and physical images pending for retry');

    blockStorage = false;
    await sql.query("update public.cleanup_jobs set next_attempt_at=now()-interval '1 second' where id=any($1::uuid[])", [childJobs]);
    assert.equal((await cleanup(service, {mode: 'drain'})).status, 202);
    await Promise.all(childJobs.map((id, index) => until('cleanup_jobs', id, 'completed', cleanupFailures[index].attempts)));
    assert.deepEqual(await storage.inspectObjects(), afterChild.filter(object => !object.key.includes(siblingImage.id)));
    loseAuthReply = true;
    await sql.query("update public.account_deletion_jobs set next_attempt_at=now()-interval '1 second' where id=$1", [accountJob]);
    assert.equal((await deletion(service, {mode: 'drain'})).status, 202);
    const failedAuth = await until('account_deletion_jobs', accountJob, 'failed');
    assert.equal(failedAuth.error_code, 'AUTH_DELETE_FAILED');
    assert.equal(lostAuthReplies, 1);
    assert.equal((await sql.query('select count(*)::int n from auth.users where id=$1', [owner.id])).rows[0].n, 0);
    assert.deepEqual(await storage.inspectObjects(), preserved);
    passed('Auth delete really commits before an injected lost reply, without deleting unrelated images');

    await sql.query("update public.account_deletion_jobs set next_attempt_at=now()-interval '1 second' where id=$1", [accountJob]);
    assert.equal((await deletion(service, {mode: 'drain'})).status, 202);
    const complete = await until('account_deletion_jobs', accountJob, 'completed', failedAuth.attempts);
    assert.deepEqual(complete.manifest, []);
    assert.ok([401, 403, 404].includes((await api('/auth/v1/user', owner.token)).status));
    assert.ok([400, 401].includes((await api('/auth/v1/token?grant_type=refresh_token', anon, {method: 'POST', body: {refresh_token: owner.refresh}})).status));
    assert.equal((await api('/auth/v1/user', other.token)).status, 200);
    assert.equal((await api(`/rest/v1/children?select=id&family_id=eq.${unrelated.id}`, owner.token)).data.length, 0);
    assert.deepEqual(await storage.inspectObjects(), preserved);
    const repeated = await deletion(service, {mode: 'drain'});
    assert.equal(repeated.status, 202); assert.equal(repeated.data.jobs, 0);
    passed('missing-user retry finalizes once, clears the manifest and rejects deleted credentials');
    const retained = await api(`/rest/v1/wrong_questions?select=id,final_text&child_id=eq.${unrelated.child}`, other.token);
    assert.equal(retained.status, 200); assert.equal(retained.data.length, 3);
    assert.equal(retained.data.find(question => question.id === shared.question).final_text, '2+2=?');
    assert.ok([400,404].includes((await fetch(shared.signed)).status));
    const reuse = await api('/rest/v1/rpc/begin_question_media_upload', other.token, {method:'POST', body:{
      target_child_id:unrelated.child,draft_id:shared.id,payload_hash:'a'.repeat(64)}});
    assert.ok([400,403].includes(reuse.status));
    assert.deepEqual(await storage.inspectObjects(), preserved);
    passed('joined family keeps edited questions and other-member images while deleted upload IDs cannot be reused');
  } finally {
    for (const processHandle of edges.reverse()) await processHandle.stop();
    await closeServer(faultProxy);
  }
}, {createStorage: createStorageBackend});
console.log(`All ${checks} real privacy integration checks passed; simulated job clocks, no cloud SLA claim.`);
