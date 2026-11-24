import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtemp, readFile, readdir, rm, writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';
import {androidEvidence, androidSessionMatches, fixtureOperation} from './test_cross_device_sync.mjs';
import {closeServer, listen, signedJwt} from './fixtures/http_test_tools.mjs';

const scenario={task_id:'task',child_id:'child',family_id:'family',coins:7,xp:5};
const report={...scenario,device:'android',test:'AC-01',stage:'confirmed',ready_with_zero_wallet:true,completed:true};

test('native auth URL queries share the same fixture cooldown and counters', () => {
  for (const suffix of ['', '?', '?redirect_to=private_marker']) {
    assert.equal(fixtureOperation('POST','/auth/v1/otp'+suffix),'otp');
    assert.equal(fixtureOperation('POST','/auth/v1/verify'+suffix),'verify');
    assert.equal(fixtureOperation('POST','/rest/v1/rpc/task_sync_snapshot'+suffix),'snapshot');
  }
  assert.equal(fixtureOperation('GET','/auth/v1/verify?private_marker'),undefined);
  assert.equal(fixtureOperation('POST','/auth/v1/user?otp'),undefined);
});

async function fixture(t) {
  const dir=await mkdtemp(join(tmpdir(),'android-report-'));
  const file=join(dir,'report.json');
  const state={phase:'reader-ready',dbValid:true,checks:0,logs:[]};
  const receiver=androidEvidence({scenario,file,phase:()=>state.phase,
    authorize:async bearer=>bearer==='Bearer fixture-session',
    verify:async ()=>{state.checks++;assert.ok(state.dbValid);},
    log:line=>state.logs.push(line)});
  const server=createServer((req,res)=>{
    const url=new URL(req.url,'http://localhost');
    receiver.receive(url.pathname,url.searchParams.get('device'),req,res)
      .catch(()=>res.writeHead(500).end());
  });
  await listen(server);
  t.after(async()=>{await closeServer(server);await rm(dir,{recursive:true,force:true});});
  async function post(path,body,{device='android',bearer='Bearer fixture-session',type='application/json'}={}) {
    const res=await fetch(`http://127.0.0.1:${server.address().port}${path}?device=${device}`,{
      method:'POST',headers:{'Content-Type':type,Authorization:bearer},
      body:typeof body==='string' ? body : JSON.stringify(body),
    });
    await res.arrayBuffer();
    return res.status;
  }
  return {post,state,receiver,file,dir};
}

test('wrong phase, device, body, session or database state cannot publish evidence',async t=>{
  const {post,state,dir,receiver}=await fixture(t);
  assert.equal(await post('/report',report),409);
  state.phase='writer-complete';
  assert.equal(await post('/report',report,{device:'ios'}),403);
  for (const invalid of [{...report,xp:'5'}, {...report,extra:true}, {...report,device:'ios'},
    {...report,ready_with_zero_wallet:false}, {...report,family_id:'other'}, [], null, '{']) {
    assert.equal(await post('/report',invalid),400);
  }
  assert.equal(await post('/report','x'.repeat(2200)),413);
  assert.equal(await post('/report',report,{type:'text/plain'}),415);
  assert.equal(await post('/report',report,{bearer:'Bearer other'}),403);
  assert.equal(state.checks,0);
  state.dbValid=false;
  assert.equal(await post('/report',report),500);
  assert.deepEqual(await readdir(dir),[]);
  assert.equal(receiver.saved,false);
});

