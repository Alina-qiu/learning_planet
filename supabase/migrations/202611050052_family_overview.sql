-- Bounded aggregates for the parent landing page; no ledger/history downloads
-- and no generation, expiry or reward side effects while reading the report.
create index children_family_overview_idx on public.children(family_id,created_at,id);
create index redemption_pending_child_idx on public.redemptions(child_id,expires_at)
  where status in ('requested','approved');
create index coin_awards_pending_child_idx on public.pending_coin_awards(child_id)
  where status='pending';

create function public.family_overview(target_family_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare family public.families; today date; result jsonb;
begin
  perform public.require_parent_authorization(target_family_id);
  select * into strict family from public.families where id=target_family_id;
  today:=(now() at time zone family.timezone)::date;
  with kids as materialized (
    select id,nickname,created_at from public.children where family_id=target_family_id
  ), eligible as materialized (
    select t.child_id,t.due_date,t.status from public.task_instances t
      join kids c on c.id=t.child_id
    where t.due_date between today-6 and today
      and not exists(select 1 from public.long_plans p join public.plan_leaves l on l.plan_id=p.id
        where p.template_id=t.template_id and l.leave_date=t.due_date)
  ), days as (
    select c.id as child_id,today-6+n as day from kids c cross join generate_series(0,6) n
  ), daily as (
    select d.child_id,d.day,count(t.child_id)::integer expected,
      count(t.child_id) filter(where t.status='completed')::integer completed
    from days d left join eligible t on t.child_id=d.child_id and t.due_date=d.day
    group by d.child_id,d.day
  ), claims as (
    select r.child_id,
      count(*) filter(where r.status='requested' and r.expires_at>now())::integer requested,
      count(*) filter(where r.status='approved' and r.expires_at>now())::integer approved,
      count(*) filter(where r.expires_at<=now())::integer awaiting_expiry
    from public.redemptions r join kids c on c.id=r.child_id
    where r.status in ('requested','approved') group by r.child_id
  ), awards as (
    select a.child_id,count(*)::integer pending_awards,sum(a.amount) pending_coins
    from public.pending_coin_awards a join kids c on c.id=a.child_id
    where a.status='pending' group by a.child_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'child_id',c.id,'nickname',c.nickname,
    'days',(select jsonb_agg(jsonb_build_object('day',d.day,'expected',d.expected,'completed',d.completed)
      order by d.day) from daily d where d.child_id=c.id),
    'requested',coalesce(r.requested,0),'approved',coalesce(r.approved,0),
    'awaiting_expiry',coalesce(r.awaiting_expiry,0),
    'pending_awards',coalesce(a.pending_awards,0),'pending_coins',coalesce(a.pending_coins,0)
  ) order by c.created_at,c.id),'[]'::jsonb) into result
  from kids c left join claims r on r.child_id=c.id left join awards a on a.child_id=c.id;
  return jsonb_build_object('family_id',family.id,'family_name',family.name,
    'timezone',family.timezone,'today',today,'generated_at',now(),'children',result);
end $$;
revoke all on function public.family_overview(uuid) from public,anon,service_role;
grant execute on function public.family_overview(uuid) to authenticated;
