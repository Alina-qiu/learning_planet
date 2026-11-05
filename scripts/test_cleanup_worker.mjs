import assert from 'node:assert/strict';
import { executeCleanup } from '../supabase/functions/_shared/cleanup_worker.mjs';
const family = '10000000-0000-0000-0000-000000000001';
const draft = '20000000-0000-0000-0000-000000000001';
const path = `${family}/${draft}/original.jpg`;
function fixture(options = {}) {
  const events = [];
  const storage = { from: bucket => ({
    remove: async paths => { events.push(['remove', bucket, paths]); return { error: options.removeError }; },
    exists: async file => { events.push(['exists', file]); return { data: options.present ?? false, error: options.verifyError }; },
    info: async file => { events.push(['info', file]); if (options.infoThrows) throw new Error('private network details'); return options.info; },
  }) };
  const finish = async (...args) => { events.push(['finish', ...args]); };
  const claim = { id: 'job', lease_token: 'lease', status: 'claimed', manifest: [{ bucket: 'wrong-question-images', path }] };
  return { events, storage, finish, claim };
}
{
  const f = fixture();
  assert.equal(await executeCleanup(f.claim, f.storage, f.finish), 'completed');
  assert.deepEqual(f.events.map(e => e[0]), ['remove', 'exists', 'finish']);
  assert.equal(f.events.at(-1).at(-1), null);
}
for (const [options, code] of [
  [{ removeError: new Error('secret provider message') }, 'STORAGE_REMOVE_FAILED'],
  [{ present: true }, 'STORAGE_VERIFY_FAILED'],
  [{ verifyError: new Error('network unavailable') }, 'STORAGE_VERIFY_FAILED'],
]) {
  const f = fixture(options);
  assert.equal(await executeCleanup(f.claim, f.storage, f.finish), 'failed');
  assert.equal(f.events.at(-1).at(-1), code);
  assert.ok(!JSON.stringify(f.events).includes('secret provider message'));
}
{
  const f = fixture(); f.claim.manifest[0].path = '../other-family/image.jpg';
  assert.equal(await executeCleanup(f.claim, f.storage, f.finish), 'failed');
  assert.equal(f.events.length, 1); assert.equal(f.events[0].at(-1), 'INVALID_MANIFEST');
}
{
  const f = fixture({ verifyError: { status: 404 } });
  assert.equal(await executeCleanup(f.claim, f.storage, f.finish), 'completed');
  assert.equal(f.events.at(-1).at(-1), null);
}
{
  const f = fixture({ verifyError: { status: 400 } });
  assert.equal(await executeCleanup(f.claim, f.storage, f.finish), 'failed');
  assert.equal(f.events.at(-1).at(-1), 'STORAGE_VERIFY_FAILED');
}
{
  const f = fixture(); f.claim.status = 'running';
  assert.equal(await executeCleanup(f.claim, f.storage, f.finish), 'running');
  assert.equal(f.events.length, 0);
}
{
  const f = fixture();
  f.claim.manifest = Array.from({ length: 1001 }, (_, i) => ({
    bucket: 'wrong-question-images', path: `${family}/${i.toString(16).padStart(8, '0')}-0000-0000-0000-000000000001/original.jpg`,
  }));
  assert.equal(await executeCleanup(f.claim, f.storage, f.finish), 'completed');
  assert.deepEqual(f.events.filter(e => e[0] === 'remove').map(e => e[2].length), [1000, 1]);
}
{
  const f = fixture();
  f.claim.manifest.push({bucket:'worksheets',path:`${family}/${draft}/worksheet.pdf`});
  assert.equal(await executeCleanup(f.claim,f.storage,f.finish),'completed');
  assert.deepEqual(f.events.filter(e=>e[0]==='remove').map(e=>e[1]),['wrong-question-images','worksheets']);
}
{
  const f = fixture();
  f.claim.manifest=[{bucket:'worksheets',path:`${family}/${draft}/original.jpg`}];
  assert.equal(await executeCleanup(f.claim,f.storage,f.finish),'failed');
  assert.equal(f.events[0].at(-1),'INVALID_MANIFEST');
}
for (const detail of [
  {status:400,statusCode:'404',message:'Object not found'},
  {status:404,statusCode:'404',message:'Object not found'},
  {status:400,statusCode:'NoSuchKey',message:'Object not found'},
  {status:404,statusCode:'NoSuchKey',message:'Object not found'},
]) {
  const f=fixture({verifyError:{status:400},info:{data:null,error:detail}});
  assert.equal(await executeCleanup(f.claim,f.storage,f.finish),'completed');
  assert.deepEqual(f.events.map(e=>e[0]),['remove','exists','info','finish']);
}
for (const info of [
  {data:null,error:{status:400,statusCode:'400',message:'Invalid request'}},
  {data:null,error:{status:400,statusCode:'404',message:'Bucket not found'}},
  {data:null,error:{status:404,statusCode:'NoSuchBucket',message:'Bucket not found'}},
  {data:null,error:{status:403,statusCode:'404',message:'Object not found'}},
  {data:null,error:{status:503,statusCode:'NoSuchKey',message:'Object not found'}},
  {data:{id:'still-present'},error:null},
  {data:null,error:null},
  undefined,
]) {
  const f=fixture({verifyError:{status:400},info});
  assert.equal(await executeCleanup(f.claim,f.storage,f.finish),'failed');
  assert.equal(f.events.at(-1).at(-1),'STORAGE_VERIFY_FAILED');
}
{
  const f=fixture({verifyError:{originalError:{status:400}},infoThrows:true});
  assert.equal(await executeCleanup(f.claim,f.storage,f.finish),'failed');
  assert.equal(f.events.at(-1).at(-1),'STORAGE_VERIFY_FAILED');
  assert.ok(!JSON.stringify(f.events).includes('private network details'));
}
console.log('All 24 cleanup worker checks passed. Storage API is injected, not a cloud integration test.');
