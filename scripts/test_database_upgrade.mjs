// Upgrade a populated historical database through the actual migration files.
// Auth/Storage are schema fixtures; this is not a hosted Supabase rehearsal.
import assert from 'node:assert/strict';
import {randomUUID, createHash} from 'node:crypto';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {startTestDatabase} from './fixtures/database.mjs';
import {freePort} from './fixtures/http_test_tools.mjs';

const output = 'build/database_upgrade', runId = randomUUID();
await mkdir(output, {recursive: true});
const report = {runId, passed: false, status: 'running', scope: 'Populated local PostgreSQL upgrade; Auth/Storage schema fixtures',
  checkpoints: [], checks: [], migrations: []};
const saveReport = () => writeFile(`${output}/results.json`, JSON.stringify(report, null, 2) + '\n');
await saveReport();
const owner = randomUUID(), outsider = randomUUID(), session = randomUUID();
const data = {}, saved = [];
let database, client;
const scalar = async (sql, args = []) => Object.values((await client.query(sql, args)).rows[0])[0];
async function login(user = owner, currentSession = session) {
  await client.query('reset role');
  await scalar("select set_config('request.jwt.claims',$1,false)", [JSON.stringify({sub: user, role: 'authenticated',
    session_id: currentSession, email: user === owner ? 'upgrade@example.test' : 'outsider@example.test',
    iat: Math.floor(Date.now() / 1000)})]);
  await client.query('set role authenticated');
}
async function clearIdentity() {
  await client.query('reset role');
  await scalar("select set_config('request.jwt.claims','{}',false)");
}
async function authorize() {
  await login();
  const result = await client.query("select * from public.verify_parent_pin($1,'2468')", [data.family]);
  assert.equal(result.rows[0].verified, true);
}
async function check(name, action) {
  await action(); report.checks.push(name); console.log('PASS ' + name);
}
async function capture(table, condition, parameters) {
  assert.match(table, /^[a-z_]+$/);
  await clearIdentity();
  const rows = (await client.query(`select to_jsonb(t) as row from public.${table} t where ${condition}`, parameters)).rows.map(row => row.row);
  assert.ok(rows.length > 0, `No historical ${table} rows captured`);
  saved.push({table, condition, parameters, rows});
  await login();
}
async function wallet(child) {
  return scalar('select jsonb_build_object(\'coins\',coin_balance,\'frozen\',frozen_balance,\'xp\',xp) from public.wallets where child_id=$1', [child]);
}
async function task(child, title) {
  const day = await scalar('select public.family_today($1)', [child]);
  const template = await scalar('select public.save_task_schedule($1,$2)', [child, {title, recurrence: 'once',
    starts_on: day, ends_on: day, start_time: '00:00', due_time: '23:59', coins: 25, xp: 20, minimum_seconds: 0}]);
  return scalar('select id from public.task_instances where template_id=$1', [template]);
}
async function seedCore() {
  await login();
  data.family = await scalar("select public.onboard_family('Upgrade','Asia/Shanghai','Historical child',2::smallint)");
  data.child = await scalar('select id from public.children where family_id=$1', [data.family]);
  await scalar("select public.set_parent_pin($1,'2468')", [data.family]); await authorize();
  data.reviewChild = await scalar("select public.create_child($1,'Review child',2::smallint)", [data.family]);
  data.completed = await task(data.child, 'Historical completed task');
  data.pending = await task(data.child, 'Historical queued task');
  data.completionKey = `upgrade:${randomUUID()}`;
  await scalar('select public.start_task($1)', [data.completed]);
  await scalar('select public.complete_task($1,$2)', [data.completed, data.completionKey]);
  assert.deepEqual(await wallet(data.child), {coins: 25, frozen: 0, xp: 20});
  await capture('families', 'id=$1', [data.family]);
  await capture('children', 'family_id=$1', [data.family]);
  await capture('task_instances', 'child_id=$1', [data.child]);
  await capture('ledger_entries', 'source_id=$1', [data.completed]);
}
async function seedReview() {
  await authorize();
  data.math = await scalar('select public.save_review_question($1,$2)', [data.reviewChild,
    {kind: 'question', subject: 'math', prompt: '2 + 2 = ?', answers: ['4'], explanation: '相加'}]);
  data.pinyin = await scalar('select public.save_review_question($1,$2)', [data.reviewChild,
    {kind: 'pinyin', subject: 'chinese', prompt: '重庆', answers: ['chóng qìng'], context: '重庆是一座城市。', pronunciation_confirmed: true}]);
  data.review = await scalar('select public.generate_daily_wrong_review_task($1)', [data.reviewChild]);
  await scalar('select public.start_task($1)', [data.review]);
  data.answerCommand = randomUUID();
  await scalar('select public.submit_review_answer($1,$2,$3,$4)', [data.review, data.math, '4', data.answerCommand]);
  assert.equal(await scalar("select count(*)::int from public.task_review_items where task_instance_id=$1 and result=true", [data.review]), 1);
  await capture('wrong_questions', 'child_id=$1', [data.reviewChild]);
  await capture('wrong_question_answers', 'question_id=any($1::uuid[])', [[data.math, data.pinyin]]);
  await capture('task_review_items', 'task_instance_id=$1', [data.review]);
  await capture('task_review_answer_keys', 'task_id=$1', [data.review]);
}
async function seedEconomy() {
  await authorize(); data.adjustment = randomUUID();
  await scalar('select public.adjust_wallet($1,200,0,$2,$3)', [data.child, 'Historical adjustment', data.adjustment]);
  data.reward = await scalar('select public.save_reward($1,$2)', [data.family, {title: 'Family reading', cost: 100, rules: '周末一起阅读'}]);
  data.redemptionCommand = randomUUID();
  const version = await scalar('select version from public.rewards where id=$1', [data.reward]);
  data.redemption = await scalar('select public.request_reward($1,$2,$3,$4)', [data.child, data.reward, data.redemptionCommand, version]);
  await scalar("select public.transition_redemption($1,'approve','Historical approval')", [data.redemption]);
  assert.deepEqual(await wallet(data.child), {coins: 125, frozen: 100, xp: 20});
  await capture('rewards', 'id=$1', [data.reward]);
  await capture('redemptions', 'id=$1', [data.redemption]);
  await capture('wallets', 'child_id=any($1::uuid[])', [[data.child, data.reviewChild]]);
  await capture('ledger_entries', 'child_id=$1', [data.child]);
}
async function seedWorksheet() {
  await authorize(); data.worksheet = randomUUID();
  await scalar('select public.request_worksheet($1,$2,$3,$4)', [data.reviewChild, [data.pinyin, data.math],
    {title: 'Historical worksheet', include_questions: true, include_answers: false, include_explanations: true}, data.worksheet]);
  assert.equal(await scalar('select renderer_version from public.worksheet_jobs where id=$1', [data.worksheet]), 'a4-v1');
  await capture('worksheet_jobs', 'id=$1', [data.worksheet]);
  await capture('worksheet_items', 'worksheet_id=$1', [data.worksheet]);
  await capture('audit_logs', 'family_id=$1', [data.family]);
}
async function seedOffline() {
  await authorize();
  const snapshot = await scalar('select public.task_sync_snapshot($1)', [data.child]);
  const pending = snapshot.tasks.find(row => row.id === data.pending);
  data.start = {command_id: randomUUID(), task_id: pending.id, kind: 'start', lease_id: snapshot.lease_id,
    expected_version: pending.sync_version, predecessor_id: null, occurred_at: await scalar('select clock_timestamp()::text')};
  data.finish = {...data.start, command_id: randomUUID(), kind: 'complete', predecessor_id: data.start.command_id,
    occurred_at: await scalar('select clock_timestamp()::text')};
  await capture('task_sync_leases', 'id=$1', [snapshot.lease_id]);
  assert.equal(pending.status, 'ready');
}
const checkpoints = new Map([
  ['202609160008_task_maintenance.sql', ['008: old family, children, completed/pending tasks and ledger', seedCore]],
  ['202609160011_wrong_question_pinyin_review.sql', ['011: partially answered frozen review with private answer keys', seedReview]],
  ['202609170013_wallet_redemptions.sql', ['013: approved redemption, frozen balance and adjustment audit', seedEconomy]],
  ['202609170017_worksheet_dispatch.sql', ['017: queued v1 worksheet with frozen mixed question order', seedWorksheet]],
  ['202611040030_durable_image_uploads.sql', ['030: pre-upgrade offline lease and unsent command IDs', seedOffline]],
]);

