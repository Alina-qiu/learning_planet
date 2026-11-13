import assert from 'node:assert/strict';
import {withAuthBackend} from './fixtures/auth_backend.mjs';
import {createStorageBackend} from './fixtures/storage_backend.mjs';
import {runFlutter} from './fixtures/http_test_tools.mjs';

const traffic = await withAuthBackend(config =>
  runFlutter('scripts/fixtures/storage_client_test.dart', config, 'LP_STORAGE_CONFIG'),
{createStorage: createStorageBackend});
assert.ok(traffic.storageRequests >= 15);
