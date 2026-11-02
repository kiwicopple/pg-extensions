-- Throwaway measurement for research/designs/e-cedar.md, "Phase 2
-- measurements" (tag: cedar-requests): cedar_is_authorized per request for
-- typical cases. Not a benchmark baseline. Run it with phase2.sh.
--
-- Data: 1,000 users in 50 groups under Org::"acme"; 1,000 docs in 20 folders
-- under Folder::"root", each with an owner, a public flag and labels; the
-- action view in the group read, edit in write. Every request asks for a
-- different user and doc.
\set ON_ERROR_STOP on
create schema r;
create table r.res (what text, us numeric);
create function r.time(p_what text, p_n int, p_sql text) returns void language plpgsql as $$
declare t0 timestamptz; best numeric; dt numeric;
begin
    for k in 1..5 loop
        t0 := clock_timestamp();
        execute p_sql;
        dt := extract(epoch from clock_timestamp() - t0) * 1e6 / p_n;
        if best is null or dt < best then best := dt; end if;
    end loop;
    insert into r.res values (p_what, round(best, 1));
end $$;

select permissions.cedar_put_entities(entities => (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Group', 'id', 'g' || g),
    'parents', '[{"type": "Org", "id": "acme"}]'::jsonb)) from generate_series(1, 50) g));
select permissions.cedar_put_entities(entities => (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'User', 'id', 'u' || g),
    'attrs', jsonb_build_object('dept', case when g % 2 = 0 then 'Eng' else 'Ops' end, 'level', g % 5),
    'parents', jsonb_build_array(jsonb_build_object('type', 'Group', 'id', 'g' || (g % 50 + 1))))) from generate_series(1, 1000) g));
select permissions.cedar_put_entities(entities => (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Folder', 'id', 'f' || g),
    'parents', '[{"type": "Folder", "id": "root"}]'::jsonb)) from generate_series(1, 20) g));
select permissions.cedar_put_entities(entities => (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'd' || g),
    'attrs', jsonb_build_object('owner', jsonb_build_object('__entity', jsonb_build_object('type', 'User', 'id', 'u' || g)),
                                'public', g % 10 = 0, 'labels', jsonb_build_array('a', 'b')),
    'parents', jsonb_build_array(jsonb_build_object('type', 'Folder', 'id', 'f' || (g % 20 + 1))))) from generate_series(1, 1000) g));
select permissions.cedar_put_entities(entities => '[{"uid": {"type": "Action", "id": "view"}, "parents": [{"type": "Action", "id": "read"}]},
    {"uid": {"type": "Action", "id": "edit"}, "parents": [{"type": "Action", "id": "write"}]},
    {"uid": {"type": "Action", "id": "read"}}, {"uid": {"type": "Action", "id": "write"}}]');
analyze;

-- 1. one policy, scope only
select permissions.cedar_put_policy(policy_id => 'org', policy_json => '{"effect": "permit",
    "principal": {"op": "in", "entity": {"type": "Org", "id": "acme"}}, "action": {"op": "in", "entity": {"type": "Action", "id": "read"}},
    "resource": {"op": "in", "entity": {"type": "Folder", "id": "root"}}, "conditions": []}');
select r.time('1 policy, scope only: principal in Org, action in a group, resource in Folder', 2000,
    $q$select count(*) from generate_series(1, 2000) g where permissions.cedar_is_authorized(principal => 'User::"u' || (g % 1000 + 1) || '"',
       action => 'Action::"view"', resource => 'Doc::"d' || (g % 1000 + 1) || '"') ->> 'decision' = 'allow'$q$);

-- 2. ten policies with typical conditions
select permissions.cedar_put_policy(policy_id => 'owner', policy_json => '{"effect": "permit", "principal": {"op": "All"},
    "action": {"op": "in", "entities": [{"type": "Action", "id": "read"}, {"type": "Action", "id": "write"}]}, "resource": {"op": "is", "entity_type": "Doc"},
    "conditions": [{"kind": "when", "body": {"==": {"left": {".": {"left": {"Var": "resource"}, "attr": "owner"}}, "right": {"Var": "principal"}}}}]}');
