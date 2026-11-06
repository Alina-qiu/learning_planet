import assert from 'node:assert/strict';
import { test } from 'node:test';
import { randomUUID, generateKeyPairSync, verify } from 'node:crypto';
import { createParentPushTransports, drainParentPush, validParentPush } from '../supabase/functions/_shared/parent_push_worker.mjs';

const instant=Date.parse('2026-11-05T04:00:00Z');
function message(transport='hms',id=randomUUID()) {
  return {status:'authorized',transport,registration_token:transport==='apns'?'a'.repeat(64):'private-test-device-token',data:{
    version:'parent-push-v1',message_id:id,scope_nonce:randomUUID(),kind:'redemption',issued_ms:String(instant),
    expires_ms:String(instant+60000),timezone:'Asia/Shanghai',quiet_start:'21:00:00',quiet_end:'07:00:00',settings_version:'1',
  }};
}
const reply=(value,status=200)=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json'}});
const hms={PARENT_PUSH_HMS_APP_ID:'123456789',PARENT_PUSH_HMS_APP_SECRET:'local-private-hms-secret'};
const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const apns={PARENT_PUSH_APNS_KEY:privateKey.export({format:'pem',type:'pkcs8'}),PARENT_PUSH_APNS_KEY_ID:'ABC1234567',
  PARENT_PUSH_APNS_TEAM_ID:'DEF1234567',PARENT_PUSH_APNS_TOPIC:'com.learningplanet.learning_planet',PARENT_PUSH_APNS_ENVIRONMENT:'sandbox'};
const gateway={PARENT_PUSH_GATEWAY_URL:'https://push.example.test/send',PARENT_PUSH_GATEWAY_KEY:'private-gateway-secret'};
const create=(config,fetcher,extra={})=>createParentPushTransports(key=>config[key],{now:()=>instant,fetcher,...extra});

test('no transports by default; partial or unsafe server configuration fails before networking',()=>{
  const network=()=>{throw new Error('unexpected network');};
  assert.deepEqual(create({},network),{});
  for(const config of [{PARENT_PUSH_HMS_APP_ID:hms.PARENT_PUSH_HMS_APP_ID},{...hms,PARENT_PUSH_HMS_APP_ID:'../redirect'},
    {...apns,PARENT_PUSH_APNS_ENVIRONMENT:'unknown'},{...apns,PARENT_PUSH_APNS_KEY:'bad'},
    {...gateway,PARENT_PUSH_GATEWAY_URL:'http://push.example.test/send'},
    {...gateway,PARENT_PUSH_GATEWAY_URL:'https://name:password@push.example.test/send'},
    {...gateway,PARENT_PUSH_GATEWAY_URL:'https://push.example.test/send?secret=value'}]) assert.throws(()=>create(config,network),/PUSH_CONFIG_INVALID/);
});

test('only the exact opaque payload schema, short expiry and supported time zones are accepted',()=>{
  assert.equal(validParentPush(message(),instant),true);
  for(const update of [{child_name:'PRIVATE CHILD'},{kind:'sync_error'},{expires_ms:String(instant+60001)},
    {expires_ms:String(instant)},{issued_ms:String(instant+30001)},{settings_version:'9007199254740992'},
    {quiet_start:'24:00:00'},{timezone:'not-a-zone'},{message_id:'../../elsewhere'}]) {
    const value=message();Object.assign(value.data,update);assert.equal(validParentPush(value,instant),false);
  }
  const value=message();value.registration_token='line\nbreak';assert.equal(validParentPush(value,instant),false);
});

test('HMS uses form OAuth, single-token data-only delivery, zero TTL and shared cached credentials',async()=>{
  let auths=0,sends=0;
  const transports=create(hms,async(url,options)=>{
    assert.equal(options.method,'POST');assert.equal(options.redirect,'error');assert.ok(options.signal);
    if(url==='https://oauth-login.cloud.huawei.com/oauth2/v3/token') {
      auths++;const form=new URLSearchParams(options.body);assert.equal(form.get('client_id'),hms.PARENT_PUSH_HMS_APP_ID);
      assert.equal(form.get('client_secret'),hms.PARENT_PUSH_HMS_APP_SECRET);assert.equal(form.get('grant_type'),'client_credentials');
      await new Promise(resolve=>setTimeout(resolve,10));return reply({access_token:'private-oauth-token',expires_in:3600});
    }
    sends++;assert.equal(url,'https://push-api.cloud.huawei.com/v1/123456789/messages:send');
    assert.equal(options.headers.Authorization,'Bearer private-oauth-token');const body=JSON.parse(options.body);
    assert.deepEqual(body.message.token,['private-test-device-token']);assert.equal(body.validate_only,false);
    assert.deepEqual(body.message.android,{urgency:'HIGH',ttl:'0s',collapse_key:1});
    assert.equal(typeof body.message.data,'string');assert.ok(!('notification' in body.message));
    assert.doesNotMatch(body.message.data,/PRIVATE CHILD|family_id|owner_id|child_id|redemption_id/);
    return reply({code:'80000000',msg:'success',requestId:'opaque-provider-id'});
  });
  assert.deepEqual(await Promise.all([transports.hms(message()),transports.hms(message())]),['accepted','accepted']);
  assert.equal(auths,1);assert.equal(sends,2);
});

