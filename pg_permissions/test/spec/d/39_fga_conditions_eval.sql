-- Goal: conditioned tuples behave as in OpenFGA v1.22.1 across the API
-- (designs/d-conditions.md sections 3 and 7; probe answers Pn from
-- test/fga_abac/probe.sh): Write validates a tuple's condition (2000), Read
-- returns it, deletes ignore it; contextual tuples carry conditions (Check
-- 2027, lists 2000); the error rule per API (P14 to P16); stale stored
-- contexts are ignored everywhere (a deviation for ListObjects, P29); the RLS
-- helpers deny instead of failing; Check, ListObjects and ListUsers agree;
-- and a walk step evaluates a condition once per distinct context.
\ir ../../fixtures/fga_suite.sql

select tap.plan(64);

-- type user
-- type group
--   relations
--     define member: [user, user with cx]
-- type folder
--   relations
--     define viewer: [user]
-- type doc
--   relations
--     define parent: [folder with cx]
--     define editor: [user]
--     define blocked: [user with cx]
--     define viewer: [user with cx, group#member with cx] or viewer from parent
--     define safe: editor but not blocked
--     define both: editor and viewer
-- condition cx(x: int) { x < 100 }
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "group", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user"}, {"type": "user", "condition": "cx"}]}}}},
    {"type": "folder", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "doc",
     "relations": {
       "parent": {"this": {}},
       "editor": {"this": {}},
       "blocked": {"this": {}},
       "viewer": {"union": {"child": [{"this": {}},
         {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}},
       "safe": {"difference": {"base": {"computedUserset": {"relation": "editor"}}, "subtract": {"computedUserset": {"relation": "blocked"}}}},
       "both": {"intersection": {"child": [{"computedUserset": {"relation": "editor"}}, {"computedUserset": {"relation": "viewer"}}]}}},
     "metadata": {"relations": {
       "parent": {"directly_related_user_types": [{"type": "folder", "condition": "cx"}]},
       "editor": {"directly_related_user_types": [{"type": "user"}]},
       "blocked": {"directly_related_user_types": [{"type": "user", "condition": "cx"}]},
       "viewer": {"directly_related_user_types": [{"type": "user", "condition": "cx"}, {"type": "group", "relation": "member", "condition": "cx"}]}}}}],
  "conditions": {"cx": {"name": "cx", "expression": "x < 100", "parameters": {"x": {"type_name": "TYPE_NAME_INT"}}}}}$m$::jsonb) as m \gset

-- Write and Read
select permissions.fga_write('[{"user": "user:ann", "relation": "viewer", "object": "doc:1", "condition": {"name": "cx", "context": {"x": 10}}},
                               {"user": "user:bob", "relation": "viewer", "object": "doc:1", "condition": {"name": "cx"}}]');
select tap.is((select r.tuples -> 0 -> 'key' from permissions.fga_read('doc:1', 'viewer', 'user:ann') r),
              '{"user": "user:ann", "relation": "viewer", "object": "doc:1", "condition": {"name": "cx", "context": {"x": 10}}}'::jsonb,
              'Read returns the condition with the tuple key (P8)');
select tap.is((select r.tuples #> '{0,key,condition}' from permissions.fga_read('doc:1', 'viewer', 'user:bob') r),
              '{"name": "cx", "context": {}}'::jsonb, 'a condition written without context reads back with context {} (P42)');
select tap.is(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:jon", "relation": "viewer", "object": "doc:9", "condition": {"name": "nope"}}]') $$),
              'openfga:2000 Invalid tuple ''doc:9#viewer@user:jon''. Reason: undefined condition ''nope''', 'Write: an undefined condition is 2000 (P6)');
select tap.is(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:jon", "relation": "viewer", "object": "doc:9", "condition": {"name": "cx", "context": {"z": 1}}}]') $$),
              'openfga:2000 Invalid tuple ''doc:9#viewer@user:jon''. Reason: found invalid context parameter: z', 'Write: a context key that is not a parameter is 2000 (P6)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:jon", "relation": "viewer", "object": "doc:9", "condition": {"name": "cx", "context": {"x": "abc"}}}]') $$)
              ~ '^openfga:2000 Invalid tuple ''doc:9#viewer@user:jon''\. Reason: failed to convert context parameter ''x'': ', 'Write: a context value of the wrong type is 2000 (P6)');
