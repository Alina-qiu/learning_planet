import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {resolve} from 'node:path';
import {randomUUID} from 'node:crypto';
import {weeklyInput,weeklyValue} from './fixtures/weekly_report.mjs';
const user=randomUUID(),childId=randomUUID(),session=randomUUID(),service='local-ai-service';
const token=`header.${Buffer.from(JSON.stringify({sub:user,session_id:session})).toString('base64url')}.signature`;
let providerCalls=0, claimCalls=0, denied=false, finished, sent, status='unknown', requestId, similar=false, weekly=false;
const mock=createServer(async(req,res)=>{
  const chunks=[];for await(const v of req)chunks.push(v);
  const text=Buffer.concat(chunks).toString(); const body=text?JSON.parse(text):{};
  const path=new URL(req.url,'http://localhost').pathname;
  const reply=(code,value)=>{res.writeHead(code,{'Content-Type':'application/json'});res.end(JSON.stringify(value));};
  if(path==='/auth/v1/user') return req.headers.authorization===`Bearer ${token}`
    ?reply(200,{id:user,aud:'authenticated',app_metadata:{},user_metadata:{},created_at:'2026-01-01T00:00:00Z'}) :reply(401,{});
  if(path==='/rest/v1/rpc/claim_ai_analysis') {
    assert.equal(req.headers.authorization,`Bearer ${service}`); claimCalls++;
    assert.equal(body.caller_id,user);assert.equal(body.caller_session,session); assert.equal(body.target_child_id,childId);
    if(denied)return reply(403,{message:'AI_DISABLED: private backend detail',code:'42501'});
    requestId=body.request_id;
    similar=body.input.kind==='similar';weekly=body.input.kind==='weekly_report';
    if(status!=='unknown')return reply(200,{request_id:requestId,child_id:childId,status});
    status='running';return reply(200,{request_id:requestId,child_id:childId,status:'claimed',token:'private-claim',model:'test-model',provider:'openai',grade:3,prompt_version:weekly?'weekly-report-v1':similar?'similar-question-v1':'question-structure-v1'});
  }
  if(path==='/provider') {
    providerCalls++;sent=body;assert.equal(req.headers.authorization,'Bearer local-ai-key');
    const value=weekly?weeklyValue:similar?{prompt:'3+4=?',answers:['7'],explanation:'3与4相加等于7',knowledge_point:'加法',difficulty:'easy',confidence:.8,safety_flags:[]}:{knowledge_points:['加法'],difficulty:'easy',error_reasons:['unknown'],confidence:.8,safety_flags:[]};
    return reply(200,{status:'completed',output:[{type:'message',content:[{type:'output_text',text:JSON.stringify(value)}]}]});
  }
  if(path==='/rest/v1/rpc/finish_ai_analysis') {
    assert.equal(req.headers.authorization,`Bearer ${service}`); assert.equal(body.token,'private-claim'); finished=body.output;status='completed';return reply(200,null);
  }
  return reply(404,{});
});
await new Promise(r=>mock.listen(0,'127.0.0.1',r));const port=mock.address().port;
const reserve=createServer();await new Promise(r=>reserve.listen(0,'127.0.0.1',r));const edgePort=reserve.address().port;await new Promise(r=>reserve.close(r));
const executable=process.platform==='win32'?resolve('node_modules/deno/deno.exe'):resolve('node_modules/.bin/deno');
const child=spawn(executable,['run','--cached-only','--config','supabase/functions/worksheet-render/deno.json',
  '--allow-env=SUPABASE_URL,SUPABASE_ANON_KEY,SUPABASE_SERVICE_ROLE_KEY,TEST_EDGE_PORT,TEST_EDGE_KIND,OPENAI_API_KEY',
  `--allow-net=127.0.0.1:${port},127.0.0.1:${edgePort}`,`--allow-read=${resolve('supabase/functions')}`,'scripts/fixtures/edge_bootstrap.mjs'],
  {windowsHide:true,env:{...process.env,SUPABASE_URL:`http://127.0.0.1:${port}`,SUPABASE_ANON_KEY:'local-anon',SUPABASE_SERVICE_ROLE_KEY:service,
    TEST_EDGE_KIND:'ai',TEST_EDGE_PORT:String(edgePort),OPENAI_API_KEY:'local-ai-key'},stdio:['ignore','pipe','pipe']});
