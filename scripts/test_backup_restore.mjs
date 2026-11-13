// Recover a stopped local backend into new PostgreSQL and MinIO instances from actual archives.
import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {mkdir, mkdtemp, readFile, realpath, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {basename, join, resolve, sep} from 'node:path';
import {PDFDocument} from 'pdf-lib';
import {renderWorksheet} from '../supabase/functions/_shared/worksheet_pdf.mjs';
import {withAuthBackend} from './fixtures/auth_backend.mjs';
import {createStorageBackend} from './fixtures/storage_backend.mjs';
import {realApiClient} from './fixtures/real_api_client.mjs';
import {signedJwt} from './fixtures/http_test_tools.mjs';
import {databaseBackupTools, databaseFingerprint} from './fixtures/database_backup.mjs';

const started = performance.now(), runId = randomUUID();
const report = {runId, date: new Date().toISOString(), passed: false, status: 'running', checks: [],
  scope: 'Quiesced synthetic loopback backend; new PostgreSQL and MinIO; no cloud, PITR, live cross-service snapshot or device acceptance.'};
const output = resolve('build/backup_restore/results.json');
await mkdir(resolve('build/backup_restore'), {recursive: true});
const save = () => writeFile(output, JSON.stringify(report, null, 2) + '\n');
const passed = name => { report.checks.push(name); console.log('PASS ' + name); };
await save();
const backupDirectory = await mkdtemp(join(tmpdir(), 'learning-planet-backup-'));
const objectDirectory = join(backupDirectory, 'objects');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');
let baseline, files, owner, outsider, scope, otherScope, draft, pdf, task, pendingTask, completionKey, adjustment;
let adjustmentResult, credentials, sourceDirectory, originalSignedPath;

async function signedBytes(config, token, bucket, path) {
  const {api} = realApiClient(config);
  const response = await api(`/storage/v1/object/sign/${bucket}/${path}`, token, {method: 'POST', body: {expiresIn: 300}});
  assert.equal(response.status, 200);
  const download = await fetch(`${config.url}/storage/v1${response.data.signedURL}`, {signal: AbortSignal.timeout(10000)});
  assert.equal(download.status, 200);
  return {bytes: Buffer.from(await download.arrayBuffer()), path: response.data.signedURL, type: download.headers.get('content-type')};
}

try {
  const backup = await databaseBackupTools(); report.clients = backup.versions;
  report.sourceTraffic = await withAuthBackend(async (config, context) => {
    const {database, storage, secret, quiesce} = context, sql = database.client;
    sourceDirectory = database.directory;
    credentials = {secret, createdAt: Math.floor(Date.now()/1000)};
    report.postgres = database.serverVersion; report.applicationMigrations = database.migrationCount;
    const {api, rpc, account, family} = realApiClient(config);
    owner = await account(); outsider = await account();
    scope = await family(owner); otherScope = await family(outsider);
    const today = await rpc('family_today', owner.token, {target_child_id: scope.child});
    for (const title of ['恢复前已完成', '恢复后待完成']) {
      await rpc('save_task_schedule', owner.token, {target_child_id: scope.child, config: {
        title, recurrence: 'once', starts_on: today, ends_on: today,
        start_time: '00:00', due_time: '23:59', coins: 15, xp: 20, minimum_seconds: 0}});
    }
    const tasks = await api(`/rest/v1/task_instances?child_id=eq.${scope.child}&select=id,title`, owner.token);
    assert.equal(tasks.status, 200);
    task = tasks.data.find(row => row.title === '恢复前已完成').id;
    pendingTask = tasks.data.find(row => row.title === '恢复后待完成').id;
    completionKey = `task:${task}:${randomUUID()}`;
    await rpc('complete_task', owner.token, {target_task_id: task, completion_key: completionKey, parent_reason: '备份恢复演练补签'});
    adjustment = {target_child_id: scope.child, request_id: randomUUID(), command: {
      kind: 'adjust', coins: 30, xp_amount: 5, reason: '恢复演练调账'}};
    adjustmentResult = await rpc('resolve_economy_command', owner.token, adjustment);
    assert.equal(adjustmentResult.status, 'applied');
    async function images(user, child) {
      const draftId = randomUUID();
      const result = await rpc('begin_question_media_upload', user.token,
        {target_child_id: child, draft_id: draftId, payload_hash: hash(png)});
      for (const path of [result.original_path, result.processed_path]) {
        assert.equal((await api(`/storage/v1/object/wrong-question-images/${path}`, user.token,
          {method: 'POST', type: 'image/png', body: png})).status, 200);
      }
      await rpc('record_question_ocr', user.token, {target_draft_id: draftId, result: {text: '2+2=?'}});
      result.question = await rpc('save_review_question', user.token, {target_child_id: child,
        config: {kind: 'question', subject: 'math', prompt: '2+2=?', answers: ['4'], ocr_confirmed: true, ocr_draft_id: draftId}});
      return result;
    }
    draft = await images(owner, scope.child); await images(outsider, otherScope.child);
    originalSignedPath = (await signedBytes(config, owner.token, 'wrong-question-images', draft.original_path)).path;
    const worksheetId = randomUUID();
    await rpc('request_worksheet', owner.token, {target_child_id: scope.child, question_ids: [draft.question],
      config: {title: '备份恢复练习', include_answers: true}, request_id: worksheetId});
    await sql.query('grant service_role to http_authenticator');
    const service = signedJwt(secret, {role: 'service_role'});
    const claim = await rpc('claim_worksheet', service, {target_worksheet_id: worksheetId});
    const rendered = await renderWorksheet(claim.snapshot, await readFile('supabase/functions/worksheet-render/fonts/NotoSansSC-Regular.ttf'));
    pdf = {path: claim.pdf_path, sha256: hash(rendered.bytes), pages: rendered.pages};
    assert.equal((await api(`/storage/v1/object/worksheets/${pdf.path}`, service,
      {method: 'POST', type: 'application/pdf', body: Buffer.from(rendered.bytes)})).status, 200);
    await rpc('finish_worksheet', service, {target_worksheet_id: worksheetId, token: claim.lease_token,
      result: {pages: pdf.pages, byte_size: rendered.bytes.length, sha256: pdf.sha256, renderer_version: 'a4-v2'}});
    assert.equal(hash((await signedBytes(config, owner.token, 'worksheets', pdf.path)).bytes), pdf.sha256);
    passed('real OTP users, two isolated families, completed/pending tasks, ledger receipt, four private images and a rendered PDF seeded');
    await quiesce();
    assert.equal((await fetch(`${config.url}/rest/v1/`)).status, 503);
    baseline = await databaseFingerprint(sql);
    report.databaseFiles = await backup.backup(database, backupDirectory);
    files = await storage.backupObjects(objectDirectory);
    assert.equal(files.length, 5);
    assert.deepEqual(await storage.inspectObjects(), files);
    passed('writers stopped; actual pg_dump custom archive, role globals and five object byte backups created');
  }, {createStorage: args => createStorageBackend({...args, minimumObjects: 5})});
  // withAuthBackend has awaited all source service and PostgreSQL exits here.
  report.sourceStoppedBeforeRestore = true;
  report.targetTraffic = await withAuthBackend(async (config, {database, storage}) => {
    assert.notEqual(database.directory, sourceDirectory);
    assert.deepEqual(await storage.inspectObjects(), files);
    const {api, rpc, account} = realApiClient(config);
    const user = await api('/auth/v1/user', owner.token); assert.equal(user.status, 200); assert.equal(user.data.id, owner.id);
    const refreshed = await api('/auth/v1/token?grant_type=refresh_token', config.anon,
      {method: 'POST', body: {refresh_token: owner.session.refresh_token}});
    assert.equal(refreshed.status, 200); assert.equal(refreshed.data.user.id, owner.id);
    owner.token = refreshed.data.access_token;
    assert.equal((await rpc('verify_parent_pin', owner.token, {target_family_id: scope.id, candidate_pin: '2468'}))[0].verified, true);
    const newcomer = await account(); assert.notEqual(newcomer.id, owner.id);
    passed('restored Auth user, refresh token and parent PIN work; fresh OTP signup works in the new backend');
    const tasks = await api(`/rest/v1/task_instances?id=eq.${task}`, owner.token);
    assert.equal(tasks.status, 200); assert.equal(tasks.data[0].status, 'completed');
    assert.deepEqual((await api(`/rest/v1/task_instances?child_id=eq.${scope.child}`, outsider.token)).data, []);
    assert.deepEqual((await api(`/rest/v1/wrong_questions?child_id=eq.${scope.child}`, outsider.token)).data, []);
    for (const [bucket, path, expected] of [
      ['wrong-question-images', draft.original_path, hash(png)],
      ['wrong-question-images', draft.processed_path, hash(png)], ['worksheets', pdf.path, pdf.sha256],
    ]) {
      const result = await signedBytes(config, owner.token, bucket, path);
      assert.equal(hash(result.bytes), expected);
      assert.equal(result.type, bucket === 'worksheets' ? 'application/pdf' : 'image/png');
      if (bucket === 'worksheets') assert.equal((await PDFDocument.load(result.bytes)).getPageCount(), pdf.pages);
      for (const token of [outsider.token, config.anon]) {
        const denied = await api(`/storage/v1/object/sign/${bucket}/${path}`, token, {method: 'POST', body: {expiresIn: 300}});
        assert.ok([400,401,403,404].includes(denied.status), 'Other family and anonymous signing must remain denied');
      }
    }
    const oldSigned = await fetch(`${config.url}/storage/v1${originalSignedPath}`);
    assert.equal(oldSigned.status, 200); assert.equal(hash(Buffer.from(await oldSigned.arrayBuffer())), hash(png));
    passed('private image/PDF bytes and pre-backup signed token survive; other-family and anonymous access remain denied');
    const ledger = () => api(`/rest/v1/ledger_entries?child_id=eq.${scope.child}&order=id`, owner.token).then(result => {
      assert.equal(result.status, 200); return result.data;
    });
    const before = await ledger(); assert.ok(before.length >= 4);
    const walletBefore = await rpc('wallet_overview', owner.token, {target_child_id: scope.child});
    await rpc('complete_task', owner.token, {target_task_id: task, completion_key: completionKey, parent_reason: '备份恢复演练补签'});
    assert.deepEqual(await rpc('resolve_economy_command', owner.token, adjustment), adjustmentResult);
    assert.deepEqual(await ledger(), before);
    assert.deepEqual(await rpc('wallet_overview', owner.token, {target_child_id: scope.child}), walletBefore);
    passed('task completion and adjustment replay preserve original ledger IDs and balances without a second award');
    await rpc('complete_task', owner.token, {target_task_id: pendingTask, completion_key: `task:${pendingTask}:${randomUUID()}`,
      parent_reason: '恢复后补签'});
    assert.equal((await ledger()).length, before.length + 2);
    passed('new task completion after restore creates exactly one coin entry and one XP entry');
    report.walletAfterReplay = walletBefore;
  }, {
    localCredentials: credentials,
    createStorage: async args => {
      const storage = await createStorageBackend({...args, minimumObjects: 5});
      try {
        const manifest = JSON.parse(await readFile(join(objectDirectory, 'manifest.json'), 'utf8'));
        const filename = join(objectDirectory, manifest.objects.at(-1).file), original = await readFile(filename);
        const corrupted = Buffer.from(original); corrupted[0] ^= 1; await writeFile(filename, corrupted);
        await assert.rejects(storage.restoreObjects(objectDirectory), /checksum mismatch/);
        assert.deepEqual(await storage.inspectObjects(), []);
        await writeFile(filename, original);
        passed('same-length corrupt object backup is rejected before any object is restored');
        await storage.restoreObjects(objectDirectory);
        return storage;
      } catch (error) { await storage.stop(); throw error; }
    },
    restoreDatabase: async context => {
      const filename = join(backupDirectory, 'database.dump'), original = await readFile(filename);
      const corrupted = Buffer.from(original); corrupted[0] ^= 1; await writeFile(filename, corrupted);
      await assert.rejects(backup.restore(context, backupDirectory), /checksum mismatch/);
      assert.equal((await context.client.query("select count(*)::int n from pg_roles where rolname='supabase_auth_admin'")).rows[0].n, 0);
      await writeFile(filename, original);
      passed('corrupt database archive is rejected before creating restored roles or schema');
      await backup.restore(context, backupDirectory);
      assert.deepEqual(await databaseFingerprint(context.client), baseline,
        'All table rows, sequences, roles, owners, grants, RLS policies and function definitions must match before API startup');
      report.restored = baseline;
      passed('fresh database restored with exact table/sequence/catalog fingerprints, without reapplying business migrations');
    },
  });
  report.servicesStopped = true;
  report.objects = files.map(({size, sha256}) => ({size, sha256}));
  report.passed = true; report.status = 'complete';
} catch (error) {
  report.status = 'failed'; report.errorType = error.name; throw error;
} finally {
  // Only this run's synthetic archive directory; never service data or workspace artifacts.
  const target = await realpath(backupDirectory), root = await realpath(tmpdir());
  assert.ok(target.startsWith(root + sep) && basename(target).startsWith('learning-planet-backup-'));
  await rm(target, {recursive: true, force: true});
  report.temporaryArchivesRemoved = true;
  report.elapsedSeconds = Math.round((performance.now() - started)/100)/10;
  await save();
}
console.log(`All ${report.checks.length} local backup/restore checks passed; services stopped and synthetic archives removed.`);
