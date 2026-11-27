create table public.worksheet_jobs (
  id uuid primary key,
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  owner_id uuid not null references auth.users(id),
  config jsonb not null,
  question_ids uuid[] not null,
  status text not null default 'queued' check(status in ('queued','running','ready','failed','deleting','deleted')),
  pdf_path text not null unique,
  lease_token uuid,
  completed_lease_token uuid,
  lease_until timestamptz,
  attempts integer not null default 0,
  progress integer not null default 0 check(progress between 0 and 100),
  pages integer,
  byte_size bigint,
  sha256 text,
  renderer_version text not null default 'a4-v1',
  error_code text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '30 days'
);
create table public.worksheet_items (
  worksheet_id uuid not null references public.worksheet_jobs(id) on delete cascade,
  sequence integer not null,
  question_id uuid not null,
  prompt text not null,
  subject text not null,
  review_kind text not null,
  pronunciation_context text not null,
  question_version bigint not null,
  accepted_answers text[] not null,
  explanation text not null,
  primary key(worksheet_id,sequence),unique(worksheet_id,question_id)
);
alter table public.worksheet_jobs enable row level security;
alter table public.worksheet_items enable row level security;
revoke all on public.worksheet_jobs,public.worksheet_items from public,anon,authenticated;
grant select on public.worksheet_jobs to authenticated;
grant select on public.worksheet_jobs,public.worksheet_items to service_role;
create policy worksheet_parent_read on public.worksheet_jobs for select to authenticated using(public.can_manage_family(family_id));
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  values('worksheets','worksheets',false,20971520,array['application/pdf']) on conflict(id) do update set public=false;
create policy worksheet_pdf_parent_read on storage.objects for select to authenticated using(
  bucket_id='worksheets' and exists(select 1 from public.worksheet_jobs j where pdf_path=name
    and status='ready' and expires_at>now() and public.can_manage_family(family_id)
    and not exists(select 1 from unnest(j.question_ids) source(id)
      left join public.wrong_questions w on w.id=source.id
      where w.id is null or w.deleting)));

create function public.request_worksheet(target_child_id uuid, question_ids uuid[], config jsonb, request_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare family uuid; normalized jsonb; existing public.worksheet_jobs; flag text;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if request_id is null or cardinality(question_ids) is null or cardinality(question_ids) not between 1 and 100
    or array_position(question_ids,null) is not null
    or cardinality(question_ids)<>(select count(distinct id) from unnest(question_ids) id)
    or jsonb_typeof(config) is distinct from 'object' then raise exception '请选择1至100道不重复的题目'; end if;
  foreach flag in array array['include_questions','include_answers','include_explanations'] loop
    if config ? flag and jsonb_typeof(config->flag)<>'boolean' then raise exception '版面开关必须为布尔值'; end if;
  end loop;
  normalized:=jsonb_build_object('title',btrim(coalesce(config->>'title','学习星球练习卷')),
    'orientation',coalesce(config->>'orientation','portrait'),'margin_mm',coalesce((config->>'margin_mm')::integer,12),
    'blank_lines',coalesce((config->>'blank_lines')::integer,3),'repeats',coalesce((config->>'repeats')::integer,1),
    'pinyin_mode',coalesce(config->>'pinyin_mode','word_to_pinyin'),'grid',coalesce(config->>'grid','both'),
    'include_questions',coalesce((config->>'include_questions')::boolean,true),
    'include_answers',coalesce((config->>'include_answers')::boolean,false),
    'include_explanations',coalesce((config->>'include_explanations')::boolean,false));
  if length(normalized->>'title') not between 1 and 60 or normalized->>'orientation' not in ('portrait','landscape')
    or (normalized->>'margin_mm')::integer not between 12 and 25 or (normalized->>'blank_lines')::integer not between 0 and 12
    or (normalized->>'repeats')::integer not between 1 and 5 or normalized->>'pinyin_mode' not in ('word_to_pinyin','pinyin_to_word','mixed')
    or normalized->>'grid' not in ('four_lines','tianzige','both','none')
    or not ((normalized->>'include_questions')::boolean or (normalized->>'include_answers')::boolean or (normalized->>'include_explanations')::boolean) then
    raise exception '无效A4配置，边距至少12mm'; end if;
  perform pg_advisory_xact_lock(hashtextextended('worksheet:'||request_id::text,0));
  select * into existing from public.worksheet_jobs where id=request_id;
  if found then
    if existing.child_id<>target_child_id or existing.owner_id<>auth.uid() or existing.question_ids<>question_ids or existing.config<>normalized then
      raise exception '组卷标识已用于其他内容'; end if;
    return request_id;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id::text,0));
  if exists(select 1 from unnest(question_ids) chosen(id) where not exists(select 1 from public.wrong_questions w
    join public.wrong_question_answers a on a.question_id=w.id where w.id=chosen.id and w.child_id=target_child_id and not w.deleting)) then
    raise exception '题目属于其他孩子、已删除或缺少标准答案'; end if;
  if (select count(*) from public.worksheet_jobs where owner_id=auth.uid() and created_at>now()-interval '1 day')>=50 then
    raise exception '今日组卷已达50次，请明日再试'; end if;
  insert into public.worksheet_jobs(id,family_id,child_id,owner_id,config,question_ids,pdf_path)
    values(request_id,family,target_child_id,auth.uid(),normalized,question_ids,family::text||'/'||request_id::text||'/worksheet.pdf');
  insert into public.worksheet_items(worksheet_id,sequence,question_id,prompt,subject,review_kind,pronunciation_context,question_version,accepted_answers,explanation)
    select request_id,ids.sequence,w.id,w.final_text,w.subject,w.review_kind,w.pronunciation_context,w.content_version,a.accepted_answers,a.explanation
    from unnest(question_ids) with ordinality ids(id,sequence) join public.wrong_questions w on w.id=ids.id
    join public.wrong_question_answers a on a.question_id=w.id where w.child_id=target_child_id and not w.deleting;
  if (select count(*) from public.worksheet_items where worksheet_id=request_id)<>cardinality(question_ids) then raise exception '题目快照不完整'; end if;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'worksheet.request','worksheet',request_id::text,jsonb_build_object('count',cardinality(question_ids)));
  return request_id;
