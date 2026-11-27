-- The original manifest stays intact until finalization. Existing leases continue
-- to use the original whole-manifest protocol during a rolling deployment.
alter table public.cleanup_jobs
  add column verified_files integer not null default 0 check (verified_files >= 0),
  add column file_batch_lease uuid,
  add column file_batch_size integer check (file_batch_size between 1 and 32);
alter table public.account_deletion_jobs
  add column verified_files integer not null default 0 check (verified_files >= 0),
  add column file_batch_lease uuid,
  add column file_batch_size integer check (file_batch_size between 1 and 32);

create function public.cleanup_progress_table(job_kind text) returns regclass
language plpgsql immutable set search_path='' as $$
begin
  case job_kind
    when 'cleanup' then return 'public.cleanup_jobs'::regclass;
    when 'account' then return 'public.account_deletion_jobs'::regclass;
    else raise exception 'Unknown deletion job kind';
  end case;
end $$;

create function public.cleanup_file_page(items jsonb, first_index integer, page_size integer) returns jsonb
language sql immutable strict set search_path='' as $$
  select coalesce(jsonb_agg(items->i order by i),'[]'::jsonb)
  from generate_series(first_index,least(jsonb_array_length(items),first_index+page_size)-1) i;
$$;

create function public.open_cleanup_batch(job_kind text, claim jsonb, batch_size integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  target regclass := public.cleanup_progress_table(job_kind);
  items jsonb := claim->'manifest';
  job_id uuid := (claim->>'id')::uuid;
  token uuid := (claim->>'lease_token')::uuid;
  cursor_at integer;
  previous_size integer;
begin
  if batch_size is null or batch_size not between 1 and 32 then raise exception 'Invalid cleanup batch size'; end if;
  if claim->>'status' <> 'claimed' then return claim; end if;
  -- The existing single-argument claim has already taken the row lock and
  -- enforced the PIN, ownership, dependencies and earliest run time.
  execute format('select verified_files,file_batch_size from %s where id=$1',target)
    into strict cursor_at,previous_size using job_id;
  -- An interrupted/failed lease may be on a slow Storage connection. Reduce
  -- its first retry page, down to one object, so one long page cannot starve it.
  -- A voluntary yield clears the old size and resumes with a full page.
  if previous_size is not null then batch_size := least(batch_size,greatest(1,previous_size/2)); end if;
  if cursor_at > 0 then
    -- A privileged or delayed upload may have restored a previously absent file.
    select coalesce(min(p.n-1)::integer,cursor_at) into cursor_at
      from jsonb_array_elements(items) with ordinality p(file,n)
      join storage.objects o on o.bucket_id=p.file->>'bucket' and o.name=p.file->>'path'
      where p.n <= cursor_at;
  end if;
  execute format('update %s set verified_files=$2,file_batch_lease=$3,file_batch_size=$4 where id=$1',target)
    using job_id,cursor_at,token,batch_size;
  return (claim-'manifest') || jsonb_build_object('file_offset',cursor_at,'file_total',jsonb_array_length(items),
    'manifest',public.cleanup_file_page(items,cursor_at,batch_size));
end $$;

create function public.claim_cleanup_job(target_job_id uuid,batch_size integer) returns jsonb
language sql security definer set search_path='' as $$
  select public.open_cleanup_batch('cleanup',public.claim_cleanup_job(target_job_id),batch_size);
$$;
create function public.claim_account_deletion(target_job_id uuid,batch_size integer) returns jsonb
language sql security definer set search_path='' as $$
  select public.open_cleanup_batch('account',public.claim_account_deletion(target_job_id),batch_size);
$$;

-- Only the trusted worker reports a whole page after removing and individually
-- verifying it through Storage. SQL independently checks the object metadata.
create function public.confirm_cleanup_batch(job_kind text,target_job_id uuid,token uuid,file_offset integer,
  files jsonb,yield_lease boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  target regclass := public.cleanup_progress_table(job_kind);
  job record;
  cursor_at integer;
  total integer;
  page_end integer;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Trusted worker required' using errcode='42501'; end if;
  execute format('select status,lease_token,lease_until,file_batch_lease,file_batch_size,verified_files,manifest
    from %s where id=$1 for update',target) into strict job using target_job_id;
  if token is null or job.status<>'running' or job.lease_token is distinct from token or
    job.file_batch_lease is distinct from token or job.lease_until <= clock_timestamp() then raise exception 'Invalid deletion lease'; end if;
  cursor_at := job.verified_files;
  total := jsonb_array_length(job.manifest);
  if file_offset is null or file_offset < 0 or file_offset > cursor_at or file_offset >= total or
    files is distinct from public.cleanup_file_page(job.manifest,file_offset,job.file_batch_size) then
    raise exception 'Invalid cleanup page';
  end if;
  page_end := file_offset + jsonb_array_length(files);
  if file_offset < cursor_at then
    if page_end > cursor_at then raise exception 'Overlapping cleanup page'; end if;
    -- Lost HTTP response: replay returns the current page without renewing or
    -- rewinding the lease, and never releases a newer worker's claim.
  else
    if exists(select 1 from jsonb_array_elements(files) p join storage.objects o
      on o.bucket_id=p->>'bucket' and o.name=p->>'path') then raise exception 'File deletion not verified'; end if;
    if job.lease_until <= clock_timestamp() then raise exception 'Invalid deletion lease'; end if;
    cursor_at := page_end;
    if yield_lease and cursor_at < total then
      execute format('update %s set verified_files=$2,status=''queued'',next_attempt_at=clock_timestamp(),
        lease_token=null,lease_until=null,file_batch_lease=null,file_batch_size=null where id=$1',target)
        using target_job_id,cursor_at;
      return jsonb_build_object('id',target_job_id,'status','queued','file_offset',cursor_at,'file_total',total);
    end if;
    execute format('update %s set verified_files=$2,lease_until=clock_timestamp()+interval ''5 minutes'' where id=$1',target)
      using target_job_id,cursor_at;
  end if;
  return jsonb_build_object('id',target_job_id,'lease_token',token,'status','claimed','file_offset',cursor_at,
    'file_total',total,'manifest',public.cleanup_file_page(job.manifest,cursor_at,job.file_batch_size));
end $$;

create function public.require_cleanup_batch_complete(job_kind text,target_job_id uuid,token uuid) returns void
language plpgsql security definer set search_path='' as $$
declare job record;
begin
  execute format('select status,file_batch_lease,lease_until,verified_files,jsonb_array_length(manifest) as total
    from %s where id=$1 for update',public.cleanup_progress_table(job_kind)) into job using target_job_id;
  if job.status='running' and token=job.file_batch_lease and
    (job.lease_until <= clock_timestamp() or job.verified_files <> job.total) then
    raise exception 'File verification incomplete or lease expired'; end if;
end $$;

-- Preserve the existing DB, Storage and Auth finalization checks, including
-- legitimate whole-manifest leases belonging to an older deployed worker.
alter function public.finish_cleanup_job(uuid,uuid,text) rename to finish_cleanup_job_before_file_progress;
create function public.finish_cleanup_job(target_job_id uuid,token uuid,failure_code text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
  if failure_code is null then perform public.require_cleanup_batch_complete('cleanup',target_job_id,token); end if;
  perform public.finish_cleanup_job_before_file_progress(target_job_id,token,failure_code);
end $$;
alter function public.prepare_account_auth_deletion(uuid,uuid) rename to prepare_account_auth_before_file_progress;
create function public.prepare_account_auth_deletion(target_job_id uuid,token uuid) returns uuid
language plpgsql security definer set search_path='' as $$
begin
  perform public.require_cleanup_batch_complete('account',target_job_id,token);
  return public.prepare_account_auth_before_file_progress(target_job_id,token);
end $$;
alter function public.finish_account_deletion(uuid,uuid,text) rename to finish_account_deletion_before_file_progress;
create function public.finish_account_deletion(target_job_id uuid,token uuid,failure_code text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
  if failure_code is null then perform public.require_cleanup_batch_complete('account',target_job_id,token); end if;
  perform public.finish_account_deletion_before_file_progress(target_job_id,token,failure_code);
end $$;

create function public.clear_completed_cleanup_progress() returns trigger
language plpgsql set search_path='' as $$
begin
  new.verified_files := 0;
  new.file_batch_size := null;
  new.file_batch_lease := null;
  return new;
end $$;
create trigger cleanup_progress_completed before update of status on public.cleanup_jobs
  for each row when (new.status='completed') execute function public.clear_completed_cleanup_progress();
create trigger account_progress_completed before update of status on public.account_deletion_jobs
  for each row when (new.status='completed') execute function public.clear_completed_cleanup_progress();

-- A job that voluntarily yields becomes runnable now. Give jobs that have
-- already been waiting a turn before it consumes another full Edge budget.
create or replace function public.pending_cleanup_jobs() returns uuid[]
language plpgsql security definer set search_path='' as $$
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Trusted cleanup dispatcher required' using errcode='42501'; end if;
  return array(select id from public.cleanup_jobs where
    (status in ('queued','failed') and next_attempt_at<=now()) or (status='running' and lease_until<=now())
    order by case when status='running' then lease_until else next_attempt_at end,created_at,id limit 5);
end $$;

revoke all on function public.cleanup_progress_table(text),public.cleanup_file_page(jsonb,integer,integer),
  public.open_cleanup_batch(text,jsonb,integer),public.require_cleanup_batch_complete(text,uuid,uuid),
  public.clear_completed_cleanup_progress(),public.finish_cleanup_job_before_file_progress(uuid,uuid,text),
  public.prepare_account_auth_before_file_progress(uuid,uuid),public.finish_account_deletion_before_file_progress(uuid,uuid,text),
  public.claim_cleanup_job(uuid,integer),public.claim_account_deletion(uuid,integer),
  public.confirm_cleanup_batch(text,uuid,uuid,integer,jsonb,boolean),public.finish_cleanup_job(uuid,uuid,text),
  public.prepare_account_auth_deletion(uuid,uuid),public.finish_account_deletion(uuid,uuid,text)
  from public,anon,authenticated,service_role;
grant execute on function public.claim_cleanup_job(uuid,integer) to authenticated,service_role;
grant execute on function public.claim_account_deletion(uuid,integer),public.confirm_cleanup_batch(text,uuid,uuid,integer,jsonb,boolean),
  public.finish_cleanup_job(uuid,uuid,text),public.prepare_account_auth_deletion(uuid,uuid),
  public.finish_account_deletion(uuid,uuid,text) to service_role;
