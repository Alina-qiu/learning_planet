-- Operational receipts contain only hashes and IDs, never a second copy of word/answer text.
create table public.pinyin_import_receipts(
  id uuid primary key,
  child_id uuid not null references public.children(id) on delete cascade,
  payload_hash text not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.pinyin_import_receipts enable row level security;
revoke all on public.pinyin_import_receipts from public,anon,authenticated;

create function public.import_pinyin_words(target_child_id uuid,request_id uuid,entries jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare family uuid; entry jsonb; answer jsonb; qid uuid; result jsonb; fingerprint text;
  receipt public.pinyin_import_receipts; added jsonb:='[]'; skipped jsonb:='[]'; ordinal integer:=0;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if request_id is null or jsonb_typeof(entries) is distinct from 'array' or jsonb_array_length(entries) not between 1 and 100
    or octet_length(entries::text)>262144 then raise exception '每次可导入1至100条词语，总内容不能超过256 KiB'; end if;
  perform 1 from public.families where id=family for key share;
  perform 1 from public.children where id=target_child_id for key share;
  if not found then raise exception 'Child access required' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('pinyin-import:'||request_id::text,0));
  fingerprint:=encode(sha256(convert_to(entries::text,'UTF8')),'hex');
  select * into receipt from public.pinyin_import_receipts where id=request_id;
  if found then
    if receipt.child_id<>target_child_id or receipt.payload_hash<>fingerprint then raise exception '导入请求已用于其他内容，请刷新确认结果' using errcode='22023'; end if;
    return receipt.result;
  end if;
  -- Match the existing edit/generation lock; a batch is all-or-nothing.
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id::text,0));
  for entry in select value from jsonb_array_elements(entries) loop
    ordinal:=ordinal+1;
    if jsonb_typeof(entry) is distinct from 'object' or entry->>'kind' is distinct from 'pinyin' or entry->>'subject' is distinct from 'chinese'
      or jsonb_typeof(entry->'prompt') is distinct from 'string' or length(btrim(entry->>'prompt')) not between 1 and 80
      or jsonb_typeof(entry->'context') is distinct from 'string' or length(btrim(entry->>'context')) not between 1 and 2000
      or entry->>'pronunciation_confirmed' is distinct from 'true' or jsonb_typeof(entry->'answers') is distinct from 'array'
      or jsonb_array_length(entry->'answers') not between 1 and 5 or length(coalesce(entry->>'knowledge_point',''))>200 then
      raise exception '第%条：请核对词语、语境和1至5个读音，并逐条确认',ordinal;
    end if;
    for answer in select value from jsonb_array_elements(entry->'answers') loop
      if jsonb_typeof(answer)<>'string' or length(btrim(answer#>>'{}')) not between 1 and 500 then raise exception '第%条：读音不能为空或超过500字',ordinal; end if;
      perform public.normalize_pinyin(answer#>>'{}');
    end loop;
    -- Do not silently overwrite a parent's pronunciation, mastery, archive or version.
    select id into qid from public.wrong_questions where child_id=target_child_id and review_kind='pinyin'
      and not deleting and final_text=btrim(entry->>'prompt') and pronunciation_context=btrim(entry->>'context') order by created_at,id limit 1;
    if found then
      skipped:=skipped||jsonb_build_array(jsonb_build_object('row',ordinal,'question_id',qid));
    else
      qid:=public.save_review_question(target_child_id,jsonb_build_object('kind','pinyin','subject','chinese',
        'prompt',btrim(entry->>'prompt'),'context',btrim(entry->>'context'),'answers',entry->'answers',
        'knowledge_point',coalesce(entry->>'knowledge_point',''),'pronunciation_confirmed',true));
      added:=added||jsonb_build_array(jsonb_build_object('row',ordinal,'question_id',qid));
    end if;
  end loop;
  result:=jsonb_build_object('request_id',request_id,'created',added,'skipped',skipped);
  insert into public.pinyin_import_receipts(id,child_id,payload_hash,result) values(request_id,target_child_id,fingerprint,result);
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'pinyin.import','child',target_child_id::text,
      jsonb_build_object('request_id',request_id,'created',jsonb_array_length(added),'skipped',jsonb_array_length(skipped)));
  return result;
end $$;
revoke all on function public.import_pinyin_words(uuid,uuid,jsonb) from public,anon;
grant execute on function public.import_pinyin_words(uuid,uuid,jsonb) to authenticated;
