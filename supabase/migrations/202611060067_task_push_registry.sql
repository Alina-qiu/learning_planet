-- iPhone task delivery uses a separate installation scope from parent messages.
-- Queueing/receiving is added separately; this migration never sends a message.
create function public.task_reminder_candidates(target_child_id uuid, as_of timestamptz, include_recent_snoozes boolean default false)
returns table(reminder_key text, remind_at timestamptz, titles text, remind_local text, tasks jsonb, delivery_policy jsonb)
language plpgsql security definer set search_path='' as $$
declare zone text; enabled boolean; qs time; qe time;
begin
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id
    where c.id=target_child_id and not exists(select 1 from public.child_deletion_tombstones d where d.child_id=c.id);
  if zone is null or as_of is null then return; end if;
  select s.enabled,s.quiet_start,s.quiet_end into enabled,qs,qe from public.reminder_settings s where s.child_id=target_child_id;
  if enabled=false then return; end if;
  qs:=coalesce(qs,'21:00'); qe:=coalesce(qe,'07:00');
  return query with candidates as (
    select i.id task_id,i.template_id,i.due_date,i.title,i.scheduled_at,i.due_at from public.task_instances i
      where i.child_id=target_child_id and i.status not in ('completed','skipped','expired','abandoned')
    union all
    select null::uuid,t.id,d.day::date,t.title,(d.day::date+t.start_time) at time zone zone,(d.day::date+t.due_time) at time zone zone
    from public.task_templates t
    cross join generate_series((as_of at time zone zone)::date::timestamp,
      ((as_of at time zone zone)::date+7)::timestamp,interval '1 day') d(day)
    left join public.long_plans p on p.template_id=t.id
    where t.child_id=target_child_id and t.active and public.template_due_on(t,d.day::date)
      and not exists(select 1 from public.task_instances i where i.template_id=t.id and i.due_date=d.day::date)
      and not exists(select 1 from public.plan_leaves l where l.plan_id=p.id and l.leave_date=d.day::date)
  ), slots as (
    select i.task_id,i.template_id,i.due_date,i.title,v.at from candidates i
    cross join lateral(values(i.scheduled_at-interval '10 minutes'),(i.scheduled_at),(i.due_at-interval '15 minutes')) v(at)
    where v.at between as_of-interval '1 day' and as_of+interval '7 days'
      and (i.scheduled_at is null or v.at>=i.scheduled_at-interval '10 minutes')
    union all
    select i.id,i.template_id,i.due_date,i.title,r.remind_at
    from public.review_reminder_requests r join public.task_instances i on i.id=r.task_id
    where i.child_id=target_child_id and i.status not in ('completed','skipped','expired','abandoned')
      and i.due_date=(as_of at time zone zone)::date
      and r.remind_at>as_of-case when include_recent_snoozes then interval '15 minutes' else interval '0' end
  ), grouped as (
    select 'slot:'||extract(epoch from s.at)::bigint::text k,s.at,string_agg(distinct s.title,'、' order by s.title) names,
      jsonb_agg(distinct jsonb_build_object('task_id',s.task_id,'template_id',s.template_id,'due_date',s.due_date,'title',s.title)) entries
    from slots s where qs=qe or not (
      case when qs<qe then (s.at at time zone zone)::time>=qs and (s.at at time zone zone)::time<qe
      else (s.at at time zone zone)::time>=qs or (s.at at time zone zone)::time<qe end)
    group by s.at
  ) select g.k,g.at,g.names,to_char(g.at at time zone zone,'YYYY-MM-DD HH24:MI')||' '||zone,g.entries,
      jsonb_build_object('version','task-reminder-v1','timezone',zone,'quiet_start',to_char(qs,'HH24:MI:SS'),'quiet_end',to_char(qe,'HH24:MI:SS'))
    from grouped g where not exists(select 1 from public.reminder_receipts r where r.child_id=target_child_id and r.reminder_key=g.k)
    order by g.at;
end $$;
revoke all on function public.task_reminder_candidates(uuid,timestamptz,boolean) from public,anon,authenticated,service_role;

create or replace function public.load_task_reminders(target_child_id uuid)
returns table(reminder_key text, remind_at timestamptz, titles text, remind_local text, tasks jsonb, delivery_policy jsonb)
language plpgsql security definer set search_path='' as $$
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  return query select * from public.task_reminder_candidates(target_child_id,now(),false);
end $$;

