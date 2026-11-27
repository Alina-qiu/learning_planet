-- APNs device tokens contain a variable number of bytes, encoded by iOS as lowercase hex.
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
    (requested_transport='apns' and (length(push_token)%2<>0 or push_token !~ '^[0-9a-f]+$')) then raise exception 'INVALID_PUSH_TOKEN'; end if;
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
    (device.transport='apns' and (length(push_token)%2<>0 or push_token !~ '^[0-9a-f]+$')) then raise exception 'INVALID_PUSH_TOKEN'; end if;
  update public.parent_push_devices set registration_token=push_token,registration_hash=encode(sha256(convert_to(push_token,'UTF8')),'hex'),
    expires_at=now()+interval '30 days',updated_at=now() where device_id=target_device_id;
  return public.parent_push_device_view(target_device_id);
end $$;