try {
  database = await startTestDatabase({port: await freePort(),
    users: [{id: owner, email: 'upgrade@example.test'}, {id: outsider, email: 'outsider@example.test'}],
    onMigration: async (name, context) => {
      client = context.client;
      report.migrations.push({name, sha256: createHash('sha256').update(await readFile(`supabase/migrations/${name}`)).digest('hex')});
      const checkpoint = checkpoints.get(name);
      if (!checkpoint) return;
      try {
        await check(checkpoint[0], checkpoint[1]);
        report.checkpoints.push({name, appliedMigrations: report.migrations.length});
      } finally { await clearIdentity(); }
    },
  });
  assert.equal(report.checkpoints.length, checkpoints.size);
  report.serverVersion = database.serverVersion;
  await check('all captured historical fields survive the complete ordered upgrade', async () => {
    await clearIdentity();
    let compared = 0;
    for (const snapshot of saved) {
      const current = (await client.query(`select to_jsonb(t) as row from public.${snapshot.table} t where ${snapshot.condition}`, snapshot.parameters)).rows.map(row => row.row);
      const fields = Object.keys(snapshot.rows[0]).sort();
      const canonical = row => JSON.stringify(Object.fromEntries(fields.map(key => [key, row[key]])));
      assert.deepEqual(current.map(canonical).sort(), snapshot.rows.map(canonical).sort(), `Historical ${snapshot.table} changed`);
      compared += current.length;
    }
    report.historicalRowComparisons = compared;
    report.historicalTables = [...new Set(saved.map(snapshot => snapshot.table))].sort();
    await authorize();
  });
  await check('replaying a task completed before migration 009 adds no reward', async () => {
    const before = await wallet(data.child);
    const ledger = (await client.query('select id from public.ledger_entries where child_id=$1 order by id', [data.child])).rows;
    await scalar('select public.complete_task($1,$2)', [data.completed, data.completionKey]);
    await scalar('select public.complete_task($1,$2)', [data.completed, randomUUID()]);
    assert.deepEqual(await wallet(data.child), before);
    assert.deepEqual((await client.query('select id from public.ledger_entries where child_id=$1 order by id', [data.child])).rows, ledger);
  });
  await check('pre-upgrade offline commands and lease still settle exactly once', async () => {
    for (const command of [data.start, data.finish]) {
      assert.equal((await scalar('select public.apply_task_command($1)', [command])).outcome, 'applied');
    }
    const confirmed = await wallet(data.child);
    assert.deepEqual(confirmed, {coins: 150, frozen: 100, xp: 40});
    for (const command of [data.start, data.finish]) await scalar('select public.apply_task_command($1)', [command]);
    assert.deepEqual(await wallet(data.child), confirmed);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1', [data.pending]), 2);
  });
  await check('legacy review preserves answers, receipts and its original reward/completion rules', async () => {
    const task = await scalar('select to_jsonb(t) from public.task_instances t where id=$1', [data.review]);
    assert.equal(task.review_reward_policy, 1); assert.equal(task.review_auto_complete, false);
    assert.equal(await scalar('select answer_confidence from public.task_review_items where task_instance_id=$1 and wrong_question_id=$2', [data.review, data.math]), null);
    const before = await scalar('select to_jsonb(w) from public.wrong_questions w where id=$1', [data.math]);
    await scalar('select public.submit_review_answer($1,$2,$3,$4)', [data.review, data.math, '4', data.answerCommand]);
    assert.deepEqual(await scalar('select to_jsonb(w) from public.wrong_questions w where id=$1', [data.math]), before);
    await scalar('select public.submit_review_answer($1,$2,$3,$4,3::smallint)', [data.review, data.pinyin, 'chong2 qing4', randomUUID()]);
    assert.equal(await scalar('select status::text from public.task_instances where id=$1', [data.review]), 'in_progress');
    assert.deepEqual(await wallet(data.reviewChild), {coins: 0, frozen: 0, xp: 0});
    await scalar('select public.complete_task($1,$2)', [data.review, randomUUID()]);
    assert.deepEqual(await wallet(data.reviewChild), {coins: 10, frozen: 0, xp: 10});
    await scalar('select public.complete_task($1,$2)', [data.review, randomUUID()]);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1', [data.review]), 2);
  });
  await check('approved legacy redemption fulfills without refreezing or duplicate spending', async () => {
    await authorize();
    await scalar("select public.transition_redemption($1,'fulfill','Upgrade verified')", [data.redemption]);
    await scalar("select public.transition_redemption($1,'fulfill','Upgrade verified')", [data.redemption]);
    assert.deepEqual(await wallet(data.child), {coins: 150, frozen: 0, xp: 40});
    assert.equal(await scalar("select count(*)::int from public.ledger_entries where source_id=$1 and source_type='redemption_spend'", [data.redemption]), 1);
    for (const child of [data.child, data.reviewChild]) await scalar('select public.reconcile_wallet($1)', [child]);
  });
  await check('historical queued PDF upgrades renderer on claim without changing its frozen contents', async () => {
    const before = await scalar('select to_jsonb(j) from public.worksheet_jobs j where id=$1', [data.worksheet]);
    assert.equal(before.renderer_version, 'a4-v1');
    const claim = await scalar('select public.claim_worksheet($1)', [data.worksheet]);
    assert.equal(claim.status, 'claimed');
    assert.deepEqual(claim.snapshot.items.map(row => row.question_id), [data.pinyin, data.math]);
    assert.deepEqual(claim.snapshot.config, before.config);
    assert.deepEqual(claim.snapshot.items.map(row => row.accepted_answers), [['chóng qìng'], ['4']]);
    const after = await scalar('select to_jsonb(j) from public.worksheet_jobs j where id=$1', [data.worksheet]);
    assert.equal(after.renderer_version, 'a4-v2'); assert.equal(after.pdf_path, before.pdf_path);
    assert.equal(after.expires_at, before.expires_at);
  });
  await check('original adjustment actor/time/reason are readable through the new PIN-protected API', async () => {
    const id = await scalar("select id from public.ledger_entries where source_id=$1 and asset_type='coin'", [data.adjustment]);
    const details = await scalar('select public.wallet_adjustment_details($1,$2)', [data.child, id]);
    assert.equal(details.audit.reason, 'Historical adjustment');
    assert.equal(details.audit.actor.is_self, true); assert.ok(details.audit.created_at);
    await login(owner, randomUUID());
    await assert.rejects(client.query('select public.wallet_adjustment_details($1,$2)', [data.child, id]));
    await authorize();
  });
  await check('new reviews after upgrade use stage rewards, confidence and automatic completion', async () => {
    const child = await scalar("select public.create_child($1,'New child',2::smallint)", [data.family]);
    const question = await scalar('select public.save_review_question($1,$2)', [child,
      {kind: 'question', subject: 'math', prompt: '3 + 3 = ?', answers: ['6']}]);
    const review = await scalar('select public.generate_daily_wrong_review_task($1)', [child]);
    const row = await scalar('select to_jsonb(t) from public.task_instances t where id=$1', [review]);
    assert.equal(row.review_reward_policy, 2); assert.equal(row.review_auto_complete, true);
    await scalar('select public.start_task($1)', [review]);
    await scalar('select public.submit_review_answer($1,$2,$3,$4,2::smallint)', [review, question, '6', randomUUID()]);
    assert.equal(await scalar('select status::text from public.task_instances where id=$1', [review]), 'completed');
    assert.deepEqual(await wallet(child), {coins: 15, frozen: 0, xp: 15});
  });
  await check('unrelated account cannot read or operate upgraded historical family data', async () => {
    await login(outsider);
    for (const table of ['children', 'task_instances', 'wrong_questions', 'wallets', 'ledger_entries', 'redemptions', 'worksheet_jobs']) {
      assert.equal(await scalar(`select count(*)::int from public.${table}`), 0, table);
    }
    await assert.rejects(client.query('select public.task_sync_snapshot($1)', [data.child]));
    await assert.rejects(client.query('select public.claim_worksheet($1)', [data.worksheet]));
  });
  report.status = 'validated';
} catch (error) {
  report.status = 'failed'; report.failure = error.code ?? error.name;
  throw error;
} finally {
  try { if (database) { await database.client.end(); await database.postgres.stop(); report.databaseStopped = true; } }
  catch (error) { report.status = 'cleanup_failed'; report.failure = error.code ?? error.name; throw error; }
  finally { await saveReport(); }
}
report.passed = true; report.status = 'complete'; await saveReport();
console.log(`Database upgrade passed: ${report.checks.length} checks; ${report.checkpoints.length} populated checkpoints; ${report.migrations.length} migrations.`);
