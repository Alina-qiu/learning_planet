// Disposable PostgreSQL only. This never connects to a linked Supabase project.
import EmbeddedPostgres from 'embedded-postgres';
import { cp, mkdtemp, readFile, readdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import pg from 'pg';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import assert from 'node:assert/strict';

const directory = await mkdtemp(join(tmpdir(), 'learning-planet-db-'));
const postgres = new EmbeddedPostgres({
  databaseDir: directory, user: 'postgres', password: 'local-test-only',
  port: 54339, persistent: false,
  initdbFlags: ['--locale=C', '--encoding=UTF8'],
  onLog: () => {},
});
// PostgreSQL on Windows cannot bootstrap from a Chinese binary path.
// Copy only the bundled native runtime into this fresh, ASCII temp directory.
if (process.platform === 'win32') {
  const binaries = await import('@embedded-postgres/windows-x64');
  const native = join(directory, 'native');
  await cp(dirname(dirname(binaries.initdb)), native, { recursive: true });
  const data = join(directory, 'data');
  function command(name, args) {
    const result = spawnSync(join(native, 'bin', name + '.exe'), args,
      { windowsHide: true, encoding: 'utf8', stdio: 'ignore', timeout: 30000 });
    if (result.error || result.status !== 0) {
      throw result.error ?? new Error('Temporary PostgreSQL command failed: ' + name);
    }
  }
  postgres.initialise = async () => command('initdb', ['-D', data, '-U', 'postgres', '--auth=trust', '--locale=C', '--encoding=UTF8']);
  postgres.start = async () => command('pg_ctl', ['-D', data, '-o', '-h 127.0.0.1 -p 54339', '-l', join(directory, 'postgres.log'), '-w', 'start']);
  postgres.getPgClient = () => new pg.Client({host: '127.0.0.1', port: 54339, user: 'postgres', database: 'postgres'});
  let started = false;
  const start = postgres.start;
  postgres.start = async () => { await start(); started = true; };
  postgres.stop = async () => { if (started) { command('pg_ctl', ['-D', data, '-m', 'fast', '-w', 'stop']); started = false; } };
}
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
  await postgres.initialise(); await postgres.start();
  client = postgres.getPgClient(); await client.connect();
  await client.query(`
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin bypassrls;
    create schema auth;
    create table auth.users(id uuid primary key,email text);
    create function auth.jwt() returns jsonb language sql stable as
      $$ select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
    create function auth.uid() returns uuid language sql stable as $$ select (auth.jwt()->>'sub')::uuid $$;
    create function auth.role() returns text language sql stable as $$ select auth.jwt()->>'role' $$;
    grant usage on schema auth,public to anon,authenticated,service_role;
    grant execute on all functions in schema auth to anon,authenticated,service_role;
    alter default privileges in schema public grant all on tables to anon,authenticated,service_role;
    insert into auth.users values ('${uid}','parent@example.test'),('${otherUid}','other@example.test');
  `);
  const migrationDirectory = resolve('supabase/migrations');
  for (const name of (await readdir(migrationDirectory)).filter(n => n.endsWith('.sql')).sort()) {
    const sql = await readFile(join(migrationDirectory, name), 'utf8');
    try { await client.query(sql); } catch (error) {
      const position = Number(error.position ?? 1) - 1;
      console.error('Migration error near:', sql.slice(Math.max(0, position - 150), position + 150));
      throw error;
    }
    console.log('MIGRATED ' + name);
  }
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
  await check('concurrent completion pays only one reward', async () => {
    const tid = await scalar('select public.save_task_schedule($1,$2)', [child,
      {...config, title: 'Concurrent', recurrence: 'once', minimum_seconds: 0, coins: 3, xp: 4}]);
    const taskId = await scalar('select id from public.task_instances where template_id=$1', [tid]);
    await client.query('select public.start_task($1)', [taskId]);
    const before = await scalar('select coin_balance from public.wallets where child_id=$1', [child]);
    const secondClient = new pg.Client({host: '127.0.0.1', port: 54339, user: 'postgres',
      password: 'local-test-only', database: 'postgres'});
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
    const secondClient = new pg.Client({host: '127.0.0.1', port: 54339, user: 'postgres',
      password: 'local-test-only', database: 'postgres'});
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
  console.log(`All ${passed} database checks passed.`);
} finally {
  if (client) await client.end();
  await postgres.stop();
}
