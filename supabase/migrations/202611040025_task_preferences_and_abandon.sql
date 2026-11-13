-- Presentation preferences are snapshots, never reward multipliers.
alter table public.task_templates add column task_priority text not null default 'recommended'
  check(task_priority in ('required','recommended','challenge'));
alter table public.task_instances add column task_priority text not null default 'recommended'
  check(task_priority in ('required','recommended','challenge')),
  add column expected_minutes integer check(expected_minutes>0),
  add column abandoned_at timestamptz;
update public.task_templates set expected_minutes=greatest(coalesce(expected_minutes,20),ceil(minimum_seconds::numeric/60)::integer);
alter table public.task_templates alter column expected_minutes set not null;
alter table public.task_templates alter column expected_minutes set default 20;
update public.task_instances set task_priority='challenge' where task_kind='challenge';

create function public.snapshot_task_preferences() returns trigger
language plpgsql security definer set search_path='' as $$
declare template public.task_templates;
begin
  if new.template_id is not null then
    select * into template from public.task_templates where id=new.template_id;
    new.task_priority:=template.task_priority;
    new.expected_minutes:=template.expected_minutes;
  elsif new.task_kind='challenge' then
    new.task_priority:='challenge';
    new.expected_minutes:=coalesce(new.expected_minutes,greatest(20,ceil(new.minimum_seconds::numeric/60)::integer));
  end if;
  return new;
end $$;
revoke all on function public.snapshot_task_preferences() from public,anon,authenticated,service_role;
create trigger task_preferences before insert on public.task_instances for each row execute function public.snapshot_task_preferences();

