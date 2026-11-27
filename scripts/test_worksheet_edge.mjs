import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { once } from 'node:events';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { snapshot } from './fixtures/worksheet_snapshot.mjs';
assert.ok(Number(process.versions.node.split('.')[0]) >= 22,'Edge HTTP smoke requires Node22+ (the CI version), not legacy Node16');

const family = '20000000-0000-0000-0000-000000000001';
const path = `${family}/${snapshot.id}/worksheet.pdf`;
const service = 'local-test-only-service-key';
let uploaded, result, status='queued', claims=0, finishCalls=0;
const progress=[];
const mock = createServer(async (request,response) => {
  const buffers=[]; for await (const data of request) buffers.push(data);
  const body=Buffer.concat(buffers);
  const route=new URL(request.url,'http://127.0.0.1').pathname;
  const authorized=request.headers.authorization;
  const reply=(code,value) => { response.writeHead(code,{'Content-Type':'application/json'}); response.end(JSON.stringify(value)); };
  if(route==='/auth/v1/user') {
    return authorized==='Bearer parent-token' || authorized==='Bearer child-token'
      ? reply(200,{id:family,email:'local@example.test',app_metadata:{},user_metadata:{},aud:'authenticated',created_at:'2026-01-01T00:00:00Z'})
      : reply(401,{message:'local authentication denied'});
  }
  if(route==='/rest/v1/rpc/claim_worksheet') {
    claims++;
    if(authorized!=='Bearer parent-token' && authorized!==`Bearer ${service}`) return reply(403,{code:'42501',message:'local PIN denied'});
    if(status==='ready') return reply(200,{id:snapshot.id,status:'ready'});
    status='running';
    return reply(200,{id:snapshot.id,status:'claimed',lease_token:family,pdf_path:path,snapshot});
  }
  if(route==='/rest/v1/rpc/pending_worksheet_jobs') {
    assert.equal(authorized,`Bearer ${service}`);
    return reply(200,status==='queued'?[snapshot.id]:[]);
  }
  if(route==='/rest/v1/rpc/update_worksheet_progress') {
    assert.equal(authorized,`Bearer ${service}`); progress.push(JSON.parse(body).percentage); return reply(200,null);
  }
  if(route==='/rest/v1/rpc/finish_worksheet') {
    assert.equal(authorized,`Bearer ${service}`); finishCalls++;
    result=JSON.parse(body).result;
    if(result.error_code) { status='failed'; return reply(200,null); }
    status='ready';
    // Actual SDK error after the server committed, not a mocked adapter throw.
    return reply(503,{code:'ACK_LOST',message:'local acknowledgement lost'});
  }
  if(route==='/rest/v1/worksheet_jobs') return reply(200,[{status,sha256:result?.sha256}]);
  if(route===`/storage/v1/object/worksheets/${path}` && request.method==='POST') {
    assert.equal(authorized,`Bearer ${service}`);
    uploaded=body; return reply(200,{Id:family,Key:`worksheets/${path}`});
  }
  reply(404,{message:'unexpected local route '+route});
});
await new Promise(resolve => mock.listen(0,'127.0.0.1',resolve));
const mockPort=mock.address().port;
const reserve=createServer(); await new Promise(resolve => reserve.listen(0,'127.0.0.1',resolve));
const edgePort=reserve.address().port; await new Promise(resolve => reserve.close(resolve));
const binary=process.platform==='win32' ? resolve('node_modules/deno/deno.exe') : resolve('node_modules/.bin/deno');
const child=spawn(binary,['run','--cached-only','--config','supabase/functions/worksheet-render/deno.json',
  '--allow-env=SUPABASE_URL,SUPABASE_ANON_KEY,SUPABASE_SERVICE_ROLE_KEY,TEST_EDGE_PORT,TEST_EDGE_KIND',
  `--allow-net=127.0.0.1:${mockPort},127.0.0.1:${edgePort}`,
  `--allow-read=${resolve('supabase/functions')}`,
  'scripts/fixtures/edge_bootstrap.mjs'],{windowsHide:true,env:{...process.env,SUPABASE_URL:`http://127.0.0.1:${mockPort}`,
    SUPABASE_ANON_KEY:'local-test-only-anon-key',SUPABASE_SERVICE_ROLE_KEY:service,TEST_EDGE_PORT:String(edgePort)},stdio:['ignore','pipe','pipe']});
