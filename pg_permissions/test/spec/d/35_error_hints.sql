-- Goal: every error the extension raises is descriptive (DECISION.md, end of
-- session 4, point 5; designs/d-per-model.md section 7). One row per raise
-- site, rbac_* and fga_* alike: the statement that triggers it, the SQLSTATE,
-- the DETAIL (OpenFGA's 'openfga:<code> <name>' on fga_* errors, none on
-- rbac_*), a pattern for the MESSAGE (it names the offending values) and the
-- HINT, which must never be empty and, where given, matches a pattern (the
-- nearest name, the allowed user types, the model ids, the call to make
-- first).
--
-- Guard: a static scan of the extension's function bodies (pg_proc.prosrc)
-- finds every raise site: each `raise`, and each call of the error helpers
-- _fga_error (and _fga_unsupported, gone since conditions are supported).
-- Each must pass a hint, and the number of
-- sites must equal the number of rows below, so a new raise site fails this
-- file until it has a hint and a row.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/fga_suite.sql

select permissions.create_role('viewer', '{documents.read}');
select permissions.create_role('editor', '{documents.edit}', '{viewer}');

-- a model with a condition (the first model; v1 below is the latest)
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "doc", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user", "condition": "cx"}]}}}}],
  "conditions": {"cx": {"name": "cx", "expression": "x < 100", "parameters": {"x": {"type_name": "TYPE_NAME_INT"}}}}}$m$::jsonb) as vc \gset
select permissions.fga_write('[{"user": "user:jon", "relation": "viewer", "object": "doc:1", "condition": {"name": "cx"}}]',
                             authorization_model_id => :'vc');

select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]}}}},
    {"type": "folder", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "document",
     "relations": {
       "parent": {"this": {}},
       "editor": {"this": {}},
       "viewer": {"union": {"child": [
         {"this": {}},
         {"computedUserset": {"relation": "editor"}},
         {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}}},
     "metadata": {"relations": {
       "parent": {"directly_related_user_types": [{"type": "folder"}]},
       "editor": {"directly_related_user_types": [{"type": "user"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "user", "wildcard": {}}, {"type": "team", "relation": "member"}]}}}}
  ]}$m$::jsonb) as v1 \gset
select permissions.fga_write('[{"user": "user:anne", "relation": "editor", "object": "document:1"},
                               {"user": "team:eng#member", "relation": "viewer", "object": "document:1"}]');
-- a userset chain 30 levels deep: team:t0 <- team:t1#member <- ... <- user:deep
select permissions.fga_write((select jsonb_agg(jsonb_build_object('user', 'team:t' || (g + 1) || '#member', 'relation', 'member', 'object', 'team:t' || g))
                              from generate_series(0, 29) g));
select permissions.fga_write_tuple('user:deep', 'member', 'team:t30');


create temp table sites (n serial, site text, stmt text, st text, detail text, msg text, hint text);
insert into sites (site, stmt, st, detail, msg, hint) values
-- rbac_*
('create_role: exists', $$ select permissions.create_role('viewer', '{x.read}') $$,
 '23505', null, '^role ''viewer'' already exists$', 'drop_role\(''viewer''\)'),
('create_role: overlap', $$ select permissions.create_role('documents.read', '{a.read}') $$,
 '22023', null, '^role and permission names must not overlap: ''documents.read'' is already a permission$', null),
('create_role: unknown inherits', $$ select permissions.create_role('auditor', '{audit.read}', '{viewr}') $$,
 '22023', null, '^unknown role ''viewr'' in inherits of role ''auditor''$', '^Did you mean ''viewer''\? Existing roles: editor, viewer\.$'),
('drop_role: unknown', $$ select permissions.drop_role('editr') $$,
 '22023', null, '^unknown role ''editr''$', '^Did you mean ''editor''\?'),
('drop_role: inherited', $$ select permissions.drop_role('viewer') $$,
 '2BP01', null, '^role ''viewer'' is inherited by ''editor''$', 'drop_role\(''editor''\)'),
