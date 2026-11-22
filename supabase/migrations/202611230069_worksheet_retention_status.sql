create view public.worksheet_job_history with (security_invoker = true) as
select id, child_id, created_at, config, status, progress, pages, attempts,
       error_code, pdf_path, byte_size, sha256, expires_at, expires_at <= now() as is_expired
from public.worksheet_jobs;

revoke all on public.worksheet_job_history from public, anon, authenticated, service_role;
grant select on public.worksheet_job_history to authenticated;
