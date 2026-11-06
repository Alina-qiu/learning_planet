-- PRD 6.5: confidence means the child's self-assessment before grading.
-- Old answers stay unknown. No OCR/model value is copied or inferred.
alter table public.wrong_questions add column last_answer_confidence smallint
  check(last_answer_confidence between 1 and 3);
alter table public.task_review_items add column answer_confidence smallint
  check(answer_confidence between 1 and 3);
alter table public.task_review_items add column previous_answer_confidence smallint
  check(previous_answer_confidence between 1 and 3);

create function public.reset_edited_question_confidence() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.content_version is distinct from old.content_version then new.last_answer_confidence:=null; end if;
  return new;
end $$;
revoke all on function public.reset_edited_question_confidence() from public,anon,authenticated,service_role;
create trigger reset_edited_question_confidence before update of content_version on public.wrong_questions
  for each row execute function public.reset_edited_question_confidence();

-- Keep final-answer grading, timing and milestone settlement in the same
-- transaction. Existing helpers retain their private ACLs.
create function public.submit_review_answer_with_confidence(
  target_task_id uuid,target_question_id uuid,answer text,command_id uuid,
  completion_at timestamptz,answer_confidence smallint
) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.task_instances; item public.task_review_items;
begin
  if answer_confidence is not null and answer_confidence not between 1 and 3 then
    raise exception '作答把握需为1至3' using errcode='22023'; end if;
  select * into t from public.task_instances where id=target_task_id for update;
  if not found or not public.child_is_visible(t.child_id) then
    raise exception 'Review task access required' using errcode='42501'; end if;
  select * into item from public.task_review_items where task_instance_id=t.id
    and wrong_question_id=target_question_id for update;
  if not found then raise exception 'Review question not found'; end if;
  if item.result is not null and answer_confidence is not null
    and answer_confidence is distinct from item.answer_confidence then
    raise exception '此题已提交，不能修改已记录的作答把握'; end if;
  perform public.submit_review_answer_and_complete(t.id,target_question_id,answer,command_id,completion_at);
  if item.result is null then
    update public.task_review_items i set answer_confidence=submit_review_answer_with_confidence.answer_confidence
      where i.task_instance_id=t.id and i.wrong_question_id=target_question_id;
    -- A stale task may be graded against its own key, but it must not replace
    -- the current question's confidence (the same boundary as its progression).
    update public.wrong_questions w set last_answer_confidence=submit_review_answer_with_confidence.answer_confidence
      from public.task_review_items i where i.task_instance_id=t.id and i.wrong_question_id=w.id
        and w.id=target_question_id and w.content_version=i.question_version and i.reward_status<>'stale';
  end if;
  return public.load_review_task(t.id);
end $$;
revoke all on function public.submit_review_answer_with_confidence(uuid,uuid,text,uuid,timestamptz,smallint)
  from public,anon,authenticated,service_role;

-- Exact argument sets keep PostgREST's existing four-argument RPC compatible.
-- Missing confidence is an unknown new answer or a read-only legacy replay;
-- it never clears confidence on an answer which is already recorded.
create function public.submit_review_answer(
  target_task_id uuid,target_question_id uuid,answer text,command_id uuid,answer_confidence smallint
) returns jsonb language plpgsql security definer set search_path='' as $$
begin
  perform 1 from auth.users where id=auth.uid() for share;
  perform 1 from public.families where id=(select c.family_id from public.children c
    join public.task_instances t on t.child_id=c.id where t.id=target_task_id) for key share;
  return public.submit_review_answer_with_confidence(target_task_id,target_question_id,answer,command_id,now(),answer_confidence);
end $$;
revoke all on function public.submit_review_answer(uuid,uuid,text,uuid,smallint) from public,anon,authenticated,service_role;
grant execute on function public.submit_review_answer(uuid,uuid,text,uuid,smallint) to authenticated;

