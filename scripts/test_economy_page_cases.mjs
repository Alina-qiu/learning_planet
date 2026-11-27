import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export async function economyPageCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID();
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)',[user,'economy-pages@example.test']);
  const auth=()=>login(user,'economy-pages'); await auth();
  await scalar("select public.onboard_family('Pages','Pacific/Kiritimati','Reader',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  const sql='select public.economy_page($1,$2,$3,$4,$5,$6,$7)';
  const page=(section,after=null,size=50,inactive=false)=>scalar(sql,[child,family,section,after?.created_at??null,after?.id??null,size,inactive]);
  const all=async(section,{size=100,inactive=false,after=null}={})=>{
    const rows=[]; let cursor=after;
    do {const p=await page(section,cursor,size,inactive); rows.push(...p.items);cursor=p.next_cursor;} while(cursor);
    assert.equal(new Set(rows.map(r=>r.id)).size,rows.length);return rows;
  };
  let reward;
  await check('economy pages bound 1006 ledger rows and validate owner scope without exposing internal keys',async()=>{
    await client.query('reset role');
    await client.query(`insert into public.ledger_entries(child_id,asset_type,amount,source_type,idempotency_key,created_at)
      select $1::uuid,'coin',1,'page_fixture','economy-page-'||g||'-'||$1::text,'2026-01-01'::timestamptz from generate_series(1,1006) g`,[child]);
    await auth();
    const first=await page('ledger');
    assert.equal(first.items.length,50);assert.ok(first.next_cursor);
    assert.equal(first.owner_id,user);assert.equal(first.child_id,child);assert.equal(first.family_id,family);
    assert.equal(first.family_today,await scalar("select to_char(now() at time zone 'Pacific/Kiritimati','YYYY-MM-DD')"));
    const rows=await all('ledger');assert.equal(rows.length,1006);
    assert.ok(rows.every(r=>!('idempotency_key' in r)&&r.child_id===child));
    assert.deepEqual(rows.map(r=>r.id),rows.map(r=>r.id).sort().reverse());
    assert.equal((await page('ledger', {created_at:rows.at(-1).created_at,id:rows.at(-1).id})).next_cursor,null);
  });
  await check('economy cursor survives newer inserts and removal before its position',async()=>{
    await client.query('reset role');
    await client.query(`insert into public.rewards(family_id,title,cost,active,created_at)
      select $1,'Reward '||g,1,g%2=0,'2026-01-01'::timestamptz from generate_series(1,107) g`,[family]);
    await auth(); const before=await all('rewards',{inactive:true});reward=before[0].id;
    const first=await page('rewards',null,50,true);
    await client.query('reset role');
    await client.query('delete from public.rewards where id=$1',[first.items[1].id]);
    await client.query("insert into public.rewards(family_id,title,cost) values($1,'New arrival',1)",[family]);
    await auth();
    const rest=await all('rewards',{inactive:true,after:first.next_cursor});
    assert.deepEqual(rest.map(r=>r.id),before.slice(50).map(r=>r.id));
    assert.ok((await all('rewards')).every(r=>r.active));
    assert.equal((await all('rewards',{inactive:true})).length,107);
    const legacy=await scalar('select public.reward_catalog($1,0,500)',[child]);
    for(const row of (await all('rewards',{inactive:true}))) {
      const old=legacy.items.find(r=>r.id===row.id);assert.ok(old);
      for(const field of ['can_request','blocked_reason','stock_available','quota_remaining','family_timezone']) assert.deepEqual(row[field],old[field]);
    }
  });
  await check('economy pending and redemption history remain scoped, complete and read-only',async()=>{
    await client.query('reset role');
    await client.query(`insert into public.pending_coin_awards(child_id,amount,source_type,source_key,status,created_at)
      select $1::uuid,1,'page_fixture','pending-page-'||g||'-'||$1::text,case when g%2=0 then 'pending' else 'rejected' end,'2026-01-01'::timestamptz from generate_series(1,206) g`,[child]);
    await client.query(`insert into public.redemptions(child_id,reward_id,status,frozen_amount,requested_on,created_at)
      select $1,$2,'fulfilled',1,'2026-01-01','2026-01-01'::timestamptz from generate_series(1,103)`,[child,reward]);
    await auth();
    const wallet=await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]);
    await client.query('begin read only');
    try {
      const pending=await all('pending'); assert.equal(pending.length,103);assert.ok(pending.every(r=>r.status==='pending'));
      const history=await all('redemptions'); assert.equal(history.length,103);assert.ok(history.every(r=>r.child_id===child));
      assert.equal((await all('ledger')).length,1006);
    } finally {await client.query('rollback');}
    assert.deepEqual(await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]),wallet);
  });
  await check('economy page rejects foreign families, outsiders, anonymous and malformed cursors',async()=>{
    for(const args of [
      [child,randomUUID(),'ledger',null,null,50,false],
      [randomUUID(),family,'ledger',null,null,50,false],
      [child,family,'unknown',null,null,50,false],
      [child,family,'ledger',null,null,101,false],
      [child,family,'ledger',null,null,0,false],
      [child,family,'ledger',null,null,null,false],
      [child,family,'ledger',null,null,50,null],
      [child,family,'ledger','2026-01-01',null,50,false],
      [child,family,'ledger',null,randomUUID(),50,false],
      [child,family,'ledger','infinity',randomUUID(),50,false],
    ]) await denied(sql,args);
    await login(otherUid);await denied(sql,[child,family,'ledger',null,null,50,false]);
    for(const role of ['anon','service_role']) {await client.query('reset role');await client.query('set role '+role);await denied(sql,[child,family,'ledger',null,null,50,false]);}
    await auth();
  });
  await check('paged catalog expires reservations once and keeps authoritative capacity',async()=>{
    await client.query("select public.set_parent_pin($1,'3579')",[family]);
    await client.query("select public.verify_parent_pin($1,'3579')",[family]);
    const id=await scalar('select public.save_reward($1,$2)',[family,{title:'One copy',cost:10,stock_total:1,quota_period:'lifetime',quota_limit:1}]);
    const claim=await scalar('select public.request_reward($1,$2,$3,1)',[child,id,randomUUID()]);
    const reserved=(await page('rewards')).items.find(r=>r.id===id);assert.equal(reserved.stock_available,0);assert.equal(reserved.quota_remaining,0);
    await client.query('reset role');await client.query("update public.redemptions set expires_at=now()-interval '1 second' where id=$1",[claim]);await auth();
    const released=(await page('rewards')).items.find(r=>r.id===id);assert.equal(released.stock_available,1);assert.equal(released.quota_remaining,1);assert.equal(released.can_request,true);
    await page('rewards');assert.equal(await scalar("select count(*)::int from public.ledger_entries where source_id=$1 and source_type='redemption_refund'",[claim]),1);
  });
}
