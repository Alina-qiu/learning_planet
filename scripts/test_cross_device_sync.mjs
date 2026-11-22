// Both native apps share one disposable Auth/PostgREST database. The control
// port stays reachable when the reader's data port drops its connections.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {mkdir, writeFile} from 'node:fs/promises';
import {withAuthBackend} from './fixtures/auth_backend.mjs';
import {closeServer, forwardHttp, listen} from './fixtures/http_test_tools.mjs';
import {realApiClient} from './fixtures/real_api_client.mjs';

const directory = process.env.CROSS_DEVICE_RESULTS_DIR ?? 'build/cross-device';
const ports = {ios: 54325, android: 54326};
const publicKey = 'sb_publishable_cross_device_loopback_fixture';
const title = '跨设备阅读';
const coins = 7, xp = 5;
const phases = ['initial', 'reader-ready', 'writer-complete', 'reader-reconnect', 'reader-confirmed'];

function json(res, code, value) {
  res.writeHead(code, {'Content-Type':'application/json', 'Cache-Control':'no-store'});
  res.end(JSON.stringify(value));
}

async function run(config, {database}) {
  const client = realApiClient(config);
  const owner = await client.account();
  const family = await client.family(owner);
  const day = await client.rpc('family_today', owner.token, {target_child_id:family.child});
  const template = await client.rpc('save_task_schedule', owner.token, {target_child_id:family.child,
    config:{title, recurrence:'once', starts_on:day, ends_on:day, start_time:'00:00',
      due_time:'23:59:59', coins, xp, minimum_seconds:0}});
  await client.rpc('generate_scheduled_tasks',owner.token,{target_child_id:family.child});
  const select = async (sql, params) => (await database.client.query(sql,params)).rows;
  const [task] = await select('select id from public.task_instances where template_id=$1 and child_id=$2',[template,family.child]);
  assert.ok(task?.id, 'Scheduled task missing');
  const scenario = {email:owner.email,title,coins,xp,task_id:task.id,child_id:family.child,family_id:family.id};
  const ledger = () => select('select id,asset_type,amount from public.ledger_entries where child_id=$1 and source_id=$2 order by asset_type',[family.child,task.id]);
  const state = async () => (await select(`select i.status,w.coin_balance,w.frozen_balance,w.xp
    from public.task_instances i join public.wallets w on w.child_id=i.child_id where i.id=$1`,[task.id]))[0];
  const initial = await state();
  assert.ok(['ready','scheduled'].includes(initial.status));
  assert.deepEqual([initial.coin_balance,initial.frozen_balance,initial.xp],[0,0,0]);
  assert.deepEqual(await ledger(),[]);

  let phase = phases[0], lastOtp = Date.now(), blocked = 0, reconnectAt;
  let committedLedger, timer;
  const observations = [], sessions = {}, servers = [];
  const phaseTimes = {};
  const mailboxCount = {ios:2,android:3}; // First message was used for setup.
  const {promise, resolve, reject} = Promise.withResolvers();
  const port = Number(new URL(config.url).port);
  const fail = error => reject(error);
  const interrupt = () => fail(new Error('Cross-device run interrupted'));
  try {
    for (const device of ['ios','android']) {
      const service = createServer((req,res) => {
        // These local data endpoints cannot forward test-control or mailbox traffic.
        if (!(req.url.startsWith('/rest/v1/') || req.url.startsWith('/auth/v1/'))) {
          res.writeHead(404).end(); return;
        }
        if (device==='ios' && ['reader-ready','writer-complete'].includes(phase)) {
          blocked++; req.socket.destroy(); return;
        }
        if (req.headers.apikey!==publicKey) { res.writeHead(401).end(); return; }
        req.headers.apikey = config.anon;
        if (req.headers.authorization===`Bearer ${publicKey}`) req.headers.authorization=`Bearer ${config.anon}`;
        const snapshot = req.url==='/rest/v1/rpc/task_sync_snapshot', acceptedAt=Date.now(), atPhase=phase;
        // PostgREST validates the actual bearer. Retain only the session identifier
        // from successful snapshots to distinguish the two OTP logins.
        if (snapshot) {
          const payload = req.headers.authorization?.split('.')[1];
          res.once('finish',() => {
            if (res.statusCode!==200 || !payload) return;
            try {
              const claims=JSON.parse(Buffer.from(payload,'base64url'));
              assert.equal(claims.sub,owner.id);
              assert.ok(claims.session_id);
              sessions[device]=claims.session_id;
              observations.push({device,phase:atPhase,at:acceptedAt});
            } catch (err) { fail(err); }
          });
        }
        if (req.url==='/auth/v1/otp' && req.method==='POST') lastOtp=Date.now();
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
      if (req.method==='GET' && url.pathname==='/scenario') {
        if (Date.now()-lastOtp<61000) { json(res,202,{waiting:true}); return; }
        json(res,200,scenario); return;
      }
      if (req.method==='GET' && url.pathname==='/otp') {
        const mail=await fetch(config.url+'/__test/mail?email='+encodeURIComponent(owner.email),
          {headers:{'x-test-mailbox-key':config.mailboxKey}});
        const item=mail.ok ? await mail.json() : null;
        if (item?.count!==mailboxCount[device]) { json(res,202,{waiting:true}); return; }
        json(res,200,{code:item.code}); return;
      }
      if (url.pathname!=='/phase') { res.writeHead(404).end(); return; }
      if (req.method==='GET') { json(res,200,{phase}); return; }
      if (req.method!=='POST') { res.writeHead(405).end(); return; }
      let body='';
      for await (const part of req) { body+=part; if (body.length>1024) throw Error('Unexpected phase body'); }
      const signal=JSON.parse(body), next=signal.phase;
      assert.equal(signal.task_id,task.id);
      assert.equal(device,next==='writer-complete'?'android':'ios');
      assert.equal(next,phases[phases.indexOf(phase)+1]);
      if (next==='reader-ready') {
        assert.ok(observations.some(o=>o.device==='ios' && o.phase==='initial'));
        assert.deepEqual(await state(),initial);
        // Close keepalive and any response currently in flight before the writer runs.
        servers[0].closeAllConnections();
      } else if (next==='writer-complete') {
        assert.ok(sessions.android && sessions.ios && sessions.android!==sessions.ios);
        assert.deepEqual(await state(),{status:'completed',coin_balance:coins,frozen_balance:0,xp});
        committedLedger=await ledger();
        assert.deepEqual(committedLedger.map(r=>[r.asset_type,r.amount]),[['coin',coins],['xp',xp]]);
        assert.equal(blocked>0,true,'Reader did not attempt to use the unavailable network');
      } else if (next==='reader-reconnect') {
        reconnectAt=Date.now();
      } else {
        const fresh=observations.find(o=>o.device==='ios' && o.phase==='reader-reconnect');
        assert.ok(fresh,'Reader never fetched a fresh snapshot');
        const rows=await ledger();
        assert.deepEqual(rows,committedLedger);
        const receipts=await select(`select request->>'kind' kind,outcome from public.task_command_receipts
          where task_id=$1 order by created_at`,[task.id]);
        assert.deepEqual(receipts,[{kind:'start',outcome:'applied'},{kind:'complete',outcome:'applied'}]);
        const result={passed:true,childId:family.child,taskId:task.id,separateLogins:true,initial,final:await state(),
          ledger:rows,receipts,blockedReaderRequests:blocked,firstSnapshotAfterReconnectMs:fresh.at-reconnectAt,
          phaseTimes:{...phaseTimes,[next]:Date.now()},snapshotCounts:Object.fromEntries(['ios','android'].map(d=>[d,observations.filter(o=>o.device===d).length]))};
        await writeFile(directory+'/server.json',JSON.stringify(result,null,2)+'\n');
      }
      phase=next;phaseTimes[next]=Date.now();json(res,200,{phase});
      // Let the reader receive and acknowledge the HTTP response before shutdown.
      if (phase==='reader-confirmed') res.once('close',resolve);
    }
    const controller=createServer((req,res)=>{control(req,res).catch(err=>{json(res,500,{error:'Scenario failed'});fail(err);});});
    servers.push(controller);await listen(controller,54324);
    timer=setTimeout(()=>fail(Error('Timed out waiting for both devices; last phase '+phase)),45*60000);
    process.once('SIGINT',interrupt);process.once('SIGTERM',interrupt);
    console.log('CROSS_DEVICE_READY');
    await promise;
  } finally {
    clearTimeout(timer);process.off('SIGINT',interrupt);process.off('SIGTERM',interrupt);
    for (const service of servers.reverse()) await closeServer(service);
  }
}

await mkdir(directory,{recursive:true});
await writeFile(directory+'/server.json',JSON.stringify({passed:false,status:'starting'})+'\n');
// The backend is ready before either simulator cold-boots. Keep the fixture
// anon JWT valid through both boots and the existing 45-minute scenario timer.
await withAuthBackend(run, {tokenLifetimeSeconds:3600});