let logs=''; child.stdout.on('data',value => logs+=value); child.stderr.on('data',value => logs+=value);
const exited=once(child,'exit');
const endpoint=`http://127.0.0.1:${edgePort}`;
async function ready() {
  for(let attempt=0;attempt<100;attempt++) {
    if(child.exitCode!==null) throw new Error('Local Edge stopped: '+logs);
    try { return await fetch(endpoint,{method:'OPTIONS'}); } catch { await new Promise(resolve=>setTimeout(resolve,100)); }
  }
  throw new Error('Local Edge readiness timed out: '+logs);
}
try {
  assert.equal((await ready()).status,204);
  assert.equal((await fetch(endpoint,{method:'POST',body:'{}'})).status,401);
  assert.equal((await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer invalid-token'},body:'{}'})).status,401);
  assert.equal((await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer child-token'},body:JSON.stringify({worksheet_id:snapshot.id})})).status,403);
  const accepted=await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer parent-token'},body:JSON.stringify({worksheet_id:snapshot.id})});
  assert.equal(accepted.status,202);
  for(let attempt=0;attempt<200 && status!=='ready' && status!=='failed';attempt++) await new Promise(resolve=>setTimeout(resolve,100));
  assert.equal(status,'ready',JSON.stringify(result)+' '+logs);
  assert.equal(result.pages,2); assert.equal(result.byte_size,uploaded.length);
  assert.equal(result.sha256,createHash('sha256').update(uploaded).digest('hex'));
  assert.deepEqual(progress,[15,75,90]); assert.equal(finishCalls,1,'lost acknowledgement must not mark a committed file failed');
  assert.deepEqual(uploaded,await readFile('tmp/pdfs/worksheet-mixed.pdf'),'Deno and Node must generate identical pinned snapshot bytes');
  const replay=await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer parent-token'},body:JSON.stringify({worksheet_id:snapshot.id})});
  assert.equal(replay.status,200); assert.equal((await replay.json()).status,'ready'); assert.equal(finishCalls,1);
  assert.equal((await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer parent-token'},body:JSON.stringify({mode:'drain'})})).status,403);
  status='queued'; progress.length=0;
  const drained=await fetch(endpoint,{method:'POST',headers:{Authorization:`Bearer ${service}`},body:JSON.stringify({mode:'drain',worksheet_id:'untrusted-id'})});
  assert.equal(drained.status,202);
  for(let attempt=0;attempt<200 && status!=='ready' && status!=='failed';attempt++) await new Promise(resolve=>setTimeout(resolve,100));
  assert.equal(status,'ready',logs); assert.equal(finishCalls,2); assert.deepEqual(progress,[15,75,90]);
  assert.deepEqual(uploaded,await readFile('tmp/pdfs/worksheet-mixed.pdf'));
  const empty=await fetch(endpoint,{method:'POST',headers:{Authorization:`Bearer ${service}`},body:JSON.stringify({mode:'drain'})});
  assert.equal(empty.status,202); assert.equal((await empty.json()).jobs,0);
  console.log(`Edge HTTP smoke passed: real Deno entrypoint, Auth/PIN denials, background202, ${uploaded.length} identical bytes, acknowledged replay. Supabase HTTP backend is local mock (${claims} claims).`);
} finally {
  child.kill(); await exited;
  mock.closeAllConnections?.(); await new Promise(resolve=>mock.close(resolve));
}
