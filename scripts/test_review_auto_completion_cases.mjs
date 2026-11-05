import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function reviewAutoCompletionCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(),auth=()=>login(user,'review-auto');
  await client.query('reset role');await client.query('insert into auth.users values($1,$2)',[user,'auto-review@example.test']);
  await auth();await scalar("select public.onboard_family('Auto review','Asia/Shanghai','Initial',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  await scalar("select public.set_parent_pin($1,'2468')",[family]);await scalar("select public.verify_parent_pin($1,'2468')",[family]);
  const row=id=>scalar('select public.load_review_task($1)',[id]);
  const wallet=child=>scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]);
  const fixture=async(n=1)=>{
    const child=await scalar("select public.create_child($1,'Auto',1::smallint)",[family]),questions=[];
    for(let i=0;i<n;i++) questions.push(await scalar('select public.save_review_question($1,$2)',[child,{kind:'question',subject:'math',prompt:'2+2 = ?',answers:['4']}]));
    const snapshot=await scalar('select public.task_sync_snapshot($1)',[child]);
    const task=snapshot.tasks.find(t=>t.source_type==='automatic_wrong_review');
    return {child,questions,task,snapshot};
  };
  const start=f=>scalar('select public.start_task($1)',[f.task.id]);
  const answer=(f,index=0,text='4',key=randomUUID())=>scalar('select public.submit_review_answer($1,$2,$3,$4)',[f.task.id,f.questions[index],text,key]);
  const cmd=async(f,kind,previous=null,extra={})=>({command_id:randomUUID(),task_id:f.task.id,lease_id:f.snapshot.lease_id,
    expected_version:f.task.sync_version,predecessor_id:previous?.command_id??null,kind:'review_'+kind,occurred_at:await scalar('select clock_timestamp()::text'),...extra});
  const apply=c=>scalar('select public.apply_task_command($1)',[c]);
  let completed;
  await check('AC-11 daily snapshot finishes exactly on the last of three answers and stores each result',async()=>{
    const f=completed=await fixture(3);assert.equal(f.task.review_auto_complete,true);
    assert.equal(await scalar('select public.generate_daily_wrong_review_task($1)',[f.child]),f.task.id);
    await start(f);
    for(const [i,value] of [[0,'4'],[1,'wrong']]) {
      const result=await answer(f,i,value);assert.equal(result.task.status,'in_progress');
      assert.equal((await wallet(f.child)).coin_balance,0);assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[f.task.id]),0);
    }
    const result=await answer(f,2);assert.equal(result.task.status,'completed');assert.ok(result.task.completed_at);assert.equal(result.task.active_started_at,null);
    assert.equal(result.task.coin_reward,30);assert.equal(result.task.xp_reward,30);assert.equal((await wallet(f.child)).coin_balance,30);
    assert.equal(result.items.filter(i=>i.result).length,2);assert.equal(result.items.filter(i=>i.reward_coins===15).length,2);
    assert.equal(result.items.find(i=>!i.result).reward_coins,0);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[f.task.id]),2);
  });
  await check('automatic final-answer retries and legacy explicit-finish calls preserve one completion and reward',async()=>{
    const f=completed,before=await row(f.task.id),balance=await wallet(f.child);
    const key=randomUUID();assert.deepEqual(await answer(f,2,'4',key),before);assert.deepEqual(await answer(f,2,'4',key),before);
    await denied('select public.submit_review_answer($1,$2,$3,$4)',[f.task.id,f.questions[2],'changed',randomUUID()]);
    await scalar('select public.complete_task($1,$2)',[f.task.id,randomUUID()]);
    assert.deepEqual(await row(f.task.id),before);assert.deepEqual(await wallet(f.child),balance);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[f.task.id]),2);
  });
  await check('new all-wrong review completes with zero award while pre-migration snapshots remain explicit',async()=>{
    const wrong=await fixture();await start(wrong);assert.equal((await answer(wrong,0,'wrong')).task.status,'completed');assert.equal((await wallet(wrong.child)).coin_balance,0);assert.equal((await wallet(wrong.child)).xp,0);
    const old=await fixture();await client.query('reset role');await client.query('update public.task_instances set review_auto_complete=false where id=$1',[old.task.id]);await auth();
    assert.equal(await scalar('select public.generate_daily_wrong_review_task($1)',[old.child]),old.task.id);
    await start(old);assert.equal((await answer(old)).task.status,'in_progress');assert.equal((await wallet(old.child)).coin_balance,0);
    assert.equal((await row(old.task.id)).task.review_auto_complete,false);
    await scalar('select public.complete_task($1,$2)',[old.task.id,randomUUID()]);assert.equal((await wallet(old.child)).coin_balance,15);
  });
  await check('failed automatic settlement rolls back final grading progress version and reward atomically',async()=>{
    const f=await fixture();await start(f);await client.query('reset role');await client.query('update public.task_instances set minimum_seconds=60 where id=$1',[f.task.id]);await auth();
    const before=await row(f.task.id),question=await scalar('select to_jsonb(w) from public.wrong_questions w where id=$1',[f.questions[0]]);
    await denied('select public.submit_review_answer($1,$2,$3,$4)',[f.task.id,f.questions[0],'4',randomUUID()]);
    assert.deepEqual(await row(f.task.id),before);assert.deepEqual(await scalar('select to_jsonb(w) from public.wrong_questions w where id=$1',[f.questions[0]]),question);
    assert.equal((await wallet(f.child)).coin_balance,0);
    await client.query('reset role');assert.equal(await scalar('select count(*)::int from public.review_milestone_awards where child_id=$1',[f.child]),0);
    await client.query("update public.task_instances set active_started_at=now()-interval '61 seconds' where id=$1",[f.task.id]);await auth();
    const result=await answer(f);assert.equal(result.task.status,'completed');assert.ok(result.task.accumulated_seconds>=60);assert.equal((await wallet(f.child)).coin_balance,15);
  });
  await check('delayed offline final answer freezes duration at its validated occurrence and replay does not add waiting time',async()=>{
    const f=await fixture();await client.query('reset role');
    // Privileged clock fixtures emulate a lease and task cached two hours ago.
    await client.query("update public.task_instances set created_at=now()-interval '2 hours' where id=$1",[f.task.id]);
    await client.query("update public.task_sync_leases set issued_at=now()-interval '2 hours' where id=$1",[f.snapshot.lease_id]);
    // Updating the clock fixture also advances the generic task version.
    f.task.sync_version=await scalar('select sync_version from public.task_instances where id=$1',[f.task.id]);
    const began=await scalar("select (clock_timestamp()-interval '90 minutes')::text"),ended=await scalar("select ($1::timestamptz+interval '60 seconds')::text",[began]);await auth();
    const s=await cmd(f,'start',null,{occurred_at:began});const started=await apply(s);assert.equal(started.outcome,'applied',started.reason);
    const version=Number(await scalar('select content_version from public.wrong_questions where id=$1',[f.questions[0]]));
    const a=await cmd(f,'answer',s,{occurred_at:ended,question_id:f.questions[0],question_version:version,answer:'4'});
    const result=await apply(a);assert.equal(result.outcome,'applied',result.reason);assert.equal(result.task.status,'completed');assert.equal(result.task.accumulated_seconds,60);assert.equal(result.wallet.coin_balance,15);
    assert.equal((await apply(a)).task.accumulated_seconds,60);
    const done=await cmd(f,'complete',a,{occurred_at:ended});assert.equal((await apply(done)).outcome,'already_completed');assert.equal((await apply(done)).wallet.coin_balance,15);
    assert.equal((await row(f.task.id)).task.accumulated_seconds,60);
    const conflicting=await cmd(f,'answer',s,{occurred_at:ended,question_id:f.questions[0],question_version:a.question_version,answer:'wrong'});
    assert.equal((await apply(conflicting)).outcome,'conflict');
  });
  await check('two connections submitting the final answer simultaneously finish and award once',async()=>{
    const f=await fixture();await start(f);const peer=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});
    try {
      await peer.connect();await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:'auto-other-device'})]);await peer.query('set role authenticated');
      const [a,b]=await Promise.all([answer(f),peer.query('select public.submit_review_answer($1,$2,$3,$4) as result',[f.task.id,f.questions[0],'4',randomUUID()])]);
      assert.equal(a.task.status,'completed');assert.deepEqual(a,b.rows[0].result);assert.equal((await wallet(f.child)).coin_balance,15);
      assert.equal(await scalar('select review_attempts from public.wrong_questions where id=$1',[f.questions[0]]),1);
      assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[f.task.id]),2);
    } finally {await peer.end();}
  });
  await check('automatic completion cannot bypass access control private cutoff checks or missing answers',async()=>{
    const f=await fixture();
    await denied('select public.submit_review_answer($1,$2,$3,$4)',[f.task.id,f.questions[0],'4',randomUUID()]);
    for(const role of ['anon','service_role','authenticated']) {
      await client.query('reset role');await client.query('set role '+role);
      await denied('select public.submit_review_answer_and_complete($1,$2,$3,$4,now())',[f.task.id,f.questions[0],'4',randomUUID()]);
      await denied('select public.apply_task_command_before_membership($1)',[{}]);
    }
    await auth();assert.equal((await client.query('update public.task_instances set review_auto_complete=false where id=$1',[f.task.id])).rowCount,0);
    await login(otherUid);await denied('select public.submit_review_answer($1,$2,$3,$4)',[f.task.id,f.questions[0],'4',randomUUID()]);await auth();
    await denied("select public.complete_task($1,$2,'skip answers')",[f.task.id,randomUUID()]);await start(f);
    assert.equal((await answer(f)).task.status,'completed');
  });
  await check('online final-answer transaction serializes member removal and removed-member replays are denied',async()=>{
    const member=randomUUID(),f=await fixture();await start(f);await client.query('reset role');
    await client.query('insert into auth.users values($1,$2)',[member,'auto-member@example.test']);
    await client.query("insert into public.family_members(family_id,user_id,role) values($1,$2,'parent')",[family,member]);await auth();
    const peer=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});
    const sql='select public.resolve_family_member_removal($1,$2,$3,$4)',key=randomUUID(),payload={kind:'remove',user_id:member,version:1};
    try {
      await peer.connect();await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:member,role:'authenticated',session_id:'auto-member'})]);await peer.query('set role authenticated');await peer.query('begin');
      const result=await peer.query('select public.submit_review_answer($1,$2,$3,$4) as value',[f.task.id,f.questions[0],'4',randomUUID()]);assert.equal(result.rows[0].value.task.status,'completed');
      await client.query("set lock_timeout='100ms'");
      await assert.rejects(client.query(sql,[family,key,payload,'submit']),e=>e.code==='55P03');
      await client.query('set lock_timeout=0');await peer.query('commit');
      assert.equal((await scalar(sql,[family,key,payload,'submit'])).status,'applied');
      await assert.rejects(peer.query('select public.submit_review_answer($1,$2,$3,$4)',[f.task.id,f.questions[0],'4',randomUUID()]));
      assert.equal((await wallet(f.child)).coin_balance,15);assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[f.task.id]),2);
    } finally {await client.query('set lock_timeout=0');await peer.query('rollback').catch(()=>{});await peer.end();}
  });
  await check('automatic completion contract exports and deleted children cannot replay a final answer',async()=>{
    const f=completed;await client.query('reset role');const sections=await scalar('select public.child_export_source($1)',[f.child]);
    const tasks=sections.find(s=>s.name==='tasks');assert.ok(tasks.columns.includes('review_auto_complete'));assert.equal(tasks.rows.find(t=>t.id===f.task.id).review_auto_complete,true);
    await auth();const preview=await scalar('select public.preview_child_deletion($1)',[f.child]);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[f.child,randomUUID(),preview.counts]);
    await denied('select public.submit_review_answer($1,$2,$3,$4)',[f.task.id,f.questions[2],'4',randomUUID()]);await login();
  });
}
