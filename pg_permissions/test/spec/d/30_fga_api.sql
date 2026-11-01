-- Goal: the fga_* API beyond what OpenFGA's suite covers (research/designs/d-per-model.md):
-- writes and their errors, model versioning and validation, Read, the
-- current-subject wrappers, cleanup, and who may call what.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/fga_suite.sql

select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]}}}},
    {"type": "document",
     "relations": {
       "editor": {"this": {}},
       "viewer": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "editor"}}]}}},
     "metadata": {"relations": {
       "editor": {"directly_related_user_types": [{"type": "user"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "user", "wildcard": {}}, {"type": "team", "relation": "member"}]}}}}
  ]}$m$::jsonb) as v1 \gset

select tap.plan(43);

-- models
select tap.ok(:'v1' ~ '^[0-9A-HJKMNP-TV-Z]{26}$', 'write_authorization_model returns a ULID');
select tap.is(permissions.fga_read_authorization_model() ->> 'id', :'v1', 'the new model is the latest');
select tap.is(fga_test.code_of($$ select permissions.fga_write_authorization_model('{"schema_version": "1.0", "type_definitions": [{"type": "user"}]}') $$),
              'openfga:2056 unsupported schema version 1.0: only 1.1 is supported', 'schema 1.0 is refused (2056, as OpenFGA v1.22.1; d/36 has the other versions)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "doc", "relations": {"viewer": {"computedUserset": {"relation": "nope"}}}}]}') $$)
              like 'openfga:2056 %', 'a computed relation that does not exist is refused (2056)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "doc", "relations": {"viewer": {"this": {}}}, "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "nobody"}]}}}}]}') $$)
              like 'openfga:2056 %', 'a type restriction naming an unknown type is refused (2056)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"viewer": {"this": {}}}}]}') $$)
              like 'openfga:2056 %', 'a direct relation without type restrictions is refused (2056)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "user"}]}') $$)
              like 'openfga:2056 %', 'a type defined twice is refused (2056, as OpenFGA v1.22.1)');
select tap.is(fga_test.code_of($$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}], "conditions": {"c": {"name": "c", "expression": "x <"}}}') $$),
              'openfga:2056 failed to compile expression on condition ''c'' - Syntax error: unexpected end of expression', 'a condition that does not compile is refused (2056; d/37 has the rest)');
select tap.is(permissions.fga_read_authorization_model() ->> 'id', :'v1', 'refused models do not become the latest');

-- writes
select permissions.fga_write('[{"user": "user:anne", "relation": "editor", "object": "document:1"},
                               {"user": "team:eng#member", "relation": "viewer", "object": "document:1"},
                               {"user": "user:bob", "relation": "member", "object": "team:eng"}]');
select tap.is(permissions.fga_check('user:anne', 'viewer', 'document:1'), true, 'editor implies viewer');
select tap.is(permissions.fga_check('user:bob', 'viewer', 'document:1'), true, 'a team member views through the team userset');
select tap.is(permissions.fga_check('user:carl', 'viewer', 'document:1'), false, 'others do not');
select tap.ok(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:anne", "relation": "editor", "object": "document:1"}]') $$)
              like 'openfga:2017 %', 'writing a tuple that exists fails (2017)');
select tap.is(fga_test.code_of($$ select permissions.fga_write('{"tuple_keys": [{"user": "user:anne", "relation": "editor", "object": "document:1"}], "on_duplicate": "ignore"}') $$),
              'ok', 'unless on_duplicate is ignore');
select tap.ok(fga_test.code_of($$ select permissions.fga_write(deletes => '[{"user": "user:zed", "relation": "editor", "object": "document:1"}]') $$)
              like 'openfga:2017 %', 'deleting a tuple that does not exist fails (2017)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write(deletes => '[{"user": "team:eng", "relation": "viewer", "object": "document:1"}]') $$)
              like 'openfga:2017 %', 'deleting team:eng where team:eng#member is stored fails (2017), not silently');
select tap.ok(fga_test.code_of($$ select permissions.fga_write() $$) like 'openfga:2003 %', 'a write with no writes and no deletes fails (2003)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:x", "relation": "editor", "object": "document:9"}, {"user": "user:x", "relation": "editor", "object": "document:9"}]') $$)
              like 'openfga:2004 %', 'the same tuple twice in one request fails (2004)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:*", "relation": "editor", "object": "document:9"}]') $$)
              like 'openfga:2027 %', 'a wildcard where the relation does not allow one fails (2027)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write('[{"user": "team:eng#member", "relation": "editor", "object": "document:9"}]') $$)
              like 'openfga:2027 %', 'a userset where the relation does not allow one fails (2027)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:x", "relation": "owner", "object": "document:9"}]') $$)
              like 'openfga:2027 %', 'an unknown relation fails (2027)');
