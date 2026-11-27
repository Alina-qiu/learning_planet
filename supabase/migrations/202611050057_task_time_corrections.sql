-- Parent time corrections are online, versioned and separate from completion.
create table public.task_time_correction_receipts (
  owner_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  task_id uuid not null references public.task_instances(id) on delete cascade,
  payload_hash text not null,
  applied_version bigint not null,
  primary key(owner_id,request_id)
);
alter table public.task_time_correction_receipts enable row level security;
revoke all on public.task_time_correction_receipts from public,anon,authenticated,service_role;

create function public.task_time_context(target_task_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t public.task_instances; family uuid;
begin
  select * into t from public.task_instances where id=target_task_id;
  select family_id into family from public.children where id=t.child_id;
  if not coalesce(public.child_is_visible(t.child_id),false) then
    raise exception 'Task access required' using errcode='42501'; end if;
  perform public.require_parent_authorization(family);
  return jsonb_build_object('owner_id',auth.uid(),'task_id',t.id,'child_id',t.child_id,'family_id',family,
    'title',t.title,'status',t.status,'seconds',t.accumulated_seconds,'version',t.sync_version,
    'running',t.status='in_progress' or t.active_started_at is not null);
end $$;

create function public.correct_task_time(target_task_id uuid,request_id uuid,
  expected_version bigint,corrected_seconds integer,reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t public.task_instances; family uuid; fingerprint text; receipt public.task_time_correction_receipts;
  applied bigint; before_seconds integer;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  if not public.account_is_active(auth.uid()) then raise exception 'Account unavailable' using errcode='42501'; end if;
  if request_id is null or expected_version is null or expected_version<0 or corrected_seconds is null or corrected_seconds<0
    or nullif(btrim(reason),'') is null or reason !~ '[^[:space:]]' or char_length(reason)>500 then
    raise exception 'Invalid time correction' using errcode='22023'; end if;
  fingerprint:=encode(sha256(convert_to(jsonb_build_object('version',expected_version,'seconds',corrected_seconds,'reason',reason)::text,'UTF8')),'hex');
  select c.family_id into family from public.children c join public.task_instances i on i.child_id=c.id where i.id=target_task_id;
  perform 1 from public.families where id=family for key share;
  perform pg_advisory_xact_lock(hashtextextended('task-time:'||auth.uid()::text||':'||request_id::text,0));
  select * into t from public.task_instances where id=target_task_id for update;
  if not found or not coalesce(public.child_is_visible(t.child_id),false) then
    raise exception 'Task access required' using errcode='42501'; end if;
  perform public.require_parent_authorization(family);
  -- Recheck actual expiry after waiting for task/request locks, and serialize
  -- with explicit PIN revocation until this short transaction completes.
  perform 1 from public.parent_authorizations a where a.family_id=family and a.user_id=auth.uid()
    and a.session_id=auth.jwt()->>'session_id' and a.expires_at>clock_timestamp() for key share;
  if not found then raise exception 'Parent authorization expired' using errcode='42501'; end if;
  select * into receipt from public.task_time_correction_receipts r
    where r.owner_id=auth.uid() and r.request_id=correct_task_time.request_id;
  if found then
    if receipt.task_id<>target_task_id or receipt.payload_hash<>fingerprint then
      raise exception 'Correction request changed' using errcode='22023'; end if;
    applied:=receipt.applied_version;
  else
    if t.sync_version<>expected_version then raise exception 'Task changed; refresh before correcting' using errcode='40001'; end if;
    if t.status='in_progress' or t.active_started_at is not null then
      raise exception 'Pause and synchronize the task before correcting time' using errcode='22023'; end if;
    if t.accumulated_seconds=corrected_seconds then raise exception 'Time is unchanged' using errcode='22023'; end if;
    before_seconds:=t.accumulated_seconds;
    update public.task_instances set accumulated_seconds=corrected_seconds where id=t.id returning sync_version into applied;
    insert into public.task_time_correction_receipts values(auth.uid(),request_id,t.id,fingerprint,applied);
    insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
      values(family,auth.uid(),'task.time_corrected','task_instance',t.id::text,
        jsonb_build_object('reason',btrim(reason),'before_seconds',before_seconds,'after_seconds',corrected_seconds,
          'before_version',t.sync_version,'after_version',applied,'status',t.status));
  end if;
  -- Replay reports the original receipt and the latest task, never rewrites it.
  return jsonb_build_object('request_id',request_id,'applied_version',applied,'current',public.task_time_context(t.id));
end $$;
revoke all on function public.task_time_context(uuid),public.correct_task_time(uuid,uuid,bigint,integer,text) from public,anon,service_role;
grant execute on function public.task_time_context(uuid),public.correct_task_time(uuid,uuid,bigint,integer,text) to authenticated;