create or replace function public.submit_review_answer(target_task_id uuid,target_question_id uuid,answer text,command_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  return public.submit_review_answer(target_task_id,target_question_id,answer,command_id,null::smallint);
end $$;
revoke all on function public.submit_review_answer(uuid,uuid,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.submit_review_answer(uuid,uuid,text,uuid) to authenticated;

create or replace function public.generate_daily_wrong_review_task(
  target_child_id uuid,target_date date default null,max_questions integer default 10
) returns uuid language plpgsql security definer set search_path='' as $$
declare task_id uuid; zone text; today date;
begin
  if auth.role() is distinct from 'service_role' and not public.child_is_visible(target_child_id) then
    raise exception 'Child access required' using errcode='42501'; end if;
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  if zone is null then raise exception 'Child not found'; end if;
  today:=(now() at time zone zone)::date;
  if auth.role() is distinct from 'service_role' and target_date is not null and target_date<>today then
    raise exception 'Only family today can be generated'; end if;
  target_date:=coalesce(target_date,today);
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id,0));
  select id into task_id from public.task_instances where child_id=target_child_id
    and due_date=target_date and source_type='automatic_wrong_review' for update;
  if found then return task_id; end if;
  if not exists(select 1 from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
    where w.child_id=target_child_id and not w.archived and not w.deleting and w.mastery_status<>'mastered'
      and w.review_due_at<((target_date+1)::timestamp at time zone zone)) then return null; end if;
  insert into public.task_instances(child_id,title,due_date,source_type,coin_reward,xp_reward,idempotency_key,review_reward_policy,review_auto_complete)
    values(target_child_id,'今日错题与拼音复习',target_date,'automatic_wrong_review',0,0,
      'auto-review:'||target_child_id||':'||target_date,2,true) returning id into task_id;
  with candidates as (
    select w.*,(w.review_due_at at time zone zone)::date as review_due_day from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
    where w.child_id=target_child_id and not w.archived and not w.deleting and w.mastery_status<>'mastered'
      and w.review_due_at<((target_date+1)::timestamp at time zone zone)
    order by (w.review_due_at at time zone zone)::date,w.wrong_count desc,w.last_answer_confidence asc nulls last,w.id limit greatest(1,least(coalesce(max_questions,10),10))
    for share of w,a
  ) insert into public.task_review_items(task_instance_id,wrong_question_id,sequence,prompt,subject,
    knowledge_point,review_kind,pronunciation_context,question_version,previous_answer_confidence)
    select task_id,id,row_number() over(order by review_due_day,wrong_count desc,last_answer_confidence asc nulls last,id)::smallint,
      final_text,subject,knowledge_point,review_kind,pronunciation_context,content_version,last_answer_confidence from candidates;
  insert into public.task_review_answer_keys(task_id,question_id,accepted_answers,explanation)
    select task_id,w.id,a.accepted_answers,a.explanation from public.task_review_items i
    join public.wrong_questions w on w.id=i.wrong_question_id
    join public.wrong_question_answers a on a.question_id=w.id where i.task_instance_id=task_id;
  update public.task_instances set
    coin_reward=(select coalesce(sum(case i.reward_stage when 0 then 15 when 3 then 25 when 4 then 40 else 0 end),0)::integer
      from public.task_review_items i where i.task_instance_id=task_id and not exists(select 1 from public.review_milestone_awards r where r.question_id=i.wrong_question_id and r.question_version=i.question_version and r.stage=i.reward_stage)),
    xp_reward=(select coalesce(sum(case i.reward_stage when 0 then 15 when 3 then 20 when 4 then 30 else 0 end),0)::integer
      from public.task_review_items i where i.task_instance_id=task_id and not exists(select 1 from public.review_milestone_awards r where r.question_id=i.wrong_question_id and r.question_version=i.question_version and r.stage=i.reward_stage)),
    expected_minutes=(select greatest(1,count(*)::integer*2) from public.task_review_items where task_instance_id=task_id)
    where id=task_id;
  return task_id;
end $$;

