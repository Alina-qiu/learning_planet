import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import pg from 'pg';

export async function similarQuestionCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(),session='similar-parent';
  const auth=()=>login(user,session);
  const admin=async()=>{await client.query('reset role');await client.query(`select set_config('request.jwt.claims','{"role":"service_role"}',false)`);};
  const service=async()=>{await admin();await client.query('set role service_role');};
  await admin();await client.query('insert into auth.users values($1,$2)',[user,'similar@example.test']);
  await auth();await scalar("select public.onboard_family('Similar family','Asia/Shanghai','Child',3::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[user]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'1234')",[family]);await scalar("select public.verify_parent_pin($1,'1234')",[family]);
  const source=await scalar('select public.save_review_question($1,$2)',[child,{kind:'question',subject:'math',prompt:'8+7=?',answers:['15'],knowledge_point:'进位加法',explanation:'加法',difficulty:'easy'}]);
  const input=(await scalar('select public.similar_question_context($1)',[source])).input;
  let settings=await scalar('select public.read_ai_settings($1)',[family]);
  await scalar('select public.update_ai_settings($1,$2,$3)',[family,settings.version,{enabled:true,monthly_limit:100,budget_cents:20000,retention_days:7}]);
  await admin();await client.query("update public.ai_gateway_config set enabled=true,model='test-model',reserve_cents=100");
  let generation=0;
  const claim=async(data=input,id=randomUUID(),expected=generation)=>{await service();return scalar('select public.claim_ai_analysis($1,$2,$3,$4,$5,$6)',[user,session,child,id,data,expected]);};
  const output=(changes={})=>({model_version:'test-model',prompt_version:'similar-question-v1',confidence:.72,raw_output:'generated sample',safety_flags:[],
    structured_output:{subject:'math',prompt:'计算：9+6=?',answers:['15'],explanation:'9加1得10，再加5。',knowledge_point:'进位加法',difficulty:'easy',...changes}});
  const finish=async(c,o=output())=>{await service();await scalar('select public.finish_ai_analysis($1,$2,$3)',[c.request_id,c.token,o]);};
  const resolve=async(c,data=input)=>{await auth();return scalar("select public.resolve_ai_analysis($1,$2,$3,'inspect')",[child,c.request_id,data]);};
  const approve=async(c,config)=>{await auth();return scalar('select public.adopt_similar_question($1,$2,$3)',[child,c.request_id,config]);};
  const config={...output().structured_output,reviewed:true};
  let first,saved;

  await check('similar arithmetic uses exact rationals, precedence and bounds; unsupported semantics are never marked verified',async()=>{
    await admin();
    const verify=(prompt,answers,subject='math')=>scalar('select public.check_practice_answer($1,$2,$3)',[subject,prompt,JSON.stringify(answers)]);
    for(const [prompt,answers] of [['0.1+0.2=?',['0.3','3/10']],['计算：2×(3+4)=？',['14']],['1/3+1/6',['1/2','0.5']],['-3*-2+1',['7']],['2--3',['5']],['(1-4)/2',['-1.5','-3/2']]]) assert.equal((await verify(prompt,answers)).status,'passed',prompt);
    for(let a=-8;a<=8;a++)for(let b=1;b<=4;b++) assert.equal((await verify(`(${a}+${b})*2`,[String((a+b)*2)])).status,'passed');
    for(const [prompt,answers] of [['2+2',['5']],['2+2',['4','5']],['1/0',['0']],['1..2+3',['4']],['2(3+4)',['14']],['('.repeat(30)+'1'+')'.repeat(30),['1']]]) assert.equal((await verify(prompt,answers)).status,'failed',prompt);
    assert.equal((await verify('有2个苹果，又买3个，现有多少？',['5'])).status,'manual');
    assert.equal((await verify('2+3',['5个'])).status,'manual');
    assert.equal((await verify('drop table public.wallets',['x'])).status,'manual');
    assert.equal((await verify('读一读“行”',['xing2'],'chinese')).status,'manual');
    await auth();await denied('select public.practice_calculate($1)',['2+2']);
    assert.equal((await scalar('select public.preview_practice_answer($1,$2)',[child,config])).status,'passed');
  });
  await check('similar retrieval returns only current child non-archived candidates and no answer keys',async()=>{
    await auth();
    const exact=await scalar('select public.save_review_question($1,$2)',[child,{kind:'question',subject:'math',prompt:'7+8=?',answers:['15'],knowledge_point:'进位加法'}]);
    const general=await scalar('select public.save_review_question($1,$2)',[child,{kind:'question',subject:'math',prompt:'2*3=?',answers:['6'],knowledge_point:'乘法'}]);
    await scalar('select public.save_review_question($1,$2)',[child,{kind:'question',subject:'english',prompt:'spell cat',answers:['cat']}]);
    let result=await scalar('select public.find_similar_questions($1)',[source]);
    assert.deepEqual(result.items.map(q=>q.id),[exact,general]);assert.equal(result.items[0].match_reason,'knowledge');
    assert.equal(JSON.stringify(result).includes('answers'),false);assert.equal(JSON.stringify(result).includes('explanation'),false);
    assert.deepEqual((await scalar('select public.find_similar_questions($1,$2)',[source,'乘法'])).items.map(q=>q.id),[general]);
    await scalar('select public.archive_review_question($1,true)',[exact]);
    assert.deepEqual((await scalar('select public.find_similar_questions($1)',[source])).items.map(q=>q.id),[general]);
    await login(otherUid);await denied('select public.similar_question_context($1)',[source]);await denied('select public.find_similar_questions($1)',[source]);
    await login(user,'expired-similar');await denied('select public.find_similar_questions($1)',[source]);await auth();
    for(const t of ['similar_question_adoptions','question_ai_origins','ai_result_feedback'])await denied(`select * from public.${t}`);
  });
  await check('generation binds original version and purpose, shares quota, computes results and redacts unsafe output',async()=>{
    await service();await denied('select public.claim_ai_analysis($1,$2,$3,$4,$5)',[user,session,child,randomUUID(),{...input,source_version:9}]);
    await denied('select public.claim_ai_analysis($1,$2,$3,$4,$5)',[user,session,child,randomUUID(),{...input,text:'invented source'}]);
    first=await claim();assert.equal(first.prompt_version,'similar-question-v1');
    assert.equal((await claim(input,first.request_id)).status,'running');
    await finish(first);const receipt=await resolve(first);assert.equal(receipt.result.structured_output.answer_check.status,'passed');
    assert.equal((await scalar('select public.read_ai_settings($1)',[family])).requests,1);
    const refusal=await claim();await finish(refusal,{...output(),raw_output:'',structured_output:{},safety_flags:['refused'],confidence:0});
    await auth();await denied('select public.adopt_similar_question($1,$2,$3)',[child,refusal.request_id,config]);
    const classification=await claim({text:'2+3=?',subject:'math'});assert.equal(classification.prompt_version,'question-structure-v1');
    await auth();assert.equal((await scalar('select public.read_ai_settings($1)',[family])).requests,3);
  });
  await check('approval rejects wrong numeric answers, requires review, is idempotent and does not reward',async()=>{
    await auth();const wallet=await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]);
    for(const bad of [{...config,answers:['14']},{...config,reviewed:false},{...config,ocr_draft_id:randomUUID()},{...config,subject:'english'}]) await denied('select public.adopt_similar_question($1,$2,$3)',[child,first.request_id,bad]);
    saved=await approve(first,config);assert.equal(saved.status,'saved');
    assert.deepEqual(await approve(first,config),saved);
    await denied('select public.adopt_similar_question($1,$2,$3)',[child,first.request_id,{...config,prompt:'1+1=?'}]);
    assert.deepEqual(await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]),wallet);
    const edited=await scalar('select public.review_question_editor($1)',[saved.question_id]);
    assert.equal(edited.ai_generated,true);assert.equal(edited.ai_origin.source_question_id,source);assert.equal(edited.ai_origin.prompt_version,'similar-question-v1');
    assert.equal(edited.ai_origin.answer_check.status,'passed');
  });
  await check('parallel approvals create one question; saved math edits recheck answers and immutable snapshots show AI label',async()=>{
    const c=await claim();await finish(c);
    const peer=new pg.Client(client.connectionParameters);await peer.connect();
    try{
      await peer.query('set role authenticated');await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:session})]);
      await auth();
      const calls=await Promise.all([scalar('select public.adopt_similar_question($1,$2,$3)',[child,c.request_id,config]),peer.query('select public.adopt_similar_question($1,$2,$3) value',[child,c.request_id,config]).then(r=>r.rows[0].value)]);
      assert.deepEqual(calls[0],calls[1]);
    }finally{await peer.end();}
    await auth();
    await denied('select public.save_review_question($1,$2,$3)',[child,{...config,kind:'question',answers:['99']},saved.question_id]);
    await scalar('select public.save_review_question($1,$2,$3)',[child,{...config,kind:'question',prompt:'10+5=?'},saved.question_id]);
    const edited=await scalar('select public.review_question_editor($1)',[saved.question_id]);
    assert.equal(edited.ai_generated,true);assert.equal(edited.ai_origin.last_reviewed_version,edited.content_version);
    await scalar('select public.generate_daily_wrong_review_task($1,public.family_today($1)::date)',[child]);
    await admin();
    assert.match(await scalar('select prompt from public.task_review_items where wrong_question_id=$1 limit 1',[saved.question_id]),/^【AI生成·家长已审核】/);
    const worksheet=randomUUID();await auth();
    await scalar('select public.request_worksheet($1,$2,$3,$4)',[child,[saved.question_id],{title:'练习',include_answers:true,include_explanations:true},worksheet]);
    await admin();assert.match(await scalar('select prompt from public.worksheet_items where worksheet_id=$1',[worksheet]),/^【AI生成·家长已审核】/);
  });
  await check('failed arithmetic output can be edited and rechecked; open questions remain explicit manual reviews',async()=>{
    const c=await claim();await finish(c,output({answers:['999']}));assert.equal((await resolve(c)).result.structured_output.answer_check.status,'failed');
    const corrected=await approve(c,config);assert.equal(corrected.status,'saved');
    const manual=await claim();await finish(manual,output({prompt:'有9颗糖，再买6颗，现在有几颗？'}));
    assert.equal((await resolve(manual)).result.structured_output.answer_check.status,'manual');
    assert.equal((await approve(manual,{...config,prompt:'有9颗糖，再买6颗，现在有几颗？'})).status,'saved');
  });
  await check('feedback and provenance export without extra identity fields; cancellation prevents delayed approval',async()=>{
    await auth();await scalar("select public.feedback_ai_result($1,$2,'wrong_answer')",[child,first.request_id]);
    await scalar("select public.feedback_ai_result($1,$2,'unclear')",[child,first.request_id]);
    await denied('select public.feedback_ai_result($1,$2,$3)',[child,first.request_id,'private free text']);
    const c=await claim();await finish(c);await auth();
    await scalar("select public.resolve_ai_analysis($1,$2,$3,'cancel')",[child,c.request_id,input]);
    await denied('select public.adopt_similar_question($1,$2,$3)',[child,c.request_id,config]);
    await admin();const sections=await scalar('select public.child_export_source($1)',[child]);
    assert.equal(sections.length,40);assert.ok(sections.find(s=>s.name==='ai_question_origins').rows.length>=1);
    assert.equal(sections.find(s=>s.name==='ai_feedback').rows[0].reason,'unclear');
    assert.equal(JSON.stringify(sections.find(s=>s.name==='ai_question_adoptions')).includes('config_hash'),false);
  });
  await check('permanent cleanup erases adopted answers and pending output but keeps receipt to prevent recreation',async()=>{
    const pending=await claim();
    await auth();const job=randomUUID();
    await scalar("select public.request_question_cleanup($1,'questions',$2,$3,'永久删除')",[child,[saved.question_id],job]);
    generation=(await scalar('select public.read_ai_context($1)',[child])).generation;
    assert.equal(generation,1);await finish(pending);
    await service();const lease=await scalar('select public.claim_cleanup_job($1)',[job]);
    await scalar('select public.finish_cleanup_job($1,$2)',[job,lease.token??lease.lease_token]);
    await auth();assert.equal((await approve(first,config)).status,'deleted');
    assert.equal((await scalar('select public.inspect_similar_adoption($1,$2)',[child,first.request_id])).status,'deleted');
    await admin();assert.equal(await scalar('select count(*)::int from public.question_ai_origins where question_id=$1',[saved.question_id]),0);
    assert.equal(await scalar('select result from public.ai_analysis_requests where id=$1',[pending.request_id]),null);
  });
  await check('AI off and retention fence unsaved suggestions while preserving independently approved questions',async()=>{
    const c=await claim();await finish(c);await auth();settings=await scalar('select public.read_ai_settings($1)',[family]);
    await scalar('select public.update_ai_settings($1,$2,$3)',[family,settings.version,{enabled:false,monthly_limit:100,budget_cents:20000,retention_days:7}]);
    await denied('select public.adopt_similar_question($1,$2,$3)',[child,c.request_id,config]);
    assert.equal((await scalar('select public.inspect_similar_adoption($1,$2)',[child,first.request_id])).status,'deleted');
    await admin();assert.ok(await scalar('select count(*)::int from public.wrong_questions where child_id=$1 and ai_generated',[child])>=1);
    const counts=(await scalar('select public.child_deletion_source($1)',[child])).counts;
    assert.ok(counts.ai_adoptions>=1);assert.equal(counts.ai_feedback,1);
  });
  await check('child deletion removes generated provenance, adoption receipts and feedback through real deletion workflow',async()=>{
    await auth();const preview=await scalar('select public.preview_child_deletion($1)',[child]);
    assert.ok(preview.counts.ai_adoptions>0);assert.equal(preview.counts.ai_feedback,1);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[child,randomUUID(),preview.counts]);
    await admin();for(const table of ['question_ai_origins','similar_question_adoptions','ai_result_feedback','ai_analysis_requests'])
      assert.equal(await scalar(`select count(*)::int from public.${table} where child_id=$1`,[child]),0,table);
  });
  await auth();
}
