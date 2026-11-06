import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function reviewMilestoneCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(),auth=()=>login(user,'review-milestones');
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)',[user,'milestones@example.test']);
  await auth();
  await scalar("select public.onboard_family('Milestones','Asia/Shanghai','Initial',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  await client.query("select public.set_parent_pin($1,'2468')",[family]);
  await client.query("select public.verify_parent_pin($1,'2468')",[family]);
  const config={kind:'question',subject:'math',prompt:'2 + 2 = ?',answers:['4'],explanation:'相加'};
  const row=id=>scalar('select public.load_review_task($1)',[id]);
  const wallet=child=>scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]);
  const finish=id=>scalar('select to_jsonb(public.complete_task($1,$2))',[id,'milestone:'+id]);
  const answer=async(id,value='4')=>{
    await scalar('select public.start_task($1)',[id]);
    for(const item of (await row(id)).items) await scalar('select public.submit_review_answer($1,$2,$3,$4)',[id,item.wrong_question_id,value,randomUUID()]);
    return row(id);
  };
  const claims=async(child)=>{
    await client.query('reset role');
    const n=await scalar('select count(*)::int from public.review_milestone_awards where child_id=$1',[child]);
    await auth();return n;
  };
  const fixture=async(steps=[0],cap=10000)=>{
    const child=await scalar("select public.create_child($1,'Milestones',1::smallint)",[family]);
    await scalar('select public.set_daily_coin_limit($1,$2)',[child,cap]);
    const questions=[];
    for(const step of steps) {
      const id=await scalar('select public.save_review_question($1,$2)',[child,config]);questions.push(id);
      // Only the privileged test clock seeds elapsed review phases; clients cannot edit them.
      await client.query('reset role');
      await client.query("update public.wrong_questions set review_step=$2,review_due_at=now()-interval '1 minute',mastery_status='practicing' where id=$1",[id,step]);
      await auth();
    }
    const task=await scalar('select public.generate_daily_wrong_review_task($1)',[child]);
    // These cases retain pre-062 explicit-completion snapshots to exercise
    // eligibility races/rollback. New automatic completion has its own suite.
    await client.query('reset role');await client.query('update public.task_instances set review_auto_complete=false where id=$1',[task]);await auth();
    return {child,questions,task};
  };
  // Seed queued historical snapshots without waiting weeks. Actions, grading,
  // claims, timing, authorization and settlement below always use real RPCs.
  let queued=0;
  const backlog=async(f,{step=null,policy=2,resetDue=false}={})=>{
    await client.query('reset role');
    if(resetDue) await client.query("update public.wrong_questions set review_step=coalesce($2,review_step),review_due_at=now()-interval '1 minute',mastery_status='practicing' where id=any($1::uuid[])",[f.questions,step]);
    const id=await scalar(`insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key,review_reward_policy)
      values($1,'Queued review',public.family_today($1)::date-$2::integer,'automatic_wrong_review',$3,$4) returning id`,[f.child,++queued*2,randomUUID(),policy]);
    await client.query(`insert into public.task_review_items(task_instance_id,wrong_question_id,sequence,prompt,subject,knowledge_point,review_kind,question_version)
      select $1,id,row_number() over(order by id)::smallint,final_text,subject,knowledge_point,review_kind,content_version from public.wrong_questions where id=any($2::uuid[])`,[id,f.questions]);
    await client.query(`insert into public.task_review_answer_keys(task_id,question_id,accepted_answers,explanation)
      select $1,question_id,accepted_answers,explanation from public.wrong_question_answers where question_id=any($2::uuid[])`,[id,f.questions]);
    await auth();return id;
  };
  await check('milestones freeze all five phases and pay only correction, seven-day and mastery on completion',async()=>{
    for(const [step,coins,xp] of [[0,15,15],[1,0,0],[2,0,0],[3,25,20],[4,40,30]]) {
      const f=await fixture([step]),before=await row(f.task);
      assert.equal(before.task.review_reward_policy,2);assert.equal(before.task.coin_reward,coins);assert.equal(before.task.xp_reward,xp);
      assert.equal(before.items[0].review_step_snapshot,step);assert.ok(before.items[0].review_due_snapshot);
      assert.equal(before.items[0].accepted_answers,null);assert.equal(before.items[0].reward_status,'pending');
      const graded=await answer(f.task);assert.equal(graded.items[0].result,true);
      assert.equal(graded.items[0].reward_status,coins?'eligible':'practice');assert.equal((await wallet(f.child)).coin_balance,0);
      assert.equal(await claims(f.child),0);
      const done=await finish(f.task);assert.equal(done.status,'completed');assert.equal(done.coin_reward,coins);assert.equal(done.xp_reward,xp);
      assert.equal((await wallet(f.child)).coin_balance,coins);assert.equal((await wallet(f.child)).xp,xp);
      const item=(await row(f.task)).items[0];assert.equal(item.reward_coins,coins);assert.equal(item.reward_xp,xp);
      assert.equal(item.reward_status,coins?'awarded':'practice');assert.equal(!!item.reward_awarded_at,!!coins);
      await finish(f.task);assert.equal((await wallet(f.child)).coin_balance,coins);
      assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[f.task]),2);
      assert.equal(await scalar('select mastery_status::text from public.wrong_questions where id=$1',[f.questions[0]]),step===4?'mastered':'practicing');
    }
  });
  await check('one question version earns three distinct milestones only after all five due phases',async()=>{
    const f=await fixture();await answer(f.task);await finish(f.task);
    for(const step of [1,2,3,4]) {
      const task=await backlog(f,{resetDue:true});assert.equal((await row(task)).items[0].review_step_snapshot,step);
      await answer(task);await finish(task);
    }
    assert.equal(await claims(f.child),3);assert.equal((await wallet(f.child)).coin_balance,80);assert.equal((await wallet(f.child)).xp,65);
    assert.equal(await scalar('select mastery_status::text from public.wrong_questions where id=$1',[f.questions[0]]),'mastered');
    assert.equal(await scalar('select review_attempts from public.wrong_questions where id=$1',[f.questions[0]]),5);
  });
  await check('wrong answers reset progress without paying coins or XP at any milestone',async()=>{
    for(const step of [0,3,4]) {
      const f=await fixture([step]),graded=await answer(f.task,'wrong');assert.equal(graded.items[0].reward_status,'wrong');
      const done=await finish(f.task);assert.equal(done.coin_reward,0);assert.equal(done.xp_reward,0);assert.equal(await claims(f.child),0);
      assert.equal((await wallet(f.child)).xp,0);assert.equal(await scalar('select review_step from public.wrong_questions where id=$1',[f.questions[0]]),0);
    }
  });
  await check('a repeated cycle cannot repay a milestone and a parent content edit starts a new version',async()=>{
    const f=await fixture();await answer(f.task);await finish(f.task);
    const wrong=await backlog(f,{resetDue:true});await answer(wrong,'wrong');await finish(wrong);
    const retry=await backlog(f,{resetDue:true});assert.equal((await answer(retry)).items[0].reward_status,'already_rewarded');
    assert.equal((await finish(retry)).coin_reward,0);assert.equal(await claims(f.child),1);
    const version=await scalar('select content_version from public.wrong_questions where id=$1',[f.questions[0]]);
    await scalar('select public.save_review_question($1,$2,$3)',[f.child,{...config,prompt:'修改后的 2 + 2 = ?',expected_version:Number(version)},f.questions[0]]);
    const edited=await backlog(f,{resetDue:true});assert.equal((await answer(edited)).items[0].reward_status,'eligible');
    assert.equal((await finish(edited)).coin_reward,15);assert.equal(await claims(f.child),2);
  });
  await check('old phase, changed due date and edited content snapshots cannot advance a new phase or earn its reward',async()=>{
    const f=await fixture(),duplicate=await backlog(f);
    await answer(f.task);const progress=await scalar('select to_jsonb(w) from public.wrong_questions w where id=$1',[f.questions[0]]);
    const stale=await answer(duplicate);assert.equal(stale.items[0].result,true);assert.equal(stale.items[0].reward_status,'stale');
    assert.deepEqual(await scalar('select to_jsonb(w) from public.wrong_questions w where id=$1',[f.questions[0]]),progress);
    assert.equal((await finish(duplicate)).coin_reward,0);
    for(const mode of ['due','version']) {
      const task=await backlog(f,{resetDue:true,step:3});
      if(mode==='due') {await client.query('reset role');await client.query("update public.wrong_questions set review_due_at=now()+interval '7 days' where id=$1",[f.questions[0]]);await auth();}
      else {const v=await scalar('select content_version from public.wrong_questions where id=$1',[f.questions[0]]);await scalar('select public.save_review_question($1,$2,$3)',[f.child,{...config,expected_version:Number(v)},f.questions[0]]);}
      const before=await scalar('select to_jsonb(w) from public.wrong_questions w where id=$1',[f.questions[0]]);
      assert.equal((await answer(task)).items[0].reward_status,'stale');assert.equal((await finish(task)).coin_reward,0);
      assert.deepEqual(await scalar('select to_jsonb(w) from public.wrong_questions w where id=$1',[f.questions[0]]),before);
    }
  });
  await check('two connections settling multiple eligible snapshots claim each question and stage only once',async()=>{
    const f=await fixture([0,0]);await answer(f.task);
    const wrong=await backlog(f,{resetDue:true});await answer(wrong,'wrong');
    const retry=await backlog(f,{resetDue:true});assert.ok((await answer(retry)).items.every(i=>i.reward_status==='eligible'));
    const peers=[0,1].map(()=>new pg.Client(client.connectionParameters));
    try {
      for(const peer of peers) {await peer.connect();await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:'review-milestones'})]);await peer.query('set role authenticated');}
      const complete=(peer,id)=>peer.query('select to_jsonb(public.complete_task($1,$2)) as task',[id,'milestone:'+id]);
      const results=await Promise.all([complete(peers[0],f.task),complete(peers[1],retry)]);
      assert.equal(results.reduce((s,r)=>s+r.rows[0].task.coin_reward,0),30);assert.equal(results.reduce((s,r)=>s+r.rows[0].task.xp_reward,0),30);
      assert.equal(await claims(f.child),2);assert.equal((await wallet(f.child)).coin_balance,30);
      await Promise.all(peers.map(peer=>complete(peer,f.task)));assert.equal((await wallet(f.child)).coin_balance,30);
    } finally {await Promise.all(peers.map(p=>p.end()));}
  });
  await check('existing legacy tasks retain their old answer reward contract and never create milestone claims',async()=>{
    const f=await fixture([0,0]),legacy=await backlog(f,{policy:1});
    await scalar('select public.start_task($1)',[legacy]);const items=(await row(legacy)).items;
    for(const [i,item] of items.entries()) await scalar('select public.submit_review_answer($1,$2,$3,$4)',[legacy,item.wrong_question_id,i?'wrong':'4',randomUUID()]);
    const done=await finish(legacy);assert.equal(done.review_reward_policy,1);assert.equal(done.coin_reward,5);assert.equal(done.xp_reward,8);
    assert.equal(await claims(f.child),0);assert.ok((await row(legacy)).items.every(i=>i.reward_status==='legacy'&&i.review_step_snapshot===null));
  });
  let exportFixture;
  await check('milestone awards respect the wallet soft cap and replay creates no extra pending coins',async()=>{
    const f=exportFixture=await fixture([4,4,4],50);await answer(f.task);const done=await finish(f.task);
    assert.equal(done.coin_reward,120);assert.equal(done.xp_reward,90);assert.equal((await wallet(f.child)).coin_balance,50);assert.equal((await wallet(f.child)).xp,90);
    const pending=()=>scalar('select coalesce(sum(amount),0)::int from public.pending_coin_awards where child_id=$1',[f.child]);
    assert.equal(await pending(),70);await finish(f.task);assert.equal(await pending(),70);assert.equal(await claims(f.child),3);
  });
  await check('private receipts and reward fields reject forgery and failed completion rolls back all claims',async()=>{
    const f=await fixture();await answer(f.task);
    await denied('select * from public.review_milestone_awards');
    assert.equal((await client.query('update public.task_instances set review_reward_policy=1 where id=$1',[f.task])).rowCount,0);
    assert.equal((await row(f.task)).task.review_reward_policy,2);
    await denied("update public.task_review_items set reward_status='awarded',reward_coins=40 where task_instance_id=$1",[f.task]);
    await denied('select public.complete_task_before_milestones($1,$2)',[f.task,randomUUID()]);
    await denied('select public.complete_task_before_review($1,$2)',[f.task,randomUUID()]);
    for(const role of ['anon','service_role']) {
      await client.query('reset role');await client.query('set role '+role);
      await denied('select * from public.review_milestone_awards');
      await denied('select public.complete_task_before_milestones($1,$2)',[f.task,randomUUID()]);
    }
    await auth();
    await denied("select public.complete_task($1,$2,'override')",[f.task,randomUUID()]);
    await login(otherUid);await denied('select public.complete_task($1,$2)',[f.task,randomUUID()]);await auth();
    await client.query('reset role');await client.query('update public.task_instances set minimum_seconds=99999 where id=$1',[f.task]);await auth();
    await denied('select public.complete_task($1,$2)',[f.task,randomUUID()]);assert.equal(await claims(f.child),0);
    assert.equal((await row(f.task)).items[0].reward_status,'eligible');assert.equal((await wallet(f.child)).coin_balance,0);
    await client.query('reset role');await client.query('update public.task_instances set minimum_seconds=0 where id=$1',[f.task]);await auth();
    assert.equal((await finish(f.task)).coin_reward,15);
  });
  await check('review reward snapshots export with public history and child deletion removes private claims',async()=>{
    const f=exportFixture;await client.query('reset role');const sections=await scalar('select public.child_export_source($1)',[f.child]);
    assert.equal(sections.length,40);
    const reviews=sections.find(s=>s.name==='review_items');assert.ok(reviews.columns.includes('reward_coins'));
    const rows=reviews.rows.filter(r=>r.task_instance_id===f.task);assert.equal(rows.length,3);
    assert.ok(rows.every(r=>r.reward_coins===40&&r.reward_status==='awarded'));
    assert.equal(sections.find(s=>s.name==='tasks').rows.find(r=>r.id===f.task).review_reward_policy,2);
    await auth();const preview=await scalar('select public.preview_child_deletion($1)',[f.child]);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[f.child,randomUUID(),preview.counts]);
    assert.equal(await claims(f.child),0);await denied('select public.complete_task($1,$2)',[f.task,randomUUID()]);await login();
  });
}
