import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function familyMemberRemovalCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(), parent=randomUUID(), outsider=randomUUID(), parentEmail='removal-parent@example.test';
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2),($3,$4),($5,$6)',
    [owner,'removal-admin@example.test',parent,parentEmail,outsider,'removal-outsider@example.test']);
  const auth=()=>login(owner,'removal-admin');
  await auth(); await scalar("select public.onboard_family('Removal family','Asia/Shanghai','child',2::smallint)");
  const family=await scalar('select family_id from public.family_members where user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'1234')",[family]);
  await scalar("select public.verify_parent_pin($1,'1234')",[family]);
  await client.query('reset role');
  await client.query("insert into public.family_members values($1,$2,'parent')",[family,parent]);
  const task=await scalar("insert into public.task_instances(child_id,title,due_date,source_type,coin_reward,xp_reward,idempotency_key) values($1,'Keep shared task',current_date,'parent_template',3,4,$2) returning id",[child,randomUUID()]);
  await login(parent,'removal-parent');
  await scalar("select public.verify_parent_pin($1,'1234')",[family]);
  const snapshot=await scalar('select public.task_sync_snapshot($1)',[child]);
  await auth();
  const sql='select public.resolve_family_member_removal($1,$2,$3,$4)', request=randomUUID();
  const command={kind:'remove',user_id:parent,version:1};
  const run=(payload=command,id=request,op='submit')=>scalar(sql,[family,id,payload,op]);
  const roster=()=>scalar('select public.load_family_members($1)',[family]);
  const states=()=>scalar('select public.family_membership_access()');
  async function peer(user=parent,session='removal-parent') {
    const p=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});await p.connect();
    await p.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:session})]);
    await p.query('set role authenticated'); return p;
  }
  await check('member removal requires admin PIN and protects administrators/self; direct membership writes are closed',async()=>{
    const members=(await roster()).members;
    assert.equal(members.find(m=>m.user_id===parent).can_remove,true);
    assert.equal(members.find(m=>m.user_id===owner).can_remove,false);
    await denied('delete from public.family_members where family_id=$1 and user_id=$2',[family,owner]);
    await denied('update public.family_members set role=\'admin\' where family_id=$1 and user_id=$2',[family,parent]);
    await denied(sql,[family,randomUUID(),{...command,user_id:owner},'submit']);
    await login(owner,'child-mode');await denied(sql,[family,request,command,'submit']);
    await login(parent,'removal-parent');await denied(sql,[family,request,command,'submit']);
    await denied('select * from public.family_membership_states');await auth();
    assert.equal((await run(command,request,'inspect')).status,'unknown');
  });
  await check('removal revokes all parent sessions and offline leases without deleting shared child task or wallet',async()=>{
    const before=await scalar('select row_to_json(w) from public.wallets w where child_id=$1',[child]);
    const receipt=await run();assert.equal(receipt.status,'applied');assert.deepEqual(await run(),receipt);
    assert.equal((await roster()).members.some(m=>m.user_id===parent),false);
    assert.deepEqual(await scalar('select row_to_json(w) from public.wallets w where child_id=$1',[child]),before);
    assert.equal(await scalar('select count(*)::int from public.task_instances where id=$1',[task]),1);
    await client.query('reset role');
    assert.equal(await scalar('select count(*)::int from public.task_sync_leases where id=$1',[snapshot.lease_id]),0);
    assert.equal(await scalar('select count(*)::int from public.parent_authorizations where family_id=$1 and user_id=$2',[family,parent]),0);
    await login(parent,'removal-parent');
    await denied('select public.task_sync_snapshot($1)',[child]);
    await denied('select public.load_family_members($1)',[family]);
    const access=await states(); assert.equal(access.owner_id,parent);
    const lost=access.states.find(s=>s.family_id===family);
    assert.equal(lost.active,false);assert.equal(lost.version,2);assert.equal(lost.last_revoked_version,2);assert.ok(lost.child_ids.includes(child));
    await login(outsider);assert.deepEqual((await states()).states,[]);await auth();
  });
  await check('rejoining has a new membership version and cannot restore old PIN leases or replay a prior removal',async()=>{
    await scalar('select public.invite_family_parent($1,$2)',[family,parentEmail]);
    await login(parent,'removal-parent');assert.equal(await scalar('select public.accept_family_invitations()'),1);
    assert.equal(await scalar('select public.has_parent_authorization($1)',[family]),false);
    const state=(await states()).states.find(s=>s.family_id===family);
    assert.equal(state.active,true);assert.equal(state.version,3);assert.equal(state.last_revoked_version,2);
    const stale={command_id:randomUUID(),task_id:task,kind:'start',lease_id:snapshot.lease_id,
      expected_version:0,occurred_at:new Date().toISOString()};
    assert.equal((await scalar('select public.apply_task_command($1)',[stale])).outcome,'conflict');
    assert.notEqual((await scalar('select public.task_sync_snapshot($1)',[child])).lease_id,snapshot.lease_id);
    await auth();
    assert.equal((await run()).status,'applied');
    assert.equal((await run(command,randomUUID())).status,'conflict');
    assert.equal((await roster()).members.find(m=>m.user_id===parent).version,3);
    await denied(sql,[family,request,{...command,version:3},'submit']);
  });
  await check('cancel barrier and invalid target recovery never remove a member',async()=>{
    const id=randomUUID(), payload={...command,version:3};
    assert.equal((await run(payload,id,'cancel')).status,'abandoned');
    assert.equal((await run(payload,id)).status,'abandoned');
    const bad={kind:'remove',user_id:'invalid',version:1}, invalid=randomUUID();
    await denied(sql,[family,invalid,bad,'submit']);
    assert.equal((await run(bad,invalid,'cancel')).status,'abandoned');
    assert.equal((await run({...command,user_id:outsider},randomUUID())).status,'conflict');
    assert.equal((await roster()).members.some(m=>m.user_id===parent),true);
  });
  await check('removal and accepting an older pending invitation serialize; removed member cannot auto-rejoin',async()=>{
    await client.query('reset role');
    await client.query('insert into public.family_invitations(family_id,email,invited_by) values($1,$2,$3)',[family,parentEmail,owner]);await auth();
    const p=await peer();
    try {
      const result=await Promise.all([run({...command,version:3},randomUUID()),p.query('select public.accept_family_invitations()')]);
      assert.equal(result[0].status,'applied');
      assert.equal((await p.query('select public.accept_family_invitations()')).rows[0].accept_family_invitations,0);
      assert.equal((await roster()).members.some(m=>m.user_id===parent),false);
    } finally {await p.end();}
  });
  await check('a real snapshot transaction blocks removal until commit, then its newly minted lease is revoked',async()=>{
    await scalar('select public.invite_family_parent($1,$2)',[family,parentEmail]);
    const p=await peer();
    try {
      await p.query('select public.accept_family_invitations()');
      const member=(await roster()).members.find(m=>m.user_id===parent);
      const adminPid=await scalar('select pg_backend_pid()');
      await p.query('begin');
      const lease=(await p.query('select public.task_sync_snapshot($1)',[child])).rows[0].task_sync_snapshot.lease_id;
      const removal=run({...command,version:member.version},randomUUID());
      let blockers=[];
      for(let i=0;i<40;i++) {
        blockers=(await p.query('select pg_blocking_pids($1) as ids',[adminPid])).rows[0].ids;
        if(blockers.length) break;
        await new Promise(resolve=>setTimeout(resolve,25));
      }
      assert.ok(blockers.length>0,'removal must wait on the snapshot family lock');
      await p.query('commit');assert.equal((await removal).status,'applied');
      await client.query('reset role');
      assert.equal(await scalar('select count(*)::int from public.task_sync_leases where id=$1',[lease]),0);await auth();
    } finally {await p.query('rollback');await p.end();}
  });
  await check('revocations survive family dissolution and remain account-scoped; account deletion cascades its notices',async()=>{
    await client.query('reset role');await client.query('delete from public.families where id=$1',[family]);
    await login(parent,'removal-parent');
    const state=(await states()).states.find(s=>s.family_id===family);
    assert.equal(state.active,false);assert.ok(state.child_ids.includes(child));
    await client.query('reset role');await client.query('delete from auth.users where id=$1',[parent]);
    assert.equal(await scalar('select count(*)::int from public.family_membership_states where user_id=$1',[parent]),0);
    assert.equal(await scalar('select count(*)::int from public.family_membership_states where user_id=$1',[owner]),1);
  });
}