-- Replaces only the private save implementation. The public plan/stage wrapper
-- and its immutability checks remain unchanged.
create or replace function public.save_task_schedule_base(target_child_id uuid, config jsonb, target_template_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare family uuid; zone text; today date; tid uuid; rec public.task_recurrence;
  first_day date; last_day date; rule jsonb; st time; dt time; priority text; expected integer;
begin
  select c.family_id,f.timezone into family,zone from public.children c
    join public.families f on f.id=c.family_id where c.id=target_child_id;
  perform public.require_parent_authorization(family);
  priority:=coalesce(config->>'priority',(select task_priority from public.task_templates where id=target_template_id and child_id=target_child_id),'recommended');
  expected:=coalesce((config->>'expected_minutes')::integer,(select expected_minutes from public.task_templates where id=target_template_id and child_id=target_child_id),greatest(20,ceil((config->>'minimum_seconds')::numeric/60)::integer));
  if priority not in ('required','recommended','challenge') or expected not between 1 and 1440
    or expected::bigint*60<(config->>'minimum_seconds')::bigint then raise exception '目标时长需为1至1440分钟且不少于最低时长，任务类别须有效'; end if;
  today := (now() at time zone zone)::date;
  rec := (config->>'recurrence')::public.task_recurrence;
  first_day := (config->>'starts_on')::date;
  last_day := (config->>'ends_on')::date;
  st := (config->>'start_time')::time; dt := (config->>'due_time')::time;
  rule := coalesce(config->'rule','{}');
  if nullif(btrim(config->>'title'),'') is null or first_day is null
    or last_day is null or last_day<first_day or last_day-first_day>366
    or st is null or dt is null or dt<=st then raise exception 'Invalid schedule configuration'; end if;
  if target_template_id is null and first_day<today then raise exception 'Start date cannot be in the past'; end if;
  if rec='weekly' and (jsonb_typeof(rule->'weekdays') is distinct from 'array'
      or jsonb_array_length(rule->'weekdays')=0
      or exists(select 1 from jsonb_array_elements_text(rule->'weekdays') d
        where d::integer not between 1 and 7)) then raise exception 'Choose valid weekdays'; end if;
  if rec='custom' and (jsonb_typeof(rule->'dates') is distinct from 'array'
      or jsonb_array_length(rule->'dates')=0
      or exists(select 1 from jsonb_array_elements_text(rule->'dates') d
        where d::date not between first_day and last_day)) then raise exception 'Choose dates within schedule'; end if;
  if rec='once' then rule := jsonb_build_object('date',first_day::text); end if;
  if target_template_id is null then
    insert into public.task_templates(child_id,title,recurrence,recurrence_rule,starts_on,ends_on,
      start_time,due_time,coin_reward,xp_reward,minimum_seconds,task_priority,expected_minutes)
    values(target_child_id,btrim(config->>'title'),rec,rule,first_day,last_day,st,dt,
      (config->>'coins')::integer,(config->>'xp')::integer,(config->>'minimum_seconds')::integer,priority,expected)
      returning id into tid;
    if coalesce((config->>'long_plan')::boolean,false) then
      if rec='once' then raise exception 'A plan requires recurring tasks'; end if;
      insert into public.long_plans(template_id,minimum_rate,bonus_coins,bonus_xp)
      values(tid,(config->>'minimum_rate')::numeric,
        (config->>'bonus_coins')::integer,(config->>'bonus_xp')::integer);
    end if;
  else
    select id into tid from public.task_templates where id=target_template_id and child_id=target_child_id for update;
    if tid is null then raise exception 'Template not found'; end if;
    if exists(select 1 from public.long_plans where template_id=tid) then
      raise exception 'Plan rules are immutable after creation'; end if;
    update public.task_templates set title=btrim(config->>'title'),recurrence=rec,recurrence_rule=rule,
      starts_on=first_day,ends_on=last_day,start_time=st,due_time=dt,
      coin_reward=(config->>'coins')::integer,xp_reward=(config->>'xp')::integer,
      minimum_seconds=(config->>'minimum_seconds')::integer,task_priority=priority,expected_minutes=expected,updated_at=now() where id=tid;
  end if;
  perform public.generate_scheduled_tasks(target_child_id);
  return tid;
end;
$$;

revoke all on function public.save_task_schedule_base(uuid,jsonb,uuid) from public,anon,authenticated,service_role;

create function public.abandon_task_internal(target_task_id uuid,occurred_at timestamptz) returns public.task_instances
language plpgsql security definer set search_path='' as $$
declare t public.task_instances; family uuid; elapsed bigint; old_status public.task_status;
begin
  select * into t from public.task_instances where id=target_task_id for update;
  if not found or not public.child_is_visible(t.child_id) then raise exception 'Task access required' using errcode='42501'; end if;
  if t.status='abandoned' then return t; end if;
  if t.status not in ('scheduled','ready','in_progress','paused') then raise exception '任务已结束，不能放弃'; end if;
  if occurred_at is null or occurred_at>clock_timestamp() or occurred_at<t.created_at
    or (t.active_started_at is not null and occurred_at<t.active_started_at) then raise exception '无效放弃时间'; end if;
  old_status:=t.status;
  elapsed:=t.accumulated_seconds::bigint+case when t.active_started_at is null then 0
    else greatest(0,floor(extract(epoch from occurred_at-t.active_started_at))::bigint) end;
  update public.task_instances set status='abandoned',abandoned_at=occurred_at,
    accumulated_seconds=least(elapsed,2147483647)::integer,active_started_at=null where id=t.id returning * into t;
  select family_id into family from public.children where id=t.child_id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'task.abandon','task_instance',t.id::text,
      jsonb_build_object('previous_status',old_status,'effective_seconds',t.accumulated_seconds,'occurred_at',occurred_at));
  return t;
end $$;
revoke all on function public.abandon_task_internal(uuid,timestamptz) from public,anon,authenticated,service_role;
create function public.abandon_task(target_task_id uuid) returns public.task_instances
language sql security definer set search_path='' as $$
  select public.abandon_task_internal(target_task_id,clock_timestamp());
$$;
revoke all on function public.abandon_task(uuid) from public,anon;
grant execute on function public.abandon_task(uuid) to authenticated;
alter table public.task_command_receipts drop constraint task_command_receipts_outcome_check;
alter table public.task_command_receipts add constraint task_command_receipts_outcome_check
  check(outcome in ('applied','already_completed','already_abandoned'));
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
  outcome text := 'applied';
  seconds bigint;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if request_command_id is null or request_task_id is null or occurred_at is null
    or kind is null or kind not in ('start','pause','resume','complete','abandon')
    or command - array['command_id','task_id','predecessor_id','occurred_at','kind','lease_id','expected_version'] <> '{}'::jsonb then
    raise exception 'Invalid offline command';
  end if;
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
revoke all on function public.apply_task_command(jsonb) from public,anon,authenticated;
grant execute on function public.apply_task_command(jsonb) to authenticated;


