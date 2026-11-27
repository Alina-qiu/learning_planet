import { createClient } from 'npm:@supabase/supabase-js@2.99.1';
import { createParentPushTransports, drainParentPush } from '../_shared/parent_push_worker.mjs';

declare const EdgeRuntime: { waitUntil(task: Promise<unknown>): void };
const headers={'Content-Type':'application/json','Cache-Control':'no-store'};
let transports: ReturnType<typeof createParentPushTransports> | undefined;
Deno.serve(async request=>{
  if(request.method!=='POST') return new Response('{}',{status:405,headers});
  const secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if(!secret || request.headers.get('Authorization')!==`Bearer ${secret}`) return new Response('{}',{status:403,headers});
  try {
    const text=await request.text();if(text.length>1024) return new Response('{}',{status:413,headers});
    let body;
    try {body=JSON.parse(text);} catch {return new Response('{}',{status:400,headers});}
    if(body===null || Array.isArray(body) || body.mode!=='drain' || Object.keys(body).length!==1) return new Response('{}',{status:400,headers});
    transports??=createParentPushTransports((name:string)=>Deno.env.get(name));
    if(Object.keys(transports).length===0) return new Response('{"error":"PUSH_NOT_CONFIGURED"}',{status:503,headers});
    const admin=createClient(Deno.env.get('SUPABASE_URL')!,secret,{auth:{persistSession:false},global:{
      fetch:(input,init)=>fetch(input,{...init,redirect:'error',signal:init?.signal
        ? AbortSignal.any([init.signal,AbortSignal.timeout(10000)]) : AbortSignal.timeout(10000)}),
    }});
    const task=drainParentPush((name:string,args:Record<string,unknown>)=>admin.rpc(name,args),transports)
      .then(result=>{
        console.info(JSON.stringify({event:'PARENT_PUSH_BATCH',...result}));
        if(result.unsettled>0) console.error('PUSH_LEASE_REQUIRES_RETRY');
      })
      .catch(()=>console.error('PUSH_DISPATCH_REQUIRES_RETRY'));
    EdgeRuntime.waitUntil(task);
    return new Response('{"status":"accepted"}',{status:202,headers});
  } catch {return new Response('{"error":"PUSH_DISPATCH_UNAVAILABLE"}',{status:503,headers});}
});
