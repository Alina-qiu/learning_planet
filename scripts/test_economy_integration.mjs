import assert from 'node:assert/strict';
import {mkdir, writeFile} from 'node:fs/promises';
import {withAuthBackend} from './fixtures/auth_backend.mjs';
import {runFlutter} from './fixtures/http_test_tools.mjs';

const traffic = await withAuthBackend(config =>
  runFlutter('scripts/fixtures/economy_client_test.dart', config, 'LP_ECONOMY_CONFIG'));
assert.ok(traffic.authRequests >= 10 && traffic.restRequests >= 40 && traffic.mailCount >= 5);
await mkdir('build/economy_integration', {recursive: true});
await writeFile('build/economy_integration/results.json', JSON.stringify({
  date: new Date().toISOString(), passed: true, tests: 5, traffic,
  scope: 'Actual Supabase Auth/PostgREST, production repositories and file-backed Drift; controlled client network loss. No device or cloud acceptance.',
}, null, 2)+'\n');