-- Keep policy revisions out of editable/exported reminder settings.
create table public.task_push_policy_versions (
  child_id uuid primary key references public.children(id) on delete cascade,
  version bigint not null check(version between 1 and 9007199254740991)
);
alter table public.task_push_policy_versions enable row level security;
revoke all on public.task_push_policy_versions from public,anon,authenticated,service_role;

create function public.bump_task_push_policy() returns trigger
language plpgsql security definer set search_path='' as $$
declare child uuid;
begin
  if tg_op='UPDATE' and (new.enabled,new.quiet_start,new.quiet_end) is not distinct from (old.enabled,old.quiet_start,old.quiet_end) then return new; end if;
  child:=case when tg_op='DELETE' then old.child_id else new.child_id end;
  if exists(select 1 from public.children where id=child) then
    insert into public.task_push_policy_versions(child_id,version) values(child,2)
      on conflict(child_id) do update set version=task_push_policy_versions.version+1;
  end if;
  return coalesce(new,old);
end $$;
create trigger bump_task_push_policy after insert or update or delete on public.reminder_settings
  for each row execute function public.bump_task_push_policy();
revoke all on function public.bump_task_push_policy() from public,anon,authenticated,service_role;

create function public.bump_family_task_push_policy() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.timezone is distinct from old.timezone then
    insert into public.task_push_policy_versions(child_id,version)
      select id,2 from public.children where family_id=new.id order by id
      on conflict(child_id) do update set version=task_push_policy_versions.version+1;
  end if;
  return new;
end $$;
create trigger bump_family_task_push_policy after update of timezone on public.families
  for each row execute function public.bump_family_task_push_policy();
revoke all on function public.bump_family_task_push_policy() from public,anon,authenticated,service_role;

create table public.task_push_devices (
  device_id uuid primary key,
  family_id uuid not null,
  owner_id uuid not null,
  child_id uuid not null references public.children(id) on delete cascade,
  secret_hash text not null,
  intent_version bigint not null check(intent_version between 1 and 9007199254740991),
  scope_nonce uuid not null,
  state text not null check(state in ('prepared','enabled','disabled')),
  registration_token text,
  registration_hash text,
  prepared_until timestamptz,
  expires_at timestamptz,
  updated_at timestamptz not null default now(),
  foreign key(family_id,owner_id) references public.family_members(family_id,user_id) on delete cascade,
  check(state<>'enabled' or (registration_token is not null and registration_hash is not null and expires_at is not null))
);
create unique index task_push_token_unique on public.task_push_devices(registration_hash) where registration_hash is not null;
create index task_push_device_scope on public.task_push_devices(child_id,owner_id,expires_at) where state='enabled';
alter table public.task_push_devices enable row level security;
revoke all on public.task_push_devices from public,anon,authenticated,service_role;

