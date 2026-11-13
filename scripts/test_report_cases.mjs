import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

// Runs against the same disposable database and real migrations as test_database.
export async function reportCases({ client, scalar, login, denied, check, family, otherUid }) {
  await login();
  const child = await scalar("select public.create_child($1,'Report child',2::smallint)", [family]);
  const sibling = await scalar("select public.create_child($1,'Report sibling',2::smallint)", [family]);
  const zone = await scalar('select timezone from public.families where id=$1', [family]);
  const report = (period = 'day', date = '2026-03-08', id = child) =>
    scalar('select public.learning_report($1,$2,$3)', [id, period, date]);
  await client.query('reset role');
  await client.query("update public.families set timezone='America/New_York' where id=$1", [family]);
  const template = await scalar("insert into public.task_templates(child_id,title) values($1,'Excused') returning id", [child]);
  const plan = await scalar('insert into public.long_plans(template_id,minimum_rate,bonus_coins,bonus_xp) values($1,1,0,0) returning id', [template]);
  await client.query("insert into public.plan_leaves values($1,'2026-03-08','approved')", [plan]);
  async function task(id, title, day, status, seconds, completed, tid = null) {
    return scalar(`insert into public.task_instances(child_id,title,due_date,source_type,status,
      accumulated_seconds,completed_at,idempotency_key,template_id)
      values($1,$2,$3,'parent_template',$4,$5,$6,$7,$8) returning id`,
    [id, title, day, status, seconds, completed, randomUUID(), tid]);
  }
  const completed = await task(child, 'Reading', '2026-03-08', 'completed', 600, '2026-03-08T05:00:00Z');
  await task(child, 'Paused', '2026-03-08', 'paused', 120, null);
  await task(child, 'Voluntary skip', '2026-03-08', 'skipped', 0, null);
  await task(child, 'Approved leave', '2026-03-08', 'skipped', 0, null, template);
  await task(child, 'Late completion', '2026-03-07', 'completed', 240, '2026-03-09T03:59:59Z');
  await task(child, 'Next local day', '2026-03-09', 'completed', 300, '2026-03-09T04:00:00Z');
  await task(sibling, 'Other child private task', '2026-03-08', 'completed', 999, '2026-03-08T12:00:00Z');
  const question = await scalar(`insert into public.wrong_questions(child_id,subject,final_text,review_due_at)
    values($1,'math','Private prompt','2026-03-08T05:00:00Z') returning id`, [child]);
  await client.query(`insert into public.task_review_items(task_instance_id,wrong_question_id,sequence,result,answered_at)
    values($1,$2,1,true,'2026-03-09T03:59:59Z')`, [completed, question]);
  await client.query(`insert into public.wrong_questions(child_id,subject,final_text,review_due_at,archived)
    values($1,'math','Archived','2026-03-08',true),($2,'math','Sibling','2026-03-08',false)`, [child, sibling]);
  async function ledger(amount, frozen, source, time, asset = 'coin') {
    await client.query(`insert into public.ledger_entries(child_id,asset_type,amount,frozen_delta,source_type,idempotency_key,created_at)
      values($1,$2,$3,$4,$5,$6,$7)`, [child, asset, amount, frozen, source, randomUUID(), time]);
  }
  await ledger(100, 0, 'parent_adjustment', '2026-03-08T05:00:00Z');
  await ledger(-40, 40, 'redemption_freeze', '2026-03-08T06:00:00Z');
  await ledger(40, -40, 'redemption_refund', '2026-03-08T07:00:00Z');
  await ledger(-20, 20, 'redemption_freeze', '2026-03-08T08:00:00Z');
  await ledger(0, -20, 'redemption_spend', '2026-03-09T03:59:59Z');
  await ledger(-5, 0, 'parent_adjustment', '2026-03-08T09:00:00Z');
  await ledger(12, 0, 'parent_adjustment', '2026-03-08T09:00:00Z', 'xp');
  await ledger(17, 0, 'parent_adjustment', '2026-03-09T04:00:00Z');
  await login();
  await check('reports exclude approved leave but include voluntary skips and stored active time', async () => {
    const r = await report();
    assert.deepEqual(r.tasks, { expected: 3, completed: 1, effective_seconds: 720, completion_rate: 0.3333 });
    assert.equal(r.days.length, 1);
    assert.equal(r.due_now, 1);
    assert.equal(JSON.stringify(r).includes('Private prompt'), false);
    assert.equal(JSON.stringify(r).includes('Other child private task'), false);
  });
  await check('report completion activity and review use a 23-hour family day and exclusive upper bound', async () => {
    const r = await report();
    assert.equal(r.activity_count, 2);
    assert.deepEqual(r.activities.map(a => a.title), ['Late completion', 'Reading']);
    assert.deepEqual(r.reviews, { answered: 1, correct: 1, accuracy: 1 });
    assert.deepEqual(r.coins, { income: 100, spent: 20, adjustment_out: 5, xp: 12 });
  });
  await check('weekly reports include empty dates and empty rates remain null', async () => {
    const r = await report('week');
    assert.equal(r.start_date, '2026-03-02');
    assert.equal(r.days.length, 7);
    assert.equal(r.days[0].expected, 0);
    assert.equal(r.tasks.expected, 4);
    assert.equal(r.tasks.completed, 2);
    const empty = await report('day', '2026-02-01');
    assert.equal(empty.tasks.completion_rate, null);
    assert.equal(empty.reviews.accuracy, null);
    assert.deepEqual(empty.activities, []);
  });
  await check('report dates default to server family today and reject future or unbounded input', async () => {
    const r = await report('week', null);
    assert.equal(r.end_date, await scalar('select public.family_today($1)', [child]));
    for (const date of ['2999-01-01', 'infinity', '-infinity', '1999-01-01']) {
      await denied("select public.learning_report($1,'day',$2)", [child, date]);
    }
    await denied("select public.learning_report($1,'year',null)", [child]);
    await denied('select public.learning_report($1,null,null)', [child]);
  });
  await check('ordinary PIN-authorized parent can read reports', async () => {
    await login(otherUid);
    assert.equal((await report()).child_id, child);
    await login();
  });
  await check('report RPC requires current-session PIN and rejects other families and anonymous users', async () => {
    await login(undefined, 'report-no-pin');
    await assert.rejects(report());
    const outsider = randomUUID();
    await client.query('reset role');
    await client.query('insert into auth.users values($1,$2)', [outsider, 'report-outsider@example.test']);
    await login(outsider);
    await assert.rejects(report());
    await client.query('reset role');
    await client.query('set role anon');
    await assert.rejects(report());
    await login();
    await assert.rejects(report('day', null, randomUUID()));
  });
  await check('expired PIN cannot read reports and restored authorization reads fresh totals', async () => {
    await client.query('reset role');
    await client.query("update public.parent_authorizations set expires_at=now()-interval '1 second' where family_id=$1", [family]);
    await login();
    await assert.rejects(report());
    await client.query("select public.verify_parent_pin($1,'1234')", [family]);
    assert.equal((await report()).tasks.completed, 1);
  });
  await client.query('reset role');
  await client.query('update public.families set timezone=$1 where id=$2', [zone, family]);
  await login();
}
