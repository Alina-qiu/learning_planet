-- Invitation changes are explicit, PIN protected and durable across lost replies.
alter table public.family_invitations add column cancelled_at timestamptz;
alter table public.family_invitations add column version bigint not null default 1;
drop index public.family_invitations_pending_email_idx;
create unique index family_invitations_pending_email_idx
  on public.family_invitations(family_id,email)
  where accepted_at is null and cancelled_at is null;

drop policy family_invitations_admin_select on public.family_invitations;
create policy family_invitations_admin_select on public.family_invitations for select
  using (public.is_family_admin(family_id) and public.has_parent_authorization(family_id));

create table public.family_invitation_receipts (
  owner_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  family_id uuid not null references public.families(id) on delete cascade,
  payload_hash text not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key(owner_id,request_id)
);
alter table public.family_invitation_receipts enable row level security;
revoke all on public.family_invitation_receipts from public,anon,authenticated,service_role;

create function public.load_family_members(target_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare admin boolean; members jsonb; invitations jsonb;
begin
  perform public.require_parent_authorization(target_family_id);
  admin:=public.is_family_admin(target_family_id);
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',m.user_id,'role',m.role,'is_self',m.user_id=auth.uid(),
    'is_owner',m.user_id=f.owner_user_id,
    'email',case when admin or m.user_id=auth.uid() then u.email
      else left(split_part(u.email,'@',1),1)||'***@'||split_part(u.email,'@',2) end
  ) order by m.user_id=f.owner_user_id desc,m.user_id),'[]'::jsonb) into members
  from public.family_members m join auth.users u on u.id=m.user_id
    join public.families f on f.id=m.family_id where m.family_id=target_family_id;
  invitations:='[]'::jsonb;
  if admin then
    select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,
      'version',i.version,'expires_at',i.expires_at,'expired',i.expires_at<=clock_timestamp())
      order by i.created_at desc,i.id),'[]'::jsonb) into invitations
    from public.family_invitations i where i.family_id=target_family_id
      and i.accepted_at is null and i.cancelled_at is null;
  end if;
  return jsonb_build_object('family_id',target_family_id,'viewer_id',auth.uid(),
    'can_manage',admin,'members',members,'invitations',invitations);
end $$;
revoke all on function public.load_family_members(uuid) from public,anon,service_role;
grant execute on function public.load_family_members(uuid) to authenticated;

create function public.resolve_family_invitation(target_family_id uuid,request_id uuid,
  command jsonb,operation text default 'submit') returns jsonb
language plpgsql security definer set search_path=public as $$
declare receipt public.family_invitation_receipts; invitation public.family_invitations;
  fingerprint text; kind text; normalized_email text; target uuid; expected bigint; result jsonb; status text;
