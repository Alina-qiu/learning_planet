-- Preserve the existing overview contract while making saved reads attributable.
alter function public.growth_overview(uuid) rename to growth_overview_before_snapshot;
revoke all on function public.growth_overview_before_snapshot(uuid) from public,anon,authenticated,service_role;
create function public.growth_overview(target_child_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare family uuid; result jsonb;
begin
  if not public.child_is_visible(target_child_id) then
    raise exception 'Child access required' using errcode='42501'; end if;
  select family_id into family from public.children where id=target_child_id;
  result:=public.growth_overview_before_snapshot(target_child_id);
  return result||jsonb_build_object('schema',1,'child_id',target_child_id,
    'family_id',family,'fetched_at',now());
end $$;
revoke all on function public.growth_overview(uuid) from public,anon,service_role;
grant execute on function public.growth_overview(uuid) to authenticated;
