// Manifests are returned by a trusted database claim, never taken from request JSON.
export async function executeCleanup(claim, storage, finish) {
  if (claim.status !== 'claimed') return claim.status;
  try {
    if (!Array.isArray(claim.manifest)) throw new Error('INVALID_MANIFEST');
    const groups = new Map();
    for (const file of claim.manifest) {
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
    await finish(claim.id, claim.lease_token, null);
    return 'completed';
  } catch (error) {
    const code = ['INVALID_MANIFEST', 'STORAGE_REMOVE_FAILED', 'STORAGE_VERIFY_FAILED'].includes(error?.message)
      ? error.message : 'CLEANUP_FINISH_FAILED';
    await finish(claim.id, claim.lease_token, code);
    return 'failed';
  }
}
