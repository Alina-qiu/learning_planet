import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';
import {executeCleanup} from '../supabase/functions/_shared/cleanup_worker.mjs';

export async function childDeletionCases({client,scalar,login,denied,check,family,uid,otherUid}) {
  await login();
  const child=await scalar("select public.create_child($1,'Delete all my data',2::smallint)",[family]);
  const sibling=await scalar("select public.create_child($1,'Keep sibling',2::smallint)",[family]);
  await client.query("select public.adjust_wallet($1,25,40,'SENSITIVE REASON',$2,false)",[child,randomUUID()]);
  await client.query('reset role');
  const task=await scalar(`insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key)
    values($1,'SENSITIVE TASK',current_date,'parent_template',$2) returning id`,[child,randomUUID()]);
  const question=await scalar("insert into public.wrong_questions(child_id,subject,final_text) values($1,'math','PRIVATE QUESTION') returning id",[child]);
  await client.query("insert into public.wrong_question_answers values($1,array['PRIVATE ANSWER'],'PRIVATE EXPLANATION')",[question]);
  const template=await scalar("insert into public.task_templates(child_id,title) values($1,'PRIVATE TEMPLATE') returning id",[child]);
  const plan=await scalar("insert into public.long_plans(template_id,minimum_rate,bonus_coins,bonus_xp) values($1,1,0,0) returning id",[template]);
  await client.query("insert into public.plan_leaves values($1,current_date,'PRIVATE LEAVE')",[plan]);
  await client.query("insert into public.task_review_items(task_instance_id,wrong_question_id,sequence,prompt,answer_text) values($1,$2,1,'PRIVATE SNAPSHOT','PRIVATE RESPONSE')",[task,question]);
  await client.query("insert into public.task_review_answer_keys(task_id,question_id,accepted_answers,explanation) values($1,$2,array['KEY'],'EXPLANATION')",[task,question]);
  const reward=await scalar("insert into public.rewards(family_id,title,cost) values($1,'Shared reward stays',1) returning id",[family]);
  await client.query("insert into public.redemptions(child_id,reward_id,frozen_amount) values($1,$2,1)",[child,reward]);
  const draft=randomUUID(),orphan=randomUUID(),pdf=randomUUID(),oldJob=randomUUID(),oldLease=randomUUID();
  const paths=[`${child}/${draft}/original.jpg`,`${child}/${draft}/processed.jpg`,`${child}/${orphan}/original.jpg`];
  await client.query(`insert into public.question_ocr_drafts(id,child_id,owner_id,status,original_path,processed_path,question_id)
    values($1,$2,$3,'saved',$4,$5,$6)`,[draft,child,uid,paths[0],paths[1],question]);
  for(const path of paths) await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1)",[path]);
  await client.query(`insert into public.worksheet_jobs(id,family_id,child_id,owner_id,config,question_ids,pdf_path,status,lease_token,lease_until)
    values($1,$2,$3,$4,'{}',$5,$6,'running',$7,now()+interval '5 minutes')`,[pdf,family,child,uid,[question],`${family}/${pdf}/worksheet.pdf`,randomUUID()]);
  await client.query("insert into storage.objects(bucket_id,name) values('worksheets',$1)",[`${family}/${pdf}/worksheet.pdf`]);
  await client.query("insert into public.worksheet_items values($1,1,$2,'PRIVATE PDF','math','wrong_question','',1,array['KEY'],'EXPLANATION')",[pdf,question]);
  await login();
  const exportId=randomUUID(),exportPreview=await scalar('select public.preview_child_export($1)',[child]);
  await client.query('select public.prepare_child_export($1,$2,$3,$4)',[child,exportId,exportPreview.counts,'导出孩子数据']);
  await client.query('reset role');
  await client.query(`insert into public.cleanup_jobs(id,family_id,child_id,owner_id,scope,question_ids,draft_ids,manifest,status,lease_token,lease_until)
    values($1,$2,$3,$4,'originals',$5,$6,$7,'running',$8,now()+interval '5 minutes')`,[oldJob,family,child,uid,[question],[draft],JSON.stringify([{bucket:'wrong-question-images',path:paths[0]}]),oldLease]);
  await login();
  const preview=()=>scalar('select public.preview_child_deletion($1)',[child]),requestId=randomUUID();
  let counts;
  await check('child deletion needs admin session PIN, explicit phrase and unchanged preview',async()=>{
    counts=(await preview()).counts;
    assert.equal(counts.files,4); assert.equal(counts.coins,25); assert.equal(counts.tasks,1);
    await denied('select public.child_deletion_source($1)',[child]);
    await denied('select public.delete_child($1)',[child]);
    await denied('select public.request_child_deletion($1,$2,$3,$4)',[child,requestId,counts,'yes']);
    await denied('select public.request_child_deletion($1,$2,$3,$4)',[child,requestId,{...counts,files:0},'永久删除孩子']);
    await login(uid,'delete-without-pin'); await assert.rejects(preview());
    await login(otherUid); await client.query("select public.verify_parent_pin($1,'1234')",[family]); await assert.rejects(preview());
    await client.query('reset role'); await client.query('set role anon'); await assert.rejects(preview()); await login();
  });
  await check('accepted deletion erases business data and exports with a durable complete file job and UUID replay',async()=>{
    assert.equal(await scalar('select public.request_child_deletion($1,$2,$3,$4)',[child,requestId,counts,'永久删除孩子']),requestId);
    await denied('select public.child_export_manifest($1)',[exportId]);
    await denied('select public.task_sync_snapshot($1)',[child]);
    await denied('select public.start_task($1)',[task]);
    await denied('select public.update_child($1,$2,2::smallint)',[child,'RESTORE']);
    await assert.rejects(preview());
    assert.equal(await scalar('select public.can_insert_question_image($1)',[paths[0]]),false);
    await client.query('reset role');
    for(const table of ['children','task_instances','wallets','ledger_entries','wrong_questions','question_ocr_drafts','worksheet_jobs','child_export_jobs','task_sync_leases']) {
      assert.equal(await scalar(`select count(*)::int from public.${table} where ${table==='children'?'id':'child_id'}=$1`,[child]),0,table);
    }
    assert.equal(await scalar('select count(*)::int from public.children where id=$1',[sibling]),1);
    assert.equal(await scalar('select count(*)::int from public.rewards where id=$1',[reward]),1);
    for(const [table,column,id] of [['long_plans','id',plan],['plan_leaves','plan_id',plan],['task_review_items','task_instance_id',task],['task_review_answer_keys','task_id',task],['worksheet_items','worksheet_id',pdf]]) {
      assert.equal(await scalar(`select count(*)::int from public.${table} where ${column}=$1`,[id]),0,table);
    }
    await denied('delete from public.families where id=$1',[family]);
    assert.equal(await scalar('select count(*)::int from storage.objects where name like $1 or name=$2',[child+'/%',`${family}/${pdf}/worksheet.pdf`]),4);
    assert.equal(await scalar('select count(*)::int from public.audit_logs where target_id=$1',[child]),0);
    const job=await scalar('select to_jsonb(j) from public.cleanup_jobs j where id=$1',[requestId]);
    assert.equal(job.manifest.length,4); assert.ok(Date.parse(job.next_attempt_at)-Date.parse(job.created_at)>14*60000);
    assert.equal(await scalar('select status from public.cleanup_jobs where id=$1',[oldJob]),'superseded');
    await login();
    assert.equal(await scalar('select public.request_child_deletion($1,$2,$3,$4)',[child,requestId,counts,'永久删除孩子']),requestId);
    await denied('select public.request_child_deletion($1,$2,$3,$4)',[sibling,requestId,counts,'永久删除孩子']);
  });
  await check('history and retry are admin-only and revoked PDF or cleanup leases cannot bypass the waiting period',async()=>{
    const jobs=await scalar('select public.child_deletion_history($1)',[family]);
    assert.equal(jobs.find(j=>j.id===requestId).status,'queued'); assert.equal(JSON.stringify(jobs).includes('SENSITIVE'),false);
    assert.equal((await scalar('select public.claim_cleanup_job($1)',[requestId])).status,'queued');
    assert.equal((await scalar('select public.claim_cleanup_job($1)',[oldJob])).status,'superseded');
    await login(otherUid); await denied('select public.child_deletion_history($1)',[family]); await denied('select public.claim_cleanup_job($1)',[requestId]);
    assert.equal(await scalar('select count(*)::int from public.cleanup_jobs where id=$1',[requestId]),0);
    assert.equal(await scalar('select count(*)::int from public.child_deletion_tombstones where child_id=$1',[child]),1);
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false)"); await client.query('set role service_role');
    await denied('select public.finish_cleanup_job($1,$2,null)',[oldJob,oldLease]);
    assert.equal((await scalar('select public.claim_cleanup_job($1)',[requestId])).status,'queued'); await login();
  });
  async function service() {
    await client.query('reset role');
    await client.query("update public.cleanup_jobs set next_attempt_at=now()-interval '1 second' where id=$1",[requestId]);
    await client.query("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false)"); await client.query('set role service_role');
  }
  await check('file failure stays retryable and only verified absence completes and erases the child manifest',async()=>{
    await service(); let claim=await scalar('select public.claim_cleanup_job($1)',[requestId]);
    assert.equal(claim.status,'claimed'); await denied('select public.finish_cleanup_job($1,$2,null)',[requestId,claim.lease_token]);
    const finish=(id,token,code)=>client.query('select public.finish_cleanup_job($1,$2,$3)',[id,token,code]);
    assert.equal(await executeCleanup(claim,{from:()=>({remove:async()=>({error:{message:'offline'}})})},finish),'failed');
    await client.query('reset role'); assert.equal(await scalar('select status from public.cleanup_jobs where id=$1',[requestId]),'failed');
    await service(); claim=await scalar('select public.claim_cleanup_job($1)',[requestId]);
    const storage={from:bucket=>({
      async remove(paths) {
        await client.query('reset role'); await client.query('delete from storage.objects where bucket_id=$1 and name=any($2::text[])',[bucket,paths]);
        await client.query('set role service_role'); return {error:null};
      },
      async exists() {return {data:false,error:{status:404}};}
    })};
    assert.equal(await executeCleanup(claim,storage,finish),'completed'); await finish(requestId,claim.lease_token,null);
    await client.query('reset role');
    const job=await scalar('select to_jsonb(j) from public.cleanup_jobs j where id=$1',[requestId]);
    assert.equal(job.status,'completed'); assert.deepEqual(job.manifest,[]); assert.deepEqual(job.question_ids,[]);
    assert.equal(await scalar('select count(*)::int from public.cleanup_jobs where id=$1',[oldJob]),0); await login();
  });
  await check('30-day deletion records expire while UUID-only reconnect markers remain',async()=>{
    await denied('select public.enqueue_expired_worksheets()'); await client.query('reset role');
    await client.query("update public.cleanup_jobs set completed_at=now()-interval '31 days' where id=$1",[requestId]);
    await client.query("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false)"); await client.query('set role service_role');
    await client.query('select public.enqueue_expired_worksheets()'); await client.query('reset role');
    assert.equal(await scalar('select count(*)::int from public.cleanup_jobs where id=$1',[requestId]),0);
    assert.deepEqual(Object.keys(await scalar('select to_jsonb(t) from public.child_deletion_tombstones t where child_id=$1',[child])).sort(),['child_id','deleted_at','family_id']); await login();
  });
  await check('last-child deletion is supported and unknown file paths leave data untouched',async()=>{
    await client.query("select public.onboard_family('Empty after delete','Asia/Shanghai','Only child',1::smallint)");
    const solo=await scalar("select id from public.children where nickname='Only child'"),soloFamily=await scalar('select family_id from public.children where id=$1',[solo]);
    await client.query("select public.set_parent_pin($1,'1234')",[soloFamily]); await client.query("select public.verify_parent_pin($1,'1234')",[soloFamily]);
    await client.query('reset role'); await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1)",[`${solo}/unrecognized.bin`]); await login();
    let p=await scalar('select public.preview_child_deletion($1)',[solo]);
    await denied('select public.request_child_deletion($1,$2,$3,$4)',[solo,randomUUID(),p.counts,'永久删除孩子']);
    assert.equal(await scalar('select count(*)::int from public.children where id=$1',[solo]),1);
    await client.query('reset role'); await client.query('delete from storage.objects where name=$1',[`${solo}/unrecognized.bin`]); await login();
    p=await scalar('select public.preview_child_deletion($1)',[solo]);
    await client.query('select public.request_child_deletion($1,$2,$3,$4)',[solo,randomUUID(),p.counts,'永久删除孩子']);
    assert.equal(await scalar('select count(*)::int from public.children where family_id=$1',[soloFamily]),0);
    assert.equal(await scalar('select count(*)::int from public.families where id=$1',[soloFamily]),1);
  });
  await check('two sessions retry one deletion UUID without duplicate jobs or losing the surviving child',async()=>{
    await login();
    const concurrent=await scalar("select public.create_child($1,'Concurrent deletion',1::smallint)",[family]);
    const counts=(await scalar('select public.preview_child_deletion($1)',[concurrent])).counts, id=randomUUID();
    const other=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});
    await other.connect();
    try {
      await other.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:uid,role:'authenticated',session_id:'parallel-child-delete'})]);
      await other.query('set role authenticated');
      await other.query("select public.verify_parent_pin($1,'1234')",[family]);
      const sql='select public.request_child_deletion($1,$2,$3,$4)',args=[concurrent,id,counts,'永久删除孩子'];
      const result=await Promise.all([scalar(sql,args),other.query(sql,args)]);
      assert.equal(result[0],id); assert.equal(Object.values(result[1].rows[0])[0],id);
      await client.query('reset role'); assert.equal(await scalar('select count(*)::int from public.cleanup_jobs where child_id=$1',[concurrent]),1);
      await login(); assert.equal(await scalar('select count(*)::int from public.children where id=$1',[sibling]),1);
    } finally {await other.end();}
  });
}
