-- A short-lived offline policy permits only generic LOCAL sync notices. It
-- cannot authorize reading reports, approving rewards or replaying commands.
alter function public.parent_notification_delivery(uuid) rename to parent_notification_delivery_before_offline;
revoke all on function public.parent_notification_delivery_before_offline(uuid) from public,anon,authenticated,service_role;
create function public.parent_notification_delivery(target_family_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; issued timestamptz:=clock_timestamp();
begin
  -- The existing function checks current account and family membership.
  result:=public.parent_notification_delivery_before_offline(target_family_id);
  return result||jsonb_build_object('offline_policy',jsonb_build_object(
    'schema',1,'purpose','local_sync_notice','family_id',target_family_id,
    'settings',result->'settings',
    'timezone',(select timezone from public.families where id=target_family_id),
    'child_ids',coalesce((select jsonb_agg(c.id order by c.id) from public.children c
      where c.family_id=target_family_id and public.child_is_visible(c.id)
        and not exists(select 1 from public.child_deletion_tombstones t where t.child_id=c.id)),'[]'::jsonb),
    'issued_at',issued,'expires_at',issued+interval '168 hours'));
end $$;
revoke all on function public.parent_notification_delivery(uuid) from public,anon,authenticated,service_role;
grant execute on function public.parent_notification_delivery(uuid) to authenticated;
