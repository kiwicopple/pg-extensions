-- Goal: pin D's answer for a cycle under a subtract where the subtract is
-- monotone (designs/d-per-model.md §5, §8). D follows OpenFGA's default
-- strategy (LocalChecker.hasCycle, then exclusion() in internal/graph/check.go):
-- the cycle makes the difference false. This is NOT what OpenFGA answers for
-- this exact model. Checked against openfga/openfga v1.22.1 (commit 44054f5,
-- image sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671,
-- memory datastore, default settings and enable-check-optimizations, 600+ runs
-- over fresh containers and stores): check(user:jon, viewer, document:1) is
-- true, list_objects returns {document:1, document:3}, list_users returns {};
-- blocked alone is false and document:3 is true, as here. For a recursive
-- userset like `blocked: [user, document#blocked]` the planner picks the
-- recursive resolver, which never reports a cycle; its cold-start priors
-- (150 ms against 500 ms for the default resolver) make that choice in
-- practice every time. The same model with a second weight for `user` on
-- blocked (so the recursive resolver doesn't apply) gives false, as D does.
-- So the check and list_objects assertions below pin D's deliberate
-- difference, not OpenFGA's answer. The upstream suite has no such case.
-- Under a subtract D always uses the recursive evaluator, never the set-based
-- search (which would compute plain false for blocked).
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
