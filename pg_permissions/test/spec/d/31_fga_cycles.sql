-- Goal: pin D's answer for a cycle under a subtract where the subtract is
-- monotone (designs/d-per-model.md §5, §8). This is D's choice, not a verified
-- OpenFGA answer: OpenFGA's default strategy (LocalChecker.hasCycle, then
-- exclusion() in internal/graph/check.go) makes the difference false, but for
-- a recursive userset like `blocked: [user, document#blocked]` its planner
-- may pick the recursive resolver instead, which never reports a cycle and
-- would answer true. The upstream suite has no such case. D follows the
-- default strategy: under a subtract it always uses the recursive evaluator,
-- never the set-based search (which would compute plain false for blocked).
\ir ../../fixtures/fga_suite.sql

-- type user
-- type document
--   relations
--     define blocked: [user, document#blocked]
--     define viewer: [user] but not blocked
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "document",
     "relations": {
       "blocked": {"this": {}},
       "viewer": {"difference": {"base": {"this": {}}, "subtract": {"computedUserset": {"relation": "blocked"}}}}},
     "metadata": {"relations": {
       "blocked": {"directly_related_user_types": [{"type": "user"}, {"type": "document", "relation": "blocked"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}$m$::jsonb);
select permissions.fga_write('[
  {"user": "user:jon", "relation": "viewer", "object": "document:1"},
  {"user": "user:jon", "relation": "viewer", "object": "document:3"},
  {"user": "document:2#blocked", "relation": "blocked", "object": "document:1"},
  {"user": "document:1#blocked", "relation": "blocked", "object": "document:2"}]');

select tap.plan(5);

select tap.is(permissions.fga_check('user:jon', 'blocked', 'document:1'), false, 'blocked alone: the cycle resolves to false');
select tap.is(permissions.fga_check('user:jon', 'viewer', 'document:1'), false, 'but a cycle in the subtract makes the difference false');
select tap.is(permissions.fga_check('user:jon', 'viewer', 'document:3'), true, 'without the cycle the viewer tuple counts');
select tap.set_eq(array(select permissions.fga_list_objects('user:jon', 'document', 'viewer')), '{document:3}', 'list_objects agrees with check');
select tap.set_eq(array(select permissions.fga_list_users('document:1', 'viewer', '{user}')), '{}'::text[], 'list_users agrees with check');

select * from tap.finish();
