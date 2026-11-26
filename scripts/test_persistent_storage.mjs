import assert from 'node:assert/strict';
import {createHash, randomBytes} from 'node:crypto';
import {mkdtemp, mkdir, readFile, readdir, rename, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {createStorageBackend} from './fixtures/storage_backend.mjs';

test('persistent MinIO reopens the original private objects and refuses a missing or incompatible volume', async () => {
  const root = await mkdtemp(join(tmpdir(), 'learning-planet-storage-restart-'));
  const persistentDirectory = join(root, 'storage'), fixture = join(root, 'backup');
  const secret = randomBytes(32).toString('hex');
  const settings = {secret, persistentDirectory, minimumObjects: 0};
  const reopen = () => createStorageBackend({...settings, requireExisting: true});
  const key = 'tenant/wrong-question-images/child/image.png', bytes = Buffer.from('private restart fixture');
  const hash = value => createHash('sha256').update(value).digest('hex');
  const file = hash(key) + '.bin';
  let backend;
  try {
    await assert.rejects(reopen(), /Missing local storage manifest/);
    await mkdir(fixture);
    await writeFile(join(fixture, file), bytes);
    await writeFile(join(fixture, 'manifest.json'), JSON.stringify({version: 1, objects: [
      {key, file, size: bytes.length, sha256: hash(bytes), attributes: {ContentType: 'image/png'}},
    ]}));
    backend = await createStorageBackend(settings);
    await backend.restoreObjects(fixture);
    await assert.rejects(reopen(), {code: 'EADDRINUSE'});
    await backend.stop(); backend = null;
    const manifest = join(persistentDirectory, 'storage.json'), data = join(persistentDirectory, 'objects');
    assert.deepEqual((await readdir(persistentDirectory)).sort(), ['objects', 'storage.json']);
    assert.ok(!(await readdir(data)).includes('migrations'));
    const original = await readFile(manifest, 'utf8');
    assert.ok(!original.includes(secret));
    await assert.rejects(createStorageBackend({...settings, secret: secret + 'wrong', requireExisting: true}), /credentials/);
    await writeFile(manifest, JSON.stringify({...JSON.parse(original), volumeId: 'different'}));
    await assert.rejects(reopen(), /volume identity changed/);
    await writeFile(manifest, original);
    await rename(data, join(root, 'disconnected'));
    await assert.rejects(reopen(), {code: 'ENOENT'});
    assert.ok(!(await readdir(persistentDirectory)).includes('objects'));
    await rename(join(root, 'disconnected'), data);
    const bucket = join(data, 'learning-planet-integration');
    await rename(bucket, join(root, 'removed-bucket'));
    await assert.rejects(reopen(), /bucket is missing/);
    assert.ok(!(await readdir(data)).includes('learning-planet-integration'));
    await rename(join(root, 'removed-bucket'), bucket);
    backend = await reopen();
    assert.deepEqual(await backend.inspectObjects(), [{key, size: bytes.length, sha256: hash(bytes)}]);
    const after = join(root, 'after');
    await backend.backupObjects(after);
    assert.deepEqual(await readFile(join(after, file)), bytes);
    assert.equal(JSON.parse(await readFile(join(after, 'manifest.json'), 'utf8')).objects[0].attributes.ContentType, 'image/png');
  } finally {
    await backend?.stop();
    await rm(root, {recursive: true, force: true});
  }
});
