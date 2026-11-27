-- Run after migration 038 in the target environment. Verify pg_cron timezone.
create extension if not exists pg_cron with schema pg_catalog;
do $$ declare previous bigint; begin
  for previous in select jobid from cron.job where jobname='purge-parent-notification-receipts' loop
    perform cron.unschedule(previous);
  end loop;
end $$;
select cron.schedule('purge-parent-notification-receipts','23 3 * * *',
  'select public.purge_parent_notification_receipts();');
