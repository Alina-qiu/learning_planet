import assert from 'node:assert/strict';
import {randomBytes,randomUUID} from 'node:crypto';
import pg from 'pg';

export async function taskPushQueueCases({client,scalar,login,denied,check}) {
  const admin=()=>client.query('reset role');
  const service=async()=>{await admin();await client.query('set role service_role');};
  async function fixture() {
    await admin();await client.query("update public.task_push_devices set state='disabled',registration_token=null,registration_hash=null");
    const owner=randomUUID(),device=randomUUID(),secret=randomBytes(32).toString('base64url'),nonce=randomUUID(),token=randomBytes(32).toString('hex');
    await client.query('insert into auth.users values($1,$2)',[owner,`${owner}@test.invalid`]);
    const family=await scalar("insert into public.families(name,timezone,owner_user_id) values('Push queue','UTC',$1) returning id",[owner]);
    await client.query("insert into public.family_members values($1,$2,'admin')",[family,owner]);
    const child=await scalar("insert into public.children(family_id,nickname,grade) values($1,'PRIVATE CHILD',1) returning id",[family]);
    await client.query("insert into public.reminder_settings values($1,true,'00:00','00:00')",[child]);
    // Only the start slot is currently due: the pre-start slot is over 15 minutes old.
    const at=await scalar("select date_trunc('second',now())-interval '6 minutes'");
    const task=await scalar("insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key,scheduled_at,due_at) values($1,'PRIVATE TASK',(now() at time zone 'UTC')::date,'parent_template',$2,$3,$3::timestamptz+interval '1 hour') returning id",[child,randomUUID(),at]);
    await login(owner);
    await scalar('select public.prepare_task_push_device($1,$2,$3,1,$4)',[child,device,secret,nonce]);
    await scalar('select public.activate_task_push_device($1,$2,1,$3)',[device,secret,token]);
    const enqueue=async()=>{await service();return scalar('select public.enqueue_task_push_jobs()');};
    const claim=async(n=20)=>{await service();return scalar('select public.claim_task_push_jobs($1)',[n]);};
    const authorize=async j=>{await service();return scalar('select public.authorize_task_push_job($1,$2)',[j.job_id,j.lease_token]);};
    const finish=async(j,outcome)=>{await service();return scalar('select public.finish_task_push_job($1,$2,$3)',[j.job_id,j.lease_token,outcome]);};
    return {owner,family,child,task,at,device,secret,nonce,token,enqueue,claim,authorize,finish};
  }
  await check('task push queue and dispatcher are service-only; due slots merge and provider acceptance never reads a task',async()=>{
    const f=await fixture();
    await denied('select * from public.task_push_jobs');await denied('select public.enqueue_task_push_jobs()');
    await denied('select public.claim_task_push_jobs(1)');await denied('select public.purge_task_push()');
    await admin();await client.query("insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key,scheduled_at) values($1,'SECOND PRIVATE TASK',(now() at time zone 'UTC')::date,'parent_template',$2,$3)",[f.child,randomUUID(),f.at]);
    assert.equal(await f.enqueue(),1);assert.equal(await f.enqueue(),0);
    const [j]=await f.claim();assert.deepEqual(Object.keys(j).sort(),['job_id','lease_token']);assert.deepEqual(await f.claim(),[]);
    const value=await f.authorize(j);assert.equal(value.status,'authorized');assert.equal(value.registration_token,f.token);
    assert.deepEqual(Object.keys(value.data).sort(),['expires_ms','issued_ms','kind','message_id','quiet_end','quiet_start','scheduled_ms','scope_nonce','settings_version','timezone','version']);
    assert.equal(value.data.kind,'task');assert.equal(value.data.version,'task-push-v1');assert.equal(value.data.scope_nonce,f.nonce);
    assert.equal(Number(value.data.scheduled_ms),f.at.getTime());assert.equal(value.data.message_id,j.job_id);
    assert.ok(Number(value.data.expires_ms)-Number(value.data.issued_ms)<=60000);
    for(const hidden of [f.owner,f.family,f.child,f.task,'PRIVATE']) assert.ok(!JSON.stringify(value.data).includes(hidden));
    assert.equal((await f.finish(j,'accepted')).status,'sent');assert.equal((await f.finish(j,'accepted')).status,'sent');
    assert.equal(await f.enqueue(),0);await admin();
    assert.equal(await scalar('select count(*)::int from public.reminder_receipts where child_id=$1',[f.child]),0);
    assert.equal(await scalar("select status::text from public.task_instances where id=$1",[f.task]),'ready');
  });
  await check('task dispatch rechecks completion, receipts, parent disable and quiet hours before sending',async()=>{
    for(const mutation of ['completion','receipt','disable','quiet']) {
      const f=await fixture();await f.enqueue();const [j]=await f.claim();await admin();
      if(mutation==='completion') await client.query("update public.task_instances set status='abandoned' where id=$1",[f.task]);
      if(mutation==='receipt') await client.query("insert into public.reminder_receipts(child_id,reminder_key) values($1,'slot:'||extract(epoch from $2::timestamptz)::bigint::text)",[f.child,f.at]);
      if(mutation==='disable') await client.query('update public.reminder_settings set enabled=false where child_id=$1',[f.child]);
      if(mutation==='quiet') await client.query("update public.reminder_settings set quiet_start=((now() at time zone 'UTC')-interval '1 hour')::time,quiet_end=((now() at time zone 'UTC')+interval '1 hour')::time where child_id=$1",[f.child]);
      assert.equal((await f.authorize(j)).status,'cancelled',mutation);assert.equal(await f.enqueue(),0,mutation);
    }
  });
  await check('task queue includes recently due snoozes while the public future snooze list excludes them',async()=>{
    const f=await fixture();await admin();
    await client.query('update public.task_instances set scheduled_at=null,due_at=null where id=$1',[f.task]);
    await client.query('insert into public.review_reminder_requests(task_id,remind_at,revision,delay_minutes) values($1,$2,1,15)',[f.task,f.at]);
    await login(f.owner);assert.equal((await client.query('select * from public.load_task_reminders($1)',[f.child])).rows.length,0);
    assert.equal(await f.enqueue(),1);const [j]=await f.claim();assert.equal((await f.authorize(j)).status,'authorized');
    await admin();await client.query('update public.review_reminder_requests set remind_at=null,revision=2,delay_minutes=0 where task_id=$1',[f.task]);
    assert.equal((await f.authorize(j)).status,'cancelled');
  });
  await check('task token rotation and changed device scope fence stale workers and invalid-token results',async()=>{
    const f=await fixture();await f.enqueue();let [j]=await f.claim();await f.authorize(j);
    await login(f.owner);const rotated=randomBytes(48).toString('hex');await scalar('select public.renew_task_push_device($1,$2,1,$3)',[f.device,f.secret,rotated]);
    assert.equal((await f.finish(j,'invalid_token')).status,'deferred');[j]=await f.claim();assert.equal((await f.authorize(j)).registration_token,rotated);
    await login(f.owner);await scalar('select public.revoke_task_push_device($1,$2,2)',[f.device,f.secret]);
    assert.equal((await f.finish(j,'accepted')).status,'cancelled');await admin();
    assert.equal(await scalar('select state from public.task_push_devices where device_id=$1',[f.device]),'disabled');
  });
  await check('task queue leases recover crashed workers, reject stale results and bound retry attempts',async()=>{
    const f=await fixture();await f.enqueue();let [j]=await f.claim();const old=j;
    await admin();await client.query("update public.task_push_jobs set lease_until=now()-interval '1 second' where id=$1",[j.job_id]);
    [j]=await f.claim();assert.notEqual(j.lease_token,old.lease_token);assert.equal((await f.finish(old,'accepted')).status,'stale');
    for(let attempt=2;attempt<=5;attempt++) {
      assert.equal((await f.finish(j,'retry')).status,attempt===5?'cancelled':'queued');
      await admin();assert.equal(await scalar('select attempts from public.task_push_jobs where id=$1',[j.job_id]),attempt);
      if(attempt<5) {await client.query('update public.task_push_jobs set next_attempt_at=now() where id=$1',[j.job_id]);[j]=await f.claim();}
    }
    assert.deepEqual(await f.claim(),[]);for(const n of [0,21,null]) await assert.rejects(f.claim(n));
    await admin();await client.query("update public.task_push_jobs set expires_at=now()-interval '8 days' where id=$1",[j.job_id]);
    await service();await scalar('select public.purge_task_push()');await admin();assert.equal(await scalar('select count(*)::int from public.task_push_jobs where id=$1',[j.job_id]),0);
  });
  await check('task deletion erases queued deliveries and prevents late worker recreation',async()=>{
    const f=await fixture();await f.enqueue();const [j]=await f.claim();await f.authorize(j);await admin();
    await client.query('insert into public.child_deletion_tombstones(child_id,family_id) values($1,$2)',[f.child,f.family]);
    assert.equal(await scalar('select count(*)::int from public.task_push_jobs where child_id=$1',[f.child]),0);
    assert.equal((await f.finish(j,'accepted')).status,'stale');assert.equal((await f.authorize(j)).status,'stale');assert.equal(await f.enqueue(),0);
  });
  await check('concurrent task dispatchers obtain disjoint leases',async()=>{
    const f=await fixture();await admin();
    for(let i=1;i<=7;i++) await client.query("insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key,scheduled_at) values($1,'Queue task',(now() at time zone 'UTC')::date,'parent_template',$2,$3::timestamptz+make_interval(secs=>$4))",[f.child,randomUUID(),f.at,i]);
    assert.equal(await f.enqueue(),8);const workers=[new pg.Client(client.connectionParameters),new pg.Client(client.connectionParameters)];
    try {
      for(const w of workers) {await w.connect();await w.query('set role service_role');await w.query('begin');}
      const results=await Promise.all(workers.map(w=>w.query('select public.claim_task_push_jobs(4) as claims')));
      const jobs=results.flatMap(r=>r.rows[0].claims);assert.equal(jobs.length,8);assert.equal(new Set(jobs.map(j=>j.job_id)).size,8);
      for(const w of workers) await w.query('commit');assert.deepEqual(await f.claim(),[]);
    } finally {for(const w of workers) {await w.query('rollback').catch(()=>{});await w.end();}}
  });
  await login();
}
