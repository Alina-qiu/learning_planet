-- Apply migration 044 first. Run only in the intended cloud environment.
create extension if not exists pg_cron with schema pg_catalog;
do $$ declare previous bigint; begin
  for previous in select jobid from cron.job where jobname='purge-configuration-intervals' loop
    perform cron.unschedule(previous);
  end loop;
end $$;
select cron.schedule('purge-configuration-intervals','23 3 * * *','select public.purge_configuration_intervals();');
