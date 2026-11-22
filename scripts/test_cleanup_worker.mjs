import assert from 'node:assert/strict';
import { claimFileBatch, executeCleanup } from '../supabase/functions/_shared/cleanup_worker.mjs';
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
{
  const f = fixture();
  const page = {...f.claim, file_offset: 0, file_total: 2};
  const nextFile = {...page.manifest[0], path: path.replace('original', 'processed')};
  const confirm = async current => {
    f.events.push(['confirm', current.file_offset]);
    if (current.file_offset === 1) throw new Error('lost acknowledgement');
    return {...page, file_offset: 1, manifest: [nextFile]};
  };
  assert.equal(await executeCleanup(page, f.storage, f.finish, confirm), 'failed');
  assert.deepEqual(f.events.map(e => e[0]), ['remove', 'exists', 'confirm', 'remove', 'exists', 'confirm', 'finish']);
  assert.equal(f.events.at(-1).at(-1), 'CLEANUP_FINISH_FAILED');
  f.events.length = 0;
  const resumed = {...page, lease_token: 'new', file_offset: 1, manifest: [nextFile]};
  assert.equal(await executeCleanup(resumed, f.storage, f.finish, async current =>
    ({...current, file_offset: 2, manifest: []})), 'completed');
  assert.deepEqual(f.events.filter(e => e[0] === 'exists').map(e => e[1]), [nextFile.path]);
}
for (const [total, deadline, pages] of [[20, Infinity, 16], [3, 0, 1]]) {
  const f = fixture();
  const page = {...f.claim, file_offset: 0, file_total: total};
  const result = await executeCleanup(page, f.storage, f.finish, async (current, yieldLease) => {
    const offset = current.file_offset + 1;
    assert.equal(yieldLease, offset === pages);
    return {...current, file_offset: offset, status: yieldLease ? 'queued' : 'claimed'};
  }, deadline);
  assert.equal(result, 'queued');
  assert.equal(f.events.filter(e => e[0] === 'exists').length, pages);
  assert.equal(f.events.some(e => e[0] === 'finish'), false);
}
{
  const f = fixture();
  const page = {...f.claim, manifest: [], file_offset: 0, file_total: 0};
  assert.equal(await executeCleanup(page, f.storage, f.finish), 'completed');
  assert.deepEqual(f.events.map(e => e[0]), ['finish']);
}
for (const code of ['PGRST202', '42501', 'PGRST000']) {
  const calls = [];
  const rpc = async (name, args) => {
    calls.push([name,args]);
    return 'batch_size' in args ? {error:{code}} : {data:'legacy'};
  };
  const result = await claimFileBatch({rpc}, 'account', 'job');
  assert.equal(calls.length, code === 'PGRST202' ? 2 : 1);
  assert.deepEqual(calls[0], ['claim_account_deletion', {target_job_id:'job', batch_size:16}]);
  if (code === 'PGRST202') {
    assert.deepEqual(calls[1], ['claim_account_deletion', {target_job_id:'job'}]);
    assert.equal(result.data, 'legacy');
  } else assert.equal(result.error.code, code);
}
console.log('Cleanup worker checks passed, including lost acknowledgements, bounded runs and rolling upgrade compatibility.');
