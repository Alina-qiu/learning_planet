-- Reviewed target only: migration045 + deployed parent-push + configured HMS/APNs.
-- This script is never run by the mobile app or the local test suite.
do $$ begin
  if not exists(select 1 from pg_extension where extname='pg_cron')
    or not exists(select 1 from pg_extension where extname='pg_net')
    or to_regclass('vault.decrypted_secrets') is null then
    raise exception 'Enable pg_cron, pg_net and Supabase Vault first';
  end if;
end $$;
create or replace function public.dispatch_parent_push() returns bigint
language plpgsql security definer set search_path='' as $$
declare base_url text; worker_key text; request_id bigint;
begin
  select decrypted_secret into base_url from vault.decrypted_secrets where name='learning_planet_project_url';
  select decrypted_secret into worker_key from vault.decrypted_secrets where name='learning_planet_cleanup_worker_key';
  if base_url is null or base_url !~ '^https://[a-z0-9-]+[.]supabase[.]co$' or nullif(worker_key,'') is null then
    raise exception 'Configure reviewed project URL and worker credential in Vault';
  end if;
  select net.http_post(url=>base_url||'/functions/v1/parent-push',
    headers=>jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||worker_key),
    body=>'{"mode":"drain"}'::jsonb,timeout_milliseconds=>10000) into request_id;
  return request_id;
end $$;
revoke all on function public.dispatch_parent_push() from public,anon,authenticated,service_role;
do $$ declare job bigint; begin
  for job in select jobid from cron.job where jobname in ('learning-planet-parent-push','learning-planet-parent-push-retention') loop
    perform cron.unschedule(job); end loop;
  perform cron.schedule('learning-planet-parent-push','* * * * *','select public.dispatch_parent_push();');
  perform cron.schedule('learning-planet-parent-push-retention','31 3 * * *','select public.purge_parent_push();');
end $$;