end $$;

create function public.claim_worksheet(target_worksheet_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.worksheet_jobs; token uuid; items jsonb;
begin
  select * into job from public.worksheet_jobs where id=target_worksheet_id for update;
  if not found then raise exception '组卷不存在'; end if;
  if coalesce(auth.role(),'')<>'service_role' then perform public.require_parent_authorization(job.family_id); end if;
  if job.status='ready' and job.expires_at>now() then return jsonb_build_object('id',job.id,'status','ready'); end if;
  if job.status in ('deleting','deleted') or job.expires_at<=now() then raise exception '组卷已删除或过期'; end if;
  if job.status='running' and job.lease_until>now() then return jsonb_build_object('id',job.id,'status','running'); end if;
  if exists(select 1 from public.worksheet_items i left join public.wrong_questions w on w.id=i.question_id
    where i.worksheet_id=job.id and (w.id is null or w.deleting)) then raise exception '源题正在或已经永久删除，禁止生成'; end if;
  token:=gen_random_uuid();
  update public.worksheet_jobs set status='running',lease_token=token,lease_until=now()+interval '5 minutes',
    attempts=attempts+1,progress=5,error_code=null where id=job.id;
  select jsonb_agg(to_jsonb(i) order by sequence) into items from public.worksheet_items i where worksheet_id=job.id;
  return jsonb_build_object('id',job.id,'status','claimed','lease_token',token,'pdf_path',job.pdf_path,
    'snapshot',jsonb_build_object('id',job.id,'created_at',job.created_at,'config',job.config,'items',items));
end $$;

create function public.update_worksheet_progress(target_worksheet_id uuid, token uuid, percentage integer) returns void
language plpgsql security definer set search_path='' as $$
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Trusted PDF worker required' using errcode='42501'; end if;
  if percentage not between 5 and 95 then raise exception 'Invalid progress'; end if;
  update public.worksheet_jobs set progress=greatest(progress,percentage) where id=target_worksheet_id
    and status='running' and lease_token=token and lease_until>now() and expires_at>now();
  if not found then raise exception 'PDF生成租约已失效'; end if;
end $$;

create function public.finish_worksheet(target_worksheet_id uuid, token uuid, result jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare job public.worksheet_jobs;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Trusted PDF worker required' using errcode='42501'; end if;
  select * into job from public.worksheet_jobs where id=target_worksheet_id for update;
  if job.status='ready' and job.completed_lease_token=token and job.sha256=result->>'sha256' then return; end if;
  if not found or job.status<>'running' or job.lease_token is distinct from token or job.lease_until<=now() or job.expires_at<=now() then raise exception 'PDF生成租约已失效'; end if;
  if result->>'error_code' is not null then
    update public.worksheet_jobs set status='failed',error_code=left(result->>'error_code',80),lease_token=null,lease_until=null where id=job.id;
    return;
  end if;
  if result->>'pages' is null or result->>'byte_size' is null or result->>'sha256' is null
    or (result->>'pages')::integer not between 1 and 1000 or (result->>'byte_size')::bigint not between 1 and 20971520
    or result->>'sha256' !~ '^[a-f0-9]{64}$' or result->>'renderer_version' is distinct from job.renderer_version
    or not exists(select 1 from storage.objects where bucket_id='worksheets' and name=job.pdf_path) then raise exception 'PDF结果未验证或文件尚未上传'; end if;
  update public.worksheet_jobs set status='ready',progress=100,pages=(result->>'pages')::integer,byte_size=(result->>'byte_size')::bigint,
    sha256=result->>'sha256',completed_lease_token=token,lease_token=null,lease_until=null,error_code=null where id=job.id;
end $$;
revoke all on function public.request_worksheet(uuid,uuid[],jsonb,uuid),public.claim_worksheet(uuid),public.update_worksheet_progress(uuid,uuid,integer),public.finish_worksheet(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.request_worksheet(uuid,uuid[],jsonb,uuid),public.claim_worksheet(uuid) to authenticated;
grant execute on function public.claim_worksheet(uuid),public.update_worksheet_progress(uuid,uuid,integer),public.finish_worksheet(uuid,uuid,jsonb) to service_role;

create or replace function public.guard_child_media_delete() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.cleanup_jobs where child_id=old.id and status<>'completed')
    or exists(select 1 from public.question_ocr_drafts d join storage.objects o
      on o.bucket_id='wrong-question-images' and o.name in (d.original_path,d.processed_path) where d.child_id=old.id)
    or exists(select 1 from public.worksheet_jobs j where j.child_id=old.id and
      (j.status<>'deleted' or exists(select 1 from storage.objects o where o.bucket_id='worksheets' and o.name=j.pdf_path))) then
    raise exception '请先完成该孩子的图片和PDF永久清理，再删除档案';
  end if;
  return old;
end $$;
