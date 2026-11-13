-- Run only in the intended Supabase environment after reviewing the migration.
create extension if not exists pg_cron;
select cron.schedule('learning-planet-task-maintenance','*/5 * * * *',
  'select public.run_task_maintenance();');
-- Requires migration 011; family 00:05 cutoff is enforced inside the function.
select cron.schedule('learning-planet-review-maintenance','* * * * *',
  'select public.run_review_maintenance();');
-- Requires migration013. Refunds expired requests and unfulfilled approvals.
select cron.schedule('learning-planet-reward-maintenance','*/5 * * * *',
  'select public.run_reward_maintenance();');
-- Requires migration021. Erases abandoned export content after 15-minute expiry.
select cron.schedule('learning-planet-export-maintenance','* * * * *',
  'select public.run_child_export_maintenance();');
