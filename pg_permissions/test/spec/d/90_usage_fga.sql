-- Goal: every example in usage/fga.md ("The OpenFGA model") works as written.
--
-- This file mirrors that page, section by section and in the same order, so the
-- state one section builds (the model, the tuples) is what the next one uses.
-- When you change an example on the page, change it here, and the other way
-- round. Statements without a result are copied from the page; queries that
-- return something appear as tap.is(<the same expression>, <the documented
-- answer>), and errors as fga_test.error_of(<the statement>).
\ir ../../fixtures/fga_suite.sql

select tap.plan(54);

-- ============================================================================
-- Writing a model
-- ============================================================================

-- The page writes model.fga and runs `fga model transform --file model.fga > model.json`.
-- This is that output for the page's model.fga, verbatim (openfga/cli v0.8.2):
\set model '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"metadata":{"relations":{"member":{"directly_related_user_types":[{"type":"user"},{"relation":"member","type":"team"}]}}},"relations":{"member":{"this":{}}},"type":"team"},{"metadata":{"relations":{"owner":{"directly_related_user_types":[{"type":"user"}]},"parent":{"directly_related_user_types":[{"type":"folder"}]},"viewer":{"directly_related_user_types":[{"type":"user"},{"relation":"member","type":"team"}]}}},"relations":{"owner":{"this":{}},"parent":{"this":{}},"viewer":{"union":{"child":[{"this":{}},{"computedUserset":{"relation":"owner"}},{"tupleToUserset":{"computedUserset":{"relation":"viewer"},"tupleset":{"relation":"parent"}}}]}}},"type":"folder"},{"metadata":{"relations":{"blocked":{"directly_related_user_types":[{"type":"user"}]},"can_view":{},"editor":{"directly_related_user_types":[{"type":"user"},{"relation":"member","type":"team"}]},"owner":{"directly_related_user_types":[{"type":"user"}]},"parent":{"directly_related_user_types":[{"type":"folder"}]},"viewer":{"directly_related_user_types":[{"type":"user"},{"type":"user","wildcard":{}},{"relation":"member","type":"team"}]}}},"relations":{"blocked":{"this":{}},"can_view":{"difference":{"base":{"computedUserset":{"relation":"viewer"}},"subtract":{"computedUserset":{"relation":"blocked"}}}},"editor":{"union":{"child":[{"this":{}},{"computedUserset":{"relation":"owner"}}]}},"owner":{"this":{}},"parent":{"this":{}},"viewer":{"union":{"child":[{"this":{}},{"computedUserset":{"relation":"editor"}},{"tupleToUserset":{"computedUserset":{"relation":"viewer"},"tupleset":{"relation":"parent"}}}]}}},"type":"document"}]}'

select permissions.fga_write_authorization_model(:'model') as model_id \gset
select tap.ok(:'model_id' ~ '^[0-9A-HJKMNP-TV-Z]{26}$', 'model: fga_write_authorization_model returns the new model id (a ULID)');
select tap.is((select count(*)::int from permissions.fga_read_authorization_models()), 1, 'model: fga_read_authorization_models lists it');
select tap.is(permissions.fga_read_authorization_model() ->> 'id', :'model_id', 'model: and it is the latest');

-- validation errors
select tap.is((fga_test.error_of($$
select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [
  {"type": "user"},
  {"type": "document",
   "relations": {"editor": {"this": {}}, "viewer": {"computedUserset": {"relation": "editr"}}},
   "metadata": {"relations": {"editor": {"directly_related_user_types": [{"type": "user"}]}}}}]}')
$$)).detail, 'openfga:2056 invalid_authorization_model', 'model: a computed relation that does not exist is 2056');
select tap.is((fga_test.error_of($$
select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [
  {"type": "user"},
  {"type": "document",
   "relations": {"editor": {"this": {}}, "viewer": {"computedUserset": {"relation": "editr"}}},
   "metadata": {"relations": {"editor": {"directly_related_user_types": [{"type": "user"}]}}}}]}')
$$)).msg, 'document#viewer: computed relation ''editr'' is not defined on type ''document''', 'model: the message names the relation');
select tap.is((fga_test.error_of($$
select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [
  {"type": "user"},
  {"type": "document",
   "relations": {"editor": {"this": {}}, "viewer": {"computedUserset": {"relation": "editr"}}},
   "metadata": {"relations": {"editor": {"directly_related_user_types": [{"type": "user"}]}}}}]}')
$$)).hint, 'Did you mean ''editor''? Relations on type ''document'': editor, viewer.', 'model: the hint suggests the nearest name');
-- no entrypoint
select tap.is((fga_test.error_of($$
select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [
  {"type": "user"},
  {"type": "document",
   "relations": {"viewer": {"computedUserset": {"relation": "reader"}}, "reader": {"computedUserset": {"relation": "viewer"}}}}]}')
$$)).msg, 'the definition of relation ''reader'' in object type ''document'' is invalid: no entrypoints defined (no path from document#reader to a concrete user type)',
    'model: relations that only refer to each other are refused');

