-- Transport-neutral parent push registry. Tokens/secrets never enter child exports.
create function public.family_member_is_active(target_family_id uuid,target_user_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select public.account_is_active(target_user_id)
    and exists(select 1 from public.family_members where family_id=target_family_id and user_id=target_user_id)
    and not exists(select 1 from public.account_deletion_jobs where target_family_id=any(owned_family_ids));
$$;
revoke all on function public.family_member_is_active(uuid,uuid) from public,anon,authenticated,service_role;
create or replace function public.is_family_member(target_family_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select public.family_member_is_active(target_family_id,auth.uid());
$$;

-- Foreground and scheduled delivery share one authoritative event definition.
create function public.parent_notification_events_for_user(target_family_id uuid,target_user_id uuid,as_of timestamptz)
returns table(notification_key text,child_id uuid,kind text,created_at timestamptz,anchor_date date)
language sql stable security definer set search_path='' as $$
  with family_time as (
    select timezone,(as_of at time zone timezone)::date as today,
      date_trunc('week',as_of at time zone timezone)::date as monday
    from public.families where id=target_family_id and public.family_member_is_active(id,target_user_id)
  )
  select 'redemption:'||d.id::text,d.child_id,'redemption',d.created_at,null::date
    from public.redemptions d join public.children c on c.id=d.child_id cross join family_time
    where c.family_id=target_family_id and d.status='requested' and d.expires_at>as_of
      and not exists(select 1 from public.child_deletion_tombstones t where t.child_id=c.id)
  union all
  select 'weekly:'||c.id::text||':'||(f.monday-1)::text,c.id,'weekly',
    (f.monday+time '09:00') at time zone f.timezone,f.monday-1
    from public.children c cross join family_time f where c.family_id=target_family_id
      and not exists(select 1 from public.child_deletion_tombstones t where t.child_id=c.id)
      and c.created_at<(f.monday::timestamp at time zone f.timezone)
      and as_of>=(f.monday+time '09:00') at time zone f.timezone;
$$;
revoke all on function public.parent_notification_events_for_user(uuid,uuid,timestamptz) from public,anon,authenticated,service_role;
create or replace function public.parent_notification_events(target_family_id uuid,as_of timestamptz default now())
returns table(notification_key text,child_id uuid,kind text,created_at timestamptz,anchor_date date)
language sql stable security definer set search_path='' as $$
  select * from public.parent_notification_events_for_user(target_family_id,auth.uid(),as_of);
$$;

create table public.parent_push_devices (
  device_id uuid primary key,
  family_id uuid not null,
  owner_id uuid not null,
  secret_hash text not null,
  intent_version bigint not null check(intent_version between 1 and 9007199254740991),
  scope_nonce uuid not null,
  state text not null check(state in ('prepared','enabled','disabled')),
  transport text check(transport in ('hms','apns','gateway')),
  registration_token text,
  registration_hash text,
  prepared_until timestamptz,
  expires_at timestamptz,
  updated_at timestamptz not null default now(),
  foreign key(family_id,owner_id) references public.family_members(family_id,user_id) on delete cascade,
  check(state<>'enabled' or (transport is not null and registration_token is not null and registration_hash is not null and expires_at is not null))
);
create unique index parent_push_token_unique on public.parent_push_devices(transport,registration_hash)
  where registration_hash is not null;
create index parent_push_device_owner on public.parent_push_devices(owner_id,family_id,updated_at);
alter table public.parent_push_devices enable row level security;
revoke all on public.parent_push_devices from public,anon,authenticated,service_role;

create function public.parent_push_device_view(target_device_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('device_id',d.device_id,'family_id',d.family_id,'intent_version',d.intent_version,
    'scope_nonce',d.scope_nonce,'state',d.state,'transport',d.transport,'expires_at',d.expires_at,
    'server_time',now(),'timezone',f.timezone)
  from public.parent_push_devices d join public.families f on f.id=d.family_id where d.device_id=target_device_id;
$$;
revoke all on function public.parent_push_device_view(uuid) from public,anon,authenticated,service_role;

-- Preparation creates a disabled privacy barrier before an activation request can
-- ever be sent. Revocation can then overtake a delayed activation safely.
create function public.prepare_parent_push_device(target_family_id uuid,target_device_id uuid,device_secret text,
  requested_version bigint,requested_nonce uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); previous public.parent_push_devices; digest text;
begin
  perform 1 from auth.users where id=actor for share;
  perform public.require_parent_authorization(target_family_id);
  if target_device_id is null or requested_nonce is null or requested_version is null or requested_version not between 1 and 9007199254740991
    or device_secret is null or device_secret !~ '^[A-Za-z0-9_-]{43,128}$' then raise exception 'INVALID_PUSH_DEVICE'; end if;
  perform 1 from public.family_members where family_id=target_family_id and user_id=actor for share;
  if not found then raise exception 'PUSH_ACCESS_DENIED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('parent-push-owner:'||actor::text,0));
  perform pg_advisory_xact_lock(hashtextextended('parent-push-device:'||target_device_id::text,0));
  digest:=encode(sha256(convert_to(device_secret,'UTF8')),'hex');
  select * into previous from public.parent_push_devices where device_id=target_device_id for update;
  if found then
    if previous.secret_hash<>digest then raise exception 'PUSH_DEVICE_SECRET_MISMATCH' using errcode='42501'; end if;
    if requested_version<previous.intent_version then raise exception 'STALE_PUSH_DEVICE_INTENT'; end if;
    if requested_version=previous.intent_version then
      if previous.owner_id<>actor or previous.family_id<>target_family_id or previous.scope_nonce<>requested_nonce then
        raise exception 'PUSH_DEVICE_INTENT_MISMATCH'; end if;
      return public.parent_push_device_view(target_device_id);
    end if;
    if previous.owner_id<>actor and (select count(*) from public.parent_push_devices where owner_id=actor)>=100 then
      raise exception 'PUSH_DEVICE_LIMIT'; end if;
    update public.parent_push_devices set family_id=target_family_id,owner_id=actor,intent_version=requested_version,
      scope_nonce=requested_nonce,state='prepared',transport=null,registration_token=null,registration_hash=null,
      prepared_until=now()+interval '5 minutes',expires_at=null,updated_at=now() where device_id=target_device_id;
  else
    if (select count(*) from public.parent_push_devices where owner_id=actor)>=100 then raise exception 'PUSH_DEVICE_LIMIT'; end if;
    insert into public.parent_push_devices(device_id,family_id,owner_id,secret_hash,intent_version,scope_nonce,state,prepared_until)
      values(target_device_id,target_family_id,actor,digest,requested_version,requested_nonce,'prepared',now()+interval '5 minutes');
  end if;
  return public.parent_push_device_view(target_device_id);
end $$;
revoke all on function public.prepare_parent_push_device(uuid,uuid,text,bigint,uuid) from public,anon,authenticated,service_role;
grant execute on function public.prepare_parent_push_device(uuid,uuid,text,bigint,uuid) to authenticated;

create function public.activate_parent_push_device(target_device_id uuid,device_secret text,requested_version bigint,
  requested_transport text,push_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare device public.parent_push_devices; token_hash text;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  perform pg_advisory_xact_lock(hashtextextended('parent-push-device:'||target_device_id::text,0));
  select * into device from public.parent_push_devices where device_id=target_device_id for update;
  if not found or device.owner_id<>auth.uid() or not public.family_member_is_active(device.family_id,auth.uid()) or
    device_secret is null or device.secret_hash<>encode(sha256(convert_to(device_secret,'UTF8')),'hex') then
    raise exception 'PUSH_ACCESS_DENIED' using errcode='42501'; end if;
  perform public.require_parent_authorization(device.family_id);
  if requested_version is distinct from device.intent_version or device.state='disabled' then raise exception 'STALE_PUSH_DEVICE_INTENT'; end if;
  if requested_transport is null or requested_transport not in ('hms','apns','gateway') or push_token is null or
    length(push_token) not between 1 and 4096 or push_token !~ '^[!-~]+$' or
    (requested_transport='hms' and length(push_token)<20) or
    (requested_transport='apns' and push_token !~ '^[0-9a-f]{64}$') then raise exception 'INVALID_PUSH_TOKEN'; end if;
  token_hash:=encode(sha256(convert_to(push_token,'UTF8')),'hex');
  if device.state='enabled' then
    if device.transport<>requested_transport or device.registration_hash<>token_hash then raise exception 'PUSH_DEVICE_INTENT_MISMATCH'; end if;
  else
    if device.prepared_until<now() then raise exception 'PUSH_PREPARATION_EXPIRED'; end if;
    update public.parent_push_devices set state='enabled',transport=requested_transport,registration_token=push_token,
      registration_hash=token_hash,expires_at=now()+interval '30 days',updated_at=now() where device_id=target_device_id;
  end if;
  return public.parent_push_device_view(target_device_id);
end $$;
revoke all on function public.activate_parent_push_device(uuid,text,bigint,text,text) from public,anon,authenticated,service_role;
grant execute on function public.activate_parent_push_device(uuid,text,bigint,text,text) to authenticated;

-- Revocation is a capability restricted to turning off one installation, allowing
-- an offline logout to finish it later without retaining an account JWT.
create function public.revoke_parent_push_device(target_device_id uuid,device_secret text,requested_version bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  if target_device_id is null or requested_version is null or requested_version not between 1 and 9007199254740991 or
    device_secret is null or device_secret !~ '^[A-Za-z0-9_-]{43,128}$' then raise exception 'INVALID_PUSH_DEVICE'; end if;
  perform pg_advisory_xact_lock(hashtextextended('parent-push-device:'||target_device_id::text,0));
  update public.parent_push_devices set state='disabled',intent_version=requested_version,
    transport=null,registration_token=null,registration_hash=null,expires_at=null,prepared_until=null,updated_at=now()
    where device_id=target_device_id and secret_hash=encode(sha256(convert_to(device_secret,'UTF8')),'hex')
      and intent_version<=requested_version;
  -- Do not expose whether a device exists or a supplied capability matched.
  return jsonb_build_object('device_id',target_device_id,'intent_version',requested_version,'revoked',true);
end $$;
revoke all on function public.revoke_parent_push_device(uuid,text,bigint) from public,anon,authenticated,service_role;
grant execute on function public.revoke_parent_push_device(uuid,text,bigint) to anon,authenticated;

create function public.renew_parent_push_device(target_device_id uuid,device_secret text,requested_version bigint,push_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare device public.parent_push_devices;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  perform pg_advisory_xact_lock(hashtextextended('parent-push-device:'||target_device_id::text,0));
  select * into device from public.parent_push_devices where device_id=target_device_id for update;
  if not found or device.owner_id<>auth.uid() or not public.family_member_is_active(device.family_id,auth.uid()) or
    device_secret is null or device.secret_hash<>encode(sha256(convert_to(device_secret,'UTF8')),'hex') then
    raise exception 'PUSH_ACCESS_DENIED' using errcode='42501'; end if;
  if requested_version is distinct from device.intent_version or device.state<>'enabled' or device.expires_at<now() then
    raise exception 'STALE_PUSH_DEVICE_INTENT'; end if;
  if push_token is null or length(push_token) not between 1 and 4096 or push_token !~ '^[!-~]+$' or
    (device.transport='hms' and length(push_token)<20) or
    (device.transport='apns' and push_token !~ '^[0-9a-f]{64}$') then raise exception 'INVALID_PUSH_TOKEN'; end if;
  update public.parent_push_devices set registration_token=push_token,registration_hash=encode(sha256(convert_to(push_token,'UTF8')),'hex'),
    expires_at=now()+interval '30 days',updated_at=now() where device_id=target_device_id;
  return public.parent_push_device_view(target_device_id);
end $$;
revoke all on function public.renew_parent_push_device(uuid,text,bigint,text) from public,anon,authenticated,service_role;
grant execute on function public.renew_parent_push_device(uuid,text,bigint,text) to authenticated;

create table public.parent_push_jobs (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null,
  owner_id uuid not null,
  child_id uuid not null references public.children(id) on delete cascade,
  notification_key text not null,
  kind text not null check(kind in ('redemption','weekly')),
  state text not null default 'queued' check(state in ('queued','running','sent','cancelled')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  expires_at timestamptz not null,
  device_id uuid references public.parent_push_devices(device_id) on delete set null,
  device_version bigint,
  device_token_hash text,
  lease_token uuid,
  lease_until timestamptz,
  result_code text check(result_code in ('accepted','retry','rejected','invalid_token','expired','superseded')),
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  foreign key(family_id,owner_id) references public.family_members(family_id,user_id) on delete cascade,
  unique(family_id,owner_id,notification_key)
);
create index parent_push_jobs_pending on public.parent_push_jobs(next_attempt_at,created_at) where state in ('queued','running');
alter table public.parent_push_jobs enable row level security;
revoke all on public.parent_push_jobs from public,anon,authenticated,service_role;

create function public.parent_push_is_allowed(target_family_id uuid,target_user_id uuid,message_kind text,as_of timestamptz) returns boolean
language sql stable security definer set search_path='' as $$
  select coalesce((select public.family_member_is_active(s.family_id,s.user_id) and s.enabled
    and ((message_kind='redemption' and s.redemptions) or (message_kind='weekly' and s.weekly_reports))
    and not case when s.quiet_start=s.quiet_end then false
      when s.quiet_start<s.quiet_end then (as_of at time zone f.timezone)::time>=s.quiet_start and (as_of at time zone f.timezone)::time<s.quiet_end
      else (as_of at time zone f.timezone)::time>=s.quiet_start or (as_of at time zone f.timezone)::time<s.quiet_end end
    from public.parent_notification_settings s join public.families f on f.id=s.family_id
    where s.family_id=target_family_id and s.user_id=target_user_id),false);
$$;
revoke all on function public.parent_push_is_allowed(uuid,uuid,text,timestamptz) from public,anon,authenticated,service_role;

create function public.enqueue_parent_push_jobs() returns integer
language plpgsql security definer set search_path='' as $$
declare added integer; candidates jsonb;
begin
  with scopes as (select distinct family_id,owner_id from public.parent_push_devices where state='enabled' and expires_at>now()),
  pending as (
    select s.family_id,s.owner_id,n.*,case when n.kind='redemption' then d.expires_at
      else (n.anchor_date+8+time '09:00') at time zone f.timezone end as until_at
    from scopes s join public.families f on f.id=s.family_id
    cross join lateral public.parent_notification_events_for_user(s.family_id,s.owner_id,now()) n
    left join public.redemptions d on n.kind='redemption' and n.notification_key='redemption:'||d.id::text
    where public.parent_push_is_allowed(s.family_id,s.owner_id,n.kind,now())
      and not exists(select 1 from public.parent_notification_receipts r where r.family_id=s.family_id and r.user_id=s.owner_id
        and r.notification_key=n.notification_key and (r.read_at is not null or r.delivered_at is not null))
      and not exists(select 1 from public.parent_push_jobs j where j.family_id=s.family_id and j.owner_id=s.owner_id and j.notification_key=n.notification_key)
    order by n.created_at,n.notification_key limit 200
  ) select coalesce(jsonb_agg(to_jsonb(pending)),'[]') into candidates from pending;
  -- Acquire all membership locks before any child locks, including when several
  -- parents share a child. This matches foreground receipts and deletion order.
  perform 1 from auth.users where id in (select (value->>'owner_id')::uuid from jsonb_array_elements(candidates)) order by id for share;
  perform 1 from public.family_members m where exists(select 1 from jsonb_array_elements(candidates) c
    where (c->>'owner_id')::uuid=m.user_id and (c->>'family_id')::uuid=m.family_id) order by m.family_id,m.user_id for share;
  perform pg_advisory_xact_lock(hashtextextended('cleanup:'||id::text,0)) from public.children
    where id in (select (value->>'child_id')::uuid from jsonb_array_elements(candidates)) order by id;
  perform 1 from public.children where id in (select (value->>'child_id')::uuid from jsonb_array_elements(candidates)) order by id for share;
  -- Derive permissions/source again after waiting for deletion or read receipts.
  insert into public.parent_push_jobs(family_id,owner_id,child_id,notification_key,kind,expires_at)
    select c.family_id,c.owner_id,c.child_id,c.notification_key,c.kind,c.until_at
    from jsonb_to_recordset(candidates) as c(family_id uuid,owner_id uuid,child_id uuid,notification_key text,kind text,until_at timestamptz)
    where public.parent_push_is_allowed(c.family_id,c.owner_id,c.kind,now())
      and exists(select 1 from public.parent_notification_events_for_user(c.family_id,c.owner_id,now()) n where n.notification_key=c.notification_key)
      and exists(select 1 from public.parent_push_devices d where d.family_id=c.family_id and d.owner_id=c.owner_id and d.state='enabled' and d.expires_at>now())
      and not exists(select 1 from public.parent_notification_receipts r where r.family_id=c.family_id and r.user_id=c.owner_id
        and r.notification_key=c.notification_key and (r.read_at is not null or r.delivered_at is not null))
    on conflict do nothing;
  get diagnostics added=row_count;
  return added;
end $$;
revoke all on function public.enqueue_parent_push_jobs() from public,anon,authenticated,service_role;
grant execute on function public.enqueue_parent_push_jobs() to service_role;

create function public.claim_parent_push_jobs(max_jobs integer,transports jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job record; claims jsonb:='[]'; token uuid;
begin
  if max_jobs is null or max_jobs not between 1 and 20 or jsonb_typeof(transports) is distinct from 'array'
    or jsonb_array_length(transports) not between 1 and 3 or exists(select 1 from jsonb_array_elements(transports) t
      where jsonb_typeof(t)<>'string' or t#>>'{}' not in ('hms','apns','gateway')) then raise exception 'INVALID_PUSH_CLAIM'; end if;
  update public.parent_push_jobs set state='cancelled',result_code='expired',finished_at=now(),lease_until=null
    where state in ('queued','running') and (expires_at<=now() or attempts>=5 and (state='queued' or lease_until<=now()));
  for job in
    select j.id,d.device_id,d.intent_version,d.registration_hash from public.parent_push_jobs j
    cross join lateral (select device_id,intent_version,registration_hash from public.parent_push_devices
      where owner_id=j.owner_id and family_id=j.family_id and state='enabled' and expires_at>now()
        and transports ? transport order by updated_at desc,device_id limit 1) d
    where (j.state='queued' and j.next_attempt_at<=now() or j.state='running' and j.lease_until<now())
      and j.expires_at>now() and j.attempts<5 and public.parent_push_is_allowed(j.family_id,j.owner_id,j.kind,now())
    order by j.created_at,j.id limit max_jobs for update of j skip locked
  loop
    token:=gen_random_uuid();
    update public.parent_push_jobs set state='running',attempts=attempts+1,device_id=job.device_id,
      device_version=job.intent_version,device_token_hash=job.registration_hash,lease_token=token,lease_until=clock_timestamp()+interval '2 minutes'
      where id=job.id;
    claims:=claims||jsonb_build_array(jsonb_build_object('job_id',job.id,'lease_token',token));
  end loop;
  return claims;
end $$;
revoke all on function public.claim_parent_push_jobs(integer,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.claim_parent_push_jobs(integer,jsonb) to service_role;

-- Revalidate immediately before a network call. Output is service-only and must
-- never be returned to the mobile client or written to logs.
create function public.authorize_parent_push_job(target_job_id uuid,token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.parent_push_jobs; device public.parent_push_devices; prefs public.parent_notification_settings;
  zone text; instant timestamptz:=clock_timestamp();
begin
  select * into job from public.parent_push_jobs where id=target_job_id for update;
  if not found or job.state<>'running' or job.lease_token is distinct from token or job.lease_until<=instant then return jsonb_build_object('status','stale'); end if;
  if job.expires_at<=instant or not exists(select 1 from public.parent_notification_events_for_user(job.family_id,job.owner_id,instant) n where n.notification_key=job.notification_key)
    or exists(select 1 from public.parent_notification_receipts r where r.family_id=job.family_id and r.user_id=job.owner_id
      and r.notification_key=job.notification_key and (r.read_at is not null or r.delivered_at is not null)) then
    update public.parent_push_jobs set state='cancelled',result_code='superseded',finished_at=instant,lease_until=null where id=job.id;
    return jsonb_build_object('status','cancelled');
  end if;
  select * into device from public.parent_push_devices where device_id=job.device_id;
  if not found or device.state<>'enabled' or device.owner_id<>job.owner_id or device.family_id<>job.family_id
    or device.intent_version<>job.device_version or device.registration_hash<>job.device_token_hash or device.expires_at<=instant
    or not public.parent_push_is_allowed(job.family_id,job.owner_id,job.kind,instant) then
    update public.parent_push_jobs set state='queued',next_attempt_at=instant+interval '1 minute',lease_token=null,lease_until=null,
      attempts=greatest(0,attempts-1) where id=job.id;
    return jsonb_build_object('status','deferred');
  end if;
  select * into prefs from public.parent_notification_settings where family_id=job.family_id and user_id=job.owner_id;
  select timezone into zone from public.families where id=job.family_id;
  return jsonb_build_object('status','authorized','transport',device.transport,'registration_token',device.registration_token,
    'data',jsonb_build_object('version','parent-push-v1','message_id',job.id::text,'scope_nonce',device.scope_nonce::text,
      'kind',job.kind,'issued_ms',floor(extract(epoch from instant)*1000)::bigint::text,
      'expires_ms',floor(extract(epoch from least(instant+interval '60 seconds',job.expires_at,device.expires_at))*1000)::bigint::text,
      'timezone',zone,'quiet_start',prefs.quiet_start::text,'quiet_end',prefs.quiet_end::text,'settings_version',prefs.version::text));
end $$;
revoke all on function public.authorize_parent_push_job(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.authorize_parent_push_job(uuid,uuid) to service_role;

create function public.finish_parent_push_job(target_job_id uuid,token uuid,outcome text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.parent_push_jobs; active boolean;
begin
  if outcome is null or outcome not in ('accepted','retry','rejected','invalid_token') then raise exception 'INVALID_PUSH_OUTCOME'; end if;
  select * into job from public.parent_push_jobs where id=target_job_id;
  if not found then return jsonb_build_object('status','stale'); end if;
  -- Same lock order as local delivery receipts / child deletion.
  perform 1 from auth.users where id=job.owner_id for share;
  perform 1 from public.family_members where family_id=job.family_id and user_id=job.owner_id for update;
  if not found then return jsonb_build_object('status','stale'); end if;
  perform pg_advisory_xact_lock(hashtextextended('cleanup:'||job.child_id::text,0));
  perform 1 from public.children where id=job.child_id for share;
  if not found then return jsonb_build_object('status','stale'); end if;
  select * into job from public.parent_push_jobs where id=target_job_id for update;
  if not found or job.lease_token is distinct from token then return jsonb_build_object('status','stale'); end if;
  if job.state='sent' then return jsonb_build_object('status','sent'); end if;
  if job.state<>'running' or job.lease_until<=clock_timestamp() then return jsonb_build_object('status','stale'); end if;
  if exists(select 1 from public.child_deletion_tombstones where child_id=job.child_id) then
    delete from public.parent_push_jobs where id=job.id;
    return jsonb_build_object('status','stale');
  end if;
  perform 1 from public.parent_push_devices where device_id=job.device_id for update;
  active:=public.family_member_is_active(job.family_id,job.owner_id) and exists(select 1 from public.parent_push_devices d
    where d.device_id=job.device_id and d.state='enabled' and d.intent_version=job.device_version and d.registration_hash=job.device_token_hash
      and d.owner_id=job.owner_id and d.family_id=job.family_id);
  if not active then
    update public.parent_push_jobs set state='queued',next_attempt_at=now()+interval '1 minute',lease_token=null,lease_until=null,
      attempts=greatest(0,attempts-1) where id=job.id;
    return jsonb_build_object('status','deferred');
  end if;
  if outcome='accepted' then
    update public.parent_push_jobs set state='sent',result_code=outcome,finished_at=now(),lease_until=null where id=job.id;
    -- This means provider acceptance, not proof of display or reading. The inbox
    -- remains available even if the platform ultimately drops a TTL-zero push.
    insert into public.parent_notification_receipts(family_id,user_id,child_id,notification_key,delivered_at)
      values(job.family_id,job.owner_id,job.child_id,job.notification_key,now())
      on conflict(family_id,user_id,notification_key) do update set
        delivered_at=coalesce(parent_notification_receipts.delivered_at,excluded.delivered_at),updated_at=now();
  elsif outcome='retry' and job.attempts<5 then
    update public.parent_push_jobs set state='queued',result_code=outcome,next_attempt_at=now()+make_interval(secs=>least(3600,60*power(2,job.attempts-1)::integer)),
      lease_token=null,lease_until=null where id=job.id;
  else
    update public.parent_push_jobs set state='cancelled',result_code=outcome,finished_at=now(),lease_until=null where id=job.id;
    if outcome='invalid_token' then
      update public.parent_push_devices set state='disabled',transport=null,registration_token=null,registration_hash=null,expires_at=null,updated_at=now()
        where device_id=job.device_id and intent_version=job.device_version and registration_hash=job.device_token_hash;
    end if;
  end if;
  return jsonb_build_object('status',case when outcome='accepted' then 'sent' when outcome='retry' and job.attempts<5 then 'queued' else 'cancelled' end);
end $$;
revoke all on function public.finish_parent_push_job(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.finish_parent_push_job(uuid,uuid,text) to service_role;

create function public.erase_account_parent_push() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  delete from public.parent_push_jobs where owner_id=new.user_id or family_id=any(new.owned_family_ids);
  delete from public.parent_push_devices where owner_id=new.user_id or family_id=any(new.owned_family_ids);
  return new;
end $$;
create trigger erase_account_parent_push after insert on public.account_deletion_jobs
  for each row execute function public.erase_account_parent_push();
revoke all on function public.erase_account_parent_push() from public,anon,authenticated,service_role;

create function public.erase_child_parent_push() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  delete from public.parent_push_jobs where child_id=new.child_id;
  return new;
end $$;
create trigger erase_child_parent_push after insert on public.child_deletion_tombstones
  for each row execute function public.erase_child_parent_push();
revoke all on function public.erase_child_parent_push() from public,anon,authenticated,service_role;

create function public.purge_parent_push() returns void
language plpgsql security definer set search_path='' as $$
begin
  delete from public.parent_push_jobs where expires_at<now()-interval '7 days';
  update public.parent_push_devices set state='disabled',transport=null,registration_token=null,registration_hash=null,expires_at=null
    where state='enabled' and expires_at<=now();
  delete from public.parent_push_devices where state<>'enabled' and updated_at<now()-interval '90 days';
end $$;
revoke all on function public.purge_parent_push() from public,anon,authenticated,service_role;
grant execute on function public.purge_parent_push() to service_role;
