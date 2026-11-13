// Real GoTrue + SMTP + PostgREST + app migrations; all services are disposable and loopback-only.
import {randomBytes} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {startTestDatabase} from './database.mjs';
import {localMailbox} from './local_mailbox.mjs';
import {freePort, listen, closeServer, forwardHttp, isolatedEnv, localProcess, signedJwt, startPostgrest} from './http_test_tools.mjs';

export async function withAuthBackend(run, {createStorage, verifyTraffic = true, tokenLifetimeSeconds = 1800, localCredentials, restoreDatabase} = {}) {
  if (!Number.isInteger(tokenLifetimeSeconds) || tokenLifetimeSeconds < 60 || tokenLifetimeSeconds > 86400) {
    throw new Error('Local token lifetime must be between one minute and one day');
  }
  if (localCredentials && (!/^[a-zA-Z0-9_-]{64}$/.test(localCredentials.secret)
    || !Number.isInteger(localCredentials.createdAt) || localCredentials.createdAt < 1577836800
    || localCredentials.createdAt > Math.floor(Date.now()/1000)+60
    || localCredentials.createdAt+315360000 <= Math.floor(Date.now()/1000))) {
    throw new Error('Invalid or expired isolated local credentials');
  }
  const binary = process.env.GOTRUE_BIN ?? 'auth';
  const configuration = await readFile('supabase/config.toml', 'utf8');
  function setting(section, key) {
    let current = '';
    for (const raw of configuration.split(/\r?\n/)) {
      const line = raw.trim();
      if (line.startsWith('[')) current = line;
      const equals = line.indexOf('=');
      if (current === `[${section}]` && line.slice(0, equals).trim() === key) {
        return JSON.parse(line.slice(equals + 1).trim());
      }
    }
    throw new Error(`Missing local Auth configuration: ${section}.${key}`);
  }
  // These fixture routes deliberately serve the repository's OTP template only.
  for (const kind of ['confirmation', 'magic_link']) {
    if (setting(`auth.email.template.${kind}`, 'content_path') !== './supabase/templates/email_otp.html') {
      throw new Error('Update the local Auth fixture routes for the configured email template');
    }
  }
  const otpLength = setting('auth.email', 'otp_length');
  if (otpLength !== 8) throw new Error('Update the eight-digit template fixture when changing otp_length');
  const secret = localCredentials?.secret ?? randomBytes(48).toString('base64url'), mailboxKey = randomBytes(24).toString('hex');
  const template = await readFile('supabase/templates/email_otp.html');
  let mailbox, gateway, database, auth, rest, authPort, authEnv, storage;
  let authRequests = 0, restRequests = 0, storageRequests = 0, unexpectedPaths = 0;
  let quiesced = false;
  try {
    const version = spawnSync(binary, ['version'], {encoding: 'utf8', windowsHide: true, timeout: 10000});
    if (version.error || version.status !== 0) throw new Error('Set GOTRUE_BIN to the prepared Auth executable');
    if (!/^v2\.196\.0(?:-windows-local)?$/.test(version.stdout.trim())) throw new Error('Expected pinned Auth v2.196.0');
    console.log(`GoTrue ${version.stdout.trim()}; project email settings; loopback SMTP only`);
    mailbox = await localMailbox();
    authPort = await freePort();
    gateway = createServer((incoming, outgoing) => {
      if (quiesced) { incoming.resume(); outgoing.writeHead(503); outgoing.end('Local backup in progress'); return; }
      if (incoming.url === '/__test/template') {
        outgoing.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'}); outgoing.end(template); return;
      }
      if (incoming.url.startsWith('/__test/mail?')) {
        if (incoming.headers['x-test-mailbox-key'] !== mailboxKey) { outgoing.writeHead(403); outgoing.end(); return; }
        const email = new URL(incoming.url, 'http://127.0.0.1').searchParams.get('email') ?? '';
        const message = mailbox.latest(email);
        outgoing.writeHead(message ? 200 : 404, {'Content-Type': 'application/json'});
        outgoing.end(JSON.stringify(message)); return;
      }
      if (incoming.url.startsWith('/auth/v1/')) { authRequests++; forwardHttp(incoming, outgoing, authPort, '/auth/v1'); return; }
      if (incoming.url.startsWith('/rest/v1/') && rest) { restRequests++; forwardHttp(incoming, outgoing, rest.port, '/rest/v1'); return; }
      if (incoming.url.startsWith('/storage/v1/') && storage) { storageRequests++; forwardHttp(incoming, outgoing, storage.port, '/storage/v1'); return; }
      unexpectedPaths++; outgoing.writeHead(501); outgoing.end('Unsupported local integration route');
    });
    await listen(gateway);
    const url = `http://127.0.0.1:${gateway.address().port}`;
    authEnv = isolatedEnv(['GOTRUE_', 'OTEL_']);
    for (const key of ['DATABASE_URL', 'API_EXTERNAL_URL', 'DB_NAMESPACE', 'PORT']) delete authEnv[key];
    Object.assign(authEnv, {
      GOTRUE_API_HOST: '127.0.0.1', PORT: String(authPort), API_EXTERNAL_URL: `${url}/auth/v1`,
      GOTRUE_DB_DRIVER: 'postgres', DB_NAMESPACE: 'auth', GOTRUE_DB_MAX_POOL_SIZE: '5',
      GOTRUE_SITE_URL: setting('auth', 'site_url'), GOTRUE_EXTERNAL_EMAIL_ENABLED: 'true',
      GOTRUE_EXTERNAL_PHONE_ENABLED: 'false', GOTRUE_DISABLE_SIGNUP: String(!setting('auth.email', 'enable_signup')),
      GOTRUE_JWT_SECRET: secret, GOTRUE_JWT_EXP: '3600', GOTRUE_JWT_AUD: 'authenticated',
      GOTRUE_JWT_DEFAULT_GROUP_NAME: 'authenticated', GOTRUE_MAILER_AUTOCONFIRM: String(!setting('auth.email', 'enable_confirmations')),
      GOTRUE_MAILER_OTP_LENGTH: String(otpLength), GOTRUE_MAILER_OTP_EXP: String(setting('auth.email', 'otp_expiry')),
      GOTRUE_SMTP_MAX_FREQUENCY: setting('auth.email', 'max_frequency'),
      GOTRUE_SMTP_HOST: '127.0.0.1', GOTRUE_SMTP_PORT: String(mailbox.port),
      GOTRUE_SMTP_ADMIN_EMAIL: 'noreply@example.test', GOTRUE_SMTP_SENDER_NAME: '学习星球',
      GOTRUE_MAILER_TEMPLATES_CONFIRMATION: `${url}/__test/template`,
      GOTRUE_MAILER_TEMPLATES_MAGIC_LINK: `${url}/__test/template`,
      GOTRUE_MAILER_SUBJECTS_CONFIRMATION: setting('auth.email.template.confirmation', 'subject'),
      GOTRUE_MAILER_SUBJECTS_MAGIC_LINK: setting('auth.email.template.magic_link', 'subject'),
      // Keep the project's per-address 60-second wait; allow independent synthetic users in one run.
      GOTRUE_RATE_LIMIT_EMAIL_SENT: '1000', GOTRUE_LOG_LEVEL: 'error',
    });
    storage = await createStorage?.({secret, url});
    database = await startTestDatabase({port: await freePort(), restoreDatabase, bootstrapStorage: storage?.bootstrap, bootstrapAuth: async ({client, port, directory, restored}) => {
      if (!restored) await client.query(`
        create role supabase_auth_admin login noinherit nocreatedb nocreaterole nosuperuser password 'auth-test-only';
        alter schema auth owner to supabase_auth_admin;
        alter role supabase_auth_admin set search_path = auth;
      `);
      authEnv.DATABASE_URL = `postgres://supabase_auth_admin:auth-test-only@127.0.0.1:${port}/postgres?sslmode=disable`;
      if (!restored) {
        const migration = localProcess(binary, ['migrate'], {env: authEnv, cwd: directory, name: 'GoTrue migrations'});
        try { await migration.successful(); } finally { await migration.stop(); }
      }
    }});
    const count = (await database.client.query('select count(*)::integer as count from auth.schema_migrations')).rows[0].count;
    console.log(`GoTrue real schema: ${count} migrations; no synthetic users`);
    auth = localProcess(binary, ['serve'], {env: authEnv, cwd: database.directory, name: 'GoTrue'});
    await auth.ready(`http://127.0.0.1:${authPort}/health`);
    rest = await startPostgrest(database, secret);
    const issuedAt=localCredentials?.createdAt ?? Math.floor(Date.now()/1000);
    const expiresAt=issuedAt+(localCredentials ? 315360000 : tokenLifetimeSeconds);
    await run({url, anon: signedJwt(secret, {role: 'anon',iat:issuedAt,exp:expiresAt}), mailboxKey}, {
      database, secret, storage,
      async quiesce() {
        quiesced = true;
        await rest.stop(); await auth.stop(); await storage?.quiesce();
      },
    });
    await storage?.verify(database);
    if (verifyTraffic && (unexpectedPaths !== 0 || authRequests < 2 || restRequests < 1 || mailbox.count < 1)) {
      throw new Error(`Unexpected integration traffic: auth=${authRequests}, rest=${restRequests}, mail=${mailbox.count}, unsupported=${unexpectedPaths}`);
    }
    console.log(`${verifyTraffic ? 'PASS real' : 'Local'} ${storage ? 'Storage + ' : ''}Auth integration: ${authRequests} Auth requests, ${restRequests} PostgREST requests, ${storageRequests} Storage requests, ${mailbox.count} local messages`);
    return {authRequests, restRequests, storageRequests, mailCount: mailbox.count};
  } finally {
    await closeServer(gateway); await storage?.stop(); await auth?.stop(); await rest?.stop(); await mailbox?.stop();
    if (database) { await database.client.end(); await database.postgres.stop(); }
  }
}
