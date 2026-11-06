import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function reviewSnoozeCases({client,scalar,login,denied,check}) {
  const user=randomUUID(),auth=()=>login(user,'review-snooze');
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)',[user,'snooze@example.test']);
  const zone=await scalar("select name from pg_timezone_names where name like 'Etc/GMT%' and extract(hour from now() at time zone name)=12 limit 1");
  assert.ok(zone);
  await auth();await client.query("select public.onboard_family('Snooze',$1,'Review',1::smallint)",[zone]);
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await client.query("select public.set_parent_pin($1,'2468')",[family]);
  await client.query("select public.verify_parent_pin($1,'2468')",[family]);
  const question=await scalar('select public.save_review_question($1,$2)',[child,
    {kind:'pinyin',subject:'chinese',prompt:'银行',answers:['yín háng'],context:'去银行存钱',pronunciation_confirmed:true}]);
  const overview=await scalar('select public.review_overview($1)',[child]),task=overview.task_id;
  const set=(delay,revision,key=randomUUID())=>scalar('select public.set_review_reminder($1,$2,$3,$4)',[task,delay,key,revision]);
  const state=()=>scalar('select public.review_reminder_state($1)',[task]);
  const reminders=()=>client.query('select * from public.load_task_reminders($1)',[child]);
  let saved,originalKey=randomUUID();
  await check('review snooze is idempotent without PIN and leaves task, snapshots, mastery and wallet unchanged',async()=>{
    assert.equal(overview.reminder.revision,0);assert.equal(overview.reminder.allowed,true);
    const before=await scalar('select to_jsonb(t) from public.task_instances t where id=$1',[task]);
    const q=await scalar('select to_jsonb(w) from public.wrong_questions w where id=$1',[question]);
    const items=await scalar('select public.load_review_task($1)',[task]);
    await login(user,'without-pin');
    saved=await set(15,0,originalKey);assert.equal(saved.revision,1);assert.ok(saved.remind_local.endsWith(zone));
    assert.deepEqual(await set(15,0,originalKey),saved);
    assert.deepEqual(await scalar('select to_jsonb(t) from public.task_instances t where id=$1',[task]),before);
    assert.deepEqual(await scalar('select to_jsonb(w) from public.wrong_questions w where id=$1',[question]),q);
    assert.deepEqual(await scalar('select public.load_review_task($1)',[task]),items);
    assert.equal(await scalar('select coin_balance+xp from public.wallets where child_id=$1',[child]),0);
    assert.equal(await scalar("select count(*)::int from public.audit_logs where action='review_reminder_changed' and target_id=$1",[task]),0); // PIN-restricted audit reads
    await auth();
    assert.equal(await scalar("select count(*)::int from public.audit_logs where action='review_reminder_changed' and target_id=$1",[task]),1);
  });
  await check('competing review snoozes use revisions and cancellation cannot be undone by a stale retry',async()=>{
    await assert.rejects(set(30,0),{code:'40001'});
    await denied('select public.set_review_reminder($1,30,$2,0)',[task,originalKey]);
    const peers=await Promise.all([1,2].map(async()=>{
      const peer=new pg.Client(client.connectionParameters);
      await peer.connect();await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:randomUUID()})]);
      await peer.query('set role authenticated');return peer;
    }));
    try {
      const results=await Promise.allSettled(peers.map((peer,index)=>peer.query('select public.set_review_reminder($1,$2,$3,1)',[task,index===0?30:60,randomUUID()])));
      assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
      assert.equal(results.find(r=>r.status==='rejected').reason.code,'40001');
    } finally {await Promise.all(peers.map(peer=>peer.end()));}
    saved=await state();assert.equal(saved.revision,2);
    assert.equal((await reminders()).rows.filter(r=>r.tasks.some(t=>t.task_id===task)).length,1);
    const cancelled=await set(0,2);assert.equal(cancelled.remind_at,null);assert.equal(cancelled.revision,3);
    await assert.rejects(set(15,0,originalKey),{code:'40001'});
    assert.equal((await reminders()).rows.length,0);
  });
  await check('snooze rejects disabled reminders, quiet hours, invalid delays and crossing the family day',async()=>{
    for(const delay of [-1,1,120,null]) await assert.rejects(set(delay,3));
    await client.query("insert into public.reminder_settings(child_id,enabled,quiet_start,quiet_end) values($1,false,'00:00','00:00')",[child]);
    await assert.rejects(set(15,3),/家长已关闭/);
    await client.query("update public.reminder_settings set enabled=true,quiet_start='00:00',quiet_end='23:59' where child_id=$1",[child]);
    await assert.rejects(set(15,3),/安静时段/);
    await client.query("update public.reminder_settings set quiet_start='00:00',quiet_end='00:00' where child_id=$1",[child]);
    const night=await scalar("select name from pg_timezone_names where name like 'Etc/GMT%' and extract(hour from now() at time zone name)=23 limit 1");
    await client.query('reset role');
    await client.query('update public.families set timezone=$1 where id=$2',[night,family]);
    await client.query('update public.task_instances set due_date=(now() at time zone $1)::date where id=$2',[night,task]);
    await auth();await assert.rejects(set(60,3),/跨到次日/);
    await client.query('reset role');
    await client.query('update public.families set timezone=$1 where id=$2',[zone,family]);
    await client.query('update public.task_instances set due_date=(now() at time zone $1)::date where id=$2',[zone,task]);
    await auth();assert.equal((await state()).revision,3);
  });
  await check('snooze merges with normal reminders and respects current quiet policy and terminal cancellation',async()=>{
    saved=await set(15,3);
    await client.query('reset role');
    await client.query("insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key,scheduled_at) values($1,'Same slot',(now() at time zone $2)::date,'parent_template',$3,$4)",[child,zone,randomUUID(),saved.remind_at]);
    await auth();
    const merged=(await reminders()).rows.find(r=>new Date(r.remind_at).getTime()===new Date(saved.remind_at).getTime());
    assert.equal(merged.tasks.length,2);assert.equal(merged.delivery_policy.timezone,zone);
    await client.query("update public.reminder_settings set quiet_end='23:59' where child_id=$1",[child]);
    assert.equal((await reminders()).rows.length,0);
    await client.query("update public.reminder_settings set quiet_end='00:00' where child_id=$1",[child]);
    await client.query('select public.abandon_task($1)',[task]);
    assert.equal((await state()).remind_at,null);assert.equal((await state()).allowed,false);
    assert.ok((await reminders()).rows.every(r=>r.tasks.every(t=>t.task_id!==task)));
    await assert.rejects(set(15,5),/已结束/);
  });
  await check('snooze storage is private, included in child export and cascades with deletion',async()=>{
    await denied('select * from public.review_reminder_requests');
    const preview=await scalar('select public.preview_child_export($1)',[child]);
    assert.equal(preview.counts.review_reminders,1);
    await login();await denied('select public.review_reminder_state($1)',[task]);
    await denied('select public.set_review_reminder($1,15,$2,5)',[task,randomUUID()]);
    await client.query('reset role');await client.query('set role anon');await denied('select public.review_reminder_state($1)',[task]);
    await client.query('reset role');await client.query('delete from public.task_instances where id=$1',[task]);
    assert.equal(await scalar('select count(*)::int from public.review_reminder_requests where task_id=$1',[task]),0);
    await login();
  });
}
