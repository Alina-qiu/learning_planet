-- One stable statement captures all sections from the same PostgreSQL snapshot.
-- Only trusted RPCs below may call this helper; it exposes private answer data.
create function public.child_export_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_agg(value order by value->>'name') from (
  select jsonb_build_object('name','child_profile',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.children'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.id) from public.children t where t.id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','task_templates',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.task_templates'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from public.task_templates t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','tasks',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.task_instances'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.due_date,t.id) from public.task_instances t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','long_plans',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.long_plans'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.id) from public.long_plans t where exists(select 1 from public.task_templates tt where tt.id=t.template_id and tt.child_id=target_child_id)),'[]')) as value
  union all
  select jsonb_build_object('name','plan_leaves',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.plan_leaves'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.plan_id,t.leave_date) from public.plan_leaves t where exists(select 1 from public.long_plans p join public.task_templates tt on tt.id=p.template_id where p.id=t.plan_id and tt.child_id=target_child_id)),'[]')) as value
  union all
  select jsonb_build_object('name','plan_stage_rewards',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.plan_stage_rewards'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.plan_id,t.completed_count) from public.plan_stage_rewards t where exists(select 1 from public.long_plans p join public.task_templates tt on tt.id=p.template_id where p.id=t.plan_id and tt.child_id=target_child_id)),'[]')) as value
  union all
  select jsonb_build_object('name','plan_bonus_tiers',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.plan_bonus_tiers'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.plan_id,t.minimum_rate) from public.plan_bonus_tiers t where exists(select 1 from public.long_plans p join public.task_templates tt on tt.id=p.template_id where p.id=t.plan_id and tt.child_id=target_child_id)),'[]')) as value
  union all
  select jsonb_build_object('name','wallet',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.wallets'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.child_id) from public.wallets t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','wallet_settings',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.wallet_settings'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.child_id) from public.wallet_settings t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','ledger',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.ledger_entries'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from public.ledger_entries t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','pending_coins',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.pending_coin_awards'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from public.pending_coin_awards t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','wrong_questions',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.wrong_questions'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from public.wrong_questions t where t.child_id=target_child_id and not t.deleting),'[]')) as value
  union all
  select jsonb_build_object('name','question_answers',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.wrong_question_answers'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.question_id) from public.wrong_question_answers t where exists(select 1 from public.wrong_questions q where q.id=t.question_id and q.child_id=target_child_id and not q.deleting)),'[]')) as value
  union all
  select jsonb_build_object('name','review_items',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.task_review_items'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.task_instance_id,t.sequence) from public.task_review_items t where exists(select 1 from public.task_instances ti where ti.id=t.task_instance_id and ti.child_id=target_child_id)),'[]')) as value
  union all
  select jsonb_build_object('name','review_answer_keys',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.task_review_answer_keys'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.task_id,t.question_id) from public.task_review_answer_keys t where exists(select 1 from public.task_instances ti where ti.id=t.task_id and ti.child_id=target_child_id)),'[]')) as value
  union all
  select jsonb_build_object('name','ocr_records',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.question_ocr_drafts'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from public.question_ocr_drafts t where t.child_id=target_child_id and not t.deleting and (t.question_id is not null or t.owner_id=auth.uid())),'[]')) as value
  union all
  select jsonb_build_object('name','family_rewards',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.rewards'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from public.rewards t where exists(select 1 from public.children c where c.id=target_child_id and c.family_id=t.family_id)),'[]')) as value
  union all
  select jsonb_build_object('name','redemptions',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.redemptions'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from public.redemptions t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','learning_events',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.learning_events'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from public.learning_events t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','checkin_days',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.child_checkin_days'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.day) from public.child_checkin_days t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','streak_awards',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.child_streak_awards'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.milestone) from public.child_streak_awards t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','growth_assets',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.child_growth_assets'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.asset_key) from public.child_growth_assets t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','growth_profile',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.child_growth_profiles'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.child_id) from public.child_growth_profiles t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','reminder_settings',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.reminder_settings'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.child_id) from public.reminder_settings t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','reminder_receipts',
    'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a
      where a.attrelid='public.reminder_receipts'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.reminder_key) from public.reminder_receipts t where t.child_id=target_child_id),'[]')) as value
  union all
  select jsonb_build_object('name','image_index','columns',jsonb_build_array('draft_id','question_id','variant','bucket','path','present'),
    'rows',coalesce((select jsonb_agg(to_jsonb(m) order by m.draft_id,m.variant) from (
      select d.id as draft_id,d.question_id,v.variant,'wrong-question-images'::text as bucket,v.path,
        exists(select 1 from storage.objects o where o.bucket_id='wrong-question-images' and o.name=v.path) as present
      from public.question_ocr_drafts d cross join lateral (values ('original',case when d.original_deleted_at is null then d.original_path end),('processed',d.processed_path)) v(variant,path)
      where d.child_id=target_child_id and not d.deleting and (d.question_id is not null or d.owner_id=auth.uid()) and v.path is not null
    ) m),'[]'))
  union all
  select jsonb_build_object('name','worksheets','columns',jsonb_build_array('id','config','status','pdf_path','created_at','expires_at'),
    'rows',coalesce((select jsonb_agg(to_jsonb(w) order by w.created_at,w.id) from (
      select j.id,j.config,j.status,j.pdf_path,j.created_at,j.expires_at from public.worksheet_jobs j
      where j.child_id=target_child_id and j.status not in ('deleting','deleted') and j.expires_at>now()
    ) w),'[]'))
  union all
  select jsonb_build_object('name','worksheet_items','columns',(select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a where a.attrelid='public.worksheet_items'::regclass and a.attnum>0 and not a.attisdropped),
    'rows',coalesce((select jsonb_agg(to_jsonb(t) order by t.worksheet_id,t.sequence) from public.worksheet_items t join public.worksheet_jobs j on j.id=t.worksheet_id
      where j.child_id=target_child_id and j.status not in ('deleting','deleted') and j.expires_at>now()),'[]'))
  union all
  select jsonb_build_object('name','audit_logs','columns',jsonb_build_array('id','actor_user_id','action','target_type','target_id','details','created_at'),
    'rows',coalesce((select jsonb_agg(to_jsonb(a) order by a.id) from (
      select l.id,l.actor_user_id,l.action,l.target_type,l.target_id,l.details,l.created_at from public.audit_logs l
      where l.family_id=(select family_id from public.children where id=target_child_id)
        and (l.target_id=target_child_id::text
        or l.target_id in(select id::text from public.task_instances where child_id=target_child_id)
        or l.target_id in(select id::text from public.wrong_questions where child_id=target_child_id and not deleting)
        or l.target_id in(select id::text from public.redemptions where child_id=target_child_id)
        or l.target_id in(select id::text from public.learning_events where child_id=target_child_id))
    ) a),'[]'))
  ) sections;
$$;
revoke all on function public.child_export_source(uuid) from public,anon,authenticated,service_role;

create table public.child_export_jobs(
  id uuid primary key, child_id uuid not null references public.children(id) on delete cascade,
  family_id uuid not null references public.families(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade, session_id text not null,
  state text not null default 'ready' check(state in ('ready','closed','expired','revoked')),
  sections jsonb not null, created_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '15 minutes');
create unique index one_active_child_export on public.child_export_jobs(child_id,owner_id) where state='ready';
create table public.child_export_rows(
  export_id uuid not null references public.child_export_jobs(id) on delete cascade,
  section text not null, ordinal integer not null, data jsonb not null,
  primary key(export_id,section,ordinal));
alter table public.child_export_jobs enable row level security;
alter table public.child_export_rows enable row level security;
revoke all on public.child_export_jobs,public.child_export_rows from public,anon,authenticated,service_role;

create function public.require_child_export_admin(target_child_id uuid) returns uuid
language plpgsql stable security definer set search_path='' as $$
declare family uuid;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if not public.is_family_admin(family) then raise exception '仅家庭管理员可以导出孩子数据' using errcode='42501'; end if;
  if nullif(auth.jwt()->>'session_id','') is null then raise exception '需要有效登录会话' using errcode='42501'; end if;
  return family;
end $$;
revoke all on function public.require_child_export_admin(uuid) from public,anon,authenticated,service_role;

create function public.child_export_counts(source jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select jsonb_object_agg(s->>'name',jsonb_array_length(s->'rows')) from jsonb_array_elements(source) s;
$$;
revoke all on function public.child_export_counts(jsonb) from public,anon,authenticated,service_role;

create function public.preview_child_export(target_child_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  perform public.require_child_export_admin(target_child_id);
  if exists(select 1 from public.cleanup_jobs where child_id=target_child_id and status<>'completed') then
    raise exception '请先完成该孩子正在进行的数据清理'; end if;
  return jsonb_build_object('child_id',target_child_id,'counts',public.child_export_counts(public.child_export_source(target_child_id)),
    'includes_private_answers',true,'includes_image_files',false,'snapshot_minutes',15);
end $$;
revoke all on function public.preview_child_export(uuid) from public,anon;
grant execute on function public.preview_child_export(uuid) to authenticated;

create function public.child_export_manifest(target_export_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.child_export_jobs;
begin
  select * into job from public.child_export_jobs where id=target_export_id for share;
  if not found or job.owner_id is distinct from auth.uid() or job.session_id is distinct from auth.jwt()->>'session_id' then
    raise exception '导出会话不可用' using errcode='42501'; end if;
  perform public.require_child_export_admin(job.child_id);
  if job.state<>'ready' or job.expires_at<=now() then raise exception '导出已关闭、过期或因清理而失效，请重新预览'; end if;
  return jsonb_build_object('id',job.id,'child_id',job.child_id,'family_id',job.family_id,'schema_version',1,
    'sections',job.sections,'created_at',job.created_at,'expires_at',job.expires_at);
end $$;
revoke all on function public.child_export_manifest(uuid) from public,anon;
grant execute on function public.child_export_manifest(uuid) to authenticated;

create function public.prepare_child_export(target_child_id uuid, request_id uuid, expected_counts jsonb, confirmation text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare family uuid; previous public.child_export_jobs; source jsonb; item jsonb; manifest jsonb;
begin
  family:=public.require_child_export_admin(target_child_id);
  if request_id is null or confirmation is distinct from '导出孩子数据' then raise exception '请明确确认导出孩子数据'; end if;
  perform pg_advisory_xact_lock(hashtextextended('cleanup:'||target_child_id::text,0));
  select * into previous from public.child_export_jobs where id=request_id;
  if found then
    if previous.child_id<>target_child_id or previous.owner_id is distinct from auth.uid()
      or previous.session_id is distinct from auth.jwt()->>'session_id' then raise exception '请求标识已用于其他导出'; end if;
    return public.child_export_manifest(request_id);
  end if;
  if exists(select 1 from public.cleanup_jobs where child_id=target_child_id and status<>'completed') then
    raise exception '请先完成该孩子正在进行的数据清理'; end if;
  source:=public.child_export_source(target_child_id);
  if expected_counts is distinct from public.child_export_counts(source) then
    raise exception '数据数量已变化，请刷新范围并重新确认' using errcode='40001'; end if;
  -- Only one live copy for this parent/child. A fresh confirmation supersedes it.
  delete from public.child_export_rows where export_id in(select id from public.child_export_jobs
    where child_id=target_child_id and owner_id=auth.uid() and state='ready');
  update public.child_export_jobs set state='revoked' where child_id=target_child_id and owner_id=auth.uid() and state='ready';
  select jsonb_agg((s-'rows')||jsonb_build_object('count',jsonb_array_length(s->'rows')) order by s->>'name')
    into manifest from jsonb_array_elements(source) s;
  insert into public.child_export_jobs(id,child_id,family_id,owner_id,session_id,sections)
    values(request_id,target_child_id,family,auth.uid(),auth.jwt()->>'session_id',manifest);
  for item in select value from jsonb_array_elements(source) loop
    insert into public.child_export_rows(export_id,section,ordinal,data)
      select request_id,item->>'name',ordinality::integer,value from jsonb_array_elements(item->'rows') with ordinality;
  end loop;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'child_export.prepare','child',target_child_id::text,jsonb_build_object('export_id',request_id,'counts',expected_counts));
  return public.child_export_manifest(request_id);
end $$;
revoke all on function public.prepare_child_export(uuid,uuid,jsonb,text) from public,anon;
grant execute on function public.prepare_child_export(uuid,uuid,jsonb,text) to authenticated;

create function public.read_child_export_page(target_export_id uuid, section_name text, after_ordinal integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare manifest jsonb; total integer; records jsonb; last_ordinal integer;
begin
  manifest:=public.child_export_manifest(target_export_id);
  select (s->>'count')::integer into total from jsonb_array_elements(manifest->'sections') s where s->>'name'=section_name;
  if total is null or after_ordinal is null or after_ordinal<0 or after_ordinal>total then raise exception '无效导出分页'; end if;
  select coalesce(jsonb_agg(data order by ordinal),'[]'),coalesce(max(ordinal),after_ordinal) into records,last_ordinal from (
    select ordinal,data from (
      select ordinal,data,sum(octet_length(data::text)) over(order by ordinal) as bytes,row_number() over(order by ordinal) as position
      from (select ordinal,data from public.child_export_rows where export_id=target_export_id and section=section_name
        and ordinal>after_ordinal order by ordinal limit 250) bounded
    ) sized where bytes<=1048576 or position=1
  ) page;
  return jsonb_build_object('section',section_name,'rows',records,'next_ordinal',last_ordinal,'total',total,'done',last_ordinal=total);
end $$;
revoke all on function public.read_child_export_page(uuid,text,integer) from public,anon;
grant execute on function public.read_child_export_page(uuid,text,integer) to authenticated;

create function public.close_child_export(target_export_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare job public.child_export_jobs;
begin
  select * into job from public.child_export_jobs where id=target_export_id for update;
  if not found then return; end if;
  if job.owner_id is distinct from auth.uid() or job.session_id is distinct from auth.jwt()->>'session_id' then
    raise exception '导出会话不可用' using errcode='42501'; end if;
  -- Allow discarding sensitive data after PIN expiry. No reads are granted here.
  delete from public.child_export_rows where export_id=job.id;
  update public.child_export_jobs set state='closed' where id=job.id;
end $$;
revoke all on function public.close_child_export(uuid) from public,anon;
grant execute on function public.close_child_export(uuid) to authenticated;

create function public.invalidate_child_exports_on_cleanup() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('cleanup:'||new.child_id::text,0));
  update public.child_export_jobs set state='revoked' where child_id=new.child_id and state='ready';
  delete from public.child_export_rows where export_id in(select id from public.child_export_jobs where child_id=new.child_id);
  return new;
end $$;
create trigger invalidate_child_exports_on_cleanup before insert on public.cleanup_jobs
  for each row execute function public.invalidate_child_exports_on_cleanup();
revoke all on function public.invalidate_child_exports_on_cleanup() from public,anon,authenticated,service_role;

create function public.purge_expired_child_exports() returns integer
language plpgsql security definer set search_path='' as $$
declare removed integer;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Trusted maintenance required' using errcode='42501'; end if;
  update public.child_export_jobs set state='expired' where state='ready' and expires_at<=now();
  delete from public.child_export_rows where export_id in(select id from public.child_export_jobs where state<>'ready');
  get diagnostics removed=row_count;
  return removed;
end $$;
revoke all on function public.purge_expired_child_exports() from public,anon,authenticated;
grant execute on function public.purge_expired_child_exports() to service_role;

-- Cron runs without a user JWT. Keep the context switch in a non-client wrapper.
create function public.run_child_export_maintenance() returns integer
language plpgsql security definer set search_path='' as $$
declare previous text:=current_setting('request.jwt.claims',true); result integer;
begin
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  result:=public.purge_expired_child_exports();
  perform set_config('request.jwt.claims',coalesce(previous,''),true);
  return result;
exception when others then perform set_config('request.jwt.claims',coalesce(previous,''),true); raise;
end $$;
revoke all on function public.run_child_export_maintenance() from public,anon,authenticated;
grant execute on function public.run_child_export_maintenance() to service_role;
do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    perform cron.schedule('learning-planet-export-maintenance','* * * * *','select public.run_child_export_maintenance();');
  end if;
end $$;
