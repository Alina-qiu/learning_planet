// Disposable PostgreSQL only. This never connects to a linked Supabase project.
import {startTestDatabase} from './fixtures/database.mjs';
import pg from 'pg';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { reportCases } from './test_report_cases.mjs';
import { growthCases } from './test_growth_cases.mjs';
import { exportCases } from './test_export_cases.mjs';
import { childDeletionCases } from './test_child_deletion_cases.mjs';
import { accountDeletionCases } from './test_account_deletion_cases.mjs';
import { taskPreferencesCases } from './test_task_preferences_cases.mjs';
import { rewardInventoryCases } from './test_reward_inventory_cases.mjs';
import { onboardingCases } from './test_onboarding_cases.mjs';
import { pinyinImportCases } from './test_pinyin_import_cases.mjs';
import { offlineReviewCases } from './test_offline_review_cases.mjs';
import { imageUploadCases } from './test_image_upload_cases.mjs';
import { familyCreationCases } from './test_family_creation_cases.mjs';
import { aiAnalysisCases } from './test_ai_analysis_cases.mjs';
import { monthlyReportCases } from './test_monthly_report_cases.mjs';
import { similarQuestionCases } from './test_similar_question_cases.mjs';
import { errorReasonCases } from './test_error_reason_cases.mjs';
import { aiReportCases } from './test_ai_report_cases.mjs';
import { runtimeDiagnosticsCases } from './test_runtime_diagnostics_cases.mjs';
import { parentNotificationCases } from './test_parent_notification_cases.mjs';
import { businessMetricsCases } from './test_business_metrics_cases.mjs';
import { childMediaDeletionCases } from './test_child_media_deletion_cases.mjs';
import { taskStartMetricsCases } from './test_task_start_metrics_cases.mjs';
import { familyRetentionCases } from './test_family_retention_cases.mjs';
import { configurationTimeCases } from './test_configuration_time_cases.mjs';
import { parentPushCases } from './test_parent_push_cases.mjs';
import { taskReminderPolicyCases } from './test_task_reminder_policy_cases.mjs';
import { reviewSnoozeCases } from './test_review_snooze_cases.mjs';
import { familyInvitationCases } from './test_family_invitation_cases.mjs';
import { familyMemberRemovalCases } from './test_family_member_removal_cases.mjs';
import { economyCommandCases } from './test_economy_command_cases.mjs';
import { familyOverviewCases } from './test_family_overview_cases.mjs';
import { scheduleSnapshotCases } from './test_schedule_snapshot_cases.mjs';
import { taskNoteCases } from './test_task_note_cases.mjs';
import { growthSnapshotCases } from './test_growth_snapshot_cases.mjs';
import { economyPageCases } from './test_economy_page_cases.mjs';
import { taskTimeCorrectionCases } from './test_task_time_correction_cases.mjs';
import { childQuestionSubmissionCases } from './test_child_question_submission_cases.mjs';
import { ocrFieldCases } from './test_ocr_field_cases.mjs';
import { questionCatalogCases } from './test_question_catalog_cases.mjs';
import { reviewMilestoneCases } from './test_review_milestone_cases.mjs';
import { reviewAutoCompletionCases } from './test_review_auto_completion_cases.mjs';
import { reviewConfidenceCases } from './test_review_confidence_cases.mjs';
import { familyTimezoneCases } from './test_family_timezone_cases.mjs';
import { worksheetVersionCases } from './test_worksheet_version_cases.mjs';
import { walletAdjustmentDetailsCases } from './test_wallet_adjustment_details_cases.mjs';
import { RENDERER_VERSION } from '../supabase/functions/_shared/worksheet_pdf.mjs';

