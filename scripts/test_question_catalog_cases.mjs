import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function questionCatalogCases({client,scalar,login,denied,check,otherUid}) {
  const owner=randomUUID(),member=randomUUID();await client.query('reset role');
  for(const id of [owner,member]) await client.query('insert into auth.users values($1,$2)',[id,`${id}@catalog.test`]);
  const auth=()=>login(owner,'catalog');await auth();await scalar("select public.onboard_family('Catalog','Asia/Shanghai','Child',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'2468')",[family]);await scalar("select public.verify_parent_pin($1,'2468')",[family]);
  const privateQuestion=await scalar('select public.save_review_question($1,$2)',[child,{kind:'question',subject:'math',prompt:'100%_原题',answers:['PRIVATE GRADING ANSWER'],knowledge_point:'两位数减法',error_reason_tags:['handwriting'],error_reason:'注意借位'}]);
  const pinyin=await scalar('select public.save_review_question($1,$2)',[child,{kind:'pinyin',subject:'chinese',prompt:'银行',answers:['yín háng'],context:'我去银行存钱',pronunciation_confirmed:true}]);
  await client.query('reset role');
  await client.query(`insert into public.wrong_questions(child_id,subject,final_text,review_kind,archived,review_due_at)
    select $1,'math','题目 '||n,'question',n%3=0,case when n%5=0 then null else '2026-10-01'::timestamptz end from generate_series(1,1006) n`,[child]);
  await client.query("insert into public.family_members(family_id,user_id,role) values($1,$2,'parent')",[family,member]);
  await login(owner,'without-pin');
  const filters={kind:'question',subject:'all',mastery:'all',archive:'all',keyword:''};
  const page=(f=filters,cursor=null)=>scalar('select public.question_catalog_page($1,$2,$3)',[child,f,cursor]);
  await check('catalog keyset pages cover over 1000 tied due dates null dates and both archive states without answer keys',async()=>{
    const wallet=await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]);
    const ids=[];let cursor=null;
    do {const result=await page(filters,cursor);assert.equal(result.owner_id,owner);assert.equal(result.child_id,child);assert.equal(result.family_id,family);assert.deepEqual(result.filters,filters);assert.ok(Date.parse(result.server_time));
      assert.ok(result.items.length<=50);assert.ok(!JSON.stringify(result).includes('PRIVATE GRADING ANSWER'));assert.ok(result.items.every(r=>r.review_kind==='question'&&!('answers' in r)&&!('accepted_answers' in r)));
      ids.push(...result.items.map(r=>r.id));cursor=result.next_cursor;
      if(cursor){assert.equal(result.items.length,50);assert.deepEqual(cursor,{id:result.items.at(-1).id,archived:result.items.at(-1).archived,due_at:result.items.at(-1).review_due_at});}
    }while(cursor);
    assert.equal(ids.length,1007);assert.equal(new Set(ids).size,1007);
    assert.deepEqual(ids,(await client.query("select id from public.wrong_questions where child_id=$1 and review_kind='question' order by archived,review_due_at nulls last,id",[child])).rows.map(r=>r.id));
    assert.deepEqual(await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]),wallet);
  });
  await check('catalog filters preserve literal keywords pinyin context subject mastery and Chinese reason labels',async()=>{
    for(const keyword of ['%','_原题','借位','减法','书写']) assert.deepEqual((await page({...filters,keyword})).items.map(r=>r.id),[privateQuestion]);
    assert.equal((await page({...filters,subject:'english'})).items.length,0);
    assert.ok((await page({...filters,archive:'archived'})).items.every(r=>r.archived));
    assert.ok((await page({...filters,archive:'active'})).items.every(r=>!r.archived));
    assert.equal((await page({...filters,mastery:'mastered'})).items.length,0);
    const words=await page({...filters,kind:'pinyin',keyword:'存钱'});assert.deepEqual(words.items.map(r=>r.id),[pinyin]);
    assert.equal((await page({...filters,keyword:'存钱'})).items.length,0);
  });
  await check('catalog cursor does not shift after a preceding row is inserted or removed',async()=>{
    const first=await page(),second=await page(filters,first.next_cursor);
    await client.query('reset role');await client.query('delete from public.wrong_questions where id=$1',[first.items[0].id]);
    await client.query("insert into public.wrong_questions(child_id,subject,final_text,review_kind,review_due_at) values($1,'math','New first','question','2000-01-01')",[child]);
    await login(owner,'without-pin');assert.deepEqual((await page(filters,first.next_cursor)).items.map(r=>r.id),second.items.map(r=>r.id));
  });
  await check('catalog validates all filters and cursor types and denies foreign anonymous and service roles',async()=>{
    for(const f of [{...filters,kind:'all'},{...filters,subject:'science'},{...filters,mastery:'bad'},{...filters,archive:'bad'},{...filters,keyword:'x'.repeat(101)},{...filters,keyword:null},{...filters,answers:true},null]) await denied('select public.question_catalog_page($1,$2,null)',[child,f]);
    for(const cursor of [{id:randomUUID(),archived:'false',due_at:null},{id:randomUUID(),archived:false},{id:randomUUID(),archived:false,due_at:'infinity'},{id:'invalid',archived:false,due_at:null}])await denied('select public.question_catalog_page($1,$2,$3)',[child,filters,cursor]);
    await login(otherUid);await denied('select public.question_catalog_page($1,$2,null)',[child,filters]);
    for(const role of ['anon','service_role']){await client.query('reset role');await client.query('set role '+role);await denied('select public.question_catalog_page($1,$2,null)',[child,filters]);}
  });
  await check('catalog reads without PIN still respect removed family members and deleted children',async()=>{
    await login(member,'member');assert.ok((await page()).items.length);
    await client.query('reset role');await client.query('delete from public.family_members where family_id=$1 and user_id=$2',[family,member]);
    await login(member,'member');await denied('select public.question_catalog_page($1,$2,null)',[child,filters]);
    await auth();const preview=await scalar('select public.preview_child_deletion($1)',[child]);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[child,randomUUID(),preview.counts]);
    await denied('select public.question_catalog_page($1,$2,null)',[child,filters]);await login();
  });
}
