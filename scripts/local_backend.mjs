// Real loopback services for local app debugging.
import assert from 'node:assert/strict';
import {randomBytes, randomUUID} from 'node:crypto';
import {createServer} from 'node:http';
import {realpathSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {withAuthBackend} from './fixtures/auth_backend.mjs';
import {openLocalTrial} from './fixtures/local_trial.mjs';
import {createStorageBackend} from './fixtures/storage_backend.mjs';
import {startLocalEdge} from './fixtures/local_edge.mjs';
import {closeServer, forwardHttp, listen, signedJwt} from './fixtures/http_test_tools.mjs';

const directory=resolve('.dart_tool/local-backend'), controlPath=join(directory,'control.json');
const origin='http://127.0.0.1:54321';
const command=process.argv[2] ?? 'start';
const respond=(response,status,body)=>{
  response.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});
  response.end(JSON.stringify(body));
};

async function start(keepData) {
  let finish, ready=false, config, backendPort, timer, lifetime, maintenance;
  const done=new Promise(resolve=>{finish=resolve;});
  const runId=randomUUID(), shutdownKey=randomBytes(32).toString('hex'), edges=new Map();
  const gateway=createServer((request,response)=>{
    const path=new URL(request.url,origin).pathname;
    if(path==='/__local/health') {respond(response,ready?200:503,{ready,runId,temporary:!keepData});return;}
    if(path==='/__local/stop') {
      if(request.method!=='POST' || request.headers.authorization!==`Bearer ${shutdownKey}`) {
        respond(response,403,{error:'Local control authorization required'});return;
      }
      respond(response,202,{stopping:true});finish();return;
    }
    if(!ready) {respond(response,503,{error:'Local services are starting'});return;}
    const edge=edges.get(path);
    if(edge) {forwardHttp(request,response,edge.port,'/functions/v1');return;}
    if(['/auth/v1/','/rest/v1/','/storage/v1/'].some(prefix=>path.startsWith(prefix))) {
      forwardHttp(request,response,backendPort,'');return;
    }
    respond(response,404,{error:'This service is not configured in local debugging'});
  });
  // Reserve the known port before creating services or replacing a running session's configuration.
  await listen(gateway,54321);
  const stop=()=>finish();
  process.once('SIGINT',stop);process.once('SIGTERM',stop);
  try {
    await mkdir(directory,{recursive:true});
    const trial = await openLocalTrial(resolve('.learning-planet-trial'), directory, keepData);
    await withAuthBackend(async (publicConfig,{database,secret})=>{
      config=publicConfig;backendPort=Number(new URL(config.url).port);
      await database.client.query('grant service_role to http_authenticator');
      const service=signedJwt(secret,{role:'service_role',exp:Math.floor(Date.now()/1000)+86400});
      for(const [path,kind] of [['worksheet-render','worksheet'],['permanent-cleanup','cleanup'],['account-deletion','account']]) {
        edges.set(`/functions/v1/${path}`,await startLocalEdge(kind,{url:config.url,anon:config.anon,service}));
      }
      async function maintain() {
        for(const name of ['run_task_maintenance','run_review_maintenance','run_reward_maintenance','run_child_export_maintenance']) {
          await database.client.query(`select public.${name}()`);
        }
        for(const edge of edges.values()) {
          const result=await edge.post(service,{mode:'drain'});
          assert.equal(result.status,202,'Local worker dispatch failed');
        }
      }
      await maintain();
      await mkdir(directory,{recursive:true});
      await writeFile(join(directory,'defines.json'),JSON.stringify({APP_ENV:'development',LOCAL_BACKEND:true,
        SUPABASE_URL:origin,SUPABASE_ANON_KEY:config.anon},null,2)+'\n',{mode:0o600});
      await writeFile(controlPath,JSON.stringify({runId,url:origin,mailUrl:config.url,mailboxKey:config.mailboxKey,shutdownKey},null,2)+'\n',{mode:0o600});
      await trial.markReady?.();
      ready=true;
      timer=setInterval(()=>{
        if(maintenance)return;
        maintenance=maintain().catch(error=>console.error('Local maintenance failed:',error.code??error.name))
          .finally(()=>{maintenance=null;});
      },60000);
      lifetime=setTimeout(()=>{console.log('Local session reached its 24-hour lifetime.');finish();},86400000);
      console.log(`LOCAL_BACKEND_READY ${origin}`);
      console.log(keepData
        ? 'Persistent local trial: use synthetic @example.test accounts. Restart with --keep-data to reopen the same family and files.'
        : 'Temporary empty database: use synthetic @example.test accounts only. Restarting starts a new database.');
      console.log('Public build configuration: .dart_tool/local-backend/defines.json');
      const cli = localControlInvocation();
      console.log(`Read OTP: ${cli} mail parent@example.test`);
      console.log(`Stop cleanly: ${cli} stop`);
      try {await done;} finally {
        ready=false;clearInterval(timer);clearTimeout(lifetime);await maintenance;
        for(const edge of edges.values())await edge.stop();edges.clear();
      }
    }, {
      createStorage: args => createStorageBackend({...args, minimumObjects: 0,
        persistentDirectory: trial.storage, requireExisting: trial.requireExisting}),
      persistentDirectory: trial.database, requireExisting: trial.requireExisting,
      verifyTraffic: false, localCredentials: trial.credentials,
    });
  } finally {
    ready=false;clearInterval(timer);clearTimeout(lifetime);
    for(const edge of edges.values())await edge.stop();
    await closeServer(gateway);
    process.removeListener('SIGINT',stop);process.removeListener('SIGTERM',stop);
  }
}

