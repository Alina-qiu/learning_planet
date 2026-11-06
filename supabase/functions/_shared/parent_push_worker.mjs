// Server-only transports. No provider response, registration token, signing key,
// or child data may be returned by the Edge handler or included in logs.
import {createApnsPushTransport} from './apns_push_transport.mjs';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const fields=['expires_ms','issued_ms','kind','message_id','quiet_end','quiet_start','scope_nonce','settings_version','timezone','version'];
const outcomes=new Set(['accepted','retry','rejected','invalid_token']);

export function validParentPush(value,now=Date.now()) {
  const d=value?.data;
  if(value?.status!=='authorized' || !['hms','apns','gateway'].includes(value.transport) ||
    typeof value.registration_token!=='string' || !/^[!-~]{1,4096}$/.test(value.registration_token) ||
    (value.transport==='apns' && !/^[0-9a-f]{64}$/.test(value.registration_token)) ||
    !d || typeof d!=='object' || Array.isArray(d) || Object.keys(d).sort().join(',')!==fields.join(',') ||
    Object.values(d).some(v=>typeof v!=='string') || d.version!=='parent-push-v1' ||
    !uuid.test(d.message_id) || !uuid.test(d.scope_nonce) || !['redemption','weekly'].includes(d.kind) ||
    !/^[1-9][0-9]{0,15}$/.test(d.settings_version) || !Number.isSafeInteger(Number(d.settings_version)) ||
    !/^[0-9]{13}$/.test(d.issued_ms) || !/^[0-9]{13}$/.test(d.expires_ms) ||
    Number(d.issued_ms)>now+30000 || Number(d.expires_ms)<=now ||
    Number(d.expires_ms)<=Number(d.issued_ms) || Number(d.expires_ms)-Number(d.issued_ms)>60000 ||
    !/^([01][0-9]|2[0-3]):[0-5][0-9]:00$/.test(d.quiet_start) ||
    !/^([01][0-9]|2[0-3]):[0-5][0-9]:00$/.test(d.quiet_end) || d.timezone.length>100) return false;
  try {new Intl.DateTimeFormat('en',{timeZone:d.timezone});return true;} catch {return false;}
}

