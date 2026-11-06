// Actual repositories + Deno rendering + Storage bytes, followed by retention/source cleanup.
import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {createServer, request as upstreamRequest} from 'node:http';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {PDFDocument} from 'pdf-lib';
import {renderWorksheet} from '../supabase/functions/_shared/worksheet_pdf.mjs';
import {withAuthBackend} from './fixtures/auth_backend.mjs';
import {createStorageBackend} from './fixtures/storage_backend.mjs';
import {realApiClient} from './fixtures/real_api_client.mjs';
import {startLocalEdge} from './fixtures/local_edge.mjs';
import {closeServer, forwardHttp, listen, runFlutter, signedJwt} from './fixtures/http_test_tools.mjs';

let checks = 0;
await withAuthBackend(async (config, {database, secret, storage}) => {
  const {url, anon} = config, sql = database.client;
  await sql.query('grant service_role to http_authenticator');
  const service = signedJwt(secret, {role: 'service_role'});
  const {api, rpc, account, family} = realApiClient(config);
  const owner = await account(), other = await account(), scope = await family(owner);
  const question = async input => rpc('save_review_question', owner.token, {target_child_id: scope.child, config: input});
  const math = {kind: 'question', subject: 'math', prompt: '小明有12支铅笔，又买了8支。他一共有多少支铅笔？请列式计算。',
    answers: ['20'], explanation: '12 + 8 = 20，用加法求总数。', ocr_confirmed: true};
  const mathId = await question(math);
  const word = (prompt, reading, context) => ({kind:'pinyin',subject:'chinese',prompt,context,answers:[reading],pronunciation_confirmed:true});
  const green = await question(word('绿叶', 'lǜ yè', '树上长出了绿叶。'));
  const bank = await question(word('银行', 'yín háng', '我去银行存钱。'));
  const mixedId = randomUUID(), retryId = randomUUID();
  const mixedConfig = {title:'错题与拼音练习',include_answers:true,include_explanations:true,pinyin_mode:'word_to_pinyin'};
  const retryConfig = {title:'拼音默写练习',orientation:'landscape',pinyin_mode:'pinyin_to_word',grid:'tianzige',repeats:2,
    include_answers:false,include_explanations:false};
  async function enqueue(id, ids, configuration) {
    assert.equal(await rpc('request_worksheet', owner.token, {target_child_id:scope.child,question_ids:ids,config:configuration,request_id:id}), id);
  }
  await enqueue(mixedId,[green,mathId,bank],mixedConfig);
  await enqueue(retryId,[bank,green],retryConfig);
  // A later edit must not replace the ordered, confirmed snapshot already queued.
  await rpc('save_review_question', owner.token, {target_child_id:scope.child,target_question_id:mathId,
    config:{...math,prompt:'修改后的题干，不应出现在已冻结的试卷中。',answers:['99']}});
  let blockUpload=true, loseFinishReply=true, blockedUploads=0, lostFinishReplies=0, stateReads=0;
  let renderer, cleanup;
  const gatewayPort=Number(new URL(url).port);
  const proxy=createServer((incoming,outgoing)=>{
    if (incoming.url.startsWith('/functions/v1/worksheet-render') && renderer) {
      forwardHttp(incoming,outgoing,renderer.port,'/functions/v1');return;
    }
    if (incoming.url.startsWith('/functions/v1/permanent-cleanup') && cleanup) {
      forwardHttp(incoming,outgoing,cleanup.port,'/functions/v1');return;
    }
    if(blockUpload && incoming.method==='POST' && incoming.url.startsWith('/storage/v1/object/worksheets/')) {
      blockedUploads++;incoming.resume();outgoing.writeHead(503,{'Content-Type':'application/json'});
      outgoing.end(JSON.stringify({statusCode:'503',error:'Unavailable',message:'Injected upload failure'}));return;
    }
    if(incoming.url.startsWith('/rest/v1/worksheet_jobs?') && incoming.headers.authorization===`Bearer ${service}`) stateReads++;
    if(loseFinishReply && incoming.url==='/rest/v1/rpc/finish_worksheet') {
      const chunks=[];incoming.on('data',chunk=>chunks.push(chunk));
      incoming.on('end',()=>{
        const body=Buffer.concat(chunks), payload=JSON.parse(body.toString());
        const upstream=upstreamRequest({hostname:'127.0.0.1',port:gatewayPort,path:incoming.url,method:incoming.method,
          headers:incoming.headers},response=>{
          const responseChunks=[];response.on('data',chunk=>responseChunks.push(chunk));
          response.on('end',()=>{
            if(![200,204].includes(response.statusCode)) {
              const result=JSON.parse(Buffer.concat(responseChunks).toString());
              console.error('Worksheet finish rejected:',{status:response.statusCode,code:result.code,message:result.message});
            }
            if([200,204].includes(response.statusCode) && !payload.result.error_code) {
              loseFinishReply=false;lostFinishReplies++;outgoing.writeHead(503,{'Content-Type':'application/json'});
              outgoing.end(JSON.stringify({code:'ACK_LOST',message:'Injected lost commit reply'}));
            } else {outgoing.writeHead(response.statusCode,response.headers);outgoing.end(Buffer.concat(responseChunks));}
          });
        });
        upstream.on('error',()=>{outgoing.writeHead(502);outgoing.end();});upstream.end(body);
      });return;
    }
    forwardHttp(incoming,outgoing,gatewayPort,'');
  });
  async function row(id) {return (await sql.query('select * from public.worksheet_jobs where id=$1',[id])).rows[0];}
  async function waitState(id,status) {
    for(let attempt=0;attempt<300;attempt++) {
      const job=await row(id);
      if(job.status===status)return job;
      if(job.status==='failed' && status!=='failed')throw new Error(`PDF worker failed: ${job.error_code}`);
      await delay(100);
    }
    throw new Error(`PDF did not become ${status}: ${(await row(id)).status}`);
  }
  function passed(message){checks++;console.log(`PASS ${message}`);}
  const output=resolve('output/pdf');
  await mkdir(output,{recursive:true});
  try {
    await listen(proxy);
    const clientUrl=`http://127.0.0.1:${proxy.address().port}`;
    renderer=await startLocalEdge('worksheet',{url:clientUrl,anon,service});
    cleanup=await startLocalEdge('cleanup',{url:clientUrl,anon,service});
    assert.equal((await renderer.post(other.token,{worksheet_id:mixedId})).status,403);
    assert.equal((await renderer.post(owner.token,{mode:'drain'})).status,403);
    assert.equal((await renderer.post(owner.token,{worksheet_id:retryId})).status,202);
    const failed=await waitState(retryId,'failed');
    assert.equal(failed.error_code,'PDF_UPLOAD_FAILED');assert.ok(blockedUploads>0);
    assert.deepEqual(await storage.inspectObjects(),[]);
    passed('actual Deno renderer reports upload failure without a ready PDF or orphan object');
    blockUpload=false;stateReads=0;
    await runFlutter('scripts/fixtures/worksheet_client_test.dart',{
      url:clientUrl,anon,owner:owner.session,other:other.session,child:scope.child,mixedId,retryId,
      retryIds:[bank,green],retryConfig,output,
    },'LP_WORKSHEET_CONFIG');
    assert.equal(lostFinishReplies,1);assert.ok(stateReads>0,'Worker must re-read committed metadata after the lost reply');
    const results=[];
    for(const [id,filename] of [[mixedId,'local-service-mixed.pdf'],[retryId,'local-service-pinyin.pdf']]) {
      const job=await waitState(id,'ready');
      const bytes=await readFile(join(output,filename));
      assert.equal(createHash('sha256').update(bytes).digest('hex'),job.sha256);
      assert.equal(bytes.length,Number(job.byte_size));assert.equal(job.progress,100);
      const snapshot=(await sql.query(`select jsonb_build_object('id',j.id,'created_at',j.created_at,'config',j.config,
        'items',(select jsonb_agg(to_jsonb(i) order by sequence) from public.worksheet_items i where i.worksheet_id=j.id)) snapshot
        from public.worksheet_jobs j where id=$1`,[id])).rows[0].snapshot;
      const expected=await renderWorksheet(snapshot,await readFile('supabase/functions/worksheet-render/fonts/NotoSansSC-Regular.ttf'));
      assert.deepEqual(Buffer.from(expected.bytes),bytes,'Deno output and frozen Node snapshot must be byte-identical');
      const pdf=await PDFDocument.load(bytes);assert.equal(pdf.getPageCount(),job.pages);
      const content=expected.trace.map(line=>line.text).join('\n');
      if(id===mixedId) {
        assert.ok(content.includes(math.prompt.slice(0,10)));assert.ok(!content.includes('修改后的题干'));
        assert.ok(content.includes('20'));assert.ok(content.includes('lǜ yè') && content.includes('yín háng'));
        assert.deepEqual(snapshot.items.map(item=>item.question_id),[green,mathId,bank]);
        assert.ok(pdf.getPages()[0].getWidth()<pdf.getPages()[0].getHeight());
      } else {
        assert.ok(content.includes('lǜ yè') && content.includes('yín háng'));
        assert.ok(!content.includes('银行') && !content.includes('绿叶') && !content.includes('答案：'));
        assert.ok(pdf.getPages()[0].getWidth()>pdf.getPages()[0].getHeight());
      }
      results.push({filename,pages:job.pages,bytes:Number(job.byte_size),sha256:job.sha256,renderer:job.renderer_version});
    }
    const files=await storage.inspectObjects();assert.equal(files.length,2);
    assert.equal((await row(retryId)).attempts,2);
    assert.equal((await sql.query('select count(*)::int n from public.worksheet_jobs')).rows[0].n,2);
    passed('app repository retries the same job and exports exact frozen Chinese/pinyin PDF bytes despite a lost finish reply');
    await writeFile(join(output,'local-service-pdf-validation.json'),JSON.stringify(results,null,2)+'\n');

    const retry=await row(retryId),mixed=await row(mixedId);
    async function signed(path) {
      const result=await api(`/storage/v1/object/sign/worksheets/${path}`,owner.token,{method:'POST',body:{expiresIn:300}});
      assert.equal(result.status,200);return `${url}/storage/v1${result.data.signedURL}`;
    }
    const retryUrl=await signed(retry.pdf_path),mixedUrl=await signed(mixed.pdf_path);
    assert.equal((await fetch(retryUrl)).status,200);
    // Advance this synthetic file's expiry; production's 30-day retention is unchanged.
    await sql.query("update public.worksheet_jobs set expires_at=now()-interval '1 second' where id=$1",[retryId]);
    assert.ok([400,403,404].includes((await api(`/storage/v1/object/authenticated/worksheets/${retry.pdf_path}`,owner.token)).status));
    assert.equal((await cleanup.post(service,{mode:'drain'})).status,202);
    await waitState(retryId,'deleted');
    assert.ok([400,404].includes((await fetch(retryUrl)).status));
    const retained=await storage.inspectObjects();assert.equal(retained.length,1);assert.ok(retained[0].key.includes(mixedId));
    assert.equal((await fetch(mixedUrl)).status,200);
    passed('expired PDF access is denied and trusted retention drain deletes only that file from S3');

    const deleteJob=randomUUID();
    assert.equal(await rpc('request_question_cleanup',owner.token,{target_child_id:scope.child,operation:'questions',ids:[mathId],
      request_id:deleteJob,confirmation:'永久删除'}),deleteJob);
    assert.equal((await row(mixedId)).status,'deleting');
    assert.equal((await renderer.post(owner.token,{worksheet_id:mixedId})).status,403);
    assert.equal((await cleanup.post(owner.token,{job_id:deleteJob})).status,202);
    await waitState(mixedId,'deleted');
    assert.ok([400,404].includes((await fetch(mixedUrl)).status));
    assert.deepEqual(await storage.inspectObjects(),[]);
    assert.equal((await sql.query('select count(*)::int n from public.worksheet_items')).rows[0].n,0);
    assert.equal((await sql.query('select count(*)::int n from storage.objects')).rows[0].n,0);
    passed('source-question deletion revokes and physically removes the associated PDF and answer snapshots');
  } finally {await renderer?.stop();await cleanup?.stop();await closeServer(proxy);}
},{createStorage:args=>createStorageBackend({...args,minimumObjects:0})});
console.log(`All ${checks} real PDF service checks passed; two downloaded samples remain for visual QA.`);
