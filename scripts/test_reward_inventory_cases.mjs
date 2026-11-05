import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function rewardInventoryCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID();
  await client.query('reset role');await client.query('insert into auth.users values($1,$2)',[user,'inventory@example.test']);
  const auth=()=>login(user,'inventory-session');await auth();
  await client.query("select public.onboard_family('Inventory family','Pacific/Kiritimati','First',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  await client.query("select public.set_parent_pin($1,'3579')",[family]);await client.query("select public.verify_parent_pin($1,'3579')",[family]);
  const createChild=async name=>{
    const child=await scalar('select public.create_child($1,$2,1::smallint)',[family,name]);
    await client.query("select public.adjust_wallet($1,10000,1000,'test balance',$2,true)",[child,randomUUID()]);return child;
  };
  const a=await createChild('A'),b=await createChild('B');
  const config={title:'Book',cost:20,rules:'Choose together',minimum_level:1,stock_total:null,quota_period:'none',quota_limit:null};
  const reward=patch=>scalar('select public.save_reward($1,$2)',[family,{...config,...patch}]);
  const row=id=>scalar('select to_jsonb(r) from public.rewards r where id=$1',[id]);
  const edit=async(id,patch)=>{const r=await row(id);return scalar('select public.save_reward($1,$2,$3)',[family,{...r,expected_version:r.version,...patch},id]);};
  const request=async(kid,id,key=randomUUID())=>scalar('select public.request_reward($1,$2,$3,$4)',[kid,id,key,(await row(id)).version]);
  const change=(id,op)=>client.query('select public.transition_redemption($1,$2,$3)',[id,op,'Confirmed by parent']);
  const catalog=kid=>scalar('select public.reward_catalog($1)',[kid]);
  const item=async(kid,id)=>(await catalog(kid)).items.find(r=>r.id===id);
  let limited,claimA,claimB;
  await check('inventory configuration validates bounds and paired quotas, requires PIN and preserves legacy defaults',async()=>{
    const unlimited=await reward({});assert.equal((await row(unlimited)).stock_total,null);
    const empty=await reward({stock_total:0});assert.equal((await item(a,empty)).can_request,false);
    await denied('select public.request_reward($1,$2,$3,1)',[a,empty,randomUUID()]);
    for(const patch of [{stock_total:-1},{stock_total:1000001},{quota_period:'day'},{quota_period:'none',quota_limit:1},{quota_period:'year',quota_limit:2},{quota_period:'week',quota_limit:0},{quota_period:null}]) {
      await denied('select public.save_reward($1,$2)',[family,{...config,...patch}]);
    }
    await login(user,'without-pin');await denied('select public.save_reward($1,$2)',[family,config]);await auth();
    limited=await reward({stock_total:2,quota_period:'week',quota_limit:1});
    const legacy={title:'Renamed',cost:20};await scalar('select public.save_reward($1,$2,$3)',[family,legacy,limited]);
    assert.equal((await row(limited)).stock_total,2);assert.equal((await row(limited)).quota_period,'week');
    await denied('select public.save_reward($1,$2,$3)',[family,{...config,stock_total:9},limited]);
    await denied('update public.rewards set stock_total=999 where id=$1',[limited]);
    await denied('update public.rewards set stock_fulfilled=0 where id=$1',[limited]);
  });
  await check('siblings share reservations, child quotas are independent and UUID replay does not reserve twice',async()=>{
    const key=randomUUID();claimA=await request(a,limited,key);
    const first=await item(a,limited);assert.equal(first.stock_available,1);assert.equal(first.quota_remaining,0);
    await denied('select public.request_reward($1,$2,$3,$4)',[a,limited,randomUUID(),(await row(limited)).version]);
    assert.equal((await item(b,limited)).quota_remaining,1);
    claimB=await request(b,limited);assert.equal((await item(a,limited)).stock_available,0);
    assert.equal(await request(a,limited,key),claimA);
    await denied('select public.request_reward($1,$2,$3,$4)',[b,limited,key,(await row(limited)).version]);
    assert.equal(await scalar('select count(*)::int from public.redemptions where reward_id=$1',[limited]),2);
    assert.equal(await scalar("select count(*)::int from public.ledger_entries where source_id=any($1) and source_type='redemption_freeze'",[[claimA,claimB]]),2);
  });
  await check('fulfillment consumes inventory once while refunds release stock and quota without changing XP',async()=>{
    await change(claimA,'approve');await change(claimA,'fulfill');await change(claimA,'fulfill');
    assert.equal((await row(limited)).stock_fulfilled,1);
    assert.equal((await item(a,limited)).stock_available,0);assert.equal((await item(a,limited)).quota_remaining,0);
    await change(claimB,'cancel');await change(claimB,'cancel');
    assert.equal((await item(b,limited)).stock_available,1);assert.equal((await item(b,limited)).quota_remaining,1);
    const rejected=await request(b,limited);await change(rejected,'reject');await change(rejected,'reject');
    assert.equal((await item(b,limited)).stock_available,1);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[b]),10000);
    assert.equal(await scalar('select xp from public.wallets where child_id=$1',[a]),1000);
    await denied('select public.save_reward($1,$2,$3)',[family,{...await row(limited),expected_version:(await row(limited)).version,stock_total:0},limited]);
  });
  await check('expiry of requested and approved claims releases capacity once through normal wallet reads and maintenance',async()=>{
    const id=await reward({stock_total:2,quota_period:'lifetime',quota_limit:1});
    const first=await request(a,id),second=await request(b,id);await change(second,'approve');
    await client.query('reset role');await client.query("update public.redemptions set expires_at=now()-interval '1 second' where id=any($1)",[[first,second]]);await auth();
    await scalar('select public.wallet_overview($1)',[a]);assert.equal((await item(a,id)).stock_available,1);
    await client.query('reset role');await client.query("select set_config('request.jwt.claims','{\"role\":\"service_role\",\"marker\":\"inventory\"}',false)");await client.query('set role service_role');
    await scalar('select public.run_reward_maintenance()');assert.equal(await scalar('select public.run_reward_maintenance()'),0);
    assert.equal(JSON.parse(await scalar("select current_setting('request.jwt.claims')")).marker,'inventory');await auth();
    const available=await item(b,id);assert.equal(available.stock_available,2);assert.equal(available.quota_remaining,1);
    assert.equal(await scalar("select count(*)::int from public.ledger_entries where source_id=any($1) and source_type='redemption_refund'",[[first,second]]),2);
  });
  await check('family dates stamp requests and day week month lifetime quotas handle boundaries and leap years',async()=>{
    for(const [period,day,start,next,previous] of [
      ['day','2026-12-31','2026-12-31','2027-01-01','2026-12-30'],
      ['week','2027-01-03','2026-12-28','2027-01-04','2026-12-27'],
      ['month','2028-02-29','2028-02-01','2028-03-01','2028-01-31'],
      ['lifetime','2028-02-29','2028-02-01',null,'2000-01-01'],
    ]) {
      const id=await reward({quota_period:period,quota_limit:3});
      const x=await request(a,id),y=await request(a,id);
      assert.equal(await scalar('select requested_on::text from public.redemptions where id=$1',[x]),await scalar('select public.family_today($1)',[a]));
      await client.query('reset role');await client.query('update public.redemptions set requested_on=$2 where id=$1',[x,start]);await client.query('update public.redemptions set requested_on=$2 where id=$1',[y,previous]);
      const capacity=await scalar('select public.reward_capacity($1,$2,$3)',[id,a,day]);
      assert.equal(capacity.quota_used,period==='lifetime'?2:1);assert.equal(capacity.quota_resets_on,next);
      if(next)assert.equal((await scalar('select public.reward_capacity($1,$2,$3)',[id,a,next])).quota_used,0);
      await auth();await change(x,'cancel');await change(y,'cancel');
    }
  });
  await check('editing quotas and stock protects existing snapshots and reservations and supports deliberate restocking',async()=>{
    const id=await reward({stock_total:2,quota_period:'month',quota_limit:2});
    const x=await request(a,id);await change(x,'approve');
    const snapshot=await scalar('select reward_limits from public.redemptions where id=$1',[x]);
    await edit(id,{quota_limit:1,cost:50,rules:'new rule'});
    assert.equal(await scalar("select count(distinct details->'after'->>'quota_limit')::int from public.audit_logs where action='reward.limits' and target_id=$1",[id]),2);
    assert.deepEqual(await scalar('select reward_limits from public.redemptions where id=$1',[x]),snapshot);
    assert.equal(await scalar('select frozen_amount from public.redemptions where id=$1',[x]),20);
    assert.equal((await item(a,id)).quota_remaining,0);
    await denied('select public.request_reward($1,$2,$3,1)',[b,id,randomUUID()]);
    await change(x,'fulfill');await edit(id,{stock_total:1});
    assert.equal((await item(b,id)).stock_available,0);
    await edit(id,{stock_total:2});assert.equal((await item(b,id)).stock_available,1);
    const y=await request(b,id);
    await denied('select public.save_reward($1,$2,$3)',[family,{...await row(id),expected_version:(await row(id)).version,stock_total:1},id]);
    await change(y,'cancel');
  });
  await check('two real sessions racing for last stock or child quota freeze only the winning request',async()=>{
    const peer=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});await peer.connect();
    try {
      await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:'peer'})]);await peer.query('set role authenticated');
      for(const [patch,kid] of [[{stock_total:1},b],[{quota_period:'day',quota_limit:1},a]]) {
        const id=await reward(patch);
        const results=await Promise.allSettled([client.query('select public.request_reward($1,$2,$3,1)',[a,id,randomUUID()]),peer.query('select public.request_reward($1,$2,$3,1)',[kid,id,randomUUID()])]);
        assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
        const claims=(await client.query('select id from public.redemptions where reward_id=$1',[id])).rows;
        assert.equal(claims.length,1);assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[claims[0].id]),1);
      }
      const id=await reward({stock_total:1}),key=randomUUID();
      const results=await Promise.all([client.query('select public.request_reward($1,$2,$3,1)',[a,id,key]),peer.query('select public.request_reward($1,$2,$3,1)',[a,id,key])]);
      assert.equal(results[0].rows[0].request_reward,results[1].rows[0].request_reward);
      assert.equal((await item(a,id)).stock_reserved,1);
    } finally {await peer.end();}
  });
  await check('deleting a child releases reservations but retains only aggregate consumed stock for fulfilled rewards',async()=>{
    const child=await createChild('Delete inventory'),id=await reward({stock_total:3});
    const fulfilled=await request(child,id);await change(fulfilled,'approve');await change(fulfilled,'fulfill');
    await request(child,id);await request(b,id);assert.equal((await item(b,id)).stock_available,0);
    const preview=await scalar('select public.preview_child_deletion($1)',[child]);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[child,randomUUID(),preview.counts]);
    const after=await item(b,id);assert.equal(after.stock_fulfilled,1);assert.equal(after.stock_reserved,1);assert.equal(after.stock_available,1);
    assert.equal(await scalar('select count(*)::int from public.redemptions where child_id=$1',[child]),0);
  });
  await check('catalog paginates scoped availability and no caller may bypass limits through private base functions',async()=>{
    let offset=0;const all=[];
    do {const page=await scalar('select public.reward_catalog($1,$2,2)',[a,offset]);all.push(...page.items);offset=page.next_offset;} while(offset!==null);
    assert.equal(new Set(all.map(r=>r.id)).size,all.length);assert.equal(all.length,await scalar('select count(*)::int from public.rewards where family_id=$1',[family]));
    assert.ok(all.every(r=>r.family_id===family&&r.family_timezone==='Pacific/Kiritimati'));
    await denied('select public.reward_catalog($1,-1,10)',[a]);await denied('select public.reward_catalog($1,0,501)',[a]);
    await denied('select public.reward_capacity($1,$2,current_date)',[limited,a]);
    await denied('select public.request_reward_base($1,$2,$3,1)',[a,limited,randomUUID()]);
    await denied('select public.save_reward_base($1,$2)',[family,config]);
    await denied("select public.transition_redemption_base($1,'fulfill','bypass')",[claimA]);
    await login(otherUid);await assert.rejects(client.query('select public.reward_catalog($1)',[a]),{code:'42501'});
    await denied('select public.request_reward($1,$2,$3,1)',[a,limited,randomUUID()]);await auth();
  });
}