select tap.is(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:jon", "relation": "blocked", "object": "doc:9"}]') $$),
              'openfga:2000 Invalid tuple ''doc:9#blocked@user:jon''. Reason: condition is missing', 'Write: no condition where only "with cx" is allowed is 2000 (P6)');
select tap.is(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:jon", "relation": "editor", "object": "doc:9", "condition": {"name": "cx"}}]') $$),
              'openfga:2000 Invalid tuple ''doc:9#editor@user:jon''. Reason: invalid condition ''cx'' for type restriction', 'Write: a condition on an unconditioned restriction is 2000 (P6)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:jon", "relation": "viewer", "object": "doc:9", "condition": {"name": "c"}}]') $$)
              ~ '^openfga:2000 .*RelationshipCondition\.Name', 'Write: a one-character condition name is 2000, as OpenFGA''s pattern (P43)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:jon", "relation": "viewer", "object": "doc:9", "condition": {"name": "cx", "context": [1]}}]') $$)
              ~ '^openfga:2000 .*the condition context must be a JSON object', 'Write: a context that is not an object is 2000');
select tap.is(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:ann", "relation": "viewer", "object": "doc:1", "condition": {"name": "cx", "context": {"x": 20}}}]') $$),
              'openfga:2017 cannot write a tuple which already exists: doc:1#viewer@user:ann', 'Write: the same key with another context is 2017 (P7)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write('{"tuple_keys": [{"user": "user:ann", "relation": "viewer", "object": "doc:1", "condition": {"name": "cx", "context": {"x": 20}}}], "on_duplicate": "ignore"}') $$)
              ~ '^openfga:2017 attempted to write a tuple which already exists with a different condition', '... also with on_duplicate ignore (OpenFGA: HTTP 409 Aborted, no code; P7)');
select tap.is(fga_test.code_of($$ select permissions.fga_write('{"tuple_keys": [{"user": "user:ann", "relation": "viewer", "object": "doc:1", "condition": {"name": "cx", "context": {"x": 10}}}], "on_duplicate": "ignore"}') $$),
              'ok', 'on_duplicate ignore skips a key stored with the same condition and context (P44)');
select tap.is(fga_test.code_of($$ select permissions.fga_write(deletes => '[{"user": "user:bob", "relation": "viewer", "object": "doc:1"}]') $$),
              'ok', 'a delete need not name the condition (P9)');
select tap.is((select jsonb_array_length(r.tuples) from permissions.fga_read('doc:1', 'viewer', 'user:bob') r), 0, '... and the tuple is gone');

-- evaluation through the API
select tap.is(permissions.fga_check('user:ann', 'viewer', 'doc:1', context => '{"x": 500}'), true,
              'the stored context wins over the request''s (P5)');
select tap.is(fga_test.code_of($$ select permissions.fga_check('user:ann', 'viewer', 'doc:1', context => '"x"') $$),
              'openfga:2000 invalid context: must be a JSON object of condition parameters, got a JSON string', 'a context that is not an object is 2000 (Check)');
select tap.ok(fga_test.code_of($$ select permissions.fga_list_objects('user:ann', 'doc', 'viewer', context => '[]') $$) like 'openfga:2000 invalid context%', '... (ListObjects)');
select tap.ok(fga_test.code_of($$ select permissions.fga_list_users('doc:1', 'viewer', '{user}', context => '1') $$) like 'openfga:2000 invalid context%', '... (ListUsers)');

-- contextual tuples carry conditions (P25 to P27)
select tap.is(permissions.fga_check('user:cid', 'viewer', 'doc:7', '[{"user": "user:cid", "relation": "viewer", "object": "doc:7", "condition": {"name": "cx", "context": {"x": 1}}}]',
                                    context => '{"x": 500}'), true, 'a contextual tuple''s context wins over the request''s (P27)');
select tap.is(array(select permissions.fga_list_objects('user:cid', 'doc', 'viewer', '[{"user": "user:cid", "relation": "viewer", "object": "doc:7", "condition": {"name": "cx"}}]',
                                                        context => '{"x": 5}')), '{doc:7}'::text[], 'ListObjects evaluates a contextual tuple''s condition');
