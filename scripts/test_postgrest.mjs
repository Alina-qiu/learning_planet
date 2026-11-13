// Real SDK -> local HTTP prefix proxy -> PostgREST -> all application migrations.
// Auth/Storage schemas are synthetic here; test_auth.mjs covers real Auth separately.
import {randomBytes, randomUUID} from 'node:crypto';
import {createServer} from 'node:http';
import {startTestDatabase} from './fixtures/database.mjs';
import {freePort, signedJwt, listen, closeServer, forwardHttp, startPostgrest, runFlutter} from './fixtures/http_test_tools.mjs';

const secret = randomBytes(48).toString('base64url');
const users = ['parent', 'other'].map(name => ({id: randomUUID(), email: `${name}@example.test`}));
const jwt = claims => signedJwt(secret, claims);
const session = (user, name) => ({id: user.id, email: user.email,
  token: jwt({sub: user.id, email: user.email, role: 'authenticated', session_id: name})});
let database, rest, gateway;
let unexpectedPaths = 0, requestCount = 0;
try {
  database = await startTestDatabase({port: await freePort(), users});
  rest = await startPostgrest(database, secret);
  gateway = createServer((incoming, outgoing) => {
    if (!incoming.url.startsWith('/rest/v1/')) {
      unexpectedPaths++; outgoing.writeHead(501); outgoing.end('Only local PostgREST is available'); return;
    }
    requestCount++;
    forwardHttp(incoming, outgoing, rest.port, '/rest/v1');
  });
  await listen(gateway);
  const config = {url: `http://127.0.0.1:${gateway.address().port}`, anon: jwt({role: 'anon'}),
    parent: session(users[0], 'http-parent'), peer: session(users[0], 'http-peer'), other: session(users[1], 'http-other'),
    expired: jwt({role: 'authenticated', sub: users[0].id, exp: Math.floor(Date.now() / 1000) - 300})};
  await runFlutter('scripts/fixtures/postgrest_client_test.dart', config);
  if (unexpectedPaths !== 0) throw new Error(`Unexpected Auth/Storage/external service requests: ${unexpectedPaths}`);
  if (requestCount < 20) throw new Error('Expected real repository HTTP traffic');
  console.log(`PASS real HTTP integration: ${requestCount} requests; no Auth/Storage endpoint emulation`);
} finally {
  await closeServer(gateway);
  await rest?.stop();
  if (database) { await database.client.end(); await database.postgres.stop(); }
}
