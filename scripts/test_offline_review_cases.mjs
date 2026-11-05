import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function offlineReviewCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(), auth=()=>login(user,'offline-review-session');
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)',[user,'offline-review@example.test']);
  await auth();
  await client.query("select public.onboard_family('Offline review','Asia/Shanghai','Initial',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  await client.query("select public.set_parent_pin($1,'2468')",[family]);
  await client.query("select public.verify_parent_pin($1,'2468')",[family]);
  const fixture=async()=>{
    const child=await scalar("select public.create_child($1,'Review',1::smallint)",[family]);
    const question=await scalar('select public.save_review_question($1,$2)',[child,
      {kind:'pinyin',subject:'chinese',prompt:'银行',answers:['yín háng'],context:'去银行存钱',pronunciation_confirmed:true}]);
    const snap=await scalar('select public.task_sync_snapshot($1)',[child]);
    const task=snap.tasks.find(t=>t.source_type==='automatic_wrong_review');
    // Legacy snapshots still support the explicit pause/resume/finish chain.
    await client.query('reset role');await client.query('update public.task_instances set review_auto_complete=false where id=$1',[task.id]);await auth();
    task.review_auto_complete=false;
    task.sync_version=await scalar('select sync_version from public.task_instances where id=$1',[task.id]);
    const version=await scalar('select content_version from public.wrong_questions where id=$1',[question]);
    return {child,question,task,snap,version};
  };
  const cmd=async(f,kind,previous=null,extra={})=>({command_id:randomUUID(),task_id:f.task.id,kind:'review_'+kind,
    lease_id:f.snap.lease_id,expected_version:f.task.sync_version,predecessor_id:previous?.command_id??null,
    occurred_at:await scalar('select clock_timestamp()::text'),...extra});
  const apply=c=>scalar('select public.apply_task_command($1)',[c]);
  const answer=(f,previous,extra={})=>cmd(f,'answer',previous,{question_id:f.question,question_version:Number(f.version),answer:'yin2 hang2',...extra});
  await check('offline review replays start, answer, pause, resume and completion exactly once without local rewards',async()=>{
    const f=await fixture();let c=await cmd(f,'start');await apply(c);
    c=await answer(f,c);let r=await apply(c);assert.equal(r.outcome,'applied',r.reason);assert.equal(r.review.items[0].result,true);
    assert.equal(r.wallet.coin_balance,0);assert.equal(r.wallet.xp,0);
    const version=r.task.sync_version;
    assert.equal((await apply(c)).task.sync_version,version);
    await denied('select public.apply_task_command($1)',[{...c,answer:'other'}]);
    assert.equal(await scalar('select review_attempts from public.wrong_questions where id=$1',[f.question]),1);
    await client.query('reset role');
    const receipt=await scalar('select request from public.task_command_receipts where command_id=$1',[c.command_id]);
    assert.deepEqual(Object.keys(receipt).sort(),['digest','occurred_at']);assert.equal(receipt.digest.length,64);
    await auth();
    c=await cmd(f,'pause',c);await apply(c);c=await cmd(f,'resume',c);await apply(c);
    c=await cmd(f,'complete',c);r=await apply(c);assert.equal(r.task.status,'completed');
    assert.equal(r.wallet.coin_balance,15);assert.equal(r.wallet.xp,15);
    assert.equal((await apply(c)).wallet.coin_balance,15);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[f.task.id]),2);
  });
  await check('review rejects missing answers, forged grading, wrong snapshot, future clock and expired lease',async()=>{
    const f=await fixture(),start=await cmd(f,'start');await apply(start);
    assert.equal((await apply(await cmd(f,'complete',start))).outcome,'conflict');
    assert.equal((await apply(await answer(f,start,{question_version:99}))).outcome,'conflict');
    await denied('select public.apply_task_command($1)',[await answer(f,start,{result:true,coins:999})]);
    assert.equal((await apply(await answer(f,start,{occurred_at:'2099-01-01T00:00:00Z'}))).outcome,'conflict');
    assert.equal((await apply(await answer(f,start,{predecessor_id:randomUUID()}))).outcome,'conflict');
    await client.query('reset role');await client.query("update public.task_sync_leases set expires_at=now()-interval '1 second' where id=$1",[f.snap.lease_id]);await auth();
    assert.equal((await apply(await answer(f,start))).outcome,'conflict');
    assert.equal(await scalar('select review_attempts from public.wrong_questions where id=$1',[f.question]),0);
  });
  await check('legacy online grading advances task version and conflicts with another device offline chain',async()=>{
    const f=await fixture(),start=await cmd(f,'start');const before=await apply(start);
    const stale=await answer(f,start,{answer:'wrong'});
    await scalar("select public.submit_review_answer($1,$2,'yin2 hang2',$3)",[f.task.id,f.question,randomUUID()]);
    assert.ok(Number(await scalar('select sync_version from public.task_instances where id=$1',[f.task.id]))>Number(before.task.sync_version));
    assert.equal((await apply(stale)).outcome,'conflict');
    assert.equal(await scalar('select review_attempts from public.wrong_questions where id=$1',[f.question]),1);
  });
  await check('two connections competing for the same review version accept only one answer',async()=>{
    const f=await fixture(),start=await cmd(f,'start');await apply(start);
    const a=await answer(f,start),b=await answer(f,start,{answer:'wrong'});
    const peer=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});await peer.connect();
    try {
      await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:'other-device'})]);
      await peer.query('set role authenticated');
      const [r1,r2]=await Promise.all([apply(a),peer.query('select public.apply_task_command($1) result',[b])]);
      assert.deepEqual([r1.outcome,r2.rows[0].result.outcome].sort(),['applied','conflict']);
      assert.equal(await scalar('select review_attempts from public.wrong_questions where id=$1',[f.question]),1);
    } finally {await peer.end();}
  });
  await check('offline review answer can precede abandon without awarding completion',async()=>{
    const f=await fixture(),s=await cmd(f,'start');await apply(s);const a=await answer(f,s);await apply(a);
    const abandon={...await cmd(f,'complete',a),kind:'abandon'};
    assert.equal((await apply(abandon)).task.status,'abandoned');
    assert.equal(await scalar('select coin_balance+xp from public.wallets where child_id=$1',[f.child]),0);
    assert.equal((await apply(await cmd(f,'complete',a))).outcome,'conflict');
  });
  await check('cleanup stops new offline answers and replay never restores erased answer content',async()=>{
    const f=await fixture(),s=await cmd(f,'start');await apply(s);const a=await answer(f,s);await apply(a);
    await scalar("select public.request_question_cleanup($1,'questions',$2,$3,'永久删除')",[f.child,[f.question],randomUUID()]);
    const replay=await apply(a);assert.equal(replay.review.items[0].answer_text,null);
    assert.equal(replay.review.items[0].accepted_answers,null);
    assert.equal((await apply(await answer(f,s))).outcome,'conflict');
  });
  await check('offline review is account scoped and private bypass functions stay inaccessible',async()=>{
    const f=await fixture(),s=await cmd(f,'start');
    await login(otherUid);await denied('select public.apply_task_command($1)',[s]);await auth();
    await denied('select public.apply_task_command_before_review($1)',[s]);
    await denied("select public.submit_review_answer_before_offline($1,$2,'answer',$3)",[f.task.id,f.question,randomUUID()]);
    await denied('select * from public.task_command_receipts');
  });
  await login();
}