let logs='';child.stdout.on('data',v=>logs+=v);child.stderr.on('data',v=>logs+=v);const exited=once(child,'exit');
const url=`http://127.0.0.1:${edgePort}`;
const submit=(body,auth=token)=>fetch(url,{method:'POST',headers:auth?{Authorization:`Bearer ${auth}`}:{},body:JSON.stringify(body)});
const body={request_id:randomUUID(),child_id:childId,consent:true,generation:0,input:{subject:'math',text:'1 + 2 = ?'}};
try {
  let ready=false;
  for(let i=0;i<100;i++){if(child.exitCode!==null)throw new Error(logs);try{ready=(await fetch(url,{method:'OPTIONS'})).status===204;break;}catch{await new Promise(r=>setTimeout(r,100));}}
  assert.ok(ready,logs);
  assert.equal((await submit(body,null)).status,401);assert.equal((await submit(body,'invalid')).status,401);
  assert.equal((await submit({...body,consent:false})).status,400);
  assert.equal((await submit({...body,input:{...body.input,nickname:'private'}})).status,400);
  assert.equal(claimCalls,0);
  denied=true;const unavailable=await submit(body);assert.equal(unavailable.status,403);assert.deepEqual(await unavailable.json(),{error:'AI_DISABLED'});denied=false;
  const accepted=await submit(body);assert.equal(accepted.status,202);assert.deepEqual(await accepted.json(),{request_id:body.request_id,child_id:childId,status:'running'});
  for(let i=0;i<100&&!finished;i++)await new Promise(r=>setTimeout(r,30));
  assert.equal(finished.model_version,'test-model');assert.deepEqual(JSON.parse(sent.input),{grade:3,...body.input});assert.equal(sent.store,false);
  const replay=await submit(body);assert.equal(replay.status,200);assert.equal((await replay.json()).status,'completed');assert.equal(providerCalls,1);
  assert.equal(logs.includes('1 + 2'),false);assert.equal(logs.includes('local-ai-key'),false);
  status='unknown';finished=null;
  const generated={...body,request_id:randomUUID(),input:{...body.input,kind:'similar',source_question_id:randomUUID(),source_version:0,knowledge_point:'加法',difficulty:'easy'}};
  assert.equal((await submit(generated)).status,202);
  for(let i=0;i<100&&!finished;i++)await new Promise(r=>setTimeout(r,30));
  assert.equal(finished.prompt_version,'similar-question-v1');assert.deepEqual(finished.structured_output.answers,['7']);
  assert.equal(JSON.stringify(sent).includes(generated.input.source_question_id),false);
  assert.deepEqual(Object.keys(JSON.parse(sent.input)).sort(),['difficulty','grade','knowledge_point','subject','text']);
  assert.equal((await submit(generated)).status,200);assert.equal(providerCalls,2);
  status='unknown';finished=null;
  const report={...body,request_id:randomUUID(),input:weeklyInput};
  assert.equal((await submit(report)).status,202);
  for(let i=0;i<100&&!finished;i++)await new Promise(r=>setTimeout(r,30));
  assert.equal(finished.prompt_version,'weekly-report-v1');assert.deepEqual(JSON.parse(sent.input),weeklyInput.snapshot);
  assert.equal(JSON.stringify(sent).includes(childId),false);assert.equal((await submit(report)).status,200);assert.equal(providerCalls,3);
  console.log('AI Edge HTTP checks passed: real Deno entrypoint, verified session, consent/input checks, redacted errors, asynchronous completion and replay without another provider call. All HTTP is local mock.');
} finally {child.kill();await exited;mock.closeAllConnections?.();await new Promise(r=>mock.close(r));}
