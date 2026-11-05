import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function configurationTimeCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(),parent=randomUUID(),outsider=randomUUID();
  const admin=()=>client.query('reset role');
  await admin();for(const id of [owner,parent,outsider]) await client.query('insert into auth.users values($1,$2)',[id,`${id}@configuration.test`]);
  const auth=()=>login(owner,'configuration-session');await auth();
  await scalar("select public.onboard_family('Editing','America/New_York','Child',2::smallint)");
  const family=await scalar('select family_id from public.family_members where user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'2468')",[family]);await scalar("select public.verify_parent_pin($1,'2468')",[family]);
  const sibling=await scalar("select public.create_child($1,'Sibling',2::smallint)",[family]);
  await admin();await client.query("insert into public.family_members values($1,$2,'parent')",[family,parent]);await auth();
  const now=Date.parse(await scalar('select clock_timestamp()::text'));
  const event=(start=-60000,end=-40000,extra={})=>({event_id:randomUUID(),child_id:child,family_id:family,kind:'task',
    started_at:new Date(now+start).toISOString(),ended_at:new Date(now+end).toISOString(),...extra});
  const send=events=>scalar('select public.record_parent_configuration($1)',[JSON.stringify(events)]);
  const report=()=>scalar("select public.learning_report($1,'week',null)",[child]);
  const count=async()=>{await admin();const n=await scalar('select count(*)::integer from public.parent_configuration_intervals where family_id=$1',[family]);await auth();return n;};
  let first;
  await check('configuration intervals replay idempotently; same-parent overlaps across task/rules/children merge without suppressing another parent',async()=>{
    first=event();await send([first]);await send([first]);
    await send([event(-50000,-30000,{kind:'rules'}),event(-55000,-45000,{child_id:sibling})]);
    let stats=(await report()).configuration_time;assert.equal(stats.milliseconds,30000);assert.equal(stats.samples,3);assert.equal(stats.parents,1);
    await login(parent,'configuration-parent');await scalar("select public.verify_parent_pin($1,'2468')",[family]);await send([event()]);
    stats=(await report()).configuration_time;assert.equal(stats.milliseconds,50000);assert.equal(stats.parents,2);
    await auth();await denied('select public.record_parent_configuration($1)',[JSON.stringify([{...first,kind:'rules'}])]);assert.equal(await count(),4);
  });
  await check('configuration validation is all-or-nothing and bounds payloads, duration, future and offline age',async()=>{
    for(const body of [[],Array(51).fill(event()),[event(),event(0,31000)],[{...event(),text:'PRIVATE'}],
      [event(-1,-2)],[event(-5,-5)],[event(-10,-1,{kind:'unknown'})],[event(-10,-1,{started_at:null})],
      [event(-10,-1,{event_id:'not-uuid'})]]) await denied('select public.record_parent_configuration($1)',[JSON.stringify(body)]);
    const duplicate=event();await denied('select public.record_parent_configuration($1)',[JSON.stringify([duplicate,duplicate])]);
    const expired=event(-8*86400000,-8*86400000+10000),future=event(86400000,86410000);
    const result=await send([expired,future]);assert.equal(result.accepted,0);assert.deepEqual(result.event_ids,[expired.event_id,future.event_id]);
    assert.equal(await count(),4);
  });
  await check('private scopes cannot be injected, stale/deleted children do not block valid intervals, and parent reports still require PIN',async()=>{
    await login(outsider);assert.equal((await send([event()])).accepted,0);
    await denied('select * from public.parent_configuration_intervals');await denied("select public.learning_report($1,'week',null)",[child]);
    await login(owner,'configuration-no-pin');await send([event(-20000,-10000)]);await denied("select public.learning_report($1,'week',null)",[child]);
    await auth();assert.equal((await send([event(-20000,-10000,{child_id:randomUUID()}),event(-20000,-10000,{family_id:randomUUID()})])).accepted,0);
    assert.equal(await count(),5);
    const preview=await scalar('select public.preview_child_deletion($1)',[sibling]);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[sibling,randomUUID(),preview.counts]);
    const result=await send([event(-20000,-10000,{child_id:sibling}),event(-5000,-1000)]);assert.equal(result.accepted,1);
    await admin();assert.equal(await scalar('select count(*)::integer from public.parent_configuration_intervals where child_id=$1',[sibling]),0);await auth();
  });
  await check('two devices uploading the same interval concurrently cannot double-count or replace its payload',async()=>{
    const peer=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});await peer.connect();
    try {
      await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:owner,role:'authenticated',session_id:'configuration-session'})]);await peer.query('set role authenticated');
      const sample=event(-120000,-100000);
      await Promise.all([send([sample]),peer.query('select public.record_parent_configuration($1)',[JSON.stringify([sample])])]);
      await admin();assert.equal(await scalar('select count(*)::integer from public.parent_configuration_intervals where owner_id=$1 and event_id=$2',[owner,sample.event_id]),1);await auth();
      const race=event(-150000,-130000);
      const outcomes=await Promise.allSettled([send([race]),peer.query('select public.record_parent_configuration($1)',[JSON.stringify([{...race,kind:'rules'}])])]);
      assert.equal(outcomes.filter(r=>r.status==='fulfilled').length,1);assert.equal(outcomes.filter(r=>r.status==='rejected').length,1);
    } finally {await peer.end();}
  });
  await check('family-local report boundaries split intervals exactly; empty and expired windows remain explicit',async()=>{
    await admin();await client.query('delete from public.parent_configuration_intervals where family_id=$1',[family]);
    const midnight=Date.parse(await scalar("select ((now() at time zone 'America/New_York')::date)::timestamp at time zone 'America/New_York'"));
    const yesterday=await scalar("select ((now() at time zone 'America/New_York')::date-1)::text");
    await auth();await send([{...event(),started_at:new Date(midnight-10000).toISOString(),ended_at:new Date(midnight+10000).toISOString()}]);
    let data=await scalar("select public.learning_report($1,'day',$2)",[child,yesterday]);assert.equal(data.configuration_time.milliseconds,10000);
    data=await scalar("select public.learning_report($1,'day',null)",[child]);assert.equal(data.configuration_time.milliseconds,10000);
    data=await scalar("select public.learning_report($1,'day',(public.family_today($1)::date-150))",[child]);
    assert.equal(data.configuration_time.milliseconds,0);assert.equal(data.configuration_time.samples,0);assert.equal(data.configuration_time.partial_window,true);
    await admin();assert.equal(Number(await scalar("select extract(epoch from ('2026-11-01T06:00:10Z'::timestamptz-'2026-11-01T05:59:50Z'::timestamptz))")),20);await auth();
  });
  await check('export includes only the requesting parent configuration metadata and retention cleanup is service-only',async()=>{
    await login(parent,'configuration-parent');await send([event()]);await auth();
    const preview=await scalar('select public.preview_child_export($1)',[child]);assert.equal(preview.counts.parent_configuration_time,1);
    const job=await scalar('select public.prepare_child_export($1,$2,$3,$4)',[child,randomUUID(),preview.counts,'导出孩子数据']);assert.equal(job.sections.length,40);
    const page=await scalar("select public.read_child_export_page($1,'parent_configuration_time',0)",[job.id]);
    assert.equal(page.rows.length,1);assert.ok(!JSON.stringify(page).includes(owner));assert.ok(!JSON.stringify(page).includes('payload_hash'));
    await denied('select public.purge_configuration_intervals()');await admin();
    await client.query("update public.parent_configuration_intervals set started_at=now()-interval '91 days',ended_at=now()-interval '91 days'+interval '10 seconds' where owner_id=$1",[parent]);
    await client.query('set role service_role');await scalar('select public.purge_configuration_intervals()');await admin();
    assert.equal(await scalar('select count(*)::integer from public.parent_configuration_intervals where owner_id=$1',[parent]),0);await auth();
  });
  await check('membership removal and account-deletion acceptance immediately erase configuration intervals and reject stale collection',async()=>{
    await login(parent,'configuration-parent');await send([event()]);await admin();
    await client.query('delete from public.family_members where family_id=$1 and user_id=$2',[family,parent]);
    assert.equal(await scalar('select count(*)::integer from public.parent_configuration_intervals where owner_id=$1',[parent]),0);
    await login(parent,'configuration-parent');assert.equal((await send([event()])).accepted,0);
    await admin();await client.query("insert into public.family_members values($1,$2,'parent')",[family,parent]);
    await login(parent,'configuration-parent');await send([event()]);
    assert.equal(await scalar('select public.has_parent_authorization($1)',[family]),false);
    await scalar("select public.verify_parent_pin($1,'2468')",[family]);
    const scope=(await scalar('select public.preview_account_deletion()')).scope;
    await scalar("select public.request_account_deletion($1,$2,'永久注销我的账号')",[randomUUID(),scope]);
    await denied('select public.record_parent_configuration($1)',[JSON.stringify([event()])]);
    await admin();assert.equal(await scalar('select count(*)::integer from public.parent_configuration_intervals where owner_id=$1',[parent]),0);await auth();
  });
}
