import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';
export async function imageUploadCases({client,scalar,login,denied,check,otherUid}){
  const user=randomUUID(),auth=()=>login(user,'image-session');
  await client.query('reset role');await client.query('insert into auth.users values($1,$2)',[user,'offline-images@example.test']);
  await auth();await client.query("select public.onboard_family('Image family','Asia/Shanghai','Images',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await client.query("select public.set_parent_pin($1,'2468')",[family]);await client.query("select public.verify_parent_pin($1,'2468')",[family]);
  const hash='a'.repeat(64),otherHash='b'.repeat(64),id=randomUUID();
  const begin=(draft=id,fingerprint=hash)=>scalar('select public.begin_question_media_upload($1,$2,$3)',[child,draft,fingerprint]);
  let draft;
  await check('durable image upload binds a stable payload and rejects changed content or stale PIN',async()=>{
    draft=await begin();assert.equal(draft.client_payload_hash,hash);assert.equal((await begin()).id,id);
    await denied('select public.begin_question_media_upload($1,$2,$3)',[child,id,otherHash]);
    await denied('select public.begin_question_media_upload($1,$2,$3)',[child,randomUUID(),'invalid']);
    await login(user,'without-pin');await denied('select public.begin_question_media_upload($1,$2,$3)',[child,id,hash]);await auth();
    await login(otherUid);await denied('select public.begin_question_media_upload($1,$2,$3)',[child,id,hash]);await auth();
    assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where id=$1',[id]),1);
    await denied('select * from public.question_media_upload_bindings');
  });
  let question;
  await check('partial upload and recognized or saved reply retries preserve provenance and create one question',async()=>{
    await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1)",[draft.original_path]);
    assert.equal((await begin()).status,'pending');await denied('select public.record_question_ocr($1,$2)',[id,{text:'raw 2+Z'}]);
    await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1)",[draft.processed_path]);
    await client.query('select public.record_question_ocr($1,$2)',[id,{text:'raw 2+Z'}]);assert.equal((await begin()).status,'recognized');
    const config={kind:'question',subject:'math',prompt:'2+2',answers:['4'],ocr_confirmed:true,ocr_draft_id:id};
    question=await scalar('select public.save_review_question($1,$2)',[child,config]);assert.equal((await begin()).status,'saved');
    assert.equal(await scalar('select public.save_review_question($1,$2)',[child,config]),question);
    assert.equal(await scalar('select count(*)::int from public.wrong_questions where child_id=$1',[child]),1);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[child]),0);
    assert.equal((await begin()).raw_text,'raw 2+Z');
    assert.equal((await scalar('select to_jsonb(d) from public.question_ocr_drafts d where id=$1',[id])).client_payload_hash,undefined);
  });
  await check('two upload sessions cannot bind different image payloads to the same draft UUID',async()=>{
    const draftId=randomUUID(),peer=new pg.Client(client.connectionParameters);await peer.connect();
    try{
      await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:'image-session'})]);await peer.query('set role authenticated');
      const results=await Promise.allSettled([begin(draftId),peer.query('select public.begin_question_media_upload($1,$2,$3)',[child,draftId,otherHash])]);
      assert.equal(results.filter(r=>r.status==='fulfilled').length,1);assert.equal(results.filter(r=>r.status==='rejected').length,1);
      assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where id=$1',[draftId]),1);
    }finally{await peer.end();}
  });
  await check('permanent cleanup prevents new and legacy offline clients resurrecting deleted image UUIDs',async()=>{
    const key=randomUUID();await scalar("select public.request_question_cleanup($1,'questions',$2,$3,'永久删除')",[child,[question],key]);
    await denied('select public.begin_question_media_upload($1,$2,$3)',[child,id,hash]);
    await client.query('reset role');await client.query("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false)");await client.query('set role service_role');
    const job=await scalar('select public.claim_cleanup_job($1)',[key]);await client.query('reset role');
    await client.query("delete from storage.objects where bucket_id='wrong-question-images' and name=any($1::text[])",[[draft.original_path,draft.processed_path]]);
    await client.query('set role service_role');await client.query('select public.finish_cleanup_job($1,$2,null)',[key,job.lease_token]);await auth();
    await denied('select public.begin_question_media_upload($1,$2,$3)',[child,id,hash]);
    await denied('select public.begin_question_ocr($1,$2)',[child,id]);
    assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where id=$1',[id]),0);
    await denied('select * from public.deleted_ocr_drafts');
  });
  await login();
}