create or replace function public.apply_task_command_before_membership(command jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  request_command_id uuid := (command->>'command_id')::uuid;
  request_task_id uuid := (command->>'task_id')::uuid;
  predecessor_id uuid := (command->>'predecessor_id')::uuid;
  occurred_at timestamptz := (command->>'occurred_at')::timestamptz;
  kind text := command->>'kind';
  expected_version bigint;
  t public.task_instances;
  lease public.task_sync_leases;
  receipt public.task_command_receipts;
  predecessor public.task_command_receipts;
  request_digest jsonb;
  outcome text := 'applied';
  seconds bigint;
begin
  if kind not like 'review\_%' escape '\' then
    return public.apply_task_command_before_review(command);
  end if;
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if request_command_id is null or request_task_id is null or occurred_at is null
    or kind is null or kind not in ('review_start','review_pause','review_resume','review_answer','review_complete')
    or command - array['command_id','task_id','predecessor_id','occurred_at','kind','lease_id','expected_version','start_origin',
      'question_id','question_version','answer','answer_confidence'] <> '{}'::jsonb
    or (kind<>'review_answer' and command ?| array['question_id','question_version','answer','answer_confidence'])
    or (kind='review_answer' and (nullif(btrim(command->>'answer'),'') is null
      or length(command->>'answer')>500 or command->>'question_id' is null or command->>'question_version' is null)) then
    raise exception 'Invalid offline review command';
  end if;
  if command ? 'start_origin' and (kind<>'review_start'
    or jsonb_typeof(command->'start_origin') is distinct from 'string'
    or command->>'start_origin' not in ('unknown','child_mode','parent_assisted')) then
    raise exception 'Invalid start origin' using errcode='22023'; end if;
  if command ? 'answer_confidence' and (jsonb_typeof(command->'answer_confidence') is distinct from 'number'
    or command->>'answer_confidence' not in ('1','2','3')) then
    raise exception 'Invalid answer confidence' using errcode='22023'; end if;
  -- Receipts contain a digest, never another durable copy of a child's answer.
  request_digest := jsonb_build_object('digest',encode(sha256(convert_to(command::text,'UTF8')),'hex'),
    'occurred_at',command->>'occurred_at');
  perform pg_advisory_xact_lock(hashtextextended('task-command:'||auth.uid()||':'||request_command_id,0));
  select * into t from public.task_instances where id=request_task_id for update;
  if not found or not public.child_is_visible(t.child_id) or t.source_type<>'automatic_wrong_review' then
    raise exception 'Review task access required' using errcode='42501'; end if;
  select * into receipt from public.task_command_receipts
    where user_id=auth.uid() and task_command_receipts.command_id=request_command_id;
  if found then
    if receipt.request<>request_digest then raise exception 'Command UUID cannot be reused with different data'; end if;
    return public.task_command_result(t.id,receipt.outcome)||jsonb_build_object('review',public.load_review_task(t.id));
  end if;
  select * into lease from public.task_sync_leases where id=(command->>'lease_id')::uuid
    and user_id=auth.uid() and child_id=t.child_id;
  if not found or lease.expires_at<clock_timestamp() then
    return public.task_command_result(t.id,'conflict','离线缓存授权已过期，请联网刷新后处理'); end if;
  if occurred_at<lease.issued_at or occurred_at<t.created_at or occurred_at>clock_timestamp() then
    return public.task_command_result(t.id,'conflict','操作时间不在服务端允许范围内，请联网校准'); end if;
  if predecessor_id is not null then
    select * into predecessor from public.task_command_receipts where user_id=auth.uid()
      and task_command_receipts.command_id=predecessor_id and task_command_receipts.task_id=t.id;
    if not found or occurred_at<(predecessor.request->>'occurred_at')::timestamptz then
      return public.task_command_result(t.id,'conflict','前序命令缺失或操作时间顺序错误'); end if;
    expected_version := predecessor.result_version;
  else
    expected_version := (command->>'expected_version')::bigint;
  end if;
  if t.status='completed' and kind='review_complete' then
    outcome := 'already_completed';
  elsif t.status in ('completed','skipped','expired','abandoned') then
    return public.task_command_result(t.id,'conflict','复习已结束或题目已清理，请采用服务端状态');
  elsif expected_version is null or expected_version<>t.sync_version then
    return public.task_command_result(t.id,'conflict','另一台设备已修改复习，请采用服务端状态');
  else
    begin
      if kind='review_answer' then
        if not exists(select 1 from public.task_review_items i where i.task_instance_id=t.id
          and i.wrong_question_id=(command->>'question_id')::uuid
          and i.question_version=(command->>'question_version')::bigint) then
          raise exception '题目快照已改变，请重新加载复习'; end if;
        perform public.submit_review_answer_with_confidence(t.id,(command->>'question_id')::uuid,command->>'answer',request_command_id,occurred_at,(command->>'answer_confidence')::smallint);
      elsif kind='review_start' and t.status in ('ready','scheduled') then
        update public.task_instances set status='in_progress',started_at=coalesce(started_at,occurred_at),
          start_origin=case when started_at is null then coalesce(command->>'start_origin','unknown') else start_origin end,
          active_started_at=occurred_at where id=t.id;
      elsif kind='review_resume' and t.status='paused' then
        update public.task_instances set status='in_progress',active_started_at=occurred_at where id=t.id;
      elsif (kind='review_pause' and t.status='in_progress') or
        (kind='review_complete' and t.status in ('in_progress','paused')) then
        if t.active_started_at is not null and occurred_at<t.active_started_at then
          raise exception '操作时间早于上次开始时间'; end if;
        seconds := t.accumulated_seconds::bigint + case when t.active_started_at is null then 0
          else greatest(floor(extract(epoch from occurred_at-t.active_started_at))::bigint,0) end;
        if kind='review_complete' and seconds<t.minimum_seconds then raise exception '尚未达到最低有效时长'; end if;
        update public.task_instances set accumulated_seconds=least(seconds,2147483647)::integer,
          active_started_at=null,status=case when kind='review_pause' then 'paused'::public.task_status else status end where id=t.id;
        if kind='review_complete' then perform public.complete_task(t.id,'offline-review:'||request_command_id,null); end if;
      else
        raise exception '复习当前状态不允许此操作';
      end if;
    exception when sqlstate 'P0001' then
      return public.task_command_result(t.id,'conflict',sqlerrm);
    end;
    select * into t from public.task_instances where id=request_task_id;
  end if;
  insert into public.task_command_receipts(user_id,command_id,task_id,request,outcome,result_version)
    values(auth.uid(),request_command_id,t.id,request_digest,outcome,t.sync_version);
  return public.task_command_result(t.id,outcome)||jsonb_build_object('review',public.load_review_task(t.id));
end;
$$;

revoke all on function public.apply_task_command_before_membership(jsonb) from public,anon,authenticated,service_role;
