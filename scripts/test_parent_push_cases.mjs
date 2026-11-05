import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import pg from 'pg';

export async function parentPushCases({client,scalar,login,denied,check}) {
  const admin=()=>client.query('reset role');
  async function service() {
    await admin();await client.query("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false)");
    await client.query('set role service_role');
  }
  const settings={enabled:true,redemptions:true,sync_errors:true,weekly_reports:false,quiet_start:'00:00',quiet_end:'00:00'};
  async function fixture() {
    await admin();
    // Keep each dispatch assertion confined to its fixture.
    await client.query("update public.parent_push_devices set state='disabled',registration_token=null,registration_hash=null");
    const owner=randomUUID(),peer=randomUUID(),device=randomUUID(),secret=randomBytes(32).toString('base64url'),nonce=randomUUID();
    for (const id of [owner,peer]) await client.query('insert into auth.users(id,email) values($1,$2)',[id,`${id}@test.invalid`]);
    const family=await scalar("insert into public.families(name,timezone,owner_user_id) values('push test','Asia/Shanghai',$1) returning id",[owner]);
    await client.query("insert into public.family_members values($1,$2,'admin'),($1,$3,'parent')",[family,owner,peer]);
    const child=await scalar("insert into public.children(family_id,nickname,grade) values($1,'PRIVATE CHILD',2) returning id",[family]);
    const reward=await scalar("insert into public.rewards(family_id,title,cost) values($1,'PRIVATE REWARD',10) returning id",[family]);
    const redemption=await scalar("insert into public.redemptions(child_id,reward_id,frozen_amount,expires_at) values($1,$2,10,now()+interval '7 days') returning id",[child,reward]);
    await login(owner);await scalar("select public.set_parent_pin($1,'1234')",[family]);
    await scalar("select public.verify_parent_pin($1,'1234')",[family]);
    await scalar('select public.save_parent_notification_settings($1,$2,0)',[family,JSON.stringify(settings)]);
    const prepare=(version=1,n=nonce,id=device,s=secret)=>scalar('select public.prepare_parent_push_device($1,$2,$3,$4,$5)',[family,id,s,version,n]);
    const token=`test-token-${randomUUID()}`;
    const activate=(version=1,t=token,transport='hms',id=device,s=secret)=>scalar('select public.activate_parent_push_device($1,$2,$3,$4,$5)',[id,s,version,transport,t]);
    const revoke=(version=2,s=secret)=>scalar('select public.revoke_parent_push_device($1,$2,$3)',[device,s,version]);
    const renew=(t=token,version=1,s=secret)=>scalar('select public.renew_parent_push_device($1,$2,$3,$4)',[device,s,version,t]);
    const readDevice=async()=>{await admin();return scalar('select to_jsonb(d) from public.parent_push_devices d where device_id=$1',[device]);};
    const enqueue=async()=>{await service();return scalar('select public.enqueue_parent_push_jobs()');};
    const claim=async(transports=['hms'],limit=20)=>{await service();return scalar('select public.claim_parent_push_jobs($1,$2)',[limit,JSON.stringify(transports)]);};
    const authorize=async j=>{await service();return scalar('select public.authorize_parent_push_job($1,$2)',[j.job_id,j.lease_token]);};
    const finish=async(j,outcome)=>{await service();return scalar('select public.finish_parent_push_job($1,$2,$3)',[j.job_id,j.lease_token,outcome]);};
    return {owner,peer,family,child,reward,redemption,key:`redemption:${redemption}`,device,secret,nonce,token,
      prepare,activate,revoke,renew,readDevice,enqueue,claim,authorize,finish};
  }
  await check('push registry and queue are private; parent preparation requires current-session PIN',async()=>{
    const f=await fixture();
    for (const table of ['parent_push_devices','parent_push_jobs']) await denied(`select * from public.${table}`);
    for (const sql of ['select public.enqueue_parent_push_jobs()','select public.purge_parent_push()',
      'select public.claim_parent_push_jobs(1,\'["hms"]\')',`select public.parent_push_device_view('${f.device}')`,
      `select * from public.parent_notification_events_for_user('${f.family}','${f.owner}',now())`]) await denied(sql);
    await login(f.owner,'no-pin');await assert.rejects(f.prepare());
    await login(f.peer);await assert.rejects(f.prepare());
    await login(f.owner);const prepared=await f.prepare();
    assert.equal(prepared.state,'prepared');assert.equal(prepared.family_id,f.family);
    assert.doesNotMatch(JSON.stringify(prepared),/secret|registration|PRIVATE/);
    assert.deepEqual(Object.keys(await f.activate()).sort(),Object.keys(prepared).sort());
    await service();await denied('select * from public.parent_push_devices');
  });
  await check('push preparation is replayable and capability revocation fences delayed activation and stale logout',async()=>{
    const f=await fixture();await f.prepare();
    assert.equal((await f.prepare()).scope_nonce,f.nonce);
    await assert.rejects(f.prepare(1,randomUUID()),/INTENT_MISMATCH/);
    await assert.rejects(f.prepare(0));await assert.rejects(f.prepare(2,f.nonce,f.device,'short'));
    await admin();await client.query('set role anon');
    assert.equal((await f.revoke(2,'x'.repeat(43))).revoked,true);
    await f.revoke(2);await login(f.owner);
    await assert.rejects(f.activate(),/STALE/);assert.equal((await f.prepare(2)).state,'disabled');
    await f.prepare(3);await f.activate(3);await f.revoke(2);
    assert.equal((await f.readDevice()).state,'enabled');
    await login(f.owner);await assert.rejects(f.prepare(2),/STALE/);
    await f.revoke(4);assert.equal((await f.readDevice()).registration_token,null);
  });
  await check('push endpoint uniqueness, validation, expiry and renewal preserve ownership',async()=>{
    const f=await fixture();await f.prepare();
    for (const [token,transport] of [['bad token','gateway'],['short','hms'],['a'.repeat(63),'apns'],['z'.repeat(64),'apns'],['a'.repeat(4097),'gateway']])
      await assert.rejects(f.activate(1,token,transport),/INVALID_PUSH_TOKEN/);
    await f.activate();assert.equal((await f.activate()).state,'enabled');
    await assert.rejects(f.activate(1,`${f.token}-changed`),/INTENT_MISMATCH/);
    const second=randomUUID();await f.prepare(1,randomUUID(),second);
    await assert.rejects(f.activate(1,f.token,'hms',second),/unique/);
    await login(f.peer);await assert.rejects(f.renew(),/ACCESS_DENIED/);
    await login(f.owner,'renew-without-pin');assert.equal((await f.renew(`${f.token}-rotated`)).state,'enabled');
    await assert.rejects(f.renew(f.token,1,'wrong'),/ACCESS_DENIED/);
    await admin();await client.query("update public.parent_push_devices set expires_at=now()-interval '1 second' where device_id=$1",[f.device]);
    await login(f.owner);await assert.rejects(f.renew(),/STALE/);
    await f.prepare(2);await admin();await client.query("update public.parent_push_devices set prepared_until=now()-interval '1 second' where device_id=$1",[f.device]);
    await login(f.owner);await assert.rejects(f.activate(2),/PREPARATION_EXPIRED/);
    await f.prepare(3);await f.activate(3,'vendor-id','gateway');
    assert.equal((await f.readDevice()).transport,'gateway');
  });
  await check('same installation can transfer to another authorized parent without inheriting the old intent',async()=>{
    const f=await fixture();await f.prepare();await f.activate();
    await login(f.peer);await scalar("select public.verify_parent_pin($1,'1234')",[f.family]);
    await assert.rejects(f.prepare(1),/INTENT_MISMATCH/);
    await assert.rejects(f.prepare(2,f.nonce,f.device,'x'.repeat(43)),/SECRET_MISMATCH/);
    const value=await f.prepare(2,randomUUID());assert.equal(value.state,'prepared');
    await f.activate(2);await login(f.owner);await assert.rejects(f.renew(f.token,2),/ACCESS_DENIED/);
    assert.equal((await f.readDevice()).owner_id,f.peer);
  });
  await check('push enqueue and claims obey enabled devices, categories, quiet time and configured transports',async()=>{
    const f=await fixture();assert.equal(await f.enqueue(),0);
    await login(f.owner);await f.prepare();await f.activate();
    await admin();await client.query('update public.parent_notification_settings set redemptions=false where family_id=$1',[f.family]);
    assert.equal(await f.enqueue(),0);
    await admin();await client.query("update public.parent_notification_settings set redemptions=true,quiet_start='00:00',quiet_end='23:59:59' where family_id=$1",[f.family]);
    assert.equal(await scalar("select public.parent_push_is_allowed($1,$2,'redemption','2026-11-05T04:00:00Z')",[f.family,f.owner]),false);
    await client.query("update public.parent_notification_settings set quiet_end='00:00' where family_id=$1",[f.family]);
    assert.equal(await f.enqueue(),1);assert.equal(await f.enqueue(),0);
    assert.deepEqual(await f.claim(['apns']),[]);
    for(const invalid of [[],['unknown'],['hms','apns','gateway','hms'],null]) await assert.rejects(f.claim(invalid));
    await assert.rejects(f.claim(['hms'],21));assert.equal((await f.claim()).length,1);assert.deepEqual(await f.claim(),[]);
  });
  await check('authorized push contains only short-lived opaque data and never child/reward/account contents',async()=>{
    const f=await fixture();await f.prepare();await f.activate();await f.enqueue();const [job]=await f.claim();
    assert.deepEqual(Object.keys(job).sort(),['job_id','lease_token']);
    const value=await f.authorize(job);assert.equal(value.status,'authorized');assert.equal(value.registration_token,f.token);
    assert.deepEqual(Object.keys(value.data).sort(),['expires_ms','issued_ms','kind','message_id','quiet_end','quiet_start','scope_nonce','settings_version','timezone','version']);
    assert.equal(value.data.scope_nonce,f.nonce);assert.equal(value.data.message_id,job.job_id);assert.equal(value.data.kind,'redemption');
    assert.equal(value.data.timezone,'Asia/Shanghai');assert.equal(value.data.version,'parent-push-v1');
    assert.ok(Number(value.data.expires_ms)-Number(value.data.issued_ms)<=60000);
    assert.ok(Math.abs(Number(value.data.issued_ms)-Date.now())<30000);
    for (const secret of [f.family,f.owner,f.child,f.redemption,f.key,'PRIVATE']) assert.ok(!JSON.stringify(value.data).includes(secret));
    assert.equal((await f.authorize({...job,lease_token:randomUUID()})).status,'stale');
    await admin();const exported=JSON.stringify(await scalar('select public.child_export_source($1)',[f.child]));
    assert.ok(!exported.includes(f.token));assert.ok(!exported.includes(f.secret));assert.ok(!exported.includes('parent_push'));
  });
  await check('source changes, reads and settings changes are rechecked immediately before dispatch',async()=>{
    const f=await fixture();await f.prepare();await f.activate();await f.enqueue();let [job]=await f.claim();
    await admin();await client.query('update public.parent_notification_settings set enabled=false where family_id=$1',[f.family]);
    assert.equal((await f.authorize(job)).status,'deferred');
    await admin();assert.equal(await scalar('select attempts from public.parent_push_jobs where id=$1',[job.job_id]),0);
    await client.query('update public.parent_notification_settings set enabled=true where family_id=$1',[f.family]);
    await client.query('update public.parent_push_jobs set next_attempt_at=now() where id=$1',[job.job_id]);
    [job]=await f.claim();await login(f.owner);await scalar('select public.ack_parent_notifications($1,$2)',[f.family,JSON.stringify([f.key])]);
    assert.equal((await f.authorize(job)).status,'cancelled');
    await admin();await client.query('delete from public.parent_notification_receipts where family_id=$1',[f.family]);
    await client.query('delete from public.parent_push_jobs where family_id=$1',[f.family]);await f.enqueue();[job]=await f.claim();
    await admin();await client.query("update public.redemptions set expires_at=now()-interval '1 second' where id=$1",[f.redemption]);
    assert.equal((await f.authorize(job)).status,'cancelled');
  });
  await check('provider acceptance is idempotent, suppresses foreground delivery and never marks a message read',async()=>{
    const f=await fixture();await f.prepare();await f.activate();await f.enqueue();const [job]=await f.claim();
    await f.authorize(job);assert.equal((await f.finish(job,'accepted')).status,'sent');
    assert.equal((await f.finish(job,'accepted')).status,'sent');assert.equal(await f.enqueue(),0);
    await login(f.owner);const inbox=await scalar('select public.parent_notification_inbox($1)',[f.family]);
    assert.equal(inbox.items.find(item=>item.notification_key===f.key).read_at,null);
    assert.deepEqual((await scalar('select public.parent_notification_delivery($1)',[f.family])).items,[]);
    await admin();assert.equal(await scalar('select count(*)::int from public.parent_notification_receipts where family_id=$1',[f.family]),1);
  });
  await check('token rotation and logout fence late results; invalid tokens cannot disable a newer registration',async()=>{
    const f=await fixture();await f.prepare();await f.activate();await f.enqueue();let [job]=await f.claim();
    await f.authorize(job);await login(f.owner);await f.renew(`${f.token}-new`);
    assert.equal((await f.finish(job,'invalid_token')).status,'deferred');assert.equal((await f.readDevice()).state,'enabled');
    await client.query('update public.parent_push_jobs set next_attempt_at=now() where id=$1',[job.job_id]);[job]=await f.claim();
    assert.equal((await f.authorize(job)).registration_token,`${f.token}-new`);
    await login(f.owner);await f.revoke();assert.equal((await f.finish(job,'accepted')).status,'deferred');
    await admin();assert.equal(await scalar('select count(*)::int from public.parent_notification_receipts where family_id=$1',[f.family]),0);
    await login(f.owner);await f.prepare(3);await f.activate(3);
    await admin();await client.query('update public.parent_push_jobs set next_attempt_at=now() where id=$1',[job.job_id]);[job]=await f.claim();
    assert.equal((await f.finish(job,'invalid_token')).status,'cancelled');assert.equal((await f.readDevice()).state,'disabled');
    assert.equal((await f.readDevice()).registration_token,null);
  });
  await check('push leases survive crashes, reject stale workers and terminate bounded retries',async()=>{
    const f=await fixture();await f.prepare();await f.activate();await f.enqueue();let [job]=await f.claim();const old=job;
    await admin();await client.query("update public.parent_push_jobs set lease_until=now()-interval '1 second' where id=$1",[job.job_id]);
    [job]=await f.claim();assert.equal(job.job_id,old.job_id);assert.notEqual(job.lease_token,old.lease_token);
    assert.equal((await f.finish(old,'accepted')).status,'stale');
    for(let attempt=2;attempt<=5;attempt++) {
      assert.equal((await f.finish(job,'retry')).status,attempt<5?'queued':'cancelled');
      await admin();const row=await scalar('select to_jsonb(j) from public.parent_push_jobs j where id=$1',[job.job_id]);
      assert.equal(row.attempts,attempt);
      if(attempt<5) {assert.ok(Date.parse(row.next_attempt_at)>Date.now()+30000);
        await client.query('update public.parent_push_jobs set next_attempt_at=now() where id=$1',[job.job_id]);[job]=await f.claim();}
    }
    assert.deepEqual(await f.claim(),[]);
    await admin();await client.query("update public.parent_push_jobs set state='running',lease_until=now()-interval '1 second' where id=$1",[old.job_id]);
    assert.deepEqual(await f.claim(),[]);await admin();
    assert.equal(await scalar('select state from public.parent_push_jobs where id=$1',[old.job_id]),'cancelled');
  });
  await check('child deletion immediately removes queued notifications and late workers cannot recreate receipts',async()=>{
    const f=await fixture();await f.prepare();await f.activate();await f.enqueue();const [job]=await f.claim();await f.authorize(job);
    await admin();await client.query('insert into public.child_deletion_tombstones(child_id,family_id) values($1,$2)',[f.child,f.family]);
    assert.equal(await scalar('select count(*)::int from public.parent_push_jobs where child_id=$1',[f.child]),0);
    assert.equal((await f.finish(job,'accepted')).status,'stale');assert.equal(await f.enqueue(),0);
    await admin();assert.equal(await scalar('select count(*)::int from public.parent_notification_receipts where child_id=$1',[f.child]),0);
  });
  await check('two dispatchers claim a shared queue without sending the same job under two active leases',async()=>{
    const f=await fixture();await f.prepare();await f.activate();await admin();
    await client.query("insert into public.redemptions(child_id,reward_id,frozen_amount,expires_at) select $1,$2,10,now()+interval '7 days' from generate_series(1,11)",[f.child,f.reward]);
    assert.equal(await f.enqueue(),12);
    const workers=Array.from({length:2},()=>new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'}));
    try {
      for(const worker of workers) {await worker.connect();await worker.query('set role service_role');await worker.query('begin');}
      const results=await Promise.all(workers.map(worker=>worker.query('select public.claim_parent_push_jobs(6,\'["hms"]\') as claims')));
      const claimed=results.flatMap(r=>r.rows[0].claims);assert.equal(claimed.length,12);
      assert.equal(new Set(claimed.map(c=>c.job_id)).size,12);assert.equal(new Set(claimed.map(c=>c.lease_token)).size,12);
      for(const worker of workers) await worker.query('commit');assert.deepEqual(await f.claim(),[]);
    } finally {for(const worker of workers) {await worker.query('rollback').catch(()=>{});await worker.end();}}
  });
  await check('enqueue waiting on child deletion rechecks its source after the deletion commits',async()=>{
    const f=await fixture();await f.prepare();await f.activate();
    const worker=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});await worker.connect();
    try {
      await worker.query("set statement_timeout='5s'");await worker.query('set role service_role');
      const pid=(await worker.query('select pg_backend_pid() as pid')).rows[0].pid;
      await admin();await client.query('begin');await client.query("select pg_advisory_xact_lock(hashtextextended('cleanup:'||$1,0))",[f.child]);
      const work=worker.query('select public.enqueue_parent_push_jobs() as count');
      // Observe the actual advisory wait, rather than depending on an arbitrary sleep.
      let waiting=false;
      for(let i=0;i<100 && !waiting;i++) {waiting=await scalar("select coalesce(wait_event='advisory',false) from pg_stat_activity where pid=$1",[pid]);
        if(!waiting) await new Promise(resolve=>setTimeout(resolve,10));}
      assert.ok(waiting,'dispatcher reached child privacy barrier');
      await client.query('insert into public.child_deletion_tombstones(child_id,family_id) values($1,$2)',[f.child,f.family]);await client.query('commit');
      assert.equal((await work).rows[0].count,0);
    } finally {await client.query('rollback');await worker.end();}
  });
  await check('account deletion erases all registrations in owned families; membership removal cascades private queue',async()=>{
    const f=await fixture();await f.prepare();await f.activate();await f.enqueue();
    await login(f.peer);await scalar("select public.verify_parent_pin($1,'1234')",[f.family]);
    await scalar('select public.save_parent_notification_settings($1,$2,0)',[f.family,JSON.stringify(settings)]);
    await f.prepare(1,randomUUID(),randomUUID());
    await admin();await client.query("insert into public.account_deletion_jobs(id,user_id,owned_family_ids,child_ids,manifest,next_attempt_at) values($1,$2,$3,$4,'[]',now())",[randomUUID(),f.owner,[f.family],[f.child]]);
    assert.equal(await scalar('select count(*)::int from public.parent_push_devices where family_id=$1',[f.family]),0);
    assert.equal(await scalar('select count(*)::int from public.parent_push_jobs where family_id=$1',[f.family]),0);
    await login(f.peer);await assert.rejects(f.prepare(2));assert.equal(await f.enqueue(),0);
    const g=await fixture();await g.prepare();await g.activate();await g.enqueue();
    await admin();await client.query('delete from public.family_members where family_id=$1 and user_id=$2',[g.family,g.owner]);
    assert.equal(await scalar('select count(*)::int from public.parent_push_devices where family_id=$1',[g.family]),0);
    assert.equal(await scalar('select count(*)::int from public.parent_push_jobs where family_id=$1',[g.family]),0);
  });
  await check('push retention clears expired endpoints and old jobs, while batch limits do not starve later events',async()=>{
    const f=await fixture();await f.prepare();await f.activate();await admin();
    await client.query("insert into public.redemptions(child_id,reward_id,frozen_amount,expires_at) select $1,$2,10,now()+interval '7 days' from generate_series(1,200)",[f.child,f.reward]);
    assert.equal(await f.enqueue(),200);assert.equal(await f.enqueue(),1);assert.equal(await f.enqueue(),0);
    await admin();await client.query("update public.parent_push_jobs set expires_at=now()-interval '8 days' where family_id=$1",[f.family]);
    await client.query("update public.parent_push_devices set expires_at=now()-interval '1 second' where device_id=$1",[f.device]);
    await service();await scalar('select public.purge_parent_push()');const device=await f.readDevice();
    assert.equal(device.state,'disabled');assert.equal(device.registration_token,null);
    assert.equal(await scalar('select count(*)::int from public.parent_push_jobs where family_id=$1',[f.family]),0);
    await client.query("update public.parent_push_devices set updated_at=now()-interval '91 days' where device_id=$1",[f.device]);
    await service();await scalar('select public.purge_parent_push()');await admin();
    assert.equal(await scalar('select count(*)::int from public.parent_push_devices where device_id=$1',[f.device]),0);
  });
  await login();
}
