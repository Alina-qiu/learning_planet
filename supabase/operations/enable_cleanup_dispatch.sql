-- Run only against a reviewed target after migration023 and both permanent-cleanup
-- and account-deletion Edge Functions have been deployed.
-- Configure Vault secrets via the dashboard; never paste the service key here.
-- learning_planet_project_url = https://<project-ref>.supabase.co (no trailing slash)
-- learning_planet_cleanup_worker_key = the project's legacy service_role key
do $$ begin
  if not exists(select 1 from pg_extension where extname='pg_cron')
    or not exists(select 1 from pg_extension where extname='pg_net') then
    raise exception 'Enable pg_cron and pg_net in the reviewed target project first';
  end if;
  if to_regclass('vault.decrypted_secrets') is null then raise exception 'Supabase Vault is required'; end if;
end $$;

create or replace function public.dispatch_cleanup_jobs() returns bigint
language plpgsql security definer set search_path='' as $$
declare base_url text; worker_key text; request_id bigint;
begin
  select decrypted_secret into base_url from vault.decrypted_secrets where name='learning_planet_project_url';
  select decrypted_secret into worker_key from vault.decrypted_secrets where name='learning_planet_cleanup_worker_key';
  if base_url is null or base_url !~ '^https://[a-z0-9-]+[.]supabase[.]co$' or nullif(worker_key,'') is null then
    raise exception 'Configure the reviewed project URL and worker credential in Vault';
  end if;
  select net.http_post(url => base_url||'/functions/v1/permanent-cleanup',
    headers => jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||worker_key),
    body => '{"mode":"drain"}'::jsonb,timeout_milliseconds => 10000) into request_id;
  perform net.http_post(url => base_url||'/functions/v1/account-deletion',
    headers => jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||worker_key),
    body => '{"mode":"drain"}'::jsonb,timeout_milliseconds => 10000);
  return request_id;
end $$;
revoke all on function public.dispatch_cleanup_jobs() from public,anon,authenticated,service_role;
do $$ declare job bigint; begin
  for job in select jobid from cron.job where jobname='learning-planet-cleanup' loop perform cron.unschedule(job); end loop;
  perform cron.schedule('learning-planet-cleanup','*/2 * * * *','select public.dispatch_cleanup_jobs();');
end $$;