select tap.is(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:x", "relation": "editor", "object": "document:9", "condition": {"name": "cx"}}]') $$),
              'openfga:2000 Invalid tuple ''document:9#editor@user:x''. Reason: undefined condition ''cx''', 'a tuple naming a condition the model does not define is refused (2000; d/39 has the rest)');
select permissions.fga_write('[{"user": "user:x", "relation": "editor", "object": "document:9"}]',
                             '[{"user": "user:anne", "relation": "editor", "object": "document:1"}]');
select tap.ok(not permissions.fga_check('user:anne', 'editor', 'document:1') and permissions.fga_check('user:x', 'editor', 'document:9'),
              'writes and deletes apply together');
select permissions.fga_write_tuple('user:anne', 'editor', 'document:1');
select permissions.fga_write_tuple('user:anne', 'editor', 'document:1');
select tap.is(permissions.fga_check('user:anne', 'editor', 'document:1'), true, 'fga_write_tuple writes, and is idempotent');

-- read
select tap.set_eq(array(select t #>> '{key,user}' from permissions.fga_read('document:1') r, jsonb_array_elements(r.tuples) t),
                  '{user:anne,team:eng#member}', 'read by object');
select tap.set_eq(array(select t #>> '{key,object}' from permissions.fga_read('document:', null, 'user:anne') r, jsonb_array_elements(r.tuples) t),
                  '{document:1}', 'read by object type and user');
select tap.set_eq(array(select (t #>> '{key,object}') || '#' || (t #>> '{key,relation}')
                        from permissions.fga_read(null, null, 'team:eng#member') r, jsonb_array_elements(r.tuples) t),
                  '{document:1#viewer}', 'read by userset');

-- versioning: a new model that drops the team userset from viewer
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "document", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}$m$::jsonb) as v2 \gset
select tap.is(permissions.fga_check('user:bob', 'viewer', 'document:1'), false, 'latest model: a tuple it no longer allows is ignored');
select tap.is(permissions.fga_check('user:bob', 'viewer', 'document:1', null, :'v1'), true, 'an earlier model id still evaluates with that model');
select tap.ok(fga_test.code_of($$ select permissions.fga_check('user:bob', 'editor', 'document:1') $$) like 'openfga:2000 %', 'a relation the latest model dropped is invalid input (2000)');
select tap.ok(fga_test.code_of($$ select permissions.fga_check('user:bob', 'viewer', 'document:1', null, '01ARZ3NDEKTSV4RRFFQ69G5FAV') $$) like 'openfga:2001 %', 'an unknown model id fails (2001)');
select tap.set_eq(array(select id from permissions.fga_read_authorization_models()), array[:'v1', :'v2'], 'read_authorization_models lists both versions');
select permissions.fga_write(deletes => '[{"user": "team:eng#member", "relation": "viewer", "object": "document:1"}]');
select tap.is((select tuples from permissions.fga_read('document:1', 'viewer')), '[]'::jsonb, 'a tuple the model no longer allows can still be deleted');

-- current subject
select permissions.fga_write(('[{"user": "user:' || :'alice' || '", "relation": "viewer", "object": "document:' || :'acme_plan' || '"}]')::jsonb);
select tap.is(permissions.fga_check_current('viewer', 'document:' || :'acme_plan'), false, 'no subject: fga_check_current is false');
select set_config('permissions.subject_id', :'alice', false);
select tap.is(permissions.fga_check_current('viewer', 'document:' || :'acme_plan'), true, 'fga_check_current answers for the current subject');
select tap.set_eq(array(select permissions.fga_list_object_ids_current('document', 'viewer')), array[:'acme_plan'], 'fga_list_object_ids_current returns bare ids');
select tap.set_eq(array(select permissions.fga_list_objects_current('document', 'viewer')), array['document:' || :'acme_plan'], 'fga_list_objects_current returns type:id');
select set_config('permissions.subject_type', 'robot', false);
select tap.is(permissions.fga_check_current('viewer', 'document:' || :'acme_plan'), false, 'a subject type the model does not define has nothing');
select set_config('permissions.subject_type', '', false);
select tap.ok(fga_test.code_of($$ select permissions.fga_check_current('owner', 'document:x') $$) like 'openfga:2000 %', 'an unknown relation still raises');

-- privileges
set role authenticated;
select tap.lives_ok($$ select permissions.fga_check_current('viewer', 'document:1') $$, 'authenticated can call fga_check_current');
select tap.throws_ok($$ select permissions.fga_check('user:anne', 'viewer', 'document:1') $$, '42501', 'authenticated cannot check for another user');
select tap.throws_ok($$ select permissions.fga_write_tuple('user:anne', 'viewer', 'document:2') $$, '42501', 'authenticated cannot write tuples');
reset role;

-- cleanup
select tap.is(permissions.delete_subject('user', :'alice'), 1::bigint, 'delete_subject removes the subject''s tuples');

select * from tap.finish();
