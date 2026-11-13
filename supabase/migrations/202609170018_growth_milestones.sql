-- Growth is projected from trusted completion/XP records, never client counters.
create table public.child_checkin_days(
  child_id uuid not null references public.children(id) on delete cascade,
  day date not null, created_at timestamptz not null default now(), primary key(child_id,day));
create table public.child_streak_awards(
  child_id uuid not null references public.children(id) on delete cascade,
  milestone integer not null check(milestone in (3,7,30)),
  id uuid not null default gen_random_uuid() unique,
  achieved_at timestamptz not null default now(), primary key(child_id,milestone));
create table public.growth_assets(
  key text primary key,title text not null,kind text not null check(kind in ('badge','outfit','pet')),
  minimum_level integer check(minimum_level between 5 and 50 and minimum_level%5=0));
insert into public.growth_assets values
  ('streak7','坚持七天徽章','badge',null),('streak30','坚持三十天装扮','outfit',null),
  ('level5','星星徽章','badge',5),('level10','勇气披风','outfit',10),
  ('level15','月亮徽章','badge',15),('level20','小猫伙伴','pet',20),
  ('level25','探索者帽子','outfit',25),('level30','太阳徽章','badge',30),
  ('level35','小熊伙伴','pet',35),('level40','星际披风','outfit',40),
  ('level45','银河徽章','badge',45),('level50','学习星球皇冠','outfit',50);
create table public.child_growth_assets(
  child_id uuid not null references public.children(id) on delete cascade,
  asset_key text not null references public.growth_assets(key),
  unlocked_at timestamptz not null default now(),primary key(child_id,asset_key));
create table public.child_growth_profiles(
  child_id uuid primary key references public.children(id) on delete cascade,
  equipped_asset text references public.growth_assets(key));
alter table public.child_checkin_days enable row level security;
alter table public.child_streak_awards enable row level security;
alter table public.growth_assets enable row level security;
alter table public.child_growth_assets enable row level security;
alter table public.child_growth_profiles enable row level security;
revoke all on public.child_checkin_days,public.child_streak_awards,public.growth_assets,
  public.child_growth_assets,public.child_growth_profiles from public,anon,authenticated;
grant select on public.child_checkin_days,public.child_streak_awards,public.growth_assets,
  public.child_growth_assets,public.child_growth_profiles to authenticated,service_role;
create policy checkin_read on public.child_checkin_days for select to authenticated using(public.child_is_visible(child_id));
create policy streak_read on public.child_streak_awards for select to authenticated using(public.child_is_visible(child_id));
create policy growth_catalog_read on public.growth_assets for select to authenticated using(true);
create policy growth_assets_read on public.child_growth_assets for select to authenticated using(public.child_is_visible(child_id));
create policy growth_profiles_read on public.child_growth_profiles for select to authenticated using(public.child_is_visible(child_id));

create function public.record_growth_day(child uuid, task_day date) returns void
language plpgsql security definer set search_path='' as $$
declare zone text; longest integer; milestone integer; award uuid;
begin
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=child;
  if zone is null or task_day is null or task_day>(now() at time zone zone)::date then return; end if;
  -- Ledger insertion already owns this wallet lock; use the same lock order.
  perform pg_advisory_xact_lock(hashtextextended('wallet:'||child::text,0));
  insert into public.child_checkin_days(child_id,day) values(child,task_day) on conflict do nothing;
  with islands as(select day,day-(row_number() over(order by day))::integer as run from public.child_checkin_days where child_id=child)
    select coalesce(max(length),0)::integer into longest from(select count(*) as length from islands group by run) runs;
  foreach milestone in array array[3,7,30] loop
    if longest<milestone then continue; end if;
    award:=null;
    -- Achievement bonuses are first-time milestones, not a farmable reset loop.
    insert into public.child_streak_awards(child_id,milestone) values(child,milestone)
      on conflict do nothing returning id into award;
    if award is null then continue; end if;
    insert into public.ledger_entries(child_id,asset_type,amount,source_type,source_id,idempotency_key)
      values(child,case when milestone=3 then 'coin' else 'xp' end,
        case milestone when 3 then 30 when 7 then 50 else 150 end,'streak',award,'streak:'||award);
    if milestone in (7,30) then
      insert into public.child_growth_assets(child_id,asset_key) values(child,'streak'||milestone) on conflict do nothing;
    end if;
  end loop;
