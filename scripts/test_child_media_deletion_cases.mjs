import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { executeCleanup } from '../supabase/functions/_shared/cleanup_worker.mjs';

export async function childMediaDeletionCases({client,scalar,login,denied,check}) {
  const owner=randomUUID();await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)',[owner,`${owner}@media-delete.test`]);
  await login(owner);
  await scalar("select public.onboard_family('Media deletion','Asia/Shanghai','First',2::smallint)");
  const family=await scalar('select family_id from public.family_members where user_id=$1',[owner]);
  await scalar("select public.set_parent_pin($1,'1234')",[family]);
  const auth=async()=>{await login(owner);await scalar("select public.verify_parent_pin($1,'1234')",[family]);};
  await auth();
  const child=await scalar("select id from public.children where family_id=$1 and nickname='First'",[family]);
  const sibling=await scalar("select public.create_child($1,'Sibling',2::smallint)",[family]);
  async function upload(id) {
    const draft=await scalar('select public.begin_question_ocr($1,$2)',[id,randomUUID()]);
    await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1),('wrong-question-images',$2)",[draft.original_path,draft.processed_path]);
    await scalar('select public.record_question_ocr($1,$2)',[draft.id,{text:'PRIVATE OCR'}]);
    const question=await scalar('select public.save_review_question($1,$2)',[id,{kind:'question',subject:'math',prompt:'Confirmed',answers:['Answer'],ocr_confirmed:true,ocr_draft_id:draft.id}]);
    return {...draft,question};
  }
  const first=await upload(child),other=await upload(sibling);
  const preview=(id)=>scalar('select public.preview_child_deletion($1)',[id]);
  const request=async(id,key=randomUUID())=>scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[id,key,(await preview(id)).counts]);
  await check('real family-path OCR upload can be deleted with its child while sibling images remain intact',async()=>{
    assert.ok(first.original_path.startsWith(`${family}/`));
    const key=await request(child);
    await client.query('reset role');
    const job=await scalar('select to_jsonb(j) from public.cleanup_jobs j where id=$1',[key]);
    assert.deepEqual(new Set(job.manifest.map(f=>f.path)),new Set([first.original_path,first.processed_path]));
    assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where child_id=$1',[child]),0);
    assert.equal(await scalar('select count(*)::int from public.deleted_ocr_drafts where draft_id=$1 and family_id=$2',[first.id,family]),1);
    await client.query("update public.cleanup_jobs set next_attempt_at=now()-interval '1 second' where id=$1",[key]);
    await client.query("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false)");await client.query('set role service_role');
    const claim=await scalar('select public.claim_cleanup_job($1)',[key]);
    assert.equal(claim.status,'claimed');
    const storage={from:bucket=>({
      async remove(paths){await client.query('reset role');await client.query('delete from storage.objects where bucket_id=$1 and name=any($2::text[])',[bucket,paths]);await client.query('set role service_role');return {error:null};},
      async exists(path){await client.query('reset role');const n=await scalar('select count(*)::int from storage.objects where bucket_id=$1 and name=$2',[bucket,path]);await client.query('set role service_role');return {data:n>0,error:null};},
    })};
    assert.equal(await executeCleanup(claim,storage,(id,lease,error)=>scalar('select public.finish_cleanup_job($1,$2,$3)',[id,lease,error])),'completed');
    await client.query('reset role');
    assert.equal(await scalar('select count(*)::int from storage.objects where name=any($1::text[])',[[other.original_path,other.processed_path]]),2);
    assert.equal(await scalar('select count(*)::int from public.wrong_questions where id=$1',[other.question]),1);
    await auth();await denied('select public.begin_question_ocr($1,$2)',[sibling,first.id]);
    await denied("select public.learning_report($1,'day',null)",[child]);
    assert.equal(await scalar("select public.request_child_deletion($1,$2,'{}','永久删除孩子')",[child,key]),key);
  });
  await check('child cleanup rejects unrelated family files, accepts its retained manifests, and fences legacy draft IDs',async()=>{
    const legacy=await scalar("select public.create_child($1,'Legacy',2::smallint)",[family]);
    const legacyDraft=randomUUID(),oldJob=randomUUID(),ownDraft=randomUUID();
    await client.query('reset role');
    await client.query(`insert into public.question_ocr_drafts(id,child_id,owner_id,original_path,processed_path)
      values($1,$2,$3,$4,$5)`,[legacyDraft,legacy,owner,`${legacy}/${legacyDraft}/original.jpg`,`${legacy}/${legacyDraft}/processed.jpg`]);
    await client.query('delete from public.question_ocr_drafts where id=$1',[legacyDraft]);
    assert.equal(await scalar('select family_id from public.deleted_ocr_drafts where draft_id=$1',[legacyDraft]),family);
    await auth();await denied('select public.begin_question_ocr($1,$2)',[legacy,legacyDraft]);
    await client.query('reset role');
    const file=path=>({bucket:'wrong-question-images',path});
    await client.query(`insert into public.cleanup_jobs(id,family_id,child_id,owner_id,scope,question_ids,draft_ids,manifest)
      values($1,$2,$3,$4,'originals','{}',$5,$6)`,[oldJob,family,legacy,owner,[other.id],JSON.stringify([file(other.original_path)])]);
    await auth();await assert.rejects(request(legacy),/不属于支持范围/);
    // Family directory alone is insufficient when no draft or retained manifest ID proves ownership.
    await client.query('reset role');
    const ownPath=`${family}/${ownDraft}/original.jpg`;
    await client.query("update public.cleanup_jobs set draft_ids='{}',manifest=$2 where id=$1",[oldJob,JSON.stringify([file(ownPath)])]);
    await auth();await assert.rejects(request(legacy),/不属于支持范围/);
    await client.query('reset role');
    await client.query('update public.cleanup_jobs set draft_ids=$2,manifest=$3 where id=$1',[oldJob,[ownDraft],JSON.stringify([file(`${randomUUID()}/${ownDraft}/original.jpg`)])]);
    await auth();await assert.rejects(request(legacy),/不属于支持范围/);
    await client.query('reset role');
    await client.query('update public.cleanup_jobs set manifest=$2 where id=$1',[oldJob,JSON.stringify([file(ownPath)])]);
    await auth();const deletion=await request(legacy);
    await client.query('reset role');
    assert.deepEqual(await scalar('select manifest from public.cleanup_jobs where id=$1',[deletion]),[file(ownPath)]);
    assert.equal(await scalar('select count(*)::int from public.children where id=$1',[sibling]),1);
    assert.equal(await scalar('select count(*)::int from storage.objects where name=$1',[other.original_path]),1);
  });
  await login();
}
