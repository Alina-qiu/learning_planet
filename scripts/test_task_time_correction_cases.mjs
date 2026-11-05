import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function taskTimeCorrectionCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(),member=randomUUID();
  await client.query('reset role');
  for(const [id,name] of [[user,'owner'],[member,'parent']]) await client.query('insert into auth.users values($1,$2)',[id,`time-${name}@example.test`]);
  const auth=()=>login(user,'time-corrections');await auth();
  await scalar("select public.onboard_family('Time corrections','Asia/Shanghai','Child',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  const today=await scalar('select public.family_today($1)',[child]);
  await client.query("select public.set_parent_pin($1,'3579')",[family]);
  await client.query('reset role');
  await client.query("insert into public.family_members(family_id,user_id,role) values($1,$2,'parent')",[family,member]);
  const make=async(status='paused',source='parent_template')=>{
    await client.query('reset role');
    const id=await scalar(`insert into public.task_instances(child_id,title,due_date,source_type,status,accumulated_seconds,completed_at,active_started_at,idempotency_key)
      values($1,'Correct my timer',$2,$3,$4::public.task_status,120,case when $4::public.task_status='completed' then now() else null end,case when $4::public.task_status='in_progress' then now() else null end,$5) returning id`,[child,today,source,status,randomUUID()]);
    await auth();return id;
  };
  const task=await make('completed');
  const read=id=>scalar('select public.task_time_context($1)',[id]);
  const row=id=>scalar('select to_jsonb(t) from public.task_instances t where id=$1',[id]);
  const sql='select public.correct_task_time($1,$2,$3,$4,$5)';
  const save=(id,version,seconds,key=randomUUID(),reason='误记时长，按实际学习时间纠正')=>scalar(sql,[id,key,version,seconds,reason]);
  await check('time correction requires current session PIN for reads writes and replays',async()=>{
    await denied('select public.task_time_context($1)',[task]);await denied(sql,[task,randomUUID(),0,60,'No PIN']);
    await client.query("select public.verify_parent_pin($1,'3579')",[family]);
    const context=await read(task);assert.equal(context.seconds,120);assert.equal(context.version,0);assert.equal(context.owner_id,user);
    await login(user,'different-session');await denied('select public.task_time_context($1)',[task]);await auth();
    await login(otherUid);await denied('select public.task_time_context($1)',[task]);await denied(sql,[task,randomUUID(),0,60,'Foreign']);await auth();
    for(const role of ['anon','service_role']) {await client.query('reset role');await client.query('set role '+role);await denied('select public.task_time_context($1)',[task]);}
    await auth();await denied('select * from public.task_time_correction_receipts');
  });
  await check('completed time correction audits before and after once without changing completion or money',async()=>{
    const before=await row(task),wallet=await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]);
    const key=randomUUID(),first=await save(task,0,59,key);assert.equal(first.applied_version,1);assert.equal(first.current.seconds,59);
    assert.deepEqual(await save(task,0,59,key),first);
    assert.deepEqual(await row(task),{...before,accumulated_seconds:59,sync_version:1});
    assert.deepEqual(await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]),wallet);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[child]),0);
    const audit=await scalar("select details from public.audit_logs where action='task.time_corrected' and target_id=$1",[task]);
    assert.equal(audit.before_seconds,120);assert.equal(audit.after_seconds,59);assert.ok(audit.reason);
    await save(task,1,180);
    const replay=await save(task,0,59,key);assert.equal(replay.applied_version,1);assert.equal(replay.current.seconds,180);assert.equal(replay.current.version,2);
    await denied(sql,[task,key,0,60,'Changed payload']);await denied(sql,[task,randomUUID(),0,60,'Stale version']);
    await login(user,'without-pin');await denied(sql,[task,key,0,59,'误记时长，按实际学习时间纠正']);await auth();
    const report=await scalar("select public.learning_report($1,'day',$2)",[child,today]);
    assert.equal(report.tasks.effective_seconds,180);assert.equal(report.tasks.completed,1);
  });
  await check('time correction validates input, rejects live timers and supports paused review and abandoned history',async()=>{
    for(const args of [
      [task,null,2,10,'reason'],[task,randomUUID(),null,10,'reason'],[task,randomUUID(),-1,10,'reason'],
      [task,randomUUID(),2,-1,'reason'],[task,randomUUID(),2,null,'reason'],[task,randomUUID(),2,10,' '],
      [task,randomUUID(),2,10,'🪐'.repeat(501)],[task,randomUUID(),2,180,'unchanged'],
      [task,randomUUID(),2,10,'\n\t'],[task,randomUUID(),2,2147483648,'Out of bounds'],
    ]) await denied(sql,args);
    const live=await make('in_progress');await denied(sql,[live,randomUUID(),0,30,'Pause first']);
    for(const [status,source] of [['paused','parent_template'],['abandoned','parent_template'],['paused','automatic_wrong_review']]) {
      const id=await make(status,source),before=await row(id);const corrected=await save(id,0,0);
      assert.equal(corrected.current.status,status);assert.equal(corrected.current.seconds,0);
      assert.deepEqual(await row(id),{...before,accumulated_seconds:0,sync_version:1});
    }
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[child]),0);
  });
  await check('concurrent time corrections compare versions and same-request replays audit only once',async()=>{
    const id=await make(),a=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'}),b=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});
    try {
      for(const peer of [a,b]) {await peer.connect();await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:'time-corrections'})]);await peer.query('set role authenticated');}
      const races=await Promise.allSettled([a.query(sql,[id,randomUUID(),0,50,'First']),b.query(sql,[id,randomUUID(),0,70,'Second'])]);
      assert.equal(races.filter(r=>r.status==='fulfilled').length,1);
      assert.equal(races.find(r=>r.status==='rejected').reason.code,'40001');
      const key=randomUUID();const results=await Promise.all([a.query(sql,[id,key,1,90,'Replay']),b.query(sql,[id,key,1,90,'Replay'])]);
      assert.deepEqual(results[0].rows,results[1].rows);
      assert.equal((await read(id)).version,2);assert.equal((await read(id)).seconds,90);
      assert.equal(await scalar("select count(*)::int from public.audit_logs where target_id=$1 and action='task.time_corrected'",[id]),2);
    } finally {await a.end();await b.end();}
  });
  await check('corrected time fences old offline commands and remains in exports with its audit',async()=>{
    const id=await make();const snapshot=await scalar('select public.task_sync_snapshot($1)',[child]);
    await save(id,0,45);
    const command={task_id:id,command_id:randomUUID(),lease_id:snapshot.lease_id,expected_version:0,kind:'resume',occurred_at:new Date().toISOString()};
    const result=await scalar('select public.apply_task_command($1)',[command]);
    assert.equal(result.outcome,'conflict');assert.equal(result.task.accumulated_seconds,45);assert.equal((await read(id)).seconds,45);
    await client.query('reset role');
    const sections=await scalar('select public.child_export_source($1)',[child]);assert.equal(sections.length,40);
    assert.equal(sections.find(s=>s.name==='tasks').rows.find(r=>r.id===id).accumulated_seconds,45);
    assert.ok(sections.find(s=>s.name==='audit_logs').rows.some(r=>r.target_id===id&&r.details.after_seconds===45));
    assert.ok(sections.every(s=>s.name!=='task_time_correction_receipts'));
    await client.query('delete from public.task_instances where id=$1',[id]);
    assert.equal(await scalar('select count(*)::int from public.task_time_correction_receipts where task_id=$1',[id]),0);
    await auth();await denied('select public.task_time_context($1)',[id]);
  });
  await check('ordinary authorized family parents may correct; removal and actual PIN expiry prevent it',async()=>{
    await login(member,'member-time');await client.query("select public.verify_parent_pin($1,'3579')",[family]);
    await save(task,2,200);assert.equal((await read(task)).seconds,200);
    await client.query('reset role');await client.query('delete from public.family_members where family_id=$1 and user_id=$2',[family,member]);
    await login(member,'member-time');await denied(sql,[task,randomUUID(),3,300,'Removed']);
    await client.query('reset role');await client.query("update public.parent_authorizations set expires_at=clock_timestamp()-interval '1 second' where family_id=$1",[family]);
    await auth();await denied(sql,[task,randomUUID(),3,300,'Expired']);
    await client.query('reset role');await client.query('begin');
    try {
      await client.query("update public.parent_authorizations set expires_at=now()+interval '0.05 seconds' where family_id=$1 and user_id=$2",[family,user]);
      await auth();await client.query('select pg_sleep(0.08)');
      assert.equal(await scalar('select public.has_parent_authorization($1)',[family]),true);
      await denied(sql,[task,randomUUID(),3,300,'Expired during transaction']);
    } finally {await client.query('rollback');}
  });
}
