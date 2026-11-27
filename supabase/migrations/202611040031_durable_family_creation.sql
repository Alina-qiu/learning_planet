-- Store no profile text in receipts. Keep UUID/hash barriers after a child or
-- family is deleted, until the requesting account itself is erased.
create table public.family_creation_receipts (
  request_id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  payload_hash text not null,
  kind text not null check(kind in ('family','child')),
  family_id uuid not null,
  child_id uuid not null,
  state text not null check(state in ('created','cancelled')),
  created_at timestamptz not null default now()
);
alter table public.family_creation_receipts enable row level security;
revoke all on public.family_creation_receipts from public,anon,authenticated,service_role;
create index family_creation_owner on public.family_creation_receipts(owner_id);

create function public.family_creation_result(receipt public.family_creation_receipts) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('request_id',receipt.request_id,
    'family_id',receipt.family_id,'child_id',receipt.child_id,
    'status',case when receipt.state='cancelled' then 'cancelled'
      when not public.is_family_member(receipt.family_id)
        or not exists(select 1 from public.children where id=receipt.child_id and family_id=receipt.family_id)
      then 'unavailable' else 'created' end);
$$;
revoke all on function public.family_creation_result(public.family_creation_receipts) from public,anon,authenticated,service_role;

-- 'inspect' is read-only. 'cancel' fences a not-yet-committed request and never
-- deletes a created profile. It races safely with 'submit' on the same lock.
create function public.resolve_family_creation(request_id uuid,command jsonb,operation text default 'inspect') returns jsonb
language plpgsql security definer set search_path='' as $$
declare receipt public.family_creation_receipts; fingerprint text; family uuid; child uuid; kind text;
  nickname text; grade smallint; family_name text; timezone text; preferences jsonb;
begin
  if auth.uid() is null or nullif(auth.jwt()->>'session_id','') is null then
    raise exception '请重新登录' using errcode='42501'; end if;
  perform 1 from auth.users where id=auth.uid() for share;
  if not public.account_is_active(auth.uid()) then raise exception '账号已申请注销' using errcode='42501'; end if;
  if request_id is null or operation is null or operation not in ('inspect','submit','cancel')
    or jsonb_typeof(command) is distinct from 'object' or octet_length(command::text)>8192
    or command->>'kind' is null or command->>'kind' not in ('family','child') then
    raise exception '创建请求格式不正确' using errcode='22023'; end if;
  kind:=command->>'kind';
  family:=(command->>'family_id')::uuid; child:=(command->>'child_id')::uuid;
  if family is null or child is null then raise exception '创建请求缺少档案编号' using errcode='22023'; end if;
  fingerprint:=encode(sha256(convert_to(command::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('family-creation:'||request_id::text,0));
  select * into receipt from public.family_creation_receipts r where r.request_id=resolve_family_creation.request_id;
  if found then
    if receipt.owner_id<>auth.uid() then raise exception '创建请求不属于当前账号' using errcode='42501'; end if;
    if receipt.payload_hash<>fingerprint then raise exception '该创建请求已绑定其他内容，请先核对原请求' using errcode='22023'; end if;
    return public.family_creation_result(receipt);
  end if;
  if operation='inspect' then
    return jsonb_build_object('request_id',request_id,'family_id',family,'child_id',child,'status','unknown');
  end if;
  if operation='cancel' then
    insert into public.family_creation_receipts values(request_id,auth.uid(),fingerprint,kind,family,child,'cancelled',now()) returning * into receipt;
    return public.family_creation_result(receipt);
  end if;

  -- Validate before creating anything. jsonb equality gives order-independent
  -- payload binding while preserving every submitted field.
  preferences:=command->'preferences';
  perform public.validate_child_preferences(preferences);
  nickname:=command->>'nickname';
  if jsonb_typeof(command->'nickname') is distinct from 'string'
    or length(btrim(nickname)) not between 1 and 40
    or jsonb_typeof(command->'grade') is distinct from 'number'
    or (command->>'grade') !~ '^[1-6]$' then
    raise exception '昵称需为1至40字，年级需为1至6' using errcode='22023'; end if;
  grade:=(command->>'grade')::smallint;
  if exists(select 1 from public.child_deletion_tombstones where child_id=child) then
    raise exception '此孩子档案已删除，不能重新创建' using errcode='22023'; end if;
  if kind='family' then
    family_name:=command->>'family_name'; timezone:=command->>'timezone';
    if jsonb_typeof(command->'family_name') is distinct from 'string'
      or length(btrim(family_name)) not between 1 and 80
      or jsonb_typeof(command->'timezone') is distinct from 'string'
      or not exists(select 1 from pg_catalog.pg_timezone_names where name=timezone) then
      raise exception '请检查家庭名称和时区' using errcode='22023'; end if;
    insert into public.families(id,name,timezone,owner_user_id) values(family,btrim(family_name),timezone,auth.uid());
    insert into public.family_members(family_id,user_id,role) values(family,auth.uid(),'admin');
  else
    -- Parent authorization is never saved in the local command or receipt.
    perform 1 from public.families where id=family for key share;
    perform public.require_parent_authorization(family);
    if not public.is_family_admin(family) then raise exception '仅家庭管理员可以添加孩子' using errcode='42501'; end if;
  end if;
  insert into public.children(id,family_id,nickname,grade,textbook_labels,avatar_key)
    values(child,family,btrim(nickname),grade,preferences->'textbook_labels',preferences->>'avatar_key');
  insert into public.wallets(child_id) values(child);
  insert into public.family_creation_receipts values(request_id,auth.uid(),fingerprint,kind,family,child,'created',now()) returning * into receipt;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),case when kind='family' then 'family.created' else 'child.created' end,
      'child',child::text,jsonb_build_object('request_id',request_id));
  return public.family_creation_result(receipt);
end $$;
revoke all on function public.resolve_family_creation(uuid,jsonb,text) from public,anon,service_role;
grant execute on function public.resolve_family_creation(uuid,jsonb,text) to authenticated;