('assign_role: unknown', $$ select permissions.assign_role('u1', 'admn') $$,
 '22023', null, '^unknown role ''admn''$', '^Existing roles: editor, viewer\.$'),
('assign_role: null user', $$ select permissions.assign_role(null, 'viewer') $$,
 '22004', null, '^user_id is required to assign role ''viewer''$', null),
-- users and objects (validation.ValidateUser / ValidateObject)
('parse_user: malformed', $$ select permissions.fga_check('anne', 'viewer', 'document:1') $$,
 '22023', 'openfga:2000 validation_error', '^invalid ''user'' value: anne: ', '''user:anne'''),
('parse_user: type', $$ select permissions.fga_check('usr:anne', 'viewer', 'document:1') $$,
 '22023', 'openfga:2000 validation_error', '^invalid ''user'' value: usr:anne: type ''usr'' not found$', '^Did you mean ''user''\? Types in model '),
('parse_user: relation', $$ select permissions.fga_check('team:eng#membr', 'viewer', 'document:1') $$,
 '22023', 'openfga:2000 validation_error', '^invalid ''user'' value: team:eng#membr: relation ''team#membr'' not found$',
 '^Did you mean ''member''\? Relations on type ''team'': member\.$'),
('parse_object: format', $$ select permissions.fga_check('user:anne', 'viewer', 'document') $$,
 '22023', 'openfga:2000 validation_error', '^invalid ''object'' field format: document$', '''document:1'''),
('parse_object: wildcard', $$ select permissions.fga_check('user:anne', 'viewer', 'document:*') $$,
 '22023', 'openfga:2000 validation_error', '^the ''object'' field cannot reference a typed wildcard: document:\*$', null),
('parse_object: type', $$ select permissions.fga_check('user:anne', 'viewer', 'documnt:1') $$,
 '22023', 'openfga:2000 validation_error', '^type ''documnt'' not found$', '^Did you mean ''document''\? Types in model [0-9A-Z]{26}: document, folder, team, user\.$'),
('parse_object: malformed relation', $$ select permissions.fga_check('user:anne', 'vi ew', 'document:1') $$,
 '22023', 'openfga:2000 validation_error', '^the ''relation'' field is malformed: vi ew$', 'Relations on type ''document'': editor, parent, viewer\.$'),
('parse_object: relation', $$ select permissions.fga_check('user:anne', 'viewr', 'document:1') $$,
 '22023', 'openfga:2000 validation_error', '^relation ''document#viewr'' not found$', '^Did you mean ''viewer''\? Relations on type ''document'': editor, parent, viewer\.$'),
-- tuple keys (validation.ValidateTupleForWrite) and contextual tuples
('tuple_for_write: not an object', $$ select permissions.fga_write('[1]') $$,
 '22023', 'openfga:2027 invalid_tuple', '^invalid tuple key: 1$', null),
('tuple_for_write: condition', $$ select permissions.fga_write('[{"user": "user:x", "relation": "editor", "object": "document:9", "condition": {"name": "cx"}}]') $$,
 '22023', 'openfga:2000 validation_error', '^Invalid tuple ''document:9#editor@user:x''\. Reason: undefined condition ''cx''$', 'the model''s conditions: none\.$'),
-- conditions (designs/d-conditions.md)
('context: not an object', $$ select permissions.fga_check('user:anne', 'viewer', 'document:1', context => '[1]') $$,
 '22023', 'openfga:2000 validation_error', '^invalid context: must be a JSON object of condition parameters, got a JSON array$', 'context =>'),
('condition: evaluation error', $$ select permissions.fga_check('user:jon', 'viewer', 'doc:1', authorization_model_id => (select m.id from permissions.fga_models m order by m.seq limit 1)) $$,
 '22023', 'openfga:2000 validation_error', '^failed to evaluate relationship condition: ''cx'' - context is missing parameters ''\[x\]''$', '^Pass every parameter the condition declares'),
