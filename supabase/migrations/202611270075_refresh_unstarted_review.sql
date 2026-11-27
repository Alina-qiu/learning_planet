-- A daily review follows the due queue until its first successful start. Keep
-- its ID across empty/non-empty transitions for notes, receipts and old clients.
alter table public.task_instances
  add column review_queue_limit smallint not null default 10 check(review_queue_limit between 1 and 10),
  add column review_waiting_for_due boolean not null default false
    check(not review_waiting_for_due or
      (source_type='automatic_wrong_review' and status='skipped' and started_at is null));

create policy hide_withdrawn_reviews on public.task_instances as restrictive
  for select to authenticated using (not review_waiting_for_due);

create or replace function public.generate_daily_wrong_review_task_before_timezone(
  target_child_id uuid, target_date date default null, max_questions integer default 10
) returns uuid language plpgsql security definer set search_path='' as $$
declare
  t public.task_instances;
  zone text;
  family_now timestamp;
  today date;
  queue_limit smallint := greatest(1,least(coalesce(max_questions,10),10));
  selected_questions uuid[];
  previously_locked uuid[];
  items_changed boolean;
  coins integer;
  xp integer;
begin
  if auth.role() is distinct from 'service_role' and not public.child_is_visible(target_child_id) then
    raise exception 'Child access required' using errcode='42501';
  end if;
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id
    where c.id=target_child_id;
  if zone is null then raise exception 'Child not found'; end if;
  family_now := now() at time zone zone;
  today := family_now::date;
  if auth.role() is distinct from 'service_role' and target_date is not null and target_date<>today then
    raise exception 'Only family today can be generated';
  end if;
  target_date := coalesce(target_date,today);
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id,0));
  select * into t from public.task_instances where child_id=target_child_id
    and due_date=target_date and source_type='automatic_wrong_review' for update;
  if found then
    if t.due_date<>today or t.started_at is not null or not t.review_auto_complete
      or t.review_reward_policy<>2 or (t.status not in ('ready','scheduled') and not t.review_waiting_for_due) then
      return case when not t.review_waiting_for_due then t.id end;
    end if;
    queue_limit := t.review_queue_limit;
  elsif target_date=today and family_now::time<time '00:05' then
    return null;
  end if;

  -- At READ COMMITTED a row can lose its top-ten rank while FOR SHARE waits
  -- for an edit. Re-read the ranking after locking so the next eligible row
  -- can take its place. The confirmed row set stays locked through start.
  loop
    select coalesce(array_agg(c.id order by c.due_day,c.wrong_count desc,c.last_answer_confidence asc nulls last,c.id),'{}'::uuid[])
      into selected_questions from (
        select w.id,(w.review_due_at at time zone zone)::date as due_day,w.wrong_count,w.last_answer_confidence
        from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
        where w.child_id=target_child_id and not w.archived and not w.deleting and w.mastery_status<>'mastered'
          and w.review_due_at<((target_date+1)::timestamp at time zone zone)
        order by due_day,w.wrong_count desc,w.last_answer_confidence asc nulls last,w.id
        limit queue_limit for share of w,a
      ) c;
    exit when cardinality(selected_questions)=0 or previously_locked=selected_questions;
    previously_locked := selected_questions;
  end loop;
  if cardinality(selected_questions)=0 then
    if t.id is not null and not t.review_waiting_for_due then
      delete from public.task_review_answer_keys where task_id=t.id;
      delete from public.task_review_items where task_instance_id=t.id;
      -- The terminal-status trigger cancels the previous reminder atomically.
      update public.task_instances set review_waiting_for_due=true,status='skipped',
        expected_minutes=1,coin_reward=0,xp_reward=0 where id=t.id;
    end if;
    return null;
  end if;

  if t.id is null then
    insert into public.task_instances(child_id,title,due_date,source_type,coin_reward,xp_reward,
      idempotency_key,review_reward_policy,review_auto_complete,review_queue_limit)
      values(target_child_id,'今日错题与拼音复习',target_date,'automatic_wrong_review',0,0,
        'auto-review:'||target_child_id||':'||target_date,2,true,queue_limit) returning * into t;
  end if;

  -- Compare private keys as well as the ordered public snapshot. A prompt or
  -- key edit needs a new sync version even if the cap, reward and IDs match.
  select exists(
    select 1 from unnest(selected_questions) with ordinality p(id,seq)
    join public.wrong_questions w on w.id=p.id
    join public.wrong_question_answers a on a.question_id=p.id
    left join public.task_review_items i on i.task_instance_id=t.id and i.wrong_question_id=p.id
    left join public.task_review_answer_keys k on k.task_id=t.id and k.question_id=p.id
    where row(p.seq,w.content_version,w.final_text,w.subject,w.knowledge_point,w.review_kind,
        w.pronunciation_context,w.last_answer_confidence,w.review_step,w.review_due_at,a.accepted_answers,a.explanation)
      is distinct from row(i.sequence,i.question_version,i.prompt,i.subject,i.knowledge_point,i.review_kind,
        i.pronunciation_context,i.previous_answer_confidence,i.review_step_snapshot,i.review_due_snapshot,k.accepted_answers,k.explanation)
  ) or exists(select 1 from public.task_review_items i where i.task_instance_id=t.id
      and not(i.wrong_question_id=any(selected_questions))) into items_changed;

  if items_changed then
    delete from public.task_review_answer_keys where task_id=t.id;
    delete from public.task_review_items where task_instance_id=t.id;
    insert into public.task_review_items(task_instance_id,wrong_question_id,sequence,prompt,subject,
      knowledge_point,review_kind,pronunciation_context,question_version,previous_answer_confidence)
      select t.id,w.id,p.seq::smallint,w.final_text,w.subject,w.knowledge_point,w.review_kind,
        w.pronunciation_context,w.content_version,w.last_answer_confidence
      from unnest(selected_questions) with ordinality p(id,seq) join public.wrong_questions w on w.id=p.id;
    insert into public.task_review_answer_keys(task_id,question_id,accepted_answers,explanation)
      select t.id,a.question_id,a.accepted_answers,a.explanation from public.wrong_question_answers a
      where a.question_id=any(selected_questions);
  end if;
  select coalesce(sum(case i.reward_stage when 0 then 15 when 3 then 25 when 4 then 40 else 0 end),0),
      coalesce(sum(case i.reward_stage when 0 then 15 when 3 then 20 when 4 then 30 else 0 end),0)
    into coins,xp from public.task_review_items i where i.task_instance_id=t.id and not exists(
      select 1 from public.review_milestone_awards r where r.question_id=i.wrong_question_id
        and r.question_version=i.question_version and r.stage=i.reward_stage);
  if items_changed or t.review_waiting_for_due or
    row(t.coin_reward,t.xp_reward,t.expected_minutes) is distinct from row(coins,xp,cardinality(selected_questions)*2) then
    update public.task_instances set sync_version=sync_version+1,coin_reward=coins,xp_reward=xp,
      expected_minutes=cardinality(selected_questions)*2,review_waiting_for_due=false,
      status=case when t.review_waiting_for_due then 'ready'::public.task_status else t.status end where id=t.id;
  end if;
  return t.id;
