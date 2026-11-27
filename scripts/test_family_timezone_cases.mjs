import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function familyTimezoneCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(),auth=()=>login(user,'family-timezone');
  await client.query('reset role');await client.query('insert into auth.users values($1,$2)',[user,'timezone@example.test']);
  await auth();await scalar("select public.onboard_family('Time','Asia/Shanghai','Child',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'2468')",[family]);await scalar("select public.verify_parent_pin($1,'2468')",[family]);
  const load=()=>scalar('select public.family_time_settings($1)',[family]);
  const save=(zone,version)=>scalar('select public.set_family_timezone($1,$2,$3)',[family,zone,version]);
  const move=async zone=>save(zone,(await load()).version);
  const count=()=>scalar("select count(*)::int from public.audit_logs where family_id=$1 and action='family.timezone_changed'",[family]);
  const tasks=()=>scalar("select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]'::jsonb) from public.task_instances t where child_id=$1",[child]);
  const wallet=()=>scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]);

  await check('timezone settings require administrator current-session PIN and direct mutation remains unavailable',async()=>{
    const initial=await load();assert.equal(initial.version,0);assert.equal(initial.timezone,'Asia/Shanghai');assert.deepEqual(initial.child_ids,[child]);
    await denied("update public.families set timezone='UTC' where id=$1",[family]);
    await denied('update public.families set timezone_version=5 where id=$1',[family]);
    await scalar('select public.revoke_parent_authorization($1)',[family]);await denied('select public.family_time_settings($1)',[family]);
    await denied("select public.set_family_timezone($1,'UTC',0)",[family]);await scalar("select public.verify_parent_pin($1,'2468')",[family]);
    await client.query('reset role');await client.query("insert into public.family_members(family_id,user_id,role) values($1,$2,'parent')",[family,otherUid]);
    await login(otherUid);await scalar("select public.verify_parent_pin($1,'2468')",[family]);
    await denied('select public.family_time_settings($1)',[family]);await denied("select public.set_family_timezone($1,'UTC',0)",[family]);
    await auth();assert.equal((await load()).version,0);
    for(const [zone,version] of [['Wrong/Zone',0],['Asia/Shanghai ' ,0],[null,0],['UTC',null],['UTC',-1]]) {
      await denied('select public.set_family_timezone($1,$2,$3)',[family,zone,version]);
    }
    await denied('select public.generate_scheduled_tasks_before_timezone($1,null)',[child]);
    await denied('select public.generate_daily_wrong_review_task_before_timezone($1,null,10)',[child]);
    assert.equal(await count(),0);
  });
  await check('timezone compare-and-set retries audit once and reject intervening changes including ABA',async()=>{
    assert.equal((await save('Asia/Shanghai',0)).outcome,'unchanged');
    const saved=await save('UTC',0);assert.equal(saved.version,1);assert.equal(saved.outcome,'applied');assert.equal(await count(),1);
    const replay=await save('UTC',0);assert.equal(replay.outcome,'already_applied');assert.equal(replay.version,1);assert.equal(await count(),1);
    await assert.rejects(save('Asia/Tokyo',0),e=>e.code==='40001');
    await save('Asia/Tokyo',1);await save('UTC',2);
    await assert.rejects(save('UTC',0),e=>e.code==='40001');assert.equal((await load()).version,3);assert.equal(await count(),3);
    const audit=await scalar("select details from public.audit_logs where family_id=$1 and action='family.timezone_changed' order by id desc limit 1",[family]);
    assert.deepEqual(audit,{before:'Asia/Tokyo',after:'UTC',previous_version:2,version:3});
  });
  await check('timezone change invalidates each parent policy version without changing notification choices',async()=>{
    await client.query('reset role');
    await client.query("insert into public.parent_notification_settings(family_id,user_id,enabled,quiet_start,quiet_end,version) values($1,$2,true,'20:00','08:00',7),($1,$3,false,'22:00','06:00',3)",[family,user,otherUid]);
    await auth();await move('Asia/Shanghai');await client.query('reset role');
    const rows=(await client.query('select user_id,version,enabled,quiet_start::text,quiet_end::text from public.parent_notification_settings where family_id=$1 order by user_id',[family])).rows;
    assert.deepEqual(rows.find(r=>r.user_id===user),{user_id:user,version:8,enabled:true,quiet_start:'20:00:00',quiet_end:'08:00:00'});
    assert.deepEqual(rows.find(r=>r.user_id===otherUid),{user_id:otherUid,version:4,enabled:false,quiet_start:'22:00:00',quiet_end:'06:00:00'});await auth();
  });
  let template,oldDay,newDay,oldTask;
  await check('family-day changes preserve existing task instants and create only the new day without backfill',async()=>{
    await move('Pacific/Pago_Pago');oldDay=(await load()).family_today;
    template=await scalar('select public.save_task_schedule($1,$2)',[child,{title:'Timezone reading',recurrence:'daily',starts_on:oldDay,
      ends_on:await scalar("select ($1::date+30)::text",[oldDay]),start_time:'16:00',due_time:'20:00',coins:10,xp:8,minimum_seconds:0}]);
    const before=await tasks();oldTask=before.find(t=>t.template_id===template);assert.ok(oldTask);
    await move('Pacific/Kiritimati');newDay=(await load()).family_today;assert.notEqual(newDay,oldDay);
    assert.deepEqual(await tasks(),before);await scalar('select public.generate_scheduled_tasks($1)',[child]);
    const after=await tasks(),today=after.find(t=>t.due_date===newDay);assert.equal(after.length,2);
    assert.deepEqual(after.find(t=>t.id===oldTask.id),oldTask);
    assert.equal(Date.parse(today.scheduled_at),Date.parse(await scalar("select (($1::date+time '16:00') at time zone 'Pacific/Kiritimati')::text",[newDay])));
    for(let i=0;i<3;i++)assert.equal(await scalar('select public.generate_scheduled_tasks($1)',[child]),0);
    await move('Pacific/Pago_Pago');assert.equal(await scalar('select public.generate_scheduled_tasks($1)',[child]),0);assert.equal((await tasks()).length,2);
  });
  await check('changing timezone keeps reviewed questions, answers, awards and completed task snapshots intact',async()=>{
    const q=await scalar('select public.save_review_question($1,$2)',[child,{kind:'question',subject:'math',prompt:'2+2',answers:['4']}]);
    const task=await scalar('select public.generate_daily_wrong_review_task($1)',[child]);await scalar('select public.start_task($1)',[task]);
    await scalar('select public.submit_review_answer($1,$2,$3,$4,2::smallint)',[task,q,'4',randomUUID()]);
    const before=await scalar('select public.load_review_task($1)',[task]),w=await wallet(),question=await scalar('select to_jsonb(q) from public.wrong_questions q where id=$1',[q]);
    await move('Pacific/Kiritimati');
    assert.deepEqual(await scalar('select public.load_review_task($1)',[task]),before);assert.deepEqual(await wallet(),w);
    assert.deepEqual(await scalar('select to_jsonb(q) from public.wrong_questions q where id=$1',[q]),question);
    await move('Pacific/Pago_Pago');assert.equal(await scalar('select public.generate_daily_wrong_review_task($1)',[child]),task);
    await scalar("select public.complete_task($1,'timezone-retry')",[task]);assert.deepEqual(await wallet(),w);
  });
  await check('two devices changing the same version serialize and the losing intent cannot overwrite the winner',async()=>{
    const original=await load(),peer=new pg.Client(client.connectionParameters);try {
      await peer.connect();await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:'family-timezone'})]);await peer.query('set role authenticated');await peer.query('begin');
      await peer.query("select public.set_family_timezone($1,'UTC',$2)",[family,original.version]);
      await client.query("set lock_timeout='100ms'");await assert.rejects(save('Asia/Tokyo',original.version),e=>e.code==='55P03');
      await client.query('set lock_timeout=0');await peer.query('commit');
      await assert.rejects(save('Asia/Tokyo',original.version),e=>e.code==='40001');assert.equal((await save('UTC',original.version)).outcome,'already_applied');
    } finally {await client.query('set lock_timeout=0');await peer.query('rollback').catch(()=>{});await peer.end();}
  });
  await check('task generators wait for a pending timezone change and use the committed family day',async()=>{
    const original=await load(),peer=new pg.Client(client.connectionParameters);try {
      await peer.connect();await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:'family-timezone'})]);await peer.query('set role authenticated');await peer.query('begin');
      await peer.query("select public.set_family_timezone($1,'Pacific/Kiritimati',$2)",[family,original.version]);
      await client.query("set lock_timeout='100ms'");
      await assert.rejects(scalar('select public.generate_scheduled_tasks($1)',[child]),e=>e.code==='55P03');
      await assert.rejects(scalar('select public.generate_daily_wrong_review_task($1)',[child]),e=>e.code==='55P03');
      await client.query('set lock_timeout=0');await peer.query('commit');
      assert.equal((await load()).family_today,newDay);assert.equal(await scalar('select public.generate_scheduled_tasks($1)',[child]),0);
    } finally {await client.query('set lock_timeout=0');await peer.query('rollback').catch(()=>{});await peer.end();}
  });
}
