// Test-only endpoint rewrite. The harness adds its temporary certificate to the
// process trust store with --cert; normal TLS verification remains enabled.
import { createParentPushTransports } from '../../supabase/functions/_shared/parent_push_worker.mjs';
const now=Date.now();
const transports=createParentPushTransports(key=>Deno.env.get(key),{fetcher:(url,options)=>{
  if(!url.startsWith('https://api.sandbox.push.apple.com/3/device/')) throw new Error('UNEXPECTED_TEST_ENDPOINT');
  return fetch(`${Deno.env.get('TEST_PUSH_ORIGIN')}${new URL(url).pathname}`,options);
}});
const outcome=await transports.apns({status:'authorized',transport:'apns',registration_token:'a'.repeat(64),data:{
  version:'parent-push-v1',message_id:'11111111-1111-4111-8111-111111111111',scope_nonce:'22222222-2222-4222-8222-222222222222',
  kind:'redemption',issued_ms:String(now),expires_ms:String(now+60000),timezone:'Asia/Shanghai',
  quiet_start:'21:00:00',quiet_end:'07:00:00',settings_version:'1',
}});
if(outcome!=='accepted') throw new Error('LOCAL_APNS_HTTP2_FAILED');
