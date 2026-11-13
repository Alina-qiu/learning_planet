import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';
import {normalizeWeekly} from '../supabase/functions/_shared/ai_weekly_report.mjs';
import {weeklyValue} from './fixtures/weekly_report.mjs';

export async function aiReportCases({client,scalar,login,denied,check,otherUid}){
  const user=randomUUID(),session='weekly-parent',auth=()=>login(user,session);
  const admin=async()=>{await client.query('reset role');await client.query(`select set_config('request.jwt.claims','{"role":"service_role"}',false)`);};
  const service=async()=>{await admin();await client.query('set role service_role');};
  await admin();await client.query('insert into auth.users values($1,$2)',[user,'weekly@example.test']);await auth();
  await scalar("select public.onboard_family('Private family','America/New_York','PRIVATE CHILD',3::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]),child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'1234')",[family]);await scalar("select public.verify_parent_pin($1,'1234')",[family]);
  await scalar('select public.update_ai_settings($1,0,$2)',[family,{enabled:true,monthly_limit:100,budget_cents:20000,retention_days:7}]);
  await admin();await client.query("update public.ai_gateway_config set enabled=true,model='test-model',reserve_cents=100");
  const task=await scalar(`insert into public.task_instances(child_id,title,due_date,source_type,status,accumulated_seconds,completed_at,idempotency_key)
    values($1,'PRIVATE TITLE','2026-03-08','parent_template','completed',600,'2026-03-08T10:00:00Z',$2) returning id`,[child,randomUUID()]);
  await client.query(`insert into public.task_instances(child_id,title,due_date,source_type,status,accumulated_seconds,completed_at,idempotency_key) values
    ($1,'PRIVATE PAUSED','2026-03-07','parent_template','paused',120,null,$2),
    ($1,'PRIVATE LATE','2026-03-01','parent_template','completed',60,'2026-03-08T11:00:00Z',$3)`,[child,randomUUID(),randomUUID()]);
  const question=await scalar("insert into public.wrong_questions(child_id,subject,final_text,review_due_at) values($1,'math','PRIVATE QUESTION','2026-03-01') returning id",[child]);
  await client.query("insert into public.task_review_items(task_instance_id,wrong_question_id,sequence,result,answered_at) values($1,$2,1,true,'2026-03-08T10:00:00Z')",[task,question]);
  await auth();
  const context=()=>scalar('select public.weekly_report_ai_context($1,$2)',[child,'2026-03-08']);
  let input=(await context()).input,generation=0,first;
  const claim=async(data=input,id=randomUUID())=>{await service();return scalar('select public.claim_ai_analysis($1,$2,$3,$4,$5,$6)',[user,session,child,id,data,generation]);};
  const output=()=>normalizeWeekly(weeklyValue,'test-model',JSON.stringify(weeklyValue));
  const finish=async(c,value=output())=>{await service();await scalar('select public.finish_ai_analysis($1,$2,$3)',[c.request_id,c.token,value]);};
  const resolve=async(c,data=input,operation='inspect')=>{await auth();return scalar('select public.resolve_ai_analysis($1,$2,$3,$4,$5)',[child,c.request_id,data,operation,generation]);};
  await check('weekly source uses family dates and exact aggregate cohorts without identities, titles or question text',async()=>{
    const s=input.snapshot;assert.equal(s.start_date,'2026-03-02');assert.equal(s.end_date,'2026-03-08');assert.equal(s.days.length,7);
    assert.deepEqual(s.tasks,{expected:2,completed:1,effective_seconds:720});assert.equal(s.activity_count,2);assert.equal(s.due_now,1);
    assert.deepEqual(s.reviews,{answered:1,correct:1});assert.equal(JSON.stringify(input).includes('PRIVATE'),false);assert.equal(JSON.stringify(input).includes(child),false);
    await login(otherUid);await denied('select public.weekly_report_ai_context($1,$2)',[child,'2026-03-08']);
    await login(user,'no-pin');await denied('select public.weekly_report_ai_context($1,$2)',[child,'2026-03-08']);await auth();
    await denied('select * from public.ai_report_feedback');
  });
  await check('tampered or stale weekly inputs fail before quota is charged and malformed sources are rejected',async()=>{
    const tampered=structuredClone(input);tampered.snapshot.activity_count++;
    await assert.rejects(claim(tampered),/AI_REPORT_CHANGED/);
    for(const invalid of [{...input,nickname:'secret'},{...input,snapshot:{...input.snapshot,title:'secret'}},{...input,end_date:'2026-02-30'}])await assert.rejects(claim(invalid));
    await admin();assert.equal(await scalar('select coalesce(sum(requests),0)::int from public.family_ai_usage where family_id=$1',[family]),0);
  });
  await check('concurrent weekly claims dispatch once, share quotas, hide running evidence and bind the original snapshot',async()=>{
    const id=randomUUID(),other=new pg.Client(client.connectionParameters);await other.connect();
    try{
      await other.query(`select set_config('request.jwt.claims','{"role":"service_role"}',false)`);await other.query('set role service_role');
      const results=await Promise.all([claim(input,id),other.query('select public.claim_ai_analysis($1,$2,$3,$4,$5,$6) r',[user,session,child,id,input,generation]).then(v=>v.rows[0].r)]);
      first=results.find(r=>r.status==='claimed');assert.ok(first);assert.equal(results.filter(r=>r.status==='claimed').length,1);
      assert.equal((await resolve(first)).result,null);
    }finally{await other.end();}
    await admin();assert.equal(await scalar('select requests from public.family_ai_usage where family_id=$1',[family]),1);
    await client.query('update public.task_instances set accumulated_seconds=660 where id=$1',[task]);
    await assert.rejects(claim(input),/AI_REPORT_CHANGED/);assert.equal((await claim(input,first.request_id)).status,'running');
    await auth();const changed=(await context()).input;await assert.rejects(claim(changed,first.request_id),/绑定/);
  });
  await check('report output requires valid evidence links and nonjudgmental text and freezes authoritative original data',async()=>{
    for(const value of [ {...output(),evidence:{forged:true}}, {...output(),structured_output:{...output().structured_output,recommendation:{text:'退步',evidence_ids:['tasks']}}},
      {...output(),structured_output:{...output().structured_output,recommendation:{text:'看数据',evidence_ids:['invented']}}}]) await assert.rejects(finish(first,value));
    await finish(first);const receipt=await resolve(first);assert.deepEqual(receipt.result.evidence,input);
    assert.equal(receipt.result.evidence.snapshot.tasks.effective_seconds,720);assert.equal(receipt.result.prompt_version,'weekly-report-v1');
    await admin();assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[child]),0);
    assert.equal(await scalar('select count(*)::int from public.task_instances where child_id=$1',[child]),3);
  });
  await check('feedback is per conclusion, owner scoped and idempotent; exports include versions and frozen evidence',async()=>{
    await auth();for(const key of ['summary:0','recommendation','recommendation'])await scalar('select public.feedback_ai_report($1,$2,$3)',[child,first.request_id,key]);
    await denied('select public.feedback_ai_report($1,$2,$3)',[child,first.request_id,'summary:2']);
    await login(otherUid);await denied('select public.feedback_ai_report($1,$2,$3)',[child,first.request_id,'recommendation']);
    await admin();const sections=await scalar('select public.child_export_source($1)',[child]);assert.equal(sections.length,40);
    const rows=sections.find(s=>s.name==='ai_report_feedback').rows;assert.equal(rows.length,2);assert.equal(rows[0].prompt_version,'weekly-report-v1');
    assert.deepEqual(sections.find(s=>s.name==='ai_analysis').rows.find(r=>r.request_id===first.request_id).result.evidence,input);
  });
  await check('cancellation, safety refusal and running retention remove evidence and never dispatch old requests again',async()=>{
    await auth();input=(await context()).input;
    const cancelled=await claim();await resolve(cancelled,input,'cancel');await finish(cancelled);
    assert.equal((await resolve(cancelled)).status,'discarded');assert.equal((await claim(input,cancelled.request_id)).status,'discarded');
    const blocked=await claim();await finish(blocked,normalizeWeekly({...weeklyValue,safety_flags:['refused']},'test-model','sensitive'));
    assert.equal((await resolve(blocked)).result.evidence,undefined);assert.deepEqual((await resolve(blocked)).result.structured_output,{});
    const expiring=await claim();await admin();await client.query("update public.ai_analysis_requests set expires_at=now()-interval '1 second' where id=$1",[expiring.request_id]);
    assert.equal((await resolve(expiring)).status,'expired');await service();await scalar('select public.purge_expired_ai_output()');
    await admin();assert.equal(await scalar('select result from public.ai_analysis_requests where id=$1',[expiring.request_id]),null);
    assert.equal((await claim(input,expiring.request_id)).status,'expired');await finish(expiring);
    assert.equal((await resolve(expiring)).result,null);
  });
  await check('real question cleanup, AI-off and child deletion clear weekly evidence and feedback through existing workflows',async()=>{
    const pending=await claim();await auth();await scalar("select public.request_question_cleanup($1,'questions',$2,$3,'永久删除')",[child,[question],randomUUID()]);
    generation=(await scalar('select public.read_ai_context($1)',[child])).generation;await finish(pending);
    await admin();assert.equal(await scalar('select result from public.ai_analysis_requests where id=$1',[pending.request_id]),null);
    await auth();input=(await context()).input;const off=await claim();await auth();const settings=await scalar('select public.read_ai_settings($1)',[family]);
    await scalar('select public.update_ai_settings($1,$2,$3)',[family,settings.version,{enabled:false,monthly_limit:100,budget_cents:20000,retention_days:7}]);await finish(off);
    assert.equal((await resolve(off)).result,null);
    const preview=await scalar('select public.preview_child_deletion($1)',[child]);assert.equal(preview.counts.ai_report_feedback,2);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[child,randomUUID(),preview.counts]);
    await admin();for(const table of ['ai_analysis_requests','ai_report_feedback'])assert.equal(await scalar(`select count(*)::int from public.${table} where child_id=$1`,[child]),0);
    await finish(off);await auth();
  });
}