// The runtime selected by the launcher may differ from the shell's default Node.
export function localControlInvocation(binary = process.execPath, platform = process.platform) {
  const quoted = platform === 'win32'
    ? "& '" + binary.replaceAll("'", "''") + "'"
    : "'" + binary.replaceAll("'", "'\\''") + "'";
  return `${quoted} scripts/local_backend.mjs`;
}

async function localHealth(origin, timeoutMs) {
  const response = await fetch(`${origin}/__local/health`, {signal: AbortSignal.timeout(timeoutMs)});
  const status = await response.json();
  assert.equal(typeof status.runId, 'string', 'Unrecognized local service');
  return status;
}

export async function stopLocalSession(origin, saved, {timeoutMs = 60000} = {}) {
  try {
    const status = await localHealth(origin, 3000);
    assert.equal(status.runId, saved.runId, 'Local control belongs to a different session');
    const response = await fetch(`${origin}/__local/stop`, {
      method: 'POST', headers: {Authorization: `Bearer ${saved.shutdownKey}`}, signal: AbortSignal.timeout(3000),
    });
    await response.arrayBuffer();
    assert.equal(response.status, 202, 'Local shutdown request was refused');
  } catch (error) {
    if (error.cause?.code === 'ECONNREFUSED') return;
    throw error;
  }

  // The public listener closes last, after Storage, Auth, the workers and PostgreSQL.
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    const remaining = Math.max(1, Math.ceil(deadline - performance.now()));
    try {
      const status = await localHealth(origin, Math.min(remaining, 1000));
      if (status.runId !== saved.runId) return;
    } catch (error) {
      if (error.cause?.code === 'ECONNREFUSED') return;
      // The final HTTP probe can be interrupted as the listener closes.
      if (!['UND_ERR_SOCKET', 'ECONNRESET'].includes(error.cause?.code) && error.name !== 'TimeoutError') throw error;
    }
    await delay(Math.min(150, Math.max(0, deadline - performance.now())));
  }
  throw new Error('Local shutdown is still in progress. Check the service terminal and run stop again.');
}

async function control() {
  const saved=JSON.parse(await readFile(controlPath,'utf8'));
  assert.equal(saved.url,origin,'Only this local origin is supported');
  if(command==='stop') {
    await stopLocalSession(origin, saved);
    console.log('Local services stopped.');return;
  }
  const status=await localHealth(origin, 3000);
  assert.equal(status.runId,saved.runId,'Local control belongs to a different session');
  assert.equal(status.ready,true,'Local session is not ready');
  if(command==='status') {
    console.log(status.temporary === false
      ? 'Local services ready; persistent trial data; loopback only.'
      : 'Local services ready; temporary database; loopback only.');
    return;
  }
  const email=(process.argv[3]??'').trim().toLowerCase();
  assert.match(email,/^[a-z0-9._+-]+@example\.test$/,'Use a synthetic @example.test address');
  const mailOrigin=new URL(saved.mailUrl);
  assert.equal(mailOrigin.protocol,'http:');assert.equal(mailOrigin.hostname,'127.0.0.1');
  const mail=await fetch(`${saved.mailUrl}/__test/mail?email=${encodeURIComponent(email)}`,
    {headers:{'x-test-mailbox-key':saved.mailboxKey},signal:AbortSignal.timeout(3000)});
  if(mail.status===404) {console.log('No local message for this account yet.');return;}
  assert.equal(mail.status,200);const message=await mail.json();assert.match(message.code,/^\d{8}$/);
  console.log(`Local OTP for ${email}: ${message.code}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  if (command === 'start') {
    const options = process.argv.slice(3);
    if (options.length > 1 || (options.length === 1 && options[0] !== '--keep-data')) {
      throw new Error('Usage: local_backend.mjs start [--keep-data]');
    }
    await start(options.length === 1);
  } else if (['mail','status','stop'].includes(command)) {
    await control();
  } else {
    throw new Error('Usage: local_backend.mjs start [--keep-data] | status | stop | mail <email>');
  }
}
