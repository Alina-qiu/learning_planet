-- Stage rewards and terminal tiers are immutable and server-calculated.
create table public.plan_stage_rewards (
  plan_id uuid not null references public.long_plans(id) on delete cascade,
  completed_count integer not null check(completed_count > 0),
  coins integer not null check(coins >= 0),
  xp integer not null check(xp >= 0),
  awarded_at timestamptz,
  primary key(plan_id, completed_count)
);
create table public.plan_bonus_tiers (
  plan_id uuid not null references public.long_plans(id) on delete cascade,
  minimum_rate numeric not null check(minimum_rate > 0 and minimum_rate <= 1),
  coins integer not null check(coins >= 0),
  xp integer not null check(xp >= 0),
  primary key(plan_id, minimum_rate)
);
alter table public.plan_stage_rewards enable row level security;
alter table public.plan_bonus_tiers enable row level security;
create policy stages_read on public.plan_stage_rewards for select using(exists(
  select 1 from public.long_plans p join public.task_templates t on t.id=p.template_id
  where p.id=plan_id and public.child_is_visible(t.child_id)));
create policy tiers_read on public.plan_bonus_tiers for select using(exists(
  select 1 from public.long_plans p join public.task_templates t on t.id=p.template_id
  where p.id=plan_id and public.child_is_visible(t.child_id)));

create function public.long_plan_progress(target_plan_id uuid)
returns table(expected integer, completed integer, rate numeric)
language plpgsql stable security definer set search_path=public as $$
declare t public.task_templates;
begin
  select tt.* into t from public.long_plans p join public.task_templates tt on tt.id=p.template_id where p.id=target_plan_id;
  if not public.child_is_visible(t.child_id) then raise exception 'Child access required'; end if;
  select count(*)::integer into expected
    from generate_series(t.starts_on::timestamp,t.ends_on::timestamp,interval '1 day') d
    where public.template_due_on(t,d::date) and not exists(
      select 1 from public.plan_leaves l where l.plan_id=target_plan_id and l.leave_date=d::date);
  select count(*)::integer into completed from public.task_instances i
    where i.template_id=t.id and i.status='completed' and public.template_due_on(t,i.due_date)
    and not exists(select 1 from public.plan_leaves l where l.plan_id=target_plan_id and l.leave_date=i.due_date);
  rate := case when expected=0 then 0 else least(completed::numeric/expected,1) end;
  return next;
end;
$$;
revoke all on function public.long_plan_progress(uuid) from public;
grant execute on function public.long_plan_progress(uuid) to authenticated;

