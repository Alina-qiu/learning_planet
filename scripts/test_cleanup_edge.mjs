import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { resolve } from 'node:path';
assert.ok(Number(process.versions.node.split('.')[0])>=22,'Edge HTTP smoke requires Node22+');
const id='10000000-0000-0000-0000-000000000001',draft='20000000-0000-0000-0000-000000000001';
const path=`${id}/${draft}/original.jpg`,secret='local-test-only-service-key';
let exists=true,status='queued',removes=0,checks=0,failRemove=true;
const mock=createServer(async(request,response)=>{
  const buffers=[]; for await(const value of request) buffers.push(value);
  const text=Buffer.concat(buffers).toString();
  const route=new URL(request.url,'http://127.0.0.1').pathname;
  const authorization=request.headers.authorization;
  const reply=(code,body)=>{ response.writeHead(code,{'Content-Type':'application/json'}); response.end(JSON.stringify(body)); };
  if(route==='/auth/v1/user') return authorization==='Bearer parent-token' || authorization==='Bearer child-token'
    ? reply(200,{id,email:'local@example.test',app_metadata:{},user_metadata:{},aud:'authenticated',created_at:'2026-01-01T00:00:00Z'}) : reply(401,{message:'local auth denied'});
  if(route==='/rest/v1/rpc/claim_cleanup_job') {
    if(!['Bearer parent-token',`Bearer ${secret}`].includes(authorization)) return reply(403,{code:'42501',message:'local PIN denied'});
    if(status==='completed') return reply(200,{id,status});
    status='running';return reply(200,{id,status:'claimed',lease_token:draft,manifest:[{bucket:'wrong-question-images',path}]});
  }
  if(route==='/rest/v1/rpc/finish_cleanup_job') {
    assert.equal(authorization,`Bearer ${secret}`);
    const result=JSON.parse(text);
    if(result.failure_code) { status='failed';return reply(200,null); }
    assert.equal(exists,false);status='completed';return reply(200,null);
  }
  if(route==='/storage/v1/object/wrong-question-images' && request.method==='DELETE') {
    removes++;assert.equal(authorization,`Bearer ${secret}`);assert.deepEqual(JSON.parse(text).prefixes,[path]);
    if(failRemove) return reply(503,{statusCode:'503',error:'Unavailable',message:'local provider unavailable'});
    exists=false;return reply(200,[{name:path}]);
  }
  if(route===`/storage/v1/object/wrong-question-images/${path}` && request.method==='HEAD') {
    checks++;response.writeHead(exists?200:404,{'Content-Type':'application/json'});return response.end();
  }
  if(route==='/rest/v1/rpc/enqueue_expired_worksheets') return reply(200,0);
  if(route==='/rest/v1/rpc/pending_cleanup_jobs') return reply(200,status==='completed'?[]:[id]);
  reply(404,{message:'unexpected route '+route});
});
await new Promise(resolve=>mock.listen(0,'127.0.0.1',resolve));const mockPort=mock.address().port;
const reserve=createServer();await new Promise(resolve=>reserve.listen(0,'127.0.0.1',resolve));
const edgePort=reserve.address().port;await new Promise(resolve=>reserve.close(resolve));
const binary=process.platform==='win32'?resolve('node_modules/deno/deno.exe'):resolve('node_modules/.bin/deno');
const child=spawn(binary,['run','--cached-only','--config','supabase/functions/worksheet-render/deno.json',
  '--allow-env=SUPABASE_URL,SUPABASE_ANON_KEY,SUPABASE_SERVICE_ROLE_KEY,TEST_EDGE_PORT,TEST_EDGE_KIND',
  `--allow-net=127.0.0.1:${mockPort},127.0.0.1:${edgePort}`,`--allow-read=${resolve('supabase/functions')}`,
  'scripts/fixtures/edge_bootstrap.mjs'],{windowsHide:true,env:{...process.env,SUPABASE_URL:`http://127.0.0.1:${mockPort}`,
    SUPABASE_ANON_KEY:'local-test-only-anon-key',SUPABASE_SERVICE_ROLE_KEY:secret,TEST_EDGE_PORT:String(edgePort),TEST_EDGE_KIND:'cleanup'},stdio:['ignore','pipe','pipe']});
let logs='';child.stdout.on('data',value=>logs+=value);child.stderr.on('data',value=>logs+=value);
const exited=once(child,'exit'),endpoint=`http://127.0.0.1:${edgePort}`;
async function waitFor(expected) {
  for(let i=0;i<100;i++) {
    if(child.exitCode!==null) throw new Error('Local Edge stopped: '+logs);
    if(status===expected) return;
    await new Promise(resolve=>setTimeout(resolve,100));
  }
  throw new Error('Local state did not reach '+expected+': '+status+' '+logs);
}
try {
  let ready=false;
  for(let i=0;i<100 && !ready;i++) {
    if(child.exitCode!==null) throw new Error(logs);
    try {assert.equal((await fetch(endpoint,{method:'OPTIONS'})).status,204);ready=true;}
    catch{await new Promise(resolve=>setTimeout(resolve,100));}
  }
  assert.equal(ready,true);
  assert.equal((await fetch(endpoint,{method:'POST',body:'{}'})).status,401);
  assert.equal((await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer child-token'},body:JSON.stringify({job_id:id})})).status,403);
  assert.equal((await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer parent-token'},body:JSON.stringify({mode:'drain'})})).status,403);
  assert.equal((await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer parent-token'},body:JSON.stringify({job_id:id,manifest:[{path:'untrusted'}]})})).status,202);
  await waitFor('failed');assert.equal(exists,true);assert.equal(checks,0);
  failRemove=false;
  assert.equal((await fetch(endpoint,{method:'POST',headers:{Authorization:`Bearer ${secret}`},body:JSON.stringify({mode:'drain'})})).status,202);
  await waitFor('completed');assert.equal(removes,2);assert.equal(checks,1);
  const replay=await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer parent-token'},body:JSON.stringify({job_id:id})});
  assert.equal(replay.status,200);assert.equal((await replay.json()).status,'completed');assert.equal(removes,2);
  console.log('Cleanup Edge HTTP smoke passed: actual SDK DELETE, expected404 verification, failed retry, trusted drain and replay. Only local mocked Storage/Auth/RPC were accessed.');
} finally {child.kill();await exited;mock.closeAllConnections();await new Promise(resolve=>mock.close(resolve));}
