import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export async function growthSnapshotCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(), stranger=randomUUID();
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2),($3,$4)',[owner,'growth-cache@example.test',stranger,'growth-stranger@example.test']);
  const auth=()=>login(owner,'growth-cache'); await auth();
  await scalar("select public.onboard_family('Growth snapshots','Asia/Shanghai','Child',2::smallint)");
  const family=await scalar('select family_id from public.family_members where user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  const read=()=>scalar('select public.growth_overview($1)',[child]);
  await check('growth snapshot is read-only without PIN and includes authoritative family date, scope and server time',async()=>{
    await scalar('select public.revoke_parent_authorization()');
    const wallet=await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]);
    await client.query('begin read only');
    let result;
    try { result=await read(); } finally { await client.query('rollback'); }
    assert.equal(result.schema,1); assert.equal(result.child_id,child); assert.equal(result.family_id,family);
    assert.equal(result.today,await scalar("select to_char(now() at time zone 'Asia/Shanghai','YYYY-MM-DD')"));
    assert.ok(Math.abs(Date.parse(result.fetched_at)-Number(await scalar('select extract(epoch from now())*1000')))<10000);
    assert.equal(result.xp,0); assert.equal(result.streak,0); assert.equal(result.checkin_today,false);
    assert.equal(result.appearance.avatar,'astronaut'); assert.equal(result.appearance.pet,'starter_star');
    assert.deepEqual(await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]),wallet);
    assert.equal(await scalar('select count(*) from public.child_streak_awards where child_id=$1',[child]),'0');
    await scalar("select public.set_growth_slot($1,'avatar','explorer')",[child]);
    await scalar("select public.set_growth_slot($1,'pet','starter_rabbit')",[child]);
    const changed=await read(); assert.equal(changed.appearance.avatar,'explorer'); assert.equal(changed.appearance.pet,'starter_rabbit');
    assert.equal(changed.xp,0);
  });
  await check('growth snapshot helper and public RPC preserve membership, anonymous and child deletion boundaries',async()=>{
    await denied('select public.growth_overview_before_snapshot($1)',[child]);
    await login(stranger,'growth-stranger'); await denied('select public.growth_overview($1)',[child]);
    await client.query('reset role'); await client.query('set role anon'); await denied('select public.growth_overview($1)',[child]);
    await client.query('reset role'); await client.query('delete from public.children where id=$1',[child]);
    await auth(); await denied('select public.growth_overview($1)',[child]);
  });
}
