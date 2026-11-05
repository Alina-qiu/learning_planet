-- Membership incarnations and revocation notices survive a family being removed.
-- Child UUIDs here describe lost access, NOT deletion of the shared child.
create table public.family_membership_states (
  user_id uuid not null references auth.users(id) on delete cascade,
  family_id uuid not null,
  version bigint not null default 1,
  active boolean not null default true,
  last_revoked_version bigint not null default 0,
  child_ids uuid[] not null default '{}',
  revoked_at timestamptz,
  primary key(user_id,family_id)
);
alter table public.family_membership_states enable row level security;
revoke all on public.family_membership_states from public,anon,authenticated,service_role;
insert into public.family_membership_states(user_id,family_id)
  select user_id,family_id from public.family_members;

create function public.record_family_membership() returns trigger
language plpgsql security definer set search_path='' as $$
declare children uuid[];
begin
  if tg_op='INSERT' then
    insert into public.family_membership_states(user_id,family_id) values(new.user_id,new.family_id)
      on conflict(user_id,family_id) do update set active=true,version=public.family_membership_states.version+1;
    return new;
  end if;
  -- A family-level BEFORE DELETE trigger preserves notices for removed members
  -- too. Auth cascades need no notice because that account can never log in again.
  if not exists(select 1 from public.families where id=old.family_id)
    or not exists(select 1 from auth.users where id=old.user_id) then return old; end if;
  children:=array(select id from public.children where family_id=old.family_id
    union select child_id from public.child_deletion_tombstones where family_id=old.family_id);
  insert into public.family_membership_states(user_id,family_id,version,active,last_revoked_version,child_ids,revoked_at)
    values(old.user_id,old.family_id,2,false,2,children,clock_timestamp())
    on conflict(user_id,family_id) do update set active=false,
      version=public.family_membership_states.version+1,
      last_revoked_version=public.family_membership_states.version+1,
      child_ids=array(select distinct unnest(public.family_membership_states.child_ids||excluded.child_ids)),
      revoked_at=excluded.revoked_at;
  delete from public.parent_authorizations where user_id=old.user_id and family_id=old.family_id;
  delete from public.task_sync_leases where user_id=old.user_id and child_id=any(children);
  return old;
end $$;
revoke all on function public.record_family_membership() from public,anon,authenticated,service_role;
create trigger family_membership_state after insert or delete on public.family_members
  for each row execute function public.record_family_membership();

create function public.revoke_dissolved_family_memberships() returns trigger
language plpgsql security definer set search_path='' as $$
declare children uuid[];
begin
  children:=array(select id from public.children where family_id=old.id
    union select child_id from public.child_deletion_tombstones where family_id=old.id);
  update public.family_membership_states s set active=false,version=s.version+1,
    last_revoked_version=s.version+1,revoked_at=clock_timestamp(),
    child_ids=array(select distinct unnest(s.child_ids||children)) where family_id=old.id;
  return old;
end $$;
revoke all on function public.revoke_dissolved_family_memberships() from public,anon,authenticated,service_role;
create trigger dissolved_family_memberships before delete on public.families
  for each row execute function public.revoke_dissolved_family_memberships();

-- Clients must use the guarded RPC. Security-definer onboarding/acceptance and
-- account cleanup keep their existing access to the underlying relation.
revoke insert,update,delete on public.family_members from authenticated,anon;

create function public.family_membership_access() returns jsonb
language plpgsql security definer set search_path=public as $$
begin
  if not public.account_is_active(auth.uid()) then raise exception '账号不可用' using errcode='42501'; end if;
  return jsonb_build_object('owner_id',auth.uid(),'states',coalesce((select jsonb_agg(
    jsonb_build_object('family_id',family_id,'version',version,'active',active,
      'last_revoked_version',last_revoked_version,'child_ids',child_ids) order by family_id)
    from public.family_membership_states where user_id=auth.uid()),'[]'::jsonb));
end $$;
revoke all on function public.family_membership_access() from public,anon,service_role;
grant execute on function public.family_membership_access() to authenticated;