let postgres;
let client;
let passed = 0;
async function check(name, test) {
  await test(); passed++; console.log('PASS ' + name);
}
const uid = '10000000-0000-0000-0000-000000000001';
const otherUid = '10000000-0000-0000-0000-000000000002';
async function login(user = uid, session = 'session-a') {
  await client.query('reset role');
  await client.query("select set_config('request.jwt.claims',$1,false)", [JSON.stringify({
    sub: user, role: 'authenticated', session_id: session,
    email: user === uid ? 'parent@example.test' : 'other@example.test',
    iat: Math.floor(Date.now() / 1000),
  })]);
  await client.query('set role authenticated');
}
async function scalar(sql, args = []) { return Object.values((await client.query(sql, args)).rows[0])[0]; }
async function denied(sql, args = []) { await assert.rejects(client.query(sql, args)); }
try {
  ({client, postgres} = await startTestDatabase({
    port: 54339,
    users: [{id: uid, email: 'parent@example.test'}, {id: otherUid, email: 'other@example.test'}],
    onMigration: name => console.log('MIGRATED ' + name),
  }));
  await check('fixture rejects invalid passwords on peer connections', async () => {
    const peer = new pg.Client({...client.connectionParameters, password: 'invalid-fixture-password'});
    try { await assert.rejects(peer.connect(), {code: '28P01'}); }
    finally { await peer.end(); }
  });
  await login();
  await client.query("select public.onboard_family('test','Asia/Shanghai','child',1::smallint)");
  const family = await scalar('select id from public.families limit 1');
  const child = await scalar('select id from public.children limit 1');
  await check('write RPC denied before PIN elevation', () =>
    denied("select public.create_child($1,'blocked',1::smallint)", [family]));
  await client.query("select public.set_parent_pin($1,'1234')", [family]);
  await check('initial PIN setup does not implicitly elevate', async () =>
    assert.equal(await scalar('select public.has_parent_authorization($1)', [family]), false));
  await client.query("select public.verify_parent_pin($1,'1234')", [family]);
  await check('PIN establishes a server authorization', async () =>
    assert.equal(await scalar('select public.has_parent_authorization($1)', [family]), true));
  await check('authorization does not carry to another session', async () => {
    await login(uid, 'session-b');
    assert.equal(await scalar('select public.has_parent_authorization($1)', [family]), false);
    await denied("select public.set_parent_pin($1,'9999')", [family]);
    await login();
  });
  const today = await scalar('select public.family_today($1)', [child]);
  // Legacy scenarios share one child/day; the cap has separate fresh-child tests.
  await client.query('select public.set_daily_coin_limit($1,10000)',[child]);
  const config = {
    title: 'Daily task', recurrence: 'daily', starts_on: today, ends_on: today,
    start_time: '16:00', due_time: '20:00', coins: 20, xp: 30, minimum_seconds: 60,
  };
  const template = await scalar('select public.save_task_schedule($1,$2)', [child, config]);
  const task = await scalar('select id from public.task_instances where template_id=$1', [template]);
  await check('generation is idempotent', async () => {
    await client.query('select public.generate_scheduled_tasks($1)', [child]);
    assert.equal(await scalar('select count(*)::int from public.task_instances where template_id=$1', [template]), 1);
  });
  await check('cannot generate arbitrary historical dates', () =>
    denied("select public.generate_scheduled_tasks($1,'2000-01-01')", [child]));
  await check('direct template writes cannot bypass validation', () =>
    denied("insert into public.task_templates(child_id,title) values($1,'raw')", [child]));
  await check('updating a template preserves existing snapshots', async () => {
    await client.query('select public.save_task_schedule($1,$2,$3)', [child, {...config, title: 'Changed', coins: 900}, template]);
    const row = (await client.query('select title,coin_reward from public.task_instances where id=$1', [task])).rows[0];
    assert.equal(row.title, 'Daily task'); assert.equal(row.coin_reward, 20);
  });
  await client.query('select public.start_task($1)', [task]);
  await check('minimum effective time enforced on server', () =>
    denied("select public.complete_task($1,'attempt')", [task]));
  await client.query("select public.complete_task($1,'manual','test approved')", [task]);
  await check('duplicate completion never pays twice', async () => {
    await client.query("select public.complete_task($1,'different')", [task]);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1', [child]), 20);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1', [task]), 2);
  });
  await check('expired elevation blocks parent writes', async () => {
    await client.query('reset role');
    await client.query("update public.parent_authorizations set expires_at=now()-interval '1 second'");
    await login(); await denied("select public.create_child($1,'expired',1::smallint)", [family]);
    await client.query("select public.verify_parent_pin($1,'1234')", [family]);
  });
  await check('another family cannot use this authorization', async () => {
    await login(otherUid);
    assert.equal(await scalar('select count(*)::int from public.children'), 0);
    await denied('select public.save_task_schedule($1,$2)', [child, config]);
    await login();
  });
  await check('revocation blocks both RPC and parent RLS', async () => {
    await client.query('select public.revoke_parent_authorization()');
    await denied("select public.create_child($1,'revoked',1::smallint)", [family]);
    await denied("insert into public.reminder_settings(child_id) values($1)", [child]);
    assert.equal(await scalar('select count(*)::int from public.audit_logs'), 0);
    assert.equal(await scalar('select count(*)::int from public.family_invitations'), 0);
  });
  await client.query("select public.verify_parent_pin($1,'1234')", [family]);
  const datePlus = (day, days) => new Date(Date.parse(day + 'T00:00:00Z') + days * 86400000).toISOString().slice(0, 10);
  await check('invalid weekly/custom schedules are atomic', async () => {
    const before = await scalar('select count(*)::int from public.task_templates');
    await denied('select public.save_task_schedule($1,$2)', [child, {...config, recurrence: 'weekly', rule: {weekdays: []}}]);
    await denied('select public.save_task_schedule($1,$2)', [child, {...config, recurrence: 'custom', rule: {dates: ['2000-01-01']}}]);
    assert.equal(await scalar('select count(*)::int from public.task_templates'), before);
  });
  const nextDay = datePlus(today, 1);
  await check('future reminders do not create future reward instances', async () => {
    for (const title of ['Future A', 'Future B']) {
      await client.query('select public.save_task_schedule($1,$2)', [child,
        {...config, title, recurrence: 'once', starts_on: nextDay, ends_on: nextDay}]);
    }
    assert.equal(await scalar('select count(*)::int from public.task_instances where due_date>$1', [today]), 0);
    const rows = (await client.query('select * from public.load_task_reminders($1)', [child])).rows;
    assert.equal(rows.length, 3);
    assert.ok(rows.every(row => row.titles.includes('Future A') && row.titles.includes('Future B')));
    assert.ok(rows.every(row => row.remind_local.includes('Asia/Shanghai')));
  });
  await check('quiet hours, disable, and acknowledgement filter reminders', async () => {
    await client.query("insert into public.reminder_settings values($1,true,'14:00','08:00')", [child]);
    assert.equal((await client.query('select * from public.load_task_reminders($1)', [child])).rows.length, 0);
    await client.query("update public.reminder_settings set quiet_start='00:00',quiet_end='00:00' where child_id=$1", [child]);
    const reminder = (await client.query('select * from public.load_task_reminders($1)', [child])).rows[0];
    await client.query('insert into public.reminder_receipts(child_id,reminder_key) values($1,$2)', [child, reminder.reminder_key]);
    assert.equal((await client.query('select * from public.load_task_reminders($1)', [child])).rows.length, 2);
    await client.query('update public.reminder_settings set enabled=false where child_id=$1', [child]);
    assert.equal((await client.query('select * from public.load_task_reminders($1)', [child])).rows.length, 0);
  });
  const planTemplate = await scalar('select public.save_task_schedule($1,$2)', [child, {
    ...config, title: 'Plan', ends_on: datePlus(today, 2), minimum_seconds: 0,
    coins: 1, xp: 1, long_plan: true, minimum_rate: .5, bonus_coins: 100, bonus_xp: 100,
    stages: [{completed_count: 1, coins: 7, xp: 9}, {completed_count: 2, coins: 11, xp: 13}],
    tiers: [{minimum_rate: 1, coins: 250, xp: 300}],
  }]);
  const plan = await scalar('select id from public.long_plans where template_id=$1', [planTemplate]);
  const planTask = await scalar('select id from public.task_instances where template_id=$1', [planTemplate]);
  await check('plan denominator includes missing instances, excludes approved leave', async () => {
    assert.equal((await client.query('select * from public.long_plan_progress($1)', [plan])).rows[0].expected, 3);
    await client.query("select public.approve_plan_leave($1,$2,'approved rest')", [plan, datePlus(today, 2)]);
    assert.equal((await client.query('select * from public.long_plan_progress($1)', [plan])).rows[0].expected, 2);
    await denied('select public.save_task_schedule($1,$2,$3)', [child, config, planTemplate]);
    await denied('select public.set_schedule_active($1,false)', [planTemplate]);
    await denied('select public.settle_long_plan($1)', [plan]);
  });
  await check('stage rewards issue once when completion threshold is reached', async () => {
    await client.query("select public.complete_task($1,'plan-first','approved')", [planTask]);
    await client.query("select public.complete_task($1,'plan-repeat')", [planTask]);
    assert.equal(await scalar("select sum(amount)::int from public.ledger_entries where source_id=$1 and source_type='plan_stage' and asset_type='coin'", [plan]), 7);
  });
  await check('terminal settlement pays only the highest tier exactly once', async () => {
    // Simulate the end of a three-day plan using isolated fixture updates only.
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims',$1,false)", [JSON.stringify({role: 'service_role'})]);
    await client.query('set role service_role');
    await client.query('select public.generate_scheduled_tasks($1,$2)', [child, nextDay]);
    await login();
    const second = await scalar('select id from public.task_instances where template_id=$1 and due_date=$2', [planTemplate, nextDay]);
    await client.query("select public.complete_task($1,'plan-second','approved')", [second]);
    await client.query('reset role');
    await client.query('update public.task_instances set due_date=due_date-10 where template_id=$1', [planTemplate]);
    await client.query('update public.task_templates set starts_on=starts_on-10,ends_on=ends_on-10 where id=$1', [planTemplate]);
    await client.query('update public.plan_leaves set leave_date=leave_date-10 where plan_id=$1', [plan]);
    await login();
    assert.equal(Number(await scalar('select public.settle_long_plan($1)', [plan])), 1);
    await client.query('select public.settle_long_plan($1)', [plan]);
    assert.equal(await scalar("select sum(amount)::int from public.ledger_entries where source_id=$1 and source_type='plan_completion' and asset_type='coin'", [plan]), 250);
    assert.equal(await scalar("select count(*)::int from public.ledger_entries where source_id=$1 and source_type='plan_completion'", [plan]), 2);
    assert.equal(await scalar("select sum(amount)::int from public.ledger_entries where source_id=$1 and source_type='plan_stage' and asset_type='coin'", [plan]), 18);
  });
  // Explicitly authorized parent permissions: manual completion, not arbitrary minting.
  const parentTemplate = await scalar('select public.save_task_schedule($1,$2)', [child,
    {...config, title: 'Parent approval', recurrence: 'once', coins: 5, xp: 6}]);
  const parentTask = await scalar('select id from public.task_instances where template_id=$1', [parentTemplate]);
  await client.query('reset role');
  await client.query("insert into public.family_members(family_id,user_id,role) values($1,$2,'parent')", [family, otherUid]);
  await login(otherUid, 'parent-session');
  await check('ordinary parent manual completion requires PIN', () =>
    denied("select public.complete_task($1,'parent-no-pin','approved')", [parentTask]));
  await client.query("select public.verify_parent_pin($1,'1234')", [family]);
  await check('PIN parent can manually complete and issue snapshot rewards once', async () => {
    assert.equal(await scalar('select public.is_family_admin($1)', [family]), false);
    const before = (await client.query('select coin_balance,xp from public.wallets where child_id=$1', [child])).rows[0];
    await denied("select public.complete_task($1,'blank','   ')", [parentTask]);
    await client.query("select public.complete_task($1,'parent-approved','parent approved')", [parentTask]);
    await client.query("select public.complete_task($1,'parent-repeat','parent approved')", [parentTask]);
    const after = (await client.query('select coin_balance,xp from public.wallets where child_id=$1', [child])).rows[0];
    assert.equal(after.coin_balance, before.coin_balance + 5);
    assert.equal(after.xp, before.xp + 6);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1', [parentTask]), 2);
    assert.equal(await scalar("select count(*)::int from public.audit_logs where target_id=$1 and actor_user_id=$2 and details->>'reason'='parent approved'", [parentTask, otherUid]), 1);
  });
  await check('parent reward permission does not grant administrator or wallet writes', async () => {
    await denied("select public.set_parent_pin($1,'9999')", [family]);
    await denied("select public.create_child($1,'not-admin',1::smallint)", [family]);
    await denied("select public.complete_task_internal($1,'bypass','approved')", [parentTask]);
    await denied('update public.wallets set coin_balance=999999 where child_id=$1', [child]);
    await denied("insert into public.ledger_entries(child_id,asset_type,amount,source_type,idempotency_key) values($1,'coin',999999,'task_completion','mint')", [child]);
  });
  await check('parent manual authorization is session scoped and revocable', async () => {
    await login(otherUid, 'different-session');
    await denied("select public.complete_task($1,'wrong-session','approved')", [parentTask]);
    await login(otherUid, 'parent-session');
    await client.query('select public.revoke_parent_authorization($1)', [family]);
    await denied("select public.complete_task($1,'revoked','approved')", [parentTask]);
    await client.query("select public.verify_parent_pin($1,'1234')", [family]);
    await client.query('reset role');
    await client.query("update public.parent_authorizations set expires_at=now()-interval '1 second' where user_id=$1", [otherUid]);
    await login(otherUid, 'parent-session');
    await denied("select public.complete_task($1,'expired','approved')", [parentTask]);
    await login();
  });
  await check('concurrent completion pays only one reward', async () => {
    const tid = await scalar('select public.save_task_schedule($1,$2)', [child,
      {...config, title: 'Concurrent', recurrence: 'once', minimum_seconds: 0, coins: 3, xp: 4}]);
    const taskId = await scalar('select id from public.task_instances where template_id=$1', [tid]);
    await client.query('select public.start_task($1)', [taskId]);
    const before = await scalar('select coin_balance from public.wallets where child_id=$1', [child]);
    const secondClient = new pg.Client(client.connectionParameters);
    await secondClient.connect();
    try {
      const claims = await scalar("select current_setting('request.jwt.claims')");
      await secondClient.query("select set_config('request.jwt.claims',$1,false)", [claims]);
      await secondClient.query('set role authenticated');
      await Promise.all([
        client.query("select public.complete_task($1,'parallel-a')", [taskId]),
        secondClient.query("select public.complete_task($1,'parallel-b')", [taskId]),
      ]);
    } finally { await secondClient.end(); }
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1', [child]), before+3);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1', [taskId]), 2);
  });
  await check('leave approval and manual completion cannot both succeed', async () => {
    const tid = await scalar('select public.save_task_schedule($1,$2)', [child, {
      ...config, title: 'Leave race', ends_on: datePlus(today, 1), minimum_seconds: 0,
      coins: 1, xp: 1, long_plan: true, minimum_rate: .8, bonus_coins: 100, bonus_xp: 100,
    }]);
    const pid = await scalar('select id from public.long_plans where template_id=$1', [tid]);
    const taskId = await scalar('select id from public.task_instances where template_id=$1', [tid]);
    const before = await scalar('select coin_balance from public.wallets where child_id=$1', [child]);
    const secondClient = new pg.Client(client.connectionParameters);
    await secondClient.connect();
    let results;
    try {
      const claims = await scalar("select current_setting('request.jwt.claims')");
      await secondClient.query("select set_config('request.jwt.claims',$1,false)", [claims]);
      await secondClient.query('set role authenticated');
      results = await Promise.allSettled([
        client.query("select public.approve_plan_leave($1,$2,'approved')", [pid, today]),
        secondClient.query("select public.complete_task($1,'leave-race','approved')", [taskId]),
      ]);
    } finally { await secondClient.end(); }
    assert.equal(results.filter(r => r.status==='fulfilled').length, 1);
    const status = await scalar('select status from public.task_instances where id=$1', [taskId]);
    const leaveCount = await scalar('select count(*)::int from public.plan_leaves where plan_id=$1', [pid]);
    assert.equal(leaveCount, status==='skipped' ? 1 : 0);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1', [child]),
      before + (status==='completed' ? 1 : 0));
  });
  async function offlineFixture(title, minimum = 0) {
    const templateId = await scalar('select public.save_task_schedule($1,$2)', [child,
      {...config, title, recurrence: 'once', coins: 8, xp: 9, minimum_seconds: minimum}]);
    const snapshot = await scalar('select public.task_sync_snapshot($1)', [child]);
    const row = snapshot.tasks.find(t => t.template_id === templateId);
    return {snapshot, row};
  }
  function offlineCommand(fixture, kind, predecessor = null, at = fixture.snapshot.server_at) {
    return {command_id: randomUUID(), task_id: fixture.row.id, kind,
      lease_id: fixture.snapshot.lease_id, expected_version: fixture.row.sync_version,
      predecessor_id: predecessor?.command_id ?? null, occurred_at: at};
  }
  const applyOffline = command => scalar('select public.apply_task_command($1)', [command]);
  await check('offline replay counts active intervals but not pauses and rewards once', async () => {
    let fixture = await offlineFixture('Offline intervals', 60);
    await client.query('reset role');
    await client.query("update public.task_sync_leases set issued_at=now()-interval '5 minutes' where id=$1", [fixture.snapshot.lease_id]);
    await client.query("update public.task_instances set created_at=now()-interval '5 minutes' where id=$1", [fixture.row.id]);
    await login();
    fixture.snapshot = await scalar('select public.task_sync_snapshot($1)', [child]);
    fixture.row = fixture.snapshot.tasks.find(t => t.id === fixture.row.id);
    const at = seconds => new Date(Date.parse(fixture.snapshot.server_at) - seconds*1000).toISOString();
    const start = offlineCommand(fixture, 'start', null, at(120));
    const pause = offlineCommand(fixture, 'pause', start, at(100));
    const resume = offlineCommand(fixture, 'resume', pause, at(80));
    const short = offlineCommand(fixture, 'complete', resume, at(70));
    const complete = offlineCommand(fixture, 'complete', resume, at(20));
    const before = await scalar('select coin_balance from public.wallets where child_id=$1', [child]);
    for (const command of [start, pause, resume]) assert.equal((await applyOffline(command)).outcome, 'applied');
    assert.equal((await applyOffline(short)).outcome, 'conflict');
    assert.equal(await scalar('select accumulated_seconds from public.task_instances where id=$1', [fixture.row.id]), 20);
    const result = await applyOffline(complete);
    assert.equal(result.outcome, 'applied'); assert.equal(result.task.accumulated_seconds, 80);
    await applyOffline(complete); // Server committed but client lost its acknowledgement.
    assert.equal((await applyOffline(offlineCommand(fixture, 'complete', resume, at(20)))).outcome, 'already_completed');
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1', [child]), before+8);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1', [fixture.row.id]), 2);
    await denied('select public.apply_task_command($1)', [{...complete, occurred_at: at(19)}]);
  });
  await check('offline task version detects another-device changes without overwriting', async () => {
    const fixture = await offlineFixture('Offline conflict');
    await client.query('select public.start_task($1)', [fixture.row.id]);
    const result = await applyOffline(offlineCommand(fixture, 'start'));
    assert.equal(result.outcome, 'conflict'); assert.equal(result.task.status, 'in_progress');
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1', [fixture.row.id]), 0);
  });
  await check('offline replay rejects future, pre-lease, missing predecessor and expired clocks', async () => {
    const fixture = await offlineFixture('Offline clock');
    const command = offlineCommand(fixture, 'start');
    assert.equal((await applyOffline({...command, occurred_at: new Date(Date.now()+86400000).toISOString()})).outcome, 'conflict');
    assert.equal((await applyOffline({...command, occurred_at: '2000-01-01T00:00:00Z'})).outcome, 'conflict');
    assert.equal((await applyOffline({...command, predecessor_id: randomUUID()})).outcome, 'conflict');
    await client.query('reset role');
    await client.query("update public.task_sync_leases set expires_at=now()-interval '1 second' where id=$1", [fixture.snapshot.lease_id]);
    await login();
    assert.equal((await applyOffline(command)).outcome, 'conflict');
    assert.equal(await scalar('select status from public.task_instances where id=$1', [fixture.row.id]), 'ready');
  });
  await check('offline commands cannot bypass account, PIN, wallet or private receipt boundaries', async () => {
    const fixture = await offlineFixture('Offline boundaries');
    const command = offlineCommand(fixture, 'start');
    await denied('select public.apply_task_command($1)', [{...command, parent_reason: 'fake PIN'}]);
    await denied('select public.apply_task_command($1)', [{...command, coins: 999999}]);
    await denied('select * from public.task_sync_leases');
    await denied('select * from public.task_command_receipts');
    await denied("select public.task_command_result($1,'applied')", [fixture.row.id]);
    await login(otherUid, 'parent-session');
    assert.equal((await applyOffline(command)).outcome, 'conflict'); // Lease belongs to original account.
    const outsider = '10000000-0000-0000-0000-000000000003';
    await client.query('reset role');
    await client.query('insert into auth.users(id,email) values($1,$2)', [outsider, 'outsider@example.test']);
    await login(outsider);
    await denied('select public.task_sync_snapshot($1)', [child]);
    await denied('select public.apply_task_command($1)', [command]);
    await login();
  });
  await check('offline replay merges completed tasks but rejects approved skips', async () => {
    const fixture = await offlineFixture('Offline terminal');
    const command = offlineCommand(fixture, 'start');
    await client.query("select public.complete_task($1,'other-device','approved')", [fixture.row.id]);
    const before = await scalar('select coin_balance from public.wallets where child_id=$1', [child]);
    assert.equal((await applyOffline(command)).outcome, 'already_completed');
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1', [child]), before);
    const skipped = await offlineFixture('Offline skip');
    await client.query('reset role');
    await client.query("update public.task_instances set status='skipped' where id=$1", [skipped.row.id]);
    await login();
    assert.equal((await applyOffline(offlineCommand(skipped, 'start'))).outcome, 'conflict');
  });
  await check('concurrent offline UUID retries produce a single receipt and reward', async () => {
    const fixture = await offlineFixture('Offline retry race');
    const start = offlineCommand(fixture, 'start');
    assert.equal((await applyOffline(start)).outcome, 'applied');
    const complete = offlineCommand(fixture, 'complete', start);
    const secondClient = new pg.Client(client.connectionParameters);
    await secondClient.connect();
    try {
      await secondClient.query("select set_config('request.jwt.claims',$1,false)", [await scalar("select current_setting('request.jwt.claims')")]);
      await secondClient.query('set role authenticated');
      const before = await scalar('select coin_balance from public.wallets where child_id=$1', [child]);
      await Promise.all([applyOffline(complete), secondClient.query('select public.apply_task_command($1)', [complete])]);
      assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1', [child]), before+8);
      await client.query('reset role');
      assert.equal(await scalar('select count(*)::int from public.task_command_receipts where command_id=$1', [complete.command_id]), 1);
      await login();
    } finally { await secondClient.end(); }
  });
  await check('offline long-plan completion preserves stage rewards and settled-plan boundaries', async () => {
    const templateId = await scalar('select public.save_task_schedule($1,$2)', [child, {
      ...config, title: 'Offline stages', ends_on: datePlus(today, 1), minimum_seconds: 0,
      coins: 2, xp: 3, long_plan: true, minimum_rate: .8, bonus_coins: 100, bonus_xp: 100,
      stages: [{completed_count: 1, coins: 7, xp: 9}],
    }]);
    const snapshot = await scalar('select public.task_sync_snapshot($1)', [child]);
    const fixture = {snapshot, row: snapshot.tasks.find(t => t.template_id === templateId)};
    const pid = await scalar('select id from public.long_plans where template_id=$1', [templateId]);
    const before = await scalar('select coin_balance from public.wallets where child_id=$1', [child]);
    const start = offlineCommand(fixture, 'start');
    const complete = offlineCommand(fixture, 'complete', start);
    await applyOffline(start); await applyOffline(complete); await applyOffline(complete);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1', [child]), before+9);
    assert.equal(await scalar("select sum(amount)::int from public.ledger_entries where source_id=$1 and source_type='plan_stage' and asset_type='coin'", [pid]), 7);
    const closedTemplate = await scalar('select public.save_task_schedule($1,$2)', [child, {
      ...config, title: 'Already settled offline', ends_on: datePlus(today, 1), minimum_seconds: 0,
      long_plan: true, minimum_rate: .8, bonus_coins: 100, bonus_xp: 100,
    }]);
    const closedSnapshot = await scalar('select public.task_sync_snapshot($1)', [child]);
    const closed = {snapshot: closedSnapshot, row: closedSnapshot.tasks.find(t => t.template_id === closedTemplate)};
    await client.query('reset role');
    await client.query('update public.long_plans set settled_at=now() where template_id=$1', [closedTemplate]);
    await login();
    assert.equal((await applyOffline(offlineCommand(closed, 'start'))).outcome, 'conflict');
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1', [closed.row.id]), 0);
  });
  const reviewChild = await scalar("select public.create_child($1,'review child',1::smallint)", [family]);
  const reviewIds = [];
  const reviewConfigs = [];
  await check('no due questions means no automatic review task', async () => {
    assert.equal(await scalar('select public.generate_daily_wrong_review_task($1)', [reviewChild]), null);
  });
  for (let i=0; i<12; i++) {
    const pinyin = [1,2,4].includes(i);
    const configuration = {kind: pinyin ? 'pinyin' : 'question', subject: pinyin ? 'chinese' : 'math',
      prompt: i===0 ? '2+2' : i===1 ? '银行' : i===2 ? '绿色' : i===4 ? '好' : '错题'+i,
      answers: [i===0 ? '4' : i===1 ? 'yín háng' : i===2 ? 'lǜ sè' : i===4 ? 'hǎo' : String(i)],
      context: pinyin ? '请根据词语在本例句中的意思读音' : '', pronunciation_confirmed: pinyin,
      explanation: '家长确认的解析', knowledge_point: '回归测试'};
    reviewConfigs.push(configuration);
    reviewIds.push(await scalar('select public.save_review_question($1,$2)', [reviewChild, configuration]));
  }
  await check('pinyin keys require context and explicit parent confirmation', async () => {
    await denied('select public.save_review_question($1,$2)', [reviewChild, {...reviewConfigs[1], pronunciation_confirmed: false}]);
    await denied('select public.save_review_question($1,$2)', [reviewChild, {...reviewConfigs[1], context: ''}]);
    await denied('select public.save_review_question($1,$2)', [reviewChild, {...reviewConfigs[1], answers: ['ma2 ma4!']}]);
  });
  await client.query('reset role');
  // These grading cases need questions 0–7 in the frozen ten-item task. PRD
  // ordering now compares family days, not creation milliseconds; use explicit
  // error counts so random UUID ties cannot drop a required grading fixture.
  await client.query('update public.wrong_questions w set wrong_count=20-q.ordinality::integer from unnest($1::uuid[]) with ordinality as q(id,ordinality) where w.id=q.id', [reviewIds.slice(0,10)]);
  await client.query('update public.wrong_questions set review_due_at=$1::timestamptz,wrong_count=case when id=$2::uuid then 2 else 5 end where id=any($3::uuid[])',
    [datePlus(today,-2)+'T00:00:00Z',reviewIds[10],[reviewIds[10],reviewIds[11]]]);
  await login();
  const reviewTask = await scalar('select public.generate_daily_wrong_review_task($1,null,100)', [reviewChild]);
  await check('automatic review is sorted, capped at ten and frozen across retries', async () => {
    for (let i=0;i<3;i++) assert.equal(await scalar('select public.generate_daily_wrong_review_task($1)', [reviewChild]), reviewTask);
    const payload = await scalar('select public.load_review_task($1)', [reviewTask]);
    assert.equal(payload.items.length, 10);
    assert.equal(payload.items[0].wrong_question_id, reviewIds[11]);
    assert.equal(payload.items[1].wrong_question_id, reviewIds[10]);
    assert.ok(payload.items.every(item => item.accepted_answers===null && item.explanation===null));
    assert.equal((await scalar('select public.review_overview($1)', [reviewChild])).backlog, 2);
    await denied("select public.generate_daily_wrong_review_task($1,'2000-01-01')", [reviewChild]);
  });
  await check('review answer keys and mastery cannot be read or directly changed by clients', async () => {
    await denied('select * from public.wrong_question_answers');
    await denied('select * from public.task_review_answer_keys');
    await denied("update public.wrong_questions set mastery_status='mastered' where id=$1", [reviewIds[0]]);
    await denied('update public.task_review_items set result=true where task_instance_id=$1', [reviewTask]);
    await client.query('select public.revoke_parent_authorization($1)', [family]);
    await denied('select public.review_question_editor($1)', [reviewIds[0]]);
    await denied('select public.save_review_question($1,$2)', [reviewChild, reviewConfigs[0]]);
    await client.query("select public.verify_parent_pin($1,'1234')", [family]);
    await login('10000000-0000-0000-0000-000000000003');
    await denied('select public.load_review_task($1)', [reviewTask]);
    await denied('select public.review_overview($1)', [reviewChild]);
    await login();
  });
  await check('automatic review cannot finish or use PIN manual completion before all answers', async () => {
    await denied("select public.complete_task($1,'early')", [reviewTask]);
    await denied("select public.complete_task($1,'manual','PIN cannot skip answers')", [reviewTask]);
    await denied('select public.submit_review_answer($1,$2,$3,$4)', [reviewTask, reviewIds[0], '4', randomUUID()]);
  });
  await client.query('select public.start_task($1)', [reviewTask]);
  await check('started snapshots keep original prompt and keys after edits and new entries', async () => {
    await scalar('select public.save_review_question($1,$2)', [reviewChild, {...reviewConfigs[0], prompt: '新增题'}]);
    await scalar('select public.save_review_question($1,$2,$3)', [reviewChild, {...reviewConfigs[0], prompt: '已编辑新版本', answers: ['99']}, reviewIds[0]]);
    await scalar('select public.generate_daily_wrong_review_task($1)', [reviewChild]);
    const payload = await scalar('select public.load_review_task($1)', [reviewTask]);
    assert.equal(payload.items.length, 10);
    assert.equal(payload.items.find(item => item.wrong_question_id===reviewIds[0]).prompt, '2+2');
    assert.equal((await scalar('select public.review_overview($1)', [reviewChild])).backlog, 4);
  });
  await check('paused review cannot submit until resumed', async () => {
    await client.query('select public.pause_task($1)', [reviewTask]);
    await denied('select public.submit_review_answer($1,$2,$3,$4)', [reviewTask, reviewIds[1], 'yin2 hang2', randomUUID()]);
    await client.query('select public.resume_task($1)', [reviewTask]);
  });
  await check('server grades numeric/marked pinyin and ü aliases without accepting wrong tones', async () => {
    for (const [index, answer, expected] of [[1,'yin2 hang2',true],[2,'lv4 se4',true],[4,'hao2',false]]) {
      const result = await scalar('select public.submit_review_answer($1,$2,$3,$4)', [reviewTask, reviewIds[index], answer, randomUUID()]);
      const item = result.items.find(item => item.wrong_question_id===reviewIds[index]);
      assert.equal(item.result, expected); assert.ok(item.accepted_answers.length>0);
    }
    const previous = await scalar('select review_attempts from public.wrong_questions where id=$1', [reviewIds[1]]);
    await scalar('select public.submit_review_answer($1,$2,$3,$4)', [reviewTask, reviewIds[1], 'yin2 hang2', randomUUID()]);
    assert.equal(await scalar('select review_attempts from public.wrong_questions where id=$1', [reviewIds[1]]), previous);
    await denied('select public.submit_review_answer($1,$2,$3,$4)', [reviewTask, reviewIds[1], 'yin1 hang2', randomUUID()]);
  });
  await check('review settlement uses actual results and pays once; stale snapshots do not advance edits', async () => {
    const payload = await scalar('select public.load_review_task($1)', [reviewTask]);
    const before = (await client.query('select coin_balance,xp from public.wallets where child_id=$1', [reviewChild])).rows[0];
    for (const item of payload.items.filter(item => item.result===null)) {
      const index = reviewIds.indexOf(item.wrong_question_id);
      await scalar('select public.submit_review_answer($1,$2,$3,$4)', [reviewTask, item.wrong_question_id,
        index===0 ? '4' : index===3 ? 'bad' : String(index), randomUUID()]);
    }
    assert.equal(await scalar('select review_attempts from public.wrong_questions where id=$1', [reviewIds[0]]), 0);
    assert.equal((await scalar('select public.load_review_task($1)',[reviewTask])).task.status,'completed');
    await client.query("select public.complete_task($1,'finish-review')", [reviewTask]);
    await client.query("select public.complete_task($1,'repeat-review')", [reviewTask]);
    const after = (await client.query('select coin_balance,xp from public.wallets where child_id=$1', [reviewChild])).rows[0];
    // Seven current-version corrections qualify; the edited old snapshot and
    // two incorrect answers do not earn a milestone.
    assert.equal(after.coin_balance, before.coin_balance+105); assert.equal(after.xp, before.xp+105);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1', [reviewTask]), 2);
  });
  await check('review schedule follows 1/3/7/30 family days, mastery and wrong-answer reset', async () => {
    for (const [step,correct,days] of [[0,true,1],[1,true,3],[2,true,7],[3,true,30],[4,true,null],[3,false,1]]) {
      const cid = await scalar("select public.create_child($1,'schedule test',1::smallint)", [family]);
      const qid = await scalar('select public.save_review_question($1,$2)', [cid, reviewConfigs[0]]);
      await client.query('reset role'); await client.query('update public.wrong_questions set review_step=$1 where id=$2', [step,qid]);
      await login(); const tid = await scalar('select public.generate_daily_wrong_review_task($1)', [cid]);
      await client.query('select public.start_task($1)', [tid]);
      await scalar('select public.submit_review_answer($1,$2,$3,$4)', [tid,qid,correct?'4':'0',randomUUID()]);
      const row = (await client.query('select review_step,mastery_status,review_due_at from public.wrong_questions where id=$1', [qid])).rows[0];
      if (days===null) { assert.equal(row.mastery_status,'mastered'); assert.equal(row.review_due_at,null); }
      else {
        assert.equal(row.review_step,correct?step+1:0);
        const next = await scalar("select (review_due_at at time zone 'Asia/Shanghai')::date::text from public.wrong_questions where id=$1", [qid]);
        assert.equal(next,datePlus(today,days));
      }
    }
  });
  await check('pinyin handles uppercase accented, decomposed Unicode and joined numeric syllables', async () => {
    for (const answer of ['YÍN HÁNG','yi\u0301n ha\u0301ng','yin2hang2']) {
      const cid = await scalar("select public.create_child($1,'unicode review',1::smallint)", [family]);
      const qid = await scalar('select public.save_review_question($1,$2)', [cid,reviewConfigs[1]]);
      const tid = await scalar('select public.generate_daily_wrong_review_task($1)', [cid]);
      await client.query('select public.start_task($1)', [tid]);
      const result = await scalar('select public.submit_review_answer($1,$2,$3,$4)', [tid,qid,answer,randomUUID()]);
      assert.equal(result.items[0].result,true);
    }
  });
  await check('review scheduler is trusted-only and restores JWT context', async () => {
    await denied('select public.run_review_maintenance()');
    await client.query('reset role');
    const claims = JSON.stringify({role:'service_role',marker:'review-must-restore'});
    await client.query("select set_config('request.jwt.claims',$1,false)",[claims]);
    await client.query('set role service_role');
    await scalar('select public.run_review_maintenance()');
    assert.equal(await scalar("select current_setting('request.jwt.claims')"),claims);
    await login();
  });
  const ocrDraftId = randomUUID();
  let ocrDraft, ocrQuestion;
  const ocrConfig = {kind:'question',subject:'math',prompt:'校对题目：2+2=?',answers:['4'],knowledge_point:'加法',error_reason:'计算粗心'};
  await check('OCR drafts require current-session PIN and immutable owner scope', async () => {
    await client.query('select public.revoke_parent_authorization()');
    await denied('select public.begin_question_ocr($1,$2)', [child,ocrDraftId]);
    await client.query("select public.verify_parent_pin($1,'1234')",[family]);
    ocrDraft = await scalar('select public.begin_question_ocr($1,$2)',[child,ocrDraftId]);
    assert.equal((await scalar('select public.begin_question_ocr($1,$2)',[child,ocrDraftId])).id,ocrDraftId);
    await login(uid,'other-ocr-session');
    await denied('select public.begin_question_ocr($1,$2)',[child,ocrDraftId]);
    assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where id=$1',[ocrDraftId]),0);
    await login();
  });
  await check('private image storage rejects arbitrary paths, overwrites and missing media', async () => {
    await client.query('reset role');
    assert.equal(await scalar("select public from storage.buckets where id='wrong-question-images'"),false);
    await login();
    await denied("insert into storage.objects(bucket_id,name) values('wrong-question-images','arbitrary.jpg')");
    await denied('select public.record_question_ocr($1,$2)',[ocrDraftId,{text:'raw OCR 2+Z'}]);
    await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1),('wrong-question-images',$2)",[ocrDraft.original_path,ocrDraft.processed_path]);
    assert.equal((await client.query("update storage.objects set name='overwritten.jpg' where name=$1",[ocrDraft.original_path])).rowCount,0);
    assert.equal((await client.query("delete from storage.objects where name=$1",[ocrDraft.original_path])).rowCount,0);
  });
  await check('OCR raw text is an immutable client suggestion, never a mastery command', async () => {
    await denied('select public.record_question_ocr($1,$2)',[ocrDraftId,{text:''}]);
    await client.query('select public.record_question_ocr($1,$2)',[ocrDraftId,{text:'raw OCR 2+Z',lines:[{text:'2+Z',confidence:null}],mastery_status:'mastered'}]);
    await denied('select public.record_question_ocr($1,$2)',[ocrDraftId,{text:'replace evidence'}]);
    await denied("update public.question_ocr_drafts set raw_text='forged' where id=$1",[ocrDraftId]);
    await denied('select public.save_review_question_before_ocr($1,$2,null)',[child,ocrConfig]);
  });
  await check('OCR correction requires explicit confirmation and save retries never duplicate', async () => {
    await denied('select public.save_review_question($1,$2)',[child,{...ocrConfig,ocr_draft_id:ocrDraftId}]);
    const configuration={...ocrConfig,ocr_draft_id:ocrDraftId,ocr_confirmed:true};
    ocrQuestion=await scalar('select public.save_review_question($1,$2)',[child,configuration]);
    assert.equal(await scalar('select public.save_review_question($1,$2)',[child,configuration]),ocrQuestion);
    const row=(await client.query('select final_text,mastery_status,error_reason from public.wrong_questions where id=$1',[ocrQuestion])).rows[0];
    assert.equal(row.final_text,ocrConfig.prompt); assert.equal(row.mastery_status,'unmastered');
    assert.equal(row.error_reason,'计算粗心');
    const provenance=await scalar('select to_jsonb(d) from public.question_ocr_drafts d where id=$1',[ocrDraftId]);
    assert.equal(provenance.raw_text,'raw OCR 2+Z');
    assert.equal(provenance.raw_result.source,'on_device_client_suggestion');
    assert.equal(await scalar("select count(*)::int from public.audit_logs where action='review.ocr_confirm' and target_id=$1",[ocrQuestion]),1);
  });
  await check('another family cannot read OCR provenance or images or attach a draft', async () => {
    await login('10000000-0000-0000-0000-000000000003');
    assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where id=$1',[ocrDraftId]),0);
    assert.equal(await scalar('select count(*)::int from storage.objects where name=$1',[ocrDraft.original_path]),0);
    await denied('select public.begin_question_ocr($1,$2)',[child,ocrDraftId]);
    await login();
    await denied('select public.save_review_question($1,$2)',[reviewChild,{...ocrConfig,ocr_draft_id:ocrDraftId,ocr_confirmed:true}]);
  });
  await check('PIN ordinary parent can manage own OCR but cannot steal another parent draft', async () => {
    await login(otherUid);
    await client.query("select public.verify_parent_pin($1,'1234')",[family]);
    await denied('select public.begin_question_ocr($1,$2)',[child,ocrDraftId]);
    const id=randomUUID();
    const draft=await scalar('select public.begin_question_ocr($1,$2)',[child,id]);
    await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1),('wrong-question-images',$2)",[draft.original_path,draft.processed_path]);
    await client.query('select public.manual_question_ocr($1)',[id]);
    await scalar('select public.save_review_question($1,$2)',[child,{...ocrConfig,ocr_draft_id:id,ocr_confirmed:true}]);
    await login();
  });
  await check('stale edits are rejected while original OCR evidence survives corrections', async () => {
    const version=await scalar('select content_version from public.wrong_questions where id=$1',[ocrQuestion]);
    await scalar('select public.save_review_question($1,$2,$3)',[child,{...ocrConfig,prompt:'修改后的题目',expected_version:version},ocrQuestion]);
    await denied('select public.save_review_question($1,$2,$3)',[child,{...ocrConfig,expected_version:version},ocrQuestion]);
    assert.equal(await scalar('select raw_text from public.question_ocr_drafts where id=$1',[ocrDraftId]),'raw OCR 2+Z');
  });
  await check('batch archive is atomic, child scoped and reversible without rewards or mastery changes', async () => {
    const balance=await scalar('select coin_balance from public.wallets where child_id=$1',[child]);
    await denied('select public.archive_review_questions($1,$2,true)',[child,[ocrQuestion,reviewIds[0]]]);
    assert.equal(await scalar('select archived from public.wrong_questions where id=$1',[ocrQuestion]),false);
    await client.query('select public.archive_review_questions($1,$2,true)',[child,[ocrQuestion]]);
    assert.equal(await scalar('select archived from public.wrong_questions where id=$1',[ocrQuestion]),true);
    await client.query('select public.archive_review_questions($1,$2,false)',[child,[ocrQuestion]]);
    assert.equal(await scalar('select archived from public.wrong_questions where id=$1',[ocrQuestion]),false);
    assert.equal(await scalar('select mastery_status from public.wrong_questions where id=$1',[ocrQuestion]),'unmastered');
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[child]),balance);
    await denied('select public.archive_review_questions($1,$2,true)',[child,[]]);
  });
  await check('revoked PIN blocks media insertion, OCR recording and bulk mutation', async () => {
    const id=randomUUID();
    const draft=await scalar('select public.begin_question_ocr($1,$2)',[child,id]);
    await client.query('select public.revoke_parent_authorization()');
    await denied("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1)",[draft.original_path]);
    await denied('select public.record_question_ocr($1,$2)',[id,{text:'raw'}]);
    await denied('select public.archive_review_questions($1,$2,true)',[child,[ocrQuestion]]);
    await client.query("select public.verify_parent_pin($1,'1234')",[family]);
  });
  const economyChild=await scalar("select public.create_child($1,'economy',1::smallint)",[family]);
  const eventConfig={title:'cap award',recurrence:'once',starts_on:today,ends_on:today,start_time:'08:00',due_time:'20:00',coins:200,xp:250,minimum_seconds:0};
  const economyTemplate=await scalar('select public.save_task_schedule($1,$2)',[economyChild,eventConfig]);
  const economyTask=await scalar('select id from public.task_instances where template_id=$1',[economyTemplate]);
  let pendingAward;
  await check('daily cap pays normal XP and moves excess coins into PIN approval exactly once',async()=>{
    await client.query("select public.complete_task($1,'cap-complete','verified')",[economyTask]);
    await client.query("select public.complete_task($1,'cap-complete-again','verified')",[economyTask]);
    const overview=await scalar('select public.wallet_overview($1)',[economyChild]);
    assert.equal(overview.coin_balance,150);assert.equal(overview.xp,250);assert.equal(Number(overview.pending_coins),50);
    assert.equal(overview.reconciled,true);
    pendingAward=await scalar('select id from public.pending_coin_awards where child_id=$1',[economyChild]);
    await client.query('select public.revoke_parent_authorization()');
    await denied("select public.decide_pending_coins($1,true,'confirmed')",[pendingAward]);
    await client.query("select public.verify_parent_pin($1,'1234')",[family]);
    await client.query("select public.decide_pending_coins($1,true,'confirmed')",[pendingAward]);
    await client.query("select public.decide_pending_coins($1,true,'retry')",[pendingAward]);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[economyChild]),200);
    assert.equal(await scalar("select count(*)::int from public.ledger_entries where source_type='coin_approval' and child_id=$1",[economyChild]),1);
  });
  await check('XP thresholds reach level50 at122500 and XP deductions are denied',async()=>{
    for(const [xp,level]of [[0,1],[99,1],[100,2],[299,2],[300,3],[122499,49],[122500,50],[1000000,50]])
      assert.equal(await scalar('select public.xp_level($1)',[xp]),level);
    await denied("select public.adjust_wallet($1,0,-1,'no', $2)",[economyChild,randomUUID()]);
  });
  await check('manual adjustments are PIN protected, reasoned, capped and replay safe',async()=>{
    const key=randomUUID();
    await denied("select public.adjust_wallet($1,501,0,'large',$2)",[economyChild,key]);
    await denied("select public.adjust_wallet($1,1,0,'',$2)",[economyChild,key]);
    await client.query("select public.adjust_wallet($1,501,100,'large confirmed',$2,true)",[economyChild,key]);
    await client.query("select public.adjust_wallet($1,501,100,'lost response',$2,true)",[economyChild,key]);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[economyChild]),701);
    await denied("select public.adjust_wallet($1,500,100,'changed',$2,true)",[economyChild,key]);
    await denied("select public.adjust_wallet($1,-9999,0,'overdraw',$2,true)",[economyChild,randomUUID()]);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[economyChild]),701);
    await denied('update public.ledger_entries set amount=0 where child_id=$1',[economyChild]);
    await denied('delete from public.ledger_entries where child_id=$1',[economyChild]);
  });
  const rewardConfig={title:'family movie',cost:120,rules:'weekend only',request_days:7,fulfillment_days:30};
  const reward=await scalar('select public.save_reward($1,$2)',[family,rewardConfig]);
  let redemption;
  await check('request freezes available coins with price rules snapshot and UUID retries pay once',async()=>{
    const key=randomUUID();
    redemption=await scalar('select public.request_reward($1,$2,$3,1)',[economyChild,reward,key]);
    assert.equal(await scalar('select public.request_reward($1,$2,$3,1)',[economyChild,reward,key]),redemption);
    const row=(await client.query('select coin_balance,frozen_balance from public.wallets where child_id=$1',[economyChild])).rows[0];
    assert.equal(row.coin_balance,581);assert.equal(row.frozen_balance,120);
    await scalar('select public.save_reward($1,$2,$3)',[family,{...rewardConfig,cost:250,rules:'new price'},reward]);
    const snapshot=(await client.query('select frozen_amount,reward_rules from public.redemptions where id=$1',[redemption])).rows[0];
    assert.equal(snapshot.frozen_amount,120);assert.equal(snapshot.reward_rules,'weekend only');
    await denied('select public.request_reward($1,$2,$3,1)',[economyChild,reward,randomUUID()]);
  });
  await check('approval retains freeze and fulfillment consumes only frozen coins once without XP loss',async()=>{
    await denied("select public.transition_redemption($1,'fulfill','done')",[redemption]);
    await client.query('select public.revoke_parent_authorization()');
    await denied("select public.transition_redemption($1,'approve','checked')",[redemption]);
    await client.query("select public.verify_parent_pin($1,'1234')",[family]);
    await client.query("select public.transition_redemption($1,'approve','checked')",[redemption]);
    await denied("select public.transition_redemption($1,'cancel')",[redemption]);
    await client.query("select public.transition_redemption($1,'fulfill','delivered')",[redemption]);
    await client.query("select public.transition_redemption($1,'fulfill','retry')",[redemption]);
    const row=await scalar('select public.wallet_overview($1)',[economyChild]);
    assert.equal(row.coin_balance,581);assert.equal(row.frozen_balance,0);assert.equal(row.xp,350);assert.equal(row.reconciled,true);
  });
  await check('rejection and child cancellation return the full frozen snapshot once',async()=>{
    for(const operation of ['reject','cancel']){
      const id=await scalar('select public.request_reward($1,$2,$3,2)',[economyChild,reward,randomUUID()]);
      await client.query('select public.transition_redemption($1,$2,$3)',[id,operation,'return']);
      await client.query('select public.transition_redemption($1,$2,$3)',[id,operation,'retry']);
      assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[economyChild]),581);
      assert.equal(await scalar('select frozen_balance from public.wallets where child_id=$1',[economyChild]),0);
    }
  });
  await check('server expiry refunds pending and approved claims and trusted maintenance restores JWT',async()=>{
    const ids=[];
    for(const approved of [false,true]){
      const id=await scalar('select public.request_reward($1,$2,$3,2)',[economyChild,reward,randomUUID()]);ids.push(id);
      if(approved)await client.query("select public.transition_redemption($1,'approve','ready')",[id]);
    }
    await denied('select public.run_reward_maintenance()');
    await client.query('reset role');
    await client.query("update public.redemptions set expires_at=now()-interval '1 second' where id=any($1)",[ids]);
    const claims=JSON.stringify({role:'service_role',marker:'reward-must-restore'});
    await client.query("select set_config('request.jwt.claims',$1,false)",[claims]);await client.query('set role service_role');
    assert.equal(await scalar('select public.run_reward_maintenance()'),2);
    assert.equal(await scalar('select public.run_reward_maintenance()'),0);
    assert.equal(await scalar("select current_setting('request.jwt.claims')"),claims);
    await login();assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[economyChild]),581);
    assert.equal(await scalar('select frozen_balance from public.wallets where child_id=$1',[economyChild]),0);
  });
  await check('reward availability level gates and cross-family access cannot be bypassed',async()=>{
    const locked=await scalar('select public.save_reward($1,$2)',[family,{...rewardConfig,minimum_level:50}]);
    await denied('select public.request_reward($1,$2,$3,1)',[economyChild,locked,randomUUID()]);
    const unavailable=await scalar('select public.save_reward($1,$2)',[family,{...rewardConfig,active:false}]);
    await denied('select public.request_reward($1,$2,$3,1)',[economyChild,unavailable,randomUUID()]);
    await login('10000000-0000-0000-0000-000000000003');
    await denied('select public.wallet_overview($1)',[economyChild]);await denied('select public.request_reward($1,$2,$3,2)',[economyChild,reward,randomUUID()]);
    await denied('select public.save_reward($1,$2)',[family,rewardConfig]);await login();
  });
  await check('wallet mismatch is detectable and authorized reconciliation uses append-only ledger totals',async()=>{
    await client.query('reset role');await client.query('update public.wallets set coin_balance=999 where child_id=$1',[economyChild]);await login();
    assert.equal((await scalar('select public.wallet_overview($1)',[economyChild])).reconciled,false);
    await client.query('select public.reconcile_wallet($1)',[economyChild]);
    const row=await scalar('select public.wallet_overview($1)',[economyChild]);assert.equal(row.reconciled,true);assert.equal(row.coin_balance,581);
  });
  await check('concurrent reward requests cannot overspend and identical UUID freezes only once',async()=>{
    const raceChild=await scalar("select public.create_child($1,'redemption race',1::smallint)",[family]);
    await client.query("select public.adjust_wallet($1,300,0,'race funding',$2)",[raceChild,randomUUID()]);
    const raceReward=await scalar('select public.save_reward($1,$2)',[family,{...rewardConfig,cost:200}]);
    const peer=new pg.Client(client.connectionParameters);await peer.connect();
    try{
      const claims=await scalar("select current_setting('request.jwt.claims')");
      await peer.query("select set_config('request.jwt.claims',$1,false)",[claims]);await peer.query('set role authenticated');
      const results=await Promise.allSettled([
        client.query('select public.request_reward($1,$2,$3,1)',[raceChild,raceReward,randomUUID()]),
        peer.query('select public.request_reward($1,$2,$3,1)',[raceChild,raceReward,randomUUID()])]);
      assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
      assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[raceChild]),100);
      assert.equal(await scalar('select frozen_balance from public.wallets where child_id=$1',[raceChild]),200);
      const id=await scalar('select id from public.redemptions where child_id=$1',[raceChild]);
      await client.query("select public.transition_redemption($1,'cancel')",[id]);
      const key=randomUUID();const duplicates=await Promise.all([
        client.query('select public.request_reward($1,$2,$3,1)',[raceChild,raceReward,key]),
        peer.query('select public.request_reward($1,$2,$3,1)',[raceChild,raceReward,key])]);
      assert.equal(Object.values(duplicates[0].rows[0])[0],Object.values(duplicates[1].rows[0])[0]);
      assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[raceChild]),100);
      assert.equal((await scalar('select public.wallet_overview($1)',[raceChild])).reconciled,true);
    }finally{await peer.end();}
  });
  await check('permanent cleanup requires scoped PIN confirmation and stable UUID', async () => {
    await client.query("select public.verify_parent_pin($1,'1234')",[family]);
    const q = await scalar('select public.save_review_question($1,$2)',[child,{kind:'question',subject:'math',prompt:'private deletion sample',answers:['42'],explanation:'private explanation'}]);
    const preview=await scalar('select public.preview_question_cleanup($1,\'questions\',$2)',[child,[q]]);
    assert.equal(preview.questions,1); assert.equal(preview.ledger_preserved,true);
    const key=randomUUID();
    await denied('select public.request_question_cleanup($1,\'questions\',$2,$3,\'yes\')',[child,[q],key]);
    await denied('select public.request_question_cleanup($1,\'questions\',$2,$3,\'永久删除\')',[economyChild,[q],key]);
    assert.equal(await scalar('select public.request_question_cleanup($1,\'questions\',$2,$3,\'永久删除\')',[child,[q],key]),key);
    assert.equal(await scalar('select public.request_question_cleanup($1,\'questions\',$2,$3,\'永久删除\')',[child,[q],key]),key);
    await denied('select public.save_review_question($1,$2,$3)',[child,{kind:'question',subject:'math',prompt:'cannot edit deleting',answers:['1']},q]);
    const claim=await scalar('select public.claim_cleanup_job($1)',[key]);
    assert.equal(claim.status,'claimed');
    assert.equal((await scalar('select public.claim_cleanup_job($1)',[key])).status,'running');
    await denied('select public.finish_cleanup_job($1,$2,null)',[key,claim.lease_token]);
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await client.query('set role service_role');
    await denied('select public.finish_cleanup_job($1,$2,null)',[key,randomUUID()]);
    await client.query('select public.finish_cleanup_job($1,$2,null)',[key,claim.lease_token]);
    assert.equal((await scalar('select public.claim_cleanup_job($1)',[key])).status,'completed');
    await login();
    assert.equal(await scalar('select count(*)::int from public.wrong_questions where id=$1',[q]),0);
    assert.equal((await scalar('select public.wallet_overview($1)',[child])).reconciled,true);
  });
  await check('original-only cleanup verifies media before commit and safely retries failure', async () => {
    await denied('select public.delete_child($1)',[child]);
    const key=randomUUID();
    const balance=await scalar('select coin_balance from public.wallets where child_id=$1',[child]);
    assert.equal((await scalar('select public.preview_question_cleanup($1,\'originals\',$2)',[child,[ocrQuestion]])).files,1);
    await client.query('select public.request_question_cleanup($1,\'originals\',$2,$3,\'永久删除\')',[child,[ocrQuestion],key]);
    await login('10000000-0000-0000-0000-000000000003');
    await denied('select public.claim_cleanup_job($1)',[key]);
    assert.equal(await scalar('select count(*)::int from public.cleanup_jobs where id=$1',[key]),0);
    await login();
    let claim=await scalar('select public.claim_cleanup_job($1)',[key]);
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await denied('select public.finish_cleanup_job($1,$2,null)',[key,claim.lease_token]);
    await client.query('select public.finish_cleanup_job($1,$2,\'STORAGE_REMOVE_FAILED\')',[key,claim.lease_token]);
    claim=await scalar('select public.claim_cleanup_job($1)',[key]);
    // Mock the Storage API effect only in this disposable harness. Production uses .remove().
    await client.query('delete from storage.objects where name=$1',[ocrDraft.original_path]);
    await client.query('select public.finish_cleanup_job($1,$2,null)',[key,claim.lease_token]);
    await login();
    assert.equal(await scalar('select count(*)::int from storage.objects where name=$1',[ocrDraft.processed_path]),1);
    assert.equal(await scalar('select count(*)::int from public.wrong_questions where id=$1',[ocrQuestion]),1);
    assert.equal((await scalar('select public.preview_question_cleanup($1,\'originals\',$2)',[child,[ocrQuestion]])).files,0);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[child]),balance);
  });
  await check('question purge redacts historical answers and skips unfinished review without rewriting ledger', async () => {
    await client.query('reset role');
    const done=await scalar("insert into public.task_instances(child_id,title,due_date,source_type,status,idempotency_key) values($1,'deletion history','2000-01-01','automatic_wrong_review','completed',$2) returning id",[child,randomUUID()]);
    const unfinished=await scalar("insert into public.task_instances(child_id,title,due_date,source_type,status,idempotency_key) values($1,'deletion unfinished','2000-01-02','automatic_wrong_review','in_progress',$2) returning id",[child,randomUUID()]);
    for(const taskId of [done,unfinished]) {
      await client.query('insert into public.task_review_items(task_instance_id,wrong_question_id,sequence,prompt,answer_text,result) values($1,$2,1,\'private prompt\',\'private answer\',true)',[taskId,ocrQuestion]);
      await client.query('insert into public.task_review_answer_keys(task_id,question_id,accepted_answers,explanation) values($1,$2,array[\'private answer\'],\'private explanation\')',[taskId,ocrQuestion]);
    }
    await login();
    const balance=await scalar('select coin_balance from public.wallets where child_id=$1',[child]);
    const key=randomUUID();
    const preview=await scalar('select public.preview_question_cleanup($1,\'questions\',$2)',[child,[ocrQuestion]]);
    assert.equal(preview.unfinished_reviews,1); assert.equal(preview.files,1);
    await client.query('select public.request_question_cleanup($1,\'questions\',$2,$3,\'永久删除\')',[child,[ocrQuestion],key]);
    assert.equal(await scalar('select status from public.task_instances where id=$1',[unfinished]),'skipped');
    const pendingSnapshot=await scalar('select public.load_review_task($1)',[done]);
    assert.equal(pendingSnapshot.items[0].prompt,null);
    assert.equal(pendingSnapshot.items[0].answer_text,null);
    assert.equal(pendingSnapshot.items[0].accepted_answers,null);
    assert.equal(pendingSnapshot.items[0].source_deleted,true);
    await denied('select public.complete_task($1,\'deleted-source\')',[unfinished]);
    const claim=await scalar('select public.claim_cleanup_job($1)',[key]);
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await denied('select public.finish_cleanup_job($1,$2,null)',[key,claim.lease_token]);
    await client.query('delete from storage.objects where name=$1',[ocrDraft.processed_path]);
    await client.query('select public.finish_cleanup_job($1,$2,null)',[key,claim.lease_token]);
    assert.equal(await scalar('select count(*)::int from public.task_review_answer_keys where question_id=$1',[ocrQuestion]),0);
    await login();
    assert.equal(await scalar('select count(*)::int from public.wrong_questions where id=$1',[ocrQuestion]),0);
    assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where id=$1',[ocrDraftId]),0);
    const history=await scalar('select public.load_review_task($1)',[done]);
    assert.equal(history.task.status,'completed'); assert.equal(history.items.length,1);
    assert.equal(history.items[0].source_deleted,true); assert.equal(history.items[0].result,true);
    assert.equal(history.items[0].prompt,null); assert.equal(history.items[0].answer_text,null);
    assert.equal(history.items[0].accepted_answers,null);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[child]),balance);
    assert.equal((await scalar('select public.wallet_overview($1)',[child])).reconciled,true);
  });
  await check('abandoned OCR cleanup only includes own old unsaved drafts and stops new uploads', async () => {
    const id=randomUUID(); const freshId=randomUUID();
    const draft=await scalar('select public.begin_question_ocr($1,$2)',[child,id]);
    await client.query('select public.begin_question_ocr($1,$2)',[child,freshId]);
    await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1)",[draft.original_path]);
    await client.query('reset role');
    await client.query("update public.question_ocr_drafts set created_at=now()-interval '2 days' where id=$1",[id]);
    await login();
    const preview=await scalar('select public.preview_question_cleanup($1,\'abandoned_ocr\')',[child]);
    assert.ok(preview.draft_ids.includes(id)); assert.ok(!preview.draft_ids.includes(freshId));
    const key=randomUUID();
    await client.query('select public.request_question_cleanup($1,\'abandoned_ocr\',array[]::uuid[],$2,\'永久删除\')',[child,key]);
    await denied("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1)",[draft.processed_path]);
    const claim=await scalar('select public.claim_cleanup_job($1)',[key]);
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    for(const file of claim.manifest) await client.query('delete from storage.objects where bucket_id=$1 and name=$2',[file.bucket,file.path]);
    await client.query('select public.finish_cleanup_job($1,$2,null)',[key,claim.lease_token]);
    await login();
    assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where id=$1',[id]),0);
    assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where id=$1',[freshId]),1);
  });
  await check('cleanup dispatcher is trusted-only and expired leases reject old workers', async () => {
    await denied('select public.pending_cleanup_jobs()');
    const q=await scalar('select public.save_review_question($1,$2)',[child,{kind:'question',subject:'math',prompt:'lease cleanup',answers:['1']}]);
    const key=randomUUID();
    await client.query('select public.request_question_cleanup($1,\'questions\',$2,$3,\'永久删除\')',[child,[q],key]);
    const first=await scalar('select public.claim_cleanup_job($1)',[key]);
    await client.query('reset role');
    await client.query("update public.cleanup_jobs set lease_until=now()-interval '1 second' where id=$1",[key]);
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await client.query('set role service_role');
    assert.ok((await scalar('select public.pending_cleanup_jobs()')).includes(key));
    await denied('select public.finish_cleanup_job($1,$2,null)',[key,first.lease_token]);
    const second=await scalar('select public.claim_cleanup_job($1)',[key]);
    assert.notEqual(second.lease_token,first.lease_token);
    await denied('select public.finish_cleanup_job($1,$2,null)',[key,first.lease_token]);
    await client.query('select public.finish_cleanup_job($1,$2,null)',[key,second.lease_token]);
    assert.ok(!(await scalar('select public.pending_cleanup_jobs()')).includes(key));
    await login();
  });
  let worksheet, worksheetClaim;
  const worksheetConfig={title:'Frozen worksheet',include_answers:true,include_explanations:true};
  const worksheetQ1=await scalar('select public.save_review_question($1,$2)',[child,{kind:'question',subject:'math',prompt:'worksheet old prompt',answers:['42'],explanation:'frozen explanation'}]);
  const worksheetQ2=await scalar('select public.save_review_question($1,$2)',[child,{kind:'pinyin',subject:'chinese',prompt:'银行',context:'去银行存钱',pronunciation_confirmed:true,answers:['yín háng'],explanation:'多音字'}]);
  await check('A4 request validates child scope configuration order and stable UUID without charges', async () => {
    const key=randomUUID();
    for(const invalid of [{margin_mm:11},{repeats:0},{include_questions:false,include_answers:false,include_explanations:false},{include_answers:'true'}])
      await denied('select public.request_worksheet($1,$2,$3,$4)',[child,[worksheetQ1],invalid,key]);
    await denied('select public.request_worksheet($1,$2,$3,$4)',[child,[worksheetQ1,worksheetQ1],{},key]);
    await denied('select public.request_worksheet($1,$2,$3,$4)',[economyChild,[worksheetQ1],{},key]);
    await denied('select public.request_worksheet($1,$2,$3,$4)',[child,[randomUUID()],{},key]);
    const balance=await scalar('select coin_balance from public.wallets where child_id=$1',[child]);
    worksheet=await scalar('select public.request_worksheet($1,$2,$3,$4)',[child,[worksheetQ2,worksheetQ1],worksheetConfig,key]);
    assert.equal(worksheet,key);
    assert.equal(await scalar('select public.request_worksheet($1,$2,$3,$4)',[child,[worksheetQ2,worksheetQ1],worksheetConfig,key]),key);
    await denied('select public.request_worksheet($1,$2,$3,$4)',[child,[worksheetQ1,worksheetQ2],worksheetConfig,key]);
    await denied('select public.request_worksheet($1,$2,$3,$4)',[child,[worksheetQ2,worksheetQ1],{...worksheetConfig,title:'Changed'},key]);
    const row=await scalar('select to_jsonb(j) from public.worksheet_jobs j where id=$1',[key]);
    assert.equal(row.config.margin_mm,12); assert.equal(row.config.orientation,'portrait');
    assert.equal(new Date(row.expires_at)-new Date(row.created_at),30*86400000);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[child]),balance);
    await denied('select * from public.worksheet_items');
    await denied('update public.worksheet_jobs set status=\'ready\' where id=$1',[key]);
  });
  await check('worksheet snapshot preserves old private answers and prompts after edits', async () => {
    await client.query('select public.save_review_question($1,$2,$3)',[child,{kind:'question',subject:'math',prompt:'edited live prompt',answers:['99'],explanation:'new explanation'},worksheetQ1]);
    worksheetClaim=await scalar('select public.claim_worksheet($1)',[worksheet]);
    assert.equal(worksheetClaim.status,'claimed');
    assert.equal(worksheetClaim.snapshot.items[0].question_id,worksheetQ2);
    assert.equal(worksheetClaim.snapshot.items[1].prompt,'worksheet old prompt');
    assert.deepEqual(worksheetClaim.snapshot.items[1].accepted_answers,['42']);
    assert.equal((await scalar('select public.claim_worksheet($1)',[worksheet])).status,'running');
    await denied('select public.update_worksheet_progress($1,$2,75)',[worksheet,worksheetClaim.lease_token]);
    await denied('select public.finish_worksheet($1,$2,$3)',[worksheet,worksheetClaim.lease_token,{}]);
    await denied("insert into storage.objects(bucket_id,name) values('worksheets',$1)",[worksheetClaim.pdf_path]);
  });
  await check('trusted PDF finish validates file metadata lease and identical acknowledgement replay', async () => {
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await client.query('set role service_role');
    await denied('select public.finish_worksheet($1,$2,$3)',[worksheet,worksheetClaim.lease_token,{}]);
    const result={pages:2,byte_size:6000000,sha256:'a'.repeat(64),renderer_version:RENDERER_VERSION};
    await denied('select public.finish_worksheet($1,$2,$3)',[worksheet,worksheetClaim.lease_token,result]);
    await denied('select public.update_worksheet_progress($1,$2,75)',[worksheet,randomUUID()]);
    await client.query('select public.update_worksheet_progress($1,$2,75)',[worksheet,worksheetClaim.lease_token]);
    await client.query('reset role');
    await client.query("insert into storage.objects(bucket_id,name) values('worksheets',$1)",[worksheetClaim.pdf_path]);
    await client.query('set role service_role');
    await client.query('select public.finish_worksheet($1,$2,$3)',[worksheet,worksheetClaim.lease_token,result]);
    await client.query('select public.finish_worksheet($1,$2,$3)',[worksheet,worksheetClaim.lease_token,result]);
    await denied('select public.finish_worksheet($1,$2,$3)',[worksheet,randomUUID(),result]);
    await login();
    const row=await scalar('select to_jsonb(j) from public.worksheet_jobs j where id=$1',[worksheet]);
    assert.equal(row.status,'ready'); assert.equal(row.progress,100); assert.equal(row.pages,2);
    assert.equal(await scalar('select count(*)::int from storage.objects where name=$1',[worksheetClaim.pdf_path]),1);
  });
  await check('worksheet PDFs and history require current-session PIN and block outsiders or expiry', async () => {
    await client.query('select public.revoke_parent_authorization($1)',[family]);
    assert.equal(await scalar('select count(*)::int from public.worksheet_jobs where id=$1',[worksheet]),0);
    assert.equal(await scalar('select count(*)::int from storage.objects where name=$1',[worksheetClaim.pdf_path]),0);
    await denied('select public.claim_worksheet($1)',[worksheet]);
    await login('10000000-0000-0000-0000-000000000003');
    await denied('select public.claim_worksheet($1)',[worksheet]);
    assert.equal(await scalar('select count(*)::int from public.worksheet_jobs where id=$1',[worksheet]),0);
    await login(); await client.query("select public.verify_parent_pin($1,'1234')",[family]);
    await client.query('reset role');
    await client.query("update public.worksheet_jobs set expires_at=now()-interval '1 second' where id=$1",[worksheet]);
    await login();
    await denied('select public.claim_worksheet($1)',[worksheet]);
    assert.equal(await scalar('select count(*)::int from storage.objects where name=$1',[worksheetClaim.pdf_path]),0);
  });
  await check('failed and expired PDF leases can retry without replacing snapshots or paying rewards', async () => {
    const id=await scalar('select public.request_worksheet($1,$2,$3,$4)',[child,[worksheetQ1],{},randomUUID()]);
    const first=await scalar('select public.claim_worksheet($1)',[id]);
    await client.query('reset role');
    await client.query("update public.worksheet_jobs set lease_until=now()-interval '1 second' where id=$1",[id]);
    await login();
    const second=await scalar('select public.claim_worksheet($1)',[id]);
    assert.notEqual(first.lease_token,second.lease_token);
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await client.query('set role service_role');
    await denied('select public.finish_worksheet($1,$2,$3)',[id,first.lease_token,{error_code:'STALE_WORKER'}]);
    await client.query('select public.finish_worksheet($1,$2,$3)',[id,second.lease_token,{error_code:'PDF_UPLOAD_FAILED'}]);
    await login();
    const third=await scalar('select public.claim_worksheet($1)',[id]);
    assert.equal(third.status,'claimed'); assert.equal(third.snapshot.items[0].prompt,'edited live prompt');
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[id]),0);
  });
  await check('PDF permanent deletion is PIN protected and requires real file removal before snapshot redaction', async () => {
    const key=randomUUID();
    await denied('select public.request_worksheet_cleanup($1,$2,$3)',[worksheet,key,'delete']);
    const cleanup=await scalar('select public.request_worksheet_cleanup($1,$2,$3)',[worksheet,key,'永久删除']);
    assert.equal(await scalar('select public.request_worksheet_cleanup($1,$2,$3)',[worksheet,key,'永久删除']),cleanup);
    const claim=await scalar('select public.claim_cleanup_job($1)',[cleanup]);
    assert.equal(claim.manifest[0].bucket,'worksheets');
    assert.equal(await scalar('select count(*)::int from storage.objects where name=$1',[worksheetClaim.pdf_path]),0);
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await client.query('set role service_role');
    await denied('select public.finish_cleanup_job($1,$2,null)',[cleanup,claim.lease_token]);
    await client.query('reset role');
    // Disposable harness simulates Storage API success; production never SQL-deletes Storage rows.
    await client.query('delete from storage.objects where name=$1',[worksheetClaim.pdf_path]);
    await client.query('set role service_role');
    await client.query('select public.finish_cleanup_job($1,$2,null)',[cleanup,claim.lease_token]);
    assert.equal(await scalar('select count(*)::int from public.worksheet_items where worksheet_id=$1',[worksheet]),0);
    const row=await scalar('select to_jsonb(j) from public.worksheet_jobs j where id=$1',[worksheet]);
    assert.equal(row.status,'deleted'); assert.deepEqual(row.config,{}); assert.equal(row.pdf_path,worksheetClaim.pdf_path);
    await login();
    await denied('select public.claim_worksheet($1)',[worksheet]);
  });
  await check('running PDF deletion waits beyond prior generation lease and rejects stale generator completion', async () => {
    const id=await scalar('select public.request_worksheet($1,$2,$3,$4)',[child,[worksheetQ2],{},randomUUID()]);
    const generation=await scalar('select public.claim_worksheet($1)',[id]);
    const cleanup=await scalar('select public.request_worksheet_cleanup($1,$2,$3)',[id,randomUUID(),'永久删除']);
    assert.equal((await scalar('select public.claim_cleanup_job($1)',[cleanup])).status,'queued');
    await client.query('reset role');
    assert.ok(await scalar("select next_attempt_at>now()+interval '14 minutes' from public.cleanup_jobs where id=$1",[cleanup]));
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await client.query('set role service_role');
    await denied('select public.update_worksheet_progress($1,$2,75)',[id,generation.lease_token]);
    await denied('select public.finish_worksheet($1,$2,$3)',[id,generation.lease_token,{error_code:'STALE'}]);
    await client.query('reset role');
    // Advance the disposable retention clock instead of waiting for a real hosted runtime.
    await client.query("update public.cleanup_jobs set next_attempt_at=now()-interval '1 second' where id=$1",[cleanup]);
    await client.query('set role service_role');
    const claim=await scalar('select public.claim_cleanup_job($1)',[cleanup]);
    await client.query('select public.finish_cleanup_job($1,$2,null)',[cleanup,claim.lease_token]);
    await login();
  });
  await check('source question purge clears associated PDF snapshots and retention queues expired PDFs once', async () => {
    const id=await scalar('select public.request_worksheet($1,$2,$3,$4)',[child,[worksheetQ2],{},randomUUID()]);
    const preview=await scalar('select public.preview_question_cleanup($1,$2,$3)',[child,'questions',[worksheetQ2]]);
    assert.equal(preview.worksheets,1); assert.equal(preview.files,1);
    const cleanup=await scalar('select public.request_question_cleanup($1,$2,$3,$4,$5)',[child,'questions',[worksheetQ2],randomUUID(),'永久删除']);
    const claim=await scalar('select public.claim_cleanup_job($1)',[cleanup]);
    assert.equal(claim.manifest.some(p=>p.bucket==='worksheets'),true);
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await client.query('set role service_role');
    await client.query('select public.finish_cleanup_job($1,$2,null)',[cleanup,claim.lease_token]);
    assert.equal(await scalar('select count(*)::int from public.worksheet_items where worksheet_id=$1',[id]),0);
    await login();
    const expired=await scalar('select public.request_worksheet($1,$2,$3,$4)',[child,[worksheetQ1],{},randomUUID()]);
    await denied('select public.enqueue_expired_worksheets()');
    await client.query('reset role');
    await client.query("update public.worksheet_jobs set expires_at=now()-interval '1 second' where id=$1",[expired]);
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await client.query('set role service_role');
    assert.equal(await scalar('select public.enqueue_expired_worksheets()'),1);
    assert.equal(await scalar('select public.enqueue_expired_worksheets()'),0);
    const queue=await scalar("select id from public.cleanup_jobs where $1=any(worksheet_ids)",[expired]);
    const expiredClaim=await scalar('select public.claim_cleanup_job($1)',[queue]);
    await client.query('select public.finish_cleanup_job($1,$2,null)',[queue,expiredClaim.lease_token]);
    assert.equal(await scalar('select count(*)::int from public.worksheet_items where worksheet_id=$1',[expired]),0);
    await login();
  });
  await check('PDF dispatcher is service-only and recovers queued failed and expired-lease work without charging', async () => {
    const id=await scalar('select public.request_worksheet($1,$2,$3,$4)',[child,[worksheetQ1],{},randomUUID()]);
    await denied('select public.pending_worksheet_jobs()');
    await client.query('reset role');
    await client.query("update public.worksheet_jobs set created_at='2000-01-01' where id=$1",[id]);
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await client.query('set role service_role');
    assert.deepEqual(await scalar('select public.pending_worksheet_jobs()'),[id]);
    const first=await scalar('select public.claim_worksheet($1)',[id]);
    assert.equal((await scalar('select public.pending_worksheet_jobs()')).includes(id),false);
    assert.equal((await scalar('select public.claim_worksheet($1)',[id])).status,'running');
    await client.query('select public.finish_worksheet($1,$2,$3)',[id,first.lease_token,{error_code:'PDF_UPLOAD_FAILED'}]);
    assert.equal((await scalar('select public.pending_worksheet_jobs()')).includes(id),false);
    assert.ok(await scalar('select next_attempt_at>now() from public.worksheet_jobs where id=$1',[id]));
    await client.query('reset role');
    await client.query("update public.worksheet_jobs set next_attempt_at=now()-interval '1 second' where id=$1",[id]);
    await client.query('set role service_role');
    assert.deepEqual(await scalar('select public.pending_worksheet_jobs()'),[id]);
    const second=await scalar('select public.claim_worksheet($1)',[id]);
    assert.deepEqual(second.snapshot.items,first.snapshot.items);
    await client.query('reset role');
    await client.query("update public.worksheet_jobs set lease_until=now()-interval '1 second' where id=$1",[id]);
    await client.query('set role service_role');
    assert.deepEqual(await scalar('select public.pending_worksheet_jobs()'),[id]);
    const third=await scalar('select public.claim_worksheet($1)',[id]);
    assert.notEqual(third.lease_token,second.lease_token);
    await denied('select public.update_worksheet_progress($1,$2,75)',[id,second.lease_token]);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[id]),0);
    await login();
  });
  await growthCases({client, scalar, login, denied, check, family, uid, postgres});
  await reportCases({client, scalar, login, denied, check, family, otherUid});
  await exportCases({client, scalar, login, denied, check, family, uid, otherUid});
  await childDeletionCases({client, scalar, login, denied, check, family, uid, otherUid});
  await check('family-local schedules handle a 23-hour daylight-saving day', async () => {
    await client.query('reset role');
    await client.query("update public.families set timezone='America/New_York' where id=$1", [family]);
    await client.query("insert into public.task_templates(child_id,title,recurrence,starts_on,ends_on) values($1,'DST','daily','2026-03-07','2026-03-08')", [child]);
    const dst = await scalar("select id from public.task_templates where title='DST'");
    await client.query("select set_config('request.jwt.claims',$1,false)", [JSON.stringify({role: 'service_role'})]);
    await client.query('set role service_role');
    await client.query("select public.generate_scheduled_tasks($1,'2026-03-07')", [child]);
    await client.query("select public.generate_scheduled_tasks($1,'2026-03-08')", [child]);
    const rows = (await client.query('select scheduled_at from public.task_instances where template_id=$1 order by due_date', [dst])).rows;
    assert.equal((rows[1].scheduled_at - rows[0].scheduled_at) / 3600000, 23);
    await login();
  });
  await check('five PIN failures lock verification and revoke elevation', async () => {
    for (let i = 0; i < 5; i++) {
      const row = (await client.query("select * from public.verify_parent_pin($1,'0000')", [family])).rows[0];
      assert.equal(row.verified, false);
      assert.equal(row.remaining_attempts, 4-i);
      if (i===4) assert.ok(row.retry_at);
    }
    const row = (await client.query("select * from public.verify_parent_pin($1,'1234')", [family])).rows[0];
    assert.equal(row.verified, false);
    assert.equal(await scalar('select public.has_parent_authorization($1)', [family]), false);
    await denied('select public.settle_long_plan($1)', [plan]);
  });
  await check('maintenance is restricted to the trusted scheduler and restores context', async () => {
    await denied('select public.run_task_maintenance()');
    await client.query('reset role');
    const tid = await scalar(`insert into public.task_templates(child_id,title,recurrence,starts_on,ends_on)
      values($1,'Closed zero-completion plan','daily',
        (now() at time zone 'America/New_York')::date-2,
        (now() at time zone 'America/New_York')::date-1) returning id`, [child]);
    const pid = await scalar('insert into public.long_plans(template_id,minimum_rate,bonus_coins,bonus_xp) values($1,.8,100,100) returning id', [tid]);
    const claims = JSON.stringify({role: 'service_role', marker: 'must-restore'});
    await client.query("select set_config('request.jwt.claims',$1,false)", [claims]);
    await client.query('set role service_role');
    const run = await scalar('select public.run_task_maintenance()');
    assert.equal(run.settled, 1);
    assert.equal(await scalar("select current_setting('request.jwt.claims')"), claims);
    assert.equal(Number(await scalar('select public.settle_long_plan($1)', [pid])), 0);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1', [pid]), 0);
    assert.equal((await scalar('select public.run_task_maintenance()')).settled, 0);
  });
  await taskPreferencesCases({client,scalar,login,denied,check,otherUid});
  await rewardInventoryCases({client,scalar,login,denied,check,otherUid});
  await onboardingCases({client,scalar,login,denied,check,otherUid});
  await pinyinImportCases({client,scalar,login,denied,check,otherUid});
  await offlineReviewCases({client,scalar,login,denied,check,otherUid});
  await imageUploadCases({client,scalar,login,denied,check,otherUid});
  await familyCreationCases({client,scalar,login,denied,check,otherUid});
  await aiAnalysisCases({client,scalar,login,denied,check,otherUid});
  await monthlyReportCases({client,scalar,login,denied,check,otherUid});
  await similarQuestionCases({client,scalar,login,denied,check,otherUid});
  await errorReasonCases({client,scalar,login,denied,check,otherUid});
  await aiReportCases({client,scalar,login,denied,check,otherUid});
  await runtimeDiagnosticsCases({client,scalar,login,denied,check});
  await parentNotificationCases({client,scalar,login,denied,check});
  await businessMetricsCases({client,scalar,login,denied,check});
  await childMediaDeletionCases({client,scalar,login,denied,check});
  await taskStartMetricsCases({client,scalar,login,denied,check});
  await familyRetentionCases({client,scalar,login,denied,check});
  await configurationTimeCases({client,scalar,login,denied,check});
  await parentPushCases({client,scalar,login,denied,check});
  await taskReminderPolicyCases({client,scalar,login,denied,check});
  await reviewSnoozeCases({client,scalar,login,denied,check});
  await familyInvitationCases({client,scalar,login,denied,check});
  await familyMemberRemovalCases({client,scalar,login,denied,check});
  await economyCommandCases({client,scalar,login,denied,check});
  await familyOverviewCases({client,scalar,login,denied,check});
  await scheduleSnapshotCases({client,scalar,login,denied,check});
  await taskNoteCases({client,scalar,login,denied,check});
  await growthSnapshotCases({client,scalar,login,denied,check});
  await economyPageCases({client,scalar,login,denied,check,otherUid});
  await taskTimeCorrectionCases({client,scalar,login,denied,check,otherUid});
  await childQuestionSubmissionCases({client,scalar,login,denied,check,otherUid});
  await ocrFieldCases({client,scalar,login,denied,check});
  await questionCatalogCases({client,scalar,login,denied,check,otherUid});
  await reviewMilestoneCases({client,scalar,login,denied,check,otherUid});
  await reviewAutoCompletionCases({client,scalar,login,denied,check,otherUid});
  await reviewConfidenceCases({client,scalar,login,denied,check,otherUid});
  await familyTimezoneCases({client,scalar,login,denied,check,otherUid});
  await worksheetVersionCases({client,scalar,login,denied,check,otherUid});
  await walletAdjustmentDetailsCases({client,scalar,login,denied,check});
  await accountDeletionCases({client,scalar,login,denied,check,otherUid});
  console.log(`All ${passed} database checks passed.`);
} finally {
  if (client) await client.end();
  await postgres?.stop();
}
