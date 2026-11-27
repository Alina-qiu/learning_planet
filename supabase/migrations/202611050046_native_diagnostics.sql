-- Native OS diagnostic categories reuse exact seven-field validation, receipt
-- replay, per-account rate limits, deletion barriers and aggregate retention.
create or replace function public.valid_runtime_diagnostic(e jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare field text;
begin
  if jsonb_typeof(e) is distinct from 'object' or
    (select array_agg(k order by k) from jsonb_object_keys(e) k) is distinct from
      array['bucket','day','error','event_id','kind','operation','outcome'] then return false; end if;
  if jsonb_typeof(e->'event_id') is distinct from 'string' or
    (e->>'event_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or
    jsonb_typeof(e->'day') is distinct from 'string' or (e->>'day') !~ '^\d{4}-\d{2}-\d{2}$' or
    jsonb_typeof(e->'bucket') is distinct from 'number' or (e->>'bucket') !~ '^[0-6]$' then return false; end if;
  perform (e->>'day')::date;
  foreach field in array array['error','kind','operation','outcome'] loop
    if jsonb_typeof(e->field) is distinct from 'string' then return false; end if;
  end loop;
  if not (e->>'error'=any(array['none','state','format','type','range','unsupported','unknown'])) or
    not (e->>'outcome'=any(array['ok','client_error','server_error','network','timeout','cancelled','conflict','authorization','unexpected'])) then return false; end if;
  if e->>'kind'='api' then
    return coalesce(e->>'operation'=any(array['auth','database','storage','edge']),false);
  elsif e->>'kind'='sync' then
    return coalesce(e->>'operation'=any(array['tasks','reviews','images']),false);
  elsif e->>'kind'='runtime' then
    return coalesce(e->>'operation'=any(array['framework','async','startup']) and e->>'outcome'='unexpected' and e->>'bucket'='0',false);
  elsif e->>'kind'='native' then
    return coalesce(e->>'operation'=any(array['androidJavaCrash','androidNativeCrash','androidAnr','iosCrash','iosHang'])
      and e->>'outcome'='unexpected' and e->>'error'='none' and e->>'bucket'='0',false);
  end if;
  return false;
exception when others then return false;
end $$;
revoke all on function public.valid_runtime_diagnostic(jsonb) from public,anon,authenticated,service_role;