-- ============================================================================
-- Tuples
-- ============================================================================

select permissions.fga_write('[
  {"user": "user:bob",            "relation": "member", "object": "team:eng"},
  {"user": "team:design#member",  "relation": "member", "object": "team:eng"},
  {"user": "user:carl",           "relation": "member", "object": "team:design"},
  {"user": "user:anne",           "relation": "owner",  "object": "folder:projects"},
  {"user": "team:eng#member",     "relation": "viewer", "object": "folder:projects"},
  {"user": "folder:projects",     "relation": "parent", "object": "folder:roadmaps"},
  {"user": "folder:roadmaps",     "relation": "parent", "object": "document:roadmap"},
  {"user": "user:dana",           "relation": "editor", "object": "document:roadmap"},
  {"user": "user:carl",           "relation": "blocked", "object": "document:roadmap"},
  {"user": "user:*",              "relation": "viewer", "object": "document:handbook"}
]');
select tap.pass('tuples: fga_write writes the page''s ten tuples');

select permissions.fga_write_tuple('user:erin', 'owner', 'document:notes');
select permissions.fga_write_tuple('user:erin', 'owner', 'document:notes');   -- no error: already there
select permissions.fga_delete_tuple('user:erin', 'owner', 'document:notes');
select tap.is(permissions.fga_check('user:erin', 'owner', 'document:notes'), false, 'tuples: fga_write_tuple and fga_delete_tuple are idempotent');

select permissions.fga_write(
  writes  => '[{"user": "user:erin", "relation": "editor", "object": "document:notes"}]',
  deletes => '{"tuple_keys": [{"user": "user:zed", "relation": "editor", "object": "document:notes"}], "on_missing": "ignore"}');
select tap.is(permissions.fga_check('user:erin', 'editor', 'document:notes'), true, 'tuples: writes and deletes in one call, on_missing ignore');

select tap.is((fga_test.error_of($$ select permissions.fga_write('[{"user": "user:erin", "relation": "editor", "object": "document:notes"}]') $$)).detail,
              'openfga:2017 write_failed_due_to_invalid_input', 'tuples: writing a tuple that exists is 2017');
select tap.is((fga_test.error_of($$ select permissions.fga_write('[{"user": "user:erin", "relation": "editor", "object": "document:notes"}]') $$)).hint,
              'Pass writes as {"tuple_keys": [...], "on_duplicate": "ignore"} to skip tuples that already exist.', 'tuples: the hint says how to skip it');
select tap.is((fga_test.error_of($$ select permissions.fga_write('[{"user": "user:*", "relation": "editor", "object": "document:notes"}]') $$)).detail,
              'openfga:2027 invalid_tuple', 'tuples: a tuple the type restrictions do not allow is 2027');
