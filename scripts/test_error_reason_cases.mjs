import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export async function errorReasonCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(),auth=()=>login(user,'reason-tags');
  await client.query('reset role');await client.query('insert into auth.users values($1,$2)',[user,'reason-tags@example.test']);
  await auth();await scalar("select public.onboard_family('Reason family','Asia/Shanghai','Child',3::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'1234')",[family]);await scalar("select public.verify_parent_pin($1,'1234')",[family]);
  const tags=['reading','concept','calculation','handwriting','memory','other'];
  const config={kind:'question',subject:'math',prompt:'2+3=?',answers:['5'],error_reason:'书写与记忆待核对'};
  const save=(value=config,id=null)=>scalar('select public.save_review_question($1,$2,$3)',[child,value,id]);
  const read=id=>scalar('select public.review_question_editor($1)',[id]);
  let question;
  await check('six reviewed error labels remain separate from legacy notes and do not issue rewards',async()=>{
    question=await save();assert.deepEqual((await read(question)).error_reason_tags,[]);
    const row=await read(question);
    await save({...config,error_reason_tags:[...tags].reverse(),expected_version:row.content_version},question);
    const updated=await read(question);assert.deepEqual(updated.error_reason_tags,tags);assert.equal(updated.error_reason,config.error_reason);
    assert.equal(updated.content_version,row.content_version+1);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[child]),0);
    // An old client which omits this new field preserves the explicit labels.
    await save(config,question);assert.deepEqual((await read(question)).error_reason_tags,tags);
    await save({...config,error_reason_tags:[]},question);assert.deepEqual((await read(question)).error_reason_tags,[]);
  });
  await check('invalid labels and stale edits roll back atomically; PIN and family boundaries remain required',async()=>{
    const before=await read(question),count=await scalar('select count(*)::int from public.wrong_questions where child_id=$1',[child]);
    for(const invalid of [null,'reading',{},[null],[true],['method'],['memory','memory'],[...tags,'other']]) {
      await denied('select public.save_review_question($1,$2)',[child,{...config,error_reason_tags:invalid}]);
    }
    assert.equal(await scalar('select count(*)::int from public.wrong_questions where child_id=$1',[child]),count);
    await save({...config,error_reason_tags:['memory'],expected_version:before.content_version},question);
    await denied('select public.save_review_question($1,$2,$3)',[child,{...config,prompt:'stale',error_reason_tags:['reading'],expected_version:before.content_version},question]);
    assert.deepEqual((await read(question)).error_reason_tags,['memory']);assert.equal((await read(question)).final_text,config.prompt);
    await denied('select public.save_review_question_before_reason_tags($1,$2,$3)',[child,config,question]);
    await login(user,'no-pin');await denied('select public.save_review_question($1,$2,$3)',[child,config,question]);
    await login(otherUid);await denied('select public.save_review_question($1,$2,$3)',[child,config,question]);await auth();
  });
  await check('OCR retries cannot replace labels and child exports include the reviewed label column',async()=>{
    const draftId=randomUUID();
    const draft=await scalar('select public.begin_question_media_upload($1,$2,$3)',[child,draftId,'a'.repeat(64)]);
    for(const name of [draft.original_path,draft.processed_path]) await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1)",[name]);
    await scalar('select public.record_question_ocr($1,$2)',[draftId,{text:'2+3=?'}]);
    const ocrConfig={...config,ocr_draft_id:draftId,ocr_confirmed:true,error_reason_tags:['handwriting']};
    const ocrQuestion=await save(ocrConfig);
    assert.equal(await save({...ocrConfig,error_reason_tags:['memory']}),ocrQuestion);
    assert.deepEqual((await read(ocrQuestion)).error_reason_tags,['handwriting']);
    await client.query('reset role');
    const exported=(await scalar('select public.child_export_source($1)',[child])).find(section=>section.name==='wrong_questions');
    assert.ok(exported.columns.includes('error_reason_tags'));
    assert.deepEqual(exported.rows.find(row=>row.id===ocrQuestion).error_reason_tags,['handwriting']);
    await auth();
  });
}