test('HMS distinguishes invalid endpoints, transient auth/provider failures and unknown responses',async()=>{
  let result={code:'80300007'},status=200,auths=0;
  const transport=create(hms,async url=>{
    if(url.includes('/oauth2/')) {auths++;return reply({access_token:'opaque-token',expires_in:3600});}
    return reply(result,status);
  }).hms;
  assert.equal(await transport(message()),'invalid_token');
  result={code:'80200003',msg:'PRIVATE TOKEN'};assert.equal(await transport(message()),'retry');
  result={code:'80000000'};assert.equal(await transport(message()),'accepted');assert.equal(auths,2);
  result={code:'81000001'};assert.equal(await transport(message()),'retry');
  result={code:'80100000'};assert.equal(await transport(message()),'rejected');
  status=503;assert.equal(await transport(message()),'retry');
  status=429;assert.equal(await transport(message()),'retry');
  status=400;assert.equal(await transport(message()),'rejected');
});

test('APNs signs a valid ES256 token and sends background-only requests with explicit environment and expiry',async()=>{
  let jwt;
  const transport=create(apns,async(url,options)=>{
    assert.equal(url,`https://api.sandbox.push.apple.com/3/device/${'a'.repeat(64)}`);
    const h=options.headers;jwt=h.authorization.slice(7);const [header,payload,signature]=jwt.split('.');
    assert.deepEqual(JSON.parse(Buffer.from(header,'base64url')),{alg:'ES256',kid:apns.PARENT_PUSH_APNS_KEY_ID});
    assert.deepEqual(JSON.parse(Buffer.from(payload,'base64url')),{iss:apns.PARENT_PUSH_APNS_TEAM_ID,iat:instant/1000});
    assert.ok(verify('sha256',Buffer.from(`${header}.${payload}`),{key:publicKey,dsaEncoding:'ieee-p1363'},Buffer.from(signature,'base64url')));
    assert.equal(h['apns-push-type'],'background');assert.equal(h['apns-priority'],'5');assert.equal(h['apns-expiration'],'0');
    assert.equal(h['apns-topic'],apns.PARENT_PUSH_APNS_TOPIC);assert.equal(h['apns-collapse-id'],'parent-redemption');
    const body=JSON.parse(options.body);assert.deepEqual(body.aps,{'content-available':1});assert.equal(body.message_id,h['apns-id']);
    assert.ok(!('alert' in body.aps));assert.equal(options.redirect,'error');return new Response(null,{status:200});
  }).apns;
  assert.equal(await transport(message('apns')),'accepted');const first=jwt;
  assert.equal(await transport(message('apns')),'accepted');assert.equal(jwt,first);
});

test('APNs maps device revocation and service errors without forwarding provider body text',async()=>{
  let status=410,reason='Unregistered';
  const transport=create({...apns,PARENT_PUSH_APNS_ENVIRONMENT:'production'},async(url)=>{
    assert.ok(url.startsWith('https://api.push.apple.com/'));return reply({reason},status);
  }).apns;
  assert.equal(await transport(message('apns')),'invalid_token');
  status=400;reason='BadDeviceToken';assert.equal(await transport(message('apns')),'invalid_token');
  reason='DeviceTokenNotForTopic';assert.equal(await transport(message('apns')),'rejected');
  status=403;reason='ExpiredProviderToken';assert.equal(await transport(message('apns')),'retry');
  status=429;reason='TooManyRequests';assert.equal(await transport(message('apns')),'retry');
  status=500;reason='PRIVATE SERVER BODY';assert.equal(await transport(message('apns')),'retry');
});

test('gateway endpoint comes only from server configuration and must acknowledge an explicit outcome',async()=>{
  let result={outcome:'accepted'};
  const transport=create(gateway,async(url,options)=>{
    assert.equal(url,gateway.PARENT_PUSH_GATEWAY_URL);assert.equal(options.headers.Authorization,`Bearer ${gateway.PARENT_PUSH_GATEWAY_KEY}`);
    const body=JSON.parse(options.body);assert.equal(body.ttl_seconds,0);assert.equal(body.collapse_key,'parent-redemption');
    assert.equal(body.registration_token,'private-test-device-token');return reply(result);
  }).gateway;
  assert.equal(await transport(message('gateway')),'accepted');result={success:true};assert.equal(await transport(message('gateway')),'rejected');
  result={outcome:'invalid_token'};assert.equal(await transport(message('gateway')),'invalid_token');
});

