import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

export async function growthCases({client, scalar, login, denied, check, family, uid, postgres}) {
  await login();
  const child = await scalar("select public.create_child($1,'Growth',2::smallint)", [family]);
  const today = await scalar('select public.family_today($1)', [child]);
  const dayBefore = offset => new Date(Date.parse(today + 'T00:00:00Z') - offset * 86400000).toISOString().slice(0, 10);
  const overview = (id=child) => scalar('select public.growth_overview($1)', [id]);
  async function completedDay(id, day) {
    await client.query('reset role');
    const task = await scalar(`insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key)
      values($1,'Approved historical task',$2,'parent_template',$3) returning id`, [id,day,randomUUID()]);
    await login();
    await client.query("select public.complete_task($1,$2,'家长核实后补签')", [task,randomUUID()]);
    return task;
  }
  await check('growth starts with free static pets and rejects locked assets, wrong slots and direct writes', async () => {
    const first = await overview();
    assert.equal(first.streak,0); assert.equal(first.xp,0);
    assert.equal(first.appearance.avatar,'astronaut'); assert.equal(first.appearance.pet,'starter_star');
    assert.equal(first.assets.filter(a=>a.unlocked).length,2);
    await client.query("select public.set_growth_slot($1,'avatar','explorer')",[child]);
    await client.query("select public.set_growth_slot($1,'pet','starter_rabbit')",[child]);
    await denied("select public.set_growth_slot($1,'pet','level20')",[child]);
    await denied("select public.set_growth_slot($1,'badge','starter_rabbit')",[child]);
    await denied("select public.set_growth_slot($1,'avatar','unknown')",[child]);
    await denied("insert into public.child_growth_assets values($1,'level5',now())",[child]);
    await denied("update public.child_growth_profiles set avatar_key='astronaut' where child_id=$1",[child]);
    await denied('select public.record_growth_day($1,current_date)',[child]);
    const second = await overview();
    assert.equal(second.appearance.avatar,'explorer'); assert.equal(second.appearance.pet,'starter_rabbit');
    assert.equal(second.xp,0);
  });
  let lastTask;
  await check('completed zero-reward tasks settle 3/7/30 day milestones exactly once', async () => {
    for (let offset=29;offset>=0;offset--) lastTask=await completedDay(child,dayBefore(offset));
    const r=await overview();
    assert.equal(r.streak,30); assert.equal(r.checkin_today,true);
    assert.deepEqual(r.milestones,[3,7,30]); assert.equal(r.xp,200);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[child]),30);
    assert.ok(r.assets.find(a=>a.key==='streak7').unlocked);
    assert.ok(r.assets.find(a=>a.key==='streak30').unlocked);
    await client.query('select public.complete_task($1,$2)',[lastTask,randomUUID()]);
    await completedDay(child,today);
    assert.equal((await overview()).xp,200);
    assert.equal(await scalar("select count(*)::int from public.ledger_entries where child_id=$1 and source_type='streak'",[child]),3);
  });
  await check('a broken current streak retains all earned assets and balances', async () => {
    // Advance only this disposable child's attendance fixture to an earlier run.
    await client.query('reset role');
    await client.query('update public.child_checkin_days set day=day-40 where child_id=$1',[child]);
    await login();
    const r=await overview();
    assert.equal(r.streak,0); assert.equal(r.xp,200); assert.deepEqual(r.milestones,[3,7,30]);
    assert.ok(r.assets.find(a=>a.key==='streak30').unlocked);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[child]),30);
  });
  await check('level rewards unlock every five levels and independent slots never spend XP or coins', async () => {
    await client.query("select public.adjust_wallet($1,0,1000,'level test',$2,false)",[child,randomUUID()]);
    const before=await scalar('select row_to_json(w) from public.wallets w where child_id=$1',[child]);
    assert.ok((await overview()).assets.find(a=>a.key==='level5').unlocked);
    assert.equal((await overview()).assets.find(a=>a.key==='level10').unlocked,false);
    await client.query("select public.set_growth_slot($1,'badge','level5')",[child]);
    await client.query("select public.set_growth_slot($1,'outfit','streak30')",[child]);
    assert.deepEqual((await overview()).appearance,{avatar:'explorer',pet:'starter_rabbit',badge:'level5',outfit:'streak30'});
    assert.deepEqual(await scalar('select row_to_json(w) from public.wallets w where child_id=$1',[child]),before);
    await client.query("select public.set_growth_slot($1,'pet',null)",[child]);
    assert.equal((await overview()).appearance.badge,'level5');
    assert.equal((await overview()).appearance.pet,null);
    for(let n=0;n<12;n++) await client.query("select public.adjust_wallet($1,0,10000,'level progression',$2,false)",[child,randomUUID()]);
    await client.query("select public.adjust_wallet($1,0,1300,'level50 threshold',$2,false)",[child,randomUUID()]);
    const level50=await overview();
    assert.equal(level50.xp,122500);
    assert.equal(level50.assets.filter(a=>a.minimum_level!==null && a.unlocked).length,10);
  });
  await check('streak coins obey the daily soft cap and require the existing parent approval', async () => {
    const capped=await scalar("select public.create_child($1,'Capped streak',2::smallint)",[family]);
    await client.query('select public.set_daily_coin_limit($1,0)',[capped]);
    for (let offset=2;offset>=0;offset--) await completedDay(capped,dayBefore(offset));
    assert.deepEqual((await overview(capped)).milestones,[3]);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[capped]),0);
    assert.equal(await scalar("select sum(amount)::int from public.pending_coin_awards where child_id=$1 and source_type='streak' and status='pending'",[capped]),30);
  });
  let challenge;
  await check('daily challenge is a real timed task, fixed reward, once per family day and UUID replay safe', async () => {
    const command=randomUUID();
    challenge=await scalar("select public.create_daily_challenge($1,$2,'Try a new book',60)",[child,command]);
    assert.equal(await scalar("select public.create_daily_challenge($1,$2,'Try a new book',60)",[child,command]),challenge);
    await denied("select public.create_daily_challenge($1,$2,'Changed',60)",[child,command]);
    await denied("select public.create_daily_challenge($1,$2,'Second task',0)",[child,randomUUID()]);
    assert.equal(await scalar('select count(*)::int from public.ledger_entries where source_id=$1',[challenge]),0);
    await client.query('select public.start_task($1)',[challenge]);
    await denied('select public.complete_task($1,$2)',[challenge,randomUUID()]);
    await client.query("select public.complete_task($1,$2,'parent verified reading')",[challenge,randomUUID()]);
    await client.query('select public.complete_task($1,$2)',[challenge,randomUUID()]);
    assert.deepEqual((await client.query('select asset_type,amount from public.ledger_entries where source_id=$1 order by asset_type',[challenge])).rows,
      [{asset_type:'coin',amount:30},{asset_type:'xp',amount:25}]);
  });
  await check('concurrent challenge creation permits only one instance', async () => {
    const target=await scalar("select public.create_child($1,'Concurrent challenge',2::smallint)",[family]);
    const parallel=postgres.getPgClient(); await parallel.connect();
    try {
      await parallel.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:uid,role:'authenticated',session_id:'session-a'})]);
      await parallel.query('set role authenticated');
      const results=await Promise.allSettled([
        client.query("select public.create_daily_challenge($1,$2,'First',0)",[target,randomUUID()]),
        parallel.query("select public.create_daily_challenge($1,$2,'Second',0)",[target,randomUUID()]),
      ]);
      assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
      assert.equal(await scalar("select count(*)::int from public.task_instances where child_id=$1 and task_kind='challenge'",[target]),1);
    } finally {await parallel.end();}
  });
  const eventChild=await scalar("select public.create_child($1,'Learning awards',2::smallint)",[family]);
  const exam={kind:'exam',date:today,reference:'数学期中考试',reason:'本次更独立地检查了答案',score_coins:200,score_xp:30,improvement_coins:100,improvement_xp:100};
  await check('exam chooses one reward package rather than stacking and soft cap still applies', async () => {
    const command=randomUUID();
    assert.equal(await scalar('select public.award_learning_event($1,$2,$3)',[eventChild,command,exam]),command);
    assert.equal(await scalar('select public.award_learning_event($1,$2,$3)',[eventChild,command,exam]),command);
    const row=await scalar('select row_to_json(e) from public.learning_events e where id=$1',[command]);
    assert.equal(row.coin_reward,200); assert.equal(row.xp_reward,30); assert.equal(row.actor_id,uid);
    assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[eventChild]),150);
    assert.equal(await scalar('select xp from public.wallets where child_id=$1',[eventChild]),30);
    assert.equal(await scalar("select sum(amount)::int from public.pending_coin_awards where child_id=$1 and status='pending'",[eventChild]),50);
    await denied('select public.award_learning_event($1,$2,$3)',[eventChild,command,{...exam,reason:'changed'}]);
    await denied('select public.award_learning_event($1,$2,$3)',[eventChild,randomUUID(),exam]);
    assert.equal(await scalar("select count(*)::int from public.audit_logs where action='learning_event.award' and target_id=$1",[command]),1);
  });
  await check('praise and exam values validate reason, date, reward ranges and equal-price XP tie', async () => {
    const praise={kind:'praise',date:today,reference:'课堂分享',reason:'老师确认',coins:30,xp:20};
    await scalar('select public.award_learning_event($1,$2,$3)',[eventChild,randomUUID(),praise]);
    for(const invalid of [{...praise,coins:101},{...praise,reason:' '},{...praise,date:'2999-01-01'},{...exam,score_xp:0},{...exam,improvement_coins:null}]) {
      await denied('select public.award_learning_event($1,$2,$3)',[eventChild,randomUUID(),invalid]);
    }
    const id=await scalar('select public.award_learning_event($1,$2,$3)',[eventChild,randomUUID(),{...exam,reference:'语文考试',score_coins:100,score_xp:30}]);
    assert.equal(await scalar('select xp_reward from public.learning_events where id=$1',[id]),100);
    await denied('delete from public.learning_events where id=$1',[id]);
  });
  await check('child mode may dress unlocked assets but cannot award events or create challenges', async () => {
    await login(uid,'growth-child-session');
    await client.query("select public.set_growth_slot($1,'avatar','astronaut')",[child]);
    await denied("select public.create_daily_challenge($1,$2,'bypass',0)",[eventChild,randomUUID()]);
    await denied('select public.award_learning_event($1,$2,$3)',[eventChild,randomUUID(),exam]);
    const outsider=randomUUID();
    await client.query('reset role');
    await client.query('insert into auth.users values($1,$2)',[outsider,'growth-outsider@example.test']);
    await login(outsider);
    await denied('select public.growth_overview($1)',[child]);
    await denied("select public.set_growth_slot($1,'pet','starter_star')",[child]);
    assert.equal(await scalar('select count(*)::int from public.learning_events'),0);
    await login();
  });
}
