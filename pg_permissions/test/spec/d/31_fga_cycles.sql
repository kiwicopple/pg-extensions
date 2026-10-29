-- Goal: pin D's answer for a cycle under a subtract where the subtracted
-- relation is monotone and positively recursive (designs/d-per-model.md §5,
-- §8). D uses least-fixpoint semantics there: a cycle of usersets with no user
-- in it contributes nobody, so `blocked` is empty and `viewer: [user] but not
-- blocked` holds. Check, ListObjects and ListUsers agree. Recursion through
-- negation (a relation that reaches itself through a subtract, upstream
-- `true_butnot_cycle_return_false`) keeps OpenFGA's cycle rule and is covered
-- by the vendored suite.
--
-- OpenFGA v1.22.1 (commit 44054f5, image
-- sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671,
-- memory datastore) also answers Check and ListObjects true here (its planner
-- picks the recursive resolver for `blocked: [user, document#blocked]`), but
-- its ListUsers on document:1 returns nothing, and adding an unused path to
-- the model (the control model below: blocked also takes team#member, which
-- reaches users through group#member, with no team or group tuples) flips its
-- Check to false. D gives the same answers for both models. Reported upstream:
-- pg_permissions/upstream/openfga-cycle-but-not-inconsistency.md.
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
  ]}$m$::jsonb) as m1 \gset

-- control: the same plus an unused path to users for blocked
-- type user
-- type group
--   relations
--     define member: [user]
-- type team
--   relations
--     define member: [group#member]
-- type document
--   relations
--     define blocked: [user, document#blocked, team#member]
--     define viewer: [user] but not blocked
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "group", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "group", "relation": "member"}]}}}},
    {"type": "document",
     "relations": {
       "blocked": {"this": {}},
       "viewer": {"difference": {"base": {"this": {}}, "subtract": {"computedUserset": {"relation": "blocked"}}}}},
     "metadata": {"relations": {
       "blocked": {"directly_related_user_types": [
         {"type": "user"}, {"type": "document", "relation": "blocked"}, {"type": "team", "relation": "member"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}$m$::jsonb) as m2 \gset

select permissions.fga_write('[
  {"user": "user:jon", "relation": "viewer", "object": "document:1"},
  {"user": "user:jon", "relation": "viewer", "object": "document:3"},
  {"user": "document:2#blocked", "relation": "blocked", "object": "document:1"},
  {"user": "document:1#blocked", "relation": "blocked", "object": "document:2"}]', null, :'m1');

select tap.plan(20);

-- the cycle bans nobody, in both models
select tap.is(permissions.fga_check('user:jon', 'blocked', 'document:1', null, m), false,
              format('%s: blocked alone: the cycle contributes nobody', name))
from (values ('model', :'m1'), ('control model', :'m2')) v(name, m);
select tap.is(permissions.fga_check('user:jon', 'viewer', 'document:1', null, m), true,
              format('%s: a cycle in the subtract doesn''t make the difference false', name))
from (values ('model', :'m1'), ('control model', :'m2')) v(name, m);
select tap.is(permissions.fga_check('user:jon', 'viewer', 'document:3', null, m), true,
              format('%s: without the cycle the viewer tuple counts', name))
from (values ('model', :'m1'), ('control model', :'m2')) v(name, m);
select tap.set_eq(array(select permissions.fga_list_objects('user:jon', 'document', 'viewer', null, m)),
                  '{document:1,document:3}', format('%s: list_objects agrees with check', name))
from (values ('model', :'m1'), ('control model', :'m2')) v(name, m);
select tap.set_eq(array(select permissions.fga_list_users('document:1', 'viewer', '{user}', null, m)),
                  '{user:jon}', format('%s: list_users agrees with check', name))
from (values ('model', :'m1'), ('control model', :'m2')) v(name, m);

-- blocking jon on document:2 blocks him on document:1 too, through the cycle
select tap.is(permissions.fga_check('user:jon', 'viewer', 'document:1',
              '[{"user": "user:jon", "relation": "blocked", "object": "document:2"}]', :'m1'), false,
              'jon blocked on document:2: not a viewer of document:1 (document:2#blocked is blocked on it)');
select tap.set_eq(array(select permissions.fga_list_objects('user:jon', 'document', 'viewer',
                        '[{"user": "user:jon", "relation": "blocked", "object": "document:2"}]', :'m1')),
                  '{document:3}', 'list_objects agrees');
select tap.set_eq(array(select permissions.fga_list_users('document:1', 'viewer', '{user}',
                        '[{"user": "user:jon", "relation": "blocked", "object": "document:2"}]', :'m1')),
                  '{}'::text[], 'list_users agrees');

-- break the cycle (document:2 no longer takes document:1's blocked)
select permissions.fga_write(null, '[{"user": "document:1#blocked", "relation": "blocked", "object": "document:2"}]');
select tap.is(permissions.fga_check('user:jon', 'viewer', 'document:1', null, :'m1'), true,
              'cycle broken: jon is a viewer of document:1');
select tap.set_eq(array(select permissions.fga_list_objects('user:jon', 'document', 'viewer', null, :'m1')),
                  '{document:1,document:3}', 'cycle broken: list_objects agrees');

-- then block jon on document:2, where he is also a viewer
select permissions.fga_write('[
  {"user": "user:jon", "relation": "blocked", "object": "document:2"},
  {"user": "user:jon", "relation": "viewer", "object": "document:2"}]', null, :'m1');
select tap.is(permissions.fga_check('user:jon', 'viewer', 'document:2', null, :'m1'), false,
              'jon blocked on document:2: not a viewer of it');
select tap.is(permissions.fga_check('user:jon', 'viewer', 'document:1', null, :'m1'), false,
              'and not of document:1, which takes document:2''s blocked');
select tap.set_eq(array(select permissions.fga_list_objects('user:jon', 'document', 'viewer', null, :'m1')),
                  '{document:3}', 'list_objects agrees');
select tap.set_eq(array(select permissions.fga_list_users('document:1', 'viewer', '{user}', null, :'m1')),
                  '{}'::text[], 'list_users agrees');
select tap.set_eq(array(select permissions.fga_list_objects('user:jon', 'document', 'viewer', null, :'m2')),
                  '{document:3}', 'the control model agrees');

select * from tap.finish();