test('only a complete verified report is published atomically; concurrent repeats are idempotent',async t=>{
  const {post,state,dir,file,receiver}=await fixture(t);
  state.phase='writer-complete';
  assert.deepEqual(await Promise.all([post('/report',report),post('/report',report)]),[200,200]);
  assert.equal(await readFile(file,'utf8'),JSON.stringify(report,null,2)+'\n');
  assert.deepEqual(await readdir(dir),['report.json']);
  assert.equal(state.checks,2);
  assert.equal(receiver.saved,true);
  assert.equal(await post('/report',{...report,coins:8}),400);
  assert.equal(await post('/progress',{stage:'failed'}),200);
  assert.equal(receiver.stage,'confirmed');
  assert.deepEqual(state.logs,['CROSS_DEVICE_ANDROID_STAGE confirmed']);
  state.phase='reader-reconnect';
  assert.equal(await post('/report',report),409);
  assert.deepEqual(JSON.parse(await readFile(file,'utf8')),report);
});

test('Android progress is bounded, monotonic, and a terminal test failure cannot become a pass',async t=>{
  const {post,state,dir,receiver}=await fixture(t);
  assert.equal(receiver.stage,null);
  assert.equal(await post('/progress',{stage:'unexpected',text:'no logging'}),400);
  assert.equal(await post('/progress',{stage:'unexpected'}),400);
  const checkpoints=['fixture','email_login','login_form_visible','otp_send_tapped','otp_received','otp_form_ready','otp_verify_tapped'];
  for (const stage of [...checkpoints,'fixture','email_login','confirmed','failed','failed','complete_task']) {
    assert.equal(await post('/progress',{stage}),200);
  }
  assert.deepEqual(state.logs,[...checkpoints,'failed'].map(s=>'CROSS_DEVICE_ANDROID_STAGE '+s));
  assert.equal(receiver.checkpoint,'otp_verify_tapped');
  assert.equal(receiver.stage,'failed');
  state.phase='writer-complete';
  assert.equal(await post('/report',report),409);
  assert.deepEqual(await readdir(dir),[]);
});

test('Android bearer check requires a GoTrue-accepted token from the same observed session and owner',async ()=>{
  const owner='owner', android='android-session';
  const token=(session,subject=owner,nonce=1)=>signedJwt('local-test-only',{sub:subject,session_id:session,nonce});
  const first=token(android), renewed=token(android,owner,2);
  let calls=0;
  const client={api:async(path,bearer)=>{
    assert.equal(path,'/auth/v1/user');calls++;
    return bearer===first || bearer===renewed ? {status:200,data:{id:owner}} : {status:401};
  }};
  for (const bearer of ['', 'Bearer bad', 'Bearer '+token('ios-session'), 'Bearer '+token(android,'other')]) {
    assert.equal(await androidSessionMatches(bearer,android,owner,client),false);
  }
  assert.equal(calls,0);
  assert.equal(await androidSessionMatches('Bearer '+first,undefined,owner,client),false);
  assert.equal(await androidSessionMatches('Bearer '+first.replace(/\.[^.]+$/,'.invalid'),android,owner,client),false);
  assert.equal(await androidSessionMatches('Bearer '+first,android,owner,client),true);
  assert.equal(await androidSessionMatches('Bearer '+renewed,android,owner,client),true);
  assert.equal(calls,3);
});

test('starting a fixture removes its previous Android report even if the backend never becomes ready',async t=>{
  const dir=await mkdtemp(join(tmpdir(),'old-device-report-'));
  t.after(()=>rm(dir,{recursive:true,force:true}));
  const file=join(dir,'android.json');
  await writeFile(file,JSON.stringify(report));
  const run=spawnSync(process.execPath,['scripts/test_cross_device_sync.mjs'],{
    cwd:fileURLToPath(new URL('../',import.meta.url)),timeout:15000,windowsHide:true,
    env:{...process.env,CROSS_DEVICE_RESULTS_DIR:dir,ANDROID_REPORT_PATH:file,GOTRUE_BIN:join(dir,'missing-auth')},
  });
  assert.equal(run.error,undefined);
  assert.equal(run.status,1);
  assert.equal(JSON.parse(await readFile(join(dir,'server.json'),'utf8')).passed,false);
  await assert.rejects(readFile(file),{code:'ENOENT'});
});
