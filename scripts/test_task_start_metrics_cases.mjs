import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function taskStartMetricsCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(),outsider=randomUUID();await client.query('reset role');
  for(const id of [owner,outsider]) await client.query('insert into auth.users values($1,$2)',[id,`${id}@start.test`]);
  const auth=async()=>login(owner,'start-metrics-session');
  await auth();await scalar("select public.onboard_family('Start metrics','America/New_York','Initial',2::smallint)");
  const family=await scalar('select family_id from public.family_members where user_id=$1',[owner]);
  await scalar("select public.set_parent_pin($1,'2468')",[family]);await scalar("select public.verify_parent_pin($1,'2468')",[family]);
  const child=await scalar("select public.create_child($1,'Start child',2::smallint)",[family]);
  async function task(id=child){
    await client.query('reset role');
    const result=await scalar(`insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key,scheduled_at,due_at)
      values($1,'Start task',public.family_today($1)::date,'parent_template',$2,now()-interval '1 hour',now()+interval '1 hour') returning id`,[id,randomUUID()]);
    await auth();return result;
  }
  const load=id=>scalar('select to_jsonb(t) from public.task_instances t where id=$1',[id]);
  const apply=c=>scalar('select public.apply_task_command($1)',[c]);
  const command=async(id,kind='start',extra={})=>{
    const snapshot=await scalar('select public.task_sync_snapshot($1)',[child]);
    return {command_id:randomUUID(),task_id:id,kind,lease_id:snapshot.lease_id,
      expected_version:snapshot.tasks.find(t=>t.id===id).sync_version,predecessor_id:null,
      occurred_at:await scalar('select clock_timestamp()::text'),...extra};
  };
  await check('first online start records UI mode once; legacy starts stay unknown and resume cannot rewrite provenance',async()=>{
    for(const origin of ['child_mode','parent_assisted']){
      const id=await task();const started=await scalar('select to_jsonb(public.start_task_with_origin($1,$2))',[id,origin]);
      assert.equal(started.start_origin,origin);assert.equal(started.sync_version,1);assert.ok(started.start_observed_at);
      await denied('select public.start_task_with_origin($1,$2)',[id,origin==='child_mode'?'parent_assisted':'child_mode']);
      await scalar('select public.pause_task($1)',[id]);await scalar('select public.resume_task($1)',[id]);
      assert.equal((await load(id)).start_origin,origin);assert.equal((await load(id)).start_observed_at,started.start_observed_at);
      await client.query('reset role');await client.query("update public.task_instances set start_origin='unknown',start_observed_at=null where id=$1",[id]);
      await auth();assert.equal((await load(id)).start_origin,origin);
    }
    const legacy=await task();await scalar('select public.start_task($1)',[legacy]);assert.equal((await load(legacy)).start_origin,'unknown');
    const invalid=await task();for(const value of [null,'parent','child','']) await denied('select public.start_task_with_origin($1,$2)',[invalid,value]);
    assert.equal((await load(invalid)).started_at,null);
    assert.equal((await client.query("update public.task_instances set start_origin='child_mode' where id=$1",[invalid])).rowCount,0);
    assert.equal((await load(invalid)).start_origin,'unknown');
    await login(outsider);await denied("select public.start_task_with_origin($1,'child_mode')",[invalid]);await auth();
  });
  await check('offline ordinary starts preserve the original source and UUID through replay, predecessor timing and completion',async()=>{
    const id=await task(),start=await command(id,'start',{start_origin:'parent_assisted'});
    const first=await apply(start);assert.equal(first.outcome,'applied');assert.equal(first.task.start_origin,'parent_assisted');
    assert.equal(first.task.sync_version,1);
    assert.equal((await apply(start)).task.sync_version,1);
    await denied('select public.apply_task_command($1)',[{...start,start_origin:'child_mode'}]);
    const pause=await command(id,'pause',{predecessor_id:start.command_id});assert.equal((await apply(pause)).outcome,'applied');
    const resume=await command(id,'resume',{predecessor_id:pause.command_id});await apply(resume);
    const complete=await command(id,'complete',{predecessor_id:resume.command_id});const result=await apply(complete);
    assert.equal(result.task.status,'completed');assert.equal(result.task.start_origin,'parent_assisted');
    assert.equal(result.task.start_observed_at,first.task.start_observed_at);
    const version=result.task.sync_version;assert.equal((await apply(start)).task.sync_version,version);
    await denied('select public.apply_task_command($1)',[{...pause,start_origin:'child_mode'}]);
  });
  await check('invalid or rejected offline starts do not persist attribution and old source-free commands remain valid',async()=>{
    const id=await task(),original=await command(id);
    for(const value of [null,'parent',false,{},5]) await denied('select public.apply_task_command($1)',[{...original,start_origin:value}]);
    const future={...original,occurred_at:'2999-01-01T00:00:00Z',start_origin:'child_mode'};
    assert.equal((await apply(future)).outcome,'conflict');
    assert.equal((await load(id)).start_origin,'unknown');assert.equal((await load(id)).start_observed_at,null);
    const result=await apply(original);assert.equal(result.outcome,'applied');assert.equal(result.task.start_origin,'unknown');
    await denied('select public.apply_task_command($1)',[{...original,start_origin:'child_mode'}]);
  });
  await check('review starts digest source with the original command and preserve it through answer and completion',async()=>{
    const reviewChild=await scalar("select public.create_child($1,'Review starts',2::smallint)",[family]);
    const question=await scalar('select public.save_review_question($1,$2)',[reviewChild,{kind:'pinyin',subject:'chinese',prompt:'银行',answers:['yín háng'],context:'去银行',pronunciation_confirmed:true}]);
    const snapshot=await scalar('select public.task_sync_snapshot($1)',[reviewChild]);const task=snapshot.tasks.find(t=>t.source_type==='automatic_wrong_review');
    const base={task_id:task.id,lease_id:snapshot.lease_id,expected_version:task.sync_version,predecessor_id:null};
    const start={...base,command_id:randomUUID(),kind:'review_start',start_origin:'child_mode',occurred_at:await scalar('select clock_timestamp()::text')};
    const first=await apply(start);assert.equal(first.review.task.start_origin,'child_mode');assert.equal(first.task.sync_version,task.sync_version+1);
    assert.equal((await apply(start)).task.sync_version,first.task.sync_version);await denied('select public.apply_task_command($1)',[{...start,start_origin:'parent_assisted'}]);
    const version=await scalar('select content_version from public.wrong_questions where id=$1',[question]);
    const answer={...base,command_id:randomUUID(),kind:'review_answer',predecessor_id:start.command_id,occurred_at:await scalar('select clock_timestamp()::text'),question_id:question,question_version:Number(version),answer:'yin2 hang2'};
    const result=await apply(answer);assert.equal(result.review.items[0].result,true);assert.equal(result.task.start_origin,'child_mode');
    await denied('select public.apply_task_command($1)',[{...answer,start_origin:'child_mode'}]);
    await client.query('reset role');const receipt=await scalar('select request from public.task_command_receipts where command_id=$1',[start.command_id]);
    assert.deepEqual(Object.keys(receipt).sort(),['digest','occurred_at']);await auth();
    const done=await apply({...base,command_id:randomUUID(),kind:'review_complete',predecessor_id:answer.command_id,occurred_at:await scalar('select clock_timestamp()::text')});
    assert.equal(done.task.status,'completed');assert.equal(done.task.start_origin,'child_mode');
  });
  await check('two devices cannot replace the winning first-start source or increment version twice for a duplicate UUID',async()=>{
    const id=await task(),a=await command(id,'start',{start_origin:'child_mode'}),b={...a,command_id:randomUUID(),start_origin:'parent_assisted'};
    const peer=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});await peer.connect();
    try {
      await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:owner,role:'authenticated',session_id:'start-metrics-session'})]);await peer.query('set role authenticated');
      const [left,right]=await Promise.all([apply(a),peer.query('select public.apply_task_command($1) result',[b]).then(r=>r.rows[0].result)]);
      assert.equal([left,right].filter(r=>r.outcome==='applied').length,1);assert.equal([left,right].filter(r=>r.outcome==='conflict').length,1);
      const winner=left.outcome==='applied'?a:b;
      assert.equal((await load(id)).start_origin,winner.start_origin);assert.equal((await load(id)).sync_version,1);
      await Promise.all([apply(winner),peer.query('select public.apply_task_command($1)',[winner])]);assert.equal((await load(id)).sync_version,1);
    } finally {await peer.end();}
  });
  let reportChild;
  await check('start rate uses executable due-date cohorts, approved leave, exact window bounds and family daylight saving',async()=>{
    reportChild=await scalar("select public.create_child($1,'Start report',2::smallint)",[family]);
    await client.query('reset role');
    const template=await scalar("insert into public.task_templates(child_id,title) values($1,'Excused') returning id",[reportChild]);
    const plan=await scalar('insert into public.long_plans(template_id,minimum_rate,bonus_coins,bonus_xp) values($1,1,0,0) returning id',[template]);
    await client.query("insert into public.plan_leaves values($1,'2026-03-08','approved')",[plan]);
    async function seed(start,origin='child_mode',extra={}){
      return scalar(`insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key,status,started_at,start_origin,scheduled_at,due_at,template_id)
        values($1,'Historical start',$2,'parent_template',$3,$4,$5,$6,$7,$8,$9) returning id`,[
        reportChild,extra.day??'2026-03-08',randomUUID(),extra.status??(start?'in_progress':'ready'),start,origin,extra.lower??null,extra.upper??null,extra.template??null]);
    }
    await client.query('alter table public.task_instances disable trigger capture_task_start_origin');
    try {
      await seed('2026-03-08T05:00Z');await seed('2026-03-09T03:59:59Z');await seed('2026-03-09T04:00Z');
      await seed('2026-03-08T15:00Z','parent_assisted');await seed(null,'unknown');await seed(null,'unknown',{status:'abandoned'});
      await seed('2026-03-08T06:00Z','child_mode',{template});
      await seed('2026-11-01T05:30Z','child_mode',{day:'2026-11-01'});await seed('2026-11-01T06:30Z','child_mode',{day:'2026-11-01'});
      await seed('2026-11-02T05:00Z','child_mode',{day:'2026-11-01'});
    } finally {await client.query('alter table public.task_instances enable trigger capture_task_start_origin');}
    await auth();
    const read=async(period='day',day='2026-03-08')=>(await scalar('select public.learning_report($1,$2,$3)',[reportChild,period,day])).start_metrics;
    assert.deepEqual(await read(),{version:'start-v1',eligible:6,autonomous:2,outside_window:1,parent_assisted:1,unknown:0,not_started:2,future_windows:0,invalid_windows:0,rate:0.3333});
    assert.equal((await read('week')).eligible,6);assert.equal((await read('month')).rate,0.3333);
    assert.equal((await read('day','2026-11-01')).autonomous,2);assert.equal((await read('day','2026-11-01')).outside_window,1);
    assert.equal((await read('day','2026-02-01')).rate,null);
    await client.query('reset role');
    await seed('2026-03-08T12:00Z','unknown');
    await seed(null,'unknown',{day:'2026-03-09',lower:'2998-01-01',upper:'2998-01-02'});
    await auth();assert.equal((await read()).unknown,1);assert.equal((await read()).rate,null);assert.equal((await read('month')).future_windows,1);
    await client.query('reset role');await seed(null,'unknown',{day:'2026-03-10',lower:'2026-03-10T12:00Z',upper:'2026-03-10T11:00Z'});
    await auth();assert.equal((await read('day','2026-03-10')).invalid_windows,1);assert.equal((await read('day','2026-03-10')).rate,null);
  });
  await check('start metadata follows existing export and child deletion while report and helpers keep their authorization boundaries',async()=>{
    await denied("select public.learning_report_before_start_metrics($1,'day',null)",[child]);
    await denied('select public.apply_task_command_before_review($1)',[{}]);
    await login(owner,'start-no-pin');await denied("select public.learning_report($1,'day',null)",[child]);await auth();
    const preview=await scalar('select public.preview_child_export($1)',[child]);
    const job=await scalar("select public.prepare_child_export($1,$2,$3,'导出孩子数据')",[child,randomUUID(),preview.counts]);
    assert.ok(job.sections.find(s=>s.name==='tasks').columns.includes('start_origin'));assert.equal(job.sections.length,40);
    const rows=await scalar("select public.read_child_export_page($1,'tasks',0)",[job.id]);
    assert.ok(rows.rows.some(r=>r.start_origin==='parent_assisted'&&r.start_observed_at));
    const deletion=await scalar('select public.preview_child_deletion($1)',[reportChild]);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[reportChild,randomUUID(),deletion.counts]);
    await denied("select public.learning_report($1,'day',null)",[reportChild]);
    await client.query('reset role');assert.equal(await scalar('select count(*)::int from public.task_instances where child_id=$1',[reportChild]),0);
  });
  await login();
}
