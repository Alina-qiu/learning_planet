import assert from 'node:assert/strict';
import {withAuthBackend} from './fixtures/auth_backend.mjs';
import {runFlutter} from './fixtures/http_test_tools.mjs';

const traffic = await withAuthBackend(config =>
  runFlutter('scripts/fixtures/auth_client_test.dart', config, 'LP_AUTH_CONFIG'));
assert.ok(traffic.authRequests >= 10 && traffic.restRequests >= 5 && traffic.mailCount >= 2);
