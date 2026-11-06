import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { resolve } from 'node:path';

const secret='private-test-service-key',deviceToken='private-test-device-token',oauthToken='private-test-oauth-token';
const id=randomUUID(),lease=randomUUID();let status='queued',sends=0,auths=0,claims=0,forceFailure=true,authorized=true;
const mock=createServer(async(request,response)=>{
  const buffers=[];for await(const value of request) buffers.push(value);
  const route=new URL(request.url,'http://127.0.0.1').pathname;
  const text=Buffer.concat(buffers).toString();
  const reply=(code,body)=>{response.writeHead(code,{'Content-Type':'application/json'});response.end(JSON.stringify(body));};
  if(route==='/push-auth') {
    auths++;const body=new URLSearchParams(text);assert.equal(body.get('client_id'),'123456789');
    assert.equal(body.get('client_secret'),'private-test-hms-secret');return reply(200,{access_token:oauthToken,expires_in:3600});
  }
  if(route==='/push-send') {
    sends++;assert.equal(request.headers.authorization,`Bearer ${oauthToken}`);const body=JSON.parse(text);
    assert.deepEqual(body.message.token,[deviceToken]);assert.equal(body.message.android.ttl,'0s');
    assert.ok(!body.message.notification);assert.equal(JSON.parse(body.message.data).message_id,id);
    return forceFailure?reply(503,{message:`PRIVATE ${deviceToken}`}):reply(200,{code:'80000000'});
  }
  assert.equal(request.headers.authorization,`Bearer ${secret}`);
  if(route==='/rest/v1/rpc/enqueue_parent_push_jobs') return reply(200,0);
  if(route==='/rest/v1/rpc/claim_parent_push_jobs') {
    claims++;assert.deepEqual(JSON.parse(text),{max_jobs:20,transports:['hms']});
    if(status!=='queued') return reply(200,[]);status='running';return reply(200,[{job_id:id,lease_token:lease}]);
  }
  if(route==='/rest/v1/rpc/authorize_parent_push_job') {
    assert.deepEqual(JSON.parse(text),{target_job_id:id,token:lease});
    if(!authorized) {status='cancelled';return reply(200,{status:'cancelled'});}
    const now=Date.now();return reply(200,{status:'authorized',transport:'hms',registration_token:deviceToken,data:{
      version:'parent-push-v1',message_id:id,scope_nonce:randomUUID(),kind:'weekly',issued_ms:String(now),expires_ms:String(now+60000),
      timezone:'Asia/Shanghai',quiet_start:'21:00:00',quiet_end:'07:00:00',settings_version:'3',
    }});
  }
  if(route==='/rest/v1/rpc/finish_parent_push_job') {
    const body=JSON.parse(text);assert.deepEqual(body,{target_job_id:id,token:lease,outcome:forceFailure?'retry':'accepted'});
    status=forceFailure?'queued':'sent';return reply(200,{status});
  }
  reply(404,{});
});
await new Promise(resolve=>mock.listen(0,'127.0.0.1',resolve));const mockPort=mock.address().port;
const binary=process.platform==='win32'?resolve('node_modules/deno/deno.exe'):resolve('node_modules/.bin/deno');
async function start(configured) {
  const reserve=createServer();await new Promise(resolve=>reserve.listen(0,'127.0.0.1',resolve));const port=reserve.address().port;
  await new Promise(resolve=>reserve.close(resolve));
  const env={...process.env,SUPABASE_URL:`http://127.0.0.1:${mockPort}`,SUPABASE_SERVICE_ROLE_KEY:secret,
    TEST_EDGE_PORT:String(port),TEST_EDGE_KIND:'parent-push'};
  for(const key of Object.keys(env)) if(key.startsWith('PARENT_PUSH_')) delete env[key];
  if(configured) Object.assign(env,{PARENT_PUSH_HMS_APP_ID:'123456789',PARENT_PUSH_HMS_APP_SECRET:'private-test-hms-secret'});
  const names=['SUPABASE_URL','SUPABASE_SERVICE_ROLE_KEY','TEST_EDGE_PORT','TEST_EDGE_KIND','PARENT_PUSH_HMS_APP_ID','PARENT_PUSH_HMS_APP_SECRET',
    'PARENT_PUSH_APNS_KEY','PARENT_PUSH_APNS_KEY_ID','PARENT_PUSH_APNS_TEAM_ID','PARENT_PUSH_APNS_TOPIC','PARENT_PUSH_APNS_ENVIRONMENT','PARENT_PUSH_GATEWAY_URL','PARENT_PUSH_GATEWAY_KEY'];
  const child=spawn(binary,['run','--cached-only','--config','supabase/functions/worksheet-render/deno.json',
    `--allow-env=${names.join(',')}`,`--allow-net=127.0.0.1:${mockPort},127.0.0.1:${port}`,
    `--allow-read=${resolve('supabase/functions')}`,'scripts/fixtures/edge_bootstrap.mjs'],{windowsHide:true,env,stdio:['ignore','pipe','pipe']});
  let logs='';child.stdout.on('data',v=>logs+=v);child.stderr.on('data',v=>logs+=v);const exited=once(child,'exit');
  const endpoint=`http://127.0.0.1:${port}`;
  const stop=async()=>{child.kill();await exited;
    for(const value of [secret,deviceToken,oauthToken,'private-test-hms-secret']) assert.ok(!logs.includes(value),'logs must not contain credentials');};
  try {
    let ready=false;
    for(let i=0;i<100 && !ready;i++) {if(child.exitCode!==null) throw new Error(logs);
      try {ready=(await fetch(endpoint)).status===405;} catch {await new Promise(resolve=>setTimeout(resolve,50));}}
    assert.ok(ready);return {endpoint,stop};
  } catch(error) {await stop();throw error;}
}
async function until(predicate) {for(let i=0;i<200;i++) {if(predicate()) return;await new Promise(resolve=>setTimeout(resolve,25));}throw new Error('Local push worker did not settle');}
try {
  const empty=await start(false);
  try {
    const response=await fetch(empty.endpoint,{method:'POST',headers:{Authorization:`Bearer ${secret}`},body:'{"mode":"drain"}'});
    assert.equal(response.status,503);assert.deepEqual(await response.json(),{error:'PUSH_NOT_CONFIGURED'});assert.equal(claims,0);
  } finally {await empty.stop();}
  const edge=await start(true);
  const post=(body,token=secret)=>fetch(edge.endpoint,{method:'POST',headers:{Authorization:`Bearer ${token}`},body});
  try {
    assert.equal((await post('{"mode":"drain"}','parent-token')).status,403);
    assert.equal((await post('{"mode":"drain","registration_token":"untrusted"}')).status,400);
    assert.equal((await post('{invalid json')).status,400);
    assert.equal((await post('x'.repeat(1025))).status,413);assert.equal(claims,0);
    let response=await post('{"mode":"drain"}');assert.equal(response.status,202);assert.deepEqual(await response.json(),{status:'accepted'});
    assert.equal(response.headers.get('cache-control'),'no-store');await until(()=>sends===1 && status==='queued');
    forceFailure=false;assert.equal((await post('{"mode":"drain"}')).status,202);await until(()=>status==='sent');
    assert.equal(sends,2);assert.equal(auths,1);
    const before=claims;await post('{"mode":"drain"}');await until(()=>claims>before);assert.equal(sends,2);
    status='queued';authorized=false;await post('{"mode":"drain"}');await until(()=>status==='cancelled');assert.equal(sends,2);
  } finally {await edge.stop();}
  console.log('Parent push Edge HTTP smoke passed: service-only auth, no-config refusal, real Supabase RPC transport, HMS OAuth/data request, retry, replay and revocation. Local mocks only.');
} finally {mock.closeAllConnections();await new Promise(resolve=>mock.close(resolve));}
