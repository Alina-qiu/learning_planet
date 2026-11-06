// Disposable loopback PostgreSQL. Auth defaults to a stub; bootstrapAuth can install real GoTrue migrations.
import EmbeddedPostgres from 'embedded-postgres';
import {cp, mkdtemp, readFile, readdir, unlink, writeFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import pg from 'pg';

export async function startTestDatabase({port, users = [], onMigration = () => {}, bootstrapAuth, bootstrapStorage, restoreDatabase}) {
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid test port');
  const configuration = await readFile(resolve('supabase/config.toml'), 'utf8');
  let section = '', configuredMajor;
  for (const raw of configuration.split(/\r?\n/)) {
    const line = raw.split('#')[0].trim();
    if (line.startsWith('[')) section = line;
    if (section === '[db]') {
      const match = /^major_version\s*=\s*(\d+)\s*$/.exec(line);
      if (match) configuredMajor = Number(match[1]);
    }
  }
  if (!configuredMajor) throw new Error('Missing [db].major_version in supabase/config.toml');
  const directory = await mkdtemp(join(tmpdir(), 'learning-planet-db-'));
  const postgres = new EmbeddedPostgres({
    databaseDir: directory, user: 'postgres', password: 'local-test-only', port,
    persistent: false, initdbFlags: ['--locale=C', '--encoding=UTF8'], onLog: () => {},
    postgresFlags: ['-h', '127.0.0.1'],
  });
  let nativeBin;
  if (process.platform === 'win32') {
    const binaries = await import('@embedded-postgres/windows-x64');
    const native = join(directory, 'native');
    await cp(dirname(dirname(binaries.initdb)), native, {recursive: true});
    nativeBin = join(native, 'bin');
    const data = join(directory, 'data');
    function command(name, args) {
      const result = spawnSync(join(nativeBin, name + '.exe'), args,
        {windowsHide: true, encoding: 'utf8', stdio: 'ignore', timeout: 30000});
      if (result.error || result.status !== 0) {
        throw result.error ?? new Error('Temporary PostgreSQL command failed: ' + name);
      }
    }
    postgres.initialise = async () => {
      // Require credentials on Windows too; trust authentication hides missing
      // passwords in peer connections that fail on the Linux CI runner.
      const passwordFile = join(directory, 'initdb-password');
      await writeFile(passwordFile, 'local-test-only\n', {flag: 'wx', mode: 0o600});
      try {
        command('initdb', ['-D', data, '-U', 'postgres', '--auth=scram-sha-256',
          '--pwfile=' + passwordFile, '--locale=C', '--encoding=UTF8']);
      } finally { await unlink(passwordFile); }
    };
    postgres.start = async () => command('pg_ctl', ['-D', data, '-o', `-h 127.0.0.1 -p ${port}`, '-l', join(directory, 'postgres.log'), '-w', 'start']);
    postgres.stop = async () => command('pg_ctl', ['-D', data, '-m', 'fast', '-w', 'stop']);
  }
  // Match the IPv4-only listener on every host; avoid localhost resolving to ::1 in CI.
  postgres.getPgClient = (database = 'postgres') => new pg.Client({
    host: '127.0.0.1', port, user: 'postgres', password: 'local-test-only', database,
  });
  let started = false, client;
  const stop = postgres.stop.bind(postgres);
  postgres.stop = async () => { if (started) { await stop(); started = false; } };
  try {
    await postgres.initialise(); await postgres.start(); started = true;
    client = postgres.getPgClient(); await client.connect();
    const version = (await client.query(`select current_setting('server_version') as version,
      current_setting('server_version_num')::integer as number`)).rows[0];
    if (Math.floor(version.number / 10000) !== configuredMajor) {
      throw new Error(`Test PostgreSQL ${version.version} does not match configured major ${configuredMajor}; update the pinned embedded-postgres dependency.`);
    }
    console.log(`DATABASE PostgreSQL ${version.version}; configured major ${configuredMajor}`);
    if (restoreDatabase) {
      if (users.length) throw new Error('A restored fixture must use its backed-up Auth users');
      await restoreDatabase({client, port, directory, nativeBin});
      await bootstrapAuth?.({client, port, directory, restored: true});
      await bootstrapStorage?.({client, port, directory, restored: true});
      // The archive supplies schema and data; applying migrations here could hide a broken backup.
      return {client, postgres, nativeBin, directory, restored: true, migrationCount: 0, serverVersion: version.version};
    }
    await client.query(`
      create role anon nologin;
      create role authenticated nologin;
      create role service_role nologin bypassrls;
      create schema auth;
      create schema storage;
    `);
    if (!bootstrapStorage) await client.query(`
      create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
      create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,owner uuid,owner_id text,unique(bucket_id,name));
      alter table storage.objects enable row level security;
      grant usage on schema storage to authenticated,service_role;
      grant select,insert,update,delete on storage.objects to authenticated;
    `);
    if (bootstrapAuth) {
      if (users.length) throw new Error('Real Auth fixtures must create users through Auth APIs');
      await bootstrapAuth({client, port, directory});
    } else await client.query(`
      create table auth.users(id uuid primary key,email text);
      create function auth.jwt() returns jsonb language sql stable as
        $$ select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
      create function auth.uid() returns uuid language sql stable as $$ select (auth.jwt()->>'sub')::uuid $$;
      create function auth.role() returns text language sql stable as $$ select auth.jwt()->>'role' $$;
    `);
    await client.query(`
      grant usage on schema auth,public to anon,authenticated,service_role;
      grant execute on function auth.jwt(),auth.uid(),auth.role() to anon,authenticated,service_role;
      alter default privileges in schema public grant all on tables to anon,authenticated,service_role;
    `);
    for (const user of users) await client.query('insert into auth.users values($1,$2)', [user.id, user.email]);
    if (bootstrapStorage) await bootstrapStorage({client, port, directory});
    const migrationDirectory = resolve('supabase/migrations');
    const migrations = (await readdir(migrationDirectory)).filter(n => n.endsWith('.sql')).sort();
    for (const name of migrations) {
      const sql = await readFile(join(migrationDirectory, name), 'utf8');
      try { await client.query(sql); } catch (error) {
        const position = Number(error.position ?? 1) - 1;
        console.error('Migration error near:', sql.slice(Math.max(0, position - 150), position + 150));
        throw error;
      }
      // Await callers that seed the real historical schema before later upgrades.
      // Existing progress-only callbacks can continue to ignore the context.
      await onMigration(name, {client});
    }
    return {client, postgres, nativeBin, directory, migrationCount: migrations.length, serverVersion: version.version};
  } catch (error) {
    await client?.end(); await postgres.stop(); throw error;
  }
}
