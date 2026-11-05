import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function taskPreferencesCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID();
  const service=async()=>{await client.query('reset role');await client.query("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false)");await client.query('set role service_role');};
  await client.query('reset role');await client.query('insert into auth.users values($1,$2)',[user,'task-preferences@example.test']);
  const auth=()=>login(user,'preferences-session');
  await auth();await client.query("select public.onboard_family('Task family','Asia/Shanghai','Priorities',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await client.query("select public.set_parent_pin($1,'2468')",[family]);await client.query("select public.verify_parent_pin($1,'2468')",[family]);
  const today=await scalar('select public.family_today($1)',[child]);
  const tomorrow=await scalar('select ($1::date+1)::text',[today]);
  const base={title:'Read',recurrence:'daily',starts_on:today,ends_on:tomorrow,start_time:'16:00',due_time:'20:00',coins:10,xp:20,minimum_seconds:0,expected_minutes:20,priority:'recommended'};
  const save=(kid,config,id=null)=>scalar('select public.save_task_schedule($1,$2,$3)',[kid,config,id]);
  const newChild=(name)=>scalar('select public.create_child($1,$2,1::smallint)',[family,name]);
  const one=async(kid,config={})=>{
    const template=await save(kid,{...base,...config});
    return {template,task:await scalar('select id from public.task_instances where template_id=$1 and due_date=$2',[template,today])};
  };
  let template,task;
  await check('priority and target are validated and saved into immutable instances, with no reward multiplier',async()=>{
    for(const priority of ['required','recommended','challenge']) {
      const created=await one(child,{priority});
      const row=await scalar('select to_jsonb(t) from public.task_instances t where id=$1',[created.task]);
      assert.equal(row.task_priority,priority);assert.equal(row.expected_minutes,20);
      assert.equal(row.coin_reward,10);assert.equal(row.xp_reward,20);
      if(priority==='required') ({template,task}=created);
    }
    await save(child,{...base,priority:'challenge',expected_minutes:40},template);
    assert.equal(await scalar('select task_priority from public.task_instances where id=$1',[task]),'required');
    assert.equal(await scalar('select expected_minutes from public.task_instances where id=$1',[task]),20);
    await service();await client.query('select public.generate_scheduled_tasks($1,$2)',[child,tomorrow]);await auth();
    const future=await scalar('select to_jsonb(t) from public.task_instances t where template_id=$1 and due_date=$2',[template,tomorrow]);
    assert.equal(future.task_priority,'challenge');assert.equal(future.expected_minutes,40);
    const legacy={...base};delete legacy.priority;delete legacy.expected_minutes;
    await save(child,legacy,template);
    assert.equal(await scalar('select task_priority from public.task_templates where id=$1',[template]),'challenge');
    assert.equal(await scalar('select expected_minutes from public.task_templates where id=$1',[template]),40);
    for(const bad of [{priority:'punishment'},{expected_minutes:0},{expected_minutes:1441},{minimum_seconds:301,expected_minutes:5}]) {
      await denied('select public.save_task_schedule($1,$2)',[child,{...base,...bad}]);
    }
    await login(user,'no-pin');await denied('select public.save_task_schedule($1,$2)',[child,base]);await auth();
    const challenge=await scalar('select public.create_daily_challenge($1,$2,$3,0)',[child,randomUUID(),'Daily challenge']);
    assert.equal(await scalar('select task_priority from public.task_instances where id=$1',[challenge]),'challenge');
    assert.equal(await scalar('select coin_reward from public.task_instances where id=$1',[challenge]),30);
  });
  const abandonedChild=await newChild('Abandon timing'),a=await one(abandonedChild);
  await check('abandon ends timing without rewards or penalties, is idempotent, and remains in report denominator',async()=>{
    await client.query('select public.start_task($1)',[a.task]);
    await client.query('reset role');await client.query("update public.task_instances set accumulated_seconds=20,active_started_at=now()-interval '90 seconds' where id=$1",[a.task]);await auth();
    await client.query('select public.abandon_task($1)',[a.task]);
    let row=await scalar('select to_jsonb(t) from public.task_instances t where id=$1',[a.task]);
    assert.equal(row.status,'abandoned');assert.equal(row.active_started_at,null);assert.ok(row.accumulated_seconds>=110&&row.accumulated_seconds<115);
    const seconds=row.accumulated_seconds,version=row.sync_version;
    await client.query('select public.abandon_task($1)',[a.task]);
    row=await scalar('select to_jsonb(t) from public.task_instances t where id=$1',[a.task]);
    assert.equal(row.accumulated_seconds,seconds);assert.equal(row.sync_version,version);
    assert.equal(await scalar('select coin_balance+xp from public.wallets where child_id=$1',[abandonedChild]),0);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[abandonedChild]),0);
    assert.equal(await scalar("select count(*)::int from public.audit_logs where action='task.abandon' and target_id=$1",[a.task]),1);
    const report=await scalar("select public.learning_report($1,'day')",[abandonedChild]);
    assert.equal(report.tasks.expected,1);assert.equal(report.tasks.completed,0);assert.equal(report.tasks.effective_seconds,seconds);
    await denied('select public.start_task($1)',[a.task]);await denied('select public.resume_task($1)',[a.task]);
    await denied("select public.complete_task($1,'bad')",[a.task]);await denied('select public.abandon_task_internal($1,now())',[a.task]);
    await login(otherUid);await denied('select public.abandon_task($1)',[a.task]);
    await assert.rejects(client.query('select * from public.load_task_reminders($1)',[abandonedChild]),{code:'42501'});
    await auth();
  });
  await check('parent correction of abandoned task requires PIN and reason and pays only once',async()=>{
    await login(user,'no-pin');await denied("select public.complete_task($1,'fix','家长确认实际已完成')",[a.task]);await auth();
    await denied("select public.complete_task($1,'fix','  ')",[a.task]);
    await client.query("select public.complete_task($1,'fix','实际已完成，纠正误触')",[a.task]);
    await client.query("select public.complete_task($1,'retry','实际已完成，纠正误触')",[a.task]);
    assert.equal(await scalar('select status from public.task_instances where id=$1',[a.task]),'completed');
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[abandonedChild]),10);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[a.task]),2);
    await denied('select public.abandon_task($1)',[a.task]);
    assert.equal(await scalar("select count(*)::int from public.audit_logs where action='task.manual_complete' and target_id=$1",[a.task]),1);
  });
  const offlineChild=await newChild('Offline abandon'),o=await one(offlineChild);
  await check('offline abandon uses bounded lease/version, stable command receipt and terminal conflicts',async()=>{
    const snapshot=await scalar('select public.task_sync_snapshot($1)',[offlineChild]);
    const command={command_id:randomUUID(),task_id:o.task,kind:'abandon',expected_version:snapshot.tasks.find(t=>t.id===o.task).sync_version,
      lease_id:snapshot.lease_id,occurred_at:await scalar('select clock_timestamp()::text')};
    const future={...command,command_id:randomUUID(),occurred_at:'2099-01-01T00:00:00Z'};
    assert.equal((await scalar('select public.apply_task_command($1)',[future])).outcome,'conflict');
    assert.equal((await scalar('select public.apply_task_command($1)',[{...command,command_id:randomUUID(),expected_version:999}])).outcome,'conflict');
    const first=await scalar('select public.apply_task_command($1)',[command]);assert.equal(first.outcome,'applied');assert.equal(first.task.status,'abandoned');
    assert.equal((await scalar('select public.apply_task_command($1)',[command])).task.sync_version,first.task.sync_version);
    await denied('select public.apply_task_command($1)',[{...command,kind:'complete'}]);
    assert.equal((await scalar('select public.apply_task_command($1)',[{...command,command_id:randomUUID()}])).outcome,'already_abandoned');
    assert.equal((await scalar('select public.apply_task_command($1)',[{...command,command_id:randomUUID(),kind:'start'}])).outcome,'conflict');
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[offlineChild]),0);
  });
  const raceChild=await newChild('Race'),r=await one(raceChild);
  await client.query('select public.start_task($1)',[r.task]);
  await check('two devices completing and abandoning concurrently cannot both mutate the final state or duplicate rewards',async()=>{
    const other=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});await other.connect();
    try {
      await other.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:'race-device'})]);
      await other.query('set role authenticated');
      const results=await Promise.allSettled([client.query('select public.abandon_task($1)',[r.task]),other.query("select public.complete_task($1,'race')",[r.task])]);
      assert.equal(results.filter(result=>result.status==='fulfilled').length,1);
      const status=await scalar('select status from public.task_instances where id=$1',[r.task]);
      assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[r.task]),status==='completed'?2:0);
      assert.equal(await scalar('select active_started_at from public.task_instances where id=$1',[r.task]),null);
    } finally {await other.end();}
  });
  const reviewChild=await newChild('Partial review');let reviewTask,q1,q2;
  await check('abandoned automatic review preserves submitted grading and leaves unanswered questions due without completion payout',async()=>{
    await client.query('reset role');
    const questions=(await client.query(`insert into public.wrong_questions(child_id,subject,final_text,review_due_at)
      values($1,'math','1+1',now()-interval '1 day'),($1,'math','2+2',now()-interval '1 day') returning id`,[reviewChild])).rows.map(q=>q.id);
    [q1,q2]=questions;for(const q of questions) await client.query("insert into public.wrong_question_answers values($1,array['2'],'answer')",[q]);
    await auth();reviewTask=await scalar('select public.generate_daily_wrong_review_task($1)',[reviewChild]);
    assert.equal(await scalar('select expected_minutes from public.task_instances where id=$1',[reviewTask]),4);
    await client.query('select public.start_task($1)',[reviewTask]);await client.query("select public.submit_review_answer($1,$2,'2',$3)",[reviewTask,q1,randomUUID()]);
    const before=await scalar('select to_jsonb(q) from public.wrong_questions q where id=$1',[q1]);
    const snapshot=await scalar('select public.task_sync_snapshot($1)',[reviewChild]);
    const command={command_id:randomUUID(),task_id:reviewTask,kind:'abandon',expected_version:snapshot.tasks.find(t=>t.id===reviewTask).sync_version,
      lease_id:snapshot.lease_id,occurred_at:await scalar('select clock_timestamp()::text')};
    assert.equal((await scalar('select public.apply_task_command($1)',[command])).outcome,'applied');
    assert.deepEqual(await scalar('select to_jsonb(q) from public.wrong_questions q where id=$1',[q1]),before);
    assert.equal(await scalar('select review_attempts from public.wrong_questions where id=$1',[q2]),0);
    await denied("select public.submit_review_answer($1,$2,'2',$3)",[reviewTask,q2,randomUUID()]);
    await denied("select public.complete_task($1,'skip','parent bypass')",[reviewTask]);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[reviewChild]),0);
    assert.equal(await scalar('select public.generate_daily_wrong_review_task($1)',[reviewChild]),reviewTask);
    const loaded=await scalar('select public.load_review_task($1)',[reviewTask]);assert.equal(loaded.items.filter(i=>i.result===true).length,1);
    await service();const next=await scalar('select public.generate_daily_wrong_review_task($1,$2)',[reviewChild,tomorrow]);
    assert.notEqual(next,reviewTask);await auth();
  });
  await check('source cleanup erases abandoned review content while preserving its terminal state and counting only active reviews',async()=>{
    const preview=await scalar("select public.preview_question_cleanup($1,'questions',$2)",[reviewChild,[q2]]);
    assert.equal(preview.unfinished_reviews,1);
    await scalar("select public.request_question_cleanup($1,'questions',$2,$3,'永久删除')",[reviewChild,[q2],randomUUID()]);
    assert.equal(await scalar('select status from public.task_instances where id=$1',[reviewTask]),'abandoned');
    const loaded=await scalar('select public.load_review_task($1)',[reviewTask]);
    const removed=loaded.items.find(i=>i.wrong_question_id===q2);
    assert.equal(removed.source_deleted,true);assert.equal(removed.prompt,null);
  });
  const reminderChild=await newChild('Merged reminders'),remA=await one(reminderChild,{title:'Abandon me'}),remB=await one(reminderChild,{title:'Keep me'});
  await client.query("insert into public.reminder_settings(child_id,quiet_start,quiet_end) values($1,'00:00','00:00')",[reminderChild]);
  await check('abandon removes only that task from merged reminders and does not cancel future recurring instances',async()=>{
    const before=(await client.query('select * from public.load_task_reminders($1)',[reminderChild])).rows;
    assert.ok(before.some(r=>r.tasks.some(t=>t.task_id===remA.task)&&r.tasks.some(t=>t.task_id===remB.task)));
    await client.query('select public.abandon_task($1)',[remA.task]);
    const after=(await client.query('select * from public.load_task_reminders($1)',[reminderChild])).rows;
    assert.ok(after.some(r=>r.tasks.some(t=>t.task_id===remB.task)));
    assert.ok(after.every(r=>r.tasks.every(t=>t.task_id!==remA.task)));
    assert.ok(after.some(r=>r.tasks.some(t=>t.template_id===remA.template&&t.due_date===tomorrow)));
  });
  const planChild=await newChild('Plan abandon'),p=await one(planChild,{long_plan:true,minimum_rate:1,bonus_coins:50,bonus_xp:50,stages:[{completed_count:1,coins:5,xp:5}]});
  await check('voluntary abandonment remains in plan denominator and awards no stage or completion bonus',async()=>{
    const plan=await scalar('select id from public.long_plans where template_id=$1',[p.template]);
    await client.query('select public.abandon_task($1)',[p.task]);
    const progress=(await client.query('select * from public.long_plan_progress($1)',[plan])).rows[0];
    assert.equal(Number(progress.expected),2);assert.equal(Number(progress.completed),0);assert.equal(Number(progress.rate),0);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[planChild]),0);
    await denied('select public.save_task_schedule($1,$2,$3)',[planChild,{...base,priority:'challenge'},p.template]);
    await client.query("select public.complete_task($1,'correct','家长确认实际完成')",[p.task]);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[planChild]),15);
  });
  await login();
}
