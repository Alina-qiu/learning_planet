import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';
import {executeAccountDeletion} from '../supabase/functions/_shared/account_deletion_worker.mjs';
import {executeCleanup} from '../supabase/functions/_shared/cleanup_worker.mjs';

export async function accountDeletionCases({client,scalar,login,denied,check,otherUid}) {
  const owner=randomUUID(),job=randomUUID();
  const service=async()=>{
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false)");
    await client.query('set role service_role');
  };
  const asOwner=()=>login(owner,'delete-account-session');
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)',[owner,'delete-me@example.test']);
  await asOwner();
  await client.query("select public.onboard_family('Dissolve mine','Asia/Shanghai','Removed child',1::smallint)");
  const owned=await scalar('select id from public.families where owner_user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[owned]);
  await client.query("select public.set_parent_pin($1,'2468')",[owned]);
  await client.query("select public.verify_parent_pin($1,'2468')",[owned]);
  await login(otherUid);
  await client.query("select public.onboard_family('Keep shared family','Asia/Shanghai','Shared child',2::smallint)");
  const shared=await scalar("select id from public.families where name='Keep shared family'");
  const sibling=await scalar('select id from public.children where family_id=$1',[shared]);
  await client.query("select public.set_parent_pin($1,'1357')",[shared]);
  await client.query("select public.verify_parent_pin($1,'1357')",[shared]);
  await client.query('reset role');
  await client.query("insert into public.family_members values($1,$2,'parent'),($3,$4,'parent')",[owned,otherUid,shared,owner]);
  const sharedQuestion=await scalar("insert into public.wrong_questions(child_id,subject,final_text) values($1,'math','Keep edited question') returning id",[sibling]);
  const files=[];
  for(const [kid,who] of [[child,owner],[child,otherUid],[sibling,owner],[sibling,otherUid]]) {
    const draft=randomUUID();
    const paths=[`${kid}/${draft}/original.jpg`,`${kid}/${draft}/processed.jpg`];
    await client.query(`insert into public.question_ocr_drafts(id,child_id,owner_id,original_path,processed_path,question_id)
      values($1,$2,$3,$4,$5,$6)`,[draft,kid,who,...paths,kid===sibling&&who===owner?sharedQuestion:null]);
    for(const path of paths) {
      files.push({bucket:'wrong-question-images',path,owner:who,child:kid});
      await client.query("insert into storage.objects(bucket_id,name,owner_id) values('wrong-question-images',$1,$2)",[path,who]);
    }
  }
  const pdf=randomUUID(),pdfPath=`${sibling}/${pdf}/worksheet.pdf`;
  await client.query(`insert into public.worksheet_jobs(id,family_id,child_id,owner_id,config,question_ids,pdf_path,status,lease_until)
    values($1,$2,$3,$4,'{}','{}',$5,'running',now()+interval '5 minutes')`,[pdf,shared,sibling,owner,pdfPath]);
  await client.query("insert into storage.objects(bucket_id,name,owner) values('worksheets',$1,$2)",[pdfPath,owner]);
  files.push({bucket:'worksheets',path:pdfPath,owner,child:sibling});
  await client.query("insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details) values($1,$2,'test','child',$3,'{\"private\":\"name and email\"}')",[shared,owner,sibling]);
  await asOwner();
  let preview;
  await check('account deletion requires every membership PIN, exact phrase, stable scope and self identity',async()=>{
    const context=await scalar('select public.account_deletion_context()');
    assert.equal(context.length,2); assert.equal(context.find(f=>f.id===owned).owned,true);
    await denied('select public.preview_account_deletion()');
    await client.query("select public.verify_parent_pin($1,'1357')",[shared]);
    preview=await scalar('select public.preview_account_deletion()');
    assert.deepEqual(preview.scope.owned_family_ids,[owned]);
    assert.deepEqual(preview.scope.child_ids,[child]); assert.equal(preview.scope.files,7);
    assert.equal(preview.scope.shared_uploads,1); assert.equal(preview.scope.shared_worksheets,1);
    await denied('select public.account_deletion_source($1)',[otherUid]);
    await denied('select public.request_account_deletion($1,$2,$3)',[job,preview.scope,'yes']);
    await denied('select public.request_account_deletion($1,$2,$3)',[job,{...preview.scope,files:0},'永久注销我的账号']);
    await denied('select public.claim_account_deletion($1)',[job]);
    await denied('select public.pending_account_deletions()');
  });
  await check('account acceptance deletes owned children, removes own shared media and preserves other families and identities',async()=>{
    assert.equal(await scalar('select public.request_account_deletion($1,$2,$3)',[job,preview.scope,'永久注销我的账号']),job);
    assert.equal(await scalar('select public.request_account_deletion($1,$2,$3)',[job,preview.scope,'永久注销我的账号']),job);
    await denied('select public.request_account_deletion($1,$2,$3)',[randomUUID(),preview.scope,'永久注销我的账号']);
    const status=await scalar('select public.account_deletion_status()');
    assert.equal(status.status,'queued'); assert.equal(status.manifest,undefined);
    await client.query('reset role');
    assert.equal(await scalar('select count(*)::int from public.children where id=$1',[child]),0);
    assert.equal(await scalar('select count(*)::int from public.children where id=$1',[sibling]),1);
    assert.equal(await scalar('select final_text from public.wrong_questions where id=$1',[sharedQuestion]),'Keep edited question');
    assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where owner_id=$1',[owner]),0);
    assert.equal(await scalar('select count(*)::int from public.question_ocr_drafts where child_id=$1 and owner_id=$2',[sibling,otherUid]),1);
    assert.equal(await scalar('select count(*)::int from public.worksheet_jobs where owner_id=$1',[owner]),0);
    assert.equal(await scalar('select count(*)::int from public.audit_logs where actor_user_id=$1',[owner]),0);
    assert.equal(await scalar('select count(*)::int from auth.users where id=$1',[owner]),1);
    assert.ok(await scalar("select next_attempt_at>created_at+interval '14 minutes' from public.account_deletion_jobs where id=$1",[job]));
  });
  await check('accepted account and owned family are inaccessible with old JWTs and remote members receive scoped purge notices',async()=>{
    await asOwner();
    assert.equal(await scalar('select count(*)::int from public.families'),0);
    assert.equal(await scalar('select public.is_family_member($1)',[shared]),false);
    await denied("select public.onboard_family('Resurrect','Asia/Shanghai','Child',1::smallint)");
    await denied("select public.create_child($1,'Resurrect',1::smallint)",[owned]);
    await denied("select public.verify_parent_pin($1,'1357')",[shared]);
    await denied('select * from public.account_deletion_jobs');
    await login(otherUid);
    assert.equal(await scalar('select public.is_family_member($1)',[owned]),false);
    assert.equal(await scalar('select public.is_family_member($1)',[shared]),true);
    assert.equal(await scalar('select public.account_deletion_status()'),null);
    const notices=(await client.query('select * from public.family_access_revocations')).rows;
    assert.ok(notices.some(n=>n.family_id===owned&&n.child_ids.includes(child)));
    assert.ok(notices.every(n=>n.user_id===otherUid));
    await client.query('reset role');
    await denied("insert into public.children(family_id,nickname,grade) values($1,'Late child',1)",[owned]);
    const sharedFile=files.find(f=>f.child===sibling&&f.owner===owner);
    await denied(`insert into public.question_ocr_drafts(id,child_id,owner_id,original_path,processed_path)
      values($1,$2,$3,$4,$5)`,[randomUUID(),sibling,otherUid,sharedFile.path,sharedFile.path.replace('original','processed')]);
    await denied(`insert into public.worksheet_jobs(id,family_id,child_id,owner_id,config,question_ids,pdf_path)
      values($1,$2,$3,$4,'{}','{}',$5)`,[pdf,shared,sibling,otherUid,pdfPath]);
  });
  const storage={from:bucket=>({
    remove:async(paths)=>{
      await client.query('reset role');
      // Mock provider removal only. Production always uses Storage API.
      await client.query('delete from storage.objects where bucket_id=$1 and name=any($2)',[bucket,paths]);
      await service(); return {error:null};
    },
    exists:async path=>{
      await client.query('reset role');
      const present=await scalar('select exists(select 1 from storage.objects where bucket_id=$1 and name=$2)',[bucket,path]);
      await service(); return present?{data:true}:{data:false,error:{status:404}};
    },
  })};
  await check('account worker waits for child cleanup and old PDF lease, and SQL rejects unverified files',async()=>{
    await service();
    assert.equal((await scalar('select public.claim_account_deletion($1)',[job])).status,'waiting');
    await client.query('reset role');
    await client.query("update public.account_deletion_jobs set next_attempt_at=now()-interval '1 second' where id=$1",[job]);
    await service();
    assert.equal((await scalar('select public.claim_account_deletion($1)',[job])).status,'waiting');
    await client.query('reset role');
    await client.query("update public.cleanup_jobs set next_attempt_at=now()-interval '1 second' where family_id=$1",[owned]);
    const ids=(await client.query("select id from public.cleanup_jobs where family_id=$1 and scope='child'",[owned])).rows;
    await service();
    for(const {id} of ids) {
      const claim=await scalar('select public.claim_cleanup_job($1)',[id]);
      assert.equal(await executeCleanup(claim,storage,(id,token,code)=>client.query('select public.finish_cleanup_job($1,$2,$3)',[id,token,code])),'completed');
    }
    await client.query('reset role');
    await client.query("update public.account_deletion_jobs set next_attempt_at=now()-interval '1 second' where id=$1",[job]);
    await service();
    const claim=await scalar('select public.claim_account_deletion($1)',[job]);
    await denied('select public.prepare_account_auth_deletion($1,$2)',[job,claim.lease_token]);
    await denied('select public.finish_account_deletion($1,$2,null)',[job,claim.lease_token]);
    await client.query("select public.finish_account_deletion($1,$2,'STORAGE_VERIFY_FAILED')",[job,claim.lease_token]);
  });
  let authFails=true,authCalls=0,checkedLateObject=false;
  const admin={storage,rpc:async(name,args)=>{
    try {
      if(name==='prepare_account_auth_deletion') {
        if(!checkedLateObject) {
          checkedLateObject=true;
          // Independent final check must detect a late ownerless file that was
          // not in the original manifest, even after all known files are gone.
          const latePath=`${owned}/${randomUUID()}/worksheet.pdf`;
          await client.query('reset role');
          await client.query("insert into storage.objects(bucket_id,name) values('worksheets',$1)",[latePath]);
          await service();
          await denied('select public.prepare_account_auth_deletion($1,$2)',[args.target_job_id,args.token]);
          await client.query('reset role');
          await client.query("delete from storage.objects where bucket_id='worksheets' and name=$1",[latePath]);
          await service();
        }
        return {data:await scalar('select public.prepare_account_auth_deletion($1,$2)',[args.target_job_id,args.token])};
      }
      await client.query('select public.finish_account_deletion($1,$2,$3)',[args.target_job_id,args.token,args.failure_code]);
      return {data:null};
    } catch(error){return {error};}
  },auth:{admin:{deleteUser:async(user,soft)=>{
    authCalls++; assert.equal(user,owner); assert.equal(soft,false);
    if(authFails) return {error:{code:'unexpected_failure'}};
    await client.query('reset role');
    // Disposable Auth API emulator. Tests verify real public-schema FK behavior.
    await client.query('delete from auth.users where id=$1',[user]);
    await service(); return {data:{user:{id:user}}};
  }}}};
  const retryClaim=async()=>{
    await client.query('reset role');
    await client.query("update public.account_deletion_jobs set next_attempt_at=now()-interval '1 second' where id=$1",[job]);
    await service(); return scalar('select public.claim_account_deletion($1)',[job]);
  };
  await check('Auth failure is durable after file and family cleanup, and a later retry completes only after Auth absence',async()=>{
    assert.equal(await executeAccountDeletion(await retryClaim(),admin),'failed');
    await client.query('reset role');
    assert.equal(await scalar('select count(*)::int from public.families where id=$1',[owned]),0);
    assert.equal(await scalar('select count(*)::int from public.families where id=$1',[shared]),1);
    assert.equal(await scalar('select count(*)::int from auth.users where id=$1',[owner]),1);
    assert.equal(await scalar('select phase from public.account_deletion_jobs where id=$1',[job]),'auth');
    assert.equal(await scalar('select error_code from public.account_deletion_jobs where id=$1',[job]),'AUTH_DELETE_FAILED');
    authFails=false;
    const claim=await retryClaim();
    assert.equal(await executeAccountDeletion(claim,admin),'completed');
    assert.equal(authCalls,2);
    assert.equal((await scalar('select public.claim_account_deletion($1)',[job])).status,'completed');
    await client.query('select public.finish_account_deletion($1,$2,null)',[job,randomUUID()]);
    await client.query('reset role');
    const record=await scalar('select to_jsonb(j) from public.account_deletion_jobs j where id=$1',[job]);
    assert.equal(record.status,'completed'); assert.deepEqual(record.manifest,[]); assert.deepEqual(record.owned_family_ids,[]);
    assert.equal(await scalar('select count(*)::int from auth.users where id=$1',[owner]),0);
    for(const file of files) assert.equal(await scalar('select exists(select 1 from storage.objects where bucket_id=$1 and name=$2)',[file.bucket,file.path]),file.child===sibling&&file.owner===otherUid);
    await login(otherUid);
    assert.ok((await client.query('select child_ids from public.family_access_revocations where family_id=$1',[owned])).rows[0].child_ids.includes(child));
  });
  await check('completed account metadata expires after 30 days without making old JWTs active again',async()=>{
    await client.query('reset role');
    await client.query("update public.account_deletion_jobs set completed_at=now()-interval '31 days' where id=$1",[job]);
    await service(); await client.query('select public.pending_account_deletions()');
    await client.query('reset role');
    assert.equal(await scalar('select count(*)::int from public.account_deletion_jobs where id=$1',[job]),0);
    await asOwner();
    await denied("select public.onboard_family('Old JWT','Asia/Shanghai','Child',1::smallint)");
    assert.equal(await scalar('select count(*)::int from public.families'),0);
  });
  const emptyUser=randomUUID(),emptyJob=randomUUID();
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)',[emptyUser,'empty@example.test']);
  await client.query("insert into storage.objects(bucket_id,name,owner_id) values('unexpected-bucket','unknown.bin',$1)",[emptyUser]);
  await login(emptyUser);
  await check('unsupported account-owned files reject the entire request without freezing a new account',async()=>{
    const preview=await scalar('select public.preview_account_deletion()');
    assert.deepEqual(preview.scope.owned_family_ids,[]);
    await denied('select public.request_account_deletion($1,$2,$3)',[emptyJob,preview.scope,'永久注销我的账号']);
    assert.equal(await scalar('select public.account_deletion_status()'),null);
    assert.deepEqual(await scalar('select public.account_deletion_context()'),[]);
  });
  await client.query('reset role');
  await client.query("delete from storage.objects where owner_id=$1",[emptyUser]);
  await login(emptyUser);
  await check('two sessions can request self-deletion before onboarding with one stable job',async()=>{
    const preview=await scalar('select public.preview_account_deletion()');
    const second=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});
    await second.connect();
    try {
      await second.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:emptyUser,session_id:'other-empty-session',role:'authenticated'})]);
      await second.query('set role authenticated');
      const sql='select public.request_account_deletion($1,$2,$3)';
      const args=[emptyJob,preview.scope,'永久注销我的账号'];
      const results=await Promise.all([client.query(sql,args),second.query(sql,args)]);
      assert.ok(results.every(r=>r.rows[0].request_account_deletion===emptyJob));
      await client.query('reset role');
      assert.equal(await scalar('select count(*)::int from public.account_deletion_jobs where user_id=$1',[emptyUser]),1);
    } finally {await second.end();}
  });
  await login();
}