alter function public.load_family_members(uuid) rename to load_family_members_before_removal;
revoke all on function public.load_family_members_before_removal(uuid) from public,anon,authenticated,service_role;
create function public.load_family_members(target_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare result jsonb; members jsonb;
begin
  result:=public.load_family_members_before_removal(target_family_id);
  select coalesce(jsonb_agg(m||jsonb_build_object('version',s.version,'can_remove',
    (result->>'can_manage')::boolean and m->>'role'='parent'
      and not (m->>'is_self')::boolean and not (m->>'is_owner')::boolean)
      order by n),'[]'::jsonb) into members
    from jsonb_array_elements(result->'members') with ordinality v(m,n)
    join public.family_membership_states s on s.user_id=(m->>'user_id')::uuid
      and s.family_id=target_family_id and s.active;
  return jsonb_set(result,'{members}',members);
end $$;
revoke all on function public.load_family_members(uuid) from public,anon,service_role;
grant execute on function public.load_family_members(uuid) to authenticated;

create table public.family_member_removal_receipts (
  owner_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  family_id uuid not null references public.families(id) on delete cascade,
  payload_hash text not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key(owner_id,request_id)
);
alter table public.family_member_removal_receipts enable row level security;
revoke all on public.family_member_removal_receipts from public,anon,authenticated,service_role;

create function public.resolve_family_member_removal(target_family_id uuid,request_id uuid,
  command jsonb,operation text default 'submit') returns jsonb
language plpgsql security definer set search_path=public as $$
declare target uuid; expected bigint; fingerprint text; receipt public.family_member_removal_receipts;
  member public.family_members; state public.family_membership_states; result jsonb; status text;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  if not public.account_is_active(auth.uid()) then raise exception '账号不可用' using errcode='42501'; end if;
  if request_id is null or operation is null or operation not in ('submit','inspect','cancel')
    or jsonb_typeof(command) is distinct from 'object' or octet_length(command::text)>2048
    or command->>'kind' is distinct from 'remove' then
    raise exception '成员请求格式不正确' using errcode='22023'; end if;
  fingerprint:=encode(sha256(convert_to(command::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('member-removal:'||auth.uid()::text||':'||request_id::text,0));
  perform 1 from public.families where id=target_family_id for update;
  perform public.require_parent_authorization(target_family_id);
  if not public.is_family_admin(target_family_id) then raise exception '仅管理员可移除成员' using errcode='42501'; end if;
  select * into receipt from public.family_member_removal_receipts r
    where r.owner_id=auth.uid() and r.request_id=resolve_family_member_removal.request_id;
  if found then
    if receipt.family_id<>target_family_id or receipt.payload_hash<>fingerprint then
      raise exception '请求已绑定其他内容' using errcode='22023'; end if;
    return receipt.result;
  end if;
  result:=jsonb_build_object('request_id',request_id,'family_id',target_family_id,'kind','remove');
  if operation='inspect' then return result||jsonb_build_object('status','unknown'); end if;
  status:='abandoned';
  if operation='submit' then
    target:=(command->>'user_id')::uuid; expected:=(command->>'version')::bigint;
    if target is null or expected is null or expected<1
      or command-ARRAY['kind','user_id','version'] <> '{}'::jsonb then
      raise exception '成员版本不正确' using errcode='22023'; end if;
    select * into member from public.family_members where family_id=target_family_id and user_id=target for update;
    if not found then status:='conflict';
    else
      if target=auth.uid() or member.role='admin' or exists(
        select 1 from public.families where id=target_family_id and owner_user_id=target) then
        raise exception '不能移除自己或家庭管理员' using errcode='42501'; end if;
      select * into state from public.family_membership_states where user_id=target and family_id=target_family_id for update;
      if not found or not state.active or state.version<>expected then status:='conflict';
      else
        -- Prevent an old pending invitation immediately rejoining the removed account.
        update public.family_invitations set cancelled_at=clock_timestamp(),version=version+1
          where family_id=target_family_id and email=(select lower(btrim(email)) from auth.users where id=target)
            and accepted_at is null and cancelled_at is null;
        delete from public.family_members where family_id=target_family_id and user_id=target;
        status:='applied';
        insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
          values(target_family_id,auth.uid(),'family.member.remove','member',target::text,
            jsonb_build_object('request_id',request_id,'membership_version',expected));
      end if;
    end if;
  end if;
  result:=result||jsonb_build_object('status',status);
  insert into public.family_member_removal_receipts values(auth.uid(),request_id,target_family_id,fingerprint,result,now());
  return result;
end $$;
revoke all on function public.resolve_family_member_removal(uuid,uuid,jsonb,text) from public,anon,service_role;
grant execute on function public.resolve_family_member_removal(uuid,uuid,jsonb,text) to authenticated;

-- No snapshot can mint a new offline lease while membership is being removed.
-- In-flight task replay completes before removal, or observes lost membership.
alter function public.task_sync_snapshot(uuid) rename to task_sync_snapshot_before_membership;
revoke all on function public.task_sync_snapshot_before_membership(uuid) from public,anon,authenticated,service_role;
create function public.task_sync_snapshot(target_child_id uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
begin
  perform 1 from auth.users where id=auth.uid() for share;
  perform 1 from public.families where id=(select family_id from public.children where id=target_child_id) for key share;
  return public.task_sync_snapshot_before_membership(target_child_id);
end $$;
revoke all on function public.task_sync_snapshot(uuid) from public,anon,service_role;
grant execute on function public.task_sync_snapshot(uuid) to authenticated;

alter function public.apply_task_command(jsonb) rename to apply_task_command_before_membership;
revoke all on function public.apply_task_command_before_membership(jsonb) from public,anon,authenticated,service_role;
create function public.apply_task_command(command jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
begin
  perform 1 from auth.users where id=auth.uid() for share;
  perform 1 from public.families where id=(select c.family_id from public.children c
    join public.task_instances t on t.child_id=c.id where t.id=(command->>'task_id')::uuid) for key share;
  return public.apply_task_command_before_membership(command);
end $$;
revoke all on function public.apply_task_command(jsonb) from public,anon,service_role;
grant execute on function public.apply_task_command(jsonb) to authenticated;
