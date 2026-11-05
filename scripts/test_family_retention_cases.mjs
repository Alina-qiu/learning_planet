import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';

export async function familyRetentionCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(),outsider=randomUUID();
  await client.query('reset role');
  for(const id of [owner,outsider]) await client.query('insert into auth.users values($1,$2)',[id,`${id}@retention.test`]);
  const auth=async()=>login(owner,'retention-session');
  await auth();await scalar("select public.onboard_family('Retention','America/New_York','Child',2::smallint)");
  const family=await scalar('select family_id from public.family_members where user_id=$1',[owner]);
  await scalar("select public.set_parent_pin($1,'2468')",[family]);await scalar("select public.verify_parent_pin($1,'2468')",[family]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  const record=events=>scalar('select public.record_family_activity($1,$2)',[family,JSON.stringify(events)]);
  const at=async offset=>scalar("select to_char((clock_timestamp()+$1::interval) at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')",[offset]);
  const report=()=>scalar("select public.learning_report($1,'day',null)",[child]);
  const admin=()=>client.query('reset role');
  const snapshot=()=>scalar('select public.family_retention_snapshot($1)',[family]);
  const task=async source=>scalar(`insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key,created_at)
    values($1,'First task',current_date,$2,$3,'1999-01-01') returning id`,[child,source,randomUUID()]);
  await check('family retention starts at first non-automatic task and freezes server time/timezone across deletion and siblings',async()=>{
    const before=await at('-1 second');await record([before]);
    let view=(await report()).family_retention;assert.equal(view.days[0].status,'no_task');assert.equal(view.days[0].mature,false);
    await admin();await task('automatic_wrong_review');assert.equal((await snapshot()).cohort_date,null);
    const first=await task('parent_template');
    const anchor=await scalar('select to_jsonb(r) from public.family_retention r where family_id=$1',[family]);
    assert.equal(anchor.anchor_source,'observed');assert.notEqual(anchor.first_task_at.slice(0,4),'1999');
    await client.query("update public.families set timezone='Asia/Shanghai' where id=$1",[family]);
    await client.query('delete from public.task_instances where id=$1',[first]);await task('long_plan');
    assert.deepEqual(await scalar('select to_jsonb(r) from public.family_retention r where family_id=$1',[family]),anchor);
    await auth();view=(await report()).family_retention;
    assert.equal(view.timezone,'America/New_York');assert.equal(view.days[0].status,'pending');
  });
  await check('activity upload is bounded, idempotent and never records future, expired or arbitrary payloads',async()=>{
    const moment=await at('-2 seconds');const response=await record([moment,moment]);
    assert.equal(response.accepted,2);assert.deepEqual(response.acknowledged,[moment,moment]);
    await record([moment]);await admin();assert.equal(await scalar('select count(*)::integer from public.family_activity_days where family_id=$1',[family]),1);
    await auth();assert.equal((await record([await at('1 day'),await at('-8 days')])).accepted,0);
    for(const body of [[],Array(17).fill(moment),['invalid'],[{'question':'private text'}],[null],['2026-99-99T00:00:00Z'],[moment,'private text']]) {
      await denied('select public.record_family_activity($1,$2)',[family,JSON.stringify(body)]);
    }
    await denied('select public.record_family_activity($1,$2)',[family,JSON.stringify({moments:[moment]})]);
    await admin();assert.equal(await scalar('select count(*)::integer from public.family_activity_days where family_id=$1',[family]),1);await auth();
  });
  await check('offline day-1 and day-7 observations use family dates; maturity waits for seven-day upload grace',async()=>{
    await admin();await client.query('delete from public.family_activity_days where family_id=$1',[family]);
    await client.query(`update public.family_retention set first_task_at=now()-interval '7 days',
      cohort_date=(now() at time zone cohort_timezone)::date-7,collection_started_at=now()-interval '8 days' where family_id=$1`,[family]);
    // Calendar day 1 is not necessarily 6 * 24 hours ago across New York DST.
    const dayMoment=n=>scalar(`select to_char(least(clock_timestamp(),
      ((cohort_date+$2::integer)::timestamp at time zone cohort_timezone)+interval '12 hours')
      at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') from public.family_retention where family_id=$1`,[family,n]);
    const day1=await dayMoment(1),day7=await dayMoment(7);
    await auth();await record([day1,day7]);
    let view=(await report()).family_retention;assert.deepEqual(view.days.map(d=>d.status),['returned','returned']);
    assert.deepEqual(view.days.map(d=>d.mature),[false,false]);
    await admin();await client.query('delete from public.family_activity_days where family_id=$1',[family]);
    await auth();view=(await report()).family_retention;assert.deepEqual(view.days.map(d=>d.status),['collecting','collecting']);
    await admin();await client.query("update public.family_retention set cohort_date=cohort_date-20,first_task_at=first_task_at-interval '20 days',collection_started_at=collection_started_at-interval '20 days' where family_id=$1",[family]);
    await auth();view=(await report()).family_retention;
    assert.deepEqual(view.days.map(d=>d.status),['not_observed','not_observed']);assert.ok(view.days.every(d=>d.mature));
    assert.equal((await record([await at('-1 second')])).complete,true);
    await admin();assert.equal(await scalar('select count(*)::integer from public.family_activity_days where family_id=$1',[family]),0);await auth();
  });
  await check('mature cohort aggregate excludes legacy and uninstrumented families, exposes only service totals and null zero denominators',async()=>{
    await admin();
    const cohort=await scalar('select cohort_date::text from public.family_retention where family_id=$1',[family]);
    await client.query('insert into public.family_activity_days select family_id,cohort_date+1 from public.family_retention where family_id=$1',[family]);
    let totals=await scalar('select public.family_retention_summary($1,$1)',[cohort]);
    assert.equal(totals.days[0].denominator,1);assert.equal(totals.days[0].rate,1);assert.equal(totals.days[1].rate,0);
    await client.query("update public.family_retention set anchor_source='legacy' where family_id=$1",[family]);
    assert.equal((await snapshot()).days[0].status,'historical_unknown');
    totals=await scalar('select public.family_retention_summary($1,$1)',[cohort]);assert.equal(totals.days[0].unknown,1);assert.equal(totals.days[0].rate,null);
    await client.query("update public.family_retention set anchor_source='observed',collection_started_at=now() where family_id=$1",[family]);
    assert.equal((await snapshot()).days[0].status,'collection_unknown');
    await denied('select public.family_retention_summary(null,current_date)');await denied("select public.family_retention_summary(current_date,current_date+367)");
    await auth();await denied('select public.family_retention_summary($1,$1)',[cohort]);
    await denied('select public.family_retention_snapshot($1)',[family]);
    await client.query('set role service_role');assert.equal((await scalar('select public.family_retention_summary($1,$1)',[cohort])).days[0].unknown,1);await auth();
  });
  await check('retention metadata respects PIN, membership and RLS and is included in scoped parent exports',async()=>{
    const preview=await scalar('select public.preview_child_export($1)',[child]);
    assert.equal(preview.counts.family_retention,1);assert.equal(preview.counts.family_activity_days,1);
    const job=await scalar('select public.prepare_child_export($1,$2,$3,$4)',[child,randomUUID(),preview.counts,'导出孩子数据']);assert.equal(job.sections.length,40);
    const dart=await readFile(new URL('../lib/features/data_management/domain/child_export.dart',import.meta.url),'utf8');
    const clientSections=new Set([...dart.matchAll(/'([a-z_]+)':/g)].map(match=>match[1]));
    assert.ok(job.sections.every(s=>clientSections.has(s.name)),'every actual server export section must be accepted by the Flutter ZIP builder');
    await login(outsider);await denied('select public.record_family_activity($1,$2)',[family,JSON.stringify([await at('-1 second')])]);
    await denied("select public.learning_report($1,'day',null)",[child]);
    await denied('select * from public.family_activity_days where family_id=$1',[family]);
    await denied('delete from public.family_retention where family_id=$1',[family]);
    await login(owner,'no-pin-session');await record([await at('-1 second')]);await denied("select public.learning_report($1,'day',null)",[child]);
    await auth();
  });
  await check('local calendar offsets survive DST and shared family aggregates cascade with family deletion',async()=>{
    await admin();
    for(const day of ['2026-03-07','2026-10-31']) {
      await client.query("update public.family_retention set cohort_date=$2::date,first_task_at=$2::date::timestamp at time zone 'America/New_York',collection_started_at=$2::date::timestamp at time zone 'America/New_York' where family_id=$1",[family,day]);
      const view=await snapshot();assert.equal(view.days[0].date,day==='2026-03-07'?'2026-03-08':'2026-11-01');
      const hours=await scalar("select extract(epoch from (($1::date+2)::timestamp at time zone 'America/New_York')-(($1::date+1)::timestamp at time zone 'America/New_York'))/3600",[day]);
      assert.equal(Number(hours),day==='2026-03-07'?23:25);
    }
    // Remove child rows through established deletion workflows elsewhere; this isolated
    // family has no identity-linked measurements and both new tables use family cascade.
    const empty=await scalar("insert into public.families(name,owner_user_id) values('Cascade',$1) returning id",[owner]);
    await client.query("insert into public.family_retention(family_id,anchor_source) values($1,'observed')",[empty]);
    await client.query('insert into public.family_activity_days values($1,current_date)',[empty]);
    await client.query('delete from public.families where id=$1',[empty]);
    assert.equal(await scalar('select count(*)::integer from public.family_retention where family_id=$1',[empty]),0);
    assert.equal(await scalar('select count(*)::integer from public.family_activity_days where family_id=$1',[empty]),0);await auth();
  });
}
