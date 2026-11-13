import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function pinyinImportCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(),auth=()=>login(user,'pinyin-import');
  await client.query('reset role');await client.query('insert into auth.users values($1,$2)',[user,'pinyin@example.test']);await auth();
  const family=await scalar("select public.onboard_family('Pinyin','Asia/Shanghai','小星',2::smallint)");
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await client.query("select public.set_parent_pin($1,'3579')",[family]);await client.query("select public.verify_parent_pin($1,'3579')",[family]);
  const word=(prompt='银行',reading='yín háng',context='我去银行存钱')=>({kind:'pinyin',subject:'chinese',prompt,context,answers:[reading],pronunciation_confirmed:true,knowledge_point:'拼音'});
  const sql='select public.import_pinyin_words($1,$2,$3)';
  const run=(entries,id=randomUUID(),kid=child)=>scalar(sql,[kid,id,JSON.stringify(entries)]);
  const count=()=>scalar('select count(*)::int from public.wrong_questions where child_id=$1',[child]);
  let first,requestId=randomUUID();
  await check('pinyin import validates every row and parent PIN with no partial questions or receipts on failure',async()=>{
    await login(user,'import-no-pin');await assert.rejects(run([word()]));await auth();
    for(const invalid of [[],Array.from({length:101},()=>word()),[word(),{...word('坏行'),pronunciation_confirmed:false}],
      [word(),{...word('坏行'),context:''}],[word(),{...word('坏行'),answers:['???']}],[{...word(),answers:[5]}],
      [{...word(),kind:'question'}],[{...word(),prompt:'词'.repeat(81)}]]) {
      await assert.rejects(run(invalid));assert.equal(await count(),0);
    }
    await denied('select * from public.pinyin_import_receipts');
    first=await run([word(),word('妈妈','mā ma','妈妈回家了')],requestId);
    assert.equal(first.created.length,2);assert.equal(first.skipped.length,0);assert.equal(await count(),2);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[child]),0);
  });
  await check('same request replay returns its receipt while duplicate imports preserve pronunciation mastery and archive state',async()=>{
    assert.deepEqual(await run([word(),word('妈妈','mā ma','妈妈回家了')],requestId),first);
    await assert.rejects(run([word('新词','xin1 ci2','新词')],requestId));
    const qid=first.created[0].question_id;
    await client.query('select public.archive_review_question($1,true)',[qid]);
    const before=await scalar('select public.review_question_editor($1)',[qid]);
    const skipped=await run([word('银行','yin2 hang2','我去银行存钱'),word()]);
    assert.equal(skipped.created.length,0);assert.equal(skipped.skipped.length,2);
    assert.deepEqual(await scalar('select public.review_question_editor($1)',[qid]),before);
    const different=await run([word('银行','yín háng','银行今天开门')]);assert.equal(different.created.length,1);
  });
  await check('two independent sessions importing the same batch or word create only one set',async()=>{
    const peer=new pg.Client(client.connectionParameters);await peer.connect();
    try{
      await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:'import-peer',iat:Math.floor(Date.now()/1000)})]);
      await peer.query('set role authenticated');await peer.query("select public.verify_parent_pin($1,'3579')",[family]);
      const key=randomUUID(),payload=[word('绿叶','lü4 ye4','树上长出绿叶')];
      const [a,b]=await Promise.all([client.query(sql,[child,key,JSON.stringify(payload)]),peer.query(sql,[child,key,JSON.stringify(payload)])]);
      assert.deepEqual(a.rows,b.rows);
      const other=[word('不是','bú shì','这不是书')];
      const [c,d]=await Promise.all([client.query(sql,[child,randomUUID(),JSON.stringify(other)]),peer.query(sql,[child,randomUUID(),JSON.stringify(other)])]);
      assert.equal(c.rows[0].import_pinyin_words.created.length+d.rows[0].import_pinyin_words.created.length,1);
      assert.equal(c.rows[0].import_pinyin_words.skipped.length+d.rows[0].import_pinyin_words.skipped.length,1);
    }finally{await peer.end();}
  });
  await check('imported words use private answer keys and the existing review and worksheet snapshots in all three directions',async()=>{
    const task=await scalar('select public.generate_daily_wrong_review_task($1)',[child]);
    const loaded=await scalar('select public.load_review_task($1)',[task]);
    assert.ok(loaded.items.some(i=>i.review_kind==='pinyin'));
    assert.ok(loaded.items.every(i=>i.accepted_answers===null));
    const mom=first.created[1].question_id;
    await client.query('select public.start_task($1)',[task]);
    const answered=await scalar('select public.submit_review_answer($1,$2,$3,$4)',[task,mom,'ma1 ma5',randomUUID()]);
    assert.equal(answered.items.find(i=>i.wrong_question_id===mom).result,true);
    // New words do not expand today's frozen question set.
    await run([word('一天','yì tiān','我等了一天')]);
    await scalar('select public.generate_daily_wrong_review_task($1)',[child]);
    assert.equal((await scalar('select public.load_review_task($1)',[task])).items.length,loaded.items.length);
    for(const mode of ['word_to_pinyin','pinyin_to_word','mixed']){
      const id=randomUUID();
      await client.query('select public.request_worksheet($1,$2,$3,$4)',[child,[mom],{title:'导入词语练习',pinyin_mode:mode,grid:'both',repeats:2,include_answers:true},id]);
      await client.query('reset role');
      const item=await scalar('select to_jsonb(i) from public.worksheet_items i where worksheet_id=$1',[id]);
      assert.equal(item.prompt,'妈妈');assert.deepEqual(item.accepted_answers,['mā ma']);await auth();
    }
  });
  await check('converting a Chinese wrong question keeps its identity and frozen history while resetting only future review',async()=>{
    const kid=await scalar("select public.create_child($1,'Convert',2::smallint)",[family]);
    const config={kind:'question',subject:'chinese',prompt:'给银行标注读音',answers:['yín háng']};
    const qid=await scalar('select public.save_review_question($1,$2)',[kid,config]);
    const task=await scalar('select public.generate_daily_wrong_review_task($1)',[kid]);
    const before=await scalar('select public.review_question_editor($1)',[qid]);
    await client.query('select public.save_review_question($1,$2,$3)',[kid,{...word(),expected_version:before.content_version},qid]);
    const after=await scalar('select public.review_question_editor($1)',[qid]);
    assert.equal(after.id,qid);assert.equal(after.review_kind,'pinyin');assert.equal(after.content_version,before.content_version+1);
    await denied('select public.save_review_question($1,$2,$3)',[kid,{...word(),expected_version:before.content_version},qid]);
    const snapshot=(await scalar('select public.load_review_task($1)',[task])).items[0];
    assert.equal(snapshot.prompt,'给银行标注读音');assert.equal(snapshot.review_kind,'question');
    await client.query('select public.start_task($1)',[task]);await client.query('select public.submit_review_answer($1,$2,$3,$4)',[task,qid,'yín háng',randomUUID()]);
    assert.equal((await scalar('select public.review_question_editor($1)',[qid])).review_attempts,0);
  });
  await check('receipt isolation and deletion prevent old imports from recreating removed words or child data',async()=>{
    await login(otherUid);await assert.rejects(run([word()],requestId));await auth();
    const kid=await scalar("select public.create_child($1,'Delete imported words',2::smallint)",[family]);
    const key=randomUUID(),receipt=await run([word()],key,kid),qid=receipt.created[0].question_id;
    await client.query('reset role');await client.query('delete from public.wrong_questions where id=$1',[qid]);await auth();
    assert.deepEqual(await run([word()],key,kid),receipt);
    assert.equal(await scalar('select count(*)::int from public.wrong_questions where id=$1',[qid]),0);
    await assert.rejects(run([word()],requestId,kid));
    const counts=(await scalar('select public.preview_child_deletion($1)',[kid])).counts;
    await client.query('select public.request_child_deletion($1,$2,$3,$4)',[kid,randomUUID(),counts,'永久删除孩子']);
    await assert.rejects(run([word()],key,kid));
    await client.query('reset role');assert.equal(await scalar('select count(*)::int from public.pinyin_import_receipts where child_id=$1',[kid]),0);await auth();
  });
}
