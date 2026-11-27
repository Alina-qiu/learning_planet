-- TSK-01: parent-controlled family time, independent of a device's timezone.
alter table public.families add column timezone_version bigint not null default 0 check(timezone_version>=0);
revoke update(timezone) on public.families from authenticated;

create function public.validate_family_timezone_change() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from pg_catalog.pg_timezone_names where name=new.timezone) then
    raise exception '请选择有效的家庭时区' using errcode='22023'; end if;
  if new.timezone is distinct from old.timezone then
    new.timezone_version:=old.timezone_version+1;
    update public.parent_notification_settings set version=version+1 where family_id=new.id;
  end if;
  return new;
end $$;
revoke all on function public.validate_family_timezone_change() from public,anon,authenticated,service_role;
create trigger validate_family_timezone_change before update of timezone on public.families
  for each row execute function public.validate_family_timezone_change();

create function public.family_time_settings(target_family_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare f public.families;
begin
  perform public.require_parent_authorization(target_family_id);
  if not public.is_family_admin(target_family_id) then raise exception '仅家庭管理员可以修改时区' using errcode='42501'; end if;
  select * into f from public.families where id=target_family_id;
  if not found then raise exception '家庭不存在' using errcode='42501'; end if;
  return jsonb_build_object('family_id',f.id,'timezone',f.timezone,'version',f.timezone_version,
    'family_today',(now() at time zone f.timezone)::date,'server_time',now(),
    'child_ids',coalesce((select jsonb_agg(c.id order by c.id) from public.children c where c.family_id=f.id),'[]'::jsonb));
end $$;
revoke all on function public.family_time_settings(uuid) from public,anon,authenticated,service_role;
grant execute on function public.family_time_settings(uuid) to authenticated;

create function public.set_family_timezone(target_family_id uuid,requested_timezone text,expected_version bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare f public.families;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  select * into f from public.families where id=target_family_id for update;
  perform public.require_parent_authorization(target_family_id);
  if not public.is_family_admin(target_family_id) then raise exception '仅家庭管理员可以修改时区' using errcode='42501'; end if;
  if expected_version is null or expected_version<0 or requested_timezone is null
    or not exists(select 1 from pg_catalog.pg_timezone_names where name=requested_timezone) then
    raise exception '时区或版本无效，请刷新后重试' using errcode='22023'; end if;
  if f.timezone_version<>expected_version then
    -- A lost response can be replayed without a second audit/version change.
    -- After any intervening change, even A -> B -> A, the old intent is stale.
    if f.timezone_version=expected_version+1 and f.timezone=requested_timezone then
      return public.family_time_settings(f.id)||jsonb_build_object('outcome','already_applied'); end if;
    raise exception '家庭时区已由另一台设备修改，请刷新核对' using errcode='40001';
  end if;
  if f.timezone=requested_timezone then
    return public.family_time_settings(f.id)||jsonb_build_object('outcome','unchanged'); end if;
  update public.families set timezone=requested_timezone where id=f.id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(f.id,auth.uid(),'family.timezone_changed','family',f.id::text,
      jsonb_build_object('before',f.timezone,'after',requested_timezone,'previous_version',f.timezone_version,'version',f.timezone_version+1));
  -- Existing tasks, review due instants, plan rules, leases and ledger entries
  -- remain intact. Future generation uses the new family day; unique instance
  -- keys prevent rebuilding a date which has already been generated.
  return public.family_time_settings(f.id)||jsonb_build_object('outcome','applied');
end $$;
revoke all on function public.set_family_timezone(uuid,text,bigint) from public,anon,authenticated,service_role;
grant execute on function public.set_family_timezone(uuid,text,bigint) to authenticated;

-- A timezone write must serialize with generation before either reads its day.
alter function public.generate_scheduled_tasks(uuid,date) rename to generate_scheduled_tasks_before_timezone;
revoke all on function public.generate_scheduled_tasks_before_timezone(uuid,date) from public,anon,authenticated,service_role;
create function public.generate_scheduled_tasks(target_child_id uuid,target_date date default null) returns integer
language plpgsql security definer set search_path='' as $$
begin
  perform 1 from public.families where id=(select family_id from public.children where id=target_child_id) for key share;
  return public.generate_scheduled_tasks_before_timezone(target_child_id,target_date);
end $$;
revoke all on function public.generate_scheduled_tasks(uuid,date) from public,anon,authenticated,service_role;
grant execute on function public.generate_scheduled_tasks(uuid,date) to authenticated,service_role;

alter function public.generate_daily_wrong_review_task(uuid,date,integer) rename to generate_daily_wrong_review_task_before_timezone;
revoke all on function public.generate_daily_wrong_review_task_before_timezone(uuid,date,integer) from public,anon,authenticated,service_role;
create function public.generate_daily_wrong_review_task(target_child_id uuid,target_date date default null,max_questions integer default 10) returns uuid
language plpgsql security definer set search_path='' as $$
begin
  perform 1 from public.families where id=(select family_id from public.children where id=target_child_id) for key share;
  return public.generate_daily_wrong_review_task_before_timezone(target_child_id,target_date,max_questions);
end $$;
revoke all on function public.generate_daily_wrong_review_task(uuid,date,integer) from public,anon,authenticated,service_role;
grant execute on function public.generate_daily_wrong_review_task(uuid,date,integer) to authenticated,service_role;
