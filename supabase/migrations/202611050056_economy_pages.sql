-- Bounded, stable-key reads for years of household transaction history.
create index ledger_entries_page_idx on public.ledger_entries(child_id,created_at desc,id desc);
create index redemptions_page_idx on public.redemptions(child_id,created_at desc,id desc);
create index pending_coin_awards_page_idx on public.pending_coin_awards(child_id,created_at desc,id desc) where status='pending';
create index rewards_page_idx on public.rewards(family_id,created_at desc,id desc);

create function public.economy_page(target_child_id uuid,target_family_id uuid,section text,
  after_created_at timestamptz default null,after_id uuid default null,page_size integer default 50,
  include_inactive boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare family uuid; zone text; day date; balance public.wallets; r public.rewards;
  capacity jsonb; blocked text; items jsonb:='[]'; raw jsonb; last_row jsonb; more boolean;
begin
  select c.family_id,f.timezone into family,zone from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  if family is distinct from target_family_id or not coalesce(public.child_is_visible(target_child_id),false) then
    raise exception 'Child access required' using errcode='42501'; end if;
  if section is null or section not in ('rewards','redemptions','pending','ledger') or
    page_size is null or page_size not between 1 and 100 or include_inactive is null or
    (after_created_at is null)<>(after_id is null) or after_created_at is not null and not isfinite(after_created_at) then
    raise exception 'Invalid economy page' using errcode='22023'; end if;
  day:=(now() at time zone zone)::date;
  if section='rewards' then
    -- Same expiry and capacity rules as the existing catalog and request RPC.
    perform public.expire_child_redemptions(target_child_id);
    select * into balance from public.wallets where child_id=target_child_id;
    select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc,q.id desc),'[]') into raw from (
      select * from public.rewards t where t.family_id=family and (include_inactive or t.active)
        and (after_id is null or (t.created_at,t.id)<(after_created_at,after_id))
        order by t.created_at desc,t.id desc limit page_size+1) q;
    more:=jsonb_array_length(raw)>page_size;
    for r in select * from jsonb_populate_recordset(null::public.rewards,raw) order by created_at desc,id desc limit page_size loop
      capacity:=public.reward_capacity(r.id,target_child_id,day);
      blocked:=case when not r.active then '已下架' when r.available_from>now() then '尚未开放' when r.available_until<=now() then '已结束'
        when (capacity->>'stock_available')::bigint=0 then '库存已用完' when (capacity->>'quota_remaining')::bigint=0 then '已达兑换次数限制'
        when public.xp_level(balance.xp)<r.minimum_level then '尚未达到解锁等级' when balance.coin_balance<r.cost then '可用金币不足' else null end;
      items:=items||jsonb_build_array(to_jsonb(r)||capacity||jsonb_build_object('can_request',blocked is null,'blocked_reason',blocked,'family_timezone',zone));
    end loop;
  else
    if section='redemptions' then
      select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc,q.id desc),'[]') into raw from (
        select * from public.redemptions t where t.child_id=target_child_id
          and (after_id is null or (t.created_at,t.id)<(after_created_at,after_id))
          order by t.created_at desc,t.id desc limit page_size+1) q;
    elsif section='pending' then
      select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc,q.id desc),'[]') into raw from (
        select * from public.pending_coin_awards t where t.child_id=target_child_id and t.status='pending'
          and (after_id is null or (t.created_at,t.id)<(after_created_at,after_id))
          order by t.created_at desc,t.id desc limit page_size+1) q;
    else
      select coalesce(jsonb_agg(to_jsonb(q)-'idempotency_key' order by q.created_at desc,q.id desc),'[]') into raw from (
        select * from public.ledger_entries t where t.child_id=target_child_id
          and (after_id is null or (t.created_at,t.id)<(after_created_at,after_id))
          order by t.created_at desc,t.id desc limit page_size+1) q;
    end if;
    more:=jsonb_array_length(raw)>page_size;
    select coalesce(jsonb_agg(value order by ordinal),'[]') into items
      from jsonb_array_elements(raw) with ordinality e(value,ordinal) where ordinal<=page_size;
  end if;
  last_row:=items->(jsonb_array_length(items)-1);
  return jsonb_build_object('owner_id',auth.uid(),'child_id',target_child_id,'family_id',family,
    'section',section,'include_inactive',include_inactive,'family_today',day,'fetched_at',now(),'items',items,
    'next_cursor',case when more then jsonb_build_object('created_at',last_row->>'created_at','id',last_row->>'id') else null end);
end $$;
revoke all on function public.economy_page(uuid,uuid,text,timestamptz,uuid,integer,boolean) from public,anon,service_role;
grant execute on function public.economy_page(uuid,uuid,text,timestamptz,uuid,integer,boolean) to authenticated;
