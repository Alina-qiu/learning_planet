-- ERR-06: one explicit reminder for today's immutable review queue.
create table public.review_reminder_requests (
  task_id uuid primary key references public.task_instances(id) on delete cascade,
  revision bigint not null check(revision between 1 and 9007199254740991),
  command_id uuid,
  delay_minutes integer not null check(delay_minutes in (0,15,30,60)),
  remind_at timestamptz,
  requested_at timestamptz not null default now(),
  check ((delay_minutes=0 and remind_at is null) or (delay_minutes>0 and remind_at is not null))
);
alter table public.review_reminder_requests enable row level security;
revoke all on public.review_reminder_requests from public,anon,authenticated;

create function public.review_reminder_state(target_task_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t public.task_instances; r public.review_reminder_requests; zone text; enabled boolean; allowed boolean;
begin
  select * into t from public.task_instances where id=target_task_id;
  if not found or not public.child_is_visible(t.child_id) or t.source_type<>'automatic_wrong_review' then
    raise exception 'Review task access required' using errcode='42501'; end if;
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=t.child_id;
  select s.enabled into enabled from public.reminder_settings s where s.child_id=t.child_id;
  select * into r from public.review_reminder_requests where task_id=t.id;
  allowed:=t.status not in ('completed','skipped','expired','abandoned') and t.due_date=(now() at time zone zone)::date;
  return jsonb_build_object('revision',coalesce(r.revision,0),'enabled',coalesce(enabled,true),'allowed',allowed,
    'remind_at',case when allowed and r.remind_at>now() then r.remind_at end,
    'remind_local',case when allowed and r.remind_at>now() then to_char(r.remind_at at time zone zone,'MM-DD HH24:MI')||' '||zone end);
end $$;

create function public.set_review_reminder(target_task_id uuid,delay_minutes integer,command_id uuid,expected_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t public.task_instances; previous public.review_reminder_requests; zone text; family uuid;
  enabled boolean; qs time; qe time; candidate timestamptz; local_time time;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if command_id is null or expected_revision is null or expected_revision not between 0 and 9007199254740990
    or delay_minutes is null or delay_minutes not in (0,15,30,60) then raise exception '无效的复习提醒请求'; end if;
  -- Same task lock as completion: a reminder cannot be created after a terminal transition.
  select * into t from public.task_instances where id=target_task_id for update;
  if not found or not public.child_is_visible(t.child_id) or t.source_type<>'automatic_wrong_review' then
    raise exception 'Review task access required' using errcode='42501'; end if;
  select f.id,f.timezone into family,zone from public.children c join public.families f on f.id=c.family_id where c.id=t.child_id;
  select * into previous from public.review_reminder_requests r where r.task_id=t.id;
  if previous.command_id=command_id then
    if previous.delay_minutes<>delay_minutes or previous.revision<>expected_revision+1 then
      raise exception '请求标识已用于其他操作'; end if;
    return public.review_reminder_state(t.id);
  end if;
  if coalesce(previous.revision,0)<>expected_revision then
    raise exception '提醒已在其他设备更新，请刷新后再选择' using errcode='40001'; end if;
  if delay_minutes>0 then
    if t.status in ('completed','skipped','expired','abandoned') or t.due_date<>(now() at time zone zone)::date then
      raise exception '这次复习已结束，请刷新查看今日任务'; end if;
    select s.enabled,s.quiet_start,s.quiet_end into enabled,qs,qe from public.reminder_settings s where s.child_id=t.child_id;
    if enabled=false then raise exception '家长已关闭任务提醒'; end if;
    qs:=coalesce(qs,'21:00'); qe:=coalesce(qe,'07:00');
    candidate:=date_trunc('minute',now())+make_interval(mins=>delay_minutes+1);
    if (candidate at time zone zone)::date<>t.due_date then raise exception '提醒时间已跨到次日，请选择更早的时间'; end if;
    local_time:=(candidate at time zone zone)::time;
    if qs<>qe and (case when qs<qe then local_time>=qs and local_time<qe else local_time>=qs or local_time<qe end) then
      raise exception '该时点处于安静时段，请选择其他时间'; end if;
  end if;
  insert into public.review_reminder_requests(task_id,revision,command_id,delay_minutes,remind_at)
    values(t.id,expected_revision+1,command_id,delay_minutes,candidate)
    on conflict(task_id) do update set revision=excluded.revision,command_id=excluded.command_id,
      delay_minutes=excluded.delay_minutes,remind_at=excluded.remind_at,requested_at=now();
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'review_reminder_changed','task',t.id::text,
      jsonb_build_object('revision',expected_revision+1,'remind_at',candidate));
  return public.review_reminder_state(t.id);
end $$;
revoke all on function public.review_reminder_state(uuid),public.set_review_reminder(uuid,integer,uuid,bigint) from public,anon;
grant execute on function public.review_reminder_state(uuid),public.set_review_reminder(uuid,integer,uuid,bigint) to authenticated;

create function public.cancel_finished_review_reminder() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status in ('completed','skipped','expired','abandoned') and new.status is distinct from old.status then
    update public.review_reminder_requests set revision=revision+1,command_id=null,delay_minutes=0,remind_at=null
      where task_id=new.id and remind_at is not null;
  end if;
  return new;
end $$;
revoke all on function public.cancel_finished_review_reminder() from public,anon,authenticated,service_role;
create trigger cancel_finished_review_reminder after update of status on public.task_instances
  for each row execute function public.cancel_finished_review_reminder();

alter function public.review_overview(uuid) rename to review_overview_before_snooze;
create function public.review_overview(target_child_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  result:=public.review_overview_before_snooze(target_child_id);
  if result->>'task_id' is not null then
    result:=result||jsonb_build_object('reminder',public.review_reminder_state((result->>'task_id')::uuid));
  end if;
  return result;
end $$;
revoke all on function public.review_overview_before_snooze(uuid),public.review_overview(uuid) from public,anon,authenticated,service_role;
grant execute on function public.review_overview(uuid) to authenticated;

alter function public.child_export_source(uuid) rename to child_export_source_before_review_reminder;
create function public.child_export_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select public.child_export_source_before_review_reminder(target_child_id)||jsonb_build_array(jsonb_build_object(
    'name','review_reminders','columns',jsonb_build_array('task_id','revision','delay_minutes','remind_at','requested_at'),
    'rows',coalesce((select jsonb_agg(to_jsonb(r)-'command_id' order by r.task_id)
      from public.review_reminder_requests r join public.task_instances t on t.id=r.task_id where t.child_id=target_child_id),'[]')));
$$;
revoke all on function public.child_export_source(uuid),public.child_export_source_before_review_reminder(uuid) from public,anon,authenticated,service_role;
create or replace function public.load_task_reminders(target_child_id uuid)
returns table(reminder_key text, remind_at timestamptz, titles text, remind_local text, tasks jsonb, delivery_policy jsonb)
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
    union all
    select i.id,i.template_id,i.due_date,i.title,r.remind_at
    from public.review_reminder_requests r join public.task_instances i on i.id=r.task_id
    where i.child_id=target_child_id and i.status not in ('completed','skipped','expired','abandoned')
      and i.due_date=(now() at time zone zone)::date and r.remind_at>now()
  ), grouped as (
    select 'slot:'||extract(epoch from s.at)::bigint::text k,s.at,string_agg(distinct s.title,'、' order by s.title) names,
      jsonb_agg(distinct jsonb_build_object('task_id',s.task_id,'template_id',s.template_id,'due_date',s.due_date,'title',s.title)) entries
    from slots s where qs=qe or not (
      case when qs<qe then (s.at at time zone zone)::time>=qs and (s.at at time zone zone)::time<qe
      else (s.at at time zone zone)::time>=qs or (s.at at time zone zone)::time<qe end)
    group by s.at
  ) select g.k,g.at,g.names,to_char(g.at at time zone zone,'YYYY-MM-DD HH24:MI')||' '||zone,g.entries,jsonb_build_object('version','task-reminder-v1','timezone',zone,'quiet_start',to_char(qs,'HH24:MI:SS'),'quiet_end',to_char(qe,'HH24:MI:SS')) from grouped g where not exists(
    select 1 from public.reminder_receipts r where r.child_id=target_child_id and r.reminder_key=g.k)
    order by g.at;
end;
$$;


revoke all on function public.load_task_reminders(uuid) from public,anon;
grant execute on function public.load_task_reminders(uuid) to authenticated;
