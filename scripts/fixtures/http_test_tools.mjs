// Shared local-process helpers. No fixture reads linked-project configuration or production credentials.
import {spawn, spawnSync} from 'node:child_process';
import {createHmac} from 'node:crypto';
import {request} from 'node:http';
import {createServer} from 'node:net';
import {delimiter} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';

export async function freePort() {
  const server = createServer();
  await listen(server);
  const port = server.address().port;
  await closeServer(server);
  return port;
}
export function listen(server, port = 0) {
  return new Promise((resolve, reject) => {
    server.once('error', reject); server.listen(port, '127.0.0.1', resolve);
  });
}
export async function closeServer(server) {
  if (!server) return;
  server.closeAllConnections?.();
  await new Promise(resolve => server.close(resolve));
}
export function signedJwt(secret, claims) {
  const body = [Buffer.from(JSON.stringify({alg: 'HS256', typ: 'JWT'})).toString('base64url'),
    Buffer.from(JSON.stringify({iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 1800, ...claims})).toString('base64url')].join('.');
  return `${body}.${createHmac('sha256', secret).update(body).digest('base64url')}`;
}
export function isolatedEnv(prefixes) {
  const env = {...process.env};
  for (const key of Object.keys(env)) if (prefixes.some(prefix => key.startsWith(prefix))) delete env[key];
  return env;
}
export function localProcess(binary, args, {env, cwd, name}) {
  const child = spawn(binary, args, {env, cwd, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe']});
  let log = '', error;
  const done = new Promise(resolve => {
    child.once('error', value => { error = value; resolve({code: -1}); });
    child.once('exit', (code, signal) => resolve({code, signal}));
  });
  for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => { log = (log + chunk).slice(-8000); });
  return {
    child, done,
    async ready(url, {timeoutMs = 20000, method = 'GET', expectedStatus} = {}) {
      const started = performance.now();
      let lastProbe = 'not attempted';
      while (performance.now() - started < timeoutMs) {
        if (error || child.exitCode !== null || child.signalCode !== null) throw error ?? new Error(`${name} exited: ${log}`);
        try {
          const remaining = Math.max(1, Math.ceil(timeoutMs - (performance.now() - started)));
          const response = await fetch(url, {method, signal: AbortSignal.timeout(Math.min(1000, remaining))});
          lastProbe = `HTTP ${response.status}`;
          const ok = expectedStatus === undefined ? response.ok : response.status === expectedStatus;
          await response.arrayBuffer();
          if (ok) return {elapsedMs: Math.round(performance.now() - started)};
        } catch (failure) {
          // Do not include response bodies, URLs or request configuration in diagnostics.
          lastProbe = failure.cause?.code ?? failure.name;
        }
        await delay(Math.min(200, Math.max(0, timeoutMs - (performance.now() - started))));
      }
      throw new Error(`${name} did not become ready after ${Math.round(performance.now() - started)} ms (last probe: ${lastProbe}; process alive: ${child.exitCode === null && child.signalCode === null}): ${log}`);
    },
    async successful() {
      const result = await done;
      if (result.code !== 0) throw error ?? new Error(`${name} failed (${result.code ?? result.signal}): ${log}`);
    },
    async stop() {
      if (child.exitCode === null && child.signalCode === null) child.kill();
      await done;
    },
  };
}
export async function startPostgrest(database, secret) {
  const binary = process.env.POSTGREST_BIN ?? 'postgrest';
  const env = isolatedEnv(['PGRST_']);
  if (database.nativeBin) {
    const pathKey = Object.keys(env).find(key => key.toLowerCase() === 'path') ?? 'PATH';
    env[pathKey] = database.nativeBin + delimiter + env[pathKey];
  }
  const version = spawnSync(binary, ['--version'], {env, encoding: 'utf8', windowsHide: true, timeout: 10000});
  if (version.error || version.status !== 0) throw new Error('Set POSTGREST_BIN to an installed PostgREST executable. ' + (version.error?.message ?? version.stderr));
  console.log(`${version.stdout.trim()}; ${database.restored ? 'restored database' : `${database.migrationCount} application migrations`}`);
  if (!database.restored) await database.client.query(`
    create role http_authenticator login noinherit nocreatedb nocreaterole nosuperuser password 'http-test-only';
    grant anon, authenticated to http_authenticator;
  `);
  const port = await freePort();
  Object.assign(env, {
    PGRST_DB_URI: `postgres://http_authenticator:http-test-only@127.0.0.1:${database.client.connectionParameters.port}/postgres`,
    PGRST_DB_SCHEMAS: 'public', PGRST_DB_ANON_ROLE: 'anon', PGRST_DB_CONFIG: 'false',
    PGRST_JWT_SECRET: secret, PGRST_SERVER_HOST: '127.0.0.1', PGRST_SERVER_PORT: String(port),
  });
  const service = localProcess(binary, [], {env, name: 'PostgREST'});
  try { await service.ready(`http://127.0.0.1:${port}/`); }
  catch (error) { await service.stop(); throw error; }
  return {...service, port};
}
export function forwardHttp(incoming, outgoing, port, prefix) {
  const upstream = request({hostname: '127.0.0.1', port, method: incoming.method,
    path: incoming.url.slice(prefix.length), headers: incoming.headers}, response => {
    outgoing.writeHead(response.statusCode, response.headers); response.pipe(outgoing);
  });
  upstream.on('error', () => {
    if (!outgoing.headersSent) outgoing.writeHead(502);
    outgoing.end('Local service unavailable');
  });
  incoming.on('aborted', () => upstream.destroy()); incoming.pipe(upstream);
}
export async function runFlutter(file, configuration, variable = 'LP_HTTP_CONFIG') {
  if (!/^scripts\/fixtures\/[a-z_]+_test\.dart$/.test(file)) throw new Error('Invalid test path');
  const binary = process.env.FLUTTER_BIN ?? (process.platform === 'win32' ? 'flutter.bat' : 'flutter');
  const args = ['test', '--no-pub', '--reporter', 'expanded', file];
  const env = {...process.env, [variable]: JSON.stringify(configuration)};
  let child;
  if (process.platform === 'win32') {
    if (/["\r\n%]/.test(binary)) throw new Error('Invalid FLUTTER_BIN');
    child = spawn('cmd.exe', ['/d', '/s', '/c', `""${binary}" ${args.join(' ')}"`],
      {env, windowsHide: true, windowsVerbatimArguments: true, stdio: 'inherit'});
  } else child = spawn(binary, args, {env, stdio: 'inherit'});
  const result = await new Promise((resolve, reject) => {
    child.once('error', reject); child.once('exit', (code, signal) => resolve({code, signal}));
  });
  if (result.code !== 0) throw new Error(`Flutter HTTP integration failed (${result.code ?? result.signal})`);
}
