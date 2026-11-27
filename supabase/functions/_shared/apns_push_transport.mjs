// Shared server-side APNs wire transport; callers supply their own strict payload schema.
const encoder=new TextEncoder();
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
const base64url=bytes=>btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
const json64=value=>base64url(encoder.encode(JSON.stringify(value)));
function pkcs8(pem) {
  if(typeof pem!=='string' || pem.length>16384 || !pem.startsWith('-----BEGIN PRIVATE KEY-----')) throw new Error('PUSH_CONFIG_INVALID');
  return Uint8Array.from(atob(pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,'')),c=>c.charCodeAt(0));
}


export function createApnsPushTransport(env,{prefix,validate,collapse,fetcher=fetch,now=Date.now,cryptoApi=globalThis.crypto,timeoutMs=8000}) {
  if(typeof validate!=='function' || typeof collapse!=='function') throw new Error('PUSH_CONFIG_INVALID');
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
  const apnsKey=env(prefix+'_APNS_KEY'),keyId=env(prefix+'_APNS_KEY_ID'),teamId=env(prefix+'_APNS_TEAM_ID'),topic=env(prefix+'_APNS_TOPIC'),apnsEnv=env(prefix+'_APNS_ENVIRONMENT');
  if(apnsKey || keyId || teamId || topic || apnsEnv) {
    if(!/^[A-Z0-9]{10}$/.test(keyId??'') || !/^[A-Z0-9]{10}$/.test(teamId??'') ||
      !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9_-]+)+$/.test(topic??'') || topic.length>200 || !['sandbox','production'].includes(apnsEnv)) throw new Error('PUSH_CONFIG_INVALID');
    const keyBytes=pkcs8(apnsKey);let signingKey=null,cached=null,pending=null;
    async function apnsToken() {
      if(cached && now()>=cached.issued && now()-cached.issued<50*60*1000) return cached.token;
      if(pending) return pending;
      pending=(async()=>{
        signingKey??=await cryptoApi.subtle.importKey('pkcs8',keyBytes,{name:'ECDSA',namedCurve:'P-256'},false,['sign']);
        const issued=now();const content=`${json64({alg:'ES256',kid:keyId})}.${json64({iss:teamId,iat:Math.floor(issued/1000)})}`;
        const signature=new Uint8Array(await cryptoApi.subtle.sign({name:'ECDSA',hash:'SHA-256'},signingKey,encoder.encode(content)));
        cached={token:`${content}.${base64url(signature)}`,issued};return cached.token;
      })();
      try {return await pending;} finally {pending=null;}
    }
    const origin=apnsEnv==='sandbox'?'https://api.sandbox.push.apple.com':'https://api.push.apple.com';
    return async value=>{
      try {
        const access=await apnsToken();if(!validate(value,now())) return 'rejected';
        return await jsonPost(`${origin}/3/device/${value.registration_token}`,{aps:{'content-available':1},...value.data},{
          authorization:`bearer ${access}`,'apns-topic':topic,'apns-push-type':'background','apns-priority':'5',
          'apns-expiration':'0','apns-collapse-id':collapse(value.data),'apns-id':value.data.message_id,
        },async response=>{
          if(response.status===200) {await response.body?.cancel();return 'accepted';}
          const result=await readJson(response);
          if(response.status===410 && result.reason==='Unregistered' || response.status===400 && result.reason==='BadDeviceToken') return 'invalid_token';
          if(response.status===403 && result.reason==='ExpiredProviderToken') {cached=null;return 'retry';}
          if(response.status===429 || response.status>=500 || response.status===403) return 'retry';
          return 'rejected';
        });
      } catch {return 'retry';}
    };
  }
  return null;
}
