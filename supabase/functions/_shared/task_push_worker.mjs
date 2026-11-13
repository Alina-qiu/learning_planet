import {createApnsPushTransport} from './apns_push_transport.mjs';

const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const fields=['expires_ms','issued_ms','kind','message_id','quiet_end','quiet_start','scheduled_ms','scope_nonce','settings_version','timezone','version'];
const outcomes=new Set(['accepted','retry','rejected','invalid_token']);

export function validTaskPush(value,now=Date.now()) {
  const d=value?.data;
  if(value?.status!=='authorized' || value.transport!=='apns' || typeof value.registration_token!=='string' ||
    !/^(?:[0-9a-f]{2}){1,2048}$/.test(value.registration_token) ||
    !d || typeof d!=='object' || Array.isArray(d) || Object.keys(d).sort().join(',')!==fields.join(',') ||
    Object.values(d).some(v=>typeof v!=='string') || d.version!=='task-push-v1' || d.kind!=='task' ||
    !uuid.test(d.message_id) || !uuid.test(d.scope_nonce) ||
    !/^[1-9][0-9]{0,15}$/.test(d.settings_version) || !Number.isSafeInteger(Number(d.settings_version)) ||
    !/^[0-9]{13}$/.test(d.issued_ms) || !/^[0-9]{13}$/.test(d.expires_ms) || !/^[0-9]{13}$/.test(d.scheduled_ms) ||
    Number(d.issued_ms)>now+30000 || Number(d.expires_ms)<=now || Number(d.scheduled_ms)>Number(d.issued_ms) ||
    Number(d.expires_ms)<=Number(d.issued_ms) || Number(d.expires_ms)-Number(d.issued_ms)>60000 ||
    Number(d.expires_ms)>Number(d.scheduled_ms)+900000 ||
    !/^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$/.test(d.quiet_start) ||
    !/^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$/.test(d.quiet_end) || d.timezone.length>100) return false;
  try {new Intl.DateTimeFormat('en',{timeZone:d.timezone});return true;} catch {return false;}
}

export function createTaskPushTransports(env,options={}) {
  const apns=createApnsPushTransport(env,{...options,prefix:'TASK_PUSH',validate:validTaskPush,
    collapse:data=>`task-${data.scope_nonce}`});
  return apns?{apns}:{};
}

export async function drainTaskPush(rpc,transports,{now=Date.now}={}) {
  if(typeof transports.apns!=='function') throw new Error('PUSH_NOT_CONFIGURED');
  const call=async(name,args={})=>{const result=await rpc(name,args);if(result.error) throw new Error('PUSH_RPC_FAILED');return result.data;};
  await call('purge_task_push');
  await call('enqueue_task_push_jobs');
  const claims=await call('claim_task_push_jobs',{max_jobs:20});
  if(!Array.isArray(claims) || claims.length>20 || claims.some(c=>!uuid.test(c?.job_id) || !uuid.test(c?.lease_token)) ||
    new Set(claims.map(c=>c.job_id)).size!==claims.length) throw new Error('PUSH_CLAIMS_INVALID');
  const stats={claimed:claims.length,sent:0,queued:0,cancelled:0,deferred:0,unsettled:0};let next=0;
  async function work() {
    while(next<claims.length) {
      const claim=claims[next++];
      try {
        const args={target_job_id:claim.job_id,token:claim.lease_token};
        const value=await call('authorize_task_push_job',args);
        if(value?.status!=='authorized') {if(value?.status==='cancelled') stats.cancelled++;else stats.deferred++;continue;}
        let outcome='rejected';
        if(validTaskPush(value,now()) && value.data.message_id===claim.job_id) {
          try {outcome=await transports.apns(value);} catch {outcome='retry';}
          if(!outcomes.has(outcome)) outcome='retry';
        }
        const finished=await call('finish_task_push_job',{...args,outcome});
        if(['sent','queued','cancelled','deferred'].includes(finished?.status)) stats[finished.status]++;
        else stats.unsettled++;
      } catch {stats.unsettled++;}
    }
  }
  await Promise.all(Array.from({length:Math.min(4,claims.length)},work));
  return stats;
}