async function readJson(response) {
  if(!response.body) throw new Error('PUSH_RESPONSE_INVALID');
  const reader=response.body.getReader();const chunks=[];let length=0;
  try {
    while(true) {
      const {done,value}=await reader.read();if(done) break;
      length+=value.length;if(length>16384) throw new Error('PUSH_RESPONSE_TOO_LARGE');chunks.push(value);
    }
    const bytes=new Uint8Array(length);let offset=0;
    for(const chunk of chunks) {bytes.set(chunk,offset);offset+=chunk.length;}
    return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  } finally {await reader.cancel().catch(()=>{});reader.releaseLock();}
}
export function createParentPushTransports(env,{fetcher=fetch,now=Date.now,cryptoApi=globalThis.crypto,timeoutMs=8000}={}) {
  const transports={};
  // Abort covers response body reads too. Providers may never redirect secrets.
  async function request(url,options,consume) {
    const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),timeoutMs);
    try {
      const response=await fetcher(url,{...options,redirect:'error',signal:controller.signal});
      return await consume(response);
    } finally {clearTimeout(timer);}
  }
  const post=(url,body,headers,consume)=>request(url,{method:'POST',headers,body},consume);
  const jsonPost=(url,body,headers,consume)=>post(url,JSON.stringify(body),{'Content-Type':'application/json',...headers},consume);
  const hmsId=env('PARENT_PUSH_HMS_APP_ID'),hmsSecret=env('PARENT_PUSH_HMS_APP_SECRET');
  if(hmsId || hmsSecret) {
    if(!/^[0-9]{5,30}$/.test(hmsId??'') || typeof hmsSecret!=='string' || hmsSecret.length<16 || hmsSecret.length>4096) throw new Error('PUSH_CONFIG_INVALID');
    let cached=null,pending=null;
    async function hmsToken() {
      if(cached && now()>=cached.issued && now()<cached.until) return cached.token;
      if(pending) return pending;
      pending=post('https://oauth-login.cloud.huawei.com/oauth2/v3/token',new URLSearchParams({
        grant_type:'client_credentials',client_id:hmsId,client_secret:hmsSecret,
      }).toString(),{'Content-Type':'application/x-www-form-urlencoded'},async response=>{
        if(!response.ok) {await response.body?.cancel();throw new Error('PUSH_AUTH_UNAVAILABLE');}
        const value=await readJson(response);
        if(typeof value.access_token!=='string' || !/^[!-~]{1,8192}$/.test(value.access_token) ||
          !Number.isFinite(value.expires_in) || value.expires_in<60 || value.expires_in>86400) throw new Error('PUSH_AUTH_INVALID');
        cached={token:value.access_token,issued:now(),until:now()+(value.expires_in-30)*1000};return cached.token;
      });
      try {return await pending;} finally {pending=null;}
    }
    transports.hms=async value=>{
      try {
        const access=await hmsToken();
        if(!validParentPush(value,now())) return 'rejected';
        return await jsonPost(`https://push-api.cloud.huawei.com/v1/${hmsId}/messages:send`,{
          validate_only:false,message:{token:[value.registration_token],data:JSON.stringify(value.data),
            android:{urgency:'HIGH',ttl:'0s',collapse_key:value.data.kind==='redemption'?1:2}},
        },{Authorization:`Bearer ${access}`},async response=>{
          if(response.status===401 || response.status===403) cached=null;
          if(!response.ok) {await response.body?.cancel();return response.status===429 || response.status>=500 || response.status===401 || response.status===403?'retry':'rejected';}
          const result=await readJson(response);
          if(result.code==='80000000') return 'accepted';
          if(result.code==='80300007') return 'invalid_token';
          if(['80200001','80200003'].includes(result.code)) {cached=null;return 'retry';}
          if(result.code==='81000001') return 'retry';
          // Includes partial success: this worker sends exactly one endpoint and
          // never treats an unknown or partial response as confirmed acceptance.
          return 'rejected';
        });
      } catch {return 'retry';}
    };
  }
  const apns=createApnsPushTransport(env,{prefix:'PARENT_PUSH',validate:validParentPush,
    collapse:data=>`parent-${data.kind}`,fetcher,now,cryptoApi,timeoutMs});
  if(apns) transports.apns=apns;
  const gatewayUrl=env('PARENT_PUSH_GATEWAY_URL'),gatewayKey=env('PARENT_PUSH_GATEWAY_KEY');
  if(gatewayUrl || gatewayKey) {
    let url;try {url=new URL(gatewayUrl);} catch {throw new Error('PUSH_CONFIG_INVALID');}
    if(url.protocol!=='https:' || url.username || url.password || url.search || url.hash ||
      !/^[a-z0-9.-]+\.[a-z]{2,}$/.test(url.hostname) || !/^[!-~]{16,4096}$/.test(gatewayKey??'')) throw new Error('PUSH_CONFIG_INVALID');
    transports.gateway=async value=>{
      if(!validParentPush(value,now())) return 'rejected';
      try {return await jsonPost(url.href,{registration_token:value.registration_token,data:value.data,ttl_seconds:0,
        collapse_key:`parent-${value.data.kind}`},{Authorization:`Bearer ${gatewayKey}`},async response=>{
        if(!response.ok) {await response.body?.cancel();return response.status===429 || response.status>=500 || response.status===401 || response.status===403?'retry':'rejected';}
        const result=await readJson(response);return outcomes.has(result.outcome)?result.outcome:'rejected';
      });} catch {return 'retry';}
    };
  }
  return transports;
}

export async function drainParentPush(rpc,transports,{now=Date.now}={}) {
  const configured=Object.keys(transports).filter(key=>['hms','apns','gateway'].includes(key) && typeof transports[key]==='function');
  if(configured.length===0) throw new Error('PUSH_NOT_CONFIGURED');
  const call=async(name,args={})=>{const result=await rpc(name,args);if(result.error) throw new Error('PUSH_RPC_FAILED');return result.data;};
  await call('enqueue_parent_push_jobs');
  const claims=await call('claim_parent_push_jobs',{max_jobs:20,transports:configured});
  if(!Array.isArray(claims) || claims.length>20 || claims.some(c=>!uuid.test(c?.job_id) || !uuid.test(c?.lease_token)) ||
    new Set(claims.map(c=>c.job_id)).size!==claims.length) throw new Error('PUSH_CLAIMS_INVALID');
  const stats={claimed:claims.length,sent:0,queued:0,cancelled:0,deferred:0,unsettled:0};let next=0;
  async function work() {
    while(next<claims.length) {
      const claim=claims[next++];
      try {
        const args={target_job_id:claim.job_id,token:claim.lease_token};
        const value=await call('authorize_parent_push_job',args);
        if(value?.status!=='authorized') {if(value?.status==='cancelled') stats.cancelled++;else stats.deferred++;continue;}
        let outcome='rejected';
        if(validParentPush(value,now()) && value.data.message_id===claim.job_id) {
          try {outcome=transports[value.transport]?await transports[value.transport](value):'retry';} catch {outcome='retry';}
          if(!outcomes.has(outcome)) outcome='retry';
        }
        const finished=await call('finish_parent_push_job',{...args,outcome});
        if(['sent','queued','cancelled','deferred'].includes(finished?.status)) stats[finished.status]++;
        else stats.unsettled++;
      } catch {stats.unsettled++;} // Lease recovery handles crashes/lost RPC replies.
    }
  }
  await Promise.all(Array.from({length:Math.min(4,claims.length)},work));
  return stats;
}
