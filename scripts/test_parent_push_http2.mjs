import assert from 'node:assert/strict';
import { createSecureServer } from 'node:http2';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve, sep, basename } from 'node:path';
import { generateKeyPairSync, verify } from 'node:crypto';

const exec=promisify(execFile),directory=await mkdtemp(join(tmpdir(),'learning-planet-push-tls-'));
const certificate=join(directory,'certificate.pem'),keyStore=join(directory,'server.p12'),password='local-test-only-password';
const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
let server,requests=0;
try {
  const keytool=process.env.JAVA_HOME?join(process.env.JAVA_HOME,'bin',process.platform==='win32'?'keytool.exe':'keytool'):'keytool';
  await exec(keytool,['-genkeypair','-alias','local-test','-keyalg','RSA','-keysize','2048','-validity','1',
    '-dname','CN=localhost','-ext','SAN=IP:127.0.0.1,DNS:localhost','-storetype','PKCS12','-keystore',keyStore,
    '-storepass',password,'-keypass',password,'-noprompt'],{windowsHide:true,timeout:20000});
  await exec(keytool,['-exportcert','-rfc','-alias','local-test','-keystore',keyStore,'-storepass',password,'-file',certificate],
    {windowsHide:true,timeout:20000});
  server=createSecureServer({pfx:await readFile(keyStore),passphrase:password,allowHTTP1:false});
  server.on('stream',async(stream,headers)=>{
    try {
      requests++;assert.equal(stream.session.alpnProtocol,'h2');assert.equal(headers[':method'],'POST');
      assert.equal(headers[':path'],`/3/device/${'a'.repeat(64)}`);assert.equal(headers['apns-push-type'],'background');
      assert.equal(headers['apns-priority'],'5');assert.equal(headers['apns-expiration'],'0');
      const [header,payload,signature]=headers.authorization.slice(7).split('.');
      assert.ok(verify('sha256',Buffer.from(`${header}.${payload}`),{key:publicKey,dsaEncoding:'ieee-p1363'},Buffer.from(signature,'base64url')));
      const buffers=[];for await(const bytes of stream) buffers.push(bytes);
      const body=JSON.parse(Buffer.concat(buffers));assert.deepEqual(body.aps,{'content-available':1});
      assert.equal(body.message_id,headers['apns-id']);stream.respond({':status':200});stream.end();
    } catch {stream.respond({':status':400});stream.end('{"reason":"LOCAL_ASSERTION_FAILED"}');}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const env={...process.env};for(const name of Object.keys(env)) if(name.startsWith('PARENT_PUSH_')) delete env[name];
  Object.assign(env,{PARENT_PUSH_APNS_KEY:privateKey.export({format:'pem',type:'pkcs8'}),PARENT_PUSH_APNS_KEY_ID:'ABC1234567',
    PARENT_PUSH_APNS_TEAM_ID:'DEF1234567',PARENT_PUSH_APNS_TOPIC:'com.learningplanet.learning_planet',PARENT_PUSH_APNS_ENVIRONMENT:'sandbox',
    TEST_PUSH_ORIGIN:`https://127.0.0.1:${server.address().port}`,TEST_PUSH_CERT:certificate});
  const binary=process.platform==='win32'?resolve('node_modules/deno/deno.exe'):resolve('node_modules/.bin/deno');
  await exec(binary,['run','--cached-only','--cert',certificate,'--allow-env=PARENT_PUSH_HMS_APP_ID,PARENT_PUSH_HMS_APP_SECRET,PARENT_PUSH_APNS_KEY,PARENT_PUSH_APNS_KEY_ID,PARENT_PUSH_APNS_TEAM_ID,PARENT_PUSH_APNS_TOPIC,PARENT_PUSH_APNS_ENVIRONMENT,PARENT_PUSH_GATEWAY_URL,PARENT_PUSH_GATEWAY_KEY,TEST_PUSH_ORIGIN,TEST_PUSH_CERT',
    `--allow-read=${certificate}`,`--allow-net=127.0.0.1:${server.address().port}`,'scripts/fixtures/parent_push_http2.mjs'],
  {windowsHide:true,env,timeout:20000});
  assert.equal(requests,1);
  console.log('APNs HTTP/2 local TLS smoke passed: actual Deno fetch, verified ES256 JWT and background-only headers. No Apple service was accessed.');
} finally {
  if(server) await new Promise(resolve=>server.close(resolve));
  const owned=resolve(directory);
  if(dirname(owned)!==resolve(tmpdir()) || !basename(owned).startsWith('learning-planet-push-tls-') || !owned.startsWith(resolve(tmpdir())+sep))
    throw new Error('Refusing cleanup outside test temporary directory');
  await rm(owned,{recursive:true,force:true});
}
