import assert from 'node:assert/strict';
import {randomUUID, randomBytes} from 'node:crypto';
import pg from 'pg';

export async function taskPushCases({client,scalar,login,denied,check}) {
  const admin=()=>client.query('reset role');
  const service=async()=>{await admin();await client.query('set role service_role');};
  async function fixture() {
    await admin();
    const owner=randomUUID(),peer=randomUUID(),outsider=randomUUID();
    for(const id of [owner,peer,outsider]) await client.query('insert into auth.users values($1,$2)',[id,`${id}@test.invalid`]);
    const family=await scalar("insert into public.families(name,timezone,owner_user_id) values('Task push','UTC',$1) returning id",[owner]);
    await client.query("insert into public.family_members values($1,$2,'admin'),($1,$3,'parent')",[family,owner,peer]);
    const child=await scalar("insert into public.children(family_id,nickname,grade) values($1,'PRIVATE CHILD',2) returning id",[family]);
    const sibling=await scalar("insert into public.children(family_id,nickname,grade) values($1,'SIBLING',3) returning id",[family]);
    const device=randomUUID(),nonce=randomUUID(),secret=randomBytes(32).toString('base64url'),token=randomBytes(32).toString('hex');
    const prepare=(version=1,n=nonce,c=child,id=device,s=secret)=>scalar('select public.prepare_task_push_device($1,$2,$3,$4,$5)',[c,id,s,version,n]);
    const activate=(version=1,t=token,id=device,s=secret)=>scalar('select public.activate_task_push_device($1,$2,$3,$4)',[id,s,version,t]);
    const renew=(version=1,t=token,s=secret)=>scalar('select public.renew_task_push_device($1,$2,$3,$4)',[device,s,version,t]);
    const revoke=(version=2,s=secret)=>scalar('select public.revoke_task_push_device($1,$2,$3)',[device,s,version]);
    const read=async()=>{await admin();return scalar('select to_jsonb(d) from public.task_push_devices d where device_id=$1',[device]);};
    await login(owner);
    return {owner,peer,outsider,family,child,sibling,device,nonce,secret,token,prepare,activate,renew,revoke,read};
  }
  await check('task push registry is private and registration requires membership in the selected child family',async()=>{
    const f=await fixture();
    for(const table of ['task_push_devices','task_push_policy_versions']) await denied(`select * from public.${table}`);
    for(const sql of [`select public.task_push_device_view('${f.device}')`,
      `select public.lock_task_push_scope('${f.child}','${f.owner}')`,
      `select * from public.task_reminder_candidates('${f.child}',now(),true)`,
      'select public.purge_task_push_devices()']) await denied(sql);
    await login(f.outsider);await assert.rejects(f.prepare(),{code:'42501'});
    await admin();await client.query('set role anon');await assert.rejects(f.prepare(),{code:'42501'});
    // Task reminders do not grant parent editing or reward privileges; no PIN is required to opt in.
    await login(f.owner,'without-pin');const value=await f.prepare();
    assert.equal(value.child_id,f.child);assert.equal(value.family_id,f.family);assert.equal(value.state,'prepared');
    assert.equal(value.settings_version,1);assert.equal(value.transport,'apns');assert.equal(value.timezone,'UTC');
    assert.doesNotMatch(JSON.stringify(value),/secret|registration|PRIVATE|SIBLING/);
    assert.deepEqual(Object.keys(await f.activate()).sort(),Object.keys(value).sort());
    await service();await denied('select * from public.task_push_devices');
    await denied(`select * from public.task_reminder_candidates('${f.child}',now(),true)`);
  });
  await check('task push revocation fences late activation and old logout cannot disable a newer intent',async()=>{
    const f=await fixture();await f.prepare();assert.equal((await f.prepare()).scope_nonce,f.nonce);
    await assert.rejects(f.prepare(1,randomUUID()),/INTENT_MISMATCH/);
    for(const v of [0,null,9007199254740992]) await assert.rejects(f.prepare(v));
    await assert.rejects(f.prepare(2,f.nonce,f.child,f.device,'short'));
    await admin();await client.query('set role anon');await f.revoke(2,'x'.repeat(43));
    await login(f.owner);assert.equal((await f.activate()).state,'enabled');
    await admin();await client.query('set role anon');await f.revoke();
    await login(f.owner);await assert.rejects(f.activate(),/STALE/);
    assert.equal((await f.prepare(2)).state,'disabled');
    await f.prepare(3);await f.activate(3);await f.revoke(2);
    assert.equal((await f.read()).state,'enabled');
    await login(f.owner);await assert.rejects(f.prepare(2),/STALE/);await f.revoke(4);
    const row=await f.read();assert.equal(row.state,'disabled');assert.equal(row.registration_token,null);
    assert.equal(row.registration_hash,null);assert.equal(row.expires_at,null);
  });
  await check('task push switching child and account changes scope without transferring old authorization',async()=>{
    const f=await fixture();await f.prepare();await f.activate();
    await assert.rejects(f.prepare(1,f.nonce,f.sibling),/INTENT_MISMATCH/);
    const nonce=randomUUID();assert.equal((await f.prepare(2,nonce,f.sibling)).child_id,f.sibling);
    await assert.rejects(f.activate(),/STALE/);await f.activate(2);
    await login(f.peer);await assert.rejects(f.renew(2),/ACCESS_DENIED/);
    await assert.rejects(f.prepare(3,nonce,f.child,f.device,'x'.repeat(43)),/SECRET_MISMATCH/);
    await f.prepare(3,randomUUID());await f.activate(3);
    await login(f.owner);await assert.rejects(f.renew(3),/ACCESS_DENIED/);
    assert.equal((await f.read()).owner_id,f.peer);
  });
  await check('task APNs tokens support varying byte lengths, uniqueness, bounded preparation and renewal',async()=>{
    const f=await fixture();await f.prepare();
    for(const token of ['',null,'abc','z'.repeat(64),'AA','aa'.repeat(2049)]) await assert.rejects(f.activate(1,token),/INVALID_TASK_PUSH_TOKEN/);
    await f.activate(1,'ab'.repeat(48));await assert.rejects(f.activate(),/INTENT_MISMATCH/);
    assert.equal((await f.renew()).state,'enabled');
    const second=randomUUID();await f.prepare(1,randomUUID(),f.child,second);
    await assert.rejects(f.activate(1,f.token,second),{code:'23505'});
    await assert.rejects(f.renew(1,f.token,'wrong'),{code:'42501'});
    await admin();await client.query("update public.task_push_devices set expires_at=now()-interval '1 second' where device_id=$1",[f.device]);
    await login(f.owner);await assert.rejects(f.renew(),/STALE/);await f.prepare(2);
    await admin();await client.query("update public.task_push_devices set prepared_until=now()-interval '1 second' where device_id=$1",[f.device]);
    await login(f.owner);await assert.rejects(f.activate(2),/PREPARATION_EXPIRED/);
  });
  await check('task policy revisions follow quiet settings and timezone; disabled settings prevent activation and renewal',async()=>{
    const f=await fixture();await f.prepare();await f.activate();
    await admin();await client.query("insert into public.reminder_settings values($1,true,'21:00','07:00')",[f.child]);
    await login(f.owner);assert.equal((await f.renew()).settings_version,2);
    await admin();await client.query('update public.reminder_settings set enabled=enabled where child_id=$1',[f.child]);
    await client.query("update public.families set timezone='Asia/Shanghai' where id=$1",[f.family]);
    await login(f.owner);const v=await f.renew();assert.equal(v.settings_version,3);assert.equal(v.timezone,'Asia/Shanghai');
    await admin();await client.query('update public.reminder_settings set enabled=false where child_id=$1',[f.child]);
    await login(f.owner);await assert.rejects(f.renew(),/DISABLED/);await assert.rejects(f.activate(),/DISABLED/);await assert.rejects(f.prepare(2),/DISABLED/);
    await admin();await client.query('delete from public.reminder_settings where child_id=$1',[f.child]);
    await login(f.owner);assert.equal((await f.renew()).settings_version,5);
    await admin();const source=JSON.stringify(await scalar('select public.child_export_source($1)',[f.child]));
    for(const hidden of [f.secret,f.token,'task_push_devices','task_push_policy_versions']) assert.ok(!source.includes(hidden));
  });
  await check('task registrations disappear at child/account deletion and membership removal',async()=>{
    const f=await fixture();await f.prepare();await f.activate();
    await admin();await client.query('insert into public.child_deletion_tombstones(child_id,family_id) values($1,$2)',[f.child,f.family]);
    assert.equal(await scalar('select count(*)::int from public.task_push_devices where device_id=$1',[f.device]),0);
    await login(f.owner);await assert.rejects(f.prepare(2),{code:'42501'});await assert.rejects(f.renew(),{code:'42501'});
    const g=await fixture();await g.prepare();await g.activate();await login(g.peer);await g.prepare(1,randomUUID(),g.child,randomUUID());
    await admin();await client.query("insert into public.account_deletion_jobs(id,user_id,owned_family_ids,child_ids,manifest,next_attempt_at) values($1,$2,$3,$4,'[]',now())",[randomUUID(),g.owner,[g.family],[g.child,g.sibling]]);
    assert.equal(await scalar('select count(*)::int from public.task_push_devices where family_id=$1',[g.family]),0);
    await login(g.peer);await assert.rejects(g.prepare(2),{code:'42501'});
    const h=await fixture();await h.prepare();await h.activate();await admin();
    await client.query('delete from public.family_members where family_id=$1 and user_id=$2',[h.family,h.owner]);
    assert.equal(await scalar('select count(*)::int from public.task_push_devices where device_id=$1',[h.device]),0);
    await client.query("insert into public.reminder_settings values($1,true,'21:00','07:00')",[h.child]);
    await client.query('delete from public.children where id=$1',[h.child]);
    assert.equal(await scalar('select count(*)::int from public.task_push_policy_versions where child_id=$1',[h.child]),0);
  });
  await check('task activation waiting on revocation observes the newer intent after the lock releases',async()=>{
    const f=await fixture();await f.prepare();
    const worker=new pg.Client(client.connectionParameters);await worker.connect();
    try {
      await worker.query("set statement_timeout='5s'");
      await worker.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:f.owner,role:'authenticated',session_id:'delayed'})]);
      await worker.query('set role authenticated');const pid=(await worker.query('select pg_backend_pid() as pid')).rows[0].pid;
      await admin();await client.query('begin');await client.query("select pg_advisory_xact_lock(hashtextextended('task-push-device:'||$1,0))",[f.device]);
      const result=worker.query('select public.activate_task_push_device($1,$2,1,$3)',[f.device,f.secret,f.token]).then(()=>null,e=>e);
      let waiting=false;
      for(let i=0;i<100&&!waiting;i++) {waiting=await scalar("select coalesce(wait_event='advisory',false) from pg_stat_activity where pid=$1",[pid]);if(!waiting) await new Promise(r=>setTimeout(r,10));}
      assert.ok(waiting);await f.revoke();await client.query('commit');assert.match((await result).message,/STALE/);
      assert.equal((await f.read()).state,'disabled');
    } finally {await client.query('rollback');await worker.end();}
  });
  await check('task push retention removes expired endpoints and aged disabled registrations',async()=>{
    const f=await fixture();await f.prepare();await f.activate();await admin();
    await client.query("update public.task_push_devices set expires_at=now()-interval '1 second' where device_id=$1",[f.device]);
    await service();await scalar('select public.purge_task_push_devices()');const row=await f.read();assert.equal(row.state,'disabled');assert.equal(row.registration_token,null);
    await client.query("update public.task_push_devices set updated_at=now()-interval '91 days' where device_id=$1",[f.device]);
    await service();await scalar('select public.purge_task_push_devices()');await admin();
    assert.equal(await scalar('select count(*)::int from public.task_push_devices where device_id=$1',[f.device]),0);
  });
  await login();
}