select tap.is(array(select permissions.fga_list_users('doc:7', 'viewer', '{user}', '[{"user": "user:cid", "relation": "viewer", "object": "doc:7", "condition": {"name": "cx"}}]',
                                                      context => '{"x": 500}')), '{}'::text[], 'ListUsers too (false: not listed)');
select tap.ok(fga_test.code_of($$ select permissions.fga_check('user:cid', 'viewer', 'doc:7', '[{"user": "user:cid", "relation": "viewer", "object": "doc:7", "condition": {"name": "nope"}}]') $$)
              ~ '^openfga:2027 ', 'Check: a contextual tuple with an undefined condition is 2027 (P25)');
select tap.ok(fga_test.code_of($$ select permissions.fga_check('user:cid', 'viewer', 'doc:7', '[{"user": "user:cid", "relation": "viewer", "object": "doc:7", "condition": {"name": "cx", "context": {"x": "a"}}}]') $$)
              ~ '^openfga:2027 ', 'Check: a contextual tuple with a wrongly typed context is 2027 (P25)');
select tap.ok(fga_test.code_of($$ select permissions.fga_list_objects('user:cid', 'doc', 'viewer', '[{"user": "user:cid", "relation": "viewer", "object": "doc:7", "condition": {"name": "nope"}}]') $$)
              ~ '^openfga:2000 ', 'ListObjects: the same contextual tuple is 2000 (P26)');
select tap.ok(fga_test.code_of($$ select permissions.fga_list_users('doc:7', 'viewer', '{user}', '[{"user": "user:cid", "relation": "viewer", "object": "doc:7", "condition": {"name": "nope"}}]') $$)
              ~ '^openfga:2000 ', 'ListUsers: 2000 as well');

-- the error rule (designs/d-conditions.md section 3, rule 7)
select permissions.fga_write('[{"user": "group:x#member", "relation": "viewer", "object": "doc:2", "condition": {"name": "cx"}}]');
select tap.ok(fga_test.code_of($$ select permissions.fga_check('user:jon', 'viewer', 'doc:2') $$)
              ~ '^openfga:2000 failed to evaluate relationship condition: ''cx'' - context is missing parameters ''\[x\]''',
              'Check: an erroring edge off the user''s path fails a Check that finds nothing true (P14)');
select tap.is(permissions.fga_check('user:jon', 'viewer', 'doc:2', context => '{"x": 10}'), false, '... and with the parameter it is false');
select tap.is(array(select permissions.fga_list_objects('user:zed', 'doc', 'viewer')), '{}'::text[],
              'ListObjects: an erroring edge the walk does not take is no error (P15)');
select tap.ok(fga_test.code_of($$ select permissions.fga_list_objects('group:x#member', 'doc', 'viewer') $$) ~ '^openfga:2000 ',
              'ListObjects: an erroring edge the walk takes is 2000 (P16)');
select tap.ok(fga_test.code_of($$ select permissions.fga_list_users('doc:2', 'viewer', '{user}') $$) ~ '^openfga:2000 ',
              'ListUsers: an erroring edge on its walk is 2000, though nobody is behind it (P16)');
select tap.is(array(select permissions.fga_list_objects('group:x#member', 'doc', 'viewer', context => '{"x": 10}')), '{doc:2}'::text[],
              'ListObjects with the parameter');
select permissions.fga_write('[{"user": "user:jon", "relation": "viewer", "object": "doc:2", "condition": {"name": "cx", "context": {"x": 1}}}]');
select tap.is(permissions.fga_check('user:jon', 'viewer', 'doc:2'), true, 'Check: a true path wins over an erroring edge');
-- ListUsers on doc:2 for groups only does not evaluate plain users' conditions
select permissions.fga_write('[{"user": "user:kim", "relation": "viewer", "object": "doc:4", "condition": {"name": "cx"}},
                               {"user": "group:y#member", "relation": "viewer", "object": "doc:4", "condition": {"name": "cx", "context": {"x": 1}}}]');