test('timeouts, redirects, malformed and oversized provider responses produce bounded retry outcomes',async()=>{
  const timed=create(gateway,(_url,options)=>new Promise((_resolve,reject)=>{
    options.signal.addEventListener('abort',()=>reject(new Error('PRIVATE CREDENTIAL IN ERROR')),{once:true});
  }),{timeoutMs:10}).gateway;
  assert.equal(await timed(message('gateway')),'retry');
  const oversized=create(gateway,async()=>new Response('x'.repeat(20000))).gateway;
  assert.equal(await oversized(message('gateway')),'retry');
  const redirect=create(gateway,async(_url,options)=>{assert.equal(options.redirect,'error');throw new Error('redirect secret');}).gateway;
  assert.equal(await redirect(message('gateway')),'retry');
});

test('token cache refreshes after expiry or server clock rollback; no expired payload is sent',async()=>{
  let clock=instant,auths=0,sends=0;
  const transport=create(hms,async url=>{
    if(url.includes('/oauth2/')) {auths++;return reply({access_token:`token-${auths}`,expires_in:60});}
    sends++;return reply({code:'80000000'});
  },{now:()=>clock}).hms;
  assert.equal(await transport(message()),'accepted');clock+=31000;assert.equal(await transport(message()),'accepted');
  clock-=10000;assert.equal(await transport(message()),'accepted');assert.equal(auths,3);
  clock=instant+60000;assert.equal(await transport(message()),'rejected');assert.equal(sends,3);
});

test('dispatch reauthorizes each job, bounds parallel sends to four, and returns only aggregate counts',async()=>{
  const claims=Array.from({length:20},()=>({job_id:randomUUID(),lease_token:randomUUID()}));let active=0,max=0;
  const authorized=new Set(),finished=[];
  const rpc=async(name,args)=>{
    if(name==='enqueue_parent_push_jobs') return {data:20};
    if(name==='claim_parent_push_jobs') {assert.deepEqual(args,{max_jobs:20,transports:['hms']});return {data:claims};}
    if(name==='authorize_parent_push_job') {authorized.add(args.target_job_id);return {data:message('hms',args.target_job_id)};}
    assert.equal(name,'finish_parent_push_job');assert.equal(args.outcome,'accepted');finished.push(args.target_job_id);return {data:{status:'sent'}};
  };
  const stats=await drainParentPush(rpc,{hms:async value=>{
    assert.ok(authorized.has(value.data.message_id));active++;max=Math.max(max,active);
    await new Promise(resolve=>setTimeout(resolve,5));active--;return 'accepted';
  }},{now:()=>instant});
  assert.equal(max,4);assert.equal(finished.length,20);assert.deepEqual(stats,{claimed:20,sent:20,queued:0,cancelled:0,deferred:0,unsettled:0});
  assert.doesNotMatch(JSON.stringify(stats),/token|message_id|job_id/);
});

test('cancelled/deferred and malformed payloads never call providers; lost finish responses leave a recoverable lease',async()=>{
  const claims=Array.from({length:4},()=>({job_id:randomUUID(),lease_token:randomUUID()}));let sends=0;
  const rpc=async(name,args)=>{
    if(name==='enqueue_parent_push_jobs') return {data:4};if(name==='claim_parent_push_jobs') return {data:claims};
    const index=claims.findIndex(c=>c.job_id===args.target_job_id);
    if(name==='authorize_parent_push_job') {
      if(index<2) return {data:{status:index===0?'cancelled':'deferred'}};
      const value=message('hms',args.target_job_id);if(index===2) value.data.child_name='PRIVATE';return {data:value};
    }
    if(index===2) {assert.equal(args.outcome,'rejected');return {data:{status:'cancelled'}};}
    return {error:{message:'PRIVATE RPC ERROR'}};
  };
  const stats=await drainParentPush(rpc,{hms:async()=>{sends++;return 'accepted';}},{now:()=>instant});
  assert.equal(sends,1);assert.deepEqual(stats,{claimed:4,sent:0,queued:0,cancelled:2,deferred:1,unsettled:1});
});

test('unconfigured transports and invalid claims fail before any delivery',async()=>{
  await assert.rejects(drainParentPush(()=>{throw new Error('must not call');},{}),/PUSH_NOT_CONFIGURED/);
  const claim={job_id:randomUUID(),lease_token:randomUUID()};
  for(const claims of [null,{},[claim,claim],[{...claim,job_id:'not-a-uuid'}],Array.from({length:21},()=>({...claim,job_id:randomUUID()}))]) {
    await assert.rejects(drainParentPush(async name=>({data:name==='enqueue_parent_push_jobs'?0:claims}),{hms:()=>{throw new Error('must not send');}}),/PUSH_CLAIMS_INVALID/);
  }
});
