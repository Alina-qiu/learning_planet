-- Short foreground editing intervals; no field values, titles or input content.
create table public.parent_configuration_intervals (
  owner_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null,
  child_id uuid not null references public.children(id) on delete cascade,
  family_id uuid not null references public.families(id) on delete cascade,
  kind text not null check(kind in ('task','rules')),
  started_at timestamptz not null,
  ended_at timestamptz not null,
  payload_hash text not null,
  received_at timestamptz not null default now(),
  primary key(owner_id,event_id),
  check(ended_at>started_at and ended_at-started_at<=interval '30 seconds')
);
create index parent_configuration_report_idx on public.parent_configuration_intervals(family_id,ended_at);
alter table public.parent_configuration_intervals enable row level security;
revoke all on public.parent_configuration_intervals from public,anon,authenticated;

create function public.record_parent_configuration(events jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); e jsonb; field text; first_at timestamptz; last_at timestamptz;
  child uuid; family uuid; identifier uuid; digest text; previous text;
  observed timestamptz:=clock_timestamp(); used integer; accepted integer:=0; ids jsonb:='[]';
begin
  perform 1 from auth.users where id=actor for share;
  if not found or not public.account_is_active(actor) then raise exception 'CONFIGURATION_ACCESS_DENIED' using errcode='42501'; end if;
  if jsonb_typeof(events) is distinct from 'array' or jsonb_array_length(events) not between 1 and 50 then
    raise exception 'INVALID_CONFIGURATION_EVENTS'; end if;
  -- Validate every item before inserting any record. Never accept arbitrary text.
  for e in select value from jsonb_array_elements(events) loop
    if jsonb_typeof(e) is distinct from 'object' or
      (select count(*) from jsonb_object_keys(e))<>6 or
      not(e ?& array['event_id','child_id','family_id','kind','started_at','ended_at']) then raise exception 'INVALID_CONFIGURATION_EVENT'; end if;
    foreach field in array array['event_id','child_id','family_id','kind','started_at','ended_at'] loop
      if jsonb_typeof(e->field) is distinct from 'string' then raise exception 'INVALID_CONFIGURATION_EVENT'; end if;
    end loop;
    if e->>'kind' not in ('task','rules') or
      e->>'event_id' !~ '^[0-9a-f-]{36}$' or e->>'child_id' !~ '^[0-9a-f-]{36}$' or e->>'family_id' !~ '^[0-9a-f-]{36}$' or
      e->>'started_at' !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$' or
      e->>'ended_at' !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$' then raise exception 'INVALID_CONFIGURATION_EVENT'; end if;
    identifier:=(e->>'event_id')::uuid;child:=(e->>'child_id')::uuid;family:=(e->>'family_id')::uuid;
    first_at:=(e->>'started_at')::timestamptz;last_at:=(e->>'ended_at')::timestamptz;
    if last_at<=first_at or last_at-first_at>interval '30 seconds' then raise exception 'INVALID_CONFIGURATION_DURATION'; end if;
  end loop;
  if (select count(distinct item->>'event_id') from jsonb_array_elements(events) item)<>jsonb_array_length(events) then raise exception 'DUPLICATE_CONFIGURATION_EVENT'; end if;
  perform pg_advisory_xact_lock(hashtextextended('configuration:'||actor::text,0));
  select count(*) into used from public.parent_configuration_intervals where owner_id=actor and received_at>=observed-interval '24 hours';
  for e in select value from jsonb_array_elements(events) loop
    identifier:=(e->>'event_id')::uuid;child:=(e->>'child_id')::uuid;family:=(e->>'family_id')::uuid;
    first_at:=(e->>'started_at')::timestamptz;last_at:=(e->>'ended_at')::timestamptz;
    ids:=ids||jsonb_build_array(identifier);
    -- Revoked/deleted scopes are acknowledged and discarded, so one stale child
    -- cannot hold other children's pending intervals indefinitely.
    perform 1 from public.children c where c.id=child and c.family_id=family for share;
    if not found or not public.child_is_visible(child) or exists(select 1 from public.child_deletion_tombstones where child_id=child) then continue; end if;
    perform 1 from public.family_members where family_id=family and user_id=actor for share;
    if not found then continue; end if;
    digest:=encode(sha256(convert_to(e::text,'UTF8')),'hex');
    select payload_hash into previous from public.parent_configuration_intervals where owner_id=actor and event_id=identifier;
    if found then
      if previous<>digest then raise exception 'CONFIGURATION_RECEIPT_MISMATCH'; end if;
      accepted:=accepted+1;continue;
    end if;
    if last_at>observed or first_at<observed-interval '168 hours' then continue; end if;
    if used>=10000 then raise exception 'CONFIGURATION_RATE_LIMIT'; end if;
    insert into public.parent_configuration_intervals(owner_id,event_id,child_id,family_id,kind,started_at,ended_at,payload_hash)
      values(actor,identifier,child,family,e->>'kind',first_at,last_at,digest);
    used:=used+1;accepted:=accepted+1;
  end loop;
  return jsonb_build_object('event_ids',ids,'accepted',accepted,'server_time',observed);