-- Recreate to add per-task identities for offline suppression of merged reminders.
drop function public.load_task_reminders(uuid);
create function public.load_task_reminders(target_child_id uuid)
returns table(reminder_key text, remind_at timestamptz, titles text, remind_local text, tasks jsonb)
language plpgsql security definer set search_path=public as $$
declare zone text; enabled boolean; qs time; qe time;
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  select s.enabled,s.quiet_start,s.quiet_end into enabled,qs,qe from public.reminder_settings s where s.child_id=target_child_id;
  if enabled=false then return; end if;
  qs := coalesce(qs,'21:00'); qe := coalesce(qe,'07:00');
  return query with candidates as (
    select i.id task_id,i.template_id,i.due_date,i.title,i.scheduled_at,i.due_at from public.task_instances i
      where i.child_id=target_child_id and i.status not in ('completed','skipped','expired','abandoned')
    union all
    select null::uuid,t.id,d.day::date,t.title,(d.day::date+t.start_time) at time zone zone,(d.day::date+t.due_time) at time zone zone
    from public.task_templates t
    cross join generate_series((now() at time zone zone)::date::timestamp,
      ((now() at time zone zone)::date+7)::timestamp,interval '1 day') d(day)
    left join public.long_plans p on p.template_id=t.id
    where t.child_id=target_child_id and t.active and public.template_due_on(t,d.day::date)
      and not exists(select 1 from public.task_instances i where i.template_id=t.id and i.due_date=d.day::date)
      and not exists(select 1 from public.plan_leaves l where l.plan_id=p.id and l.leave_date=d.day::date)
  ), slots as (
    select i.task_id,i.template_id,i.due_date,i.title,v.at from candidates i
    cross join lateral(values(i.scheduled_at-interval '10 minutes'),(i.scheduled_at),(i.due_at-interval '15 minutes')) v(at)
    where v.at between now()-interval '1 day' and now()+interval '7 days'
      and (i.scheduled_at is null or v.at>=i.scheduled_at-interval '10 minutes')
  ), grouped as (
    select 'slot:'||extract(epoch from s.at)::bigint::text k,s.at,string_agg(distinct s.title,'、' order by s.title) names,
      jsonb_agg(distinct jsonb_build_object('task_id',s.task_id,'template_id',s.template_id,'due_date',s.due_date,'title',s.title)) entries
    from slots s where qs=qe or not (
      case when qs<qe then (s.at at time zone zone)::time>=qs and (s.at at time zone zone)::time<qe
      else (s.at at time zone zone)::time>=qs or (s.at at time zone zone)::time<qe end)
    group by s.at
  ) select g.k,g.at,g.names,to_char(g.at at time zone zone,'YYYY-MM-DD HH24:MI')||' '||zone,g.entries from grouped g where not exists(
    select 1 from public.reminder_receipts r where r.child_id=target_child_id and r.reminder_key=g.k)
    order by g.at;
end;
$$;


revoke all on function public.load_task_reminders(uuid) from public,anon;
grant execute on function public.load_task_reminders(uuid) to authenticated;
create or replace function public.generate_daily_wrong_review_task(
  target_child_id uuid,target_date date default null,max_questions integer default 10
) returns uuid language plpgsql security definer set search_path='' as $$
declare task_id uuid; zone text; today date;
begin
  if auth.role() is distinct from 'service_role' and not public.child_is_visible(target_child_id) then
    raise exception 'Child access required' using errcode='42501'; end if;
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  if zone is null then raise exception 'Child not found'; end if;
  today := (now() at time zone zone)::date;
  if auth.role() is distinct from 'service_role' and target_date is not null and target_date<>today then
    raise exception 'Only family today can be generated'; end if;
  target_date:=coalesce(target_date,today);
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id,0));
  select id into task_id from public.task_instances where child_id=target_child_id
    and due_date=target_date and source_type='automatic_wrong_review' for update;
  if found then return task_id; end if;
  if not exists(select 1 from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
    where w.child_id=target_child_id and not w.archived and w.mastery_status<>'mastered'
      and w.review_due_at<((target_date+1)::timestamp at time zone zone)) then return null; end if;
  insert into public.task_instances(child_id,title,due_date,source_type,coin_reward,xp_reward,idempotency_key)
    values(target_child_id,'今日错题与拼音复习',target_date,'automatic_wrong_review',0,0,
      'auto-review:'||target_child_id||':'||target_date) returning id into task_id;
  with candidates as (
    select w.* from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
    where w.child_id=target_child_id and not w.archived and w.mastery_status<>'mastered'
      and w.review_due_at<((target_date+1)::timestamp at time zone zone)
    order by w.review_due_at,w.wrong_count desc,w.id limit greatest(1,least(coalesce(max_questions,10),10))
    for share of w,a
  ) insert into public.task_review_items(task_instance_id,wrong_question_id,sequence,prompt,subject,
    knowledge_point,review_kind,pronunciation_context,question_version)
    select task_id,id,row_number() over(order by review_due_at,wrong_count desc,id)::smallint,
      final_text,subject,knowledge_point,review_kind,pronunciation_context,content_version from candidates;
  insert into public.task_review_answer_keys(task_id,question_id,accepted_answers,explanation)
    select task_id,w.id,a.accepted_answers,a.explanation from public.task_review_items i
    join public.wrong_questions w on w.id=i.wrong_question_id
    join public.wrong_question_answers a on a.question_id=w.id where i.task_instance_id=task_id;
  update public.task_instances set coin_reward=(select count(*)::integer*5 from public.task_review_items where task_instance_id=task_id),
    xp_reward=(select count(*)::integer*5 from public.task_review_items where task_instance_id=task_id),
    expected_minutes=(select greatest(1,count(*)::integer*2) from public.task_review_items where task_instance_id=task_id) where id=task_id;
  return task_id;
