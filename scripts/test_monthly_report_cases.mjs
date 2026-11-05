import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function monthlyReportCases({client,scalar,login,denied,check,otherUid}) {
  const owner=randomUUID(), auth=()=>login(owner,'monthly-parent');
  await client.query('reset role');await client.query('insert into auth.users values($1,$2)',[owner,'monthly@example.test']);
  await auth();await scalar("select public.onboard_family('Monthly family','America/New_York','Monthly child',2::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await scalar("select public.set_parent_pin($1,'4321')",[family]);await scalar("select public.verify_parent_pin($1,'4321')",[family]);
  const report=(date='2024-02-15',id=child)=>scalar("select public.learning_report($1,'month',$2)",[id,date]);
  const sibling=await scalar("select public.create_child($1,'Sibling',2::smallint)",[family]);
  await client.query('reset role');
  async function task(title,day,category,seconds,completed,status='completed',kid=child,source='parent_template',template=null) {
    return scalar(`insert into public.task_instances(child_id,title,due_date,source_type,growth_category,status,accumulated_seconds,completed_at,idempotency_key,template_id)
      values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) returning id`,[kid,title,day,source,category,status,seconds,completed,randomUUID(),template]);
  }
  const study=await task('Study','2024-02-01','learning',600,'2024-02-01T05:00:00Z');
  const explore=await task('Explore','2024-02-29','exploration',300,'2024-03-01T04:59:59Z');
  await task('Late responsibility','2024-01-31','responsibility',0,'2024-03-01T04:59:59Z');
  await task('Unclassified','2024-02-20','general',120,'2024-02-20T12:00:00Z');
  const automatic=await task('Automatic review','2024-02-29','responsibility',180,'2024-02-29T12:00:00Z','completed',child,'automatic_wrong_review');
  await task('Paused','2024-02-10','learning',60,null,'paused');
  await task('Before February','2024-01-31','learning',50,'2024-02-01T04:59:59Z');
  await task('Next month','2024-03-01','responsibility',90,'2024-03-01T05:00:00Z');
  await task('Other child secret','2024-02-01','learning',999,'2024-02-01T05:00:00Z','completed',sibling);
  const template=await scalar("insert into public.task_templates(child_id,title) values($1,'Excused') returning id",[child]);
  const plan=await scalar('insert into public.long_plans(template_id,minimum_rate,bonus_coins,bonus_xp) values($1,1,0,0) returning id',[template]);
  await client.query("insert into public.plan_leaves values($1,'2024-02-12','approved')",[plan]);
  await task('Leave','2024-02-12','general',0,null,'skipped',child,'parent_template',template);
  await client.query(`insert into public.ledger_entries(child_id,asset_type,amount,source_type,idempotency_key,created_at)
    values($1,'coin',10,'parent_adjustment',$2,'2024-02-01T05:00:00Z'),($1,'coin',20,'parent_adjustment',$3,'2024-03-01T05:00:00Z')`,[child,randomUUID(),randomUUID()]);
  async function question(subject,point,time,archived=false,kid=child) {
    return scalar('insert into public.wrong_questions(child_id,subject,knowledge_point,final_text,created_at,archived) values($1,$2,$3,$4,$5,$6) returning id',
      [kid,subject,point,'QUESTION BODY MUST NOT APPEAR',time,archived]);
  }
  const math=await question('math','加法','2024-02-01T05:00:00Z');
  const chinese=await question('chinese','拼音','2024-01-20T12:00:00Z');
  await question('math','  ','2024-02-20T12:00:00Z',true);
  const redacted=await question('math','已清理标签','2024-01-01T12:00:00Z');
  await question('english','Not this month','2024-03-01T05:00:00Z');
  await question('english','OTHER CHILD LABEL','2024-02-01T12:00:00Z',false,sibling);
  await client.query(`insert into public.task_review_items(task_instance_id,wrong_question_id,sequence,subject,knowledge_point,result,answered_at,source_deleted)
    values($1,$4,1,'math','加法',true,'2024-02-01T05:00:00Z',false),
      ($1,$5,2,'chinese','拼音',false,'2024-02-10T05:00:00Z',false),
      ($2,$5,1,'chinese','拼音',true,'2024-03-01T04:59:59Z',false),
      ($2,$4,2,null,null,false,'2024-02-29T12:00:00Z',false),
      ($3,$6,1,'math','已清理标签',true,'2024-02-15T12:00:00Z',true)`,[study,explore,automatic,math,chinese,redacted]);
  await client.query("update public.wrong_questions set subject='english',knowledge_point='词汇' where id=$1",[math]);
  await auth();

  await check('monthly report is a full family-local calendar month including leap day and exclusive end boundary',async()=>{
    const r=await report();assert.equal(r.start_date,'2024-02-01');assert.equal(r.end_date,'2024-02-29');assert.equal(r.days.length,29);
    assert.equal(r.period,'month');assert.equal(r.tasks.expected,5);assert.equal(r.tasks.completed,4);assert.equal(r.tasks.effective_seconds,1260);
    assert.equal(r.activity_count,5);assert.equal(r.coins.income,10);assert.equal(r.reviews.answered,5);
    assert.equal(r.activities.some(a=>a.title==='Late responsibility'),true);
    assert.equal(JSON.stringify(r).includes('Other child secret'),false);assert.equal(JSON.stringify(r).includes('QUESTION BODY MUST NOT APPEAR'),false);
    const january=await report('2024-01-01');assert.equal(january.end_date,'2024-01-31');assert.equal(january.growth.series.at(-1).learning,1);
  });
  await check('five activity dimensions have distinct units, actual completion dates, uncategorized records and six zero-filled months',async()=>{
    const growth=(await report()).growth;assert.equal(growth.definition_version,'activity-v1');assert.equal(growth.series.length,6);
    assert.equal(growth.series[0].start_date,'2023-09-01');assert.equal(growth.series[0].completed,0);
    assert.deepEqual(growth.series.at(-1),{start_date:'2024-02-01',end_date:'2024-02-29',partial:false,
      completed:5,learning:2,persistence:3,focus_seconds:1200,exploration:1,responsibility:1,unclassified:1});
    assert.equal((await report('2024-03-31')).growth.series.at(-1).responsibility,1);
    assert.equal(await scalar('select growth_category from public.task_instances where id=$1',[automatic]),'learning');
  });
  await check('monthly knowledge distribution separates current intake labels from immutable review snapshots and handles missing labels',async()=>{
    const k=(await report()).knowledge;assert.equal(k.added,2);assert.equal(k.answered,4);assert.equal(k.correct,2);
    const subject=key=>k.subjects.find(s=>s.subject===key);
    assert.equal(subject('english').added,1);assert.equal(subject('english').points[0].knowledge_point,'词汇');
    assert.equal(subject('chinese').answered,2);assert.equal(subject('chinese').points[0].accuracy,.5);
    assert.equal(subject('math').points.find(p=>p.knowledge_point==='加法').answered,1);
    assert.equal(subject('math').points.find(p=>p.knowledge_point==='').added,1);
    assert.equal(subject('unknown').answered,1);
    assert.equal(JSON.stringify(k).includes('已清理标签'),false);assert.equal(JSON.stringify(k).includes('OTHER CHILD LABEL'),false);
    const empty=await report('2024-04-10');assert.deepEqual(empty.knowledge,{subjects:[],added:0,answered:0,correct:0});assert.equal(empty.tasks.completion_rate,null);
  });
  await check('current month uses server today, earliest supported month is bounded, DST boundaries keep actual local months',async()=>{
    const current=await report(null);const today=await scalar('select public.family_today($1)::text',[child]);
    assert.equal(current.start_date,today.slice(0,7)+'-01');assert.equal(current.end_date,today);
    assert.equal(current.days.length,Number(today.slice(8)));assert.equal(current.growth.series.at(-1).end_date,today);
    const earliest=await report('2000-01-01');assert.equal(earliest.growth.series.length,1);
    for(const bad of ['1999-12-31','2999-01-01','infinity','-infinity'])await denied("select public.learning_report($1,'month',$2)",[child,bad]);
    await client.query('reset role');
    await task('March local final second','2026-03-31','exploration',60,'2026-04-01T03:59:59Z');
    await task('April local midnight','2026-04-01','exploration',60,'2026-04-01T04:00:00Z');
    await task('November first midnight','2025-11-01','responsibility',30,'2025-11-01T04:00:00Z');
    await task('After November','2025-12-01','responsibility',30,'2025-12-01T05:00:00Z');
    await auth();assert.equal((await report('2026-03-08')).growth.series.at(-1).exploration,1);
    assert.equal((await report('2025-11-02')).growth.series.at(-1).responsibility,1);
  });
  await check('growth categories validate, snapshot on generation, preserve legacy edits and never multiply rewards',async()=>{
    const today=await scalar('select public.family_today($1)::text',[child]);const tomorrow=await scalar('select ($1::date+1)::text',[today]);
    const cfg={title:'Explore nature',starts_on:today,ends_on:tomorrow,recurrence:'daily',rule:{},start_time:'16:00',due_time:'20:00',coins:10,xp:20,minimum_seconds:0,expected_minutes:20,growth_category:'exploration'};
    const tid=await scalar('select public.save_task_schedule($1,$2)',[child,cfg]);
    const initial=await scalar('select to_jsonb(t) from public.task_instances t where template_id=$1',[tid]);assert.equal(initial.growth_category,'exploration');assert.equal(initial.coin_reward,10);
    await scalar('select public.save_task_schedule($1,$2,$3)',[child,{...cfg,growth_category:'responsibility'},tid]);
    assert.equal(await scalar('select growth_category from public.task_instances where id=$1',[initial.id]),'exploration');
    const legacy={...cfg};delete legacy.growth_category;await scalar('select public.save_task_schedule($1,$2,$3)',[child,legacy,tid]);
    assert.equal(await scalar('select growth_category from public.task_templates where id=$1',[tid]),'responsibility');
    await client.query('reset role');await client.query(`select set_config('request.jwt.claims','{"role":"service_role"}',false)`);await client.query('set role service_role');
    await scalar('select public.generate_scheduled_tasks($1,$2)',[child,tomorrow]);await auth();
    const next=await scalar('select to_jsonb(t) from public.task_instances t where template_id=$1 and due_date=$2',[tid,tomorrow]);assert.equal(next.growth_category,'responsibility');assert.equal(next.coin_reward,10);assert.equal(next.xp_reward,20);
    const peer=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});await peer.connect();let edit;
    try {
      await peer.query('begin');await peer.query("update public.task_templates set growth_category='learning' where id=$1",[tid]);
      edit=client.query('select public.save_task_schedule($1,$2,$3)',[child,legacy,tid]);
      let waiting=false;
      for(let i=0;i<100;i++) {
        waiting=(await peer.query("select count(*)::int n from pg_stat_activity where pid<>pg_backend_pid() and datname=current_database() and wait_event_type='Lock' and query like '%save_task_schedule%' ")).rows[0].n>0;
        if(waiting)break;await new Promise(resolve=>setTimeout(resolve,10));
      }
      assert.ok(waiting,'legacy edit must be observed waiting on the held template lock');
      await peer.query('commit');await edit;
      assert.equal(await scalar('select growth_category from public.task_templates where id=$1',[tid]),'learning');
      assert.equal(await scalar('select growth_category from public.task_instances where id=$1',[initial.id]),'exploration');
    } finally {await peer.query('rollback');await edit?.catch(()=>{});await peer.end();}
    for(const invalid of ['focus','persistence','score',{}])await denied('select public.save_task_schedule($1,$2)',[child,{...cfg,growth_category:invalid}]);
  });
  await check('monthly summaries include all records beyond activity display cap and all knowledge groups',async()=>{
    const bulk=await scalar("select public.create_child($1,'Large month',2::smallint)",[family]);await client.query('reset role');
    await client.query(`insert into public.task_instances(child_id,title,due_date,source_type,status,growth_category,completed_at,accumulated_seconds,idempotency_key)
      select $1,'Activity '||n,'2024-02-01','parent_template','completed','learning','2024-02-01T12:00:00Z',1,gen_random_uuid()::text from generate_series(1,250) n`,[bulk]);
    await client.query(`insert into public.wrong_questions(child_id,subject,knowledge_point,final_text,created_at)
      select $1,'math','Point '||n,'Private body','2024-02-01T12:00:00Z' from generate_series(1,205) n`,[bulk]);
    await auth();const before=await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[bulk]);
    const r=await report('2024-02-29',bulk);assert.equal(r.activities.length,200);assert.equal(r.activity_count,250);assert.equal(r.tasks.completed,250);
    assert.equal(r.growth.series.at(-1).learning,250);assert.equal(r.growth.series.at(-1).focus_seconds,250);
    assert.equal(r.knowledge.subjects[0].points.length,205);assert.equal(r.knowledge.added,205);
    assert.deepEqual(await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[bulk]),before);
  });
  await check('monthly data requires family and current PIN; private aggregation helpers cannot bypass authorization',async()=>{
    await login(owner,'no-monthly-pin');await denied("select public.learning_report($1,'month','2024-02-01')",[child]);
    await auth();await denied("select public.monthly_growth_trends($1,'2024-02-01',current_date,'UTC')",[child]);
    await denied("select public.monthly_knowledge_distribution($1,'2024-02-01','2024-03-01')",[child]);
    await login(otherUid);await denied("select public.learning_report($1,'month','2024-02-01')",[child]);
    await client.query('reset role');await client.query("insert into public.family_members values($1,$2,'parent')",[family,otherUid]);
    await login(otherUid,'monthly-shared');await scalar("select public.verify_parent_pin($1,'4321')",[family]);assert.equal((await report()).growth.series.at(-1).learning,2);
    await client.query('reset role');await client.query('set role anon');await denied("select public.learning_report($1,'month','2024-02-01')",[child]);await auth();
  });
  await check('requested and completed permanent question cleanup remove monthly labels while retaining non-identifying review totals',async()=>{
    await scalar("select public.request_question_cleanup($1,'questions',$2,$3,'永久删除')",[child,[math],randomUUID()]);
    const r=await report();assert.equal(r.knowledge.added,1);assert.equal(r.knowledge.answered,2);
    assert.equal(JSON.stringify(r.knowledge).includes('词汇'),false);assert.equal(JSON.stringify(r.knowledge).includes('加法'),false);
    assert.equal(r.reviews.answered,5);
    const job=await scalar("select id from public.cleanup_jobs where child_id=$1 and scope='questions' and status='queued' order by created_at desc limit 1",[child]);
    await client.query('reset role');await client.query(`select set_config('request.jwt.claims','{"role":"service_role"}',false)`);await client.query('set role service_role');
    const lease=await scalar('select public.claim_cleanup_job($1)',[job]);await scalar('select public.finish_cleanup_job($1,$2)',[job,lease.token??lease.lease_token]);
    await auth();const done=await report();assert.deepEqual(done.knowledge,r.knowledge);assert.equal(done.reviews.answered,5);
  });
}