select tap.is(array(select permissions.fga_list_users('doc:4', 'viewer', '{group#member}')), '{group:y#member}'::text[],
              'ListUsers does not evaluate the condition of a plain user of a type the filters exclude');
select tap.ok(fga_test.code_of($$ select permissions.fga_list_users('doc:4', 'viewer', '{user}') $$) ~ '^openfga:2000 ', '... and does for one they include');

-- non-monotone relations (_fga_rec, set-based but not)
select permissions.fga_write('[{"user": "user:bob", "relation": "editor", "object": "doc:3"},
                               {"user": "user:bob", "relation": "blocked", "object": "doc:3", "condition": {"name": "cx"}},
                               {"user": "user:ann", "relation": "viewer", "object": "doc:3", "condition": {"name": "cx"}},
                               {"user": "user:bob", "relation": "viewer", "object": "doc:3", "condition": {"name": "cx"}}]');
select tap.ok(fga_test.code_of($$ select permissions.fga_check('user:bob', 'safe', 'doc:3') $$) ~ '^openfga:2000 ',
              'but not: a subtract that errors, with a true base, is 2000');
select tap.is(permissions.fga_check('user:bob', 'safe', 'doc:3', context => '{"x": 10}'), false, 'but not: the subtract true');
select tap.is(permissions.fga_check('user:bob', 'safe', 'doc:3', context => '{"x": 500}'), true, 'but not: the subtract false');
select tap.ok(fga_test.code_of($$ select permissions.fga_list_objects('user:bob', 'doc', 'safe') $$) ~ '^openfga:2000 ', 'but not, ListObjects (set-based): 2000');
select tap.is(array(select permissions.fga_list_objects('user:bob', 'doc', 'safe', context => '{"x": 500}')), '{doc:3}'::text[], 'but not, ListObjects with the parameter');
select tap.ok(fga_test.code_of($$ select permissions.fga_list_users('doc:3', 'safe', '{user}') $$) ~ '^openfga:2000 ', 'but not, ListUsers (set-based): 2000');
select tap.is(array(select permissions.fga_list_users('doc:3', 'safe', '{user}', context => '{"x": 500}')), '{user:bob}'::text[], 'but not, ListUsers with the parameter');
select tap.ok(fga_test.code_of($$ select permissions.fga_check('user:bob', 'both', 'doc:3') $$) ~ '^openfga:2000 ',
              'and: a true branch and an erroring branch is 2000');
select tap.is(permissions.fga_check('user:ann', 'both', 'doc:3'), false, 'and: a false branch decides over an erroring one');
select tap.is(array(select permissions.fga_list_objects('user:bob', 'doc', 'both', context => '{"x": 1}')), '{doc:3}'::text[], 'and, ListObjects (per candidate)');
select tap.ok(fga_test.code_of($$ select permissions.fga_list_objects('user:bob', 'doc', 'both') $$) ~ '^openfga:2000 ', 'and, ListObjects without the parameter: 2000');

-- the RLS helpers: no request context, never an error
set permissions.subject_id = 'ann';
select tap.is(permissions.fga_check_current('viewer', 'doc:1'), true, 'RLS: a condition true with its stored context alone is true');
select tap.is(permissions.fga_check_current('viewer', 'doc:3'), false, 'RLS: a condition that needs a request parameter denies, without an error');
select tap.is(array(select permissions.fga_list_object_ids_current('doc', 'viewer') order by 1), '{1}'::text[], 'RLS: the list takes only the true edges');
set permissions.subject_id = 'bob';
select tap.is(permissions.fga_check_current('safe', 'doc:3'), false, 'RLS: an erroring subtract denies (no error)');
select tap.is(array(select permissions.fga_list_object_ids_current('doc', 'safe')), '{}'::text[], '... in the list too');
set permissions.subject_id = 'jon';
select tap.is(permissions.fga_check_current('viewer', 'doc:2'), true, 'RLS: a true path among erroring edges is true');
reset permissions.subject_id;

-- Check, ListObjects and ListUsers agree (both contexts, every user, object, relation)
create temp table agree as
select x.ctx, u.u, r.r, o.o,
       permissions.fga_check(u.u, r.r, o.o, context => x.ctx) as chk,
       o.o in (select permissions.fga_list_objects(u.u, 'doc', r.r, context => x.ctx)) as lo,
       u.u in (select permissions.fga_list_users(o.o, r.r, '{user}', context => x.ctx)) as lu
