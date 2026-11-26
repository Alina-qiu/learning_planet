import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {cp, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, writeFile} from 'node:fs/promises';
import {createServer} from 'node:net';
import {basename, dirname, join} from 'node:path';
import {setTimeout as sleep} from 'node:timers/promises';
import {startTestDatabase} from './fixtures/database.mjs';
import {freePort} from './fixtures/http_test_tools.mjs';

const project = await realpath(process.cwd());
const build = join(project, 'build');
await mkdir(build, {recursive: true});
const scratch = await mkdtemp(join(build, 'trial-database-'));
const cluster = join(scratch, '家用数据库');
const start = async (options = {}) => startTestDatabase({port: await freePort(), persistentDirectory: cluster, ...options});
let db;
async function stop() {
  if (!db) return;
  await db.client.end();
  await db.postgres.stop();
  db = null;
}
try {
  // Use real historical migrations, appending the final one after the first stop.
  await cp(join(project, 'supabase', 'migrations'), join(scratch, 'supabase', 'migrations'), {recursive: true});
  await cp(join(project, 'supabase', 'config.toml'), join(scratch, 'supabase', 'config.toml'));
  process.chdir(scratch);
  const names = (await readdir('supabase/migrations')).filter(n => n.endsWith('.sql')).sort();
  const last = names.at(-1);
  const lastPath = join('supabase', 'migrations', last);
  const mixedName = '202611050047_task_reminder_delivery_policy.sql';
  const mixedPath = join('supabase', 'migrations', mixedName);
  const mixedLF = (await readFile(mixedPath, 'utf8')).replace(/\r\n/g, '\n');
  const mixedText = mixedLF.replace('\n', '\r\n');
  const hash = text => createHash('sha256').update(text).digest('hex');
  await writeFile(mixedPath, mixedText);
  await rename(lastPath, 'later.sql');
  await assert.rejects(start({requireExisting: true}), /ENOENT/);
  db = await start();
  assert.equal(db.restored, false);
  assert.equal(db.httpRoleExists, false);
  assert.equal(db.migrationCount, names.length - 1);
  await db.client.query(`insert into auth.users(id,email) values ('30303030-0000-4000-8000-000000000001','trial@example.test')`);
  await db.client.query('update learning_planet_local.migrations set sha256=$1 where name=$2', [hash(mixedText), mixedName]);
  const first = join('supabase', 'migrations', names[0]);
  const original = await readFile(first);
  const lf = original.toString('utf8').replace(/\r\n/g, '\n');
  await db.client.query('update learning_planet_local.migrations set sha256=$1 where name=$2', [hash(lf.replace(/\n/g, '\r\n')), names[0]]);
  await assert.rejects(start(), /already in use/);
  assert.equal((await db.client.query('select 1 as ok')).rows[0].ok, 1);
  await stop();
  await rename('later.sql', lastPath);

  const busy = createServer();
  await new Promise((done, fail) => { busy.once('error', fail); busy.listen(0, '127.0.0.1', done); });
  try {
    await assert.rejects(start({port: busy.address().port, requireExisting: true}));
    assert.ok(busy.listening);
  } finally { await new Promise(done => busy.close(done)); }

  const added = [];
  db = await start({requireExisting: true, onMigration: name => added.push(name)});
  assert.equal(db.restored, true);
  assert.equal(db.httpRoleExists, false);
  assert.deepEqual(added, [last]);
  for (const [name, expected] of [[mixedName, hash(mixedLF)], [names[0], hash(lf)]]) {
    assert.equal((await db.client.query('select sha256 from learning_planet_local.migrations where name=$1', [name])).rows[0].sha256, expected);
  }
  assert.equal((await db.client.query('select email from auth.users')).rows[0].email, 'trial@example.test');
  await db.client.query('create role http_authenticator login noinherit; grant anon, authenticated, service_role to http_authenticator');
  await stop();

  await writeFile(first, original.includes('\r\n') ? lf : lf.replace(/\n/g, '\r\n'));
  db = await start({requireExisting: true, onMigration: () => assert.fail('Line endings must not reapply a migration')});
  await stop();
  await writeFile(first, Buffer.concat([original, Buffer.from('\n-- edited history')]));
  await assert.rejects(start({requireExisting: true}), /history mismatch/);
  await writeFile(first, original);

  const broken = 'supabase/migrations/999999999999_test_atomicity.sql';
  await writeFile(broken, 'create table marker_for_rollback(id int); select 1/0;');
  await assert.rejects(start({requireExisting: true}), /division by zero/);
  await writeFile(broken, 'create table marker_for_rollback(id int);');
  db = await start({requireExisting: true});
  assert.equal(db.httpRoleExists, true);
  assert.equal((await db.client.query('select count(*)::integer n from learning_planet_local.migrations')).rows[0].n, names.length + 1);
  assert.equal((await db.client.query('select count(*)::integer n from auth.users')).rows[0].n, 1);

  // Stop our own postmaster out-of-band. A delayed stop from its old owner must leave the next owner alone.
  const old = db;
  await old.client.end();
  const pidFile = join(cluster, 'data', 'postmaster.pid');
  const [pid, path] = (await readFile(pidFile, 'utf8')).split(/\r?\n/);
  assert.equal(await realpath(path), await realpath(join(cluster, 'data')));
  if (process.platform === 'win32') {
    execFileSync(join(old.nativeBin, 'pg_ctl.exe'), ['-D', path, '-m', 'fast', '-w', 'stop'], {stdio: 'ignore', windowsHide: true});
  } else {
    process.kill(Number(pid), 'SIGINT');
    for (let i = 0; i < 300 && (await readdir(join(cluster, 'data'))).includes('postmaster.pid'); i++) await sleep(100);
  }
  db = null;
  try { db = await start({requireExisting: true}); }
  finally { await old.postgres.stop(); }
  assert.equal((await db.client.query('select count(*)::integer n from auth.users')).rows[0].n, 1);
  await stop();

  const unknown = join(scratch, 'unidentified-cluster');
  await mkdir(unknown);
  await writeFile(join(unknown, 'existing'), 'keep');
  await assert.rejects(start({persistentDirectory: unknown}), /Unrecognized or incomplete/);
  assert.deepEqual(await readdir(unknown), ['existing']);
  console.log('PASS trial database preserves data and roles, upgrades exact history, and rejects altered or incomplete state');
} finally {
  await stop();
  process.chdir(project);
  const owned = await realpath(scratch);
  assert.equal(dirname(owned), await realpath(build));
  assert.ok(basename(owned).startsWith('trial-database-'));
  await rm(owned, {recursive: true});
}
