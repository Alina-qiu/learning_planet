import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {resolve} from 'node:path';
const id='10000000-0000-0000-0000-000000000001',user='20000000-0000-0000-0000-000000000002',lease='30000000-0000-0000-0000-000000000003';
const path=`${user}/${lease}/original.jpg`,secret='local-test-account-secret';
let status='queued',phase='files',fileExists=true,authExists=true,failAuth=true,authCalls=0;
const mock=createServer(async(request,response)=>{
  const buffers=[];for await(const buffer of request) buffers.push(buffer);
  const text=Buffer.concat(buffers).toString(),route=new URL(request.url,'http://127.0.0.1').pathname;
  const reply=(code,body)=>{response.writeHead(code,{'Content-Type':'application/json'});response.end(JSON.stringify(body));};
  const bearer=request.headers.authorization;
  if(route==='/auth/v1/user') return ['Bearer self-token','Bearer other-token'].includes(bearer)
    ?reply(200,{id:bearer==='Bearer self-token'?user:lease,email:'local@example.test',app_metadata:{},user_metadata:{},aud:'authenticated',created_at:'2026-01-01'})
    :reply(401,{message:'bad token'});
  if(route==='/rest/v1/rpc/account_deletion_status') return reply(200,bearer==='Bearer self-token'?{id,status,phase}:null);
  if(bearer!==`Bearer ${secret}`) return reply(403,{message:'service only'});
  if(route==='/rest/v1/rpc/pending_account_deletions') return reply(200,status==='completed'?[]:[id]);
  if(route==='/rest/v1/rpc/claim_account_deletion') {
    assert.equal(JSON.parse(text).target_job_id,id);
    if(status==='completed') return reply(200,{id,status});
    status='running';return reply(200,{id,user_id:user,status:'claimed',phase,lease_token:lease,manifest:[{bucket:'wrong-question-images',path}]});
  }
  if(route==='/storage/v1/object/wrong-question-images'&&request.method==='DELETE') {
    assert.deepEqual(JSON.parse(text).prefixes,[path]);fileExists=false;return reply(200,[{name:path}]);
  }
  if(route===`/storage/v1/object/wrong-question-images/${path}`&&request.method==='HEAD') {
    response.writeHead(fileExists?200:404);return response.end();
  }
  if(route==='/rest/v1/rpc/prepare_account_auth_deletion') {
    assert.equal(fileExists,false);phase='auth';return reply(200,user);
  }
  if(route===`/auth/v1/admin/users/${user}`&&request.method==='DELETE') {
    authCalls++;assert.equal(phase,'auth');assert.equal(JSON.parse(text).should_soft_delete,false);
    if(failAuth) return reply(503,{code:'unexpected_failure',message:'local failure'});
    authExists=false;return reply(200,{user:{id:user}});
  }
  if(route==='/rest/v1/rpc/finish_account_deletion') {
    const args=JSON.parse(text);
    if(args.failure_code){status='failed';return reply(200,null);}
    assert.equal(authExists,false);status='completed';return reply(200,null);
  }
  return reply(404,{message:'unexpected local route '+route});
});
await new Promise(resolve=>mock.listen(0,'127.0.0.1',resolve));const mockPort=mock.address().port;
const reserve=createServer();await new Promise(resolve=>reserve.listen(0,'127.0.0.1',resolve));const edgePort=reserve.address().port;await new Promise(resolve=>reserve.close(resolve));
const child=spawn(process.platform==='win32'?resolve('node_modules/deno/deno.exe'):resolve('node_modules/.bin/deno'),[
  'run','--cached-only','--config','supabase/functions/worksheet-render/deno.json',
  '--allow-env=SUPABASE_URL,SUPABASE_ANON_KEY,SUPABASE_SERVICE_ROLE_KEY,TEST_EDGE_PORT,TEST_EDGE_KIND',
  `--allow-net=127.0.0.1:${mockPort},127.0.0.1:${edgePort}`,`--allow-read=${resolve('supabase/functions')}`,
  'scripts/fixtures/edge_bootstrap.mjs',
],{windowsHide:true,env:{...process.env,SUPABASE_URL:`http://127.0.0.1:${mockPort}`,SUPABASE_ANON_KEY:'local-anon',SUPABASE_SERVICE_ROLE_KEY:secret,TEST_EDGE_PORT:String(edgePort),TEST_EDGE_KIND:'account'},stdio:['ignore','pipe','pipe']});
let logs='';child.stdout.on('data',data=>logs+=data);child.stderr.on('data',data=>logs+=data);
const exited=once(child,'exit'),endpoint=`http://127.0.0.1:${edgePort}`;
const post=(token,body)=>fetch(endpoint,{method:'POST',headers:{Authorization:`Bearer ${token}`},body:JSON.stringify(body)});
async function waitFor(expected) {
  for(let i=0;i<100;i++) {if(child.exitCode!==null)throw new Error(logs);if(status===expected)return;await new Promise(resolve=>setTimeout(resolve,100));}
  throw new Error('state '+status+' expected '+expected+' '+logs);
}
try {
  let ready=false;for(let i=0;i<100&&!ready;i++) {
    if(child.exitCode!==null)throw new Error(logs);
    try {ready=(await fetch(endpoint,{method:'OPTIONS'})).status===204;}catch{await new Promise(resolve=>setTimeout(resolve,100));}
  }
  assert.equal(ready,true);
  assert.equal((await fetch(endpoint,{method:'POST',body:'{}'})).status,401);
  assert.equal((await post('other-token',{job_id:id,user_id:user})).status,403);
  assert.equal((await post('self-token',{mode:'drain'})).status,403);
  assert.equal((await post('self-token',{job_id:'attacker',user_id:'someone-else',manifest:[]})).status,202);
  await waitFor('failed');assert.equal(authExists,true);assert.equal(fileExists,false);assert.equal(authCalls,1);
  failAuth=false;assert.equal((await post(secret,{mode:'drain'})).status,202);
  await waitFor('completed');assert.equal(authCalls,2);assert.equal(authExists,false);
  assert.equal((await post('self-token',{})).status,200);assert.equal(authCalls,2);
  console.log('Account deletion Edge HTTP passed: actual SDK Storage and hard Auth DELETE, isolation, failure/retry and completed replay; local mock services only.');
} finally {child.kill();await exited;mock.closeAllConnections();await new Promise(resolve=>mock.close(resolve));}