end $$;
revoke all on function public.record_growth_day(uuid,date) from public,anon,authenticated,service_role;

create function public.project_task_growth() returns trigger
language plpgsql security definer set search_path='' as $$
declare task public.task_instances;
begin
  if new.asset_type='xp' and new.source_type='task_completion' then
    select * into task from public.task_instances where id=new.source_id and child_id=new.child_id and status='completed';
    if found then perform public.record_growth_day(task.child_id,task.due_date); end if;
  end if;
  return new;
end $$;
create trigger task_growth_projection after insert on public.ledger_entries
  for each row execute function public.project_task_growth();
revoke all on function public.project_task_growth() from public,anon,authenticated;

create function public.project_level_assets() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.xp>old.xp then
    insert into public.child_growth_assets(child_id,asset_key)
      select new.child_id,key from public.growth_assets where minimum_level<=public.xp_level(new.xp)
      on conflict do nothing;
  end if;
  return new;
end $$;
create trigger wallet_level_assets after update of xp on public.wallets
  for each row execute function public.project_level_assets();
revoke all on function public.project_level_assets() from public,anon,authenticated;
-- Existing levels receive their visible assets without minting new money or XP.
insert into public.child_growth_assets(child_id,asset_key)
  select w.child_id,a.key from public.wallets w cross join public.growth_assets a
  where a.minimum_level<=public.xp_level(w.xp) on conflict do nothing;
insert into public.child_checkin_days(child_id,day)
  select distinct t.child_id,t.due_date from public.task_instances t
  join public.children c on c.id=t.child_id join public.families f on f.id=c.family_id
  where t.status='completed' and t.completed_at is not null and t.due_date<=(now() at time zone f.timezone)::date
  on conflict do nothing;

create function public.equip_growth_asset(target_child_id uuid, asset_key text) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  if asset_key is not null and not exists(select 1 from public.child_growth_assets
    where child_id=target_child_id and child_growth_assets.asset_key=equip_growth_asset.asset_key) then
    raise exception '请先解锁这项奖励'; end if;
  insert into public.child_growth_profiles(child_id,equipped_asset) values(target_child_id,asset_key)
    on conflict(child_id) do update set equipped_asset=excluded.equipped_asset;
end $$;
revoke all on function public.equip_growth_asset(uuid,text) from public,anon;
grant execute on function public.equip_growth_asset(uuid,text) to authenticated;

create function public.growth_overview(target_child_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare today date; streak integer; assets jsonb; milestones jsonb; equipped text;
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  select (now() at time zone f.timezone)::date into today from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  with islands as(select day,day-(row_number() over(order by day))::integer as run from public.child_checkin_days where child_id=target_child_id)
    select coalesce(max(length),0)::integer into streak from
      (select count(*) as length,max(day) as last_day from islands group by run) runs where last_day>=today-1;
  select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('unlocked',u.asset_key is not null,'unlocked_at',u.unlocked_at)
    order by a.minimum_level nulls first,a.key),'[]') into assets from public.growth_assets a
    left join public.child_growth_assets u on u.asset_key=a.key and u.child_id=target_child_id;
  select coalesce(jsonb_agg(milestone order by milestone),'[]') into milestones from public.child_streak_awards where child_id=target_child_id;
  select equipped_asset into equipped from public.child_growth_profiles where child_id=target_child_id;
  return jsonb_build_object('streak',streak,'milestones',milestones,'assets',assets,'equipped_asset',equipped,
    'checkin_today',exists(select 1 from public.child_checkin_days where child_id=target_child_id and day=today));
end $$;
revoke all on function public.growth_overview(uuid) from public,anon;
grant execute on function public.growth_overview(uuid) to authenticated;
