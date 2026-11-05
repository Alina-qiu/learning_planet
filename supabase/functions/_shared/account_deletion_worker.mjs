import {executeCleanup} from './cleanup_worker.mjs';

// Only a service-authorized SQL claim supplies the account identity and manifest.
// Auth deletion is last, and SQL verifies absence independently before completion.
export async function executeAccountDeletion(claim, admin) {
  if (claim.status !== 'claimed') return claim.status;
  const finish = async (code) => {
    const {error} = await admin.rpc('finish_account_deletion', {
      target_job_id: claim.id, token: claim.lease_token, failure_code: code,
    });
    if (error) throw new Error('ACCOUNT_FINISH_FAILED');
  };
  let fileFailure = null;
  const cleanup = await executeCleanup(claim, admin.storage, async (_id, _token, code) => {
    fileFailure = code;
  });
  if (cleanup !== 'completed') {
    await finish(fileFailure ?? 'STORAGE_VERIFY_FAILED');
    return 'failed';
  }
  let failure = 'ACCOUNT_PREPARE_FAILED';
  try {
    const {data: user, error} = await admin.rpc('prepare_account_auth_deletion', {
      target_job_id: claim.id, token: claim.lease_token,
    });
    if (error || user !== claim.user_id) throw new Error('ACCOUNT_PREPARE_FAILED');
    failure = 'AUTH_DELETE_FAILED';
    const result = await admin.auth.admin.deleteUser(user, false);
    // A retry may find the Auth API already succeeded before the worker crashed.
    // Only the exact missing-user code is accepted; SQL still checks auth.users.
    if (result.error && result.error.code !== 'user_not_found') throw new Error('AUTH_DELETE_FAILED');
    failure = 'ACCOUNT_FINISH_FAILED';
    await finish(null);
    return 'completed';
  } catch {
    await finish(failure);
    return 'failed';
  }
}