select tap.is((fga_test.error_of($$ select permissions.fga_write('[{"user": "user:*", "relation": "editor", "object": "document:notes"}]') $$)).hint,
              '''document#editor'' allows users of type: team#member, user.', 'tuples: the hint lists what the relation allows');

-- ============================================================================
-- Check
-- ============================================================================

select tap.is(permissions.fga_check('user:anne', 'viewer', 'document:roadmap'), true, 'check: anne owns folder:projects, two parents up');
select tap.is(permissions.fga_check('user:bob',  'viewer', 'document:roadmap'), true, 'check: bob through team:eng, a viewer of folder:projects');
select tap.is(permissions.fga_check('user:carl', 'viewer', 'document:roadmap'), true, 'check: carl through team:design, a member of team:eng');
select tap.is(permissions.fga_check('user:carl', 'can_view', 'document:roadmap'), false, 'check: but carl is blocked');
select tap.is(permissions.fga_check('user:dana', 'viewer', 'document:roadmap'), true, 'check: dana edits it, so she views it');
select tap.is(permissions.fga_check('user:erin', 'viewer', 'document:roadmap'), false, 'check: erin does not');
select tap.is(permissions.fga_check('user:erin', 'viewer', 'document:handbook'), true, 'check: everyone views the handbook (user:*)');

-- ============================================================================
-- ListObjects
-- ============================================================================

select tap.set_eq(array(select permissions.fga_list_objects('user:bob', 'document', 'viewer')),
                  '{document:handbook,document:roadmap}', 'list objects: what bob views');
select tap.set_eq(array(select permissions.fga_list_objects('user:carl', 'document', 'can_view')),
                  '{document:handbook}', 'list objects: carl, net of the block');
select tap.set_eq(array(select permissions.fga_list_objects('user:anne', 'folder', 'viewer')),
                  '{folder:projects,folder:roadmaps}', 'list objects: the folders anne views');

-- ============================================================================
-- ListUsers
-- ============================================================================

select tap.set_eq(array(select permissions.fga_list_users('document:roadmap', 'viewer', '{user}')),
                  '{user:anne,user:bob,user:carl,user:dana}', 'list users: who views the roadmap');
select tap.set_eq(array(select permissions.fga_list_users('document:roadmap', 'can_view', '{user}')),
                  '{user:anne,user:bob,user:dana}', 'list users: net of the block');
select tap.set_eq(array(select permissions.fga_list_users('document:roadmap', 'viewer', '{team#member}')),
                  '{team:eng#member,team:design#member}', 'list users: the team usersets');
select tap.set_eq(array(select permissions.fga_list_users('document:handbook', 'viewer', '{user}')),
                  '{user:*}', 'list users: a public document returns the wildcard');

-- ============================================================================
-- Read
-- ============================================================================

select tap.is((select jsonb_array_length(tuples) from permissions.fga_read('document:roadmap')), 3, 'read: the tuples on one object');
select tap.set_eq(array(select t #>> '{key,relation}' || ' ' || (t #>> '{key,user}')
                        from permissions.fga_read('document:roadmap') r, jsonb_array_elements(r.tuples) t),
                  '{"parent folder:roadmaps","editor user:dana","blocked user:carl"}', 'read: as rows');
select tap.is((select continuation_token from permissions.fga_read('document:roadmap')), '', 'read: the last page has an empty token');

-- page by page: every tuple on a folder, one per page
select tuples, continuation_token as token from permissions.fga_read('folder:', p_page_size => 1) \gset
select tap.is(:'tuples'::jsonb #>> '{0,key,object}', 'folder:projects', 'read: page 1');
select tuples, continuation_token as token from permissions.fga_read('folder:', p_page_size => 1, p_continuation_token => :'token') \gset
select tap.is(:'tuples'::jsonb #>> '{0,key,object}', 'folder:projects', 'read: page 2');
select tuples, continuation_token as token from permissions.fga_read('folder:', p_page_size => 1, p_continuation_token => :'token') \gset
select tap.is(:'tuples'::jsonb #>> '{0,key,object}', 'folder:roadmaps', 'read: page 3');
select tap.is(:'token'::text, '', 'read: the third page is the last');

-- a recursive walk over every page
select tap.is((
with recursive pages(tuples, token, n) as (
    select r.tuples, r.continuation_token, 1 from permissions.fga_read(p_page_size => 4) r
  union all
    select r.tuples, r.continuation_token, n + 1
    from pages, permissions.fga_read(p_page_size => 4, p_continuation_token => pages.token) r
    where pages.token <> ''
)
select sum(jsonb_array_length(tuples))::int from pages), 11, 'read: a recursive query walks every page');

-- ============================================================================
-- Contextual tuples
-- ============================================================================

select tap.is(permissions.fga_check('user:erin', 'viewer', 'document:roadmap',
    contextual_tuples => '[{"user": "user:erin", "relation": "member", "object": "team:eng"}]'), true,
    'contextual tuples: erin, if she were in team:eng');
select tap.set_eq(array(select permissions.fga_list_objects('user:erin', 'document', 'viewer',
    contextual_tuples => '[{"user": "user:erin", "relation": "member", "object": "team:eng"}]')),
    '{document:handbook,document:notes,document:roadmap}', 'contextual tuples: in ListObjects too');
select tap.is(permissions.fga_check('user:erin', 'viewer', 'document:roadmap'), false, 'contextual tuples: nothing was written');

-- ============================================================================
-- Errors and limits
-- ============================================================================

select tap.is((fga_test.error_of($$ select permissions.fga_check('user:anne', 'viewr', 'document:roadmap') $$)).msg,
              'relation ''document#viewr'' not found', 'errors: the message');
select tap.is((fga_test.error_of($$ select permissions.fga_check('user:anne', 'viewr', 'document:roadmap') $$)).detail,
              'openfga:2000 validation_error', 'errors: the OpenFGA code in DETAIL');
select tap.is((fga_test.error_of($$ select permissions.fga_check('user:anne', 'viewr', 'document:roadmap') $$)).hint,
              'Did you mean ''viewer''? Relations on type ''document'': blocked, can_view, editor, owner, parent, viewer.', 'errors: the hint');
select tap.is((fga_test.error_of($$ select permissions.fga_check('user:anne', 'viewr', 'document:roadmap') $$)).st,
              '22023', 'errors: SQLSTATE 22023');
select tap.is((fga_test.error_of($$ select permissions.fga_list_objects('user:anne', 'document', 'viewr') $$)).detail,
              'openfga:2022 relation_not_found', 'errors: ListObjects with a typo is 2022');

select tap.is((fga_test.error_of($$
select permissions.fga_write((select jsonb_agg(jsonb_build_object('user', 'user:u' || g, 'relation', 'viewer', 'object', 'document:big'))
                              from generate_series(1, 101) g))
$$)).detail, 'openfga:2053 exceeded_entity_limit', 'limits: more than 100 tuple keys in one write is 2053');

begin;
select permissions.fga_write((select jsonb_agg(jsonb_build_object('user', 'user:u' || g, 'relation', 'viewer', 'object', 'document:big'))
                              from generate_series(1, 100) g));
select permissions.fga_write((select jsonb_agg(jsonb_build_object('user', 'user:u' || g, 'relation', 'viewer', 'object', 'document:big'))
                              from generate_series(101, 200) g));
select tap.is((select count(*)::int from permissions.fga_list_users('document:big', 'viewer', '{user}')), 200,
              'limits: batches of 100 in one transaction');
rollback;

-- ============================================================================
-- Changing the model
-- ============================================================================

-- the same model without `blocked` and `can_view`
select permissions.fga_write_authorization_model(
    jsonb_set(:'model'::jsonb, '{type_definitions,3}',
              (:'model'::jsonb #> '{type_definitions,3}') #- '{relations,blocked}' #- '{relations,can_view}'
                #- '{metadata,relations,blocked}' #- '{metadata,relations,can_view}')) as model_v2 \gset
select tap.is(permissions.fga_read_authorization_model() ->> 'id', :'model_v2', 'model change: the new model is the latest');
select tap.is((fga_test.error_of($$ select permissions.fga_check('user:carl', 'can_view', 'document:roadmap') $$)).detail,
              'openfga:2000 validation_error', 'model change: can_view is gone from the latest model');
select tap.is(permissions.fga_check('user:carl', 'can_view', 'document:roadmap', authorization_model_id => :'model_id'), false,
              'model change: the old model id still evaluates with the old model');
select tap.is((select jsonb_array_length(tuples) from permissions.fga_read('document:roadmap', 'blocked')), 1,
              'model change: the blocked tuple is still stored');

-- ============================================================================
-- Privileges
-- ============================================================================

begin;
set local role authenticated;
select tap.throws_ok($$ select permissions.fga_check('user:anne', 'viewer', 'document:roadmap') $$, '42501', 'privileges: clients cannot call fga_check');
select tap.throws_ok($$ select permissions.fga_write_tuple('user:erin', 'owner', 'document:roadmap') $$, '42501', 'privileges: or write tuples');
select tap.lives_ok($$ select permissions.fga_check_current('viewer', 'document:roadmap') $$, 'privileges: clients can call fga_check_current');
commit;

grant execute on function
    permissions.fga_write_authorization_model(jsonb),
    permissions.fga_read_authorization_model(text),
    permissions.fga_read_authorization_models(),
    permissions.fga_write(jsonb, jsonb, text),
    permissions.fga_write_tuple(text, text, text),
    permissions.fga_delete_tuple(text, text, text),
    permissions.fga_read(text, text, text, integer, text),
    permissions.fga_check(text, text, text, jsonb, text),
    permissions.fga_list_objects(text, text, text, jsonb, text),
    permissions.fga_list_users(text, text, text[], jsonb, text)
to service_role;
begin;
set local role service_role;
select tap.is(permissions.fga_check('user:anne', 'viewer', 'document:roadmap'), true, 'privileges: a granted backend role can call fga_check');
commit;

select * from tap.finish();
