// Prove the runtime gate rejects a mismatched server before any migration and stops it.
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile} from 'node:fs/promises';
import {createServer} from 'node:net';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {startTestDatabase} from './fixtures/database.mjs';

const workspace = process.cwd();
const directory = await mkdtemp(join(tmpdir(), 'learning-planet-version-check-'));
await mkdir(join(directory, 'supabase'));
await writeFile(join(directory, 'supabase', 'config.toml'), '[db]\nmajor_version = 99\n');
async function listener(port = 0) {
  const server = createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  return server;
}
const reservation = await listener();
const port = reservation.address().port;
await new Promise(resolve => reservation.close(resolve));
let migrated = false;
try {
  process.chdir(directory);
  await assert.rejects(startTestDatabase({port, onMigration: () => { migrated = true; }}),
    /Test PostgreSQL .* does not match configured major 99/);
  assert.equal(migrated, false);
  const released = await listener(port);
  await new Promise(resolve => released.close(resolve));
  console.log('PASS mismatched PostgreSQL fails before migrations and releases its listener');
} finally { process.chdir(workspace); }
