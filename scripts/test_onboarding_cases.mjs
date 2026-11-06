import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function onboardingCases({client,scalar,login,denied,check,otherUid}) {
  const user=randomUUID(), session='getting-started';
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)',[user,'onboarding@example.test']);
  const auth=()=>login(user,session); await auth();
  const preferences={avatar_key:'rocket',textbook_labels:{chinese:'统编版三年级上册',math:'自定义数学版本'}};
  let family,child,sibling;
  const overview=id=>scalar('select public.onboarding_overview($1)',[id]);
  const profile=id=>scalar('select to_jsonb(c) from public.children c where id=$1',[id]);
  const configure=(id,keys=['cartoon','book'],preset='study20',limit=150)=>client.query('select public.configure_starter_rules($1,$2,$3,$4)',[id,preset,limit,keys]);
  const advance=(id,step,selection=null)=>scalar('select public.advance_child_guide($1,$2,$3)',[id,step,selection]);
  async function peerConnection(name) {
    const peer=new pg.Client(client.connectionParameters);
    await peer.connect();
    await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:name,iat:Math.floor(Date.now()/1000)})]);
    await peer.query('set role authenticated');
    await peer.query("select public.verify_parent_pin($1,'3579')",[family]);
    return peer;
  }
  await check('profile onboarding validates custom textbook labels and avatar atomically with safe legacy defaults',async()=>{
    for(const prefs of [null,{}, {avatar_key:'photo',textbook_labels:{}}, {avatar_key:'star',textbook_labels:[]},
      {avatar_key:'star',textbook_labels:{science:'text'}},{avatar_key:'star',textbook_labels:{math:5}},
      {avatar_key:'star',textbook_labels:{math:' '}},{avatar_key:'star',textbook_labels:{math:'x'.repeat(61)}}]) {
      await denied("select public.onboard_family_profile('Invalid','Asia/Shanghai','Nickname',3::smallint,$1)",[prefs]);
    }
    assert.equal(await scalar('select count(*)::int from public.families where owner_user_id=$1',[user]),0);
    family=await scalar("select public.onboard_family_profile('Starter family','Pacific/Kiritimati','小火箭',3::smallint,$1)",[preferences]);
    child=await scalar('select id from public.children where family_id=$1',[family]);
    assert.equal((await profile(child)).avatar_key,'rocket');
    assert.deepEqual((await profile(child)).textbook_labels,preferences.textbook_labels);
    assert.equal((await profile(child)).guide_step,0);
    await denied("select public.create_child_profile($1,'No PIN',1::smallint,$2)",[family,preferences]);
    await client.query("select public.set_parent_pin($1,'3579')",[family]);
    await client.query("select public.verify_parent_pin($1,'3579')",[family]);
    sibling=await scalar("select public.create_child($1,'Legacy sibling',2::smallint)",[family]);
    assert.deepEqual((await profile(sibling)).textbook_labels,{});
    assert.equal((await profile(sibling)).avatar_key,'star');
    assert.equal((await profile(sibling)).profile_version,0);
  });
  await check('profile changes require admin PIN and a current version; competing devices cannot overwrite each other',async()=>{
    const before=await profile(child), peer=await peerConnection('profile-peer');
    const sql='select public.update_child_profile($1,$2,4::smallint,$3,$4)';
    try {
      const result=await Promise.allSettled([
        client.query(sql,[child,'First edit',preferences,before.profile_version]),
        peer.query(sql,[child,'Second edit',preferences,before.profile_version]),
      ]);
      assert.equal(result.filter(r=>r.status==='fulfilled').length,1);
      assert.equal(result.find(r=>r.status==='rejected').reason.code,'40001');
    } finally {await peer.end();}
    assert.equal((await profile(child)).profile_version,before.profile_version+1);
    await client.query("select public.update_child($1,'Legacy edit',4::smallint)",[child]);
    assert.equal((await profile(child)).profile_version,before.profile_version+2);
    assert.deepEqual((await profile(child)).textbook_labels,preferences.textbook_labels);
    await login(user,'no-profile-pin');
    await denied(sql,[child,'Unauthorized',preferences,before.profile_version+2]); await auth();
    await denied("update public.children set guide_step=3,onboarding_completed_at=now(),profile_version=0 where id=$1",[child]);
    await denied('select public.validate_child_preferences($1)',[preferences]);
    const invalid={avatar_key:'leaf',textbook_labels:{math:''}};
    await denied(sql,[child,'Unchanged',invalid,before.profile_version+2]);
    assert.equal((await profile(child)).nickname,'Legacy edit');
  });
  await check('starter rules seed the PRD prices once per family and preserve edited reward stock prices and availability',async()=>{
    assert.equal((await overview(child)).daily_limit,150);
    await configure(child,['cartoon','game','book','movie','restaurant','toy','park']);
    let rewards=(await client.query('select * from public.rewards where family_id=$1 order by cost',[family])).rows;
    assert.deepEqual(rewards.map(r=>r.cost),[120,220,500,1200,1800,3000,8000]);
    const cartoon=rewards.find(r=>r.starter_key==='cartoon');
    await client.query('select public.save_reward($1,$2,$3)',[family,{...cartoon,cost:130,stock_total:2,expected_version:cartoon.version},cartoon.id]);
    const date=(await profile(child)).starter_rules_at;
    await configure(child,['cartoon','book']);
    await configure(sibling,['cartoon'],'study10',100);
    rewards=(await client.query('select * from public.rewards where family_id=$1',[family])).rows;
    assert.equal(rewards.length,7); assert.equal(rewards.find(r=>r.id===cartoon.id).cost,130);
    assert.equal(rewards.find(r=>r.id===cartoon.id).stock_total,2);
    assert.equal((await profile(child)).starter_rules_at,date);
    assert.equal((await profile(sibling)).starter_task_preset,'study10');
    assert.equal((await overview(sibling)).daily_limit,100);
  });
  await check('starter rules reject expired PIN invalid settings and entirely inactive shops without partial writes',async()=>{
    await login(user,'no-rules-pin'); await assert.rejects(configure(child)); await auth();
    for(const [preset,limit,keys] of [['invalid',150,[]],['habit',-1,[]],['habit',10001,[]],['habit',80,['unknown']],['habit',80,[null]]]) {
      await assert.rejects(configure(child,keys,preset,limit));
    }
    assert.equal((await overview(child)).daily_limit,150);
    await client.query('reset role'); await client.query('update public.rewards set active=false where family_id=$1',[family]); await auth();
    await assert.rejects(configure(child,[],'habit',80));
    await assert.rejects(configure(child,['cartoon'],'habit',80));
    assert.equal((await profile(child)).starter_task_preset,'study20');
    assert.equal((await overview(child)).daily_limit,150);
    await client.query('reset role'); await client.query('update public.rewards set active=true where family_id=$1',[family]); await auth();
    await configure(child,[]);
  });
  await check('three-step guide resumes from server state and rejects skipped steps locked pets and cross-family access',async()=>{
    await denied('select public.finish_onboarding($1)',[child]);
    await assert.rejects(advance(child,1,'starter_rabbit'));
    await assert.rejects(advance(child,0,'unrecognized'));
    assert.equal(await advance(child,0,'explorer'),1);
    assert.equal(await advance(child,0,'astronaut'),1);
    assert.equal((await overview(child)).appearance.avatar,'explorer');
    await assert.rejects(advance(child,1));
    const locked=await scalar("select key from public.growth_assets where kind='pet' and not starter limit 1");
    await assert.rejects(advance(child,1,locked));
    await assert.rejects(advance(child,1,'astronaut'));
    assert.equal((await overview(child)).child.guide_step,1);
    assert.equal(await advance(child,1,'starter_rabbit'),2);
    assert.equal(await advance(child,2),3); assert.equal(await advance(child,2),3);
    assert.equal((await overview(child)).appearance.pet,'starter_rabbit');
    assert.equal((await profile(sibling)).guide_step,0);
    await denied('select public.finish_onboarding($1)',[child]); // Still no real task.
    await login(otherUid); await assert.rejects(overview(child)); await assert.rejects(advance(child,0,'astronaut'));
    await denied('select public.finish_onboarding($1)',[child]); await auth();
    await assert.rejects(overview(randomUUID()));
  });
  await check('first task is due on the family date; invalid days roll back and concurrent retries create one real template',async()=>{
    const today=(await overview(child)).today;
    const config={title:'每天阅读20分钟',recurrence:'daily',starts_on:today,ends_on:today,start_time:'16:00',due_time:'20:00',coins:25,xp:20,minimum_seconds:0,expected_minutes:20,priority:'recommended'};
    const sql='select public.create_starter_task($1,$2)';
    await login(user,'no-task-pin');await denied(sql,[child,config]);await auth();
    await denied(sql,[child,{...config,starts_on:'2000-01-01'}]);
    const weekday=await scalar('select extract(isodow from $1::date)::int',[today]);
    await denied(sql,[child,{...config,recurrence:'weekly',rule:{weekdays:[weekday===7?1:weekday+1]}}]);
    assert.equal(await scalar('select count(*)::int from public.task_templates where child_id=$1',[child]),0);
    const peer=await peerConnection('first-task-peer'); let template;
    try {
      const [a,b]=await Promise.all([client.query(sql,[child,config]),peer.query(sql,[child,config])]);
      template=a.rows[0].create_starter_task; assert.equal(template,b.rows[0].create_starter_task);
    } finally {await peer.end();}
    assert.equal(await scalar(sql,[child,{...config,title:'Unknown-response retry'}]),template);
    assert.equal(await scalar('select count(*)::int from public.task_templates where child_id=$1',[child]),1);
    const task=await scalar('select to_jsonb(t) from public.task_instances t where template_id=$1',[template]);
    assert.equal(task.due_date,today); assert.equal(task.title,config.title);
    assert.equal(task.coin_reward,25); assert.equal(task.xp_reward,20); assert.equal(task.expected_minutes,20);
    assert.equal((await overview(child)).has_task,true);
  });
  await check('finishing onboarding requires all three prerequisites and never grants coins XP or growth unlocks',async()=>{
    await denied('select public.finish_onboarding($1)',[sibling]);
    await client.query('select public.finish_onboarding($1)',[child]);
    const completed=(await profile(child)).onboarding_completed_at;
    assert.ok(completed);
    await client.query('select public.finish_onboarding($1)',[child]);
    await login(user,'child-mode-no-pin');
    assert.equal((await overview(child)).child.onboarding_completed_at,completed);
    for(const id of [child,sibling]) {
      assert.equal(await scalar('select coin_balance from public.wallets where child_id=$1',[id]),0);
      assert.equal(await scalar('select xp from public.wallets where child_id=$1',[id]),0);
      assert.equal(await scalar('select count(*)::int from public.ledger_entries where child_id=$1',[id]),0);
      assert.equal(await scalar('select count(*)::int from public.child_growth_assets where child_id=$1',[id]),0);
    }
    await auth();
  });
  await check('profile metadata and guide progress are exported and removed by real child deletion without touching siblings',async()=>{
    const counts=(await scalar('select public.preview_child_export($1)',[child])).counts, exportId=randomUUID();
    await client.query('select public.prepare_child_export($1,$2,$3,$4)',[child,exportId,counts,'导出孩子数据']);
    const exported=await scalar("select public.read_child_export_page($1,'child_profile',0)",[exportId]);
    assert.deepEqual(exported.rows[0].textbook_labels,preferences.textbook_labels);
    assert.equal(exported.rows[0].guide_step,3);assert.ok(exported.rows[0].onboarding_completed_at);
    const deletion=(await scalar('select public.preview_child_deletion($1)',[child])).counts;
    await client.query('select public.request_child_deletion($1,$2,$3,$4)',[child,randomUUID(),deletion,'永久删除孩子']);
    await assert.rejects(overview(child));
    await denied("select public.read_child_export_page($1,'child_profile',0)",[exportId]);
    await denied('select public.finish_onboarding($1)',[child]);
    assert.equal(await scalar('select count(*)::int from public.children where id=$1',[child]),0);
    assert.equal((await profile(sibling)).nickname,'Legacy sibling');
    assert.equal(await scalar('select count(*)::int from public.rewards where family_id=$1',[family]),7);
  });
}
