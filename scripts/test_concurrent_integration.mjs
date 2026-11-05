import assert from 'node:assert/strict';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {withAuthBackend} from './fixtures/auth_backend.mjs';
import {runFlutter} from './fixtures/http_test_tools.mjs';

const runId = randomUUID();
await mkdir('build/concurrency_integration', {recursive: true});
await writeFile('build/concurrency_integration/results.json', JSON.stringify({
  runId, date: new Date().toISOString(), passed: false, status: 'running',
}, null, 2) + '\n');
try {
  const traffic = await withAuthBackend(config =>
    runFlutter('scripts/fixtures/concurrent_client_test.dart', {...config, runId}, 'LP_CONCURRENT_CONFIG'));
  const client = JSON.parse(await readFile('build/concurrency_integration/client.json', 'utf8'));
  assert.equal(client.passed, true);
  assert.equal(client.runId, runId);
  assert.deepEqual(client.checks.map(check => check.name), ['task_sync', 'shared_stock']);
  assert.ok(traffic.authRequests >= 10 && traffic.restRequests >= 160 && traffic.mailCount === 5);
  await writeFile('build/concurrency_integration/results.json', JSON.stringify({
    date: new Date().toISOString(), status: 'complete', tests: 2, traffic, ...client,
  }, null, 2) + '\n');
} catch (error) {
  await writeFile('build/concurrency_integration/results.json', JSON.stringify({
    runId, date: new Date().toISOString(), passed: false, status: 'failed',
    errorType: error.name,
  }, null, 2) + '\n');
  throw error;
}
