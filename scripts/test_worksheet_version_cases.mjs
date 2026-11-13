import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {RENDERER_VERSION} from '../supabase/functions/_shared/worksheet_pdf.mjs';

export async function worksheetVersionCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(), auth=()=>login(user,'worksheet-version');
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)',[user,'worksheet-version@example.test']);
  await auth();await scalar("select public.onboard_family('PDF','Asia/Shanghai','Child',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'2468')",[family]);
  await scalar("select public.verify_parent_pin($1,'2468')",[family]);
  const question=await scalar('select public.save_review_question($1,$2)',[child,
    {kind:'question',subject:'math',prompt:'12 + 8 = ?',answers:['20'],explanation:'Frozen answer'}]);
  const create=()=>scalar('select public.request_worksheet($1,$2,$3,$4)',[child,[question],{},randomUUID()]);
  const row=id=>scalar('select to_jsonb(j) from public.worksheet_jobs j where id=$1',[id]);
  const claim=id=>scalar('select public.claim_worksheet($1)',[id]);
  async function admin(sql,args) {
    await client.query('reset role');
    try {return await client.query(sql,args);} finally {await auth();}
  }
  async function trusted() {
    await client.query('reset role');
    await scalar("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:'service_role'})]);
    await client.query('set role service_role');
  }
  const result=version=>({pages:1,byte_size:6000000,sha256:'b'.repeat(64),renderer_version:version});
  const finish=(id,token,version)=>client.query('select public.finish_worksheet($1,$2,$3)',[id,token,result(version)]);
  async function object(path) {
    await admin("insert into storage.objects(bucket_id,name) values('worksheets',$1)",[path]);
  }

  await check('new worksheet version matches the actual renderer and completion still rejects mismatched results',async()=>{
    const id=await create();assert.equal((await row(id)).renderer_version,RENDERER_VERSION);
    const lease=await claim(id);await object(lease.pdf_path);await trusted();
    await denied('select public.finish_worksheet($1,$2,$3)',[id,lease.lease_token,result('a4-v1')]);
    await finish(id,lease.lease_token,RENDERER_VERSION);
    await auth();assert.equal((await row(id)).status,'ready');
  });
  for(const state of ['queued','failed']) {
    await check(`legacy ${state} worksheet upgrades only when claimed and preserves its frozen snapshot`,async()=>{
      const id=await create();
      await admin("update public.worksheet_jobs set renderer_version='a4-v1',status=$2,error_code='PDF_GENERATION_FAILED' where id=$1",[id,state]);
      const before=await row(id), lease=await claim(id), after=await row(id);
      assert.equal(lease.status,'claimed');assert.equal(after.renderer_version,RENDERER_VERSION);
      assert.equal(after.attempts,before.attempts+1);assert.equal(after.error_code,null);
      assert.deepEqual(after.question_ids,before.question_ids);assert.deepEqual(after.config,before.config);
      assert.equal(after.pdf_path,before.pdf_path);assert.equal(after.created_at,before.created_at);
      assert.equal(after.expires_at,before.expires_at);assert.equal(lease.snapshot.items[0].prompt,'12 + 8 = ?');
      assert.deepEqual(lease.snapshot.items[0].accepted_answers,['20']);
    });
  }
  await check('active legacy lease can finish with its original renderer and ready PDFs remain unchanged',async()=>{
    const id=await create(), lease=await claim(id);
    await admin("update public.worksheet_jobs set renderer_version='a4-v1' where id=$1",[id]);
    const running=await row(id);assert.equal((await claim(id)).status,'running');
    assert.deepEqual(await row(id),running);
    await object(lease.pdf_path);await trusted();await finish(id,lease.lease_token,'a4-v1');await auth();
    const ready=await row(id);assert.equal((await claim(id)).status,'ready');assert.deepEqual(await row(id),ready);
    assert.equal(ready.renderer_version,'a4-v1');assert.equal(ready.attempts,1);
  });
  await check('expired legacy lease upgrades on reclaim and rejects the previous worker token',async()=>{
    const id=await create(), old=await claim(id);
    await admin("update public.worksheet_jobs set renderer_version='a4-v1',lease_until=now()-interval '1 second' where id=$1",[id]);
    const fresh=await claim(id);assert.notEqual(fresh.lease_token,old.lease_token);
    assert.equal((await row(id)).renderer_version,RENDERER_VERSION);
    await object(fresh.pdf_path);await trusted();
    await denied('select public.finish_worksheet($1,$2,$3)',[id,old.lease_token,result('a4-v1')]);
    await finish(id,fresh.lease_token,RENDERER_VERSION);await auth();assert.equal((await row(id)).attempts,2);
  });
  await check('unauthorized claims cannot upgrade legacy jobs while trusted dispatch can',async()=>{
    const id=await create();await admin("update public.worksheet_jobs set renderer_version='a4-v1' where id=$1",[id]);
    const before=await row(id);await login(otherUid);await denied('select public.claim_worksheet($1)',[id]);
    await auth();await scalar('select public.revoke_parent_authorization($1)',[family]);
    await denied('select public.claim_worksheet($1)',[id]);await scalar("select public.verify_parent_pin($1,'2468')",[family]);
    assert.deepEqual(await row(id),before);
    await trusted();assert.equal((await claim(id)).status,'claimed');await auth();
    assert.equal((await row(id)).renderer_version,RENDERER_VERSION);
  });
  await check('expired worksheets remain unavailable without changing version or retention',async()=>{
    const id=await create();
    await admin("update public.worksheet_jobs set renderer_version='a4-v1',expires_at=now()-interval '1 second' where id=$1",[id]);
    const before=await row(id);await denied('select public.claim_worksheet($1)',[id]);assert.deepEqual(await row(id),before);
  });
}
