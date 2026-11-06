import assert from 'node:assert/strict';
import {executeAccountDeletion} from '../supabase/functions/_shared/account_deletion_worker.mjs';
let passed=0;
const claim={id:'job',user_id:'self',status:'claimed',phase:'files',lease_token:'lease',manifest:[{
  bucket:'wrong-question-images',path:'10000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000002/original.jpg',
}]};
function setup({removeError,verifyError,prepareError,wrongUser,authError,finishError}={}) {
  const calls=[];
  const admin={storage:{from:()=>({
    remove:async()=>{calls.push('remove');return {error:removeError};},
    exists:async()=>{calls.push('verify');return {data:false,error:verifyError??{status:404}};},
  })},rpc:async(name,args)=>{
    calls.push([name,args]);
    if(name==='prepare_account_auth_deletion') return {data:wrongUser?'someone-else':'self',error:prepareError};
    return {error:args.failure_code?null:finishError};
  },auth:{admin:{deleteUser:async(user,soft)=>{calls.push(['auth',user,soft]);return {error:authError};}}}};
  return {calls,admin};
}
async function check(name,action){await action();passed++;console.log('PASS '+name);}
await check('non-claim never calls storage or Auth',async()=>{
  const {calls,admin}=setup();assert.equal(await executeAccountDeletion({...claim,status:'waiting'},admin),'waiting');assert.deepEqual(calls,[]);
});
await check('successful order is file remove, absence verification, SQL preparation, hard Auth deletion, SQL completion',async()=>{
  const {calls,admin}=setup();assert.equal(await executeAccountDeletion(claim,admin),'completed');
  assert.deepEqual(calls.map(c=>Array.isArray(c)?c[0]:c),['remove','verify','prepare_account_auth_deletion','auth','finish_account_deletion']);
  assert.deepEqual(calls[3],['auth','self',false]);assert.equal(calls[4][1].failure_code,null);
});
for(const [name,options,expected] of [
  ['Storage failure',{removeError:{status:503}},'STORAGE_REMOVE_FAILED'],
  ['ambiguous verification',{verifyError:{status:403}},'STORAGE_VERIFY_FAILED'],
  ['SQL preparation failure',{prepareError:{}},'ACCOUNT_PREPARE_FAILED'],
  ['identity mismatch',{wrongUser:true},'ACCOUNT_PREPARE_FAILED'],
  ['Auth failure',{authError:{code:'unexpected_failure'}},'AUTH_DELETE_FAILED'],
  ['SQL finish failure',{finishError:{}},'ACCOUNT_FINISH_FAILED'],
]) await check(name+' stays retryable and never claims completion',async()=>{
  const {calls,admin}=setup(options);assert.equal(await executeAccountDeletion(claim,admin),'failed');
  assert.equal(calls.at(-1)[1].failure_code,expected);
  if(expected!=='AUTH_DELETE_FAILED'&&expected!=='ACCOUNT_FINISH_FAILED') assert.equal(calls.some(c=>c[0]==='auth'),false);
});
await check('Auth already missing still requires independent SQL verification',async()=>{
  const {calls,admin}=setup({authError:{code:'user_not_found'}});
  assert.equal(await executeAccountDeletion(claim,admin),'completed');assert.equal(calls.at(-1)[1].failure_code,null);
});
await check('untrusted path is rejected before any Storage or Auth call',async()=>{
  const {calls,admin}=setup();assert.equal(await executeAccountDeletion({...claim,manifest:[{bucket:'wrong-question-images',path:'../other'}]},admin),'failed');
  assert.equal(calls.length,1);assert.equal(calls[0][1].failure_code,'INVALID_MANIFEST');
});
console.log(`All ${passed} account worker checks passed (injected APIs only).`);
