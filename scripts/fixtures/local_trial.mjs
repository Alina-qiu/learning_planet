import {randomBytes, randomUUID} from 'node:crypto';
import {lstat, mkdir, readFile, rename, writeFile} from 'node:fs/promises';
import {join} from 'node:path';

async function readJson(path) {
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

export function validateLocalCredentials(value) {
  const now = Math.floor(Date.now() / 1000);
  if (!value || typeof value.secret !== 'string' || !/^[a-zA-Z0-9_-]{64}$/.test(value.secret)
    || !Number.isSafeInteger(value.createdAt) || value.createdAt < 1577836800
    || value.createdAt > now + 60 || value.createdAt + 315360000 <= now) {
    throw new Error('Invalid or expired local signing credentials. Restore the original file for this debug APK.');
  }
  return value;
}

function newCredentials() {
  return {secret: randomBytes(48).toString('base64url'), createdAt: Math.floor(Date.now() / 1000)};
}

async function createJson(path, value) {
  await writeFile(path, JSON.stringify(value) + '\n', {mode: 0o600, flag: 'wx'});
}

// Called only after the loopback gateway has acquired its exclusive port. The
// trial is outside Flutter's generated files so flutter clean preserves it.
export async function openLocalTrial(trialRoot, generatedDirectory, keepData) {
  const cachedPath = join(generatedDirectory, 'credentials.json');
  const profilePath = join(trialRoot, 'profile.json');
  const cached = await readJson(cachedPath);
  if (cached) validateLocalCredentials(cached);
  if (!keepData && cached) return {credentials: cached};

  let fresh = false;
  if (keepData) {
    try { await mkdir(trialRoot, {mode: 0o700}); fresh = true; }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
  }
  const directory = await lstat(trialRoot).catch(error => {
    if (error.code === 'ENOENT') return null;
    throw error;
  });
  if (directory && !directory.isDirectory()) throw new Error('Invalid local trial directory');
  const profile = await readJson(profilePath);
  if (profile && (profile.version !== 1 || typeof profile.ready !== 'boolean')) {
    throw new Error('Unsupported local trial profile. Its data was preserved.');
  }
  if (directory && !fresh && !profile) {
    throw new Error('Unrecognized local trial directory. Restore the original profile before restarting.');
  }
  const saved = profile ? validateLocalCredentials(profile.credentials) : null;
  if (cached && saved && (cached.secret !== saved.secret || cached.createdAt !== saved.createdAt)) {
    throw new Error('The local trial and debug APK signing configuration differ. Both configurations were preserved.');
  }
  const credentials = saved ?? cached ?? newCredentials();
  if (fresh) await createJson(profilePath, {version: 1, ready: false, credentials});
  if (!cached) await createJson(cachedPath, credentials);
  if (!keepData) return {credentials};

  return {
    credentials,
    database: join(trialRoot, 'database'),
    storage: join(trialRoot, 'storage'),
    requireExisting: profile?.ready === true,
    async markReady() {
      if (profile?.ready) return;
      const temporary = join(trialRoot, 'profile-' + randomUUID() + '.tmp');
      await createJson(temporary, {version: 1, ready: true, credentials});
      await rename(temporary, profilePath);
    },
  };
}
