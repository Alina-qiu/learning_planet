-- Run after migration 037 in the target environment. Repeat without duplicates.
-- The application does not receive service-role access to these health counters.
create extension if not exists pg_cron with schema pg_catalog;
do $$ declare previous bigint; begin
  for previous in select jobid from cron.job where jobname='purge-runtime-diagnostics' loop
    perform cron.unschedule(previous);
  end loop;
end $$;
select cron.schedule('purge-runtime-diagnostics','17 3 * * *','select public.purge_runtime_diagnostics();');
-- Operators can inspect aggregates with: select public.runtime_health_report(7);