-- Same lock order as deletion: account, membership, child cleanup, child row.
create function public.lock_task_push_scope(target_child_id uuid,target_owner_id uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare family uuid;
begin
  perform 1 from auth.users where id=target_owner_id for share;
  select family_id into family from public.children where id=target_child_id;
  perform 1 from public.family_members where family_id=family and user_id=target_owner_id for share;
  if not found then raise exception 'TASK_PUSH_ACCESS_DENIED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('cleanup:'||target_child_id::text,0));
  perform 1 from public.children where id=target_child_id and family_id=family for share;
  if not found or not public.family_member_is_active(family,target_owner_id)
    or exists(select 1 from public.child_deletion_tombstones where child_id=target_child_id) then
    raise exception 'TASK_PUSH_ACCESS_DENIED' using errcode='42501';
  end if;
  return family;
end $$;
revoke all on function public.lock_task_push_scope(uuid,uuid) from public,anon,authenticated,service_role;

create function public.task_push_device_view(target_device_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('device_id',d.device_id,'family_id',d.family_id,'child_id',d.child_id,
    'intent_version',d.intent_version,'scope_nonce',d.scope_nonce,'state',d.state,'transport','apns',
    'expires_at',d.expires_at,'server_time',now(),'timezone',f.timezone,'settings_version',coalesce(v.version,1))
  from public.task_push_devices d join public.families f on f.id=d.family_id
    left join public.task_push_policy_versions v on v.child_id=d.child_id where d.device_id=target_device_id;
$$;
revoke all on function public.task_push_device_view(uuid) from public,anon,authenticated,service_role;

create function public.prepare_task_push_device(target_child_id uuid,target_device_id uuid,device_secret text,
  requested_version bigint,requested_nonce uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); family uuid; previous public.task_push_devices; digest text;
begin
  family:=public.lock_task_push_scope(target_child_id,actor);
  if target_device_id is null or requested_nonce is null or requested_version is null or requested_version not between 1 and 9007199254740991
    or device_secret is null or device_secret !~ '^[A-Za-z0-9_-]{43,128}$' then raise exception 'INVALID_TASK_PUSH_DEVICE'; end if;
  if exists(select 1 from public.reminder_settings where child_id=target_child_id and not enabled) then raise exception 'TASK_REMINDERS_DISABLED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('task-push-owner:'||actor::text,0));
  perform pg_advisory_xact_lock(hashtextextended('task-push-device:'||target_device_id::text,0));
  digest:=encode(sha256(convert_to(device_secret,'UTF8')),'hex');
  select * into previous from public.task_push_devices where device_id=target_device_id for update;
  if found then
    if previous.secret_hash<>digest then raise exception 'TASK_PUSH_DEVICE_SECRET_MISMATCH' using errcode='42501'; end if;
    if requested_version<previous.intent_version then raise exception 'STALE_TASK_PUSH_INTENT'; end if;
    if requested_version=previous.intent_version then
      if previous.owner_id<>actor or previous.child_id<>target_child_id or previous.scope_nonce<>requested_nonce then raise exception 'TASK_PUSH_INTENT_MISMATCH'; end if;
      return public.task_push_device_view(target_device_id);
    end if;
    if previous.owner_id<>actor and (select count(*) from public.task_push_devices where owner_id=actor)>=100 then raise exception 'TASK_PUSH_DEVICE_LIMIT'; end if;
    update public.task_push_devices set family_id=family,owner_id=actor,child_id=target_child_id,intent_version=requested_version,
      scope_nonce=requested_nonce,state='prepared',registration_token=null,registration_hash=null,
      prepared_until=now()+interval '5 minutes',expires_at=null,updated_at=now() where device_id=target_device_id;
  else
    if (select count(*) from public.task_push_devices where owner_id=actor)>=100 then raise exception 'TASK_PUSH_DEVICE_LIMIT'; end if;
    insert into public.task_push_devices(device_id,family_id,owner_id,child_id,secret_hash,intent_version,scope_nonce,state,prepared_until)
      values(target_device_id,family,actor,target_child_id,digest,requested_version,requested_nonce,'prepared',now()+interval '5 minutes');
  end if;
  return public.task_push_device_view(target_device_id);
end $$;
revoke all on function public.prepare_task_push_device(uuid,uuid,text,bigint,uuid) from public,anon,authenticated,service_role;
grant execute on function public.prepare_task_push_device(uuid,uuid,text,bigint,uuid) to authenticated;

create function public.activate_task_push_device(target_device_id uuid,device_secret text,requested_version bigint,push_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare device public.task_push_devices; child uuid;
begin
  select child_id into child from public.task_push_devices where device_id=target_device_id and owner_id=auth.uid();
  perform public.lock_task_push_scope(child,auth.uid());
  perform pg_advisory_xact_lock(hashtextextended('task-push-device:'||target_device_id::text,0));
  select * into device from public.task_push_devices where device_id=target_device_id for update;
  if not found or device.owner_id is distinct from auth.uid() or device.child_id is distinct from child
    or device_secret is null or device.secret_hash<>encode(sha256(convert_to(device_secret,'UTF8')),'hex') then
    raise exception 'TASK_PUSH_ACCESS_DENIED' using errcode='42501';
  end if;
  if requested_version is distinct from device.intent_version or device.state not in ('prepared','enabled') then raise exception 'STALE_TASK_PUSH_INTENT'; end if;
  if push_token is null or length(push_token) not between 2 and 4096 or length(push_token)%2<>0 or push_token !~ '^[0-9a-f]+$' then raise exception 'INVALID_TASK_PUSH_TOKEN'; end if;
  if exists(select 1 from public.reminder_settings where child_id=child and not enabled) then raise exception 'TASK_REMINDERS_DISABLED'; end if;
  if device.state='enabled' then
    if device.registration_token<>push_token or device.expires_at<=now() then raise exception 'TASK_PUSH_INTENT_MISMATCH'; end if;
    return public.task_push_device_view(target_device_id);
  end if;
  if device.prepared_until<=now() then raise exception 'TASK_PUSH_PREPARATION_EXPIRED'; end if;
  update public.task_push_devices set state='enabled',registration_token=push_token,
    registration_hash=encode(sha256(convert_to(push_token,'UTF8')),'hex'),prepared_until=null,
    expires_at=now()+interval '30 days',updated_at=now() where device_id=target_device_id;
  return public.task_push_device_view(target_device_id);
end $$;
revoke all on function public.activate_task_push_device(uuid,text,bigint,text) from public,anon,authenticated,service_role;
grant execute on function public.activate_task_push_device(uuid,text,bigint,text) to authenticated;

create function public.renew_task_push_device(target_device_id uuid,device_secret text,requested_version bigint,push_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare device public.task_push_devices; child uuid;
begin
  select child_id into child from public.task_push_devices where device_id=target_device_id and owner_id=auth.uid();
  perform public.lock_task_push_scope(child,auth.uid());
  perform pg_advisory_xact_lock(hashtextextended('task-push-device:'||target_device_id::text,0));
  select * into device from public.task_push_devices where device_id=target_device_id for update;
  if not found or device.owner_id is distinct from auth.uid() or device.child_id is distinct from child
    or device_secret is null or device.secret_hash<>encode(sha256(convert_to(device_secret,'UTF8')),'hex') then
    raise exception 'TASK_PUSH_ACCESS_DENIED' using errcode='42501';
  end if;
  if requested_version is distinct from device.intent_version or device.state<>'enabled' or device.expires_at<=now() then raise exception 'STALE_TASK_PUSH_INTENT'; end if;
  if push_token is null or length(push_token) not between 2 and 4096 or length(push_token)%2<>0 or push_token !~ '^[0-9a-f]+$' then raise exception 'INVALID_TASK_PUSH_TOKEN'; end if;
  if exists(select 1 from public.reminder_settings where child_id=child and not enabled) then raise exception 'TASK_REMINDERS_DISABLED'; end if;
  update public.task_push_devices set registration_token=push_token,
    registration_hash=encode(sha256(convert_to(push_token,'UTF8')),'hex'),expires_at=now()+interval '30 days',updated_at=now() where device_id=target_device_id;
  return public.task_push_device_view(target_device_id);
end $$;
revoke all on function public.renew_task_push_device(uuid,text,bigint,text) from public,anon,authenticated,service_role;
grant execute on function public.renew_task_push_device(uuid,text,bigint,text) to authenticated;

create function public.revoke_task_push_device(target_device_id uuid,device_secret text,requested_version bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  if target_device_id is null or requested_version is null or requested_version not between 1 and 9007199254740991
    or device_secret is null or device_secret !~ '^[A-Za-z0-9_-]{43,128}$' then raise exception 'INVALID_TASK_PUSH_DEVICE'; end if;
  perform pg_advisory_xact_lock(hashtextextended('task-push-device:'||target_device_id::text,0));
  update public.task_push_devices set state='disabled',intent_version=requested_version,registration_token=null,
    registration_hash=null,prepared_until=null,expires_at=null,updated_at=now()
    where device_id=target_device_id and secret_hash=encode(sha256(convert_to(device_secret,'UTF8')),'hex') and intent_version<requested_version;
  return jsonb_build_object('device_id',target_device_id,'intent_version',requested_version,'revoked',true);
end $$;
revoke all on function public.revoke_task_push_device(uuid,text,bigint) from public,anon,authenticated,service_role;
grant execute on function public.revoke_task_push_device(uuid,text,bigint) to anon,authenticated;

create function public.erase_account_task_push() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  delete from public.task_push_devices where owner_id=new.user_id or family_id=any(new.owned_family_ids);
  return new;
end $$;
create trigger erase_account_task_push after insert on public.account_deletion_jobs
  for each row execute function public.erase_account_task_push();
revoke all on function public.erase_account_task_push() from public,anon,authenticated,service_role;

create function public.erase_child_task_push() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  delete from public.task_push_devices where child_id=new.child_id;
  return new;
end $$;
create trigger erase_child_task_push after insert on public.child_deletion_tombstones
  for each row execute function public.erase_child_task_push();
revoke all on function public.erase_child_task_push() from public,anon,authenticated,service_role;

create function public.purge_task_push_devices() returns void
language plpgsql security definer set search_path='' as $$
begin
  update public.task_push_devices set state='disabled',registration_token=null,registration_hash=null,expires_at=null,prepared_until=null
    where state='enabled' and expires_at<=now() or state='prepared' and prepared_until<=now();
  delete from public.task_push_devices where state='disabled' and updated_at<now()-interval '90 days';
end $$;
revoke all on function public.purge_task_push_devices() from public,anon,authenticated,service_role;
grant execute on function public.purge_task_push_devices() to service_role;
