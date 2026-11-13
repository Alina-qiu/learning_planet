import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function reviewConfidenceCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(),auth=()=>login(user,'review-confidence');
  await client.query('reset role');await client.query('insert into auth.users values($1,$2)',[user,'confidence@example.test']);
  await auth();await scalar("select public.onboard_family('Confidence','Asia/Shanghai','Initial',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  await scalar("select public.set_parent_pin($1,'2468')",[family]);await scalar("select public.verify_parent_pin($1,'2468')",[family]);
  const load=id=>scalar('select public.load_review_task($1)',[id]);
  const question=id=>scalar('select to_jsonb(w) from public.wrong_questions w where id=$1',[id]);
  const wallet=child=>scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]);
  const fixture=async(n=1,{generate=true}={})=>{
    const child=await scalar("select public.create_child($1,'Confidence',1::smallint)",[family]),questions=[];
    for(let i=0;i<n;i++) questions.push(await scalar('select public.save_review_question($1,$2)',[child,{kind:'question',subject:'math',prompt:`2+2 = ? (${i})`,answers:['4']}]));
    if(!generate)return {child,questions};
    const snapshot=await scalar('select public.task_sync_snapshot($1)',[child]);
    return {child,questions,snapshot,task:snapshot.tasks.find(t=>t.source_type==='automatic_wrong_review')};
  };
  const start=f=>scalar('select public.start_task($1)',[f.task.id]);
  const answer=(f,confidence=1,index=0,text='4',id=randomUUID())=>scalar('select public.submit_review_answer($1,$2,$3,$4,$5::smallint)',[f.task.id,f.questions[index],text,id,confidence]);
  const oldAnswer=f=>scalar('select public.submit_review_answer($1,$2,$3,$4)',[f.task.id,f.questions[0],'4',randomUUID()]);
  const cmd=async(f,kind,previous=null,extra={})=>({command_id:randomUUID(),task_id:f.task.id,lease_id:f.snapshot.lease_id,
    expected_version:f.task.sync_version,predecessor_id:previous?.command_id??null,kind:'review_'+kind,occurred_at:await scalar('select clock_timestamp()::text'),...extra});
  const apply=c=>scalar('select public.apply_task_command($1)',[c]);

  await check('self-assessment records before grading completion and never changes rewards or an already answered assessment',async()=>{
    const f=await fixture(3);await start(f);
    assert.equal((await question(f.questions[0])).last_answer_confidence,null);
    const first=await answer(f,1),item=first.items.find(i=>i.wrong_question_id===f.questions[0]);
    assert.equal(item.answer_confidence,1);assert.equal(item.previous_answer_confidence,null);
    assert.equal((await question(f.questions[0])).last_answer_confidence,1);
    await denied('select public.submit_review_answer($1,$2,$3,$4,$5::smallint)',[f.task.id,f.questions[0],'4',randomUUID(),3]);
    assert.equal((await oldAnswer(f)).items.find(i=>i.wrong_question_id===f.questions[0]).answer_confidence,1);
    await answer(f,3,1);const final=await answer(f,2,2);
    assert.equal(final.task.status,'completed');assert.equal((await wallet(f.child)).coin_balance,45);assert.equal((await wallet(f.child)).xp,45);
    assert.deepEqual(await answer(f,1),final);
    const wrong=await fixture();await start(wrong);
    const beforeWrong=await question(wrong.questions[0]),incorrect=await answer(wrong,3,0,'5');
    assert.equal(incorrect.items[0].result,false);assert.equal(incorrect.items[0].answer_confidence,3);
    assert.equal((await question(wrong.questions[0])).last_answer_confidence,3);
    assert.equal((await question(wrong.questions[0])).wrong_count,beforeWrong.wrong_count+1);
    assert.equal((await wallet(wrong.child)).coin_balance,0);assert.equal((await wallet(wrong.child)).xp,0);
  });
  await check('invalid self-assessment and unauthorized writes cannot change task question or wallet',async()=>{
    const f=await fixture();await start(f);const before=await load(f.task.id),q=await question(f.questions[0]);
    for(const value of [0,4,-1]) await denied('select public.submit_review_answer($1,$2,$3,$4,$5::smallint)',[f.task.id,f.questions[0],'4',randomUUID(),value]);
    await denied('update public.wrong_questions set last_answer_confidence=1 where id=$1',[f.questions[0]]);
    await denied('update public.task_review_items set answer_confidence=1 where task_instance_id=$1',[f.task.id]);
    await denied('select public.submit_review_answer_with_confidence($1,$2,$3,$4,now(),1::smallint)',[f.task.id,f.questions[0],'4',randomUUID()]);
    await login(otherUid);await denied('select public.submit_review_answer($1,$2,$3,$4,1::smallint)',[f.task.id,f.questions[0],'4',randomUUID()]);await auth();
    assert.deepEqual(await load(f.task.id),before);assert.deepEqual(await question(f.questions[0]),q);assert.equal((await wallet(f.child)).coin_balance,0);
  });
  await check('offline answer confidence survives final settlement replay and is part of the command fingerprint',async()=>{
    const f=await fixture(),s=await cmd(f,'start');assert.equal((await apply(s)).outcome,'applied');
    const version=(await load(f.task.id)).items[0].question_version;
    const a=await cmd(f,'answer',s,{question_id:f.questions[0],question_version:version,answer:'4',answer_confidence:2});
    const result=await apply(a);assert.equal(result.outcome,'applied',JSON.stringify(result));assert.equal(result.review.task.status,'completed');
    assert.equal(result.review.items[0].answer_confidence,2);assert.equal((await question(f.questions[0])).last_answer_confidence,2);
    const replay=await apply(a);assert.deepEqual(replay.review,result.review);assert.deepEqual(replay.wallet,result.wallet);assert.equal(replay.outcome,result.outcome);assert.equal((await wallet(f.child)).coin_balance,15);
    await denied('select public.apply_task_command($1)',[{...a,answer_confidence:3}]);
    for(const value of [null,'1',true,1.5,0,4]) await denied('select public.apply_task_command($1)',[{...a,command_id:randomUUID(),answer_confidence:value}]);
    await denied('select public.apply_task_command($1)',[{...s,command_id:randomUUID(),answer_confidence:1}]);
    assert.equal((await question(f.questions[0])).last_answer_confidence,2);
  });
  await check('daily queue orders by family overdue day then errors then confidence with stable unknowns and a frozen ten-item snapshot',async()=>{
    const f=await fixture(13,{generate:false});
    const rules=[[-2,22,0,3],[-1,22,9,3],[-1,0,8,1],[0,22,0,1],[0,0,0,2],[0,12,0,3],
      [0,0,0,null],[0,0,0,null],[0,0,0,null],[0,0,0,null],[0,0,0,null],[0,0,0,null],[1,0,99,1]];
    await client.query('reset role');
    for(let i=0;i<rules.length;i++) {
      const [days,hours,errors,confidence]=rules[i];
      await client.query("update public.wrong_questions set review_due_at=((public.family_today($2)::date+$3::integer)::timestamp at time zone 'Asia/Shanghai')+make_interval(hours=>$4),wrong_count=$5,last_answer_confidence=$6 where id=$1",[f.questions[i],f.child,days,hours,errors,confidence]);
    }
    await auth();const id=await scalar('select public.generate_daily_wrong_review_task($1)',[f.child]),loaded=await load(id);
    const eligible=f.questions.slice(0,12).map((id,i)=>({id,rule:rules[i]})).sort((a,b)=>a.rule[0]-b.rule[0]||b.rule[2]-a.rule[2]||(a.rule[3]??9)-(b.rule[3]??9)||a.id.localeCompare(b.id)).slice(0,10);
    assert.deepEqual(loaded.items.map(i=>i.wrong_question_id),eligible.map(i=>i.id));
    assert.deepEqual(loaded.items.map(i=>i.previous_answer_confidence),eligible.map(i=>i.rule[3]));
    await client.query('reset role');await client.query('update public.wrong_questions set last_answer_confidence=1 where child_id=$1',[f.child]);await auth();
    assert.equal(await scalar('select public.generate_daily_wrong_review_task($1)',[f.child]),id);assert.deepEqual(await load(id),loaded);
  });
  await check('edited content resets confidence and stale content or postponed snapshots cannot replace the current assessment',async()=>{
    for(const change of ['edit','postpone']) {
      const f=await fixture();await start(f);await client.query('reset role');await client.query('update public.wrong_questions set last_answer_confidence=3 where id=$1',[f.questions[0]]);await auth();
      if(change==='edit') {
        await scalar('select public.save_review_question($1,$2,$3)',[f.child,{kind:'question',subject:'math',prompt:'3+3 = ?',answers:['6']},f.questions[0]]);
        assert.equal((await question(f.questions[0])).last_answer_confidence,null);
      }
      await client.query('reset role');await client.query("update public.wrong_questions set last_answer_confidence=3,review_due_at=review_due_at+interval '3 days' where id=$1",[f.questions[0]]);await auth();
      const after=await answer(f,1);assert.equal(after.items[0].answer_confidence,1);assert.equal(after.items[0].reward_status,'stale');
      assert.equal((await question(f.questions[0])).last_answer_confidence,3);assert.equal((await wallet(f.child)).coin_balance,0);
    }
  });
  await check('failed final settlement rolls back confidence together with answer progression and rewards',async()=>{
    const f=await fixture();await start(f);await client.query('reset role');await client.query('update public.task_instances set minimum_seconds=60 where id=$1',[f.task.id]);await auth();
    const before=await load(f.task.id),q=await question(f.questions[0]);
    await denied('select public.submit_review_answer($1,$2,$3,$4,1::smallint)',[f.task.id,f.questions[0],'4',randomUUID()]);
    assert.deepEqual(await load(f.task.id),before);assert.deepEqual(await question(f.questions[0]),q);assert.equal((await wallet(f.child)).coin_balance,0);
  });
  await check('legacy new answers remain unknown and clear an older self-assessment without changing historical snapshots',async()=>{
    const f=await fixture();await start(f);await client.query('reset role');await client.query('update public.wrong_questions set last_answer_confidence=3 where id=$1',[f.questions[0]]);await auth();
    const result=await oldAnswer(f);assert.equal(result.items[0].answer_confidence,null);assert.equal((await question(f.questions[0])).last_answer_confidence,null);
    await denied('select public.submit_review_answer($1,$2,$3,$4,3::smallint)',[f.task.id,f.questions[0],'4',randomUUID()]);
    assert.equal((await wallet(f.child)).coin_balance,15);
  });
  await check('competing devices cannot replace confidence or award again after the first transaction commits',async()=>{
    const f=await fixture();await start(f);const peer=new pg.Client(client.connectionParameters);
    try {
      await peer.connect();await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:'confidence-peer'})]);await peer.query('set role authenticated');await peer.query('begin');
      const first=await peer.query('select public.submit_review_answer($1,$2,$3,$4,1::smallint) as value',[f.task.id,f.questions[0],'4',randomUUID()]);assert.equal(first.rows[0].value.task.status,'completed');
      await client.query("set lock_timeout='100ms'");await assert.rejects(answer(f,3),e=>e.code==='55P03');await client.query('set lock_timeout=0');await peer.query('commit');
      await assert.rejects(answer(f,3),e=>e.message.includes('作答把握'));assert.equal((await answer(f,1)).items[0].answer_confidence,1);
      assert.equal((await wallet(f.child)).coin_balance,15);assert.equal((await question(f.questions[0])).last_answer_confidence,1);
    } finally { await client.query('set lock_timeout=0');await peer.query('rollback').catch(()=>{});await peer.end(); }
  });
  await check('confidence history exports and permanent child deletion removes it with its question and task',async()=>{
    const f=await fixture();await start(f);await answer(f,2);
    await client.query('reset role');const sections=await scalar('select public.child_export_source($1)',[f.child]);
    assert.equal(sections.length,40);
    const questions=sections.find(s=>s.columns.includes('last_answer_confidence'));
    assert.equal(questions.rows.find(r=>r.id===f.questions[0]).last_answer_confidence,2);
    const reviews=sections.find(s=>s.name==='review_items');
    assert.ok(reviews.columns.includes('answer_confidence'));assert.ok(reviews.columns.includes('previous_answer_confidence'));
    const row=reviews.rows.find(r=>r.task_instance_id===f.task.id);
    assert.equal(row.answer_confidence,2);assert.equal(row.previous_answer_confidence,null);
    await auth();const preview=await scalar('select public.preview_child_deletion($1)',[f.child]);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[f.child,randomUUID(),preview.counts]);
    await denied('select public.submit_review_answer($1,$2,$3,$4,2::smallint)',[f.task.id,f.questions[0],'4',randomUUID()]);
    await client.query('reset role');
    assert.equal(await scalar('select count(*)::int from public.task_review_items where task_instance_id=$1',[f.task.id]),0);
    assert.equal(await scalar('select count(*)::int from public.wrong_questions where id=$1',[f.questions[0]]),0);
    await auth();
  });
}
