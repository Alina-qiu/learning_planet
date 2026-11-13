-- PRD 11: derive business metrics from authoritative records. OCR correction
-- is frozen at first confirmation; later question edits must not rewrite it.
alter table public.question_ocr_drafts
  add column metrics_confirmed_at timestamptz,
  add column metrics_ocr_fields smallint,
  add column metrics_corrected_fields smallint,
  add constraint ocr_confirmation_metrics_check check (
    (metrics_confirmed_at is null and metrics_ocr_fields is null and metrics_corrected_fields is null)
    or (metrics_confirmed_at is not null and metrics_ocr_fields is not null and metrics_corrected_fields is not null
      and metrics_ocr_fields between 0 and 1 and metrics_corrected_fields between 0 and metrics_ocr_fields)
  );

create function public.capture_ocr_confirmation_metrics() returns trigger
language plpgsql security definer set search_path='' as $$
declare confirmed text;
begin
  if tg_op='INSERT' then
    -- Existing/imported saved records have no reliable first-confirmation data.
    new.metrics_confirmed_at:=null;
    new.metrics_ocr_fields:=null;
    new.metrics_corrected_fields:=null;
  elsif old.status in ('recognized','manual') and new.status='saved'
      and old.question_id is null and new.question_id is not null then
    select final_text into confirmed from public.wrong_questions
      where id=new.question_id and child_id=new.child_id;
    if not found then raise exception 'OCR confirmation scope mismatch'; end if;
    new.metrics_confirmed_at:=now();
    -- The current OCR editor exposes one recognized field: the question text.
    -- Subject, answer, explanation and tags are manual fields, not OCR output.
    new.metrics_ocr_fields:=case when old.status='recognized' then 1 else 0 end;
    new.metrics_corrected_fields:=case when old.status='recognized'
      and btrim(old.raw_text) is distinct from btrim(confirmed) then 1 else 0 end;
  else
    new.metrics_confirmed_at:=old.metrics_confirmed_at;
    new.metrics_ocr_fields:=old.metrics_ocr_fields;
    new.metrics_corrected_fields:=old.metrics_corrected_fields;
  end if;
  return new;
end $$;
create trigger capture_ocr_confirmation_metrics before insert or update on public.question_ocr_drafts
  for each row execute function public.capture_ocr_confirmation_metrics();
revoke all on function public.capture_ocr_confirmation_metrics() from public,anon,authenticated,service_role;
create index ocr_confirmation_report_idx on public.question_ocr_drafts(child_id,metrics_confirmed_at)
  where metrics_confirmed_at is not null;
create index redemption_fulfillment_report_idx on public.redemptions(child_id,fulfilled_at)
  where status='fulfilled';

alter function public.learning_report(uuid,text,date) rename to learning_report_before_business_metrics;
revoke all on function public.learning_report_before_business_metrics(uuid,text,date) from public,anon,authenticated,service_role;
create function public.learning_report(target_child_id uuid, report_period text default 'week', anchor_date date default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare report jsonb; first_instant timestamptz; last_instant timestamptz;
  fulfillment jsonb; correction jsonb; income numeric; spent numeric;
begin
  -- The existing report checks the current session's parent PIN and dates.
  report:=public.learning_report_before_business_metrics(target_child_id,report_period,anchor_date);
  if not public.child_is_visible(target_child_id) then
    raise exception 'Child unavailable' using errcode='42501';
  end if;
  first_instant:=(report->>'start_date')::date::timestamp at time zone (report->>'timezone');
  last_instant:=((report->>'end_date')::date+1)::timestamp at time zone (report->>'timezone');
  income:=(report#>>'{coins,income}')::numeric;
  spent:=(report#>>'{coins,spent}')::numeric;

  -- Cohort: fulfilled in this period, including requests made earlier. Missing
  -- or backwards timestamps cannot be samples. Pending/rejected are not zero.
  select jsonb_build_object('samples',count(*),'median_seconds',
    round((percentile_cont(0.5) within group(order by extract(epoch from fulfilled_at-created_at)))::numeric,3))
    into fulfillment from public.redemptions where child_id=target_child_id and status='fulfilled'
      and fulfilled_at>=first_instant and fulfilled_at<last_instant and fulfilled_at>=created_at;
  fulfillment:=fulfillment||jsonb_build_object('open_requests',(
    select count(*) from public.redemptions where child_id=target_child_id and status in ('requested','approved')
      and created_at>=first_instant and created_at<last_instant));

  select jsonb_build_object('ocr_fields',coalesce(sum(metrics_ocr_fields),0),
    'corrected_fields',coalesce(sum(metrics_corrected_fields),0),
    'correction_rate',case when sum(metrics_ocr_fields)>0 then
      round(sum(metrics_corrected_fields)::numeric/sum(metrics_ocr_fields),4) else null end,
    'manual_records',count(*) filter(where metrics_ocr_fields=0)) into correction
    from public.question_ocr_drafts where child_id=target_child_id and status='saved' and not deleting
      and metrics_confirmed_at>=first_instant and metrics_confirmed_at<last_instant;
  correction:=correction||jsonb_build_object('unmeasured_saved_records',(
    select count(*) from public.question_ocr_drafts where child_id=target_child_id and status='saved'
      and not deleting and metrics_confirmed_at is null));

  return report||jsonb_build_object('business_metrics',jsonb_build_object(
    'version','business-v1','fulfillment',fulfillment,'ocr',correction,
    'coin_income_to_spent',case when spent>0 then round(income/spent,4) else null end));
end $$;
revoke all on function public.learning_report(uuid,text,date) from public,anon,authenticated,service_role;
grant execute on function public.learning_report(uuid,text,date) to authenticated;
