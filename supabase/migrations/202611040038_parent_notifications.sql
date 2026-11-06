-- Parent inboxes are derived from authoritative business rows, never child clicks.
-- Preferences and read/delivery receipts belong to each family member separately.
create table public.parent_notification_settings (
  family_id uuid not null, user_id uuid not null,
  enabled boolean not null default false,
  redemptions boolean not null default true,
  sync_errors boolean not null default true,
  weekly_reports boolean not null default true,
  quiet_start time not null default '21:00', quiet_end time not null default '07:00',
  version integer not null default 1,
  primary key(family_id,user_id),
  foreign key(family_id,user_id) references public.family_members(family_id,user_id) on delete cascade
);
create table public.parent_notification_receipts (
  family_id uuid not null, user_id uuid not null,
  child_id uuid not null references public.children(id) on delete cascade,
  notification_key text not null,
  read_at timestamptz, delivered_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(family_id,user_id,notification_key),
  foreign key(family_id,user_id) references public.family_members(family_id,user_id) on delete cascade
);
create index parent_notification_receipts_retention on public.parent_notification_receipts(updated_at);
alter table public.parent_notification_settings enable row level security;
alter table public.parent_notification_receipts enable row level security;
revoke all on public.parent_notification_settings,public.parent_notification_receipts from public,anon,authenticated,service_role;

create function public.parent_notification_preferences(target_family_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select coalesce((select to_jsonb(s)-'family_id'-'user_id' from public.parent_notification_settings s
    where family_id=target_family_id and user_id=auth.uid()),
    '{"enabled":false,"redemptions":true,"sync_errors":true,"weekly_reports":true,"quiet_start":"21:00:00","quiet_end":"07:00:00","version":0}'::jsonb);
$$;
revoke all on function public.parent_notification_preferences(uuid) from public,anon,authenticated,service_role;

create function public.parent_notification_events(target_family_id uuid,as_of timestamptz default now())
returns table(notification_key text,child_id uuid,kind text,created_at timestamptz,anchor_date date)
language sql stable security definer set search_path='' as $$
  with family_time as (
    select timezone,(as_of at time zone timezone)::date as today,
      date_trunc('week',as_of at time zone timezone)::date as monday
    from public.families where id=target_family_id
  )
  select 'redemption:'||d.id::text,d.child_id,'redemption',d.created_at,null::date
    from public.redemptions d join public.children c on c.id=d.child_id
    where c.family_id=target_family_id and public.child_is_visible(c.id)
      and not exists(select 1 from public.child_deletion_tombstones t where t.child_id=c.id)
      and d.status='requested' and d.expires_at>as_of
  union all
  select 'weekly:'||c.id::text||':'||(f.monday-1)::text,c.id,'weekly',
    (f.monday+time '09:00') at time zone f.timezone,f.monday-1
    from public.children c cross join family_time f
    where c.family_id=target_family_id and public.child_is_visible(c.id)
      and not exists(select 1 from public.child_deletion_tombstones t where t.child_id=c.id)
      and c.created_at<((f.monday::timestamp) at time zone f.timezone)
      and as_of>=(f.monday+time '09:00') at time zone f.timezone;
$$;
revoke all on function public.parent_notification_events(uuid,timestamptz) from public,anon,authenticated,service_role;

create function public.parent_notification_inbox(target_family_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  perform public.require_parent_authorization(target_family_id);
  return jsonb_build_object('family_id',target_family_id,'settings',public.parent_notification_preferences(target_family_id),
    'timezone',(select timezone from public.families where id=target_family_id),
    'items',coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc,e.notification_key) from (
      select n.*,r.read_at from public.parent_notification_events(target_family_id) n
      left join public.parent_notification_receipts r on r.family_id=target_family_id and r.user_id=auth.uid()
        and r.notification_key=n.notification_key
    ) e),'[]'::jsonb));
end $$;

