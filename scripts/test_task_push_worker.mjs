import assert from 'node:assert/strict';
import {test} from 'node:test';
import {randomUUID,generateKeyPairSync,verify} from 'node:crypto';
import {createTaskPushTransports,drainTaskPush,validTaskPush} from '../supabase/functions/_shared/task_push_worker.mjs';
import {validParentPush} from '../supabase/functions/_shared/parent_push_worker.mjs';

const instant=Date.parse('2026-11-06T04:00:00Z');
const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const config={TASK_PUSH_APNS_KEY:privateKey.export({format:'pem',type:'pkcs8'}),TASK_PUSH_APNS_KEY_ID:'ABC1234567',
  TASK_PUSH_APNS_TEAM_ID:'DEF1234567',TASK_PUSH_APNS_TOPIC:'com.learningplanet.learning_planet',TASK_PUSH_APNS_ENVIRONMENT:'sandbox'};
function message(id=randomUUID()) {
  return {status:'authorized',transport:'apns',registration_token:'ab'.repeat(48),data:{version:'task-push-v1',kind:'task',
    message_id:id,scope_nonce:randomUUID(),scheduled_ms:String(instant-60000),issued_ms:String(instant),expires_ms:String(instant+60000),
    quiet_start:'21:00:00',quiet_end:'07:00:00',timezone:'Asia/Shanghai',settings_version:'2'}};
}
test('task payload accepts only opaque due slots within their short dispatch and delivery windows',()=>{
  assert.equal(validTaskPush(message(),instant),true);assert.equal(validParentPush(message(),instant),false);
  for(const change of [{version:'parent-push-v1'},{kind:'weekly'},{title:'PRIVATE'},{scheduled_ms:String(instant+1)},
    {scheduled_ms:String(instant-900000)},{issued_ms:String(instant+30001)},{expires_ms:String(instant)},
    {expires_ms:String(instant+60001)},{settings_version:'9007199254740992'},{quiet_start:'24:00:00'},{timezone:'bad-zone'}]) {
    const m=message();Object.assign(m.data,change);assert.equal(validTaskPush(m,instant),false);
  }
  for(const token of ['abc','AB','ab'.repeat(2049),'a/b']) {const m=message();m.registration_token=token;assert.equal(validTaskPush(m,instant),false);}
});
test('task transport requires explicit configuration and keeps parent credentials separate',()=>{
  assert.deepEqual(createTaskPushTransports(()=>undefined),{});
  const parent=Object.fromEntries(Object.entries(config).map(([k,v])=>[k.replace('TASK_PUSH','PARENT_PUSH'),v]));
  assert.deepEqual(createTaskPushTransports(k=>parent[k]),{});
  assert.throws(()=>createTaskPushTransports(k=>k==='TASK_PUSH_APNS_ENVIRONMENT'?'sandbox':undefined),/CONFIG/);
});
test('task APNs requests contain no alert, use scope collapse and discard undeliverable messages',async()=>{
  const m=message();let calls=0;
  const {apns}=createTaskPushTransports(k=>config[k],{now:()=>instant,fetcher:async(url,options)=>{
    calls++;assert.equal(url,`https://api.sandbox.push.apple.com/3/device/${m.registration_token}`);
    const h=options.headers;assert.equal(h['apns-push-type'],'background');assert.equal(h['apns-priority'],'5');
    assert.equal(h['apns-expiration'],'0');assert.equal(h['apns-collapse-id'],`task-${m.data.scope_nonce}`);
    const [header,payload,signature]=h.authorization.slice(7).split('.');
    assert.ok(verify('sha256',Buffer.from(`${header}.${payload}`),{key:publicKey,dsaEncoding:'ieee-p1363'},Buffer.from(signature,'base64url')));
    assert.deepEqual(JSON.parse(options.body),{aps:{'content-available':1},...m.data});assert.equal(options.redirect,'error');
    return new Response(null,{status:200});
  }});
  assert.equal(await apns(m),'accepted');m.data.expires_ms=String(instant);assert.equal(await apns(m),'rejected');assert.equal(calls,1);
});
test('task dispatcher reauthorizes each claim, retries uncertain results and returns aggregate counts only',async()=>{
  const jobs=Array.from({length:7},()=>({job_id:randomUUID(),lease_token:randomUUID()}));let inFlight=0,max=0,sends=0;
  const outcomes=[];
  const rpc=async(name,args)=>{
    if(name==='purge_task_push'||name==='enqueue_task_push_jobs') return {data:0};
    if(name==='claim_task_push_jobs') {assert.deepEqual(args,{max_jobs:20});return {data:jobs};}
    const index=jobs.findIndex(j=>j.job_id===args.target_job_id);assert.equal(args.token,jobs[index].lease_token);
    if(name==='authorize_task_push_job') {
      if(index===0) return {data:{status:'cancelled'}};
      const m=message(jobs[index].job_id);if(index===1) m.data.child_name='PRIVATE';return {data:m};
    }
    assert.equal(name,'finish_task_push_job');outcomes.push(args.outcome);return {data:{status:args.outcome==='accepted'?'sent':args.outcome==='retry'?'queued':'cancelled'}};
  };
  const stats=await drainTaskPush(rpc,{apns:async()=>{inFlight++;max=Math.max(max,inFlight);const count=++sends;await new Promise(r=>setTimeout(r,5));inFlight--;return count===5?'unrecognized':'accepted';}},{now:()=>instant});
  assert.equal(sends,5);assert.ok(max<=4);assert.equal(stats.claimed,7);assert.equal(stats.cancelled,2);assert.equal(stats.unsettled,0);
  assert.ok(outcomes.includes('retry'));assert.doesNotMatch(JSON.stringify(stats),/token|PRIVATE|scope/);
});
test('task dispatcher rejects unconfigured providers, duplicate claims and mismatched authorized job IDs',async()=>{
  await assert.rejects(drainTaskPush(()=>{throw Error('unexpected');},{}),/NOT_CONFIGURED/);
  const j={job_id:randomUUID(),lease_token:randomUUID()};
  await assert.rejects(drainTaskPush(async n=>({data:n==='claim_task_push_jobs'?[j,j]:0}),{apns:async()=>{throw Error('unexpected');}}),/CLAIMS_INVALID/);
  let sends=0;
  const stats=await drainTaskPush(async(n,args)=>({data:n==='claim_task_push_jobs'?[j]:n==='authorize_task_push_job'?message():
    n==='finish_task_push_job'?(assert.equal(args.outcome,'rejected'),{status:'cancelled'}):0}),{apns:async()=>{sends++;return 'accepted';}},{now:()=>instant});
  assert.equal(sends,0);assert.equal(stats.cancelled,1);
});
