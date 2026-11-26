-- Retire unsupported registrations in place. Keeping the device capability and
-- disabled intent fences activation requests still in flight from an older app.
alter table public.parent_push_devices
  drop constraint parent_push_devices_transport_check,
  add constraint parent_push_devices_transport_check
    check (transport in ('apns','gateway')) not valid;

-- A job belongs to a parent's inbox. Return unfinished delivery to the queue
-- so a supported device can receive it, and fence the old worker's lease.
update public.parent_push_jobs j
set state='queued',result_code=null,attempts=greatest(0,j.attempts-1),next_attempt_at=now()
from public.parent_push_devices d
where j.device_id=d.device_id and j.state='running'
  and d.transport not in ('apns','gateway');

update public.parent_push_jobs j
set device_id=null,device_version=null,device_token_hash=null,lease_token=null,lease_until=null
from public.parent_push_devices d
where j.device_id=d.device_id and d.transport not in ('apns','gateway');

update public.parent_push_devices
set state='disabled',transport=null,registration_token=null,registration_hash=null,
    prepared_until=null,expires_at=null,updated_at=now()
where transport not in ('apns','gateway');

alter table public.parent_push_devices validate constraint parent_push_devices_transport_check;

-- Replace the installed RPC bodies as well as the table constraint. Existing
-- execute grants are preserved by CREATE OR REPLACE.
create or replace function public.activate_parent_push_device(target_device_id uuid,device_secret text,requested_version bigint,
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
  if requested_transport is null or requested_transport not in ('apns','gateway') or push_token is null or
    length(push_token) not between 1 and 4096 or push_token !~ '^[!-~]+$' or
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

create or replace function public.renew_parent_push_device(target_device_id uuid,device_secret text,requested_version bigint,push_token text) returns jsonb
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
    (device.transport='apns' and push_token !~ '^[0-9a-f]{64}$') then raise exception 'INVALID_PUSH_TOKEN'; end if;
  update public.parent_push_devices set registration_token=push_token,registration_hash=encode(sha256(convert_to(push_token,'UTF8')),'hex'),
    expires_at=now()+interval '30 days',updated_at=now() where device_id=target_device_id;
  return public.parent_push_device_view(target_device_id);
end $$;

create or replace function public.claim_parent_push_jobs(max_jobs integer,transports jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job record; claims jsonb:='[]'; token uuid;
begin
  if max_jobs is null or max_jobs not between 1 and 20 or jsonb_typeof(transports) is distinct from 'array'
    or jsonb_array_length(transports) not between 1 and 2 or exists(select 1 from jsonb_array_elements(transports) t
      where jsonb_typeof(t)<>'string' or t#>>'{}' not in ('apns','gateway')) then raise exception 'INVALID_PUSH_CLAIM'; end if;
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
