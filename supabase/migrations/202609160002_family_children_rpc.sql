create or replace function public.onboard_family(
  family_name text,
  family_timezone text,
  child_nickname text,
  child_grade smallint
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  created_family_id uuid;
  created_child_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if nullif(btrim(family_name), '') is null then
    raise exception 'Family name is required';
  end if;
  if nullif(btrim(child_nickname), '') is null then
    raise exception 'Child nickname is required';
  end if;
  if child_grade not between 1 and 6 then
    raise exception 'Grade must be between 1 and 6';
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

  insert into public.children (family_id, nickname, grade)
  values (created_family_id, btrim(child_nickname), child_grade)
  returning id into created_child_id;

  insert into public.wallets (child_id) values (created_child_id);
  return created_family_id;
end;
$$;

revoke all on function public.onboard_family(text, text, text, smallint) from public;
grant execute on function public.onboard_family(text, text, text, smallint) to authenticated;

create or replace function public.create_child(
  target_family_id uuid,
  child_nickname text,
  child_grade smallint
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  created_child_id uuid;
begin
  if not public.is_family_admin(target_family_id) then
    raise exception 'Family administrator required';
  end if;
  if nullif(btrim(child_nickname), '') is null then
    raise exception 'Child nickname is required';
  end if;
  if child_grade not between 1 and 6 then
    raise exception 'Grade must be between 1 and 6';
  end if;

  insert into public.children (family_id, nickname, grade)
  values (target_family_id, btrim(child_nickname), child_grade)
  returning id into created_child_id;
  insert into public.wallets (child_id) values (created_child_id);
  return created_child_id;
end;
$$;

revoke all on function public.create_child(uuid, text, smallint) from public;
grant execute on function public.create_child(uuid, text, smallint) to authenticated;

create or replace function public.update_child(
  target_child_id uuid,
  child_nickname text,
  child_grade smallint
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_family_id uuid;
begin
  select family_id into target_family_id from public.children where id = target_child_id;
  if not public.is_family_admin(target_family_id) then
    raise exception 'Family administrator required';
  end if;
  if nullif(btrim(child_nickname), '') is null or child_grade not between 1 and 6 then
    raise exception 'Invalid child profile';
  end if;

  update public.children
  set nickname = btrim(child_nickname), grade = child_grade
  where id = target_child_id;
end;
$$;

revoke all on function public.update_child(uuid, text, smallint) from public;
grant execute on function public.update_child(uuid, text, smallint) to authenticated;

create or replace function public.delete_child(target_child_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_family_id uuid;
begin
  select family_id into target_family_id from public.children where id = target_child_id;
  if not public.is_family_admin(target_family_id) then
    raise exception 'Family administrator required';
  end if;
  if (select count(*) from public.children where family_id = target_family_id) <= 1 then
    raise exception 'A family must keep at least one child profile';
  end if;
  delete from public.children where id = target_child_id;
end;
$$;

revoke all on function public.delete_child(uuid) from public;
grant execute on function public.delete_child(uuid) to authenticated;
