import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function childQuestionSubmissionCases({client,scalar,login,denied,check,otherUid}) {
  const parent=randomUUID(),input=randomUUID();
  await client.query('reset role');
  for(const id of [parent,input]) await client.query('insert into auth.users values($1,$2)',[id,`${id}@child-submission.test`]);
  const parentLogin=()=>login(parent,'submission-parent'),childLogin=()=>login(input,'submission-child');
  await parentLogin();await scalar("select public.onboard_family('Review submissions','Asia/Shanghai','Child',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[parent]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'2468')",[family]);
  await client.query('reset role');await client.query("insert into public.family_members(family_id,user_id,role) values($1,$2,'parent')",[family,input]);
  await childLogin();
  const hash='a'.repeat(64),config={kind:'question',subject:'math',prompt:'2+2=?',answers:[],ocr_confirmed:true,requires_parent_review:true};
  const recognition={text:'2+Z=?',lines:[{text:'2+Z=?',confidence:0.5}]};
  const begin=(id=randomUUID())=>scalar('select public.begin_child_question_upload($1,$2,$3)',[child,id,hash]);
  const upload=async()=>{const d=await begin();await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1),('wrong-question-images',$2)",[d.original_path,d.processed_path]);return d;};
  const submit=(d,c=config,r=recognition)=>scalar('select public.submit_child_question($1,$2,$3)',[d.id,c,r]);
  const read=id=>scalar('select public.child_question_submission($1)',[id]);
  const list=()=>scalar('select public.child_question_submissions($1)',[child]);
  const approveSql='select public.approve_child_question($1,$2,$3)',answer={...config,answers:['4'],explanation:'两组两个，共四个'};
  let draft,question;
  await check('children submit image drafts without PIN but cannot create graded questions rewards or automatic review tasks',async()=>{
    draft=await begin();assert.equal(draft.requires_parent_review,true);
    await denied('select public.submit_child_question($1,$2,$3)',[draft.id,config,recognition]);
    await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1),('wrong-question-images',$2)",[draft.original_path,draft.processed_path]);
    const result=await submit(draft);assert.equal(result.state,'pending');assert.equal(result.question_id,null);assert.equal(result.created_by,input);
    assert.deepEqual(await submit(draft),result);assert.equal((await begin(draft.id)).status,'recognized');
    for(const table of ['wrong_questions','ledger_entries','task_instances']) assert.equal(await scalar(`select count(*)::int from public.${table} where child_id=$1`,[child]),0);
    assert.equal(await scalar('select public.generate_daily_wrong_review_task($1)',[child]),null);
    await denied(approveSql,[draft.id,randomUUID(),answer]);
    await denied('select public.save_review_question($1,$2)',[child,{...answer,ocr_draft_id:draft.id}]);
    await denied('select public.begin_question_media_upload($1,$2,$3)',[child,randomUUID(),hash]);
    await denied('update public.question_ocr_drafts set question_id=$1 where id=$2',[randomUUID(),draft.id]);
  });
  await check('submissions freeze payloads validate fields and isolate pending images from other accounts without parent PIN',async()=>{
    await denied('select public.begin_child_question_upload($1,$2,$3)',[child,draft.id,'b'.repeat(64)]);
    await denied('select public.submit_child_question($1,$2,$3)',[draft.id,{...config,prompt:'changed'},recognition]);
    const fresh=await upload();
    for(const c of [{...config,answers:'bad'},{...config,answers:[4]},{...config,ocr_confirmed:'true'},{...config,ocr_draft_id:draft.id},{...config,error_reason_tags:{}},{...config,explanation:{}}]) await denied('select public.submit_child_question($1,$2,$3)',[fresh.id,c,recognition]);
    await denied('select public.submit_child_question($1,$2,$3)',[fresh.id,config,{text:'raw',lines:[{text:4}]}]);
    await parentLogin();assert.equal((await list()).items.length,0);await denied('select public.child_question_submission($1)',[draft.id]);
    assert.equal(await scalar('select count(*)::int from storage.objects where name=$1',[draft.original_path]),0);
    await scalar("select public.verify_parent_pin($1,'2468')",[family]);
    assert.equal((await read(draft.id)).state,'pending');assert.equal((await list()).items.length,1);
    assert.equal(await scalar('select count(*)::int from storage.objects where name=$1',[draft.original_path]),1);
    await denied('select public.child_question_submission($1)',[fresh.id]);
    await login(otherUid);await denied('select public.child_question_submissions($1)',[child]);await denied('select public.child_question_submission($1)',[draft.id]);await denied('select public.begin_child_question_upload($1,$2,$3)',[child,randomUUID(),hash]);
    await parentLogin();await denied('select public.save_review_question($1,$2)',[child,{...answer,ocr_draft_id:draft.id}]);
    await denied('select public.save_review_question_before_child_submissions($1,$2,null)',[child,answer]);
    for(const role of ['anon','service_role']) {await client.query('reset role');await client.query('set role '+role);await denied('select public.child_question_submissions($1)',[child]);}await parentLogin();
  });
  await check('explicit parent confirmation creates one question with confirmed answers and preserves raw child input and OCR metrics',async()=>{
    const key=randomUUID(),first=await scalar(approveSql,[draft.id,key,answer]);question=first.question_id;
    assert.equal(first.state,'approved');assert.ok(first.confirmed_at);assert.deepEqual(first.config.answers,[]);
    assert.deepEqual(await scalar(approveSql,[draft.id,key,answer]),first);
    await denied(approveSql,[draft.id,key,{...answer,answers:['999']}]);await denied(approveSql,[draft.id,randomUUID(),answer]);
    assert.equal(await scalar('select count(*)::int from public.wrong_questions where child_id=$1',[child]),1);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[child]),0);
    const provenance=await scalar('select to_jsonb(d) from public.question_ocr_drafts d where id=$1',[draft.id]);
    assert.equal(provenance.raw_text,recognition.text);assert.equal(provenance.parent_confirmed_by,parent);
    assert.equal(provenance.metrics_ocr_fields,1);assert.equal(provenance.metrics_corrected_fields,1);
    const approved=await scalar('select to_jsonb(q) from public.wrong_questions q where id=$1',[question]);assert.equal(approved.final_text,answer.prompt);
    await childLogin();assert.equal((await read(draft.id)).state,'approved');assert.deepEqual((await submit(draft)).config.answers,[]);
    const task=await scalar('select public.generate_daily_wrong_review_task($1)',[child]);assert.ok(task);
    await client.query('reset role');assert.deepEqual(await scalar('select accepted_answers from public.task_review_answer_keys where task_id=$1 and question_id=$2',[task,question]),['4']);
    await parentLogin();
  });
  await check('concurrent parent confirmations admit one intent and exact request replay returns the same question',async()=>{
    await childLogin();const d=await upload();await submit(d,config,null);await parentLogin();
    const a=new pg.Client(client.connectionParameters),b=new pg.Client(client.connectionParameters);
    await a.connect();await b.connect();
    try {
      for(const peer of [a,b]) {await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:parent,role:'authenticated',session_id:'submission-parent'})]);await peer.query('set role authenticated');}
      const keys=[randomUUID(),randomUUID()],results=await Promise.allSettled([a.query(approveSql,[d.id,keys[0],answer]),b.query(approveSql,[d.id,keys[1],answer])]);
      assert.equal(results.filter(r=>r.status==='fulfilled').length,1);assert.equal(results.find(r=>r.status==='rejected').reason.code,'40001');
      const key=keys[results.findIndex(r=>r.status==='fulfilled')];const replay=await Promise.all([a.query(approveSql,[d.id,key,answer]),b.query(approveSql,[d.id,key,answer])]);assert.deepEqual(replay[0].rows,replay[1].rows);
    } finally {await a.end();await b.end();}
  });
  await check('pending submission pages use bounded stable timestamp UUID cursors and enforce current membership',async()=>{
    await client.query('reset role');await client.query('begin');
    try {
      await client.query(`insert into public.question_ocr_drafts(id,child_id,owner_id,original_path,processed_path,requires_parent_review,submitted_at,status,child_submission)
        select id,$1,$2,$3::text||'/'||id::text||'/original.jpg',$3::text||'/'||id::text||'/processed.jpg',true,'2026-01-01'::timestamptz,'manual',$4::jsonb
        from (select gen_random_uuid() id from generate_series(1,55)) x`,[child,input,family,config]);
      await parentLogin();const first=await list();assert.equal(first.items.length,50);assert.ok(first.next_cursor);
      const second=await scalar('select public.child_question_submissions($1,$2,$3)',[child,first.next_cursor.created_at,first.next_cursor.id]);
      assert.equal(second.items.length,7);assert.equal(second.next_cursor,null);
      assert.equal(new Set([...first.items,...second.items].map(r=>r.id)).size,57);
      await denied('select public.child_question_submissions($1,$2,null)',[child,'2026-01-01']);
    } finally {await client.query('rollback');}
    await client.query('reset role');await client.query('begin');
    try {await client.query('delete from public.family_members where family_id=$1 and user_id=$2',[family,input]);await childLogin();await denied('select public.child_question_submissions($1)',[child]);await denied('select public.child_question_submission($1)',[draft.id]);} finally {await client.query('rollback');}
    await parentLogin();
  });
  await check('confirmation replay still requires this session and actual wall clock PIN authorization',async()=>{
    await login(parent,'no-pin');await denied(approveSql,[draft.id,randomUUID(),answer]);await parentLogin();
    await client.query('reset role');await client.query('begin');
    try {
      await client.query("update public.parent_authorizations set expires_at=now()+interval '0.05 seconds' where family_id=$1 and user_id=$2",[family,parent]);
      await parentLogin();await client.query('select pg_sleep(0.08)');
      assert.equal(await scalar('select public.has_parent_authorization($1)',[family]),true);
      await denied(approveSql,[draft.id,randomUUID(),answer]);
    } finally {await client.query('rollback');}
    await parentLogin();
  });
  await check('submitted input participates in export and child deletion while unsubmitted other-owner drafts remain private',async()=>{
    await childLogin();const pending=await upload();await submit(pending);const privateDraft=await upload();await parentLogin();
    await client.query('reset role');const sections=await scalar('select public.child_export_source($1)',[child]);assert.equal(sections.length,40);
    const rows=sections.find(s=>s.name==='ocr_records').rows;
    assert.ok(rows.some(r=>r.id===pending.id&&r.requires_parent_review&&r.child_submission.prompt===config.prompt));assert.ok(!rows.some(r=>r.id===privateDraft.id));
    assert.ok(sections.find(s=>s.name==='audit_logs').rows.some(r=>r.target_id===pending.id&&r.action==='review.child_submitted'));
    await parentLogin();const preview=await scalar('select public.preview_child_deletion($1)',[child]);
    const job=await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[child,randomUUID(),preview.counts]);
    await client.query('reset role');const manifest=await scalar('select manifest from public.cleanup_jobs where id=$1',[job]);
    assert.ok(manifest.some(f=>f.path===pending.original_path));assert.ok(manifest.some(f=>f.path===privateDraft.processed_path));
    assert.equal(await scalar('select count(*)::int from public.question_media_upload_bindings where draft_id=$1',[pending.id]),0);
    await childLogin();await denied('select public.begin_child_question_upload($1,$2,$3)',[child,pending.id,hash]);await denied('select public.submit_child_question($1,$2,$3)',[pending.id,config,recognition]);
  });
  await login();
}