from (values ('{"x": 10}'::jsonb), ('{"x": 500}'::jsonb)) x(ctx)
cross join (values ('user:ann'), ('user:bob'), ('user:jon'), ('user:kim')) u(u)
cross join (values ('viewer'), ('safe'), ('both')) r(r)
cross join (values ('doc:1'), ('doc:2'), ('doc:3'), ('doc:4')) o(o);
select tap.is((select count(*)::int from agree where chk <> lo or chk <> lu), 0, 'Check, ListObjects and ListUsers agree on 96 questions');
select tap.is((select count(*)::int from agree where chk), 9, '... of which this many are true');

-- tupleToUserset through a conditioned tupleset, contextual and stored
select permissions.fga_write('[{"user": "folder:f", "relation": "parent", "object": "doc:5", "condition": {"name": "cx", "context": {"x": 50}}},
                               {"user": "user:lee", "relation": "viewer", "object": "folder:f"}]');
select tap.is(permissions.fga_check('user:lee', 'viewer', 'doc:5'), true, 'a conditioned tupleset tuple, true with its context');
select tap.is(array(select permissions.fga_list_users('doc:5', 'viewer', '{user}')), '{user:lee}'::text[], '... ListUsers');
select tap.is(array(select permissions.fga_list_objects('user:lee', 'doc', 'viewer')), '{doc:5}'::text[], '... ListObjects');

-- a step evaluates a condition once per distinct context (designs/d-conditions.md, decision 2)
select permissions.fga_write((select jsonb_agg(jsonb_build_object('user', 'user:wide', 'relation', 'viewer', 'object', 'doc:w' || g,
                                                                  'condition', jsonb_build_object('name', 'cx')))
                              from generate_series(1, 50) g));
begin;
set local track_functions = 'all';
select count(*) as n from permissions.fga_list_objects('user:wide', 'doc', 'viewer', context => '{"x": 1}') \gset
select tap.is(:n::int, 50, 'ListObjects: 50 objects through tuples sharing one condition and context');
select tap.is((select calls::int from pg_stat_xact_user_functions where schemaname = 'permissions' and funcname = '_fga_cond_eval'), 1,
              '... evaluated the condition once');
commit;

-- stale stored contexts: ignored in every API (P28 to P30; a deviation for ListObjects, P29)
select permissions.fga_write('[{"user": "user:sam", "relation": "viewer", "object": "doc:s", "condition": {"name": "cx", "context": {"x": 10}}}]');
select tap.is(permissions.fga_check('user:sam', 'viewer', 'doc:s'), true, 'before: the stored context makes it true');
select permissions.fga_write_authorization_model(jsonb_set(permissions.fga_read_authorization_model() - 'id',
                                                           '{conditions,cx}', '{"name": "cx", "expression": "x == \"a\"", "parameters": {"x": {"type_name": "TYPE_NAME_STRING"}}}'));
select tap.is(permissions.fga_check('user:sam', 'viewer', 'doc:s'), false, 'a stored value the new parameter type rejects: the tuple is ignored (P28)');
select tap.is(array(select permissions.fga_list_objects('user:sam', 'doc', 'viewer')), '{}'::text[],
              '... ListObjects ignores it too (OpenFGA: 2000, P29; deviation)');
select tap.is(array(select permissions.fga_list_users('doc:s', 'viewer', '{user}')), '{}'::text[], '... and ListUsers');
select permissions.fga_write_authorization_model(jsonb_set(permissions.fga_read_authorization_model() - 'id',
                                                           '{conditions,cx}', '{"name": "cx", "expression": "y < 100", "parameters": {"y": {"type_name": "TYPE_NAME_INT"}}}'));
select tap.is(permissions.fga_check('user:sam', 'viewer', 'doc:s', context => '{"y": 1}'), false,
              'a stored context key that is no longer a parameter: ignored (P30)');
select tap.is(permissions.fga_check('user:sam', 'viewer', 'doc:s', authorization_model_id => :'m'), true, 'the first model still answers true');

select * from tap.finish();
