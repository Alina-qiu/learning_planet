import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export async function scheduleSnapshotCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(), stranger=randomUUID();
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2),($3,$4)',[owner,'schedule-cache@example.test',stranger,'schedule-other@example.test']);
  const auth=()=>login(owner,'schedule-cache'); await auth();
  await scalar("select public.onboard_family('Schedule cache','America/New_York','Child',2::smallint)");
  const family=await scalar('select family_id from public.family_members where user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'1234')",[family]);
  await scalar("select public.verify_parent_pin($1,'1234')",[family]);
  const sibling=await scalar("select public.create_child($1,'Sibling',2::smallint)",[family]);
  const empty=await scalar("select public.create_child($1,'Empty',2::smallint)",[family]);
  await client.query('reset role');
  const template=await scalar(`insert into public.task_templates(child_id,title,recurrence,starts_on,ends_on)
    values($1,'Plan','daily',current_date-2,current_date+2) returning id`,[child]);
  const plan=await scalar('insert into public.long_plans(template_id,minimum_rate,bonus_coins,bonus_xp) values($1,0.5,100,80) returning id',[template]);
  await client.query("insert into public.plan_leaves values($1,current_date,'Private leave reason')",[plan]);
  await client.query('insert into public.plan_stage_rewards values($1,3,30,20,null)',[plan]);
  await client.query('insert into public.plan_bonus_tiers values($1,0.9,200,100)',[plan]);
  await client.query(`insert into public.task_instances(child_id,title,due_date,source_type,status,template_id,idempotency_key)
    values($1,'Private completion',current_date-1,'long_plan','completed',$2,$3)`,[child,template,randomUUID()]);
  await client.query(`insert into public.task_templates(child_id,title,active,created_at)
    select $1,'Historical template '||n,false,'2020-01-01T00:00:00Z' from generate_series(1,1005) n`,[child]);
  await client.query("insert into public.task_templates(child_id,title,active) values($1,'Sibling private template',false)",[sibling]);
  await auth(); await scalar('select public.revoke_parent_authorization()');
  const page=(cursor=null,size=100,id=child)=>scalar('select public.task_schedule_page($1,$2,$3,$4)',[id,cursor?.created_at??null,cursor?.id??null,size]);
  await check('schedule pages include full plan rules and progress without PIN, leave reasons or business writes',async()=>{
    await client.query('begin read only');
    try {
      const r=await page(), p=r.items[0].long_plans;
      assert.equal(r.child_id,child); assert.equal(r.family_id,family);
      assert.equal(r.family_today,await scalar('select public.family_today($1)::text',[child]));
      assert.equal(p.id,plan); assert.deepEqual(p.progress,{expected:4,completed:1,rate:0.25});
      assert.equal(p.plan_leaves.length,1); assert.equal(p.plan_stage_rewards[0].completed_count,3);
      assert.equal(p.plan_bonus_tiers[0].minimum_rate,0.9);
      assert.ok(!JSON.stringify(r).includes('Private leave reason')); assert.ok(!JSON.stringify(r).includes('Private completion'));
      assert.equal(await scalar('select count(*) from public.ledger_entries where child_id=$1',[child]),'0');
      assert.equal(await scalar('select settled_at from public.long_plans where id=$1',[plan]),null);
    } finally { await client.query('rollback'); }
  });
  await check('schedule keyset reads over 1000 templates with equal timestamps without truncation or duplicates',async()=>{
    const ids=[]; let cursor=null, pages=0;
    do { const r=await page(cursor); pages++; assert.ok(r.items.length<=100); ids.push(...r.items.map(t=>t.id)); cursor=r.next_cursor; } while(cursor);
    assert.equal(pages,11); assert.equal(ids.length,1006); assert.equal(new Set(ids).size,1006);
    assert.ok(!ids.includes(sibling));
    const other=await page(null,100,sibling); assert.equal(other.items.length,1); assert.equal(other.items[0].child_id,sibling);
    assert.deepEqual((await page(null,100,empty)).items,[]); assert.equal((await page(null,100,empty)).next_cursor,null);
  });
  await check('schedule keyset remains stable when newer templates arrive and an earlier row disappears between pages',async()=>{
    const first=await page();
    await client.query('reset role');
    const added=await scalar("insert into public.task_templates(child_id,title,active,created_at) values($1,'New after first page',false,now()+interval '1 second') returning id",[child]);
    await client.query('delete from public.task_templates where id=$1',[first.items[1].id]);
    await auth(); const ids=first.items.map(t=>t.id); let cursor=first.next_cursor;
    while(cursor) {const r=await page(cursor); ids.push(...r.items.map(t=>t.id)); cursor=r.next_cursor;}
    assert.equal(ids.length,1006); assert.equal(new Set(ids).size,1006); assert.ok(!ids.includes(added));
    assert.equal((await page()).items[0].id,added);
  });
  await check('schedule page validates limits and cursors, isolates child access and rejects anonymous or removed members',async()=>{
    for(const args of [[child,null,null,0],[child,null,null,201],[child,null,null,null],[child,null,randomUUID(),10],[child,'infinity',randomUUID(),10]]) {
      await denied('select public.task_schedule_page($1,$2,$3,$4)',args);
    }
    await denied('select public.task_schedule_page($1)',[randomUUID()]);
    await login(stranger); await denied('select public.task_schedule_page($1)',[child]);
    await client.query('reset role'); await client.query('set role anon'); await denied('select public.task_schedule_page($1)',[child]);
    await client.query('reset role'); await client.query('delete from public.family_members where family_id=$1 and user_id=$2',[family,owner]);
    await auth(); await denied('select public.task_schedule_page($1)',[child]);
  });
}
