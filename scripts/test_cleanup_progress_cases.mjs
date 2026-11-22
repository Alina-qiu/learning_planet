import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export async function cleanupProgressCases({client, scalar, login, check, family, uid}) {
  const service = async () => {
    await client.query('reset role');
    await client.query("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false)");
    await client.query('set role service_role');
  };
  for (const kind of ['account', 'cleanup']) {
    const account = kind === 'account';
    const id = randomUUID(), child = randomUUID(), user = randomUUID();
    const table = account ? 'public.account_deletion_jobs' : 'public.cleanup_jobs';
    const claimRpc = account ? 'public.claim_account_deletion' : 'public.claim_cleanup_job';
    const finishRpc = account ? 'public.finish_account_deletion' : 'public.finish_cleanup_job';
    const gateRpc = account ? 'public.prepare_account_auth_deletion' : finishRpc;
    const files = Array.from({length: 3}, () => ({
      bucket: 'wrong-question-images', path: child + '/' + randomUUID() + '/original.jpg',
    }));
    const claim = (size) => scalar('select ' + claimRpc + '($1,$2)', [id, size]);
    const ack = (page, overrides = {}) => {
      const {file_offset, manifest, lease_token} = {...page, ...overrides};
      return scalar('select public.confirm_cleanup_batch($1,$2,$3,$4,$5,$6)',
        [kind, id, lease_token, file_offset, JSON.stringify(manifest), overrides.yield_lease ?? false]);
    };
    const changeObject = async (file, present) => {
      await client.query('reset role');
      if (present) await client.query('insert into storage.objects(bucket_id,name) values($1,$2)', [file.bucket,file.path]);
      else await client.query('delete from storage.objects where bucket_id=$1 and name=$2', [file.bucket,file.path]);
      await service();
    };
    await client.query('reset role');
    if (account) {
      await client.query('insert into auth.users values($1,$2)', [user,user + '@example.test']);
      await client.query("insert into public.account_deletion_jobs(id,user_id,owned_family_ids,child_ids,manifest,next_attempt_at) values($1,$2,'{}','{}',$3,now())",
        [id,user,JSON.stringify(files)]);
    } else {
      await client.query("insert into public.cleanup_jobs(id,family_id,child_id,owner_id,scope,question_ids,draft_ids,manifest) values($1,$2,$3,$4,'originals','{}','{}',$5)",
        [id,family,child,uid,JSON.stringify(files)]);
    }
    await service();
    let first, last;
    await check(kind + ' file pages require an active service lease, exact files and independent absence', async () => {
      await assert.rejects(claim(0), /Invalid cleanup batch size/);
      await assert.rejects(claim(33), /Invalid cleanup batch size/);
      first = await claim(2);
      assert.deepEqual(first.manifest,files.slice(0,2));
      assert.equal(first.file_total,3);
      assert.equal(first.file_offset,0);
      await assert.rejects(scalar('select ' + gateRpc + '($1,$2)',[id,first.lease_token]), /File verification incomplete/);
      await login();
      await assert.rejects(ack(first), {code:'42501'});
      await service();
      await assert.rejects(ack(first,{lease_token:randomUUID()}), /Invalid deletion lease/);
      await assert.rejects(ack(first,{file_offset:1}), /Invalid cleanup page/);
      await assert.rejects(ack(first,{manifest:[files[1],files[0]]}), /Invalid cleanup page/);
      await changeObject(files[1],true);
      await assert.rejects(ack(first), /File deletion not verified/);
      await changeObject(files[1],false);
      last = await ack(first);
      assert.deepEqual(last.manifest,files.slice(2));
      assert.deepEqual(await ack(first,{yield_lease:true}),last);
      await assert.rejects(ack(first,{file_offset:1,manifest:files.slice(1)}), /Overlapping cleanup page/);
    });
    await check(kind + ' handles expired leases, reappearing files, smaller retry pages and cooperative release', async () => {
      await client.query('reset role');
      await client.query("update " + table + " set lease_until=now()-interval '1 second' where id=$1",[id]);
      await changeObject(files[1],true);
      await assert.rejects(ack(last), /Invalid deletion lease/);
      const recovered = await claim(16);
      assert.equal(recovered.file_offset,1);
      assert.deepEqual(recovered.manifest,[files[1]]);
      assert.notEqual(recovered.lease_token,first.lease_token);
      await assert.rejects(ack(last), /Invalid deletion lease/);
      await changeObject(files[1],false);
      const yielded = await ack(recovered,{yield_lease:true});
      assert.equal(yielded.status,'queued');
      assert.equal(yielded.file_offset,2);
      await assert.rejects(ack(recovered), /Invalid deletion lease/);
      if (!account) {
        // A later-created job that was already waiting gets a turn before a
        // large job that just consumed its invocation budget and requeued.
        const peer = randomUUID();
        await client.query('reset role');
        await client.query("insert into public.cleanup_jobs(id,family_id,child_id,owner_id,scope,question_ids,draft_ids,manifest,next_attempt_at) values($1,$2,$3,$4,'originals','{}','{}','[]','-infinity')",
          [peer,family,child,uid]);
        await service();
        const queued = await scalar('select public.pending_cleanup_jobs()');
        assert.ok(queued.includes(peer) && (!queued.includes(id) || queued.indexOf(peer) < queued.indexOf(id)));
        await client.query('reset role');
        await client.query('delete from public.cleanup_jobs where id=$1',[peer]);
        await service();
      }
      // An older Edge instance may reclaim the queued job during rollout.
      // It still gets all files and cannot use the new acknowledgement API.
      const legacy = await scalar('select '+claimRpc+'($1)',[id]);
      assert.deepEqual(legacy.manifest,files);
      assert.equal(legacy.file_offset,undefined);
      await assert.rejects(ack({...recovered,lease_token:legacy.lease_token}), /Invalid deletion lease/);
      await client.query('reset role');
      await client.query("update " + table + " set lease_until=now()-interval '1 second' where id=$1",[id]);
      await service();
      const next = await claim(16);
      assert.equal(next.file_offset,2);
      await client.query('reset role');
      assert.equal(await scalar('select file_batch_size from '+table+' where id=$1',[id]),16);
      await service();
      const end = await ack(next);
      assert.deepEqual(end.manifest,[]);
      assert.equal(end.file_offset,end.file_total);
      assert.deepEqual(await ack(next),end);
      await changeObject(files[0],true);
      await assert.rejects(scalar('select ' + gateRpc + '($1,$2)',[id,next.lease_token]));
      await changeObject(files[0],false);
      if (account) {
        assert.equal(await scalar('select '+gateRpc+'($1,$2)',[id,next.lease_token]),user);
        await assert.rejects(scalar('select '+finishRpc+'($1,$2)',[id,next.lease_token]), /Auth deletion not verified/);
        await client.query('reset role');
        await client.query('delete from auth.users where id=$1',[user]);
        await service();
      }
      await scalar('select '+finishRpc+'($1,$2)',[id,next.lease_token]);
      await client.query('reset role');
      const state = (await client.query('select status,manifest,verified_files,file_batch_size,file_batch_lease from '+table+' where id=$1',[id])).rows[0];
      assert.deepEqual(state,{status:'completed',manifest:[],verified_files:0,file_batch_size:null,file_batch_lease:null});
    });
  }
  await login();
}
