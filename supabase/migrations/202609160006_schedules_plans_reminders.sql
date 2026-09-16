-- Family-local scheduling; existing instances remain immutable snapshots.
alter table public.task_templates
  add column starts_on date,
  add column ends_on date,
  add column start_time time not null default '16:00',
  add column due_time time not null default '20:00',
  add column minimum_seconds integer not null default 0 check(minimum_seconds >= 0),
  add constraint template_dates check(ends_on is null or starts_on is null or ends_on >= starts_on),
  add constraint template_times check(due_time > start_time);
alter table public.task_instances add column minimum_seconds integer not null default 0;

create table public.long_plans (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null unique references public.task_templates(id) on delete cascade,
  minimum_rate numeric not null check(minimum_rate > 0 and minimum_rate <= 1),
  bonus_coins integer not null check(bonus_coins >= 0),
  bonus_xp integer not null check(bonus_xp >= 0),
  settled_at timestamptz,
  achieved_rate numeric,
  created_at timestamptz not null default now()
);
create table public.plan_leaves (
  plan_id uuid not null references public.long_plans(id) on delete cascade,
  leave_date date not null,
  reason text not null check(length(btrim(reason)) > 0),
  primary key(plan_id, leave_date)
);
create table public.reminder_settings (
  child_id uuid primary key references public.children(id) on delete cascade,
  enabled boolean not null default true,
  quiet_start time not null default '21:00',
  quiet_end time not null default '07:00'
);
create table public.reminder_receipts (
  child_id uuid not null references public.children(id) on delete cascade,
  reminder_key text not null,
  acknowledged_at timestamptz not null default now(),
  primary key(child_id, reminder_key)
);
alter table public.long_plans enable row level security;
alter table public.plan_leaves enable row level security;
alter table public.reminder_settings enable row level security;
alter table public.reminder_receipts enable row level security;
create policy plans_read on public.long_plans for select using(exists(
  select 1 from public.task_templates t where t.id = template_id and public.child_is_visible(t.child_id)));
create policy leaves_read on public.plan_leaves for select using(exists(
  select 1 from public.long_plans p join public.task_templates t on t.id=p.template_id
  where p.id=plan_id and public.child_is_visible(t.child_id)));
create policy reminders_read on public.reminder_settings for select using(public.child_is_visible(child_id));
create policy reminders_write on public.reminder_settings for all using(exists(
  select 1 from public.children c where c.id=child_id and public.can_manage_family(c.family_id)))
  with check(exists(select 1 from public.children c where c.id=child_id and public.can_manage_family(c.family_id)));
create policy receipts_member on public.reminder_receipts for all
  using(public.child_is_visible(child_id)) with check(public.child_is_visible(child_id));

create function public.template_due_on(t public.task_templates, day date)
returns boolean language sql immutable set search_path=public as $$
  select (t.starts_on is null or day >= t.starts_on)
    and (t.ends_on is null or day <= t.ends_on) and (
    t.recurrence='daily' or
    (t.recurrence='once' and t.recurrence_rule->>'date'=day::text) or
    (t.recurrence='weekly' and t.recurrence_rule->'weekdays'
      @> jsonb_build_array(extract(isodow from day)::integer)) or
    (t.recurrence='custom' and t.recurrence_rule->'dates' @> jsonb_build_array(day::text)))
$$;
revoke all on function public.template_due_on(public.task_templates,date) from public;
-- The browser cannot choose another day or backfill historical rewards.
create or replace function public.generate_scheduled_tasks(target_child_id uuid, target_date date default null)
returns integer language plpgsql security definer set search_path=public as $$
declare zone text; day date; generated integer;
begin
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id
    where c.id=target_child_id;
  if zone is null or (auth.role() is distinct from 'service_role'
      and not public.child_is_visible(target_child_id)) then raise exception 'Child access required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('schedule:'||target_child_id::text,0));
  day := (now() at time zone zone)::date;
  if auth.role()='service_role' and target_date is not null then day := target_date;
  elsif target_date is not null and target_date<>day then raise exception 'Only family-local today may be generated'; end if;
  with inserted as (
    insert into public.task_instances(child_id,template_id,title,description,due_date,
      scheduled_at,due_at,source_type,coin_reward,xp_reward,minimum_seconds,idempotency_key)
    select t.child_id,t.id,t.title,t.description,day,
      (day+t.start_time) at time zone zone,(day+t.due_time) at time zone zone,
      case when p.id is null then 'parent_template'::public.task_source else 'long_plan'::public.task_source end,
      t.coin_reward,t.xp_reward,t.minimum_seconds,'template:'||t.id::text||':'||day::text
    from public.task_templates t left join public.long_plans p on p.template_id=t.id
    where t.child_id=target_child_id and t.active and public.template_due_on(t,day)
      and not exists(select 1 from public.plan_leaves l where l.plan_id=p.id and l.leave_date=day)
    on conflict(idempotency_key) do nothing returning id
  ) select count(*) into generated from inserted;
  return generated;
