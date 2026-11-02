-- Helpers for the generated Cedar oracle specs (test/cedar/generate.py).
-- Included by every generated file with \ir ../../cedar/fixture.sql.
-- Public API only (test/README.md): no reads of permissions.* tables. The
-- parser oracle (--parse-est) is the exception: it calls the parser itself,
-- because the extension types cannot be put through the API before phases
-- 4a and 4b, and their policies must still parse to the CLI's EST.
create schema if not exists cedar_test;

-- Delete every stored policy (static and template-linked) and entity.
create or replace function cedar_test.reset()
returns void
language plpgsql
as $$
declare
    v_uids jsonb;
    v_id   text;
begin
    for v_id in select p.policy_id from permissions.cedar_policies() p loop
        perform permissions.cedar_delete_policy(policy_id => v_id);
    end loop;
    select jsonb_agg(e -> 'uid') into v_uids
      from jsonb_array_elements(coalesce(permissions.cedar_read_entities(), '[]'::jsonb)) e;
    if v_uids is not null then
        perform permissions.cedar_delete_entities(uids => v_uids);
    end if;
end;
$$;

-- One request, reduced to what the oracle compares: the decision, the reasons
-- as a sorted set of policy ids, and the errors as a sorted set of policy ids
-- (messages are not compared, as in Cedar's own harness). An exception becomes
-- {"raised": sqlstate, "message": ...}, so the assertion fails with a
-- diagnostic instead of breaking the plan.
create or replace function cedar_test.authz(
    p_principal text,
    p_action    text,
    p_resource  text,
    p_context   jsonb,
    p_entities  jsonb
)
returns jsonb
language plpgsql
as $$
declare
    r jsonb;
begin
    r := permissions.cedar_is_authorized(
        principal => p_principal,
        action    => p_action,
        resource  => p_resource,
        context   => p_context,
        entities  => p_entities
    );
    return jsonb_build_object(
        'decision', lower(r ->> 'decision'),
        'reasons', coalesce((select jsonb_agg(x order by x collate "C")
                               from (select distinct x from jsonb_array_elements_text(r -> 'reasons') x) d),
                            '[]'::jsonb),
        'errors', coalesce((select jsonb_agg(x order by x collate "C")
                              from (select distinct e ->> 'policy_id' as x
                                      from jsonb_array_elements(r -> 'errors') e) d),
                           '[]'::jsonb)
    );
exception when others then
    return jsonb_build_object('raised', sqlstate, 'message', sqlerrm);
end;
$$;

-- The parser oracle: the EST of one policy's Cedar text, and the policy-set
-- object of a text with several policies. An exception becomes {"raised":
-- sqlstate, "message": ...}, as in authz.
create or replace function cedar_test.parse(p_src text)
returns jsonb
language plpgsql
as $$
begin
    return permissions._cedar_parse_policy(p_src);
exception when others then
    return jsonb_build_object('raised', sqlstate, 'message', sqlerrm);
end;
$$;

create or replace function cedar_test.parse_set(p_src text)
returns jsonb
language plpgsql
as $$
begin
    return permissions._cedar_parse_policies(p_src);
exception when others then
    return jsonb_build_object('raised', sqlstate, 'message', sqlerrm);
end;
$$;
