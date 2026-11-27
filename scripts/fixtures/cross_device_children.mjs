import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export const readingReward = {coins:7, xp:5};

export async function seedPairedChildren(client, owner, family, database) {
  const sibling = await client.rpc('create_child_profile', owner.token, {
    target_family_id:family.id, child_nickname:'小月', child_grade:2,
    preferences:{textbook_labels:{}, avatar_key:'star'},
  });
  await client.rpc('adjust_wallet', owner.token, {
    target_child_id:sibling, coins:23, xp_amount:11, reason:'期初余额', command_id:randomUUID(),
  });
  const plans = [
    {id:family.child, title:'跨设备阅读', ...readingReward, prompt:'红船有几面帆', answer:'3'},
    {id:sibling, title:'蓝鲸绘画', coins:9, xp:4, prompt:'蓝鲸生活在哪里', answer:'海洋'},
  ];
  for (const plan of plans) {
    const day = await client.rpc('family_today', owner.token, {target_child_id:plan.id});
    const question = await client.rpc('save_review_question', owner.token, {
      target_child_id:plan.id,
      config:{kind:'question', subject:'chinese', prompt:plan.prompt, answers:[plan.answer]},
    });
    // A future review date keeps the notebook populated without adding a second task today.
    await database.client.query(
      "update public.wrong_questions set review_due_at=now()+interval '7 days' where id=$1 and child_id=$2",
      [question,plan.id],
    );
    await client.rpc('save_task_schedule', owner.token, {
      target_child_id:plan.id, config:{title:plan.title, recurrence:'once', starts_on:day, ends_on:day,
        start_time:'00:00', due_time:'23:59:59', coins:plan.coins, xp:plan.xp, minimum_seconds:0},
    });
    await client.rpc('generate_scheduled_tasks', owner.token, {target_child_id:plan.id});
  }
  // Read all tasks and questions for these two children; each must provide a distinct, single marker.
  const {rows:profiles} = await database.client.query(`
    select c.id child_id,c.nickname,i.id task_id,i.title,q.final_text question,w.coin_balance,w.xp
    from public.children c join public.task_instances i on i.child_id=c.id
    join public.wrong_questions q on q.child_id=c.id join public.wallets w on w.child_id=c.id
    where c.family_id=$1 order by (c.id=$2) desc`,[family.id,family.child]);
  assert.deepEqual(profiles.map(p=>[p.child_id,p.nickname,p.title,p.question,p.coin_balance,p.xp]),[
    [family.child,'小星',plans[0].title,plans[0].prompt,0,0],
    [sibling,'小月',plans[1].title,plans[1].prompt,23,11],
  ]);
  return profiles;
}

export async function siblingState(database, child) {
  const {rows} = await database.client.query(`
    select c.id child_id,c.nickname,i.id task_id,i.title,i.status,q.final_text question,
      w.coin_balance,w.frozen_balance,w.xp,
      (select count(*)::int from public.task_command_receipts r where r.task_id=i.id) as command_count,
      (select jsonb_agg(jsonb_build_object('id',l.id,'asset_type',l.asset_type,'amount',l.amount,
        'source_type',l.source_type) order by l.asset_type,l.id)
       from public.ledger_entries l where l.child_id=c.id) as ledger
    from public.children c join public.task_instances i on i.child_id=c.id
    join public.wrong_questions q on q.child_id=c.id join public.wallets w on w.child_id=c.id
    where c.id=$1`,[child]);
  assert.equal(rows.length,1);
  return rows[0];
}
