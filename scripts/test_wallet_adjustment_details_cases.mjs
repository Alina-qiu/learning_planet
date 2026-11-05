import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export async function walletAdjustmentDetailsCases({client,scalar,login,denied,check}) {
  const user=randomUUID(), member=randomUUID(), outsider=randomUUID();
  await client.query('reset role');
  for (const [id,email] of [[user,'adjustment-admin@example.test'],[member,'adjustment-parent@example.test'],[outsider,'adjustment-outsider@example.test']]) {
    await client.query('insert into auth.users values($1,$2)',[id,email]);
  }
  const auth=async(who=user)=>login(who,'adjustment-details'); await auth();
  const family=await scalar("select public.onboard_family('Details','Asia/Shanghai','Reader',2::smallint)");
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'2468')",[family]);
  const pin=()=>scalar("select public.verify_parent_pin($1,'2468')",[family]); await pin();
  const command=randomUUID();
  await scalar("select public.adjust_wallet($1,300,20,'完成家务，补记奖励',$2)",[child,command]);
  const rows=(await client.query('select id,asset_type,amount from public.ledger_entries where child_id=$1 and source_id=$2 order by asset_type',[child,command])).rows;
  const sql='select public.wallet_adjustment_details($1,$2)';
  const detail=(id=rows[0].id)=>scalar(sql,[child,id]);
  const baseline=await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]);
  await check('adjustment details bind the original audit to both assets without exposing internal keys',async()=>{
    for(const row of rows) {
      const result=await detail(row.id);
      assert.equal(result.owner_id,user);assert.equal(result.child_id,child);assert.equal(result.family_id,family);
      assert.equal(result.family_timezone,'Asia/Shanghai');assert.equal(result.entry.id,row.id);
      assert.equal(result.entry.amount,row.amount);assert.ok(!('idempotency_key' in result.entry));assert.ok(!('source_id' in result.entry));
      assert.equal(result.audit.reason,'完成家务，补记奖励');assert.equal(result.audit.coins,300);assert.equal(result.audit.xp,20);
      assert.equal(result.audit.actor.email,'adjustment-admin@example.test');assert.equal(result.audit.actor.is_self,true);
      assert.equal(result.audit.actor.status,'member');assert.equal(result.audit.created_at,result.entry.created_at);
    }
    await client.query('begin read only');try { await detail(); } finally { await client.query('rollback'); }
    assert.deepEqual(await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]),baseline);
  });
  await check('audit access requires current PIN, matching child, adjustment type and authenticated membership',async()=>{
    await scalar('select public.revoke_parent_authorization($1)',[family]);await denied(sql,[child,rows[0].id]);await pin();
    await denied(sql,[randomUUID(),rows[0].id]);await denied(sql,[child,randomUUID()]);
    await auth(outsider);await denied(sql,[child,rows[0].id]);
    for(const role of ['anon','service_role']) {await client.query('reset role');await client.query('set role '+role);await denied(sql,[child,rows[0].id]);}
    await auth();
    const sibling=await scalar("select public.create_child($1,'Sibling',2::smallint)",[family]);
    await denied(sql,[sibling,rows[0].id]);
    await client.query('reset role');
    const other=await scalar("insert into public.ledger_entries(child_id,asset_type,amount,source_type,idempotency_key) values($1,'coin',0,'task_completion',$2) returning id",[child,randomUUID()]);
    await auth(); await denied(sql,[child,other]);
  });
  await check('non-admin parent receives masked actor identity and retains historical removed-member attribution',async()=>{
    await client.query('reset role');await client.query("insert into public.family_members values($1,$2,'parent')",[family,member]);
    await auth(member);await pin();
    assert.equal((await detail()).audit.actor.email,'a***@example.test');
    const second=randomUUID(); await scalar("select public.adjust_wallet($1,-5,0,'纠正多记金币',$2)",[child,second]);
    const entry=await scalar("select id from public.ledger_entries where child_id=$1 and source_id=$2 and asset_type='coin'",[child,second]);
    assert.equal((await detail(entry)).audit.actor.is_self,true);
    await client.query('reset role');await client.query('delete from public.family_members where family_id=$1 and user_id=$2',[family,member]);
    await auth(); const past=await detail(entry);
    assert.equal(past.audit.actor.status,'former_member');assert.equal(past.audit.actor.email,'adjustment-parent@example.test');
    assert.equal(past.audit.reason,'纠正多记金币');
    await auth(member);await denied(sql,[child,entry]);await auth();
  });
  await check('redacted audit stays unavailable and cannot match an unrelated family audit',async()=>{
    await client.query('reset role');
    await client.query("update public.audit_logs set actor_user_id=null,details='{}' where action='wallet.adjust' and details->>'command_id'=$1",[command]);
    await client.query("insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details) values($1,$2,'wallet.limit','child',$3,$4)",[family,user,child,{command_id:command,reason:'Not this adjustment'}]);
    await auth();const result=await detail();assert.equal(result.audit,null);assert.equal(result.entry.amount,300);
  });
  await check('all economy sections return the authoritative family timezone with stable pages',async()=>{
    for(const section of ['rewards','redemptions','pending','ledger']) {
      const page=await scalar('select public.economy_page($1,$2,$3)',[child,family,section]);
      assert.equal(page.family_timezone,'Asia/Shanghai');assert.equal(page.child_id,child);
    }
  });
}
