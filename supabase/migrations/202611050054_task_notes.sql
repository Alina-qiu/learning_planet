-- Notes are family content; editing them never changes task/reward versions.
create table public.task_notes (
  task_id uuid primary key references public.task_instances(id) on delete cascade,
  body text not null check(char_length(body)<=500),
  version bigint not null check(version>0),
  updated_at timestamptz not null,
  updated_by uuid references auth.users(id) on delete set null
);
alter table public.task_notes enable row level security;
revoke all on public.task_notes from public,anon,authenticated,service_role;
grant select on public.task_notes to authenticated;
create policy task_notes_visible on public.task_notes for select to authenticated using (
  exists(select 1 from public.task_instances t where t.id=task_id and public.child_is_visible(t.child_id))
);
create table public.task_note_receipts (
  owner_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  task_id uuid not null references public.task_instances(id) on delete cascade,
  payload_hash text not null,
  status text not null check(status in ('applied','abandoned')),
  applied_version bigint,
  primary key(owner_id,request_id)
);
alter table public.task_note_receipts enable row level security;
revoke all on public.task_note_receipts from public,anon,authenticated,service_role;

create function public.task_note(target_task_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare child uuid; family uuid; result jsonb;
begin
  select t.child_id,c.family_id into child,family from public.task_instances t
    join public.children c on c.id=t.child_id where t.id=target_task_id;
  if not coalesce(public.child_is_visible(child),false) then
    raise exception 'Task access required' using errcode='42501'; end if;
  select jsonb_build_object('body',n.body,'version',n.version,'updated_at',n.updated_at)
    into result from public.task_notes n where n.task_id=target_task_id;
  return jsonb_build_object('task_id',target_task_id,'child_id',child,'family_id',family)||
    coalesce(result,jsonb_build_object('body','','version',0,'updated_at',null));
end $$;

create function public.resolve_task_note(target_task_id uuid,request_id uuid,note_text text,
  operation text default 'submit') returns jsonb
language plpgsql security definer set search_path='' as $$
declare child uuid; family uuid; fingerprint text; receipt public.task_note_receipts;
  result_status text; applied bigint;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  if not public.account_is_active(auth.uid()) then raise exception 'Account unavailable' using errcode='42501'; end if;
  if request_id is null or note_text is null or char_length(note_text)>500
    or operation is null or operation not in ('submit','inspect','cancel') then
    raise exception 'Invalid note request' using errcode='22023'; end if;
  fingerprint:=encode(sha256(convert_to(note_text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('task-note:'||auth.uid()::text||':'||request_id::text,0));
  select t.child_id,c.family_id into child,family from public.task_instances t
    join public.children c on c.id=t.child_id where t.id=target_task_id;
  perform 1 from public.families where id=family for key share;
  perform 1 from public.children where id=child for key share;
  perform 1 from public.task_instances where id=target_task_id for key share;
  if not coalesce(public.child_is_visible(child),false) or not found then
    raise exception 'Task access required' using errcode='42501'; end if;
  select * into receipt from public.task_note_receipts r
    where r.owner_id=auth.uid() and r.request_id=resolve_task_note.request_id;
  if found then
    if receipt.task_id<>target_task_id or receipt.payload_hash<>fingerprint then
      raise exception 'Request content changed' using errcode='22023'; end if;
    result_status:=receipt.status; applied:=receipt.applied_version;
  elsif operation='inspect' then
    result_status:='unknown';
  else
    result_status:='abandoned';
    if operation='submit' then
      insert into public.task_notes as n values(target_task_id,note_text,1,clock_timestamp(),auth.uid())
        on conflict(task_id) do update set body=excluded.body,version=n.version+1,
          updated_at=clock_timestamp(),updated_by=excluded.updated_by returning version into applied;
      result_status:='applied';
      insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
        values(family,auth.uid(),'task.note_saved','task',target_task_id,
          jsonb_build_object('version',applied,'characters',char_length(note_text)));
    end if;
    insert into public.task_note_receipts values(auth.uid(),request_id,target_task_id,fingerprint,result_status,applied);
  end if;
  -- A receipt describes the original request; current may be newer than it.
  return jsonb_build_object('owner_id',auth.uid(),'request_id',request_id,
    'status',result_status,'applied_version',applied,'current',public.task_note(target_task_id));
end $$;
revoke all on function public.task_note(uuid),public.resolve_task_note(uuid,uuid,text,text) from public,anon,service_role;
grant execute on function public.task_note(uuid),public.resolve_task_note(uuid,uuid,text,text) to authenticated;

alter function public.child_export_source(uuid) rename to child_export_source_before_task_notes;
create function public.child_export_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select public.child_export_source_before_task_notes(target_child_id)||jsonb_build_array(jsonb_build_object(
    'name','task_notes','columns',jsonb_build_array('task_id','body','version','updated_at','updated_by'),
    'rows',coalesce((select jsonb_agg(to_jsonb(n) order by n.task_id)
      from public.task_notes n join public.task_instances t on t.id=n.task_id where t.child_id=target_child_id),'[]')));
$$;
revoke all on function public.child_export_source(uuid),public.child_export_source_before_task_notes(uuid) from public,anon,authenticated,service_role;
