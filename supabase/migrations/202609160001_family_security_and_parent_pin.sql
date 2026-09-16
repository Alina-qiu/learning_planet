create or replace function public.is_family_admin(target_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.family_members fm
    where fm.family_id = target_family_id
      and fm.user_id = auth.uid()
      and fm.role = 'admin'
  )
$$;

revoke all on function public.is_family_member(uuid) from public;
grant execute on function public.is_family_member(uuid) to authenticated;
revoke all on function public.is_family_admin(uuid) from public;
grant execute on function public.is_family_admin(uuid) to authenticated;

create or replace function public.child_is_visible(target_child_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.children c
    where c.id = target_child_id
      and public.is_family_member(c.family_id)
  )
$$;

revoke all on function public.child_is_visible(uuid) from public;
grant execute on function public.child_is_visible(uuid) to authenticated;

create or replace function public.create_family(
  family_name text,
  family_timezone text default 'Asia/Shanghai'
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  created_family_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if nullif(btrim(family_name), '') is null then
    raise exception 'Family name is required';
  end if;
  if not exists (
    select 1 from pg_timezone_names where name = family_timezone
  ) then
    raise exception 'Unknown family timezone';
  end if;

  insert into public.families (name, timezone, owner_user_id)
  values (btrim(family_name), family_timezone, auth.uid())
  returning id into created_family_id;

  insert into public.family_members (family_id, user_id, role)
  values (created_family_id, auth.uid(), 'admin');

  return created_family_id;
end;
$$;

revoke all on function public.create_family(text, text) from public;
grant execute on function public.create_family(text, text) to authenticated;

create policy families_update_admin on public.families for update
  using (public.is_family_admin(id))
  with check (public.is_family_admin(id));

create policy family_members_select on public.family_members for select
  using (public.is_family_member(family_id));
create policy family_members_insert_admin on public.family_members for insert
  with check (public.is_family_admin(family_id));
create policy family_members_update_admin on public.family_members for update
  using (public.is_family_admin(family_id))
  with check (public.is_family_admin(family_id));
create policy family_members_delete_admin on public.family_members for delete
  using (public.is_family_admin(family_id));

create policy wallets_select on public.wallets for select
  using (public.child_is_visible(child_id));
create policy wrong_questions_member on public.wrong_questions for all
  using (public.child_is_visible(child_id))
  with check (public.child_is_visible(child_id));
create policy task_instances_member on public.task_instances for all
  using (public.child_is_visible(child_id))
  with check (public.child_is_visible(child_id));
create policy task_review_items_member on public.task_review_items for all
  using (
    exists (
      select 1 from public.task_instances ti
      where ti.id = task_instance_id
        and public.child_is_visible(ti.child_id)
    )
  )
  with check (
    exists (
      select 1 from public.task_instances ti
      where ti.id = task_instance_id
        and public.child_is_visible(ti.child_id)
    )
  );
create policy ledger_entries_select on public.ledger_entries for select
  using (public.child_is_visible(child_id));
create policy rewards_member on public.rewards for all
  using (public.is_family_member(family_id))
  with check (public.is_family_member(family_id));
create policy redemptions_select on public.redemptions for select
  using (public.child_is_visible(child_id));
create policy audit_logs_select on public.audit_logs for select
  using (public.is_family_member(family_id));

create table public.parent_pins (
  family_id uuid primary key references public.families(id) on delete cascade,
  pin_hash text not null,
  failed_attempts smallint not null default 0 check (failed_attempts between 0 and 5),
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.parent_pins enable row level security;

create or replace function public.set_parent_pin(
  target_family_id uuid,
  new_pin text
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_family_admin(target_family_id) then
    raise exception 'Family administrator required';
  end if;
  if new_pin !~ '^[0-9]{4,6}$' then
    raise exception 'PIN must contain 4 to 6 digits';
  end if;

  insert into public.parent_pins (family_id, pin_hash)
  values (target_family_id, crypt(new_pin, gen_salt('bf', 12)))
  on conflict (family_id) do update
    set pin_hash = excluded.pin_hash,
        failed_attempts = 0,
        locked_until = null,
        updated_at = now();
end;
$$;

revoke all on function public.set_parent_pin(uuid, text) from public;
grant execute on function public.set_parent_pin(uuid, text) to authenticated;

create or replace function public.verify_parent_pin(
  target_family_id uuid,
  candidate_pin text
) returns table (
  verified boolean,
  remaining_attempts integer,
  retry_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  pin_record public.parent_pins%rowtype;
  next_failed_attempts integer;
begin
  if not public.is_family_member(target_family_id) then
    raise exception 'Family membership required';
  end if;

  select * into pin_record
  from public.parent_pins
  where family_id = target_family_id
  for update;

  if not found then
    raise exception 'Parent PIN is not configured';
  end if;

  if pin_record.locked_until > now() then
    return query select false, 0, pin_record.locked_until;
    return;
  end if;

  if crypt(candidate_pin, pin_record.pin_hash) = pin_record.pin_hash then
    update public.parent_pins
    set failed_attempts = 0, locked_until = null, updated_at = now()
    where family_id = target_family_id;
    return query select true, 5, null::timestamptz;
    return;
  end if;

  next_failed_attempts := case
    when pin_record.locked_until is not null then 1
    else pin_record.failed_attempts + 1
  end;

  update public.parent_pins
  set failed_attempts = least(next_failed_attempts, 5),
      locked_until = case
        when next_failed_attempts >= 5 then now() + interval '10 minutes'
        else null
      end,
      updated_at = now()
  where family_id = target_family_id
  returning parent_pins.locked_until into retry_at;

  return query
  select false, greatest(5 - next_failed_attempts, 0), retry_at;
end;
$$;

revoke all on function public.verify_parent_pin(uuid, text) from public;
grant execute on function public.verify_parent_pin(uuid, text) to authenticated;
