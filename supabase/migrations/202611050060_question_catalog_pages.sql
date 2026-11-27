-- Bounded public question metadata; grading keys remain in their private table.
create index question_catalog_page_idx on public.wrong_questions(child_id,review_kind,archived,review_due_at,id) where not deleting;
create function public.question_catalog_page(target_child_id uuid,filters jsonb,cursor jsonb default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare family uuid; rows jsonb; last_row jsonb; after_id uuid; after_archived boolean; after_due timestamptz; keyword text;
begin
  select family_id into family from public.children where id=target_child_id;
  if not coalesce(public.child_is_visible(target_child_id),false) then raise exception 'Child access required' using errcode='42501'; end if;
  if jsonb_typeof(filters) is distinct from 'object' or filters-array['kind','subject','mastery','archive','keyword']<>'{}'::jsonb
    or filters->>'kind' is null or filters->>'kind' not in ('question','pinyin')
    or filters->>'subject' is null or filters->>'subject' not in ('all','math','chinese','english')
    or filters->>'mastery' is null or filters->>'mastery' not in ('all','unmastered','practicing','review_due','mastered')
    or filters->>'archive' is null or filters->>'archive' not in ('all','active','archived')
    or jsonb_typeof(filters->'keyword') is distinct from 'string' or char_length(filters->>'keyword')>100 then
    raise exception 'Invalid question filters' using errcode='22023'; end if;
  keyword:=lower(btrim(filters->>'keyword'));
  if cursor is not null then
    if jsonb_typeof(cursor) is distinct from 'object' or cursor-array['id','archived','due_at']<>'{}'::jsonb
      or jsonb_typeof(cursor->'id') is distinct from 'string' or jsonb_typeof(cursor->'archived') is distinct from 'boolean'
      or not cursor ? 'due_at' or jsonb_typeof(cursor->'due_at') not in ('null','string') then raise exception 'Invalid cursor' using errcode='22023'; end if;
    after_id:=(cursor->>'id')::uuid;after_archived:=(cursor->>'archived')::boolean;after_due:=(cursor->>'due_at')::timestamptz;
    if after_id is null or after_due is not null and not isfinite(after_due) then raise exception 'Invalid cursor' using errcode='22023'; end if;
  end if;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.archived,q.review_due_at nulls last,q.id),'[]') into rows from (
    select w.* from public.wrong_questions w where w.child_id=target_child_id and not w.deleting
      and w.review_kind=filters->>'kind'
      and (filters->>'subject'='all' or w.subject=filters->>'subject')
      and (filters->>'mastery'='all' or w.mastery_status::text=filters->>'mastery')
      and (filters->>'archive'='all' or w.archived=(filters->>'archive'='archived'))
      and (keyword='' or position(keyword in lower(concat_ws(' ',w.final_text,w.knowledge_point,w.pronunciation_context,w.error_reason,
        (select string_agg(case tag when 'reading' then '审题' when 'concept' then '概念' when 'calculation' then '计算' when 'handwriting' then '书写' when 'memory' then '记忆' when 'other' then '其他' end,' ') from unnest(w.error_reason_tags) tag))))>0)
      and (after_id is null or w.archived>after_archived or w.archived=after_archived and (
        after_due is null and w.review_due_at is null and w.id>after_id
        or after_due is not null and (w.review_due_at is null or w.review_due_at>after_due or w.review_due_at=after_due and w.id>after_id)))
    order by w.archived,w.review_due_at nulls last,w.id limit 51) q;
  last_row:=rows->49;
  return jsonb_build_object('owner_id',auth.uid(),'child_id',target_child_id,'family_id',family,'filters',filters,'server_time',clock_timestamp(),
    'items',(select coalesce(jsonb_agg(value order by ordinal),'[]') from jsonb_array_elements(rows) with ordinality e(value,ordinal) where ordinal<=50),
    'next_cursor',case when jsonb_array_length(rows)>50 then jsonb_build_object('id',last_row->>'id','archived',last_row->'archived','due_at',last_row->'review_due_at') else null end);
end $$;
revoke all on function public.question_catalog_page(uuid,jsonb,jsonb) from public,anon,service_role;
grant execute on function public.question_catalog_page(uuid,jsonb,jsonb) to authenticated;