alter function public.save_task_schedule(uuid,jsonb,uuid) rename to save_task_schedule_base;
revoke all on function public.save_task_schedule_base(uuid,jsonb,uuid) from public,authenticated;
create function public.save_task_schedule(target_child_id uuid,config jsonb,target_template_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare tid uuid; pid uuid; stage jsonb; tier jsonb;
begin
  if jsonb_typeof(coalesce(config->'stages','[]')) <> 'array'
    or jsonb_typeof(coalesce(config->'tiers','[]')) <> 'array' then raise exception 'Rewards must be arrays'; end if;
  tid := public.save_task_schedule_base(target_child_id,config,target_template_id);
  select id into pid from public.long_plans where template_id=tid;
  if pid is not null and target_template_id is null then
    for stage in select * from jsonb_array_elements(coalesce(config->'stages','[]')) loop
      insert into public.plan_stage_rewards(plan_id,completed_count,coins,xp)
      values(pid,(stage->>'completed_count')::integer,(stage->>'coins')::integer,(stage->>'xp')::integer);
    end loop;
    for tier in select * from jsonb_array_elements(coalesce(config->'tiers','[]')) loop
      if (tier->>'minimum_rate')::numeric <= (config->>'minimum_rate')::numeric then
        raise exception 'Additional tiers must exceed the base threshold'; end if;
      insert into public.plan_bonus_tiers values(pid,(tier->>'minimum_rate')::numeric,
        (tier->>'coins')::integer,(tier->>'xp')::integer);
    end loop;
  elsif jsonb_array_length(coalesce(config->'stages','[]'))>0 or jsonb_array_length(coalesce(config->'tiers','[]'))>0 then
    raise exception 'Stage rewards and tiers require a new long plan'; end if;
  return tid;
end;
$$;
revoke all on function public.save_task_schedule(uuid,jsonb,uuid) from public;
grant execute on function public.save_task_schedule(uuid,jsonb,uuid) to authenticated;

create function public.award_plan_stages(target_plan_id uuid) returns void
language plpgsql security definer set search_path=public as $$
declare p public.long_plans; child uuid; progress record; stage public.plan_stage_rewards;
begin
  select * into p from public.long_plans where id=target_plan_id for update;
  if p.settled_at is not null then return; end if;
  select child_id into child from public.task_templates where id=p.template_id;
  select * into progress from public.long_plan_progress(p.id);
  for stage in select * from public.plan_stage_rewards where plan_id=p.id
      and completed_count<=progress.completed and awarded_at is null order by completed_count for update loop
    insert into public.ledger_entries(child_id,asset_type,amount,source_type,source_id,idempotency_key)
    values(child,'coin',stage.coins,'plan_stage',p.id,'plan:'||p.id||':stage:'||stage.completed_count||':coin'),
      (child,'xp',stage.xp,'plan_stage',p.id,'plan:'||p.id||':stage:'||stage.completed_count||':xp');
    update public.wallets set coin_balance=coin_balance+stage.coins,xp=xp+stage.xp,updated_at=now() where child_id=child;
    update public.plan_stage_rewards set awarded_at=now() where plan_id=p.id and completed_count=stage.completed_count;
  end loop;
end;
$$;
revoke all on function public.award_plan_stages(uuid) from public,authenticated;

create or replace function public.settle_long_plan(target_plan_id uuid)
returns numeric language plpgsql security definer set search_path=public as $$
declare p public.long_plans; t public.task_templates; family uuid; zone text; progress record; bonus record;
begin
  select * into p from public.long_plans where id=target_plan_id for update;
  select * into t from public.task_templates where id=p.template_id;
  select c.family_id,f.timezone into family,zone from public.children c join public.families f on f.id=c.family_id where c.id=t.child_id;
  perform public.require_parent_authorization(family);
  if p.settled_at is not null then return p.achieved_rate; end if;
  if (now() at time zone zone)::date<=t.ends_on then raise exception 'Plan has not ended'; end if;
  select * into progress from public.long_plan_progress(p.id);
  perform public.award_plan_stages(p.id);
  select * into bonus from (
    select p.minimum_rate minimum_rate,p.bonus_coins coins,p.bonus_xp xp
    union all select b.minimum_rate,b.coins,b.xp from public.plan_bonus_tiers b where b.plan_id=p.id
  ) tiers where minimum_rate<=progress.rate order by minimum_rate desc limit 1;
  if progress.expected>0 and bonus is not null then
    insert into public.ledger_entries(child_id,asset_type,amount,source_type,source_id,idempotency_key)
    values(t.child_id,'coin',bonus.coins,'plan_completion',p.id,'plan:'||p.id||':coin'),
      (t.child_id,'xp',bonus.xp,'plan_completion',p.id,'plan:'||p.id||':xp');
    update public.wallets set coin_balance=coin_balance+bonus.coins,xp=xp+bonus.xp,updated_at=now() where child_id=t.child_id;
  end if;
  update public.long_plans set settled_at=now(),achieved_rate=progress.rate where id=p.id;
  return progress.rate;
end;
$$;

alter function public.complete_task(uuid,text,text) rename to complete_task_timed;
revoke all on function public.complete_task_timed(uuid,text,text) from public,authenticated;
create function public.complete_task(target_task_id uuid,completion_key text,parent_reason text default null)
returns public.task_instances language plpgsql security definer set search_path=public as $$
declare t public.task_instances; pid uuid;
begin
  select * into t from public.task_instances where id=target_task_id for update;
  if not public.child_is_visible(t.child_id) then raise exception 'Task access required'; end if;
  if exists(select 1 from public.long_plans p join public.plan_leaves l on l.plan_id=p.id
      where p.template_id=t.template_id and l.leave_date=t.due_date) then
    raise exception 'Approved leave cannot be completed';
  end if;
  t := public.complete_task_timed(target_task_id,completion_key,parent_reason);
  select id into pid from public.long_plans where template_id=t.template_id;
  if pid is not null then perform public.award_plan_stages(pid); end if;
  return t;
end;
$$;
revoke all on function public.complete_task(uuid,text,text) from public;
grant execute on function public.complete_task(uuid,text,text) to authenticated;
