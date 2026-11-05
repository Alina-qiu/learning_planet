import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function runtimeDiagnosticsCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(),other=randomUUID();
  const admin=async()=>{await client.query('reset role');};
  const service=async()=>{await admin();await client.query('set role service_role');};
  const auth=()=>login(owner,'diagnostics-session');
  await admin();await client.query('insert into auth.users values($1,$2),($3,$4)',[owner,'runtime-private@example.test',other,'runtime-other@example.test']);
  const day=await scalar("select to_char(now() at time zone 'UTC','YYYY-MM-DD')");
  const event=(overrides={})=>({event_id:randomUUID(),day,kind:'api',operation:'database',outcome:'ok',error:'none',bucket:2,...overrides});
  const record=events=>scalar('select public.record_runtime_diagnostics($1)',[JSON.stringify(events)]);
  const receiptCount=async(user=owner)=>{await admin();return Number(await scalar('select count(*) from public.runtime_diagnostic_receipts where owner_id=$1',[user]));};
  const first=event();
  await check('runtime diagnostics reject text, identities, invalid domains and dates atomically',async()=>{
    await auth();
    const invalid=[null,[],{},event({message:'PRIVATE QUESTION'}),event({owner_id:owner}),event({operation:owner}),
      event({error:null}),event({outcome:null}),event({error:'PRIVATE ERROR'}),event({kind:'ai'}),event({bucket:1.5}),
      event({bucket:7}),event({event_id:'not-a-uuid'}),event({day:'2026-02-30'}),event({day:'2000-01-01'}),event({day:'2999-01-01'})];
    for(const bad of invalid)await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify([first,bad])]);
    await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify([])]);
    await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify(Array.from({length:51},()=>event()))]);
    await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify([first,first])]);
    assert.equal(await receiptCount(),0);
  });
  await check('runtime receipt replay is exact and cannot inflate or silently alter counters',async()=>{
    await auth();assert.deepEqual(await record([first]),{event_ids:[first.event_id]});
    assert.deepEqual(await record([first]),{event_ids:[first.event_id]});
    await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify([event(),{...first,outcome:'server_error'}])]);
    assert.equal(await receiptCount(),1);
    const stored=await scalar('select payload from public.runtime_diagnostic_receipts where owner_id=$1',[owner]);
    assert.deepEqual(stored,first);assert.equal(JSON.stringify(stored).includes(owner),false);
  });
  await check('concurrent runtime uploads keep a single receipt and one counter increment',async()=>{
    const connections=[new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'}),new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'})];
    const sample=event({operation:'edge',outcome:'timeout',bucket:6});
    await admin();const countBefore=Number(await scalar("select coalesce(sum(events),0) from public.runtime_diagnostic_daily where origin='client' and operation='edge' and outcome='timeout'"));
    try {
      for(const connection of connections){await connection.connect();await connection.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:owner,role:'authenticated',session_id:'diagnostics-session'})]);await connection.query('set role authenticated');}
      const results=await Promise.all(connections.map(c=>c.query('select public.record_runtime_diagnostics($1)',[JSON.stringify([sample])])));
      assert.deepEqual(results[0].rows,results[1].rows);
    } finally {await Promise.all(connections.map(c=>c.end()));}
    assert.equal(await receiptCount(),2);
    assert.equal(Number(await scalar("select coalesce(sum(events),0) from public.runtime_diagnostic_daily where origin='client' and operation='edge' and outcome='timeout'")),countBefore+1);
  });
  await check('diagnostic receipts are account scoped and aggregate reports require service role',async()=>{
    await login(other,'other-runtime');await record([first]);assert.equal(await receiptCount(other),1);
    await auth();await denied('select * from public.runtime_diagnostic_receipts');await denied('select * from public.runtime_diagnostic_daily');
    await denied('select public.runtime_health_report(7)');await denied('select public.purge_runtime_diagnostics()');
    await admin();await client.query('set role anon');await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify([event()])]);
    await service();const report=await scalar('select public.runtime_health_report(7)');
    assert.equal(report.timezone,'UTC');assert.deepEqual(report.bucket_upper_ms,[100,500,1500,3000,10000,30000,null]);
    assert.equal(JSON.stringify(report).includes(owner),false);assert.equal(JSON.stringify(report).includes(first.event_id),false);
    await denied('select public.runtime_health_report(null)');await denied('select public.runtime_health_report(0)');await denied('select public.runtime_health_report(91)');
  });
  await check('runtime ingest caps daily volume while allowing an exact lost-response replay',async()=>{
    await admin();await client.query(`insert into public.runtime_diagnostic_receipts(owner_id,event_id,payload)
      select $1,gen_random_uuid(),$2 from generate_series(1,9998)`,[owner,first]);
    await auth();await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify([event()])]);
    assert.deepEqual(await record([first]),{event_ids:[first.event_id]});
    assert.equal(await receiptCount(),10000);
    await client.query('delete from public.runtime_diagnostic_receipts where owner_id=$1 and event_id<>$2',[owner,first.event_id]);
  });
  await check('AI health counts terminal transitions once and survives body retention cleanup',async()=>{
    await auth();await scalar("select public.onboard_family('Runtime family','Asia/Shanghai','PRIVATE CHILD',2::smallint)");
    const family=await scalar('select id from public.families where owner_user_id=$1',[owner]),child=await scalar('select id from public.children where family_id=$1',[family]);
    await admin();const before=await scalar("select coalesce(sum(events),0) from public.runtime_diagnostic_daily where origin='server' and operation='classification'");
    const success=randomUUID(),failure=randomUUID(),cancelled=randomUUID();
    for(const id of [success,failure,cancelled])await client.query(`insert into public.ai_analysis_requests(id,family_id,child_id,owner_id,input_hash,policy_version,state,expires_at,result)
      values($1,$2,$3,$4,'hash',0,'running',now()+interval '1 day','{"private":"PRIVATE BODY"}')`,[id,family,child,owner]);
    await client.query("update public.ai_analysis_requests set state='completed' where id=$1",[success]);
    await client.query("update public.ai_analysis_requests set state='completed' where id=$1",[success]);
    await client.query("update public.ai_analysis_requests set state='failed',result=null where id=$1",[failure]);
    await client.query("update public.ai_analysis_requests set state='cancelled',result=null where id=$1",[cancelled]);
    await client.query("update public.ai_analysis_requests set state='expired',result=null where id=$1",[success]);
    assert.equal(Number(await scalar("select sum(events) from public.runtime_diagnostic_daily where origin='server' and operation='classification'")),Number(before)+2);
    await service();const report=await scalar('select public.runtime_health_report(7)');
    assert.equal(JSON.stringify(report).includes('PRIVATE'),false);assert.equal(JSON.stringify(report).includes(child),false);
    const ai=report.ai.find(row=>row.operation==='classification');assert.ok(Number(ai.failed)>=1);assert.ok(Number(ai.succeeded)>=1);assert.ok(ai.failure_rate>0&&ai.failure_rate<1);
  });
  await check('account deletion immediately erases private runtime receipts and blocks new uploads',async()=>{
    await login(other,'other-runtime');const scope=(await scalar('select public.preview_account_deletion()')).scope;
    await scalar("select public.request_account_deletion($1,$2,'永久注销我的账号')",[randomUUID(),scope]);
    await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify([event()])]);assert.equal(await receiptCount(other),0);
  });
  await check('diagnostic retention preserves replay guards and keeps only ninety UTC daily buckets',async()=>{
    await admin();const recent=randomUUID(),old=randomUUID();
    await client.query("insert into public.runtime_diagnostic_receipts(owner_id,event_id,payload,received_at) values($1,$2,$4,now()-interval '8 days'),($1,$3,$4,now()-interval '10 days')",[owner,recent,old,first]);
    await client.query(`insert into public.runtime_diagnostic_daily values
      ((now() at time zone 'UTC')::date-89,'client','api','database','ok','none',0,1),
      ((now() at time zone 'UTC')::date-90,'client','api','database','ok','none',0,1)`);
    await service();await scalar('select public.purge_runtime_diagnostics()');await admin();
    assert.equal(Number(await scalar('select count(*) from public.runtime_diagnostic_receipts where event_id=$1',[recent])),1);
    assert.equal(Number(await scalar('select count(*) from public.runtime_diagnostic_receipts where event_id=$1',[old])),0);
    assert.equal(Number(await scalar("select count(*) from public.runtime_diagnostic_daily where day=(now() at time zone 'UTC')::date-89")),1);
    assert.equal(Number(await scalar("select count(*) from public.runtime_diagnostic_daily where day<=(now() at time zone 'UTC')::date-90")),0);
  });
  const native = ['androidJavaCrash','androidNativeCrash','androidAnr','iosCrash','iosHang'].map(operation=>event({kind:'native',operation,outcome:'unexpected',bucket:0}));
  await check('native diagnostic categories replay once and expose only fixed aggregate fields',async()=>{
    await auth();
    const expected={event_ids:native.map(e=>e.event_id)};
    assert.deepEqual(await record(native),expected);
    assert.deepEqual(await record(native),expected);
    await service();const report=await scalar('select public.runtime_health_report(7)');
    const rows=report.counts.filter(e=>e.kind==='native');
    assert.equal(rows.length,5);
    for(const row of rows){assert.equal(Number(row.events),1);assert.equal(row.latency_bucket,0);assert.equal(row.error_code,'none');}
    assert.equal(JSON.stringify(rows).includes(owner),false);
    assert.equal(JSON.stringify(rows).includes(native[0].event_id),false);
  });
  await check('native diagnostics reject raw OS payloads and inconsistent category semantics atomically',async()=>{
    await auth();
    for(const change of [{trace:'PRIVATE TRACE'},{process_name:'PRIVATE'},{scope:owner},{count:5},{kind:'runtime'},{operation:'lowMemory'},
      {operation:null},{error:'unknown'},{outcome:'ok'},{bucket:1},{day:'2026-02-30'}]){
      await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify([event(),{...native[0],event_id:randomUUID(),...change}])]);
    }
    await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify([{...native[0],operation:'iosHang'}])]);
    await admin();assert.equal(Number(await scalar("select count(*) from public.runtime_diagnostic_receipts where owner_id=$1 and payload->>'kind'='native'",[owner])),5);
    await client.query('set role anon');await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify(native)]);
  });
  await check('native receipts share account deletion and cannot be uploaded by a deleted account',async()=>{
    const deleting=randomUUID();await admin();await client.query('insert into auth.users values($1,$2)',[deleting,'native-delete@example.test']);
    await login(deleting,'native-delete-session');await record([native[0]]);
    const scope=(await scalar('select public.preview_account_deletion()')).scope;
    await scalar("select public.request_account_deletion($1,$2,'永久注销我的账号')",[randomUUID(),scope]);
    await denied('select public.record_runtime_diagnostics($1)',[JSON.stringify([native[0]])]);
    assert.equal(await receiptCount(deleting),0);
  });
}
