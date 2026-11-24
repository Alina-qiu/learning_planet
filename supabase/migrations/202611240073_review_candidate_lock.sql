-- A question can be archived while generation waits for its row lock. Bind the
-- daily instance to the final locked rows, including their private answer keys.
create or replace function public.generate_daily_wrong_review_task_before_timezone(
  target_child_id uuid, target_date date default null, max_questions integer default 10
) returns uuid language plpgsql security definer set search_path='' as $$
declare
  task_id uuid;
  zone text;
  family_now timestamp;
  today date;
  selected_questions uuid[];
begin
  if auth.role() is distinct from 'service_role' and not public.child_is_visible(target_child_id) then
    raise exception 'Child access required' using errcode='42501';
  end if;
  select f.timezone into zone
    from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  if zone is null then raise exception 'Child not found'; end if;
  family_now := now() at time zone zone;
  today := family_now::date;
  if auth.role() is distinct from 'service_role' and target_date is not null and target_date<>today then
    raise exception 'Only family today can be generated';
  end if;
  target_date := coalesce(target_date,today);
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id,0));
  select id into task_id from public.task_instances where child_id=target_child_id
    and due_date=target_date and source_type='automatic_wrong_review' for update;
  if found then return task_id; end if;
  -- Startup and reconnection share the scheduler's local cutoff. An existing
  -- snapshot stays available across zone changes; trusted explicit dates keep
  -- their historical maintenance behavior.
  if target_date=today and family_now::time < time '00:05' then return null; end if;

  select array_agg(c.id order by c.due_day,c.wrong_count desc,c.last_answer_confidence asc nulls last,c.id)
    into selected_questions
    from (
      select w.id,(w.review_due_at at time zone zone)::date as due_day,w.wrong_count,w.last_answer_confidence
      from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
      where w.child_id=target_child_id and not w.archived and not w.deleting and w.mastery_status<>'mastered'
        and w.review_due_at<((target_date+1)::timestamp at time zone zone)
      order by due_day,w.wrong_count desc,w.last_answer_confidence asc nulls last,w.id
      limit greatest(1,least(coalesce(max_questions,10),10))
      for share of w,a
    ) c;
  if selected_questions is null then return null; end if;

  insert into public.task_instances(child_id,title,due_date,source_type,coin_reward,xp_reward,idempotency_key,review_reward_policy,review_auto_complete)
    values(target_child_id,'今日错题与拼音复习',target_date,'automatic_wrong_review',0,0,
      'auto-review:'||target_child_id||':'||target_date,2,true) returning id into task_id;
  insert into public.task_review_items(task_instance_id,wrong_question_id,sequence,prompt,subject,
    knowledge_point,review_kind,pronunciation_context,question_version,previous_answer_confidence)
    select task_id,w.id,p.sequence::smallint,w.final_text,w.subject,w.knowledge_point,w.review_kind,
      w.pronunciation_context,w.content_version,w.last_answer_confidence
    from unnest(selected_questions) with ordinality as p(id,sequence)
    join public.wrong_questions w on w.id=p.id;
  insert into public.task_review_answer_keys(task_id,question_id,accepted_answers,explanation)
    select task_id,a.question_id,a.accepted_answers,a.explanation
    from public.wrong_question_answers a where a.question_id=any(selected_questions);
  update public.task_instances set
    coin_reward=(select coalesce(sum(case i.reward_stage when 0 then 15 when 3 then 25 when 4 then 40 else 0 end),0)::integer
      from public.task_review_items i where i.task_instance_id=task_id and not exists(select 1 from public.review_milestone_awards r where r.question_id=i.wrong_question_id and r.question_version=i.question_version and r.stage=i.reward_stage)),
    xp_reward=(select coalesce(sum(case i.reward_stage when 0 then 15 when 3 then 20 when 4 then 30 else 0 end),0)::integer
      from public.task_review_items i where i.task_instance_id=task_id and not exists(select 1 from public.review_milestone_awards r where r.question_id=i.wrong_question_id and r.question_version=i.question_version and r.stage=i.reward_stage)),
    expected_minutes=cardinality(selected_questions)*2
    where id=task_id;
  return task_id;
end $$;

-- The old generator stored exactly one expected minute for zero items; a valid
-- snapshot always had at least two, even if its questions were removed later.
-- Lock each potential orphan before checking its associated records so notes
-- and command receipts committed while obtaining the lock remain visible.
do $$
declare orphan_id uuid;
begin
  -- The public generator takes a family key-share lock before invoking the
  -- replaceable helper. Drain callers of the old version before inspecting rows.
  lock table public.families in exclusive mode;
  for orphan_id in
    select t.id from public.task_instances t
    where t.source_type='automatic_wrong_review' and t.status='ready'
      and t.idempotency_key='auto-review:'||t.child_id||':'||t.due_date
      and t.title='今日错题与拼音复习' and t.expected_minutes=1 and t.sync_version=1
      and t.template_id is null and t.description='' and t.task_kind='standard'
      and t.task_priority='recommended' and t.growth_category='learning'
      and t.scheduled_at is null and t.due_at is null and t.minimum_seconds=0
      and t.started_at is null and t.start_observed_at is null and t.start_origin='unknown'
      and t.active_started_at is null and t.accumulated_seconds=0 and t.completed_at is null
      and t.completion_reason is null and t.abandoned_at is null and t.coin_reward=0 and t.xp_reward=0
    order by t.id for update of t
  loop
    delete from public.task_instances t where t.id=orphan_id
      and not exists(select 1 from public.task_review_items i where i.task_instance_id=t.id)
      and not exists(select 1 from public.task_review_answer_keys k where k.task_id=t.id)
      and not exists(select 1 from public.task_command_receipts c where c.task_id=t.id)
      and not exists(select 1 from public.review_milestone_awards m where m.task_id=t.id)
      and not exists(select 1 from public.review_reminder_requests r where r.task_id=t.id)
      and not exists(select 1 from public.task_notes n where n.task_id=t.id)
      and not exists(select 1 from public.task_note_receipts n where n.task_id=t.id)
      and not exists(select 1 from public.task_time_correction_receipts c where c.task_id=t.id)
      and not exists(select 1 from public.ledger_entries l where l.source_id=t.id)
      and not exists(select 1 from public.pending_coin_awards p where p.source_id=t.id)
      and not exists(select 1 from public.audit_logs a where a.target_id=t.id::text);
  end loop;
end $$;
