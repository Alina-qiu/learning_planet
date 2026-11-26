// Loopback PostgreSQL. Integration tests are disposable; family trials can opt into a dedicated cluster.
import EmbeddedPostgres from 'embedded-postgres';
import {cp, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rename, rmdir, symlink, unlink, writeFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {tmpdir} from 'node:os';
import {dirname, isAbsolute, join, relative, resolve, sep} from 'node:path';
import {setTimeout as sleep} from 'node:timers/promises';
import pg from 'pg';

const sqlHash = text => createHash('sha256').update(text).digest('hex');

async function postmaster(data) {
  let file;
  try { file = await readFile(join(data, 'postmaster.pid'), 'utf8'); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  const [pid, path, started, port] = file.trim().split(/\r?\n/);
  if (!/^[1-9]\d*$/.test(pid) || !path || !/^\d+$/.test(started) || !/^\d+$/.test(port)) {
    throw new Error('Unrecognized trial PostgreSQL lock; existing files were preserved');
  }
  return {pid: Number(pid), path: resolve(path), started, port: Number(port)};
}

async function trialCluster(path, compatibility, requireExisting) {
  const directory = resolve(path);
  const workspace = await realpath(process.cwd());
  const parent = await realpath(dirname(directory));
  const fromWorkspace = relative(workspace, parent);
  if (fromWorkspace === '..' || fromWorkspace.startsWith('..' + sep) || isAbsolute(fromWorkspace) || parent !== dirname(directory)) {
    throw new Error('The trial database must be in a project-owned directory');
  }
  if (!requireExisting) {
    try { await mkdir(directory, {mode: 0o700}); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
  }
  if (!(await lstat(directory)).isDirectory()) throw new Error('Invalid trial database directory');
  const marker = join(directory, 'learning-planet-cluster.json');
  const pending = join(directory, 'initializing-cluster');
  const files = await readdir(directory);
  if (!files.length && !requireExisting) {
    await writeFile(pending, 'Initializing the trial database.\n', {flag: 'wx', mode: 0o600});
    return {directory, reused: false, async finish(id) {
      await writeFile(pending, JSON.stringify({...compatibility, systemIdentifier: id}) + '\n', {flag: 'r+'});
      await rename(pending, marker);
    }};
  }
  if (!files.includes('learning-planet-cluster.json') || !(await lstat(marker)).isFile()) {
    throw new Error('Unrecognized or incomplete trial database; existing files were preserved');
  }
  const record = JSON.parse(await readFile(marker, 'utf8'));
  if (typeof record?.systemIdentifier !== 'string' || !/^\d+$/.test(record.systemIdentifier) || Object.keys(compatibility).some(key => record[key] !== compatibility[key])) {
    throw new Error('Incompatible trial database; existing files were preserved');
  }
  const data = join(directory, 'data');
  const version = join(data, 'PG_VERSION');
  if (!(await lstat(data)).isDirectory() || !(await lstat(version)).isFile() || (await readFile(version, 'utf8')).trim() !== String(compatibility.major)) {
    throw new Error('Invalid trial PostgreSQL data directory');
  }
  const server = await postmaster(data);
  if (server) {
    try { process.kill(server.pid, 0); throw new Error('The trial database is already in use'); }
    catch (error) { if (error.code !== 'ESRCH') throw error; }
    // PostgreSQL itself validates stale PID files and performs WAL crash recovery on startup.
  }
  return {directory, reused: true, systemIdentifier: record.systemIdentifier};
}

export async function startTestDatabase({port, users = [], onMigration = () => {}, bootstrapAuth, bootstrapStorage,
  restoreDatabase, persistentDirectory, requireExisting = false}) {
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
  if (persistentDirectory && (restoreDatabase || users.length)) throw new Error('A trial database uses its own Auth users and database');
  if (requireExisting && !persistentDirectory) throw new Error('An existing trial directory is required');
  let trial;
  if (persistentDirectory) {
    const pkg = JSON.parse(await readFile(new URL('../package.json', import.meta.resolve('embedded-postgres')), 'utf8'));
    trial = await trialCluster(persistentDirectory, {format: 1, major: configuredMajor, engine: pkg.version,
      platform: process.platform, arch: process.arch, auth: Boolean(bootstrapAuth), storage: Boolean(bootstrapStorage)}, requireExisting);
  }
  const directory = trial?.directory ?? await mkdtemp(join(tmpdir(), 'learning-planet-db-'));
  const postgres = new EmbeddedPostgres({
    databaseDir: trial ? join(directory, 'data') : directory, user: 'postgres', password: 'local-test-only', port,
    persistent: Boolean(trial), initdbFlags: ['--locale=C', '--encoding=UTF8'], onLog: () => {},
    postgresFlags: ['-h', '127.0.0.1'],
  });
  let nativeBin, aliasParent, binaryAlias, alias;
  if (process.platform === 'win32') {
    const binaries = await import('@embedded-postgres/windows-x64');
    let native = dirname(dirname(binaries.initdb));
    if (trial) {
      // PostgreSQL 15 initdb embeds its Windows ANSI pathname in UTF-8 bootstrap SQL.
      // A unique ASCII alias also identifies this launch independently of the shared data directory.
      aliasParent = await mkdtemp(join(tmpdir(), 'learning-planet-pg-path-'));
      alias = join(aliasParent, 'cluster');
      try {
        if (/[^\x20-\x7e]/.test(alias)) throw new Error('Set TEMP to an ASCII path for PostgreSQL on Windows');
        await symlink(directory, alias, 'junction');
        if (/[^\x20-\x7e]/.test(native)) {
          binaryAlias = join(aliasParent, 'engine');
          await symlink(native, binaryAlias, 'junction');
          native = binaryAlias;
        }
      } catch (error) {
        await unlink(alias).catch(cleanup => { if (cleanup.code !== 'ENOENT') throw cleanup; });
        await rmdir(aliasParent);
        throw error;
      }
    } else {
      await cp(native, join(directory, 'native'), {recursive: true});
      native = join(directory, 'native');
    }
    const processDirectory = alias ?? directory;
    nativeBin = join(native, 'bin');
    const data = join(processDirectory, 'data');
    function command(name, args) {
      const result = spawnSync(join(nativeBin, name + '.exe'), args,
        {windowsHide: true, encoding: 'utf8', stdio: name === 'initdb' ? ['ignore', 'ignore', 'pipe'] : 'ignore', timeout: 30000});
      if (result.error || result.status !== 0) {
        throw result.error ?? new Error(`PostgreSQL command failed: ${name}: ${(result.stderr ?? '').trim().slice(-500)}`);
      }
    }
    postgres.initialise = async () => {
      // Require credentials on Windows too; trust authentication hides missing
      // passwords in peer connections that fail on the Linux CI runner.
      const passwordFile = join(processDirectory, 'initdb-password');
      await writeFile(passwordFile, 'local-test-only\n', {flag: 'wx', mode: 0o600});
      try {
        command('initdb', ['-D', data, '-U', 'postgres', '--auth=scram-sha-256',
          '--pwfile=' + passwordFile, '--locale=C', '--encoding=UTF8']);
      } finally { await unlink(passwordFile); }
    };
    let owner;
    async function ownedServer() {
      const server = await postmaster(data);
      return server && server.path.toLowerCase() === data.toLowerCase() && server.port === port ? server : null;
    }
    postgres.start = async () => {
      try {
        command('pg_ctl', ['-D', data, '-o', `-h 127.0.0.1 -p ${port}`, '-l', join(processDirectory, 'postgres.log'), '-w', 'start']);
      } catch (error) {
        // A timed-out pg_ctl may already have spawned our server. Never stop a different launch.
        if (trial && (owner = await ownedServer())) await stopOwned();
        throw error;
      }
      if (trial && !(owner = await ownedServer())) throw new Error('Could not verify this trial PostgreSQL launch');
    };
    async function stopOwned() {
      const current = await ownedServer();
      if (!current || current.pid !== owner.pid || current.started !== owner.started) return;
      // Target the verified PID, not whichever process may next acquire the directory.
      command('pg_ctl', ['kill', 'INT', String(owner.pid)]);
      for (let i = 0; i < 300; i++) {
        const live = await ownedServer();
        if (!live || live.pid !== owner.pid || live.started !== owner.started) return;
        await sleep(100);
      }
      throw new Error('Timed out waiting for this trial PostgreSQL process to stop');
    }
    postgres.stop = trial ? stopOwned : async () => command('pg_ctl', ['-D', data, '-m', 'fast', '-w', 'stop']);
  }
  // Match the IPv4-only listener on every host; avoid localhost resolving to ::1 in CI.
  postgres.getPgClient = (database = 'postgres') => new pg.Client({
    host: '127.0.0.1', port, user: 'postgres', password: 'local-test-only', database,
  });
  let started = false, client;
  const stop = postgres.stop.bind(postgres);
  postgres.stop = async () => {
    if (started) {
      // embedded-postgres waits for an exit event. A previously exited Unix child has already emitted it.
      if (!trial || process.platform === 'win32' || (postgres.process?.exitCode == null && postgres.process?.signalCode == null)) await stop();
      started = false;
    }
    if (alias) {
      if (binaryAlias) await unlink(binaryAlias);
      await unlink(alias); alias = undefined; await rmdir(aliasParent);
    }
  };
  try {
    if (!trial?.reused) await postgres.initialise();
    await postgres.start(); started = true;
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
    const base = {client, postgres, nativeBin, directory, serverVersion: version.version};
    let systemIdentifier;
    if (trial) {
      systemIdentifier = (await client.query('select system_identifier::text as id from pg_control_system()')).rows[0].id;
      if (trial.reused && systemIdentifier !== trial.systemIdentifier) throw new Error('Trial cluster identity mismatch');
    }
    if (!trial?.reused) {
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
      if (trial) await client.query(`create schema learning_planet_local;
        create table learning_planet_local.migrations(position integer primary key, name text not null unique, sha256 text not null)`);
    }
    const migrationDirectory = resolve('supabase/migrations');
    const migrations = (await readdir(migrationDirectory)).filter(n => n.endsWith('.sql')).sort();
    const history = trial ? (await client.query('select * from learning_planet_local.migrations order by position')).rows : [];
    if (history.length > migrations.length) throw new Error('Trial database migration history exceeds the current project');
    const updates = [];
    for (const [index, entry] of history.entries()) {
      const name = migrations[index];
      const sql = await readFile(join(migrationDirectory, name), 'utf8');
      const normalized = sql.replace(/\r\n/g, '\n');
      const hash = sqlHash(normalized);
      if (entry.position !== index + 1 || entry.name !== name) throw new Error('Trial database migration history mismatch at ' + name);
      if (entry.sha256 !== hash) {
        // The first trial format recorded exact bytes, including a few mixed-EOL project files.
        // Only equivalent, independently computed forms of this specific checked-out SQL may upgrade.
        if (entry.sha256 !== sqlHash(sql) && entry.sha256 !== sqlHash(normalized.replace(/\n/g, '\r\n'))) {
          throw new Error('Trial database migration history mismatch at ' + name);
        }
        updates.push([hash, entry.position, name, entry.sha256]);
      }
    }
    if (updates.length) {
      await client.query('begin');
      try {
        for (const values of updates) {
          const changed = await client.query('update learning_planet_local.migrations set sha256=$1 where position=$2 and name=$3 and sha256=$4', values);
          if (changed.rowCount !== 1) throw new Error('Trial migration history changed during validation');
        }
        await client.query('commit');
      } catch (error) { await client.query('rollback'); throw error; }
    }
    for (const [index, name] of migrations.entries()) {
      if (index < history.length) continue;
      const sql = await readFile(join(migrationDirectory, name), 'utf8');
      try {
        if (trial) await client.query('begin');
        await client.query(sql);
        if (trial) {
          await client.query('insert into learning_planet_local.migrations values($1,$2,$3)', [index + 1, name, sqlHash(sql.replace(/\r\n/g, '\n'))]);
          await client.query('commit');
        }
      } catch (error) {
        if (trial) await client.query('rollback');
        const position = Number(error.position ?? 1) - 1;
        console.error('Migration error near:', sql.slice(Math.max(0, position - 150), position + 150));
        throw error;
      }
      // Await callers that seed the real historical schema before later upgrades.
      // Existing progress-only callbacks can continue to ignore the context.
      await onMigration(name, {client});
    }
    if (trial?.reused) {
      await bootstrapAuth?.({client, port, directory, restored: true});
      await bootstrapStorage?.({client, port, directory, restored: true});
    }
    if (trial && !trial.reused) await trial.finish(systemIdentifier);
    const result = {...base, migrationCount: migrations.length};
    if (trial) {
      result.restored = trial.reused;
      const role = (await client.query(`select rolcanlogin and not (rolsuper or rolinherit or rolcreatedb or rolcreaterole or rolbypassrls or rolreplication)
        and pg_has_role(oid, 'anon', 'member') and pg_has_role(oid, 'authenticated', 'member') as valid
        from pg_roles where rolname='http_authenticator'`)).rows[0];
      if (role && !role.valid) throw new Error('Unexpected trial PostgREST role permissions');
      result.httpRoleExists = Boolean(role);
    }
    return result;
  } catch (error) {
    await client?.end(); await postgres.stop(); throw error;
  }
}