begin
  -- Match account deletion's lock order. Acceptance/cancellation serialize on family.
  perform 1 from auth.users where id=auth.uid() for share;
  if not public.account_is_active(auth.uid()) then
    raise exception '账号不可用' using errcode='42501'; end if;
  if request_id is null or operation is null or operation not in ('submit','inspect','cancel')
    or jsonb_typeof(command) is distinct from 'object' or octet_length(command::text)>2048
    or command->>'kind' is null or command->>'kind' not in ('invite','renew','revoke') then
    raise exception '邀请请求格式不正确' using errcode='22023'; end if;
  kind:=command->>'kind';
  fingerprint:=encode(sha256(convert_to(command::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('invitation:'||auth.uid()::text||':'||request_id::text,0));
  perform 1 from public.families where id=target_family_id for update;
  perform public.require_parent_authorization(target_family_id);
  if not public.is_family_admin(target_family_id) then
    raise exception '仅管理员可管理邀请' using errcode='42501'; end if;
  select * into receipt from public.family_invitation_receipts r
    where r.owner_id=auth.uid() and r.request_id=resolve_family_invitation.request_id;
  if found then
    if receipt.family_id<>target_family_id or receipt.payload_hash<>fingerprint then
      raise exception '请求已绑定其他内容' using errcode='22023'; end if;
    return receipt.result;
  end if;
  result:=jsonb_build_object('request_id',request_id,'family_id',target_family_id,'kind',kind);
  if operation='inspect' then return result||jsonb_build_object('status','unknown'); end if;
  status:='abandoned';
  if operation='submit' then
    -- A rejected form must still be inspectable/cancellable with its original
    -- payload; cancellation records a barrier, never executes that payload.
    if kind='invite' then
      normalized_email:=lower(btrim(command->>'email'));
      if jsonb_typeof(command->'email') is distinct from 'string' or length(normalized_email)>254
        or normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
        or command-ARRAY['kind','email'] <> '{}'::jsonb then
        raise exception '请输入有效邮箱' using errcode='22023'; end if;
    else
      target:=(command->>'invitation_id')::uuid; expected:=(command->>'version')::bigint;
      if target is null or expected is null or expected<1
        or command-ARRAY['kind','invitation_id','version'] <> '{}'::jsonb then
        raise exception '邀请版本不正确' using errcode='22023'; end if;
    end if;
    if kind='invite' then
      if exists(select 1 from public.family_members m join auth.users u on u.id=m.user_id
        where m.family_id=target_family_id and lower(btrim(u.email))=normalized_email) then
        status:='already_member';
      else
        -- Repeated invitations do not silently extend the original deadline.
        select * into invitation from public.family_invitations i
          where i.family_id=target_family_id and i.email=normalized_email
            and i.accepted_at is null and i.cancelled_at is null for update;
        if not found then
          insert into public.family_invitations(family_id,email,invited_by)
            values(target_family_id,normalized_email,auth.uid()) returning * into invitation;
        end if;
        status:='applied';
      end if;
    else
      select * into invitation from public.family_invitations i
        where i.family_id=target_family_id and i.id=target for update;
      if not found or invitation.version<>expected or invitation.accepted_at is not null
        or invitation.cancelled_at is not null then
        status:='conflict';
      elsif kind='renew' then
        -- Only expired invitations can be renewed. CAS fences stale screens.
        if invitation.expires_at>clock_timestamp() then status:='conflict';
        else
          update public.family_invitations set expires_at=clock_timestamp()+interval '7 days',
            created_at=clock_timestamp(),invited_by=auth.uid(),version=version+1
            where id=target returning * into invitation;
          status:='applied';
        end if;
      else
        update public.family_invitations set cancelled_at=clock_timestamp(),version=version+1
          where id=target returning * into invitation;
        status:='applied';
      end if;
    end if;
  end if;
  result:=result||jsonb_build_object('status',status);
  insert into public.family_invitation_receipts values(auth.uid(),request_id,target_family_id,fingerprint,result,now());
  if status='applied' then
    insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
      values(target_family_id,auth.uid(),'family.invitation.'||kind,'invitation',invitation.id::text,
        jsonb_build_object('request_id',request_id,'version',invitation.version));
  end if;
  return result;
end $$;
revoke all on function public.resolve_family_invitation(uuid,uuid,jsonb,text) from public,anon,service_role;
grant execute on function public.resolve_family_invitation(uuid,uuid,jsonb,text) to authenticated;

-- Keep the existing API compatible while sharing the new locking and policy.
create or replace function public.invite_family_parent(target_family_id uuid,parent_email text) returns uuid
language plpgsql security definer set search_path=public as $$
declare result jsonb; invitation_id uuid;
begin
  result:=public.resolve_family_invitation(target_family_id,gen_random_uuid(),
    jsonb_build_object('kind','invite','email',parent_email),'submit');
  select id into invitation_id from public.family_invitations
    where family_id=target_family_id and email=lower(btrim(parent_email))
      and accepted_at is null and cancelled_at is null;
  return invitation_id;
end $$;
-- The old internal implementation's unique-index predicate is now obsolete.
drop function public.invite_family_parent_internal(uuid,text);

create or replace function public.accept_family_invitations() returns integer
language plpgsql security definer set search_path=public as $$
declare current_email text; family uuid; accepted_count integer:=0; changed integer;
begin
  -- Use the verified account's current email, never an old JWT email claim.
  select lower(btrim(email)) into current_email from auth.users where id=auth.uid() for share;
  if not public.account_is_active(auth.uid()) or nullif(current_email,'') is null then return 0; end if;
  for family in select distinct family_id from public.family_invitations
    where email=current_email and accepted_at is null and cancelled_at is null
      and expires_at>clock_timestamp() order by family_id loop
    perform 1 from public.families where id=family for update;
    if not found or exists(select 1 from public.account_deletion_jobs j
      where family=any(j.owned_family_ids)) then continue; end if;
    update public.family_invitations set accepted_at=clock_timestamp(),version=version+1
      where family_id=family and email=current_email and accepted_at is null
        and cancelled_at is null and expires_at>clock_timestamp();
    get diagnostics changed=row_count;
    if changed>0 then
      insert into public.family_members(family_id,user_id,role) values(family,auth.uid(),'parent')
        on conflict(family_id,user_id) do nothing;
      insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
        values(family,auth.uid(),'family.invitation.accept','member',auth.uid()::text,
          jsonb_build_object('accepted_count',changed));
      accepted_count:=accepted_count+changed;
    end if;
  end loop;
  return accepted_count;
end $$;
