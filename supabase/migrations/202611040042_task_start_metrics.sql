-- First-start provenance is a reported UI mode, never proof of identity and
-- never authority to grant rewards or bypass parent authorization.
alter table public.task_instances
  add column start_origin text not null default 'unknown'
    check(start_origin in ('unknown','child_mode','parent_assisted')),
  add column start_observed_at timestamptz;
create function public.capture_task_start_origin() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_op='INSERT' then
    new.start_origin:='unknown';new.start_observed_at:=null;
  elsif old.started_at is not null then
    new.start_origin:=old.start_origin;new.start_observed_at:=old.start_observed_at;
  elsif new.started_at is not null then
    new.start_observed_at:=clock_timestamp();
  else
    new.start_origin:='unknown';new.start_observed_at:=null;
  end if;
  return new;
end $$;
create trigger capture_task_start_origin before insert or update on public.task_instances
  for each row execute function public.capture_task_start_origin();
revoke all on function public.capture_task_start_origin() from public,anon,authenticated,service_role;

create function public.start_task_with_origin(target_task_id uuid,requested_origin text) returns public.task_instances
language plpgsql security definer set search_path='' as $$
declare t public.task_instances;
begin
  if requested_origin is null or requested_origin not in ('unknown','child_mode','parent_assisted') then
    raise exception 'Invalid start origin' using errcode='22023'; end if;
  select * into t from public.task_instances where id=target_task_id for update;
  if not found or not public.child_is_visible(t.child_id) then
    raise exception 'Task access required' using errcode='42501'; end if;
  if t.status not in ('scheduled','ready') then raise exception 'Task cannot be started from current status'; end if;
  update public.task_instances set status='in_progress',started_at=coalesce(started_at,now()),active_started_at=now(),
    start_origin=case when started_at is null then requested_origin else start_origin end
    where id=t.id returning * into t;
  return t;
