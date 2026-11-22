// The one-argument RPC remains available to older deployed workers. A new
// worker can also run against a database whose migration has not landed yet.
export async function claimFileBatch(client, jobKind, id) {
  const name = jobKind === 'account' ? 'claim_account_deletion' : 'claim_cleanup_job';
  const result = await client.rpc(name, {target_job_id: id, batch_size: 16});
  if (result.error?.code === 'PGRST202') return client.rpc(name, {target_job_id: id});
  return result;
}

export async function confirmFileBatch(admin, jobKind, page, yieldLease) {
  const {data, error} = await admin.rpc('confirm_cleanup_batch', {
    job_kind: jobKind, target_job_id: page.id, token: page.lease_token,
    file_offset: page.file_offset, files: page.manifest, yield_lease: yieldLease,
  });
  if (error) throw new Error('CLEANUP_FINISH_FAILED');
  return data;
}

export function cleanupDeadline() {
  return performance.now() + 45_000;
}

async function removeAndVerify(manifest, storage) {
  if (!Array.isArray(manifest)) throw new Error('INVALID_MANIFEST');
  const groups = new Map();
  for (const file of manifest) {
    const valid = typeof file.path === 'string' && (
      file.bucket === 'wrong-question-images' && /^[0-9a-f-]{36}\/[0-9a-f-]{36}\/(original|processed)\.jpg$/.test(file.path) ||
      file.bucket === 'worksheets' && /^[0-9a-f-]{36}\/[0-9a-f-]{36}\/worksheet\.pdf$/.test(file.path));
    if (!valid) {
      throw new Error('INVALID_MANIFEST');
    }
    if (!groups.has(file.bucket)) groups.set(file.bucket, new Set());
    groups.get(file.bucket).add(file.path);
  }
  for (const [bucket, paths] of groups) {
    const api = storage.from(bucket);
    const all = [...paths];
    for (let offset = 0; offset < all.length; offset += 1000) {
      const { error } = await api.remove(all.slice(offset, offset + 1000));
      if (error) throw new Error('STORAGE_REMOVE_FAILED');
    }
    for (const path of all) {
      let verification;
      try { verification = await api.exists(path); } catch { throw new Error('STORAGE_VERIFY_FAILED'); }
      const { data, error } = verification;
      // HEAD cannot carry the error body. Some Storage versions return HTTP 400
      // for NoSuchKey, so ask the metadata endpoint for an explicit object error.
      const status = Number(error?.status ?? error?.originalError?.status);
      if (data !== false) throw new Error('STORAGE_VERIFY_FAILED');
      if (error && status === 400) {
        let info;
        try { info = await api.info(path); } catch { throw new Error('STORAGE_VERIFY_FAILED'); }
        const detail = info?.error;
        const detailStatus = Number(detail?.status ?? detail?.originalError?.status);
        const code = String(detail?.statusCode ?? '');
        // SDK2.99.1 preserves numeric statusCode ahead of the API's NoSuchKey code.
        // Do not accept a missing bucket, a generic 400, or an authorization/network failure.
        const missingObject = code === 'NoSuchKey' || code === '404' && detail?.message === 'Object not found';
        if (info?.data !== null || ![400,404].includes(detailStatus) || !missingObject) throw new Error('STORAGE_VERIFY_FAILED');
      } else if (error && status !== 404) throw new Error('STORAGE_VERIFY_FAILED');
    }
  }
}

// Manifests are returned by a trusted database claim, never taken from request JSON.
export async function executeCleanup(claim, storage, finish, confirm, deadline = cleanupDeadline()) {
  if (claim.status !== 'claimed') return claim.status;
  try {
    let page = claim;
    if (page.file_offset === undefined) {
      await removeAndVerify(page.manifest, storage);
    } else {
      const total = page.file_total;
      let pages = 0;
      for (;;) {
        const offset = page.file_offset;
        if (!Number.isSafeInteger(total) || !Number.isSafeInteger(offset) || offset < 0 || offset > total ||
            !Array.isArray(page.manifest) || page.manifest.length > 32 || offset + page.manifest.length > total ||
            (page.manifest.length === 0) !== (offset === total)) throw new Error('INVALID_MANIFEST');
        if (offset === total) break;
        await removeAndVerify(page.manifest, storage);
        const nextOffset = offset + page.manifest.length;
        const yieldLease = ++pages >= 16 || performance.now() >= deadline;
        const next = await confirm(page, yieldLease);
        if (!next || next.id !== claim.id || next.file_total !== total || next.file_offset !== nextOffset) {
          throw new Error('CLEANUP_FINISH_FAILED');
        }
        if (yieldLease && nextOffset < total && next.status === 'queued') return 'queued';
        if (next.status !== 'claimed' || next.lease_token !== claim.lease_token) throw new Error('CLEANUP_FINISH_FAILED');
        page = next;
      }
    }
    await finish(claim.id, claim.lease_token, null);
    return 'completed';
  } catch (error) {
    const code = ['INVALID_MANIFEST', 'STORAGE_REMOVE_FAILED', 'STORAGE_VERIFY_FAILED'].includes(error?.message)
      ? error.message : 'CLEANUP_FINISH_FAILED';
    await finish(claim.id, claim.lease_token, code);
    return 'failed';
  }
}