('write: another condition, on_duplicate ignore', $$ select permissions.fga_write('{"tuple_keys": [{"user": "user:jon", "relation": "viewer", "object": "doc:1", "condition": {"name": "cx", "context": {"x": 1}}}], "on_duplicate": "ignore"}', authorization_model_id => (select m.id from permissions.fga_models m order by m.seq limit 1)) $$,
 '22023', 'openfga:2017 write_failed_due_to_invalid_input', '^attempted to write a tuple which already exists with a different condition: doc:1#viewer@user:jon \(stored: condition cx \{\}, written: condition cx \{"x": 1\}\)$', 'delete it, then write it again'),
('tuple_for_write: invalid user or object', $$ select permissions.fga_write('[{"user": "usr:x", "relation": "editor", "object": "document:9"}]') $$,
 '22023', 'openfga:2027 invalid_tuple', '^Invalid tuple ''document:9#editor@usr:x''\. Reason: invalid ''user'' value: usr:x: type ''usr'' not found$', '^Did you mean ''user''\?'),
('tuple_for_write: tupleset', $$ select permissions.fga_write('[{"user": "folder:*", "relation": "parent", "object": "document:1"}]') $$,
 '22023', 'openfga:2027 invalid_tuple', '^Invalid tuple ''document:1#parent@folder:\*''\. Reason: unexpected wildcard relationship with tupleset relation ''document#parent''$',
 '''document#parent'' is a tupleset relation.*folder'),
('tuple_for_write: type restriction', $$ select permissions.fga_write('[{"user": "team:eng#member", "relation": "editor", "object": "document:9"}]') $$,
 '22023', 'openfga:2027 invalid_tuple', '^Invalid tuple ''document:9#editor@team:eng#member''\. Reason: ''team#member'' is not an allowed type restriction for ''document#editor''$',
 '^''document#editor'' allows users of type: user\.$'),
('contextual tuples: not an array', $$ select permissions.fga_check('user:anne', 'viewer', 'document:1', '"x"') $$,
 '22023', 'openfga:2000 validation_error', '^contextual_tuples must be an array of tuple keys, got a JSON string$', 'tuple_keys'),
-- models
('model id: none written', $$ do $d$ begin perform permissions.fga_delete_store(); perform permissions.fga_check('user:anne', 'viewer', 'document:1'); end $d$ $$,
 '22023', 'openfga:2020 latest_authorization_model_not_found', '^No authorization models found for store$', 'fga_write_authorization_model\('),
('model id: unknown', $$ select permissions.fga_check('user:anne', 'viewer', 'document:1', null, '01ARZ3NDEKTSV4RRFFQ69G5FAV') $$,
 '22023', 'openfga:2001 authorization_model_not_found', '^Authorization Model ''01ARZ3NDEKTSV4RRFFQ69G5FAV'' not found$', '^Model ids, newest first: ' || :'v1' || ', ' || :'vc' || '\.'),
('model: not an object', $$ select permissions.fga_write_authorization_model('[]') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^the authorization model must be a JSON object, got a JSON array$', 'schema_version'),
('model: schema version', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.0", "type_definitions": [{"type": "user"}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^unsupported schema version 1\.0: only 1\.1 is supported$', '"schema_version": "1\.1"'),
('model: condition request validation', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}], "conditions": {"a:b": {"name": "a:b", "expression": "true"}}}') $$,
 '22023', 'openfga:2000 validation_error', '^invalid Condition\.Name ''a:b'': value does not match regex pattern', 'at most 25 parameters'),
('model: inline expression', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"viewer": {"this": {}}}, "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user", "condition": "$expression"}]}}}}]}') $$,
 '22023', 'openfga:2000 validation_error', '^\$expression requires the "inline_expressions" experimental feature flag: doc#viewer allows user with condition ''\$expression''$', 'define a named condition'),
('model: condition does not compile', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}], "conditions": {"c": {"name": "c", "expression": "x < 1", "parameters": {"x": {"type_name": "TYPE_NAME_STRING"}}}}}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^failed to compile expression on condition ''c'' - found no matching overload for ''_<_'' applied to ''\(string, int\)'' \(column 3\)$', 'no implicit conversions'),
('model: no type definitions', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": []}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^type_definitions must be a non-empty array, got \[\]$', null),
('model: type name', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "a:b"}]}') $$,
 '22023', 'openfga:2047 type_invalid_pattern', '^invalid type name ''a:b''$', null),
('model: duplicate type', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "user"}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^the type ''user'' is defined more than once$', null),
('model: reserved type name', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "self"}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^the definition of type ''self'' is invalid: self and this are reserved keywords$', 'Rename the type'),
('model: relation name', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "doc", "relations": {"a b": {"this": {}}}}]}') $$,
 '22023', 'openfga:2050 relations_invalid_pattern', '^invalid relation name ''doc#a b''$', null),
('model: reserved relation name', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "doc", "relations": {"this": {"this": {}}}}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^invalid relation name ''doc#this'': self and this are reserved keywords$', 'Rename the relation'),
('model: metadata for an undefined relation', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"viewer": {"this": {}}}, "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}, "viewr": {}}}}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^metadata for undefined relation ''doc#viewr''$', '^Did you mean ''viewer''\?'),
('model: undefined condition', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"viewer": {"this": {}}}, "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user", "condition": "c"}]}}}}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^condition c is undefined for relation viewer \(doc#viewer allows user with c\)$', 'Conditions in this model: none\.$'),
('model: type restriction', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"viewer": {"this": {}}}, "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "usr"}]}}}}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^invalid type restriction: doc#viewer allows usr \(undefined type or relation\)$', '^Did you mean ''user''\?'),
('model: rewrite', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"viewer": {"nonsense": {}}}}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^invalid rewrite for relation ''doc#viewer''$', 'computedUserset'),
('model: computed relation', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"editor": {"this": {}}, "viewer": {"computedUserset": {"relation": "editr"}}}, "metadata": {"relations": {"editor": {"directly_related_user_types": [{"type": "user"}]}}}}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^doc#viewer: computed relation ''editr'' is not defined on type ''doc''$', '^Did you mean ''editor''\?'),
('model: tupleset', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"parent": {"this": {}}, "viewer": {"tupleToUserset": {"tupleset": {"relation": "parnt"}, "computedUserset": {"relation": "viewer"}}}}, "metadata": {"relations": {"parent": {"directly_related_user_types": [{"type": "doc"}]}}}}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^doc#viewer: tupleset ''parnt'' is not defined$', '^Did you mean ''parent''\?'),
('model: direct relation without type restrictions', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"viewer": {"this": {}}}}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^relation ''doc#viewer'': a direct relation \(\[\.\.\.\]\) needs type restrictions, and only a direct relation can have them$', 'directly_related_user_types'),
('model: no entrypoint', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"a": {"computedUserset": {"relation": "b"}}, "b": {"computedUserset": {"relation": "a"}}}}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^the definition of relation ''a'' in object type ''doc'' is invalid: no entrypoints defined \(no path from doc#a to a concrete user type\)$', '^Give doc#a a way in: a direct type restriction such as \[user\]'),
('model: cycle', $$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"x": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "y"}}]}}, "y": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "x"}}]}}}, "metadata": {"relations": {"x": {"directly_related_user_types": [{"type": "user"}]}, "y": {"directly_related_user_types": [{"type": "user"}]}}}}]}') $$,
 '22023', 'openfga:2056 invalid_authorization_model', '^the definition of relation ''x'' in object type ''doc'' is invalid: an authorization model cannot contain a cycle \(computed relations on the cycle: doc#x, doc#y\)$', '^Computed relations on one type must not refer to each other in a cycle \(doc#x, doc#y\)'),
-- Write
('write: on_duplicate', $$ select permissions.fga_write('{"tuple_keys": [{"user": "user:x", "relation": "editor", "object": "document:9"}], "on_duplicate": "skip"}') $$,
 '22023', 'openfga:2000 validation_error', '^invalid on_duplicate option: skip$', '''ignore'''),
('write: on_missing', $$ select permissions.fga_write(deletes => '{"tuple_keys": [{"user": "user:x", "relation": "editor", "object": "document:9"}], "on_missing": "skip"}') $$,
 '22023', 'openfga:2000 validation_error', '^invalid on_missing option: skip$', '''ignore'''),
('write: not arrays', $$ select permissions.fga_write('"x"') $$,
 '22023', 'openfga:2000 validation_error', '^writes and deletes must be arrays of tuple keys, got writes: string, deletes: null$', null),
('write: empty list', $$ select permissions.fga_write('[{"user": "user:x", "relation": "editor", "object": "document:9"}]', '[]') $$,
 '22023', 'openfga:2000 validation_error', '^deletes must contain at least 1 tuple key, got an empty list$', 'deletes'),
('write: nothing', $$ select permissions.fga_write() $$,
 '22023', 'openfga:2003 invalid_write_input', '^Invalid input\. Make sure you provide at least one write, or at least one delete$', 'fga_write\('),
('write: malformed delete', $$ select permissions.fga_write(deletes => '[{"user": "anne", "relation": "editor", "object": "document:1"}]') $$,
 '22023', 'openfga:2000 validation_error', '^Invalid tuple ''document:1#editor@anne'' in deletes: malformed$', null),
('write: duplicate', $$ select permissions.fga_write('[{"user": "user:x", "relation": "editor", "object": "document:9"}, {"user": "user:x", "relation": "editor", "object": "document:9"}]') $$,
 '22023', 'openfga:2004 cannot_allow_duplicate_tuples_in_one_request', '^duplicate tuple in write or delete: document:9#editor@user:x$', null),
('write: too many', $$ select permissions.fga_write((select jsonb_agg(jsonb_build_object('user', 'user:x' || g, 'relation', 'editor', 'object', 'document:9')) from generate_series(1, 101) g)) $$,
 '22023', 'openfga:2053 exceeded_entity_limit', '^The number of write operations exceeds the allowed limit of 100: got 101 tuple keys \(101 writes, 0 deletes\)$', 'batches of at most 100'),
('write: delete missing', $$ select permissions.fga_write(deletes => '[{"user": "user:zed", "relation": "editor", "object": "document:1"}]') $$,
 '22023', 'openfga:2017 write_failed_due_to_invalid_input', '^cannot delete a tuple which does not exist: document:1#editor@user:zed$', '"on_missing": "ignore"'),
('write: exists', $$ select permissions.fga_write('[{"user": "user:anne", "relation": "editor", "object": "document:1"}]') $$,
 '22023', 'openfga:2017 write_failed_due_to_invalid_input', '^cannot write a tuple which already exists: document:1#editor@user:anne$', '"on_duplicate": "ignore"'),
-- Read
('read: page_size', $$ select permissions.fga_read(p_page_size => 0) $$,
 '22023', 'openfga:2000 validation_error', '^invalid ReadRequest\.PageSize: value must be inside range \[1, 100\], got 0$', 'default of 50'),
('read: token format', $$ select permissions.fga_read(p_continuation_token => 'a b') $$,
 '22023', 'openfga:2000 validation_error', '^invalid ReadRequest\.ContinuationToken: value does not match regex pattern', 'continuation_token'),
('read: token decode', $$ select permissions.fga_read(p_continuation_token => 'AAAA') $$,
 '22023', 'openfga:2007 invalid_continuation_token', '^Invalid continuation token: ''AAAA''$', 'continuation_token'),
-- depth
('too complex', $$ select permissions.fga_check('user:deep', 'member', 'team:t0') $$,
 '54001', 'openfga:2002 authorization_model_resolution_too_complex', '^Authorization Model resolution required too many rewrite rules to be resolved\.', '25'),
-- ListObjects
('list_objects: type', $$ select permissions.fga_list_objects('user:anne', 'documnt', 'viewer') $$,
 '22023', 'openfga:2021 type_not_found', '^type ''documnt'' not found$', '^Did you mean ''document''\?'),
('list_objects: relation', $$ select permissions.fga_list_objects('user:anne', 'document', 'viewr') $$,
 '22023', 'openfga:2022 relation_not_found', '^relation ''document#viewr'' not found$', '^Did you mean ''viewer''\?'),
-- ListUsers
('list_users: object', $$ select permissions.fga_list_users('document', 'viewer', '{user}') $$,
 '22023', 'openfga:2000 validation_error', '^invalid ''object'' field format: document$', '''document:1'''),
('list_users: no filters', $$ select permissions.fga_list_users('document:1', 'viewer', '{}') $$,
 '22023', 'openfga:2000 validation_error', '^user_filters must have at least one filter$', '\{user\}'),
('list_users: filter type', $$ select permissions.fga_list_users('document:1', 'viewer', '{usr}') $$,
 '22023', 'openfga:2021 type_not_found', '^type ''usr'' not found \(user_filters: usr\)$', '^Did you mean ''user''\?'),
('list_users: filter relation', $$ select permissions.fga_list_users('document:1', 'viewer', '{team#membr}') $$,
 '22023', 'openfga:2022 relation_not_found', '^relation ''team#membr'' not found \(user_filters: team#membr\)$', '^Did you mean ''member''\?'),
('list_users: object type', $$ select permissions.fga_list_users('documnt:1', 'viewer', '{user}') $$,
 '22023', 'openfga:2021 type_not_found', '^type ''documnt'' not found$', '^Did you mean ''document''\?'),
('list_users: relation', $$ select permissions.fga_list_users('document:1', 'viewr', '{user}') $$,
 '22023', 'openfga:2022 relation_not_found', '^relation ''document#viewr'' not found$', '^Did you mean ''viewer''\?');

-- static scan of the function bodies: every raise and every call of an error helper
create temp table raise_sites as
select p.proname::text as fn, m[1] as stmt
from pg_proc p
cross join lateral regexp_matches(p.prosrc, '(((?:\m_fga_error|\m_fga_unsupported)\s*\(|\mraise\M)[^;]*)', 'g') m
where p.pronamespace = 'permissions'::regnamespace;

select tap.plan((select count(*)::int from sites) + 4);

select tap.is(
    (select array_agg(fn || ': ' || left(regexp_replace(stmt, '\s+', ' ', 'g'), 80) order by fn) from raise_sites
      where stmt !~* '\mhint\s*=' and stmt !~* '\mhint\s*=>'),
    null::text[], 'guard: every raise and every _fga_error/_fga_unsupported call in the extension passes a hint');
-- the helpers' own raise statements forward the caller's message, so they are not sites
select tap.is((select count(*)::int from raise_sites where fn not in ('_fga_error', '_fga_unsupported')),
              (select count(*)::int from sites), 'guard: one row below per raise site in the extension');
select tap.is((select count(distinct site)::int from sites), (select count(*)::int from sites), 'each row is a different site');
select tap.is((select count(*)::int from raise_sites where fn in ('_fga_error', '_fga_unsupported')), 1,
              'the error helper raises once');

select tap.is(
    (select concat_ws('; ',
        case when e.st is null then 'no error' end,
        case when e.st is distinct from s.st then format('sqlstate %s, want %s', e.st, s.st) end,
        case when nullif(e.detail, '') is distinct from s.detail then format('detail %L, want %L', e.detail, s.detail) end,
        case when e.msg !~ s.msg then format('message %L does not match %L', e.msg, s.msg) end,
        case when coalesce(e.hint, '') = '' then 'no hint' end,
        case when s.hint is not null and e.hint !~ s.hint then format('hint %L does not match %L', e.hint, s.hint) end)
     from fga_test.error_of(s.stmt) e),
    '', s.site)
from sites s order by s.n;

select * from tap.finish();
