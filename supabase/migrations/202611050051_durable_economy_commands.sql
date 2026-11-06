-- Private results, not a second balance or a copy of adjustment explanations.
create table public.economy_command_receipts (
  owner_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  child_id uuid not null references public.children(id) on delete cascade,
  payload_hash text not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key(owner_id,request_id)
);
alter table public.economy_command_receipts enable row level security;
revoke all on public.economy_command_receipts from public,anon,authenticated,service_role;

create function public.resolve_economy_command(target_child_id uuid,request_id uuid,
  command jsonb,operation text default 'submit') returns jsonb
language plpgsql security definer set search_path=public as $$
declare family uuid; fingerprint text; receipt public.economy_command_receipts;
  result jsonb; kind text; redemption uuid;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  if not public.account_is_active(auth.uid()) then raise exception '账号不可用' using errcode='42501'; end if;
  if request_id is null or operation is null or operation not in ('submit','inspect','cancel')
    or jsonb_typeof(command) is distinct from 'object' or octet_length(command::text)>4096
    or coalesce(command->>'kind','') not in ('redeem','adjust') then
    raise exception '请求格式不正确' using errcode='22023'; end if;
  kind:=command->>'kind';
  fingerprint:=encode(sha256(convert_to(command::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('economy-command:'||auth.uid()::text||':'||request_id::text,0));
  select c.family_id into family from public.children c where c.id=target_child_id;
  perform 1 from public.families where id=family for key share;
  -- Prevent a child delete from clearing the business result before its receipt.
  perform 1 from public.children where id=target_child_id for key share;
  if not public.child_is_visible(target_child_id) then raise exception '无权访问该孩子' using errcode='42501'; end if;
  if kind='adjust' then perform public.require_parent_authorization(family); end if;
  select * into receipt from public.economy_command_receipts r
    where r.owner_id=auth.uid() and r.request_id=resolve_economy_command.request_id;
  if found then
    if receipt.child_id<>target_child_id or receipt.payload_hash<>fingerprint then
      raise exception '请求已绑定其他内容' using errcode='22023'; end if;
    return receipt.result;
  end if;
  result:=jsonb_build_object('owner_id',auth.uid(),'request_id',request_id,
    'child_id',target_child_id,'family_id',family,'kind',kind);
  if operation='inspect' then return result||jsonb_build_object('status','unknown'); end if;
  if operation='cancel' then
    result:=result||jsonb_build_object('status','abandoned');
  else
    if kind='redeem' then
      if command-ARRAY['kind','reward_id','version']<>'{}'::jsonb then
        raise exception '兑换参数不正确' using errcode='22023'; end if;
      redemption:=public.request_reward(target_child_id,(command->>'reward_id')::uuid,
        request_id,(command->>'version')::bigint);
      result:=result||jsonb_build_object('status','applied','redemption_id',redemption);
    else
      if command-ARRAY['kind','coins','xp_amount','reason','large_amount_confirmed']<>'{}'::jsonb then
        raise exception '调账参数不正确' using errcode='22023'; end if;
      perform public.adjust_wallet(target_child_id,(command->>'coins')::integer,
        (command->>'xp_amount')::integer,command->>'reason',request_id,
        coalesce((command->>'large_amount_confirmed')::boolean,false));
      result:=result||jsonb_build_object('status','applied');
    end if;
  end if;
  insert into public.economy_command_receipts values(auth.uid(),request_id,target_child_id,fingerprint,result,now());
  return result;
end $$;
revoke all on function public.resolve_economy_command(uuid,uuid,jsonb,text) from public,anon,service_role;
grant execute on function public.resolve_economy_command(uuid,uuid,jsonb,text) to authenticated;
