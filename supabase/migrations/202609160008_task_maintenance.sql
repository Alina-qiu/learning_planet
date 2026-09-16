-- Trusted maintenance may calculate plans without a user's PIN session.
create or replace function public.long_plan_progress(target_plan_id uuid)
returns table(expected integer, completed integer, rate numeric)
language plpgsql stable security definer set search_path=public as $$
declare t public.task_templates;
begin
  select tt.* into t from public.long_plans p join public.task_templates tt on tt.id=p.template_id where p.id=target_plan_id;
  if t.id is null or (auth.role() is distinct from 'service_role' and not public.child_is_visible(t.child_id)) then
    raise exception 'Child access required'; end if;
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

create or replace function public.settle_long_plan(target_plan_id uuid)
returns numeric language plpgsql security definer set search_path=public as $$
declare p public.long_plans; t public.task_templates; family uuid; zone text; progress record; bonus record;
begin
  select * into p from public.long_plans where id=target_plan_id for update;
  if not found then raise exception 'Plan not found'; end if;
  select * into t from public.task_templates where id=p.template_id;
  select c.family_id,f.timezone into family,zone from public.children c join public.families f on f.id=c.family_id where c.id=t.child_id;
  if auth.role() is distinct from 'service_role' then perform public.require_parent_authorization(family); end if;
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

create function public.run_task_maintenance() returns jsonb
language plpgsql security definer set search_path=public as $$
declare child record; plan record; generated integer:=0; settled integer:=0;
  previous_claims text:=current_setting('request.jwt.claims',true);
begin
  -- This function is not callable by anon/authenticated. Only the scheduler
  -- owner or trusted service role may enter this temporary system context.
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  for child in select id from public.children loop
    generated := generated + public.generate_scheduled_tasks(child.id);
  end loop;
  for plan in select p.id from public.long_plans p join public.task_templates t on t.id=p.template_id
    join public.children c on c.id=t.child_id join public.families f on f.id=c.family_id
    where p.settled_at is null and (now() at time zone f.timezone)::date>t.ends_on loop
    perform public.settle_long_plan(plan.id); settled := settled+1;
  end loop;
  perform set_config('request.jwt.claims',coalesce(previous_claims,''),true);
  return jsonb_build_object('generated',generated,'settled',settled);
exception when others then
  perform set_config('request.jwt.claims',coalesce(previous_claims,''),true);
  raise;
end;
$$;
revoke all on function public.run_task_maintenance() from public,anon,authenticated;
grant execute on function public.run_task_maintenance() to service_role;
grant execute on function public.settle_long_plan(uuid) to service_role;

-- Supabase deployments with Cron enabled are scheduled automatically.
-- Plain PostgreSQL test environments intentionally have no pg_cron.
do $$
begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    perform cron.schedule('learning-planet-task-maintenance','*/5 * * * *',
      'select public.run_task_maintenance();');
  end if;
end;
$$;
