alter table public.worksheet_jobs add column next_attempt_at timestamptz not null default now();

create function public.schedule_worksheet_retry() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.status='failed' and old.status is distinct from 'failed' then
    new.next_attempt_at:=now()+make_interval(secs=>least(21600,30*power(2,least(new.attempts,10)))::integer);
  end if;
  return new;
end $$;
create trigger worksheet_retry_schedule before update on public.worksheet_jobs
  for each row execute function public.schedule_worksheet_retry();
revoke all on function public.schedule_worksheet_retry() from public,anon,authenticated;

create function public.pending_worksheet_jobs() returns uuid[]
language plpgsql security definer set search_path='' as $$
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Trusted worksheet dispatcher required' using errcode='42501'; end if;
  -- One render per invocation bounds CPU/memory. Independent invocations safely
  -- compete for leases; a second caller sees running instead of duplicating work.
  return array(select j.id from public.worksheet_jobs j where j.expires_at>now()
    and ((j.status in ('queued','failed') and j.next_attempt_at<=now())
      or (j.status='running' and j.lease_until<=now()))
    and not exists(select 1 from unnest(j.question_ids) source(id)
      left join public.wrong_questions w on w.id=source.id where w.id is null or w.deleting)
    order by j.created_at,j.id limit 1);
end $$;
revoke all on function public.pending_worksheet_jobs() from public,anon,authenticated;
grant execute on function public.pending_worksheet_jobs() to service_role;