end;
$$;
revoke all on function public.generate_daily_wrong_review_task(uuid,date,integer) from public,anon,authenticated;
grant execute on function public.generate_daily_wrong_review_task(uuid,date,integer) to authenticated,service_role;
-- Retain terminal abandonment when private review content is erased.
create or replace function public.preview_question_cleanup_base(target_child_id uuid, operation text, ids uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare family uuid; selected uuid[]; drafts uuid[]; paths jsonb; tasks integer;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if operation not in ('questions','originals','abandoned_ocr') or operation is null then raise exception '无效清理范围'; end if;
  if operation='abandoned_ocr' then
    selected:='{}';
    select coalesce(array_agg(id order by id),'{}') into drafts from public.question_ocr_drafts
      where child_id=target_child_id and owner_id=auth.uid() and question_id is null
      and created_at<now()-interval '1 day' and not deleting;
  else
    if cardinality(ids) is null or cardinality(ids) not between 1 and 100 or array_position(ids,null) is not null then raise exception '请选择1至100道题'; end if;
    select array_agg(distinct item order by item) into selected from unnest(ids) item;
    if exists(select 1 from unnest(selected) item where not exists(select 1 from public.wrong_questions
      where id=item and child_id=target_child_id and not deleting)) then raise exception '包含其他孩子或正在删除的错题'; end if;
    select coalesce(array_agg(id order by id),'{}') into drafts from public.question_ocr_drafts
      where question_id=any(selected) and (operation='questions' or original_deleted_at is null);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('bucket','wrong-question-images','path',p.path) order by p.path),'[]') into paths
    from (select original_path as path from public.question_ocr_drafts where id=any(drafts) and original_deleted_at is null
      union select processed_path from public.question_ocr_drafts where id=any(drafts) and operation<>'originals') p;
  select count(distinct t.id)::integer into tasks from public.task_instances t join public.task_review_items i on i.task_instance_id=t.id
    where i.wrong_question_id=any(selected) and t.status not in ('completed','skipped','expired','abandoned');
  return jsonb_build_object('scope',operation,'question_ids',selected,'draft_ids',drafts,'manifest',paths,
    'questions',cardinality(selected),'drafts',cardinality(drafts),'files',jsonb_array_length(paths),
    'unfinished_reviews',case when operation='questions' then tasks else 0 end,
    'irreversible',true,'ledger_preserved',true);
end $$;

create or replace function public.request_question_cleanup(target_child_id uuid, operation text, ids uuid[], request_id uuid, confirmation text)
returns uuid language plpgsql security definer set search_path='' as $$
declare family uuid; existing public.cleanup_jobs; preview jsonb; selected uuid[]; drafts uuid[];
begin
  select family_id into family from public.children where id=target_child_id;
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
      and exists(select 1 from public.task_review_items i where i.task_instance_id=t.id and i.wrong_question_id=any(selected));
    update public.wrong_questions set archived=true,deleting=true where id=any(selected);
  end if;
  update public.question_ocr_drafts set deleting=true where id=any(drafts);
  insert into public.cleanup_jobs(id,family_id,child_id,owner_id,scope,question_ids,draft_ids,manifest)
    values(request_id,family,target_child_id,auth.uid(),operation,selected,drafts,preview->'manifest');
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'cleanup.request','cleanup_job',request_id::text,
      jsonb_build_object('scope',operation,'questions',cardinality(selected),'files',preview->'files'));
  return request_id;
end $$;
