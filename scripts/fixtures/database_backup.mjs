// Test-only logical backups. Callers supply a fresh loopback fixture, never a linked project.
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash} from 'node:crypto';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {isolatedEnv} from './http_test_tools.mjs';

const execute = promisify(execFile);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
export async function databaseBackupTools() {
  const versions = {};
  async function command(name, args, port) {
    const binary = process.env.PG_CLIENT_BIN
      ? join(process.env.PG_CLIENT_BIN, name + (process.platform === 'win32' ? '.exe' : '')) : name;
    const env = isolatedEnv(['PG']);
    Object.assign(env, {PGHOST: '127.0.0.1', PGPORT: String(port ?? 5432), PGUSER: 'postgres',
      PGPASSWORD: 'local-test-only', PGDATABASE: 'postgres', PGSSLMODE: 'disable', PGCONNECT_TIMEOUT: '5'});
    return execute(binary, args, {env, windowsHide: true, timeout: 60000, maxBuffer: 8 * 1024 * 1024});
  }
  for (const name of ['pg_dump', 'pg_dumpall', 'pg_restore', 'psql']) {
    const {stdout} = await command(name, ['--version']);
    assert.match(stdout.trim(), /\(PostgreSQL\) 15\.\d+/, 'Use PostgreSQL 15 backup clients');
    versions[name] = stdout.trim();
  }
  return {
    versions,
    async backup(database, directory) {
      const port = database.client.connectionParameters.port;
      assert.equal(database.client.connectionParameters.host, '127.0.0.1');
      await mkdir(directory, {recursive: true});
      await command('pg_dump', ['--format=custom', '--file', join(directory, 'database.dump'), '--no-password'], port);
      await command('pg_dumpall', ['--roles-only', '--no-role-passwords', '--file', join(directory, 'roles.sql'), '--no-password'], port);
      const files = {};
      for (const file of ['database.dump', 'roles.sql']) {
        const bytes = await readFile(join(directory, file)); files[file] = {bytes: bytes.length, sha256: hash(bytes)};
      }
      await writeFile(join(directory, 'database-manifest.json'), JSON.stringify({version: 1, files}, null, 2), {flag: 'wx'});
      return files;
    },
    async restore({client, port, directory: targetDirectory}, backupDirectory) {
      assert.equal(client.connectionParameters.host, '127.0.0.1');
      assert.equal((await client.query("select count(*)::int n from pg_tables where schemaname in ('public','auth','storage')")).rows[0].n, 0);
      const manifest = JSON.parse(await readFile(join(backupDirectory, 'database-manifest.json'), 'utf8'));
      assert.equal(manifest.version, 1);
      for (const file of ['database.dump', 'roles.sql']) {
        const bytes = await readFile(join(backupDirectory, file));
        assert.equal(bytes.length, manifest.files[file].bytes, 'Database backup size mismatch');
        assert.equal(hash(bytes), manifest.files[file].sha256, 'Database backup checksum mismatch');
      }
      // initdb already created the bootstrap superuser. Preserve its ALTER ROLE and all other globals.
      const globals = await readFile(join(backupDirectory, 'roles.sql'), 'utf8');
      assert.equal((globals.match(/^CREATE ROLE postgres;$/gm) ?? []).length, 1);
      const rolesFile = join(targetDirectory, 'restore-roles.sql');
      await writeFile(rolesFile, globals.replace(/^CREATE ROLE postgres;\r?\n/m, ''), {flag: 'wx'});
      await command('psql', ['--no-psqlrc', '--no-password', '--set=ON_ERROR_STOP=1', '--file', rolesFile], port);
      await command('pg_restore', ['--exit-on-error', '--single-transaction', '--no-password', '--dbname=postgres',
        join(backupDirectory, 'database.dump')], port);
      // Passwords are deliberately absent from roles.sql. These are disposable fixture credentials.
      await client.query(`alter role supabase_auth_admin password 'auth-test-only';
        alter role supabase_storage_admin password 'storage-test-only';
        alter role http_authenticator password 'http-test-only';`);
    },
  };
}

// Compare complete rows before services can rotate refresh tokens or touch timestamps.
export async function databaseFingerprint(client) {
  const tables = [], sequences = [];
  const quote = name => '"' + name.replaceAll('"', '""') + '"';
  for (const row of (await client.query(`select schemaname,tablename from pg_tables
    where schemaname in ('public','auth','storage') order by 1,2`)).rows) {
    const table = `${quote(row.schemaname)}.${quote(row.tablename)}`;
    const rows = (await client.query(`select row_to_json(t)::text as data from ${table} t order by 1`)).rows;
    tables.push({name: `${row.schemaname}.${row.tablename}`, rows: rows.length, sha256: hash(JSON.stringify(rows))});
  }
  for (const row of (await client.query(`select schemaname,sequencename from pg_sequences
    where schemaname in ('public','auth','storage') order by 1,2`)).rows) {
    const value = (await client.query(`select last_value::text,is_called from ${quote(row.schemaname)}.${quote(row.sequencename)}`)).rows[0];
    sequences.push({name: `${row.schemaname}.${row.sequencename}`, ...value});
  }
  const queries = {
    roles: `select rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls,rolconnlimit,rolvaliduntil,rolconfig
      from pg_roles where rolname not like 'pg_%' order by rolname`,
    memberships: `select a.rolname as role,b.rolname as member,c.rolname as grantor,m.admin_option from pg_auth_members m
      join pg_roles a on a.oid=m.roleid join pg_roles b on b.oid=m.member join pg_roles c on c.oid=m.grantor order by 1,2,3`,
    // pg_restore can emit equivalent grants in a different ACL array order.
    // Compare sorted effective ACL entries, keeping grantee/grantor and all grant options.
    schemas: `select nspname,pg_get_userbyid(nspowner) as owner,
      array(select a::text from unnest(coalesce(nspacl,acldefault('n',nspowner))) a order by a::text) as acl from pg_namespace
      where nspname in ('public','auth','storage') order by 1`,
    relations: `select n.nspname,c.relname,c.relkind,pg_get_userbyid(c.relowner) as owner,
      array(select a::text from unnest(coalesce(c.relacl,acldefault(case when c.relkind='S' then 's'::"char" else 'r'::"char" end,c.relowner))) a order by a::text) as acl,
      c.relrowsecurity,c.relforcerowsecurity
      from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','auth','storage') order by 1,2`,
    policies: `select * from pg_policies where schemaname in ('public','auth','storage') order by schemaname,tablename,policyname`,
    defaults: `select pg_get_userbyid(d.defaclrole) as role,n.nspname,d.defaclobjtype,
      array(select a::text from unnest(d.defaclacl) a order by a::text) as acl
      from pg_default_acl d left join pg_namespace n on n.oid=d.defaclnamespace order by 1,2,3`,
    functions: `select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) as args,pg_get_userbyid(p.proowner) as owner,
      array(select a::text from unnest(coalesce(p.proacl,acldefault('f',p.proowner))) a order by a::text) as acl,
      p.prosecdef,p.proconfig,pg_get_functiondef(p.oid) as definition
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','auth','storage') and p.prokind in ('f','p') order by 1,2,3`,
  };
  const catalog = {};
  for (const [name, query] of Object.entries(queries)) {
    const rows = (await client.query(query)).rows; catalog[name] = {rows: rows.length, sha256: hash(JSON.stringify(rows))};
  }
  return {tables, sequences, catalog};
}
