-- Helpers for the hand-written Cedar specs (test/spec/d/5x_cedar_*.sql).
-- Public API only: they call permissions.cedar_* and read no tables.
create schema if not exists cedar_t;

-- A policy in Cedar's JSON format: scope all, one `when` (null: none).
create function cedar_t.policy(p_effect text, p_when jsonb default null, p_principal jsonb default '{"op": "All"}',
                               p_action jsonb default '{"op": "All"}', p_resource jsonb default '{"op": "All"}')
returns jsonb
language sql immutable
as $$
    select jsonb_build_object('effect', p_effect, 'principal', p_principal, 'action', p_action, 'resource', p_resource,
                              'conditions', case when p_when is null then '[]'::jsonb
                                                 else jsonb_build_array(jsonb_build_object('kind', 'when', 'body', p_when)) end)
$$;

-- An entity reference value in the EST: {"Value": {"__entity": ...}}.
create function cedar_t.uid(p_type text, p_id text)
returns jsonb
language sql immutable
as $$
    select jsonb_build_object('Value', jsonb_build_object('__entity', jsonb_build_object('type', p_type, 'id', p_id)))
$$;

-- One condition, evaluated for the request User::"alice", Action::"view",
-- Doc::"d1": 'true', 'false', or 'error: <message>'. The condition is put as
-- the only policy (id 'e') and deleted afterwards; other stored policies
-- would interfere, so the specs that use this keep none.
create function cedar_t.eval(p_body jsonb, p_context jsonb default null, p_entities jsonb default null,
                             p_principal text default 'User::"alice"', p_resource text default 'Doc::"d1"')
returns text
language plpgsql
as $$
declare
    r jsonb;
begin
    perform permissions.cedar_put_policy(policy_id => 'e', policy_json => cedar_t.policy('permit', p_body));
    r := permissions.cedar_is_authorized(principal => p_principal, action => 'Action::"view"', resource => p_resource,
                                         context => p_context, entities => p_entities);
    perform permissions.cedar_delete_policy(policy_id => 'e');
    return case when jsonb_array_length(r -> 'errors') > 0 then 'error: ' || (r #>> '{errors,0,message}')
                when r ->> 'decision' = 'allow' then 'true'
                else 'false' end;
end;
$$;

-- The same for a condition in Cedar text: permit (principal, action,
-- resource) when { <p_when> };
create function cedar_t.eval_text(p_when text, p_context jsonb default null, p_entities jsonb default null)
returns text
language plpgsql
as $$
declare
    r jsonb;
begin
    perform permissions.cedar_put_policy(policy_id => 'e', policy => 'permit (principal, action, resource) when { ' || p_when || ' };');
    r := permissions.cedar_is_authorized(principal => 'User::"alice"', action => 'Action::"view"', resource => 'Doc::"d1"',
                                         context => p_context, entities => p_entities);
    perform permissions.cedar_delete_policy(policy_id => 'e');
    return case when jsonb_array_length(r -> 'errors') > 0 then 'error: ' || (r #>> '{errors,0,message}')
                when r ->> 'decision' = 'allow' then 'true'
                else 'false' end;
end;
$$;

-- The decision, the reasons and the policy ids of the errors, as one line:
-- 'allow [p1, p2] errors []'.
create function cedar_t.authz(p_principal text, p_action text, p_resource text,
                              p_context jsonb default null, p_entities jsonb default null)
returns text
language sql
as $$
    select format('%s [%s] errors [%s]', r ->> 'decision',
                  (select string_agg(x, ', ') from jsonb_array_elements_text(r -> 'reasons') x),
                  (select string_agg(e ->> 'policy_id', ', ') from jsonb_array_elements(r -> 'errors') e))
    from (select permissions.cedar_is_authorized(principal => p_principal, action => p_action, resource => p_resource,
                                                 context => p_context, entities => p_entities) as r) x
$$;

-- The SQLSTATE and DETAIL of an error a statement raises ('' if none):
-- '22023 cedar:invalid_policy path=''$.effect'''.
create function cedar_t.err(p_sql text)
returns text
language plpgsql
as $$
declare
    st text;
    detail text;
begin
    execute p_sql;
    return '';
exception when others then
    get stacked diagnostics st = returned_sqlstate, detail = pg_exception_detail;
    return st || ' ' || coalesce(detail, '');
end;
$$;

-- The MESSAGE and HINT of an error a statement raises.
create function cedar_t.msg(p_sql text, out message text, out hint text)
language plpgsql
as $$
begin
    execute p_sql;
exception when others then
    get stacked diagnostics message = message_text, hint = pg_exception_hint;
end;
$$;