select permissions.cedar_put_policy(policy_id => 'public', policy_json => '{"effect": "permit", "principal": {"op": "All"},
    "action": {"op": "==", "entity": {"type": "Action", "id": "view"}}, "resource": {"op": "All"},
    "conditions": [{"kind": "when", "body": {"&&": {"left": {"has": {"left": {"Var": "resource"}, "attr": "public"}}, "right": {".": {"left": {"Var": "resource"}, "attr": "public"}}}}}]}');
select permissions.cedar_put_policy(policy_id => 'eng', policy_json => '{"effect": "permit", "principal": {"op": "is", "entity_type": "User"},
    "action": {"op": "All"}, "resource": {"op": "All"},
    "conditions": [{"kind": "when", "body": {"&&": {"left": {"==": {"left": {".": {"left": {"Var": "principal"}, "attr": "dept"}}, "right": {"Value": "Eng"}}},
                                                     "right": {">=": {"left": {".": {"left": {"Var": "principal"}, "attr": "level"}}, "right": {"Value": 3}}}}}}]}');
select permissions.cedar_put_policy(policy_id => 'labels', policy_json => '{"effect": "permit", "principal": {"op": "All"}, "action": {"op": "All"}, "resource": {"op": "All"},
    "conditions": [{"kind": "when", "body": {"&&": {"left": {"has": {"left": {"Var": "resource"}, "attr": "labels"}},
                                                     "right": {"contains": {"left": {".": {"left": {"Var": "resource"}, "attr": "labels"}}, "right": {"Value": "secret"}}}}}}]}');
select permissions.cedar_put_policy(policy_id => 'nolow', policy_json => '{"effect": "forbid", "principal": {"op": "All"},
    "action": {"op": "in", "entity": {"type": "Action", "id": "write"}}, "resource": {"op": "All"},
    "conditions": [{"kind": "when", "body": {"<": {"left": {".": {"left": {"Var": "principal"}, "attr": "level"}}, "right": {"Value": 1}}}}]}');
select permissions.cedar_put_policy(policy_id => 'g' || g, policy_json => format('{"effect": "permit",
    "principal": {"op": "in", "entity": {"type": "Group", "id": "g%s"}}, "action": {"op": "All"},
    "resource": {"op": "in", "entity": {"type": "Folder", "id": "f%s"}}, "conditions": []}', g, g)::jsonb)
from generate_series(1, 4) g;
select r.time('10 policies with conditions (attributes, has, contains, ==, >=)', 2000,
    $q$select count(*) from generate_series(1, 2000) g where permissions.cedar_is_authorized(principal => 'User::"u' || (g % 1000 + 1) || '"',
       action => 'Action::"view"', resource => 'Doc::"d' || (g % 1000 + 1) || '"') ->> 'decision' = 'allow'$q$);
select r.time('10 policies, a context of 3 values', 2000,
    $q$select count(*) from generate_series(1, 2000) g where permissions.cedar_is_authorized(principal => 'User::"u' || (g % 1000 + 1) || '"',
       action => 'Action::"view"', resource => 'Doc::"d' || (g % 1000 + 1) || '"',
       context => '{"mfa": true, "ip": "10.0.0.1", "roles": ["a", "b"]}') ->> 'decision' = 'allow'$q$);
select r.time('10 policies, principal and resource only in the overlay', 2000,
    $q$select count(*) from generate_series(1, 2000) g where permissions.cedar_is_authorized(principal => 'User::"x' || g || '"',
       action => 'Action::"view"', resource => 'Doc::"y' || g || '"',
       entities => jsonb_build_array(
           jsonb_build_object('uid', jsonb_build_object('type', 'User', 'id', 'x' || g), 'attrs', '{"dept": "Eng", "level": 4}'::jsonb,
                              'parents', '[{"type": "Group", "id": "g1"}]'::jsonb),
           jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'y' || g), 'attrs', '{"public": false}'::jsonb,
                              'parents', '[{"type": "Folder", "id": "f1"}]'::jsonb))) ->> 'decision' = 'allow'$q$);
select r.time('10 policies, a principal that is not stored: 4 policies err (the second pass for messages)', 2000,
    $q$select count(*) from generate_series(1, 2000) g where permissions.cedar_is_authorized(principal => 'User::"nobody' || g || '"',
       action => 'Action::"view"', resource => 'Doc::"d' || (g % 1000 + 1) || '"') ->> 'decision' = 'allow'$q$);

select what, us as "us per request" from r.res;
