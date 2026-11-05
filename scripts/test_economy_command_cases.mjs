import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function economyCommandCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(), stranger=randomUUID();
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2),($3,$4)',[owner,'durable-wallet@example.test',stranger,'durable-outsider@example.test']);
  const auth=()=>login(owner,'durable-wallet'); await auth();
  await scalar("select public.onboard_family('Durable wallet','Asia/Shanghai','Child',2::smallint)");
  const family=await scalar('select family_id from public.family_members where user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'1234')",[family]);
  const pin=()=>scalar("select public.verify_parent_pin($1,'1234')",[family]); await pin();
  await scalar("select public.adjust_wallet($1,2000,100,'setup',$2,true)",[child,randomUUID()]);
  const reward=await scalar('select public.save_reward($1,$2)',[family,{title:'Book',cost:120,rules:'Together',stock_total:5,quota_period:'none'}]);
  const version=await scalar('select version from public.rewards where id=$1',[reward]);
  const command={kind:'redeem',reward_id:reward,version}, key=randomUUID();
  const sql='select public.resolve_economy_command($1,$2,$3,$4)';
  const run=(payload=command,id=key,op='submit',kid=child)=>scalar(sql,[kid,id,payload,op]);
  let first;
  await check('durable redemption inspect does not freeze; receipt replay survives price and availability changes',async()=>{
    assert.equal((await run(command,key,'inspect')).status,'unknown');
    assert.equal(await scalar('select count(*) from public.redemptions where request_key=$1',[key]),'0');
    first=await run(); assert.equal(first.status,'applied'); assert.equal(first.owner_id,owner);
    const row=await scalar('select to_jsonb(r) from public.rewards r where id=$1',[reward]);
    await scalar('select public.save_reward($1,$2,$3)',[family,{...row,cost:999,active:false,expected_version:row.version},reward]);
    assert.deepEqual(await run(),first); assert.deepEqual(await run(command,key,'cancel'),first);
    assert.equal(await scalar('select count(*) from public.ledger_entries where source_id=$1 and source_type=$2',[first.redemption_id,'redemption_freeze']),'1');
    assert.equal(await scalar('select frozen_amount from public.redemptions where id=$1',[first.redemption_id]),120);
  });
  await check('durable economic results are private, child bound and payload bound',async()=>{
    await denied('select * from public.economy_command_receipts');
    await denied(sql,[child,key,{...command,version:version+1},'inspect']);
    await login(stranger,'stranger'); await denied(sql,[child,key,command,'inspect']); await auth();
    const other=await scalar("select public.create_child($1,'Other',1::smallint)",[family]);
    await denied(sql,[other,key,command,'inspect']);
    await denied(sql,[child,randomUUID(),{kind:'unexpected'},'submit']);
  });
  await check('cancel barriers accept rejected original payloads and block late mutation without refunding applied requests',async()=>{
    const bad={kind:'redeem',reward_id:'invalid',version:0}, id=randomUUID();
    await denied(sql,[child,id,bad,'submit']);
    assert.equal((await run(bad,id,'cancel')).status,'abandoned');
    assert.equal((await run(bad,id)).status,'abandoned');
    assert.equal(await scalar('select status from public.redemptions where id=$1',[first.redemption_id]),'requested');
    assert.equal(await scalar('select count(*) from public.redemptions where request_key=$1',[id]),'0');
  });
  await check('durable adjustments require PIN even to inspect and retain original reason and amount on replay',async()=>{
    const id=randomUUID(), change={kind:'adjust',coins:600,xp_amount:20,reason:'Explicit parent reason',large_amount_confirmed:true};
    await scalar('select public.revoke_parent_authorization()');
    await denied(sql,[child,id,change,'submit']); await denied(sql,[child,id,change,'inspect']); await pin();
    await denied(sql,[child,randomUUID(),{...change,large_amount_confirmed:false},'submit']);
    const before=await scalar('select coin_balance from public.wallets where child_id=$1',[child]);
    const receipt=await run(change,id); assert.equal(receipt.status,'applied');
    assert.deepEqual(await run(change,id,'inspect'),receipt); assert.deepEqual(await run(change,id),receipt);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[child]),before+600);
    await denied(sql,[child,id,{...change,reason:'Changed reason'},'submit']);
    await client.query('reset role');
    const saved=await scalar('select to_jsonb(r) from public.economy_command_receipts r where request_id=$1',[id]);
    assert.ok(!JSON.stringify(saved).includes(change.reason)); await auth();
  });
  await check('two real sessions race economic submit and stop with exactly one durable outcome',async()=>{
    const a=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});
    const b=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});
    try {
      for(const peer of [a,b]) { await peer.connect(); await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:owner,role:'authenticated',session_id:'durable-wallet'})]); await peer.query('set role authenticated'); }
      const change={kind:'adjust',coins:7,xp_amount:0,reason:'Race'}, id=randomUUID();
      const results=await Promise.all([a.query(sql,[child,id,change,'submit']),b.query(sql,[child,id,change,'cancel'])]);
      const left=Object.values(results[0].rows[0])[0], right=Object.values(results[1].rows[0])[0];
      assert.deepEqual(left,right);
      assert.ok(['applied','abandoned'].includes(left.status));
      assert.equal(await scalar('select count(*) from public.ledger_entries where idempotency_key=$1',['adjust:'+id+':coin']),left.status==='applied'?'1':'0');
    } finally { await a.end(); await b.end(); }
  });
  await check('economic receipts cascade with the child and cannot revive a deleted child',async()=>{
    const id=randomUUID(); await run({kind:'adjust',coins:1,xp_amount:0,reason:'Cleanup'},id);
    await client.query('reset role'); await client.query('delete from public.children where id=$1',[child]);
    assert.equal(await scalar('select count(*) from public.economy_command_receipts where child_id=$1',[child]),'0');
    await auth(); await denied(sql,[child,id,{kind:'adjust',coins:1,xp_amount:0,reason:'Cleanup'},'submit']);
  });
}
