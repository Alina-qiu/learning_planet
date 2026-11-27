import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

export async function exportCases({client, scalar, login, denied, check, family, uid, otherUid}) {
  await login();
  const child=await scalar("select public.create_child($1,'Export child',2::smallint)",[family]);
  const sibling=await scalar("select public.create_child($1,'Private sibling',2::smallint)",[family]);
  await client.query("select public.adjust_wallet($1,10,20,'parent grant',$2,false)",[child,randomUUID()]);
  await client.query('reset role');
  await client.query(`insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key)
    select $1::uuid,'Export task '||n,current_date,'parent_template','export-fixture:'||$1::text||':'||n from generate_series(1,280) n`,[child]);
  await client.query(`insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key)
    values($1,'SIBLING PRIVATE',current_date,'parent_template',$2)`,[sibling,randomUUID()]);
  const question=await scalar("insert into public.wrong_questions(child_id,subject,final_text) values($1,'math','EXPORT PRIVATE QUESTION') returning id",[child]);
  const foreignFamily=await scalar("insert into public.families(name,owner_user_id) values('Foreign family',$1) returning id",[otherUid]);
  await client.query("insert into public.audit_logs(family_id,action,target_type,target_id,details) values($1,'foreign.audit','child',$2,'{\"secret\":\"FOREIGN AUDIT\"}')",[foreignFamily,child]);
  await client.query("insert into public.wrong_question_answers values($1,array['PRIVATE ANSWER'],'PRIVATE EXPLANATION')",[question]);
  const savedDraft=randomUUID(), ownDraft=randomUUID(), otherDraft=randomUUID();
  for(const [id,owner,qid] of [[savedDraft,otherUid,question],[ownDraft,uid,null],[otherDraft,otherUid,null]]) {
    await client.query(`insert into public.question_ocr_drafts(id,child_id,owner_id,status,original_path,processed_path,question_id,raw_text)
      values($1,$2,$3,$4,$5,$6,$7,$8)`,[id,child,owner,qid?'saved':'pending',`${child}/${id}/original.jpg`,`${child}/${id}/processed.jpg`,qid,id===otherDraft?'OTHER PARENT UNSAVED':'OCR TEXT']);
    await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1),('wrong-question-images',$2)",[`${child}/${id}/original.jpg`,`${child}/${id}/processed.jpg`]);
  }
  await login();
  const preview=()=>scalar('select public.preview_child_export($1)',[child]);
  const prepare=async(id=randomUUID())=>scalar('select public.prepare_child_export($1,$2,$3,$4)',[child,id,(await preview()).counts,'导出孩子数据']);
  const page=(id,section,after=0)=>scalar('select public.read_child_export_page($1,$2,$3)',[id,section,after]);

  await check('child export requires administrator plus session PIN and excludes direct table/helper access', async()=>{
    await denied('select public.child_export_source($1)',[child]);
    await denied('select * from public.child_export_rows');
    await denied('select * from public.child_export_jobs');
    await login(uid,'export-no-pin'); await assert.rejects(preview());
    await login(otherUid); await client.query("select public.verify_parent_pin($1,'1234')",[family]);
    await assert.rejects(preview());
    await client.query('reset role'); await client.query('set role anon'); await assert.rejects(preview());
    await login();
    await denied('select public.preview_child_export($1)',[randomUUID()]);
  });
  let job;
  await check('export preview counts and secondary confirmation constrain a complete scoped snapshot',async()=>{
    const counts=(await preview()).counts;
    assert.equal(counts.tasks,280); assert.equal(counts.ocr_records,2); assert.equal(counts.image_index,4);
    assert.equal(counts.question_answers,1);
    await denied('select public.prepare_child_export($1,$2,$3,$4)',[child,randomUUID(),counts,'yes']);
    await denied('select public.prepare_child_export($1,$2,$3,$4)',[child,randomUUID(),{...counts,tasks:279},'导出孩子数据']);
    job=await prepare();
    assert.equal(job.child_id,child); assert.equal(job.schema_version,1); assert.equal(job.sections.length,40);
    assert.ok(Date.parse(job.expires_at)>Date.parse(job.created_at));
    const retry=await scalar('select public.prepare_child_export($1,$2,$3,$4)',[child,job.id,counts,'导出孩子数据']);
    assert.deepEqual(retry,job);
    assert.equal((await page(job.id,'question_answers')).rows[0].accepted_answers[0],'PRIVATE ANSWER');
    const ocr=await page(job.id,'ocr_records');
    assert.equal(JSON.stringify(ocr).includes('OTHER PARENT UNSAVED'),false);
    const images=await page(job.id,'image_index');
    assert.equal(images.rows.length,4); assert.ok(images.rows.every(r=>r.present));
    assert.equal(JSON.stringify(images).includes('http'),false);
    const profile=await page(job.id,'child_profile'); assert.equal(profile.rows[0].id,child);
    assert.equal(JSON.stringify(profile).includes('Private sibling'),false);
    assert.equal(JSON.stringify(await page(job.id,'audit_logs')).includes('FOREIGN AUDIT'),false);
    for(const section of job.sections) {
      const part=await page(job.id,section.name);
      assert.equal(part.total,section.count);
      for(const row of part.rows) assert.deepEqual(new Set(Object.keys(row)),new Set(section.columns));
    }
  });
  await check('export pagination remains immutable while source tasks are edited or added',async()=>{
    const first=await page(job.id,'tasks');
    assert.equal(first.rows.length,250); assert.equal(first.next_ordinal,250); assert.equal(first.done,false);
    await client.query('reset role');
    await client.query("update public.task_instances set title='CHANGED AFTER SNAPSHOT' where child_id=$1",[child]);
    await client.query(`insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key)
      values($1,'NEW AFTER SNAPSHOT',current_date,'parent_template',$2)`,[child,randomUUID()]);
    await login();
    const second=await page(job.id,'tasks',250);
    assert.equal(second.rows.length,30); assert.equal(second.done,true); assert.equal(second.total,280);
    assert.equal(new Set([...first.rows,...second.rows].map(r=>r.id)).size,280);
    assert.ok([...first.rows,...second.rows].every(r=>r.title.startsWith('Export task ')));
    assert.deepEqual((await page(job.id,'tasks')).rows,first.rows);
    await denied('select public.read_child_export_page($1,$2,$3)',[job.id,'tasks',-1]);
    await denied('select public.read_child_export_page($1,$2,$3)',[job.id,'auth.users',0]);
  });
  await check('snapshot pages bind owner and session and stop when parent authorization expires',async()=>{
    await login(uid,'other-export-session');
    await client.query("select public.verify_parent_pin($1,'1234')",[family]);
    await assert.rejects(page(job.id,'tasks'));
    await denied('select public.close_child_export($1)',[job.id]);
    await login(); await client.query('select public.revoke_parent_authorization()');
    await assert.rejects(page(job.id,'tasks'));
    await client.query('select public.close_child_export($1)',[job.id]);
    await client.query("select public.verify_parent_pin($1,'1234')",[family]);
    await denied('select public.child_export_manifest($1)',[job.id]);
    await client.query('reset role');
    assert.equal(await scalar('select count(*)::int from public.child_export_rows where export_id=$1',[job.id]),0);
    await login();
  });
  await check('source cleanup revokes and physically erases prepared exports before file deletion',async()=>{
    job=await prepare();
    const cleanup=await scalar("select public.request_question_cleanup($1,'originals',$2,$3,'永久删除')",[child,[question],randomUUID()]);
    await denied('select public.child_export_manifest($1)',[job.id]);
    await assert.rejects(preview());
    await client.query('reset role');
    assert.equal(await scalar('select count(*)::int from public.child_export_rows where export_id=$1',[job.id]),0);
    assert.equal(await scalar('select state from public.child_export_jobs where id=$1',[job.id]),'revoked');
    // Finish only this local fixture through the existing verified cleanup API.
    await login(); const claim=await scalar('select public.claim_cleanup_job($1)',[cleanup]);
    await client.query('reset role');
    for(const file of claim.manifest) await client.query('delete from storage.objects where bucket_id=$1 and name=$2',[file.bucket,file.path]);
    await client.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await client.query('set role service_role');
    await client.query('select public.finish_cleanup_job($1,$2,null)',[cleanup,claim.lease_token]);
    await login();
    assert.equal((await preview()).counts.image_index,3);
  });
  await check('new export supersedes prior copies and service-only expiry removes abandoned content',async()=>{
    const first=await prepare(), second=await prepare();
    await denied('select public.child_export_manifest($1)',[first.id]);
    await denied('select public.run_child_export_maintenance()');
    await denied('select public.purge_expired_child_exports()');
    await client.query('reset role');
    await client.query("update public.child_export_jobs set expires_at=now()-interval '1 second' where id=$1",[second.id]);
    await login(); await denied('select public.child_export_manifest($1)',[second.id]);
    await client.query('reset role');
    const claims=JSON.stringify({role:'service_role',marker:'preserved'});
    await client.query("select set_config('request.jwt.claims',$1,false)",[claims]);
    await client.query('set role service_role');
    assert.ok(await scalar('select public.run_child_export_maintenance()')>0);
    assert.equal(await scalar("select current_setting('request.jwt.claims')"),claims);
    assert.equal(await scalar('select public.run_child_export_maintenance()'),0);
    await client.query('reset role');
    assert.equal(await scalar('select count(*)::int from public.child_export_rows where export_id=$1',[second.id]),0);
    await login();
  });
  await check('large OCR rows paginate without truncation or a stalled cursor',async()=>{
    await client.query('reset role');
    await client.query("update public.question_ocr_drafts set raw_text=repeat('x',1100000) where id=any($1::uuid[])",[[savedDraft,ownDraft]]);
    await login();
    const large=await prepare();
    const first=await page(large.id,'ocr_records');
    assert.equal(first.rows.length,1); assert.equal(first.next_ordinal,1); assert.equal(first.done,false);
    assert.equal(first.rows[0].raw_text.length,1100000);
    const second=await page(large.id,'ocr_records',first.next_ordinal);
    assert.equal(second.rows.length,1); assert.equal(second.next_ordinal,2); assert.equal(second.done,true);
    assert.equal(second.rows[0].raw_text.length,1100000);
    assert.notEqual(first.rows[0].id,second.rows[0].id);
    await client.query('select public.close_child_export($1)',[large.id]);
  });
}