end;
$$;

create function public.save_task_schedule(target_child_id uuid, config jsonb, target_template_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare family uuid; zone text; today date; tid uuid; rec public.task_recurrence;
  first_day date; last_day date; rule jsonb; st time; dt time;
begin
  select c.family_id,f.timezone into family,zone from public.children c
    join public.families f on f.id=c.family_id where c.id=target_child_id;
  perform public.require_parent_authorization(family);
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
      start_time,due_time,coin_reward,xp_reward,minimum_seconds)
    values(target_child_id,btrim(config->>'title'),rec,rule,first_day,last_day,st,dt,
      (config->>'coins')::integer,(config->>'xp')::integer,(config->>'minimum_seconds')::integer)
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
      minimum_seconds=(config->>'minimum_seconds')::integer,updated_at=now() where id=tid;
  end if;
  perform public.generate_scheduled_tasks(target_child_id);
  return tid;
end;
$$;
-- Prevent raw updates from bypassing schedule validation and plan immutability.
revoke execute on function public.create_task_from_template(uuid,date,timestamptz) from authenticated;
drop policy task_templates_parent_write on public.task_templates;
create function public.set_schedule_active(target_template_id uuid, enabled boolean)
returns void language plpgsql security definer set search_path=public as $$
declare family uuid;
begin
  select c.family_id into family from public.task_templates t join public.children c on c.id=t.child_id
    where t.id=target_template_id;
  perform public.require_parent_authorization(family);
  if exists(select 1 from public.long_plans where template_id=target_template_id) then
    raise exception 'Use approved leave for long plans'; end if;
  update public.task_templates set active=enabled,updated_at=now() where id=target_template_id;
