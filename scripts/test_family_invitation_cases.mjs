import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function familyInvitationCases({client,scalar,login,denied,check}) {
  const admin=randomUUID(), parent=randomUUID(), outsider=randomUUID(), session='invitation-admin';
  const email='invited-parent@example.test';
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2),($3,$4),($5,$6)',
    [admin,'invitation-admin@example.test',parent,email,outsider,'invitation-outsider@example.test']);
  await login(admin,session);
  await scalar("select public.onboard_family('Invitation family','Asia/Shanghai','child',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[admin]);
  await scalar("select public.set_parent_pin($1,'1234')",[family]);
  const auth=async()=>{await login(admin,session); await scalar("select public.verify_parent_pin($1,'1234')",[family]);};
  const sql='select public.resolve_family_invitation($1,$2,$3,$4)';
  const run=(command,id=randomUUID(),op='submit')=>scalar(sql,[family,id,command,op]);
  const invite={kind:'invite',email:'  INVITED-PARENT@example.test  '};
  const roster=()=>scalar('select public.load_family_members($1)',[family]);
  async function peer(user=admin,scope=session) {
    const p=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});
    await p.connect();
    await p.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:scope,email:'stale@example.test'})]);
    await p.query('set role authenticated'); return p;
  }

  await check('family roster and invitations require PIN, admin and account scope',async()=>{
    await denied('select public.load_family_members($1)',[family]);
    await denied(sql,[family,randomUUID(),invite,'submit']);
    await auth();
    const value=await roster();
    assert.equal(value.viewer_id,admin); assert.equal(value.can_manage,true);
    assert.equal(value.members[0].is_owner,true); assert.equal(value.members[0].is_self,true);
    assert.equal(value.members[0].role,'admin');
    await denied('select * from public.family_invitation_receipts');
    await login(outsider); await denied('select public.load_family_members($1)',[family]);
    await denied(sql,[family,randomUUID(),invite,'inspect']); await auth();
  });
  let original, request;
  await check('rejected invitation inputs remain cancellable and cannot be replayed after cancellation',async()=>{
    for (const command of [{kind:'invite',email:'bad address'},{kind:'revoke',invitation_id:'invalid',version:1}]) {
      const id=randomUUID();
      await denied(sql,[family,id,command,'submit']);
      assert.equal((await run(command,id,'inspect')).status,'unknown');
      assert.equal((await run(command,id,'cancel')).status,'abandoned');
      assert.equal((await run(command,id,'submit')).status,'abandoned');
    }
  });
  await check('invitation immutable receipt, normalization, inspect and lost-reply replay',async()=>{
    request=randomUUID();
    assert.equal((await run(invite,request,'inspect')).status,'unknown');
    assert.equal((await roster()).invitations.length,0);
    const a=await run(invite,request), b=await run(invite,request);
    assert.deepEqual(a,b); assert.equal(a.status,'applied');
    original=(await roster()).invitations[0]; assert.equal(original.email,email);
    assert.equal(original.version,1); assert.equal(original.expired,false);
    await run(invite); assert.deepEqual((await roster()).invitations[0],original);
    await denied(sql,[family,request,{...invite,email:'changed@example.test'},'submit']);
    await denied(sql,[family,randomUUID(),{kind:'invite',email:'bad address'},'submit']);
    await denied(sql,[family,randomUUID(),{...invite,extra:'no'},'submit']);
    assert.equal((await run(invite,request,'cancel')).status,'applied');
  });
  await check('abandoning an unresolved invitation fences late submit and concurrent retries',async()=>{
    const id=randomUUID(), command={kind:'invite',email:'never@example.test'};
    assert.equal((await run(command,id,'cancel')).status,'abandoned');
    assert.equal((await run(command,id)).status,'abandoned');
    const p=await peer();
    try {
      const key=randomUUID(), value={kind:'invite',email:'race@example.test'};
      const replies=await Promise.all([client.query(sql,[family,key,value,'submit']),p.query(sql,[family,key,value,'cancel'])]);
      assert.deepEqual(replies[0].rows,replies[1].rows);
      const exists=(await roster()).invitations.some(i=>i.email===value.email);
      assert.equal(exists,replies[0].rows[0].resolve_family_invitation.status==='applied');
    } finally {await p.end();}
    assert.equal((await roster()).invitations.some(i=>i.email===command.email),false);
  });
  await check('renewal and cancellation compare versions; old receipt never cancels renewed invitation',async()=>{
    const renew={kind:'renew',invitation_id:original.id,version:original.version};
    assert.equal((await run(renew)).status,'conflict');
    await client.query('reset role');
    await client.query("update public.family_invitations set expires_at=now()-interval '1 second' where id=$1",[original.id]);
    await auth();
    assert.equal((await roster()).invitations.find(i=>i.id===original.id).expired,true);
    const renewalId=randomUUID(); assert.equal((await run(renew,renewalId)).status,'applied');
    const updated=(await roster()).invitations.find(i=>i.id===original.id);
    assert.equal(updated.version,2); assert.equal(updated.expired,false);
    assert.equal((await run({kind:'revoke',invitation_id:original.id,version:1})).status,'conflict');
    assert.equal((await run(renew,renewalId)).status,'applied');
    assert.deepEqual((await roster()).invitations.find(i=>i.id===original.id),updated);
    assert.equal((await run({kind:'revoke',invitation_id:original.id,version:2})).status,'applied');
    const p=await peer(parent);
    try {assert.equal((await p.query('select public.accept_family_invitations()')).rows[0].accept_family_invitations,0);}
    finally {await p.end();}
    await run(invite);
    original=(await roster()).invitations.find(i=>i.email===email);
    assert.notEqual(original.id,updated.id); assert.equal(original.version,1);
    // Replaying the original invite cannot replace the new invitation.
    await run(invite,request); assert.deepEqual((await roster()).invitations.find(i=>i.email===email),original);
  });
  await check('acceptance uses current auth email and races cancellation without orphaning membership',async()=>{
    const p=await peer(parent,'parent-session');
    try {
      const revoke={kind:'revoke',invitation_id:original.id,version:original.version};
      const results=await Promise.all([
        client.query(sql,[family,randomUUID(),revoke,'submit']),p.query('select public.accept_family_invitations()')]);
      const accepted=results[1].rows[0].accept_family_invitations;
      assert.equal(results[0].rows[0].resolve_family_invitation.status,accepted?'conflict':'applied');
      assert.equal((await roster()).members.some(m=>m.user_id===parent),accepted===1);
      if (!accepted) {await run(invite); assert.equal((await p.query('select public.accept_family_invitations()')).rows[0].accept_family_invitations,1);}
      assert.equal((await p.query('select public.accept_family_invitations()')).rows[0].accept_family_invitations,0);
    } finally {await p.end();}
    assert.equal((await run(invite)).status,'already_member');
    assert.equal((await roster()).invitations.some(i=>i.email===email),false);
  });
  await check('ordinary parent sees masked roster, cannot invite and child mode cannot read invitation emails',async()=>{
    await login(parent,'parent-session');
    await denied('select public.load_family_members($1)',[family]);
    await scalar("select public.verify_parent_pin($1,'1234')",[family]);
    const value=await roster(); assert.equal(value.can_manage,false); assert.deepEqual(value.invitations,[]);
    assert.equal(value.members.find(m=>m.is_self).email,email);
    assert.equal(value.members.find(m=>m.is_owner).email,'i***@example.test');
    await denied(sql,[family,randomUUID(),invite,'submit']);
    await login(admin,'child-session');
    assert.equal(await scalar('select count(*)::int from public.family_invitations'),0);
    await denied(sql,[family,request,invite,'inspect']); await auth();
    await client.query('reset role');
    const audit=await scalar("select details from public.audit_logs where action='family.invitation.invite' and family_id=$1 limit 1",[family]);
    assert.deepEqual(Object.keys(audit).sort(),['request_id','version']);
    const receipt=await scalar('select row_to_json(r) from public.family_invitation_receipts r where owner_id=$1 limit 1',[admin]);
    assert.equal(JSON.stringify(receipt).includes('@'),false);
    await auth();
  });
}
