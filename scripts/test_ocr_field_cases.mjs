import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function ocrFieldCases({client,scalar,login,denied,check}) {
  const owner=randomUUID();await client.query('reset role');await client.query('insert into auth.users values($1,$2)',[owner,`${owner}@ocr-fields.test`]);
  const auth=()=>login(owner,'ocr-fields');await auth();
  await scalar("select public.onboard_family('OCR fields','Asia/Shanghai','Child',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'2468')",[family]);await scalar("select public.verify_parent_pin($1,'2468')",[family]);
  const raw={text:'题目：2+Z=?\nA.3\nB.4\n我的答案：3\n批注：再算一次',field_schema:1,fields:{
    prompt:{text:'2+Z=?',confidence:0.4},options:{text:'A.3\nB.4',confidence:null},answer:{text:'3',confidence:0.8},annotation:{text:'再算一次',confidence:0.9},
  }};
  const fields={prompt:'2+2=?',options:'A.3\nB.4',answer:'3',annotation:'再算一次'};
  const config={kind:'question',subject:'math',prompt:'2+2=?\nA.3\nB.4',answers:['4'],ocr_confirmed:true,ocr_corrections:fields,ocr_field_confirmations:Object.keys(fields)};
  const upload=async(childInput=false)=>{
    const id=randomUUID();const d=await scalar(`select public.${childInput?'begin_child_question_upload':'begin_question_media_upload'}($1,$2,$3)`,[child,id,'a'.repeat(64)]);
    await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1),('wrong-question-images',$2)",[d.original_path,d.processed_path]);
    if(!childInput)await scalar('select public.record_question_ocr($1,$2)',[id,raw]);return d;
  };
  const save=(d,c=config)=>scalar('select public.save_review_question($1,$2)',[child,{...c,ocr_draft_id:d.id}]);
  const row=d=>scalar('select to_jsonb(d) from public.question_ocr_drafts d where id=$1',[d.id]);
  let parentDraft,question;
  await check('structured OCR requires every nonempty field confirmation and keeps image answers out of grading',async()=>{
    parentDraft=await upload();
    for(const c of [
      {...config,ocr_corrections:undefined,ocr_field_confirmations:undefined},
      {...config,ocr_field_confirmations:['prompt','options']},
      {...config,ocr_field_confirmations:['prompt','prompt','answer','annotation']},
      {...config,prompt:'includes an answer'},
      {...config,ocr_corrections:{...fields,answer:3}},
      {...config,ocr_corrections:{...fields,annotation:'x'.repeat(2001)}},
      {...config,ocr_corrections:{...fields,extra:'unrecognized'}},
    ])await denied('select public.save_review_question($1,$2)',[child,{...c,ocr_draft_id:parentDraft.id}]);
    assert.equal((await row(parentDraft)).final_ocr_fields,null);assert.equal((await row(parentDraft)).question_id,null);
    question=await save(parentDraft);const d=await row(parentDraft);
    assert.deepEqual(d.raw_result.fields,raw.fields);assert.deepEqual(d.final_ocr_fields,fields);
    assert.equal(d.metrics_ocr_fields,4);assert.equal(d.metrics_corrected_fields,1);
    assert.equal(await scalar('select final_text from public.wrong_questions where id=$1',[question]),config.prompt);
    const task=await scalar('select public.generate_daily_wrong_review_task($1)',[child]);
    await client.query('reset role');assert.deepEqual(await scalar('select accepted_answers from public.task_review_answer_keys where task_id=$1 and question_id=$2',[task,question]),['4']);await auth();
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[child]),0);
  });
  await check('first confirmed OCR fields and quality metrics remain frozen across retries and later edits',async()=>{
    const before=await row(parentDraft);assert.equal(await save(parentDraft),question);
    const version=await scalar('select content_version from public.wrong_questions where id=$1',[question]);
    await scalar('select public.save_review_question($1,$2,$3)',[child,{kind:'question',subject:'math',prompt:'Later edit',answers:['changed'],expected_version:version},question]);
    const after=await row(parentDraft);assert.deepEqual(after.final_ocr_fields,before.final_ocr_fields);
    assert.equal(after.metrics_confirmed_at,before.metrics_confirmed_at);assert.equal(after.metrics_corrected_fields,1);
    await client.query('reset role');await client.query("update public.question_ocr_drafts set final_ocr_fields='{}' where id=$1",[parentDraft.id]);
    await auth();assert.deepEqual((await row(parentDraft)).final_ocr_fields,fields);
  });
  await check('child OCR field submissions remain pending until parent rechecks fields and answers',async()=>{
    await login(owner,'child-mode');const d=await upload(true);
    const submitted={...config,answers:[],requires_parent_review:true};
    const first=await scalar('select public.submit_child_question($1,$2,$3)',[d.id,submitted,raw]);
    assert.equal(first.state,'pending');assert.deepEqual(first.config.ocr_corrections,fields);assert.equal((await row(d)).metrics_ocr_fields,null);
    await denied('select public.submit_child_question($1,$2,$3)',[d.id,{...submitted,ocr_corrections:{...fields,answer:'changed'}},raw]);
    await denied('select public.approve_child_question($1,$2,$3)',[d.id,randomUUID(),config]);
    await auth();await denied('select public.approve_child_question($1,$2,$3)',[d.id,randomUUID(),{...config,ocr_field_confirmations:[]}]);
    assert.equal((await row(d)).final_ocr_fields,null);
    const key=randomUUID(),approved=await scalar('select public.approve_child_question($1,$2,$3)',[d.id,key,config]);
    assert.equal(approved.state,'approved');assert.deepEqual(await scalar('select public.approve_child_question($1,$2,$3)',[d.id,key,config]),approved);
    assert.deepEqual((await row(d)).final_ocr_fields,fields);assert.equal((await row(d)).metrics_ocr_fields,4);
  });
  await check('invalid source fields fail atomically and empty OCR fields do not inflate quality counts',async()=>{
    await login(owner,'child-mode');const d=await upload(true);
    for(const r of [{...raw,field_schema:2},{...raw,fields:{...raw.fields,answer:{text:'3',confidence:2}}},{...raw,fields:{...raw.fields,options:null}}]) await denied('select public.submit_child_question($1,$2,$3)',[d.id,{...config,requires_parent_review:true},r]);
    assert.equal((await row(d)).status,'pending');
    const sparse={text:'2+2=?',field_schema:1,fields:{prompt:{text:'2+2=?'},options:{text:''},answer:{text:''},annotation:{text:''}}};
    const c={...config,prompt:'2+2=?',ocr_corrections:{prompt:'2+2=?',options:'',answer:'manual notes',annotation:''},ocr_field_confirmations:['prompt','answer']};
    await scalar('select public.submit_child_question($1,$2,$3)',[d.id,{...c,requires_parent_review:true},sparse]);
    await auth();await scalar('select public.approve_child_question($1,$2,$3)',[d.id,randomUUID(),c]);
    const saved=await row(d);assert.equal(saved.metrics_ocr_fields,1);assert.equal(saved.metrics_corrected_fields,0);
    await denied('select public.validate_ocr_field_correction($1,$2)',[raw,config]);
    await denied('select public.save_review_question_before_ocr_fields($1,$2,null)',[child,config]);
  });
  await check('field source and final corrections are exported and removed with child data',async()=>{
    await client.query('reset role');const sections=await scalar('select public.child_export_source($1)',[child]);assert.equal(sections.length,40);
    const source=sections.find(s=>s.name==='ocr_records');assert.ok(source.columns.includes('final_ocr_fields'));
    assert.deepEqual(source.rows.find(r=>r.id===parentDraft.id).final_ocr_fields,fields);
    await auth();const preview=await scalar('select public.preview_child_deletion($1)',[child]);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[child,randomUUID(),preview.counts]);
    await client.query('reset role');assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where child_id=$1',[child]),0);await login();
  });
}