end $$;
revoke all on function public.record_parent_configuration(jsonb) from public,anon,authenticated,service_role;
grant execute on function public.record_parent_configuration(jsonb) to authenticated;

-- Account and child privacy barriers erase measurements at acceptance, before
-- asynchronous object-storage/Auth deletion finishes.
create function public.erase_configuration_intervals() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_table_name='family_members' then
    delete from public.parent_configuration_intervals where owner_id=old.user_id and family_id=old.family_id;
    return old;
  elsif tg_table_name='account_deletion_jobs' then
    delete from public.parent_configuration_intervals where owner_id=new.user_id;
  else
    delete from public.parent_configuration_intervals where child_id=new.child_id;
  end if;
  return new;
end $$;
create trigger erase_configuration_account after insert on public.account_deletion_jobs
  for each row execute function public.erase_configuration_intervals();
create trigger erase_configuration_child after insert on public.child_deletion_tombstones
  for each row execute function public.erase_configuration_intervals();
create trigger erase_configuration_member after delete on public.family_members
  for each row execute function public.erase_configuration_intervals();
revoke all on function public.erase_configuration_intervals() from public,anon,authenticated,service_role;

create function public.purge_configuration_intervals() returns void
language sql security definer set search_path='' as $$
  delete from public.parent_configuration_intervals where ended_at<now()-interval '90 days';
$$;
revoke all on function public.purge_configuration_intervals() from public,anon,authenticated,service_role;
grant execute on function public.purge_configuration_intervals() to service_role;

alter function public.learning_report(uuid,text,date) rename to learning_report_before_configuration_time;
create function public.learning_report(target_child_id uuid,report_period text default 'week',anchor_date date default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare report jsonb; family uuid; lower_at timestamptz; upper_at timestamptz; retained timestamptz:=now()-interval '90 days';
  milliseconds bigint; samples bigint; parents bigint;
begin
  report:=public.learning_report_before_configuration_time(target_child_id,report_period,anchor_date);
  select family_id into family from public.children where id=target_child_id;
  lower_at:=(report->>'start_date')::date::timestamp at time zone (report->>'timezone');
  upper_at:=((report->>'end_date')::date+1)::timestamp at time zone (report->>'timezone');
  with clipped as (
    select owner_id,tstzrange(greatest(started_at,lower_at,retained),least(ended_at,upper_at),'[)') duration
    from public.parent_configuration_intervals
    where family_id=family and public.child_is_visible(child_id)
      and greatest(lower_at,retained)<upper_at
      and ended_at>greatest(lower_at,retained) and started_at<upper_at
  ), by_parent as (
    select owner_id,range_agg(duration) durations from clipped group by owner_id
  ), merged as (
    select unnest(durations) duration from by_parent
  ) select coalesce(floor(sum(extract(epoch from (upper(duration)-lower(duration)))*1000)),0),
      (select count(*) from clipped),(select count(*) from by_parent)
    into milliseconds,samples,parents from merged;
  return report||jsonb_build_object('configuration_time',jsonb_build_object('version','configuration-v1',
    'family_id',family,'milliseconds',milliseconds,'samples',samples,'parents',parents,
    'retained_from',retained,'partial_window',lower_at<retained));
end $$;
revoke all on function public.learning_report_before_configuration_time(uuid,text,date),public.learning_report(uuid,text,date) from public,anon,authenticated,service_role;
grant execute on function public.learning_report(uuid,text,date) to authenticated;

alter function public.child_export_source(uuid) rename to child_export_source_before_configuration_time;
create function public.child_export_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select public.child_export_source_before_configuration_time(target_child_id)||jsonb_build_array(jsonb_build_object(
    'name','parent_configuration_time','columns',jsonb_build_array('event_id','child_id','family_id','kind','started_at','ended_at','received_at'),
    'rows',coalesce((select jsonb_agg(to_jsonb(r)-'owner_id'-'payload_hash' order by started_at,event_id)
      from public.parent_configuration_intervals r where child_id=target_child_id and owner_id=auth.uid() and ended_at>=now()-interval '90 days'),'[]')));
$$;
revoke all on function public.child_export_source(uuid),public.child_export_source_before_configuration_time(uuid) from public,anon,authenticated,service_role;
