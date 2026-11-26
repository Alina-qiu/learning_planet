// Both native apps share one disposable Auth/PostgREST database. The control
// port stays reachable when the reader's data port drops its connections.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createServer} from 'node:http';
import {link, mkdir, rm, writeFile} from 'node:fs/promises';
import {dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import {readingReward, seedPairedChildren, siblingState} from './fixtures/cross_device_children.mjs';
import {withAuthBackend} from './fixtures/auth_backend.mjs';
import {closeServer, forwardHttp, listen} from './fixtures/http_test_tools.mjs';
import {realApiClient} from './fixtures/real_api_client.mjs';

const directory = process.env.CROSS_DEVICE_RESULTS_DIR ?? 'build/cross-device';
const ports = {ios: 54325, android: 54326};
const publicKey = 'sb_publishable_cross_device_loopback_fixture';
const {coins,xp} = readingReward;
const phases = ['initial', 'reader-ready', 'writer-complete', 'reader-reconnect', 'reader-confirmed'];
const androidReportPath = process.env.ANDROID_REPORT_PATH ?? 'build/integration_results/cross_device_sync_android.json';
const androidStages = ['fixture','email_login','login_form_visible','otp_send_tapped','otp_received',
  'otp_form_ready','otp_verify_tapped','load_family_task_and_wallet','complete_task','confirm_task_and_wallet','confirmed'];
const countedRoutes = new Map([['/auth/v1/otp','otp'], ['/auth/v1/verify','verify'],
  ['/rest/v1/rpc/task_sync_snapshot','snapshot']]);

export function fixtureOperation(method, target) {
  // GoTrue's Dart client can append a query delimiter even with zero parameters.
  // The control clock and counters follow the route; query values stay private.
  return method === 'POST' ? countedRoutes.get(target.split('?', 1)[0]) : undefined;
}

// Return only the fixture status and expected code. Never forward a provider
// error body, an address, or an authorization header to the test report.
export async function fixtureMailboxReply(otpStatus, expectedCount, readMail) {
  if (otpStatus >= 400) return {status:otpStatus};
  try {
    const mail = await readMail();
    if (mail.status === 404) return {status:202};
    if (!mail.ok) return {status:mail.status};
    const item = await mail.json();
    if (item?.count !== expectedCount) return {status:202};
    return {status:200, code:item.code};
  } catch (error) {
    // A dropped connection to the loopback mailbox is safe to poll again.
    const transient = ['ECONNRESET','ECONNREFUSED','EHOSTUNREACH','EPIPE','ENETUNREACH','ETIMEDOUT',
      'EAI_AGAIN','UND_ERR_CONNECT_TIMEOUT','UND_ERR_HEADERS_TIMEOUT','UND_ERR_BODY_TIMEOUT','UND_ERR_SOCKET'];
    if (error?.name === 'TimeoutError' || transient.includes(error?.cause?.code)) {
      return {status:202,interrupted:true};
    }
    throw new Error('Invalid fixture mailbox response');
  }
}

function json(res, code, value) {
  res.writeHead(code, {'Content-Type':'application/json', 'Cache-Control':'no-store'});
  res.end(JSON.stringify(value));
}

export async function androidSessionMatches(authorization,session,ownerId,client) {
  const match = /^Bearer ([A-Za-z0-9_-]+\.([A-Za-z0-9_-]+)\.[A-Za-z0-9_-]+)$/.exec(authorization ?? '');
  if (!match || !session) return false;
  let claims;
  try { claims=JSON.parse(Buffer.from(match[2],'base64url')); } catch { return false; }
  if (claims?.session_id!==session || claims.sub!==ownerId) return false;
  // GoTrue verifies the signature and expiry. This also accepts a renewed
  // token from the same Android session after the snapshot was taken.
  const response=await client.api('/auth/v1/user',match[1]);
  return response.status===200 && response.data?.id===ownerId;
}

// Only the standalone test APK uses these loopback endpoints. Report fields
// must match the fixture, and the device must prove ownership of its session.
export function androidEvidence({scenario, file, phase, authorize, verify, saveFailure, log = console.log}) {
  const expected = {device:'android',test:'AC-01',stage:'confirmed',task_id:scenario.task_id,
    child_id:scenario.child_id,family_id:scenario.family_id,ready_with_zero_wallet:true,
    completed:true,coins:scenario.coins,xp:scenario.xp};
  let stage = null, checkpoint = null, saved = false, pending = Promise.resolve();

  function record(next) {
    if (next === stage) return;
    stage = next;
    if (next !== 'failed') checkpoint = next;
    log('CROSS_DEVICE_ANDROID_STAGE '+stage);
  }

  async function update(path, body, authorization) {
    if (!['reader-ready','writer-complete'].includes(phase())) return 409;
    if (!body || Array.isArray(body) || typeof body !== 'object') return 400;
    if (path === '/progress') {
      if (Object.keys(body).length !== 1 || !Object.hasOwn(body,'stage') ||
          (!androidStages.includes(body.stage) && body.stage !== 'failed')) return 400;
      if (saved || stage === 'failed' || body.stage === 'confirmed') return 200;
      if (body.stage === 'failed') {
        try {
          await saveFailure(checkpoint);
        } finally {
          record('failed');
        }
      } else if (androidStages.indexOf(body.stage) > androidStages.indexOf(stage)) {
        record(body.stage);
      }
      return 200;
    }
    if (phase() !== 'writer-complete' || stage === 'failed') return 409;
    if (Object.keys(body).length !== Object.keys(expected).length ||
        !Object.entries(expected).every(([key,value]) => Object.hasOwn(body,key) && body[key] === value)) return 400;
    if (!await authorize(authorization)) return 403;
    await verify();
    if (!saved) {
      await mkdir(dirname(file),{recursive:true});
      const temporary = file+'.'+randomUUID()+'.tmp';
      try {
        await writeFile(temporary,JSON.stringify(body,null,2)+'\n',{flag:'wx',mode:0o600});
        // A single link publishes the complete file and never overwrites an
        // existing result. The coordinator clears previous runs before startup.
        await link(temporary,file);
      } finally {
        await rm(temporary,{force:true});
      }
      saved = true;
      record('confirmed');
    }
    return 200;
  }

  return {
    get stage() { return stage; },
    get checkpoint() { return checkpoint; },
    get saved() { return saved; },
    async receive(path,device,req,res) {
      if (device !== 'android') { res.writeHead(403).end(); return; }
      if (req.method !== 'POST') { res.writeHead(405).end(); return; }
      if (req.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json') {
        res.writeHead(415).end(); return;
      }
      const chunks = [];
      let length = 0;
      for await (const chunk of req.iterator({destroyOnReturn:false})) {
        length += chunk.length;
        if (length > 2048) { res.writeHead(413).end(); req.resume(); return; }
        chunks.push(chunk);
      }
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { res.writeHead(400).end(); return; }
      const request = pending.then(() => update(path,body,req.headers.authorization));
      pending = request.catch(() => {});
      res.writeHead(await request).end();
    },
  };
}

async function run(config, {database}) {
  const client = realApiClient(config);
  const owner = await client.account();
  const family = await client.family(owner);
  const profiles = await seedPairedChildren(client,owner,family,database);
  const [{task_id:taskId,title},sibling] = profiles;
  const siblingInitial = await siblingState(database,sibling.child_id);
  assert.deepEqual(siblingInitial.ledger.map(row=>[row.asset_type,row.amount,row.source_type]),
    [['coin',sibling.coin_balance,'parent_adjustment'],['xp',sibling.xp,'parent_adjustment']]);
  assert.equal(siblingInitial.command_count,0);
  assert.equal(siblingInitial.frozen_balance,0);
  assert.ok(['ready','scheduled'].includes(siblingInitial.status));
  const select = async (sql, params) => (await database.client.query(sql,params)).rows;
  const scenario = {email:owner.email,title,coins,xp,task_id:taskId,child_id:family.child,
    family_id:family.id,child_profiles:profiles};
  const ledger = () => select('select id,asset_type,amount from public.ledger_entries where child_id=$1 and source_id=$2 order by asset_type',[family.child,taskId]);
  const receipts = () => select(`select request->>'kind' kind,outcome from public.task_command_receipts
    where task_id=$1 order by created_at`,[taskId]);
  const applied = [{kind:'start',outcome:'applied'},{kind:'complete',outcome:'applied'}];
  const state = async () => (await select(`select i.status,w.coin_balance,w.frozen_balance,w.xp
    from public.task_instances i join public.wallets w on w.child_id=i.child_id where i.id=$1`,[taskId]))[0];
  const initial = await state();
  assert.ok(['ready','scheduled'].includes(initial.status));
  assert.deepEqual([initial.coin_balance,initial.frozen_balance,initial.xp],[0,0,0]);
  assert.deepEqual(await ledger(),[]);

  let phase = phases[0], lastOtp = Date.now(), blocked = 0, blockedAfterWriter = 0, reconnectAt;
  let committedLedger, timer;
  const observations = [], sessions = {}, servers = [];
  const counts = () => ({otp:0, otpOk:0, otpStatus:0, verify:0, verifyOk:0, verifyStatus:0,
    snapshot:0, snapshotOk:0, snapshotStatus:0, mailboxReads:0, mailboxStatus:0, mailboxInterrupted:0});
  const deviceHttp = {android:counts(), ios:counts()};
  const phaseTimes = {};
  const mailboxCount = {ios:2,android:3}; // First message was used for setup.
  const {promise, resolve, reject} = Promise.withResolvers();
  const port = Number(new URL(config.url).port);
  const fail = error => reject(error);
  const interrupt = () => fail(new Error('Cross-device run interrupted'));
  async function verifiedWriterLedger() {
    assert.ok(sessions.android && sessions.ios && sessions.android!==sessions.ios);
    assert.ok(observations.some(o=>o.device==='android' && o.child===family.child && o.phase==='reader-ready'));
    assert.deepEqual(await state(),{status:'completed',coin_balance:coins,frozen_balance:0,xp});
    const rows = await ledger();
    assert.deepEqual(rows.map(r=>[r.asset_type,r.amount]),[['coin',coins],['xp',xp]]);
    assert.deepEqual(await receipts(),applied);
    return rows;
  }
  const android = androidEvidence({scenario, file:androidReportPath, phase:()=>phase,
    authorize:authorization=>androidSessionMatches(authorization,sessions.android,owner.id,client),
    verify:async ()=>assert.deepEqual(await verifiedWriterLedger(),committedLedger),
    saveFailure:async checkpoint=>{
      // Diagnose the stopped fixture from one committed database snapshot.
      const [taskState] = await select(`select i.status,
        (select count(*)::int from public.task_command_receipts r where r.task_id=i.id
          and r.request->>'kind'='start' and r.outcome='applied') as applied_starts,
        (select count(*)::int from public.task_command_receipts r where r.task_id=i.id
          and r.request->>'kind'='complete' and r.outcome='applied') as applied_completions,
        (select count(*)::int from public.ledger_entries l where l.child_id=i.child_id and l.source_id=i.id) as ledger_rows
        from public.task_instances i where i.id=$1`,[taskId]);
      await writeFile(directory+'/server.json',JSON.stringify({passed:false,status:'android_failed',checkpoint,taskState},null,2)+'\n');
    },
  });
  try {
    for (const device of ['ios','android']) {
      const service = createServer((req,res) => {
        // These local data endpoints cannot forward test-control or mailbox traffic.
        if (!(req.url.startsWith('/rest/v1/') || req.url.startsWith('/auth/v1/'))) {
          res.writeHead(404).end(); return;
        }
        const operation = fixtureOperation(req.method, req.url);
        if (operation) {
          const counters = deviceHttp[device];
          counters[operation]++;
          res.once('finish', () => {
            counters[operation+'Status']=res.statusCode;
            if (res.statusCode >= 200 && res.statusCode < 300) counters[operation+'Ok']++;
          });
        }
        if (device==='ios' && ['reader-ready','writer-complete'].includes(phase)) {
          blocked++;
          if (phase==='writer-complete') blockedAfterWriter++;
          req.socket.destroy();
          return;
        }
        if (req.headers.apikey!==publicKey) { res.writeHead(401).end(); return; }
        req.headers.apikey = config.anon;
        if (req.headers.authorization===`Bearer ${publicKey}`) req.headers.authorization=`Bearer ${config.anon}`;
        const snapshot = operation === 'snapshot', acceptedAt=Date.now(), atPhase=phase;
        // PostgREST validates the actual bearer. Retain only the session identifier
        // from successful snapshots to distinguish the two OTP logins.
        if (snapshot) {
          // Observe only the two fixture IDs. Sibling refreshes cannot satisfy the
          // primary child's post-reconnect timer or session checks.
          let target = null, input = '';
          req.on('data', chunk => {
            if (input.length <= 200) input += chunk.toString('utf8',0,201);
          });
          req.once('end', () => {
            if (input.length > 200) return;
            try {
              const id = JSON.parse(input).target_child_id;
              if (profiles.some(child=>child.child_id===id)) target=id;
            } catch { /* The real service validates the request. */ }
          });
          const payload = req.headers.authorization?.split('.')[1];
          res.once('finish',() => {
            if (res.statusCode!==200 || !payload || !target) return;
            try {
              const claims=JSON.parse(Buffer.from(payload,'base64url'));
              assert.equal(claims.sub,owner.id);
              assert.ok(claims.session_id);
              if (sessions[device]) assert.equal(claims.session_id,sessions[device]);
              sessions[device]=claims.session_id;
              observations.push({device,child:target,phase:atPhase,at:acceptedAt});
            } catch (err) { fail(err); }
          });
        }
        if (operation === 'otp') lastOtp=Date.now();
        forwardHttp(req,res,port,'');
      });
      servers.push(service);
      await listen(service,ports[device]);
    }
    async function control(req,res) {
      if (req.headers.host!=='127.0.0.1:54324' || req.headers.origin) { res.writeHead(403).end(); return; }
      const url = new URL(req.url,'http://127.0.0.1:54324');
      const device=url.searchParams.get('device');
      if (!Object.hasOwn(ports,device)) { res.writeHead(400).end(); return; }
      if (['/progress','/report'].includes(url.pathname)) {
        await android.receive(url.pathname,device,req,res); return;
      }
      if (req.method==='GET' && url.pathname==='/scenario') {
        if (['initial','reader-ready'].includes(phase) && Date.now()-lastOtp<61000) { json(res,202,{waiting:true}); return; }
        json(res,200,scenario); return;
      }
      if (req.method==='GET' && url.pathname==='/otp') {
        const counters = deviceHttp[device];
        counters.mailboxReads++;
        const reply = await fixtureMailboxReply(counters.otpStatus, mailboxCount[device], () =>
          fetch(config.url+'/__test/mail?email='+encodeURIComponent(owner.email),
            {headers:{'x-test-mailbox-key':config.mailboxKey},signal:AbortSignal.timeout(10000)}));
        counters.mailboxStatus=reply.status;
        if (reply.interrupted) counters.mailboxInterrupted++;
        json(res,reply.status,reply.status===200 ? {code:reply.code} : {waiting:reply.status===202});
        return;
      }
      if (url.pathname!=='/phase') { res.writeHead(404).end(); return; }
      if (req.method==='GET') {
        json(res,200,{phase,readerAttemptedWhileOffline:blockedAfterWriter>0,androidStage:android.stage,
          androidCheckpoint:android.checkpoint,androidHttp:deviceHttp.android,iosHttp:deviceHttp.ios});
        return;
      }
      if (req.method!=='POST') { res.writeHead(405).end(); return; }
      let body='';
      for await (const part of req) { body+=part; if (body.length>1024) throw Error('Unexpected phase body'); }
      const signal=JSON.parse(body), next=signal.phase;
      assert.equal(signal.task_id,taskId);
      assert.equal(device,next==='writer-complete'?'android':'ios');
      assert.equal(next,phases[phases.indexOf(phase)+1]);
      if (next==='reader-ready') {
        for (const profile of profiles) {
          assert.ok(observations.some(o=>o.device==='ios' && o.phase==='initial' && o.child===profile.child_id));
        }
        assert.deepEqual(await state(),initial);
        // Close keepalive and any response currently in flight before the writer runs.
        servers[0].closeAllConnections();
      } else if (next==='writer-complete') {
        committedLedger=await verifiedWriterLedger();
      } else if (next==='reader-reconnect') {
        assert.ok(android.saved,'Android UI report has not arrived');
        assert.ok(blockedAfterWriter>0,'Reader never attempted to use the unavailable network after completion');
        reconnectAt=Date.now();
      } else {
        const fresh=observations.find(o=>o.device==='ios' && o.child===family.child && o.phase==='reader-reconnect');
        assert.ok(fresh,'Reader never fetched a fresh snapshot');
        const rows=await ledger();
        assert.deepEqual(rows,committedLedger);
        const finalReceipts=await receipts();
        assert.deepEqual(finalReceipts,applied);
        const siblingFinal=await siblingState(database,sibling.child_id);
        assert.deepEqual(siblingFinal,siblingInitial);
        const result={childProfiles:profiles,siblingInitial,siblingFinal,passed:true,childId:family.child,taskId:taskId,separateLogins:true,initial,final:await state(),
          ledger:rows,receipts:finalReceipts,blockedReaderRequests:blocked,blockedAfterWriter,readerSessionRetained:true,
          firstSnapshotAfterReconnectMs:fresh.at-reconnectAt,
          phaseTimes:{...phaseTimes,[next]:Date.now()},snapshotCounts:Object.fromEntries(['ios','android'].map(d=>[d,observations.filter(o=>o.device===d).length]))};
        await writeFile(directory+'/server.json',JSON.stringify(result,null,2)+'\n');
      }
      phase=next;phaseTimes[next]=Date.now();json(res,200,{phase});
      // Let the reader receive and acknowledge the HTTP response before shutdown.
      if (phase==='reader-confirmed') res.once('close',resolve);
    }
    const controller=createServer((req,res)=>{control(req,res).catch(err=>{json(res,500,{error:'Scenario failed'});fail(err);});});
    servers.push(controller);await listen(controller,54324);
    timer=setTimeout(()=>fail(Error('Timed out waiting for both devices; last phase '+phase)),70*60000);
    process.once('SIGINT',interrupt);process.once('SIGTERM',interrupt);
    console.log('CROSS_DEVICE_READY');
    await promise;
  } finally {
    clearTimeout(timer);process.off('SIGINT',interrupt);process.off('SIGTERM',interrupt);
    for (const service of servers.reverse()) await closeServer(service);
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await rm(androidReportPath,{force:true});
  await mkdir(directory,{recursive:true});
  await writeFile(directory+'/server.json',JSON.stringify({passed:false,status:'starting'})+'\n');
  // All three mobile launches use the same disposable backend and signing key.
  await withAuthBackend(run, {tokenLifetimeSeconds:5400});
}
