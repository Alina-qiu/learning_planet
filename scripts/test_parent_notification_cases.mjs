import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export async function parentNotificationCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(),peer=randomUUID(),outsider=randomUUID();
  const admin=()=>client.query('reset role');
  await admin();
  for(const id of [owner,peer,outsider]) await client.query('insert into auth.users(id,email) values($1,$2)',[id,`${id}@test.invalid`]);
  await login(owner);await admin();
  const family=await scalar("insert into public.families(name,timezone,owner_user_id) values('notifications','America/New_York',$1) returning id",[owner]);
  await client.query("insert into public.family_members values($1,$2,'admin'),($1,$3,'parent')",[family,owner,peer]);
  const child=await scalar("insert into public.children(family_id,nickname,grade,created_at) values($1,'PRIVATE CHILD',2,'2025-01-01') returning id",[family]);
  const reward=await scalar("insert into public.rewards(family_id,title,cost) values($1,'PRIVATE REWARD',10) returning id",[family]);
  const redemption=await scalar("insert into public.redemptions(child_id,reward_id,frozen_amount,expires_at) values($1,$2,10,'2030-01-01') returning id",[child,reward]);
  const key=`redemption:${redemption}`;
  const inbox=()=>scalar('select public.parent_notification_inbox($1)',[family]);
  const delivery=()=>scalar('select public.parent_notification_delivery($1)',[family]);
  const defaults={enabled:true,redemptions:true,sync_errors:true,weekly_reports:true,quiet_start:'00:00',quiet_end:'00:00'};
  const save=(config,version)=>scalar('select public.save_parent_notification_settings($1,$2,$3)',[family,JSON.stringify(config),version]);
  const ack=(keys,op='read')=>scalar('select public.ack_parent_notifications($1,$2,$3)',[family,JSON.stringify(keys),op]);
  await login(owner);await scalar("select public.set_parent_pin($1,'1234')",[family]);

  await check('parent inbox and settings require session PIN, default delivery is disabled and tables are private',async()=>{
    await assert.rejects(inbox());await assert.rejects(save(defaults,0));
    assert.equal((await delivery()).settings.enabled,false);assert.deepEqual((await delivery()).items,[]);
    await denied('select * from public.parent_notification_settings');await denied('select * from public.parent_notification_receipts');
    await denied('select * from public.parent_notification_events($1)',[family]);
    await login(outsider);await assert.rejects(delivery());await assert.rejects(ack([key]));
    await login(owner);await scalar("select public.verify_parent_pin($1,'1234')",[family]);
    const value=await inbox();assert.equal(value.settings.version,0);assert.ok(value.items.some(e=>e.notification_key===key));
    assert.doesNotMatch(JSON.stringify(value),/PRIVATE CHILD|PRIVATE REWARD/);
  });
  await check('parent settings validate every field and reject stale concurrent edits',async()=>{
    for(const invalid of [{...defaults,quiet_start:'24:00'},{...defaults,enabled:'true'},{...defaults,extra:'private'},null])
      await assert.rejects(save(invalid,0));
    assert.equal((await save(defaults,0)).version,1);
    await assert.rejects(save({...defaults,redemptions:false},0),/CONFLICT/);
    assert.equal((await inbox()).settings.redemptions,true);
    await login(owner,'different-notification-session');await assert.rejects(save(defaults,1));
    await login(owner);await scalar("select public.verify_parent_pin($1,'1234')",[family]);
  });
  await check('offline notification policy is family scoped, non-content, and bounded to 168 hours',async()=>{
    const result=await delivery(),policy=result.offline_policy;
    assert.equal(policy.schema,1);assert.equal(policy.purpose,'local_sync_notice');
    assert.equal(policy.family_id,family);assert.equal(policy.timezone,'America/New_York');
    assert.deepEqual(policy.child_ids,[child]);assert.deepEqual(policy.settings,result.settings);
    assert.equal(Date.parse(policy.expires_at)-Date.parse(policy.issued_at),7*24*60*60*1000);
    assert.ok(Math.abs(Date.parse(policy.issued_at)-Date.now())<30000);
    assert.doesNotMatch(JSON.stringify(policy),/PRIVATE CHILD|PRIVATE REWARD|reward_id|items|notification_key/);
    await denied('select public.parent_notification_delivery_before_offline($1)',[family]);
    await login(outsider);await assert.rejects(delivery());await login(owner);
  });
  await check('parent delivery respects quiet time, master switch and individual categories without hiding the inbox',async()=>{
    assert.ok((await delivery()).items.some(e=>e.notification_key===key));
    const times=await scalar("select jsonb_build_object('start',to_char((now() at time zone 'America/New_York')-interval '1 hour','HH24:MI'),'end',to_char((now() at time zone 'America/New_York')+interval '1 hour','HH24:MI'))");
    await save({...defaults,quiet_start:times.start,quiet_end:times.end},1);
    assert.equal((await delivery()).quiet,true);assert.deepEqual((await delivery()).items,[]);
    assert.ok((await inbox()).items.some(e=>e.notification_key===key));
    await save({...defaults,redemptions:false,weekly_reports:false},2);assert.deepEqual((await delivery()).items,[]);
    await save({...defaults,enabled:false},3);assert.deepEqual((await delivery()).items,[]);
    await save(defaults,4);
  });
  await check('delivery receipts and read status are separate, idempotent and private to each parent',async()=>{
    const first=await ack([key],'delivered');assert.deepEqual(first,{keys:[key],operation:'delivered'});
    assert.deepEqual(await ack([key],'delivered'),first);
    assert.equal((await inbox()).items.find(e=>e.notification_key===key).read_at,null);
    assert.ok(!(await delivery()).items.some(e=>e.notification_key===key));
    await ack([key]);assert.ok((await inbox()).items.find(e=>e.notification_key===key).read_at);
    await login(peer);await scalar("select public.verify_parent_pin($1,'1234')",[family]);
    assert.equal((await inbox()).items.find(e=>e.notification_key===key).read_at,null);
    await save(defaults,0);assert.ok((await delivery()).items.some(e=>e.notification_key===key));
    await assert.rejects(ack([key,key]));await assert.rejects(ack([]));await assert.rejects(ack([key,randomUUID()]));
    assert.equal((await inbox()).items.find(e=>e.notification_key===key).read_at,null);
    await assert.rejects(ack([key],'unknown'));
  });
  await check('weekly notification uses completed family calendar week and 09:00 Monday across DST',async()=>{
    await admin();
    const events=async at=>(await client.query('select * from public.parent_notification_events($1,$2) where kind=$3',[family,at,'weekly'])).rows;
    assert.deepEqual(await events('2026-03-09T12:59:59Z'),[]);
    const monday=await events('2026-03-09T13:00:00Z');assert.equal(monday.length,1);
    assert.equal(monday[0].notification_key,`weekly:${child}:2026-03-08`);
    assert.equal(monday[0].created_at.toISOString(),'2026-03-09T13:00:00.000Z');
    const sunday=await events('2026-03-15T20:00:00Z');assert.equal(sunday[0].notification_key,monday[0].notification_key);
    const next=await events('2026-03-16T13:00:00Z');assert.equal(next[0].notification_key,`weekly:${child}:2026-03-15`);
    await login(peer);
  });
  await check('resolved redemptions disappear without affecting wallets, and child export contains only own notification receipts',async()=>{
    await ack([key]);await admin();
    await client.query("update public.redemptions set status='approved' where id=$1",[redemption]);
    await login(peer);assert.ok(!(await inbox()).items.some(e=>e.notification_key===key));await assert.rejects(ack([key]));
    // Test the source directly with the same JWT while using the database owner.
    await admin();const source=await scalar('select public.child_export_source($1)',[child]);
    const rows=source.find(s=>s.name==='parent_notification_receipts').rows;
    assert.equal(rows.length,1);assert.equal(rows[0].notification_key,key);assert.ok(!('user_id' in rows[0]));
    assert.equal(await scalar('select count(*)::int from public.wallets where child_id=$1',[child]),0);
    await client.query("update public.redemptions set status='requested' where id=$1",[redemption]);
    await login(owner);
  });
  await check('child deletion barrier erases notification receipts and excludes deleted children from every feed',async()=>{
    await admin();await client.query('insert into public.child_deletion_tombstones(child_id,family_id) values($1,$2)',[child,family]);
    assert.equal(await scalar('select count(*)::int from public.parent_notification_receipts where child_id=$1',[child]),0);
    await login(owner);assert.deepEqual((await inbox()).items,[]);assert.deepEqual((await delivery()).items,[]);
    assert.deepEqual((await delivery()).offline_policy.child_ids,[]);
    await assert.rejects(ack([key]));
    await admin();await client.query('delete from public.child_deletion_tombstones where child_id=$1',[child]);
    await login(owner);
  });
  await check('notification retention is service-only and removing a member erases their settings and receipts',async()=>{
    await ack([key]);await denied('select public.purge_parent_notification_receipts()');
    await admin();await client.query("update public.parent_notification_receipts set updated_at=now()-interval '91 days' where family_id=$1",[family]);
    await client.query('set role service_role');await client.query('select public.purge_parent_notification_receipts()');await admin();
    assert.equal(await scalar('select count(*)::int from public.parent_notification_receipts where family_id=$1',[family]),0);
    await client.query('delete from public.family_members where family_id=$1 and user_id=$2',[family,peer]);
    assert.equal(await scalar('select count(*)::int from public.parent_notification_settings where user_id=$1',[peer]),0);
    await login(peer);await assert.rejects(inbox());await assert.rejects(delivery());
    await login();
  });
  await check('account deletion acceptance clears parent preferences and receipts and rejects old-session delivery',async()=>{
    await login(owner);await scalar("select public.verify_parent_pin($1,'1234')",[family]);
    await ack([key]);
    const preview=await scalar('select public.preview_account_deletion()');
    await scalar('select public.request_account_deletion($1,$2,$3)',[randomUUID(),JSON.stringify(preview.scope),'永久注销我的账号']);
    await assert.rejects(delivery());await assert.rejects(save(defaults,5));
    await admin();
    assert.equal(await scalar('select count(*)::int from public.parent_notification_receipts where user_id=$1',[owner]),0);
    assert.equal(await scalar('select count(*)::int from public.parent_notification_settings where user_id=$1',[owner]),0);
    await login();
  });
}
