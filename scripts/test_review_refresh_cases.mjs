import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';
import {daytimeReviewZone, generateDuringReviewChange} from './fixtures/review_generation.mjs';

export async function reviewRefreshCases({client, scalar, login, denied, check, otherUid}) {
  const owner = randomUUID(), auth = () => login(owner, 'review-refresh');
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)', [owner, 'review-refresh@example.test']);
  await auth();
  const family = await scalar("select public.onboard_family('Refresh',$1,'First',1::smallint)", [await daytimeReviewZone(scalar)]);
  await scalar("select public.set_parent_pin($1,'2468')", [family]);
  await scalar("select public.verify_parent_pin($1,'2468')", [family]);
  const child = () => scalar("select public.create_child($1,'Review',1::smallint)", [family]);
  const save = (cid, prompt, key = '4', id = null) => scalar('select public.save_review_question($1,$2,$3)', [
    cid, {kind:'question', subject:'math', prompt, answers:[key], explanation:'校对后的解析'}, id,
  ]);
  const archive = (cid, ids, flag = true) => scalar('select public.archive_review_questions($1,$2,$3)', [cid, ids, flag]);
  const generate = (cid, cap = 10) => scalar('select public.generate_daily_wrong_review_task($1,null,$2)', [cid, cap]);
  const snapshot = cid => scalar('select public.task_sync_snapshot($1)', [cid]);
  const detail = tid => scalar('select public.load_review_task($1)', [tid]);
  const ids = review => review.items.map(i => i.wrong_question_id);
  const apply = command => scalar('select public.apply_task_command($1)', [command]);
  const startCommand = async (task, cache) => ({
    kind:'review_start', task_id:task.id, command_id:randomUUID(), lease_id:cache.lease_id,
    occurred_at:await scalar('select clock_timestamp()::text'), expected_version:task.sync_version,
  });
  async function counts(cid) {
    const overview = await scalar('select public.family_overview($1)', [family]);
    const parentToday = overview.children.find(c => c.child_id === cid).days.at(-1);
    const report = await scalar("select public.learning_report($1,'day')", [cid]);
    return [parentToday.expected, report.tasks.expected, report.days[0].expected, report.start_metrics.eligible];
  }

  await check('unstarted review preserves its ID and cap while refreshing order, private keys and estimates once per change', async () => {
    const cid = await child(), a = await save(cid,'A'), b = await save(cid,'B');
    const tid = await generate(cid, 2), first = await detail(tid);
    const c = await save(cid,'C');
    await client.query('reset role');
    await client.query("update public.wrong_questions set wrong_count=11,review_step=3 where id=$1", [c]);
    await client.query("update public.wrong_questions set wrong_count=5,last_answer_confidence=3 where id=$1", [b]);
    await auth();
    assert.equal(await generate(cid),tid);
    const reordered = await detail(tid);
    assert.deepEqual(ids(reordered),[c,b]);
    assert.equal(reordered.task.sync_version,first.task.sync_version+1);
    assert.equal(reordered.task.expected_minutes,4);
    assert.equal(reordered.task.coin_reward,40);
    assert.equal(reordered.task.xp_reward,35);
    assert.equal(reordered.items[1].previous_answer_confidence,3);
    assert.ok(reordered.items.every(i => i.accepted_answers === null && i.explanation === null));
    assert.equal((await scalar('select public.review_overview($1)',[cid])).backlog,1);
    assert.equal((await snapshot(cid)).tasks[0].sync_version,reordered.task.sync_version);
    await save(cid,'改正后的 B','5',b);
    const edited = await detail(tid);
    assert.equal(edited.task.sync_version,reordered.task.sync_version+1);
    assert.equal(edited.items.find(i => i.wrong_question_id===b).prompt,'改正后的 B');
    await client.query('reset role');
    assert.deepEqual(await scalar('select accepted_answers from public.task_review_answer_keys where task_id=$1 and question_id=$2',[tid,b]),['5']);
    await auth();
    await archive(cid,[b]);
    const withReplacement = await detail(tid);
    assert.deepEqual(ids(withReplacement),[c,a]);
    assert.deepEqual(await detail(tid),withReplacement);
    // A previously queued review can settle the same milestone on another
    // device without changing the prompts or IDs on this unpublished start.
    await client.query('reset role');
    const historical = await scalar(`insert into public.task_instances(child_id,title,due_date,source_type,status,idempotency_key)
      values($1,'Earlier review',current_date-3,'automatic_wrong_review','completed',$2) returning id`,[cid,randomUUID()]);
    await client.query(`insert into public.review_milestone_awards(child_id,question_id,question_version,stage,task_id)
      select child_id,id,content_version,3,$2 from public.wrong_questions where id=$1`,[c,historical]);
    await auth();
    const reestimated = await detail(tid);
    assert.equal(reestimated.task.coin_reward,15);
    assert.equal(reestimated.task.xp_reward,15);
    assert.equal(reestimated.task.sync_version,withReplacement.task.sync_version+1);
    assert.deepEqual(reestimated.items,withReplacement.items);
  });

  await check('attributed online start freezes current sources and keeps prompt, key and reward through pause and completion', async () => {
    const cid = await child(), a = await save(cid,'旧题'), tid = await generate(cid);
    await save(cid,'点击开始前的题目','5',a);
    const b = await save(cid,'新增题');
    const started = await scalar("select to_jsonb(public.start_task_with_origin($1,'child_mode'))", [tid]);
    assert.equal(started.status,'in_progress');
    assert.equal(started.start_origin,'child_mode');
    const frozen = await detail(tid);
    assert.equal(frozen.items.length,2);
    assert.ok(frozen.items.every(i => i.accepted_answers===null));
    await scalar('select public.pause_task($1)',[tid]);
    await archive(cid,[b]);
    await save(cid,'开始后的编辑','99',a);
    await save(cid,'开始后的新题');
    const paused = await detail(tid);
    assert.deepEqual(paused.items,frozen.items);
    assert.equal(paused.task.coin_reward,30);
    await scalar('select public.resume_task($1)',[tid]);
    const answered = await scalar('select public.submit_review_answer($1,$2,$3,$4)',[tid,a,'5',randomUUID()]);
    assert.equal(answered.items.find(i => i.wrong_question_id===a).result,true);
    assert.deepEqual(answered.items.find(i => i.wrong_question_id===a).accepted_answers,['5']);
    const finished = await scalar('select public.submit_review_answer($1,$2,$3,$4)',[tid,b,'4',randomUUID()]);
    assert.equal(finished.task.status,'completed');
    assert.deepEqual(ids(await detail(tid)),ids(frozen));
  });

  await check('postponed and mastered questions leave the unstarted queue; a rank demotion during a row-lock wait promotes the right replacement', async () => {
    const cid = await child(), a = await save(cid,'最早'), b = await save(cid,'候补');
    await client.query('reset role');
    await client.query('update public.wrong_questions set wrong_count=case when id=$2 then 8 else 4 end where child_id=$1',[cid,a]);
    await auth();
    const tid = await generate(cid,1);
    assert.deepEqual(ids(await detail(tid)),[a]);
    await generateDuringReviewChange(client,cid,async () => {
      await client.query('reset role');
      await client.query('update public.wrong_questions set wrong_count=1 where id=$1',[a]);
      await auth();
    });
    // Inspect the stored result before another refreshing read can fix it.
    assert.equal(await scalar('select wrong_question_id from public.task_review_items where task_instance_id=$1',[tid]),b);
    await client.query('reset role');
    await client.query("update public.wrong_questions set review_due_at=now()+interval '2 days' where id=$1",[b]);
    await auth();
    assert.deepEqual(ids(await detail(tid)),[a]);
    await client.query('reset role');
    await client.query("update public.wrong_questions set mastery_status='mastered',review_due_at=null where id=$1",[a]);
    await auth();
    assert.equal(await generate(cid),null);
    assert.deepEqual((await detail(tid)).items,[]);
  });

  await check('first offline start detects an intervening edit, rejects dependent answers, then accepts the refreshed version exactly once', async () => {
    const cid = await child(), a = await save(cid,'问题'), cache = await snapshot(cid);
    const task = cache.tasks[0], oldStart = await startCommand(task,cache);
    await save(cid,'编辑后的问题','6',a);
    const conflict = await apply(oldStart);
    assert.equal(conflict.outcome,'conflict');
    assert.equal(conflict.reason,'题目快照已改变，请重新加载复习');
    assert.equal(conflict.review.items[0].prompt,'编辑后的问题');
    assert.equal(conflict.review.items[0].accepted_answers,null);
    assert.equal(conflict.review.task.sync_version,task.sync_version+1);
    assert.equal((await apply(oldStart)).task.started_at,null);
    const staleAnswer = {...oldStart,kind:'review_answer',command_id:randomUUID(),predecessor_id:oldStart.command_id,
      question_id:a,question_version:0,answer:'4'};
    assert.equal((await apply(staleAnswer)).outcome,'conflict');
    const version = conflict.review.items[0].question_version;
    const start = await startCommand(conflict.task,cache), accepted = await apply(start);
    assert.equal(accepted.outcome,'applied');
    assert.equal((await apply(start)).task.sync_version,accepted.task.sync_version);
    await save(cid,'忽略后续编辑','7',a);
    const result = await apply({...staleAnswer,command_id:randomUUID(),predecessor_id:start.command_id,
      occurred_at:await scalar('select clock_timestamp()::text'),question_version:version,answer:'6'});
    assert.equal(result.review.items[0].result,true);
    assert.equal(result.review.task.status,'completed');
  });

  await check('empty review withdraws from lists, reminders and reports, prevents every start, then reappears once on the original ID', async () => {
    const cid = await child(), a = await save(cid,'唯一的题'), cache = await snapshot(cid);
    const t = cache.tasks[0], offline = await startCommand(t,cache);
    assert.deepEqual(await counts(cid),[1,1,1,1]);
    await scalar('select public.set_review_reminder($1,15,$2,0)',[t.id,randomUUID()]);
    await archive(cid,[a]);
    const start = await scalar('select to_jsonb(public.start_task($1))',[t.id]);
    assert.equal(start.review_waiting_for_due,true);
    assert.equal(start.started_at,null);
    assert.equal(start.status,'skipped');
    const empty = await detail(t.id), blocked = await apply(offline);
    assert.deepEqual(empty.items,[]);
    assert.deepEqual(blocked.review,empty);
    assert.equal(blocked.outcome,'conflict');
    assert.equal(blocked.reason,'题目快照已改变，请重新加载复习');
    assert.equal(await generate(cid),null);
    assert.equal(await scalar('select count(*)::int from public.task_instances where id=$1',[t.id]),0);
    assert.equal((await snapshot(cid)).tasks.length,0);
    assert.equal((await scalar('select public.review_overview($1)',[cid])).task_id,null);
    assert.equal((await scalar('select public.review_reminder_state($1)',[t.id])).allowed,false);
    await denied('select public.complete_task($1,$2,$3)',[t.id,randomUUID(),'家长补签']);
    await denied('select public.submit_review_answer($1,$2,$3,$4)',[t.id,a,'4',randomUUID()]);
    assert.deepEqual(await counts(cid),[0,0,0,0]);
    assert.equal((await detail(t.id)).task.sync_version,empty.task.sync_version);
    await archive(cid,[a],false);
    assert.equal(await generate(cid),t.id);
    const restored = await detail(t.id);
    assert.equal(restored.task.status,'ready');
    assert.equal(restored.task.review_waiting_for_due,false);
    assert.equal(restored.task.sync_version,empty.task.sync_version+1);
    assert.equal((await snapshot(cid)).tasks.length,1);
    assert.deepEqual(await counts(cid),[1,1,1,1]);
    const reminder = await scalar('select public.review_reminder_state($1)',[t.id]);
    assert.equal(reminder.allowed,true);
    assert.equal(reminder.remind_at,null);
  });

  await check('permanent question removal refreshes an unstarted task without cancelling its remaining due items', async () => {
    const cid = await child(), a = await save(cid,'要移除的题'), b = await save(cid,'保留题'), tid = await generate(cid);
    const remove = id => scalar("select public.request_question_cleanup($1,'questions',$2,$3,'永久删除')",[cid,[id],randomUUID()]);
    await remove(a);
    assert.deepEqual(ids(await detail(tid)),[b]);
    assert.equal((await detail(tid)).task.status,'ready');
    await remove(b);
    assert.equal((await detail(tid)).task.review_waiting_for_due,true);
    assert.equal((await snapshot(cid)).tasks.length,0);
    await save(cid,'替补题');
    assert.equal(await generate(cid),tid);
  });

  await check('concurrent start holds the freeze boundary against a second generator and duplicate offline start', async () => {
    const cid = await child(), a = await save(cid,'并发题'), cache = await snapshot(cid);
    const task = cache.tasks[0], start = await startCommand(task,cache), peer = new pg.Client(client.connectionParameters);
    try {
      await peer.connect();
      await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:owner,role:'authenticated',session_id:'review-refresh-peer'})]);
      await peer.query('set role authenticated');
      await peer.query('begin');
      const applied = (await peer.query('select public.apply_task_command($1) as result',[start])).rows[0].result;
      assert.equal(applied.outcome,'applied');
      await client.query("set lock_timeout='150ms'");
      await assert.rejects(generate(cid),{code:'55P03'});
      await assert.rejects(apply(start),{code:'55P03'});
      await peer.query('commit');
      const replay = await apply(start);
      assert.equal(replay.outcome,'applied');
      assert.equal(replay.task.sync_version,applied.task.sync_version);
      await save(cid,'稍后新增');
      assert.equal(await generate(cid),task.id);
      assert.deepEqual(ids(await detail(task.id)),[a]);
    } finally {
      await client.query('set lock_timeout=0');
      await peer.query('rollback').catch(()=>{});
      await peer.end();
    }
  });

  await check('refresh respects membership and preserves past, legacy and voluntarily terminal reviews', async () => {
    const cid = await child(), a = await save(cid,'原题'), tid = await generate(cid);
    const cache = await snapshot(cid), offline = await startCommand(cache.tasks[0],cache);
    await save(cid,'仍未发布的新版本','7',a);
    await login(otherUid);
    await denied('select public.load_review_task($1)',[tid]);
    await denied('select public.start_task($1)',[tid]);
    await denied('select public.apply_task_command($1)',[offline]);
    await denied('select public.refresh_review_before_start($1)',[tid]);
    await denied('select public.load_review_task_snapshot($1)',[tid]);
    await client.query('reset role');
    assert.equal(Number(await scalar('select sync_version from public.task_instances where id=$1',[tid])),cache.tasks[0].sync_version);
    await client.query("update public.task_instances set due_date=due_date-1 where id=$1",[tid]);
    await auth();
    assert.equal((await detail(tid)).items[0].prompt,'原题');
    for (const change of ["review_auto_complete=false","review_auto_complete=false,review_reward_policy=1","status='abandoned'"]) {
      const nextChild = await child(), q = await save(nextChild,'已发题'), taskId = await generate(nextChild);
      await client.query('reset role');
      await client.query('update public.task_instances set '+change+' where id=$1',[taskId]);
      await auth();
      await save(nextChild,'历史仍保留','8',q);
      assert.equal(await generate(nextChild),taskId);
      assert.equal((await detail(taskId)).items[0].prompt,'已发题');
    }
  });
}