end;
$$;
create function public.approve_plan_leave(target_plan_id uuid, day date, leave_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare t public.task_templates; family uuid; zone text;
begin
  select tt.* into t from public.long_plans p join public.task_templates tt on tt.id=p.template_id
    where p.id=target_plan_id;
  select c.family_id,f.timezone into family,zone from public.children c join public.families f on f.id=c.family_id
    where c.id=t.child_id;
  perform public.require_parent_authorization(family);
  -- Serialize generation/leave and lock task before plan, matching completion.
  perform pg_advisory_xact_lock(hashtextextended('schedule:'||t.child_id::text,0));
  perform 1 from public.task_instances where template_id=t.id and due_date=day for update;
  perform 1 from public.long_plans where id=target_plan_id for update;
  if day<(now() at time zone zone)::date or not public.template_due_on(t,day)
    or exists(select 1 from public.long_plans where id=target_plan_id and settled_at is not null) then
    raise exception 'Only pending planned dates may be excused'; end if;
  if exists(select 1 from public.task_instances where template_id=t.id and due_date=day
    and status not in ('ready','scheduled','skipped')) then raise exception 'Task has already started'; end if;
  insert into public.plan_leaves values(target_plan_id,day,leave_reason)
    on conflict(plan_id,leave_date) do update set reason=excluded.reason;
  update public.task_instances set status='skipped' where template_id=t.id and due_date=day;
end;
$$;
create function public.settle_long_plan(target_plan_id uuid)
returns numeric language plpgsql security definer set search_path=public as $$
declare p public.long_plans; t public.task_templates; family uuid; zone text; expected integer; done integer; rate numeric;
begin
  select * into p from public.long_plans where id=target_plan_id for update;
  select * into t from public.task_templates where id=p.template_id;
  select c.family_id,f.timezone into family,zone from public.children c join public.families f on f.id=c.family_id where c.id=t.child_id;
  perform public.require_parent_authorization(family);
  if p.settled_at is not null then return p.achieved_rate; end if;
  if (now() at time zone zone)::date<=t.ends_on then raise exception 'Plan has not ended'; end if;
  select count(*) into expected from generate_series(t.starts_on::timestamp,t.ends_on::timestamp,interval '1 day') d
    where public.template_due_on(t,d::date) and not exists(
      select 1 from public.plan_leaves l where l.plan_id=p.id and l.leave_date=d::date);
  select count(*) into done from public.task_instances i where i.template_id=t.id and i.status='completed'
    and i.due_date between t.starts_on and t.ends_on
    and not exists(select 1 from public.plan_leaves l where l.plan_id=p.id and l.leave_date=i.due_date);
  rate := case when expected=0 then 0 else least(done::numeric/expected,1) end;
  if expected>0 and rate>=p.minimum_rate then
    insert into public.ledger_entries(child_id,asset_type,amount,source_type,source_id,idempotency_key)
    values(t.child_id,'coin',p.bonus_coins,'plan_completion',p.id,'plan:'||p.id||':coin'),
      (t.child_id,'xp',p.bonus_xp,'plan_completion',p.id,'plan:'||p.id||':xp');
    update public.wallets set coin_balance=coin_balance+p.bonus_coins,xp=xp+p.bonus_xp,updated_at=now()
      where child_id=t.child_id;
  end if;
  update public.long_plans set settled_at=now(),achieved_rate=rate where id=p.id;
  return rate;
end;
$$;

-- At most three slots per task, merged at the same timestamp, in family time.
create function public.load_task_reminders(target_child_id uuid)
returns table(reminder_key text, remind_at timestamptz, titles text, remind_local text)
language plpgsql security definer set search_path=public as $$
declare zone text; enabled boolean; qs time; qe time;
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required'; end if;
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  select s.enabled,s.quiet_start,s.quiet_end into enabled,qs,qe from public.reminder_settings s where s.child_id=target_child_id;
  if enabled=false then return; end if;
  qs := coalesce(qs,'21:00'); qe := coalesce(qe,'07:00');
  return query with candidates as (
    select i.title,i.scheduled_at,i.due_at from public.task_instances i
      where i.child_id=target_child_id and i.status not in ('completed','skipped','expired')
    union all
    select t.title,(d.day::date+t.start_time) at time zone zone,(d.day::date+t.due_time) at time zone zone
    from public.task_templates t
    cross join generate_series((now() at time zone zone)::date::timestamp,
      ((now() at time zone zone)::date+7)::timestamp,interval '1 day') d(day)
    left join public.long_plans p on p.template_id=t.id
    where t.child_id=target_child_id and t.active and public.template_due_on(t,d.day::date)
      and not exists(select 1 from public.task_instances i where i.template_id=t.id and i.due_date=d.day::date)
      and not exists(select 1 from public.plan_leaves l where l.plan_id=p.id and l.leave_date=d.day::date)
  ), slots as (
    select i.title,v.at from candidates i
    cross join lateral(values(i.scheduled_at-interval '10 minutes'),(i.scheduled_at),(i.due_at-interval '15 minutes')) v(at)
    where v.at between now()-interval '1 day' and now()+interval '7 days'
      and (i.scheduled_at is null or v.at>=i.scheduled_at-interval '10 minutes')
  ), grouped as (
    select 'slot:'||extract(epoch from s.at)::bigint::text k,s.at,string_agg(distinct s.title,'、' order by s.title) names
    from slots s where qs=qe or not (
      case when qs<qe then (s.at at time zone zone)::time>=qs and (s.at at time zone zone)::time<qe
      else (s.at at time zone zone)::time>=qs or (s.at at time zone zone)::time<qe end)
    group by s.at
  ) select g.k,g.at,g.names,to_char(g.at at time zone zone,'YYYY-MM-DD HH24:MI')||' '||zone from grouped g where not exists(
    select 1 from public.reminder_receipts r where r.child_id=target_child_id and r.reminder_key=g.k)
    order by g.at;
end;
$$;

-- A minimum time is enforced server-side, not by a mutable client clock.
alter function public.complete_task(uuid,text,text) rename to complete_task_authorized;
revoke all on function public.complete_task_authorized(uuid,text,text) from public,authenticated;
create function public.complete_task(target_task_id uuid,completion_key text,parent_reason text default null)
returns public.task_instances language plpgsql security definer set search_path=public as $$
declare t public.task_instances;
begin
  select * into t from public.task_instances where id=target_task_id for update;
  if not public.child_is_visible(t.child_id) then raise exception 'Task access required'; end if;
  if t.status<>'completed' and parent_reason is null and t.accumulated_seconds +
    (case when t.active_started_at is null then 0 else greatest(extract(epoch from now()-t.active_started_at)::integer,0) end)
    < t.minimum_seconds then raise exception 'Minimum effective time has not been reached'; end if;
  return public.complete_task_authorized(target_task_id,completion_key,parent_reason);
end;
$$;
revoke all on function public.save_task_schedule(uuid,jsonb,uuid) from public;
revoke all on function public.set_schedule_active(uuid,boolean) from public;
revoke all on function public.approve_plan_leave(uuid,date,text) from public;
revoke all on function public.settle_long_plan(uuid) from public;
revoke all on function public.load_task_reminders(uuid) from public;
revoke all on function public.complete_task(uuid,text,text) from public;
grant execute on function public.save_task_schedule(uuid,jsonb,uuid),
  public.set_schedule_active(uuid,boolean),public.approve_plan_leave(uuid,date,text),
  public.settle_long_plan(uuid),public.load_task_reminders(uuid),public.complete_task(uuid,text,text) to authenticated;

create function public.family_today(target_child_id uuid) returns text
language plpgsql stable security definer set search_path=public as $$
declare day text;
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required'; end if;
  select ((now() at time zone f.timezone)::date)::text into day
    from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  return day;
end;
$$;
revoke all on function public.family_today(uuid) from public;
grant execute on function public.family_today(uuid) to authenticated;
