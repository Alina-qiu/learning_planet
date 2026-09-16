-- Run only in the intended Supabase environment after reviewing the migration.
create extension if not exists pg_cron;
select cron.schedule('learning-planet-task-maintenance','*/5 * * * *',
  'select public.run_task_maintenance();');
