// Real Supabase Storage API and MinIO; isolated local data, keys and listeners.
import assert from 'node:assert/strict';
import {createHash, randomBytes} from 'node:crypto';
import {createRequire} from 'node:module';
import {cp, mkdir, mkdtemp, readFile, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {freePort, isolatedEnv, localProcess} from './http_test_tools.mjs';

// MinIO's health endpoint can respond before its S3 subsystem finishes booting.
// Retry only that explicit startup response; permissions and other errors fail immediately.
export async function initializeLocalBucket(createBucket, {timeoutMs = 10000} = {}) {
  const deadline = performance.now() + timeoutMs;
  for (;;) {
    try { return await createBucket(); }
    catch (error) {
      if (error.name !== 'XMinioServerNotInitialized' || error.$metadata?.httpStatusCode !== 503 ||
          performance.now() >= deadline) throw error;
      await delay(Math.min(200, Math.max(0, deadline - performance.now())));
    }
  }
}

export async function createStorageBackend({secret, minimumObjects = 4}) {
  assert.ok(Number.isInteger(minimumObjects) && minimumObjects >= 0);
  if (Number(process.versions.node.split('.')[0]) < 24) throw new Error('Storage v1.72.1 requires Node >=24');
  if (!process.env.STORAGE_SOURCE) throw new Error('Set STORAGE_SOURCE to prepared Supabase Storage v1.72.1 source');
  const source = resolve(process.env.STORAGE_SOURCE);
  assert.equal(createHash('sha256').update(await readFile(join(source, 'package-lock.json'))).digest('hex'),
    'b97a9f0ab3f0f4efbb00f4294cad00fd197885b72d52bb8a18015ca399badae8', 'Expected the pinned Storage v1.72.1 dependency lock');
  const directory = await mkdtemp(join(tmpdir(), 'learning-planet-storage-'));
  await cp(join(source, 'migrations'), join(directory, 'migrations'), {recursive: true});
  // Use the provider's own locked AWS SDK, without adding it to the app dependencies.
  const require = createRequire(join(source, 'package.json'));
  const {S3Client, CreateBucketCommand, ListObjectsV2Command, GetObjectCommand, PutObjectCommand} = require('@aws-sdk/client-s3');
  const minioPort = await freePort(), port = await freePort();
  const accessKeyId = randomBytes(12).toString('hex'), secretAccessKey = randomBytes(32).toString('hex');
  const bucket = 'learning-planet-integration';
  const endpoint = `http://127.0.0.1:${minioPort}`;
  let minio, storage;
  const s3 = new S3Client({endpoint, region: 'us-east-1', forcePathStyle: true,
    credentials: {accessKeyId, secretAccessKey}, maxAttempts: 1});
  const stop = async () => { await storage?.stop(); s3.destroy(); await minio?.stop(); };
  try {
    const minioEnv = isolatedEnv(['MINIO_']);
    Object.assign(minioEnv, {MINIO_ROOT_USER: accessKeyId, MINIO_ROOT_PASSWORD: secretAccessKey,
      MINIO_BROWSER: 'off', MINIO_UPDATE: 'off'});
    minio = localProcess(process.env.MINIO_BIN ?? 'minio', ['server', '--address', `127.0.0.1:${minioPort}`, directory],
      {env: minioEnv, cwd: directory, name: 'Local MinIO'});
    await minio.ready(`${endpoint}/minio/health/ready`);
    await initializeLocalBucket(() => s3.send(new CreateBucketCommand({Bucket: bucket})));
    return {
      port, stop,
      async quiesce() { await storage?.stop(); },
      async backupObjects(destination) {
        await mkdir(destination, {recursive: true});
        const listing = await s3.send(new ListObjectsV2Command({Bucket: bucket}));
        assert.equal(listing.IsTruncated, false, 'Backup fixture supports at most one complete S3 listing');
        const objects = [];
        for (const item of listing.Contents ?? []) {
          const object = await s3.send(new GetObjectCommand({Bucket: bucket, Key: item.Key}));
          const bytes = await object.Body.transformToByteArray();
          const file = createHash('sha256').update(item.Key).digest('hex') + '.bin';
          await writeFile(join(destination, file), bytes, {flag: 'wx'});
          const attributes = {};
          for (const field of ['ContentType','CacheControl','ContentDisposition','ContentEncoding','ContentLanguage','Metadata']) {
            if (object[field] !== undefined) attributes[field] = object[field];
          }
          objects.push({key: item.Key, file, size: bytes.length,
            sha256: createHash('sha256').update(bytes).digest('hex'), attributes});
        }
        await writeFile(join(destination, 'manifest.json'), JSON.stringify({version: 1, objects}, null, 2), {flag: 'wx'});
        return objects.map(({key, size, sha256}) => ({key, size, sha256})).sort((a,b) => a.key.localeCompare(b.key));
      },
      async restoreObjects(sourceDirectory) {
        const listing = await s3.send(new ListObjectsV2Command({Bucket: bucket}));
        assert.ok(!listing.IsTruncated && !(listing.Contents?.length), 'Restore requires an empty disposable bucket');
        const manifest = JSON.parse(await readFile(join(sourceDirectory, 'manifest.json'), 'utf8'));
        assert.equal(manifest.version, 1);
        const seen = new Set(), validated = [];
        // Validate the entire set before putting the first object, including path safety and byte integrity.
        for (const object of manifest.objects) {
          assert.equal(typeof object.key, 'string');
          assert.ok(!seen.has(object.key), 'Duplicate backup object'); seen.add(object.key);
          assert.equal(object.file, createHash('sha256').update(object.key).digest('hex') + '.bin');
          const bytes = await readFile(join(sourceDirectory, object.file));
          assert.equal(bytes.length, object.size, 'Backup object size mismatch');
          assert.equal(createHash('sha256').update(bytes).digest('hex'), object.sha256, 'Backup object checksum mismatch');
          validated.push({object, bytes});
        }
        for (const {object, bytes} of validated) {
          const attributes = {};
          for (const field of ['ContentType','CacheControl','ContentDisposition','ContentEncoding','ContentLanguage','Metadata']) {
            if (object.attributes?.[field] !== undefined) attributes[field] = object.attributes[field];
          }
          await s3.send(new PutObjectCommand({...attributes, Bucket: bucket, Key: object.key, Body: bytes}));
        }
      },
      async inspectObjects() {
        const objects = await s3.send(new ListObjectsV2Command({Bucket: bucket}));
        assert.equal(objects.IsTruncated, false, 'The fixture must inspect every object');
        const result = [];
        for (const item of objects.Contents ?? []) {
          const object = await s3.send(new GetObjectCommand({Bucket: bucket, Key: item.Key}));
          const bytes = await object.Body.transformToByteArray();
          result.push({key: item.Key, size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex')});
        }
        return result.sort((a,b) => a.key.localeCompare(b.key));
      },
      async bootstrap({client, port: databasePort, restored}) {
        // The API can SET ROLE for the JWT but cannot create users or bypass RLS as a superuser.
        if (!restored) await client.query(`
          create role supabase_storage_admin login noinherit nocreatedb nocreaterole nosuperuser password 'storage-test-only';
          grant anon, authenticated, service_role to supabase_storage_admin;
          alter schema storage owner to supabase_storage_admin;
          grant usage on schema public, auth to supabase_storage_admin;
          alter role supabase_storage_admin set search_path = storage,public;
          alter default privileges for role supabase_storage_admin in schema storage grant all on tables to anon,authenticated,service_role;
          alter default privileges for role supabase_storage_admin in schema storage grant all on functions to anon,authenticated,service_role;
          alter default privileges for role supabase_storage_admin in schema storage grant all on sequences to anon,authenticated,service_role;
          grant usage on schema storage to anon,authenticated,service_role;
        `);
        const env = isolatedEnv(['STORAGE_', 'AUTH_', 'PGRST_', 'DATABASE_', 'DB_', 'AWS_', 'S3_',
          'SERVER_', 'PG_QUEUE_', 'VECTOR_', 'ICEBERG_', 'OTEL_', 'MULTI_TENANT', 'IS_MULTITENANT',
          'GLOBAL_', 'FILE_', 'UPLOAD_', 'TENANT_', 'SERVICE_KEY', 'ANON_KEY', 'REGION', 'PORT', 'HOST']);
        Object.assign(env, {
          NODE_ENV: 'test', SERVER_HOST: '127.0.0.1', SERVER_PORT: String(port),
          AUTH_JWT_SECRET: secret, AUTH_JWT_ALGORITHM: 'HS256', TENANT_ID: 'local-integration',
          DATABASE_URL: `postgres://supabase_storage_admin:storage-test-only@127.0.0.1:${databasePort}/postgres`,
          DATABASE_MAX_CONNECTIONS: '5', DATABASE_SEARCH_PATH: 'storage,public',
          DB_INSTALL_ROLES: 'false', DB_SUPER_USER: 'supabase_storage_admin', DB_ALLOW_MIGRATION_REFRESH: 'false',
          STORAGE_BACKEND: 's3', STORAGE_S3_BUCKET: bucket, STORAGE_S3_ENDPOINT: endpoint,
          STORAGE_S3_REGION: 'us-east-1', STORAGE_S3_FORCE_PATH_STYLE: 'true',
          AWS_ACCESS_KEY_ID: accessKeyId, AWS_SECRET_ACCESS_KEY: secretAccessKey,
          AWS_EC2_METADATA_DISABLED: 'true', PG_QUEUE_ENABLE: 'false',
          VECTOR_ENABLED: 'false', VECTOR_STORE_MIGRATIONS_ENABLED: 'false', ICEBERG_ENABLED: 'false',
          // Let the application's 10 MiB bucket limit reject the oversized test, not the service ceiling.
          UPLOAD_FILE_SIZE_LIMIT: '52428800', UPLOAD_FILE_SIZE_LIMIT_STANDARD: '52428800',
          LOG_LEVEL: 'error', REQUEST_X_FORWARDED_HOST_REGEXP: '',
        });
        // Start from a fresh directory so the upstream dotenv loader cannot read developer credentials.
        storage = localProcess(process.execPath, [join(source, 'dist/start/server.js')],
          {env, cwd: directory, name: 'Supabase Storage'});
        const startup = await storage.ready(`http://127.0.0.1:${port}/status`, {timeoutMs: 60000});
        const count = (await client.query('select count(*)::integer as n from storage.migrations')).rows[0].n;
        assert.equal(count, 68, 'Official Storage migrations must run instead of stub tables');
        console.log(`Storage v1.72.1 source; ${count} official migrations; real MinIO S3 backend; ready in ${startup.elapsedMs} ms`);
      },
      async verify(database) {
        const objects = await s3.send(new ListObjectsV2Command({Bucket: bucket}));
        const contents = objects.Contents ?? [];
        assert.ok(contents.length >= minimumObjects, 'Expected actual files in the S3 backend');
        assert.equal(objects.IsTruncated, false);
        for (const item of contents) {
          const result = await s3.send(new GetObjectCommand({Bucket: bucket, Key: item.Key}));
          const bytes = await result.Body.transformToByteArray();
          assert.ok(bytes.length > 0, 'S3 object must have bytes');
        }
        const metadata = (await database.client.query(`select count(*)::integer as n from storage.objects where bucket_id in ('wrong-question-images','worksheets')`)).rows[0].n;
        assert.equal(metadata, contents.length, 'Every file must have one object and one metadata row');
        console.log(`Storage persisted ${metadata} metadata rows and ${contents.length} nonempty S3 objects`);
      },
    };
  } catch (error) { await stop(); throw error; }
}
