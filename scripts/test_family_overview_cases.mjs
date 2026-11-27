import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export async function familyOverviewCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(), parent=randomUUID(), outsider=randomUUID();
  await client.query('reset role');
  for(const id of [owner,parent,outsider]) await client.query('insert into auth.users values($1,$2)',[id,`${id}@example.test`]);
  const auth=()=>login(owner,'overview'); await auth();
  await scalar("select public.onboard_family('Overview family','Pacific/Kiritimati','Older',2::smallint)");
  const family=await scalar('select family_id from public.family_members where user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'1234')",[family]);
  const pin=()=>scalar("select public.verify_parent_pin($1,'1234')",[family]); await pin();
  const sibling=await scalar("select public.create_child($1,'Younger',2::smallint)",[family]);
  const empty=await scalar("select public.create_child($1,'No tasks',2::smallint)",[family]);
  const report=()=>scalar('select public.family_overview($1)',[family]);
  const today=await scalar('select public.family_today($1)::text',[child]);
  await client.query('reset role');
  await client.query("insert into public.family_members values($1,$2,'parent')",[family,parent]);
  const template=await scalar("insert into public.task_templates(child_id,title) values($1,'Leave template') returning id",[child]);
  const plan=await scalar('insert into public.long_plans(template_id,minimum_rate,bonus_coins,bonus_xp) values($1,1,0,0) returning id',[template]);
  await client.query("insert into public.plan_leaves values($1,$2,'Family leave')",[plan,today]);
  async function task(id, offset, status, templateId=null) {
    await client.query(`insert into public.task_instances(child_id,title,due_date,source_type,status,idempotency_key,template_id)
      values($1,'Private task text',$2::date+$3::integer,'parent_template',$4,$5,$6)`,[id,today,offset,status,randomUUID(),templateId]);
  }
  await task(child,0,'completed'); await task(child,0,'abandoned'); await task(child,0,'skipped',template);
  await task(child,-1,'completed'); await task(child,-6,'skipped'); await task(child,-7,'completed'); await task(child,1,'completed');
  await task(sibling,0,'completed');
  const reward=await scalar("insert into public.rewards(family_id,title,cost) values($1,'Private reward',1) returning id",[family]);
  for(const [id,status,expiration] of [[child,'requested',1],[child,'approved',1],[child,'requested',-1],[child,'approved',-1],[sibling,'requested',1]]) {
    await client.query(`insert into public.redemptions(reward_id,child_id,status,frozen_amount,expires_at)
      values($1,$2,$3,1,now()+make_interval(days=>$4))`,[reward,id,status,expiration]);
  }
  await client.query(`insert into public.redemptions(reward_id,child_id,status,frozen_amount)
    select $1,$2,'fulfilled',1 from generate_series(1,1000)`,[reward,child]);
  for(const [id,amount,status] of [[child,20,'pending'],[child,30,'pending'],[child,99,'approved'],[sibling,7,'pending']]) {
    await client.query(`insert into public.pending_coin_awards(child_id,amount,status,source_type,source_key)
      values($1,$2,$3,'parent_template',$4)`,[id,amount,status,randomUUID()]);
  }
  await auth();
  await check('family overview uses seven family dates, excludes approved leave and keeps skipped or abandoned work',async()=>{
    const r=await report(), first=r.children.find(c=>c.child_id===child);
    assert.equal(r.family_id,family); assert.equal(r.today,today); assert.equal(r.timezone,'Pacific/Kiritimati');
    assert.equal(first.days.length,7); assert.deepEqual(first.days.at(-1),{day:today,expected:2,completed:1});
    assert.equal(first.days.reduce((n,d)=>n+d.expected,0),4);
    assert.equal(first.days.reduce((n,d)=>n+d.completed,0),2);
    assert.ok(r.children.find(c=>c.child_id===empty).days.every(d=>d.expected===0 && d.completed===0));
    assert.equal(r.children.find(c=>c.child_id===sibling).days.at(-1).completed,1);
    const single=await scalar("select public.learning_report($1,'week')",[child]);
    assert.deepEqual(first.days,single.days.map(({day,expected,completed})=>({day,expected,completed})));
  });
  await check('overview counts pending decisions separately from expired claims and never downloads historical details',async()=>{
    const r=await report(), a=r.children.find(c=>c.child_id===child), b=r.children.find(c=>c.child_id===sibling);
    assert.equal(a.requested,1); assert.equal(a.approved,1); assert.equal(a.awaiting_expiry,2);
    assert.equal(a.pending_awards,2); assert.equal(a.pending_coins,50);
    assert.equal(b.requested,1); assert.equal(b.pending_coins,7);
    assert.ok(!JSON.stringify(r).includes('Private')); assert.ok(JSON.stringify(r).length<4000);
    await client.query('begin read only');
    try { assert.deepEqual((await report()).children,r.children); } finally { await client.query('rollback'); }
    assert.equal(await scalar("select count(*) from public.redemptions where child_id=$1 and status in ('requested','approved')",[child]),'4');
  });
  await check('the family count and parent pending-question pages agree for each child, including tied timestamps', async () => {
    const page = (id, cursor = null) => scalar('select public.pending_child_question_submissions($1,$2,$3)',
      [id, cursor?.created_at ?? null, cursor?.id ?? null]);
    await client.query('reset role');
    await client.query('begin');
    try {
      // Only submitted child drafts still awaiting review belong in either result.
      await client.query(`insert into public.question_ocr_drafts
        (id,child_id,owner_id,original_path,processed_path,requires_parent_review,submitted_at,deleting,child_submission)
        select id,case when n<=52 then $1::uuid else $2::uuid end,$3,'original/'||id,'processed/'||id,
          n<>56,case when n<>54 then '2026-11-27 00:00Z'::timestamptz end,n=55,'{"prompt":"Private draft"}'::jsonb
        from (select n,gen_random_uuid() as id from generate_series(1,56) n) input`, [child,sibling,owner]);
      await auth();
      const rows = (await report()).children;
      assert.deepEqual(Object.fromEntries(rows.map(row => [row.child_id,row.pending_question_reviews])),
        {[child]:52,[sibling]:1,[empty]:0});
      assert.ok(!JSON.stringify(rows).includes('Private draft'));
      const first = await page(child), second = await page(child,first.next_cursor);
      assert.equal(first.items.length,50);
      assert.equal(first.next_cursor.id,first.items.at(-1).id);
      assert.equal(first.next_cursor.created_at,first.items.at(-1).submitted_at);
      assert.equal(second.items.length,2);
      assert.equal(second.next_cursor,null);
      const all = [...first.items,...second.items];
      assert.ok(all.every(row => row.state==='pending' && row.question_id===null));
      const ids = all.map(row=>row.id);
      assert.deepEqual(ids,[...new Set(ids)].sort().reverse());
      const other = await page(sibling);
      assert.equal(other.child_id,sibling);
      assert.equal(other.items.length,1);
      assert.ok(!ids.includes(other.items[0].id));
      assert.deepEqual((await page(empty)).items,[]);
    } finally { await client.query('rollback'); }
    await auth();
  });
  await check('overview takes today from server family timezone and returns zero rows for an empty family',async()=>{
    await client.query('reset role');
    await client.query("update public.families set timezone='Pacific/Pago_Pago' where id=$1",[family]);
    await auth(); const west=await report();
    assert.notEqual(west.today,today); assert.equal(west.today,await scalar('select public.family_today($1)::text',[child]));
    await client.query('reset role');
    await client.query("update public.families set timezone='Pacific/Kiritimati' where id=$1",[family]);
    const emptyFamily=await scalar("insert into public.families(name,owner_user_id) values('Empty',$1) returning id",[owner]);
    await client.query("insert into public.family_members values($1,$2,'admin')",[emptyFamily,owner]);
    await auth(); await scalar("select public.set_parent_pin($1,'2345')",[emptyFamily]);
    await scalar("select public.verify_parent_pin($1,'2345')",[emptyFamily]);
    assert.deepEqual((await scalar('select public.family_overview($1)',[emptyFamily])).children,[]);
  });
  await check('overview requires this session PIN, rejects foreign and anonymous access, and allows authorized ordinary parents',async()=>{
    await login(owner,'overview-no-pin'); await denied('select public.family_overview($1)',[family]);
    await denied('select public.pending_child_question_submissions($1)',[child]);
    await login(outsider,'overview-outsider'); await denied('select public.family_overview($1)',[family]);
    await denied('select public.pending_child_question_submissions($1)',[child]);
    await client.query('reset role'); await client.query('set role anon'); await denied('select public.family_overview($1)',[family]);
    await denied('select public.pending_child_question_submissions($1)',[child]);
    await login(parent,'overview-parent'); await pin(); assert.equal((await report()).children.length,3);
    assert.deepEqual((await scalar('select public.pending_child_question_submissions($1)',[child])).items,[]);
    await denied('select public.pending_child_question_submissions($1,$2,null)',[child,'2026-11-27']);
    await denied('select public.pending_child_question_submissions($1,$2,$3)',[child,'infinity',randomUUID()]);
    await denied('select public.family_overview($1)',[randomUUID()]);
    await scalar('select public.revoke_parent_authorization()'); await denied('select public.family_overview($1)',[family]);
    await auth(); await pin();
  });
  await check('overview drops deleted children and denies removed members even with an unexpired old PIN',async()=>{
    await client.query('reset role'); await client.query('delete from public.children where id=$1',[empty]);
    await auth(); assert.deepEqual(new Set((await report()).children.map(c=>c.child_id)),new Set([child,sibling]));
    await login(parent,'overview-parent'); await pin();
    await client.query('reset role'); await client.query('delete from public.family_members where family_id=$1 and user_id=$2',[family,parent]);
    await login(parent,'overview-parent'); await denied('select public.family_overview($1)',[family]);
    await denied('select public.pending_child_question_submissions($1)',[child]);
    await auth();
  });
}