create function public.save_parent_notification_settings(target_family_id uuid,config jsonb,expected_version integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare field text; current_version integer;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  perform public.require_parent_authorization(target_family_id);
  if jsonb_typeof(config) is distinct from 'object' or
    (select array_agg(k order by k) from jsonb_object_keys(config) k) is distinct from
    array['enabled','quiet_end','quiet_start','redemptions','sync_errors','weekly_reports'] then
    raise exception 'INVALID_PARENT_NOTIFICATION_SETTINGS'; end if;
  foreach field in array array['enabled','redemptions','sync_errors','weekly_reports'] loop
    if jsonb_typeof(config->field) is distinct from 'boolean' then raise exception 'INVALID_PARENT_NOTIFICATION_SETTINGS'; end if;
  end loop;
  foreach field in array array['quiet_start','quiet_end'] loop
    if jsonb_typeof(config->field) is distinct from 'string' or (config->>field)!~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      raise exception 'INVALID_PARENT_NOTIFICATION_TIME'; end if;
  end loop;
  -- A membership lock serializes saving with removal from the family.
  perform 1 from public.family_members where family_id=target_family_id and user_id=auth.uid() for update;
  if not found then raise exception 'PARENT_NOTIFICATION_ACCESS_DENIED' using errcode='42501'; end if;
  select version into current_version from public.parent_notification_settings where family_id=target_family_id and user_id=auth.uid();
  if expected_version is distinct from coalesce(current_version,0) then raise exception 'PARENT_NOTIFICATION_SETTINGS_CONFLICT'; end if;
  insert into public.parent_notification_settings(family_id,user_id,enabled,redemptions,sync_errors,weekly_reports,quiet_start,quiet_end)
    values(target_family_id,auth.uid(),(config->>'enabled')::boolean,(config->>'redemptions')::boolean,
      (config->>'sync_errors')::boolean,(config->>'weekly_reports')::boolean,(config->>'quiet_start')::time,(config->>'quiet_end')::time)
    on conflict(family_id,user_id) do update set enabled=excluded.enabled,redemptions=excluded.redemptions,
      sync_errors=excluded.sync_errors,weekly_reports=excluded.weekly_reports,quiet_start=excluded.quiet_start,
      quiet_end=excluded.quiet_end,version=parent_notification_settings.version+1;
  return public.parent_notification_preferences(target_family_id);
end $$;

-- The delivery feed contains no names, reward text, task bodies or report contents.
-- Enabling it requires PIN; later foreground refreshes need current membership.
create function public.parent_notification_delivery(target_family_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s jsonb; local_time time; quiet boolean;
begin
  if not public.is_family_member(target_family_id) then
    raise exception 'PARENT_NOTIFICATION_ACCESS_DENIED' using errcode='42501'; end if;
  s:=public.parent_notification_preferences(target_family_id);
  select (now() at time zone timezone)::time into local_time from public.families where id=target_family_id;
  quiet:=case when (s->>'quiet_start')::time=(s->>'quiet_end')::time then false
    when (s->>'quiet_start')::time<(s->>'quiet_end')::time then local_time>=(s->>'quiet_start')::time and local_time<(s->>'quiet_end')::time
    else local_time>=(s->>'quiet_start')::time or local_time<(s->>'quiet_end')::time end;
  return jsonb_build_object('family_id',target_family_id,'settings',s,'quiet',quiet,
    'items',case when not (s->>'enabled')::boolean or quiet then '[]'::jsonb else coalesce((
      select jsonb_agg(to_jsonb(n) order by n.created_at,n.notification_key) from public.parent_notification_events(target_family_id) n
      left join public.parent_notification_receipts r on r.family_id=target_family_id and r.user_id=auth.uid() and r.notification_key=n.notification_key
      where r.read_at is null and r.delivered_at is null
        and ((n.kind='redemption' and (s->>'redemptions')::boolean) or (n.kind='weekly' and (s->>'weekly_reports')::boolean))
    ),'[]'::jsonb) end);
end $$;

create function public.ack_parent_notifications(target_family_id uuid,keys jsonb,operation text default 'read') returns jsonb
language plpgsql security definer set search_path='' as $$
declare item record; matched integer:=0;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  if operation is null or operation not in ('read','delivered') then raise exception 'INVALID_PARENT_NOTIFICATION_OPERATION'; end if;
  if operation='read' then perform public.require_parent_authorization(target_family_id);
  elsif not public.is_family_member(target_family_id) or not (public.parent_notification_preferences(target_family_id)->>'enabled')::boolean then
    raise exception 'PARENT_NOTIFICATION_ACCESS_DENIED' using errcode='42501'; end if;
  if jsonb_typeof(keys) is distinct from 'array' or jsonb_array_length(keys) not between 1 and 200 then
    raise exception 'INVALID_PARENT_NOTIFICATION_KEYS'; end if;
  if (select count(distinct value) from jsonb_array_elements(keys) where jsonb_typeof(value)='string')<>jsonb_array_length(keys) then
    raise exception 'INVALID_PARENT_NOTIFICATION_KEYS'; end if;
  perform 1 from public.family_members where family_id=target_family_id and user_id=auth.uid() for update;
  if not found then raise exception 'PARENT_NOTIFICATION_ACCESS_DENIED' using errcode='42501'; end if;
  -- Serialize with child deletion before deriving the currently visible events.
  perform pg_advisory_xact_lock(hashtextextended('cleanup:'||id::text,0))
    from public.children where family_id=target_family_id order by id;
  perform 1 from public.children where family_id=target_family_id order by id for share;
  for item in select * from public.parent_notification_events(target_family_id) e where keys ? e.notification_key loop
    insert into public.parent_notification_receipts(family_id,user_id,child_id,notification_key,read_at,delivered_at)
      values(target_family_id,auth.uid(),item.child_id,item.notification_key,
        case when operation='read' then now() end,case when operation='delivered' then now() end)
      on conflict(family_id,user_id,notification_key) do update set
        read_at=coalesce(parent_notification_receipts.read_at,excluded.read_at),
        delivered_at=coalesce(parent_notification_receipts.delivered_at,excluded.delivered_at),updated_at=now();
    matched:=matched+1;
  end loop;
  if matched<>jsonb_array_length(keys) then raise exception 'PARENT_NOTIFICATION_SCOPE_CHANGED'; end if;
  return jsonb_build_object('keys',keys,'operation',operation);
end $$;
revoke all on function public.parent_notification_inbox(uuid),public.parent_notification_delivery(uuid),
  public.save_parent_notification_settings(uuid,jsonb,integer),public.ack_parent_notifications(uuid,jsonb,text) from public,anon,authenticated,service_role;
grant execute on function public.parent_notification_inbox(uuid),public.parent_notification_delivery(uuid),
  public.save_parent_notification_settings(uuid,jsonb,integer),public.ack_parent_notifications(uuid,jsonb,text) to authenticated;

create function public.erase_child_parent_notification_receipts() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  delete from public.parent_notification_receipts where child_id=new.child_id;
  return new;
end $$;
create trigger erase_child_parent_notification_receipts after insert on public.child_deletion_tombstones
  for each row execute function public.erase_child_parent_notification_receipts();
revoke all on function public.erase_child_parent_notification_receipts() from public,anon,authenticated,service_role;

create function public.erase_account_parent_notifications() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  delete from public.parent_notification_receipts where user_id=new.user_id;
  delete from public.parent_notification_settings where user_id=new.user_id;
  return new;
end $$;
create trigger erase_account_parent_notifications after insert on public.account_deletion_jobs
  for each row execute function public.erase_account_parent_notifications();
revoke all on function public.erase_account_parent_notifications() from public,anon,authenticated,service_role;

create function public.purge_parent_notification_receipts() returns void
language sql security definer set search_path='' as $$
  delete from public.parent_notification_receipts where updated_at<now()-interval '90 days';
$$;
revoke all on function public.purge_parent_notification_receipts() from public,anon,authenticated,service_role;
grant execute on function public.purge_parent_notification_receipts() to service_role;

alter function public.child_export_source(uuid) rename to child_export_source_before_parent_notifications;
create function public.child_export_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select public.child_export_source_before_parent_notifications(target_child_id)||jsonb_build_array(jsonb_build_object(
    'name','parent_notification_receipts','columns',jsonb_build_array('child_id','notification_key','read_at','delivered_at','updated_at'),
    'rows',coalesce((select jsonb_agg(to_jsonb(r)-'user_id'-'family_id' order by notification_key)
      from public.parent_notification_receipts r where child_id=target_child_id and user_id=auth.uid()),'[]'::jsonb)));
$$;
revoke all on function public.child_export_source(uuid),public.child_export_source_before_parent_notifications(uuid) from public,anon,authenticated,service_role;