end $$;

-- Detail and start use the same family/child/task lock order as generation.
-- A started task never needs the child lock, including when read from inside
-- an answer transaction that already holds the task row.
create function public.refresh_review_before_start(target_task_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare t public.task_instances;
begin
  select * into t from public.task_instances where id=target_task_id;
  if not found or t.source_type<>'automatic_wrong_review' or t.started_at is not null
    or (t.status not in ('ready','scheduled') and not t.review_waiting_for_due)
    or not t.review_auto_complete or t.review_reward_policy<>2 then return; end if;
  perform 1 from public.families where id=(select family_id from public.children where id=t.child_id) for key share;
  if not public.child_is_visible(t.child_id) then raise exception 'Review task access required' using errcode='42501'; end if;
  if t.due_date=public.family_today(t.child_id)::date then
    perform public.generate_daily_wrong_review_task_before_timezone(t.child_id,t.due_date,t.review_queue_limit);
  end if;
end $$;
revoke all on function public.refresh_review_before_start(uuid) from public,anon,authenticated,service_role;

alter function public.load_review_task(uuid) rename to load_review_task_snapshot;
revoke all on function public.load_review_task_snapshot(uuid) from public,anon,authenticated,service_role;
create function public.load_review_task(target_task_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  perform public.refresh_review_before_start(target_task_id);
  return public.load_review_task_snapshot(target_task_id);
end $$;
revoke all on function public.load_review_task(uuid) from public,anon,authenticated,service_role;
grant execute on function public.load_review_task(uuid) to authenticated;

create or replace function public.start_task_with_origin(target_task_id uuid,requested_origin text) returns public.task_instances
language plpgsql security definer set search_path='' as $$
declare t public.task_instances;
begin
  if requested_origin is null or requested_origin not in ('unknown','child_mode','parent_assisted') then
    raise exception 'Invalid start origin' using errcode='22023'; end if;
  perform public.refresh_review_before_start(target_task_id);
  select * into t from public.task_instances where id=target_task_id for update;
  if not found or not public.child_is_visible(t.child_id) then
    raise exception 'Task access required' using errcode='42501'; end if;
  if t.review_waiting_for_due then return t; end if;
  if t.status not in ('scheduled','ready') then raise exception 'Task cannot be started from current status'; end if;
  update public.task_instances set status='in_progress',started_at=coalesce(started_at,now()),active_started_at=now(),
    start_origin=case when started_at is null then requested_origin else start_origin end
    where id=t.id returning * into t;
  return t;
end $$;

create or replace function public.start_task(target_task_id uuid) returns public.task_instances
language sql security definer set search_path='' as $$
  select * from public.start_task_with_origin(target_task_id,'unknown');
$$;

create or replace function public.apply_task_command(command jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  task_id uuid := (command->>'task_id')::uuid;
  result jsonb;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  perform 1 from public.families where id=(select c.family_id from public.children c
    join public.task_instances t on t.child_id=c.id where t.id=task_id) for key share;
  if command->>'kind'='review_start' then
    perform pg_advisory_xact_lock(hashtextextended('task-command:'||auth.uid()||':'||((command->>'command_id')::uuid)::text,0));
    perform public.refresh_review_before_start(task_id);
  end if;
  result := public.apply_task_command_before_membership(command);
  if command->>'kind'='review_start' and result->>'outcome'='conflict' then
    if ((result->'task'->>'review_waiting_for_due')::boolean and
        result->>'reason'='复习已结束或题目已清理，请采用服务端状态') or
      (result->'task'->>'started_at' is null and result->>'reason'='另一台设备已修改复习，请采用服务端状态') then
      result := result||jsonb_build_object('reason','题目快照已改变，请重新加载复习');
    end if;
    result := result||jsonb_build_object('review',public.load_review_task_snapshot(task_id));
  end if;
  return result;
end $$;

-- Exclude withdrawn reviews where task cohorts are constructed, including
-- completion rates and autonomous starts. Voluntarily skipped tasks still count.

create or replace function public.task_sync_snapshot_before_review(target_child_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare lease public.task_sync_leases; snapshot jsonb;
begin
  if auth.uid() is null or not public.child_is_visible(target_child_id) then
    raise exception 'Child access required' using errcode='42501';
  end if;
  perform public.generate_scheduled_tasks(target_child_id);
  delete from public.task_sync_leases where user_id=auth.uid() and expires_at<now();
  select * into lease from public.task_sync_leases where user_id=auth.uid()
    and child_id=target_child_id and issued_at>now()-interval '15 minutes'
    and expires_at>now()+interval '6 days' order by issued_at desc limit 1;
  if not found then
    insert into public.task_sync_leases(user_id,child_id) values(auth.uid(),target_child_id)
      returning * into lease;
  end if;
  -- One statement observes a consistent task/wallet snapshot after generation.
  select jsonb_build_object(
    'lease_id',lease.id,'lease_expires_at',lease.expires_at,'server_at',clock_timestamp(),
    'timezone',f.timezone,'day',(now() at time zone f.timezone)::date,
    'tasks',coalesce((select jsonb_agg(to_jsonb(t) order by t.due_date,t.created_at,t.id)
      from public.task_instances t where t.child_id=c.id and not t.review_waiting_for_due),'[]'::jsonb),
    'wallet',jsonb_build_object('coin_balance',w.coin_balance,'frozen_balance',w.frozen_balance,'xp',w.xp)
  ) into snapshot from public.children c join public.families f on f.id=c.family_id
    join public.wallets w on w.child_id=c.id where c.id=target_child_id;
  return snapshot;
end;
$$;

create or replace function public.learning_report_before_business_metrics(target_child_id uuid, report_period text default 'week', anchor_date date default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare family uuid; zone text; today date; first_day date; last_day date;
  first_instant timestamptz; last_instant timestamptz; daily jsonb; totals jsonb;
  reviews jsonb; coins jsonb; activities jsonb; due_now integer; activity_count integer;
begin
  select c.family_id,f.timezone into family,zone from public.children c
    join public.families f on f.id=c.family_id where c.id=target_child_id;
  perform public.require_parent_authorization(family);
  if report_period is null or report_period not in ('day','week','month') then
    raise exception 'Unsupported report period' using errcode='22023';
  end if;
  today:=(now() at time zone zone)::date;
  last_day:=coalesce(anchor_date,today);
  if not isfinite(last_day) or last_day>today or last_day<date '2000-01-01' then
    raise exception 'Invalid report date' using errcode='22023';
  end if;
  if report_period='month' then
    first_day:=date_trunc('month',last_day)::date;
    last_day:=least(today,(first_day+interval '1 month'-interval '1 day')::date);
  else
    first_day:=last_day-case when report_period='week' then 6 else 0 end;
  end if;
  first_instant:=first_day::timestamp at time zone zone;
  last_instant:=(last_day+1)::timestamp at time zone zone;

  -- The rate is a cohort of generated instances by due date, with approved
  -- plan leave removed. A voluntary skip still counts in the denominator.
  with eligible as (
    select t.* from public.task_instances t
    where t.child_id=target_child_id and not t.review_waiting_for_due and t.due_date between first_day and last_day
      and not exists(select 1 from public.long_plans p join public.plan_leaves l on l.plan_id=p.id
        where p.template_id=t.template_id and l.leave_date=t.due_date)
  ), days as (
    select first_day+n as day from generate_series(0,last_day-first_day) n
  ), stats as (
    select d.day,count(t.id)::integer as expected,
      count(t.id) filter(where t.status='completed')::integer as completed,
      coalesce(sum(t.accumulated_seconds),0) as effective_seconds
    from days d left join eligible t on t.due_date=d.day group by d.day
  ) select jsonb_agg(to_jsonb(s) order by day),jsonb_build_object(
    'expected',sum(expected),'completed',sum(completed),'effective_seconds',sum(effective_seconds),
    'completion_rate',case when sum(expected)>0 then round(sum(completed)::numeric/sum(expected),4) else null end)
    into daily,totals from stats s;

  select jsonb_build_object('answered',count(*),'correct',count(*) filter(where i.result),
    'accuracy',case when count(*)>0 then round(count(*) filter(where i.result)::numeric/count(*),4) else null end)
    into reviews from public.task_review_items i join public.task_instances t on t.id=i.task_instance_id
    where t.child_id=target_child_id and i.answered_at>=first_instant and i.answered_at<last_instant
      and i.result is not null;
  select count(*) into due_now from public.wrong_questions q where q.child_id=target_child_id
    and not q.archived and not q.deleting and q.mastery_status<>'mastered'
    and q.review_due_at<(today+1)::timestamp at time zone zone;
  -- Freezing and refunding are transfers, not income or consumption.
  select jsonb_build_object(
    'income',coalesce(sum(amount) filter(where asset_type='coin' and amount>0 and source_type<>'redemption_refund'),0),
    'spent',coalesce(sum(-frozen_delta) filter(where source_type='redemption_spend'),0),
    'adjustment_out',coalesce(sum(-amount) filter(where asset_type='coin' and amount<0 and source_type<>'redemption_freeze'),0),
    'xp',coalesce(sum(amount) filter(where asset_type='xp'),0)) into coins
    from public.ledger_entries where child_id=target_child_id and created_at>=first_instant and created_at<last_instant;

  select count(*) into activity_count from public.task_instances
    where child_id=target_child_id and status='completed' and completed_at>=first_instant and completed_at<last_instant;
  select coalesce(jsonb_agg(to_jsonb(a) order by a.completed_at desc,a.id),'[]') into activities from (
    select id,title,due_date,(completed_at at time zone zone) as completed_at,accumulated_seconds as effective_seconds,source_type,growth_category
    from public.task_instances where child_id=target_child_id and status='completed'
      and completed_at>=first_instant and completed_at<last_instant
    order by completed_at desc,id limit 200
  ) a;
  return jsonb_build_object('child_id',target_child_id,'period',report_period,'timezone',zone,
    'today',today,'start_date',first_day,'end_date',last_day,'generated_at',now(),
    'days',daily,'tasks',totals,'reviews',reviews,'due_now',due_now,'coins',coins,
    'activities',activities,'activity_count',activity_count)||case when report_period='month' then
    jsonb_build_object('growth',public.monthly_growth_trends(target_child_id,first_day,today,zone),
      'knowledge',public.monthly_knowledge_distribution(target_child_id,first_instant,last_instant))
    else '{}'::jsonb end;
end $$;

create or replace function public.learning_report_before_retention(target_child_id uuid, report_period text default 'week', anchor_date date default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare report jsonb; stats jsonb;
begin
  report:=public.learning_report_before_start_metrics(target_child_id,report_period,anchor_date);
  with cohort as (
    select t.*,coalesce(t.scheduled_at,t.due_date::timestamp at time zone (report->>'timezone')) window_start,
      coalesce(t.due_at,(t.due_date+1)::timestamp at time zone (report->>'timezone')) window_end
    from public.task_instances t where t.child_id=target_child_id and not t.review_waiting_for_due
      and t.due_date between (report->>'start_date')::date and (report->>'end_date')::date
      and not exists(select 1 from public.long_plans p join public.plan_leaves l on l.plan_id=p.id
        where p.template_id=t.template_id and l.leave_date=t.due_date)
  ), eligible as (
    select * from cohort where window_end>window_start and window_start<=now()
  ), counts as (
    select count(*) eligible,
      count(*) filter(where started_at is not null and start_origin='child_mode' and started_at>=window_start and started_at<window_end) autonomous,
      count(*) filter(where started_at is not null and start_origin='child_mode' and (started_at<window_start or started_at>=window_end)) outside_window,
      count(*) filter(where started_at is not null and start_origin='parent_assisted') parent_assisted,
      count(*) filter(where started_at is not null and start_origin='unknown') unknown,
      count(*) filter(where started_at is null) not_started,
      (select count(*) from cohort where window_end>window_start and window_start>now()) future_windows,
      (select count(*) from cohort where window_end<=window_start) invalid_windows
    from eligible
  ) select to_jsonb(c)||jsonb_build_object('version','start-v1','rate',case when eligible>0 and unknown=0 and invalid_windows=0
    then round(autonomous::numeric/eligible,4) else null end) into stats from counts c;
  return report||jsonb_build_object('start_metrics',stats);
end $$;

create or replace function public.family_overview(target_family_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare family public.families; today date; result jsonb;
begin
  perform public.require_parent_authorization(target_family_id);
  select * into strict family from public.families where id=target_family_id;
  today:=(now() at time zone family.timezone)::date;
  with kids as materialized (
    select id,nickname,created_at from public.children where family_id=target_family_id
  ), eligible as materialized (
    select t.child_id,t.due_date,t.status from public.task_instances t
      join kids c on c.id=t.child_id
    where not t.review_waiting_for_due and t.due_date between today-6 and today
      and not exists(select 1 from public.long_plans p join public.plan_leaves l on l.plan_id=p.id
        where p.template_id=t.template_id and l.leave_date=t.due_date)
  ), days as (
    select c.id as child_id,today-6+n as day from kids c cross join generate_series(0,6) n
  ), daily as (
    select d.child_id,d.day,count(t.child_id)::integer expected,
      count(t.child_id) filter(where t.status='completed')::integer completed
    from days d left join eligible t on t.child_id=d.child_id and t.due_date=d.day
    group by d.child_id,d.day
  ), claims as (
    select r.child_id,
      count(*) filter(where r.status='requested' and r.expires_at>now())::integer requested,
      count(*) filter(where r.status='approved' and r.expires_at>now())::integer approved,
      count(*) filter(where r.expires_at<=now())::integer awaiting_expiry
    from public.redemptions r join kids c on c.id=r.child_id
    where r.status in ('requested','approved') group by r.child_id
  ), awards as (
    select a.child_id,count(*)::integer pending_awards,sum(a.amount) pending_coins
    from public.pending_coin_awards a join kids c on c.id=a.child_id
    where a.status='pending' group by a.child_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'child_id',c.id,'nickname',c.nickname,
    'days',(select jsonb_agg(jsonb_build_object('day',d.day,'expected',d.expected,'completed',d.completed)
      order by d.day) from daily d where d.child_id=c.id),
    'requested',coalesce(r.requested,0),'approved',coalesce(r.approved,0),
    'awaiting_expiry',coalesce(r.awaiting_expiry,0),
    'pending_awards',coalesce(a.pending_awards,0),'pending_coins',coalesce(a.pending_coins,0)
  ) order by c.created_at,c.id),'[]'::jsonb) into result
  from kids c left join claims r on r.child_id=c.id left join awards a on a.child_id=c.id;
  return jsonb_build_object('family_id',family.id,'family_name',family.name,
    'timezone',family.timezone,'today',today,'generated_at',now(),'children',result);
end $$;

-- Removing a source after start still cancels the affected frozen review.
-- Before start, keep the other questions and recompute from the remaining due pool.

create or replace function public.request_question_cleanup(target_child_id uuid, operation text, ids uuid[], request_id uuid, confirmation text)
returns uuid language plpgsql security definer set search_path='' as $$
declare family uuid; existing public.cleanup_jobs; preview jsonb; selected uuid[]; drafts uuid[];
begin
  select family_id into family from public.children where id=target_child_id;
  perform 1 from public.families where id=family for key share;
  perform public.require_parent_authorization(family);
  if request_id is null or confirmation is distinct from '永久删除' then raise exception '请明确确认永久删除，无法恢复'; end if;
  perform pg_advisory_xact_lock(hashtextextended('cleanup:'||target_child_id::text,0));
  select * into existing from public.cleanup_jobs where id=request_id;
  if found then
    if existing.child_id<>target_child_id or existing.owner_id<>auth.uid() or existing.scope<>operation
      or (operation<>'abandoned_ocr' and not (existing.question_ids @> ids and ids @> existing.question_ids)) then raise exception '清理标识已用于其他请求'; end if;
    return existing.id;
  end if;
  preview:=public.preview_question_cleanup(target_child_id,operation,ids);
  select coalesce(array_agg(value::uuid),'{}') into selected from jsonb_array_elements_text(preview->'question_ids');
  select coalesce(array_agg(value::uuid),'{}') into drafts from jsonb_array_elements_text(preview->'draft_ids');
  if cardinality(selected)=0 and cardinality(drafts)=0 then raise exception '没有可清理记录'; end if;
  if exists(select 1 from public.cleanup_jobs where child_id=target_child_id and status<>'completed'
    and (question_ids && selected or draft_ids && drafts)) then raise exception '已有相关清理任务，请先重试该任务'; end if;
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id::text,0));
  -- Same task-before-item/question order as grading; cancelled tasks cannot pay after the request.
  if operation='questions' then
    perform 1 from public.task_instances t where exists(select 1 from public.task_review_items i
      where i.task_instance_id=t.id and i.wrong_question_id=any(selected)) order by t.id for update;
    update public.task_instances t set status='skipped',active_started_at=null where status not in ('completed','skipped','expired','abandoned')
      and not (t.due_date=public.family_today(target_child_id)::date and t.review_auto_complete
        and t.review_reward_policy=2 and t.status in ('ready','scheduled') and t.started_at is null)
      and exists(select 1 from public.task_review_items i where i.task_instance_id=t.id and i.wrong_question_id=any(selected));
    update public.wrong_questions set archived=true,deleting=true where id=any(selected);
    perform public.refresh_review_before_start(t.id) from public.task_instances t
      where t.child_id=target_child_id and t.source_type='automatic_wrong_review'
        and t.due_date=public.family_today(target_child_id)::date
        and exists(select 1 from public.task_review_items i where i.task_instance_id=t.id and i.wrong_question_id=any(selected));
  end if;
  update public.question_ocr_drafts set deleting=true where id=any(drafts);
  insert into public.cleanup_jobs(id,family_id,child_id,owner_id,scope,question_ids,draft_ids,manifest)
    values(request_id,family,target_child_id,auth.uid(),operation,selected,drafts,preview->'manifest');
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'cleanup.request','cleanup_job',request_id::text,
      jsonb_build_object('scope',operation,'questions',cardinality(selected),'files',preview->'files'));
  return request_id;
end $$;
