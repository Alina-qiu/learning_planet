import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function aiAnalysisCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(), session='ai-parent', auth=()=>login(user,session);
  const service=async()=>{await client.query('reset role'); await client.query(`select set_config('request.jwt.claims','{"role":"service_role"}',false)`); await client.query('set role service_role');};
  await client.query('reset role'); await client.query('insert into auth.users values($1,$2)',[user,'ai@example.test']);
  await auth(); await scalar("select public.onboard_family('AI family','Asia/Shanghai','Child',2::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'1234')",[family]);
  await scalar("select public.verify_parent_pin($1,'1234')",[family]);
  const input={text:'8 + 7 = ?',subject:'math'};
  const claimSql='select public.claim_ai_analysis($1,$2,$3,$4,$5)';
  const resolveSql='select public.resolve_ai_analysis($1,$2,$3,$4)';
  const finishSql='select public.finish_ai_analysis($1,$2,$3)';
  let generation=0;
  const claim=async(id=randomUUID(),data=input)=>{await service();return scalar('select public.claim_ai_analysis($1,$2,$3,$4,$5,$6)',[user,session,child,id,data,generation]);};
  const settings=()=>scalar('select public.read_ai_settings($1)',[family]);
  const update=async changes=>{await auth(); const s=await settings(); return scalar('select public.update_ai_settings($1,$2,$3)',
    [family,s.version,{enabled:s.enabled,monthly_limit:s.monthly_limit,budget_cents:s.budget_cents,retention_days:s.retention_days,...changes}]);};
  const output={model_version:'test-model',prompt_version:'question-structure-v1',confidence:.6,
    raw_output:'{"knowledge_points":["进位加法"]}',structured_output:{knowledge_points:['进位加法'],difficulty:'easy',error_reasons:['calculation']},safety_flags:[]};
  let first;
  await check('AI defaults off, requires fresh parent session and operator availability, tables and claim tokens remain private',async()=>{
    assert.equal((await settings()).enabled,false);
    await denied(claimSql,[user,session,child,randomUUID(),input]);
    await service(); await denied(claimSql,[user,'wrong-session',child,randomUUID(),input]);
    await denied(claimSql,[user,session,child,randomUUID(),input]);
    await update({enabled:true}); await service(); await denied(claimSql,[user,session,child,randomUUID(),input]);
    await client.query('reset role'); await client.query("update public.ai_gateway_config set enabled=true,model='test-model'");
    await auth();
    for(const table of ['ai_gateway_config','family_ai_settings','family_ai_usage','ai_analysis_requests']) await denied(`select * from public.${table}`);
    await denied(resolveSql,[child,randomUUID(),input,'submit']);
    await login(user,'expired-ai'); await denied('select public.read_ai_settings($1)',[family]); await auth();
  });
  await check('AI validates minimal input, deduplicates claims, binds owner and content, never changes balances or tasks',async()=>{
    await service();
    for(const bad of [{...input,nickname:'private'}, {...input,text:''}, {...input,text:'x'.repeat(2001)}, {...input,subject:'science'}]) {
      await denied(claimSql,[user,session,child,randomUUID(),bad]);
    }
    first=await claim(); assert.equal(first.status,'claimed'); assert.equal(first.grade,2);
    const replay=await claim(first.request_id); assert.equal(replay.status,'running'); assert.equal(replay.token,undefined);
    await denied(claimSql,[user,session,child,first.request_id,{...input,text:'different'}]);
    await auth(); const receipt=await scalar(resolveSql,[child,first.request_id,input,'inspect']);
    assert.equal(JSON.stringify(receipt).includes(first.token),false);
    await login(otherUid); await denied(resolveSql,[child,first.request_id,input,'inspect']);
    await auth();
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[child]),0);
    assert.equal(await scalar('select count(*)::int from public.task_instances where child_id=$1',[child]),0);
    assert.equal((await settings()).requests,1);
  });
  await check('AI finish is service-only, validates claim, ignores repeated completion and includes retained output in private export',async()=>{
    await denied(finishSql,[first.request_id,first.token,output]); await service();
    await denied(finishSql,[first.request_id,randomUUID(),output]);
    await denied(finishSql,[first.request_id,first.token,{...output,model_version:'wrong'}]);
    await scalar(finishSql,[first.request_id,first.token,output]);
    await scalar(finishSql,[first.request_id,first.token,null]); await auth();
    const receipt=await scalar(resolveSql,[child,first.request_id,input,'inspect']); assert.deepEqual(receipt.result,output);
    const preview=await scalar('select public.preview_child_export($1)',[child]); assert.equal(preview.counts.ai_analysis,1);
    const exp=await scalar("select public.prepare_child_export($1,$2,$3,'导出孩子数据')",[child,randomUUID(),preview.counts]);
    const page=await scalar("select public.read_child_export_page($1,'ai_analysis')",[exp.id]);
    assert.deepEqual(page.rows[0].result,output); assert.equal(JSON.stringify(page).includes(first.token),false);
    assert.equal(JSON.stringify(page).includes('input_hash'),false);
    await client.query('reset role'); await client.query("update public.ai_analysis_requests set expires_at=now()-interval '1 second' where id=$1",[first.request_id]);
    await auth(); assert.equal((await scalar(resolveSql,[child,first.request_id,input,'inspect'])).result,null);
    await service(); assert.equal(await scalar('select public.purge_expired_ai_output()'),1);
    await auth(); await denied('select public.read_child_export_page($1,$2)',[exp.id,'ai_analysis']);
  });
  await check('AI settings use optimistic versioning, parents can disable but cannot enable or raise quotas',async()=>{
    await auth(); const s=await settings();
    await update({monthly_limit:50});
    await denied('select public.update_ai_settings($1,$2,$3)',[family,s.version,{enabled:true,monthly_limit:60,budget_cents:10000,retention_days:7}]);
    await client.query('reset role'); await client.query("insert into public.family_members values($1,$2,'parent')",[family,otherUid]);
    await login(otherUid,'ai-other'); await scalar("select public.verify_parent_pin($1,'1234')",[family]);
    const p=await settings(); const body={enabled:false,monthly_limit:p.monthly_limit,budget_cents:p.budget_cents,retention_days:p.retention_days};
    await denied('select public.update_ai_settings($1,$2,$3)',[family,p.version,{...body,enabled:true,monthly_limit:500}]);
    const off=await scalar('select public.update_ai_settings($1,$2,$3)',[family,p.version,body]); assert.equal(off.enabled,false);
    await denied('select public.update_ai_settings($1,$2,$3)',[family,off.version,{...body,enabled:true}]); await auth();
  });
  await check('AI disable and cancellation fence late provider output; failed/unknown work keeps budget occupied',async()=>{
    await update({enabled:true}); const a=await claim();
    await update({enabled:false}); await service(); await scalar(finishSql,[a.request_id,a.token,output]);
    await auth(); assert.equal((await scalar(resolveSql,[child,a.request_id,input,'inspect'])).status,'discarded');
    await update({enabled:true}); const b=await claim(); await auth();
    assert.equal((await scalar(resolveSql,[child,b.request_id,input,'cancel'])).status,'discarded');
    await service(); await scalar(finishSql,[b.request_id,b.token,output]);
    const before=await claim(randomUUID()); await scalar(finishSql,[before.request_id,before.token,null]);
    await auth(); assert.equal((await scalar(resolveSql,[child,b.request_id,input,'inspect'])).result,null);
    const cancelled=randomUUID(); await scalar(resolveSql,[child,cancelled,input,'cancel']);
    assert.equal((await claim(cancelled)).status,'cancelled'); await auth();
    const s=await settings(); assert.equal(s.requests,4); assert.equal(s.reserved_cents,400);
  });
  await check('AI concurrent claims reserve once and concurrent different requests cannot overspend the final slot',async()=>{
    await update({monthly_limit:5});
    const p=new pg.Client(client.connectionParameters); await p.connect();
    try {
      await p.query(`select set_config('request.jwt.claims','{"role":"service_role"}',false)`); await p.query('set role service_role');
      await service(); const id=randomUUID(), args=[user,session,child,id,input];
      const pair=await Promise.all([client.query(claimSql,args),p.query(claimSql,args)]);
      assert.deepEqual(pair.map(x=>Object.values(x.rows[0])[0].status).sort(),['claimed','running']);
      await auth(); assert.equal((await settings()).requests,5); await update({monthly_limit:6,budget_cents:600}); await service();
      const race=await Promise.allSettled([client.query(claimSql,[user,session,child,randomUUID(),input]),p.query(claimSql,[user,session,child,randomUUID(),input])]);
      assert.equal(race.filter(x=>x.status==='fulfilled').length,1);
      await auth(); const s=await settings(); assert.equal(s.requests,6); assert.equal(s.reserved_cents,600);
      await update({monthly_limit:100}); await service(); await denied(claimSql,[user,session,child,randomUUID(),input]);
    } finally {await p.end();}
  });
  await check('permanent question cleanup clears analyses and fences both running and not-yet-dispatched requests',async()=>{
    await update({budget_cents:10000}); const running=await claim();
    await client.query('reset role');const question=await scalar("insert into public.wrong_questions(child_id,subject,final_text) values($1,'math','PRIVATE AI SOURCE') returning id",[child]);
    await auth();await scalar("select public.request_question_cleanup($1,'questions',$2,$3,'永久删除')",[child,[question],randomUUID()]);
    generation=(await scalar('select public.read_ai_context($1)',[child])).generation;assert.equal(generation,1);
    await service();await scalar(finishSql,[running.request_id,running.token,output]);
    const stale=await scalar(claimSql,[user,session,child,randomUUID(),input]);assert.equal(stale.status,'discarded');
    await auth();assert.equal((await scalar(resolveSql,[child,running.request_id,input,'inspect'])).result,null);
    const fresh=await claim();assert.equal(fresh.status,'claimed');
    await scalar(finishSql,[fresh.request_id,fresh.token,output]);
  });
  await check('AI child deletion erases outputs and receipts without resetting family usage; late completion cannot resurrect them',async()=>{
    await update({budget_cents:10000}); const r=await claim(); await auth();
    const preview=await scalar('select public.preview_child_deletion($1)',[child]); assert.ok(preview.counts.ai_requests>0);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[child,randomUUID(),preview.counts]);
    await service(); await scalar(finishSql,[r.request_id,r.token,output]);
    await denied(claimSql,[user,session,child,r.request_id,input]);
    await client.query('reset role'); assert.equal(await scalar('select count(*)::int from public.ai_analysis_requests where child_id=$1',[child]),0);
    await auth(); assert.equal((await settings()).requests,9);
  });
  await check('account deletion rejects new AI claims with old sessions and late output cannot restore deleted child data',async()=>{
    await auth(); const nextChild=await scalar("select public.create_child($1,'Another',2::smallint)",[family]);
    await service();const pending=await scalar(claimSql,[user,session,nextChild,randomUUID(),input]);assert.equal(pending.status,'claimed');
    // This parent's private AI analysis in another owner's family must be erased too.
    await login(otherUid,'shared-ai-owner');await scalar("select public.onboard_family('Shared AI','Asia/Shanghai','Shared child',2::smallint)");
    const shared=await scalar("select id from public.families where name='Shared AI'");
    const sharedChild=await scalar('select id from public.children where family_id=$1',[shared]);
    await scalar("select public.set_parent_pin($1,'1234')",[shared]);await scalar("select public.verify_parent_pin($1,'1234')",[shared]);
    await scalar('select public.update_ai_settings($1,0,$2)',[shared,{enabled:true,monthly_limit:100,budget_cents:10000,retention_days:7}]);
    await client.query('reset role');await client.query("insert into public.family_members values($1,$2,'parent')",[shared,user]);
    await auth();await scalar("select public.verify_parent_pin($1,'1234')",[shared]);
    await service();const sharedRequest=await scalar(claimSql,[user,session,sharedChild,randomUUID(),input]);
    await scalar(finishSql,[sharedRequest.request_id,sharedRequest.token,output]);
    await login(otherUid,'shared-ai-owner');const exportPreview=await scalar('select public.preview_child_export($1)',[sharedChild]);
    const exportJob=await scalar("select public.prepare_child_export($1,$2,$3,'导出孩子数据')",[sharedChild,randomUUID(),exportPreview.counts]);
    await auth();const preview=await scalar('select public.preview_account_deletion()');
    await scalar("select public.request_account_deletion($1,$2,'永久注销我的账号')",[randomUUID(),preview.scope]);
    await service();await scalar(finishSql,[pending.request_id,pending.token,output]);
    await denied(claimSql,[user,session,nextChild,randomUUID(),input]);
    await login(otherUid,'shared-ai-owner');await denied("select public.read_child_export_page($1,'ai_analysis')",[exportJob.id]);
    await client.query('reset role');assert.equal(await scalar('select count(*)::int from public.ai_analysis_requests where owner_id=$1',[user]),0);
    assert.equal(await scalar('select count(*)::int from public.children where id=$1',[sharedChild]),1);
  });
}
