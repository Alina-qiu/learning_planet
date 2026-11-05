import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function familyCreationCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(), session='creation-session', auth=()=>login(user,session);
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)',[user,'creation@example.test']);
  await auth();
  const command=(kind='family',family=randomUUID())=>({kind,family_id:family,child_id:randomUUID(),
    ...(kind==='family'?{family_name:'Retry family',timezone:'Asia/Shanghai'}:{}),
    nickname:'小星星',grade:2,preferences:{avatar_key:'rocket',textbook_labels:{math:'校本教材'}}});
  const original=command(), id=randomUUID(), sql='select public.resolve_family_creation($1,$2,$3)';
  const run=(request=id,payload=original,op='submit')=>scalar(sql,[request,payload,op]);
  async function peer() {
    const p=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});
    await p.connect();
    await p.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:session,iat:Math.floor(Date.now()/1000)})]);
    await p.query('set role authenticated'); return p;
  }

  await check('creation inspect is read-only, invalid payload rolls back, replay preserves family child wallet and audit',async()=>{
    assert.equal((await run(id,original,'inspect')).status,'unknown');
    for (const invalid of [{...original,grade:null},{...original,grade:0},{...original,nickname:null},
      {...original,family_name:'x'.repeat(81)},{...original,timezone:'Invalid/Zone'},
      {...original,preferences:{avatar_key:'photo',textbook_labels:{}}}]) {
      await denied(sql,[id,invalid,'submit']);
    }
    assert.equal(await scalar('select count(*)::int from public.families where owner_user_id=$1',[user]),0);
    const created=await run(); assert.equal(created.status,'created');
    assert.equal(created.child_id,original.child_id); assert.equal(created.family_id,original.family_id);
    // JSONB canonicalization is independent of top-level ordering, with nested values retained.
    const reversed=Object.fromEntries(Object.entries(original).reverse());
    assert.deepEqual(await run(id,reversed),created);
    assert.equal(await scalar('select count(*)::int from public.children where family_id=$1',[original.family_id]),1);
    assert.equal(await scalar('select count(*)::int from public.wallets where child_id=$1',[original.child_id]),1);
    await client.query("select public.set_parent_pin($1,'4321')",[original.family_id]);
    await client.query("select public.verify_parent_pin($1,'4321')",[original.family_id]);
    assert.equal(await scalar("select count(*)::int from public.audit_logs where details->>'request_id'=$1",[id]),1);
    const wallet=await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[original.child_id]);
    assert.equal(wallet.coin_balance,0); assert.equal(wallet.xp,0);
    assert.equal((await scalar('select to_jsonb(c) from public.children c where id=$1',[original.child_id])).avatar_key,'rocket');
    await denied(sql,[id,{...original,nickname:'Different'},'submit']);
    await denied('select * from public.family_creation_receipts');
  });

  await check('additional-child creation requires a fresh PIN and administrator, keeps stable IDs on retry',async()=>{
    const addition=command('child',original.family_id), request=randomUUID();
    await login(user,'without-pin'); await denied(sql,[request,addition,'submit']);
    await auth(); const saved=await run(request,addition);
    assert.deepEqual(await run(request,addition),saved);
    assert.equal(saved.status,'created');
    await login(otherUid,'foreign'); await denied(sql,[request,addition,'inspect']);
    await denied(sql,[randomUUID(),{...addition,child_id:randomUUID()},'submit']);
    await client.query('reset role');
    await client.query("insert into public.family_members(family_id,user_id,role) values($1,$2,'parent')",[original.family_id,otherUid]);
    await login(otherUid,'non-admin'); await client.query("select public.verify_parent_pin($1,'4321')",[original.family_id]);
    await denied(sql,[randomUUID(),{...addition,child_id:randomUUID()},'submit']);
    await auth();
    assert.equal(await scalar('select count(*)::int from public.children where family_id=$1',[original.family_id]),2);
  });

  await check('two connections replay one creation, conflicting payload accepts exactly one',async()=>{
    const p=await peer(), same=command('child',original.family_id), sameId=randomUUID();
    try {
      const results=await Promise.all([client.query(sql,[sameId,same,'submit']),p.query(sql,[sameId,same,'submit'])]);
      assert.deepEqual(results[0].rows,results[1].rows);
      const request=randomUUID(), payload=command('child',original.family_id);
      const race=await Promise.allSettled([
        client.query(sql,[request,payload,'submit']),
        p.query(sql,[request,{...payload,nickname:'Different'},'submit']),
      ]);
      assert.equal(race.filter(r=>r.status==='fulfilled').length,1);
      assert.equal(race.find(r=>r.status==='rejected').reason.code,'22023');
      assert.equal(await scalar('select count(*)::int from public.children where id=$1',[payload.child_id]),1);
    } finally { await p.end(); }
  });

  await check('cancellation fences late submit, while cancellation after success never deletes a profile',async()=>{
    const cancelled=command(), request=randomUUID();
    assert.equal((await run(request,cancelled,'cancel')).status,'cancelled');
    assert.equal((await run(request,cancelled,'submit')).status,'cancelled');
    assert.equal(await scalar('select count(*)::int from public.families where id=$1',[cancelled.family_id]),0);
    assert.equal((await run(id,original,'cancel')).status,'created');
    assert.equal(await scalar('select count(*)::int from public.children where id=$1',[original.child_id]),1);
    const p=await peer(), competing=command(), competingId=randomUUID();
    try {
      const results=await Promise.all([
        client.query(sql,[competingId,competing,'submit']),p.query(sql,[competingId,competing,'cancel']),
      ]);
      const states=results.map(r=>r.rows[0].resolve_family_creation.status);
      assert.equal(states[0],states[1]);
      assert.ok(['created','cancelled'].includes(states[0]));
      assert.equal(await scalar('select count(*)::int from public.children where id=$1',[competing.child_id]),states[0]==='created'?1:0);
    } finally {await p.end();}
  });

  await check('deleted child or family receipts cannot recreate data; expired privilege reveals no private payload',async()=>{
    const removed=command('child',original.family_id), request=randomUUID();
    await run(request,removed);
    const preview=await scalar('select public.preview_child_deletion($1)',[removed.child_id]);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[removed.child_id,randomUUID(),preview.counts]);
    assert.equal((await run(request,removed)).status,'unavailable');
    assert.equal((await run(request,removed,'cancel')).status,'unavailable');
    await denied(sql,[randomUUID(),removed,'submit']);
    const familyCommand=command(), familyRequest=randomUUID();
    await run(familyRequest,familyCommand);
    await client.query('reset role');
    await client.query('delete from public.families where id=$1',[familyCommand.family_id]);
    await auth();
    assert.equal((await run(familyRequest,familyCommand)).status,'unavailable');
    await login(user,'expired-session');
    const receipt=await run(id,original,'inspect');
    assert.equal(receipt.status,'created');
    assert.deepEqual(Object.keys(receipt).sort(),['child_id','family_id','request_id','status']);
    await auth();
  });

  await check('account deletion blocks pending creation and old JWT replay; receipt access remains private',async()=>{
    const deleting=randomUUID(), payload=command(), request=randomUUID();
    await client.query('reset role'); await client.query('insert into auth.users values($1,$2)',[deleting,'creation-deletion@example.test']);
    await login(deleting,'deleting-creation');
    await run(request,payload);
    await client.query("select public.set_parent_pin($1,'1234')",[payload.family_id]);
    await client.query("select public.verify_parent_pin($1,'1234')",[payload.family_id]);
    const preview=await scalar('select public.preview_account_deletion()');
    await scalar("select public.request_account_deletion($1,$2,'永久注销我的账号')",[randomUUID(),preview.scope]);
    for(const op of ['inspect','submit','cancel']) await denied(sql,[request,payload,op]);
    await denied(sql,[randomUUID(),command(),'submit']);
    await client.query('reset role');
    assert.equal(await scalar('select count(*)::int from public.family_creation_receipts where owner_id=$1',[deleting]),1);
    await client.query("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false)");
    await client.query('set role service_role');
    await denied('select * from public.family_creation_receipts');
    await denied(sql,[request,payload,'inspect']);
    await auth();
  });
}