end $$;
revoke all on function public.start_task_with_origin(uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.start_task_with_origin(uuid,text) to authenticated;

alter function public.learning_report(uuid,text,date) rename to learning_report_before_start_metrics;
revoke all on function public.learning_report_before_start_metrics(uuid,text,date) from public,anon,authenticated,service_role;
create function public.learning_report(target_child_id uuid, report_period text default 'week', anchor_date date default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare report jsonb; stats jsonb;
begin
  report:=public.learning_report_before_start_metrics(target_child_id,report_period,anchor_date);
  with cohort as (
    select t.*,coalesce(t.scheduled_at,t.due_date::timestamp at time zone (report->>'timezone')) window_start,
      coalesce(t.due_at,(t.due_date+1)::timestamp at time zone (report->>'timezone')) window_end
    from public.task_instances t where t.child_id=target_child_id
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
revoke all on function public.learning_report(uuid,text,date) from public,anon,authenticated,service_role;
grant execute on function public.learning_report(uuid,text,date) to authenticated;

create or replace function public.apply_task_command_before_review(command jsonb) returns jsonb
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
  outcome text := 'applied';
  seconds bigint;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if request_command_id is null or request_task_id is null or occurred_at is null
    or kind is null or kind not in ('start','pause','resume','complete','abandon')
    or command - array['command_id','task_id','predecessor_id','occurred_at','kind','lease_id','expected_version','start_origin'] <> '{}'::jsonb then
    raise exception 'Invalid offline command';
  end if;
  if command ? 'start_origin' and (kind<>'start'
    or jsonb_typeof(command->'start_origin') is distinct from 'string'
    or command->>'start_origin' not in ('unknown','child_mode','parent_assisted')) then
    raise exception 'Invalid start origin' using errcode='22023'; end if;
  -- Serialize duplicate UUIDs as well as competing updates to the task.
  perform pg_advisory_xact_lock(hashtextextended('task-command:'||auth.uid()||':'||request_command_id,0));
  select * into t from public.task_instances where id=request_task_id for update;
  if not found or not public.child_is_visible(t.child_id) then
    raise exception 'Task access required' using errcode='42501';
  end if;
  select * into receipt from public.task_command_receipts
    where user_id=auth.uid() and task_command_receipts.command_id=request_command_id;
  if found then
    if receipt.request<>command then raise exception 'Command UUID cannot be reused with different data'; end if;
    return public.task_command_result(t.id,receipt.outcome);
  end if;
  select * into lease from public.task_sync_leases where id=(command->>'lease_id')::uuid
    and user_id=auth.uid() and child_id=t.child_id;
  if not found or lease.expires_at<clock_timestamp() then
    return public.task_command_result(t.id,'conflict','离线缓存授权已过期，请联网刷新后处理');
  end if;
  -- Client activity is not an attendance proof. Only bounded elapsed wall time
  -- since a server-issued lease is accepted; future/backdated clocks cannot mint time.
  if occurred_at<lease.issued_at or occurred_at<t.created_at or occurred_at>clock_timestamp() then
    return public.task_command_result(t.id,'conflict','操作时间不在服务端允许范围内，请联网校准');
  end if;
  if predecessor_id is not null then
    select * into predecessor from public.task_command_receipts where user_id=auth.uid()
      and task_command_receipts.command_id=predecessor_id and task_command_receipts.task_id=t.id;
    if not found or occurred_at<(predecessor.request->>'occurred_at')::timestamptz then
      return public.task_command_result(t.id,'conflict','前序命令缺失或操作时间顺序错误');
    end if;
    expected_version := predecessor.result_version;
  else
    expected_version := (command->>'expected_version')::bigint;
  end if;
  if t.status='completed' then
    outcome := 'already_completed';
  elsif t.status='abandoned' and kind='abandon' then
    outcome:='already_abandoned';
  elsif t.status in ('skipped','expired','abandoned') then
    return public.task_command_result(t.id,'conflict','任务已放弃、跳过或过期，不能重放离线打卡');
  elsif expected_version is null or expected_version<>t.sync_version then
    return public.task_command_result(t.id,'conflict','另一台设备已修改任务，请采用服务端状态');
  elsif t.source_type='automatic_wrong_review' and kind<>'abandon' then
    return public.task_command_result(t.id,'conflict','自动复习任务需要完成题目作答，不支持普通离线打卡');
  elsif kind<>'abandon' and exists(select 1 from public.long_plans p where p.template_id=t.template_id and p.settled_at is not null) then
    return public.task_command_result(t.id,'conflict','长期计划已经结算，请联系家长处理');
  else
    -- Exception subtransaction rolls back timing changes if the existing completion
    -- chain rejects minimum duration, approved leave, or another business rule.
    begin
      if kind='abandon' then
        perform public.abandon_task_internal(t.id,occurred_at);
      elsif kind='start' and t.status in ('ready','scheduled') then
        update public.task_instances set status='in_progress',started_at=coalesce(started_at,occurred_at),
          start_origin=case when started_at is null then coalesce(command->>'start_origin','unknown') else start_origin end,
          active_started_at=occurred_at where id=t.id;
      elsif kind='resume' and t.status='paused' then
        update public.task_instances set status='in_progress',active_started_at=occurred_at where id=t.id;
      elsif kind in ('pause','complete') and (
        (kind='pause' and t.status='in_progress') or
        (kind='complete' and t.status in ('in_progress','paused'))) then
        if t.active_started_at is not null and occurred_at<t.active_started_at then
          raise exception '操作时间早于上次开始时间';
        end if;
        seconds := t.accumulated_seconds::bigint + case when t.active_started_at is null then 0
          else greatest(floor(extract(epoch from occurred_at-t.active_started_at))::bigint,0) end;
        if kind='complete' and seconds<t.minimum_seconds then
          raise exception '尚未达到最低有效时长';
        end if;
        update public.task_instances set accumulated_seconds=least(seconds,2147483647)::integer,
          active_started_at=null,status=case when kind='pause' then 'paused'::public.task_status else status end
          where id=t.id;
        if kind='complete' then
          perform public.complete_task(t.id,'offline:'||request_command_id,null);
        end if;
      else
        raise exception '任务状态不允许此操作';
      end if;
    exception when sqlstate 'P0001' then
      return public.task_command_result(t.id,'conflict',sqlerrm);
    end;
    select * into t from public.task_instances where id=request_task_id;
  end if;
  insert into public.task_command_receipts(user_id,command_id,task_id,request,outcome,result_version)
    values(auth.uid(),request_command_id,t.id,command,outcome,t.sync_version);
  return public.task_command_result(t.id,outcome);
end;
$$;

create or replace function public.apply_task_command(command jsonb) returns jsonb
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
      'question_id','question_version','answer'] <> '{}'::jsonb
    or (kind<>'review_answer' and command ?| array['question_id','question_version','answer'])
    or (kind='review_answer' and (nullif(btrim(command->>'answer'),'') is null
      or length(command->>'answer')>500 or command->>'question_id' is null or command->>'question_version' is null)) then
    raise exception 'Invalid offline review command';
  end if;
  if command ? 'start_origin' and (kind<>'review_start'
    or jsonb_typeof(command->'start_origin') is distinct from 'string'
    or command->>'start_origin' not in ('unknown','child_mode','parent_assisted')) then
    raise exception 'Invalid start origin' using errcode='22023'; end if;
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
        perform public.submit_review_answer(t.id,(command->>'question_id')::uuid,command->>'answer',request_command_id);
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

revoke all on function public.apply_task_command_before_review(jsonb) from public,anon,authenticated,service_role;

revoke all on function public.apply_task_command(jsonb) from public,anon,authenticated,service_role;

grant execute on function public.apply_task_command(jsonb) to authenticated;
