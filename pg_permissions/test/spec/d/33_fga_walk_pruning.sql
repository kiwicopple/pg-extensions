-- Goal: ListObjects' forward walk (one recursive CTE over fga_walk_steps,
-- pruned to the nodes that can reach the target; research/designs/d-per-model.md §5)
-- returns what Check says for every object, for every relation of a model
-- with several targets, cycles, a wildcard, tupleToUserset and userset users,
-- and that its depth rule is unchanged: an answer that needs 25 levels or more
-- raises 2002, including the case where the walk stops at level 25 before
-- reaching everything (it then finishes without levels).
\ir ../../fixtures/fga_suite.sql
\ir ../../fixtures/fga_compare.sql

-- type user
-- type org
--   relations
--     define member: [user]
-- type team
--   relations
--     define member: [user, user:*, team#member]
-- type folder
--   relations
--     define parent: [org]
--     define viewer: [user, team#member] or member from parent
-- type document
--   relations
--     define parent: [folder]
--     define owner: [user]
--     define viewer: [user, team#member] or owner or viewer from parent
-- type chain
--   relations
--     define member: [user, chain#member]
-- type report
--   relations
--     define viewer: [user, chain#member]
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "org", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [
       {"type": "user"}, {"type": "user", "wildcard": {}}, {"type": "team", "relation": "member"}]}}}},
    {"type": "folder",
     "relations": {
       "parent": {"this": {}},
       "viewer": {"union": {"child": [
         {"this": {}},
         {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "member"}}}]}}},
     "metadata": {"relations": {
       "parent": {"directly_related_user_types": [{"type": "org"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]}}}},
    {"type": "document",
     "relations": {
       "parent": {"this": {}},
       "owner": {"this": {}},
       "viewer": {"union": {"child": [
         {"this": {}},
         {"computedUserset": {"relation": "owner"}},
         {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}}},
     "metadata": {"relations": {
       "parent": {"directly_related_user_types": [{"type": "folder"}]},
       "owner": {"directly_related_user_types": [{"type": "user"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]}}}},
    {"type": "chain", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user"}, {"type": "chain", "relation": "member"}]}}}},
    {"type": "report", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "chain", "relation": "member"}]}}}}
  ]}$m$::jsonb) is not null as model_written;

-- teams t1 and t2 contain each other; everyone is in t3
select permissions.fga_write('[
  {"user": "user:a", "relation": "member", "object": "org:o1"},
  {"user": "org:o1", "relation": "parent", "object": "folder:f1"},
  {"user": "team:t2#member", "relation": "viewer", "object": "folder:f2"},
  {"user": "user:b", "relation": "viewer", "object": "folder:f3"},
  {"user": "user:a", "relation": "member", "object": "team:t1"},
  {"user": "team:t1#member", "relation": "member", "object": "team:t2"},
  {"user": "team:t2#member", "relation": "member", "object": "team:t1"},
  {"user": "user:*", "relation": "member", "object": "team:t3"},
  {"user": "user:c", "relation": "member", "object": "team:t2"},
  {"user": "folder:f1", "relation": "parent", "object": "document:d1"},
  {"user": "folder:f2", "relation": "parent", "object": "document:d2"},
  {"user": "team:t3#member", "relation": "viewer", "object": "document:d3"},
  {"user": "user:b", "relation": "owner", "object": "document:d4"},
  {"user": "user:c", "relation": "viewer", "object": "document:d5"},
  {"user": "folder:f3", "relation": "parent", "object": "document:d6"},
  {"user": "team:t1#member", "relation": "viewer", "object": "document:d7"}]');

-- chain:k<j+1> is in chain:k<j>, j = 0..29; report:r1 is shared with k0, r2 with k28.
-- Levels to r1: user:z23 (in k23) 24, user:z24 (in k24) 25; user:y and user:x
-- are in k30 (31 levels), y also has r1 directly.
select permissions.fga_write(jsonb_build_object('tuple_keys', jsonb_agg(k)))
from (
    select jsonb_build_object('user', 'chain:k' || (j + 1) || '#member', 'relation', 'member', 'object', 'chain:k' || j) as k
    from generate_series(0, 29) j
  union all
    select x::jsonb from unnest(array[
      '{"user": "user:z23", "relation": "member", "object": "chain:k23"}',
      '{"user": "user:z24", "relation": "member", "object": "chain:k24"}',
      '{"user": "user:y", "relation": "member", "object": "chain:k30"}',
      '{"user": "user:x", "relation": "member", "object": "chain:k30"}',
      '{"user": "chain:k0#member", "relation": "viewer", "object": "report:r1"}',
      '{"user": "chain:k28#member", "relation": "viewer", "object": "report:r2"}',
      '{"user": "user:y", "relation": "viewer", "object": "report:r1"}']) x
) t;

select tap.plan(73);

-- every relation outside the chain, for plain users, the wildcard, a userset
-- and objects as users: ListObjects = { o | Check(o) }
select tap.is(fga_cmp.list_objects(u, split_part(tr, '#', 1), split_part(tr, '#', 2)), 'ok',
              format('list_objects(%s, %s) matches check', u, tr))
from unnest('{user:a,user:b,user:c,user:*,team:t1#member,team:t2#member,folder:f1,org:o1}'::text[]) u
cross join unnest('{org#member,team#member,folder#parent,folder#viewer,document#parent,document#owner,document#viewer}'::text[]) tr;

-- pruning is compiled: a folder list never reads document tuples, a document list does
select tap.is((select count(*)::int from permissions.fga_walk_steps s
               where s.target_type = 'folder' and s.target_relation = 'viewer' and s.object_type = 'document'),
              0, 'the steps toward folder#viewer never yield a document');
select tap.ok(exists (select 1 from permissions.fga_walk_steps s
                      where s.target_type = 'document' and s.target_relation = 'viewer'
                        and s.src_type = 'team' and s.src_relation = 'member' and s.object_type = 'team' and s.expand),
              'toward document#viewer a team member expands into its parent teams');

-- contextual tuples walk like stored ones
select tap.is(fga_cmp.list_objects('user:b', 'document', 'viewer',
              '[{"user": "user:b", "relation": "member", "object": "team:t2"}]'), 'ok',
              'list_objects with a contextual team membership matches check');
select tap.is(fga_cmp.list_objects('user:a', 'folder', 'viewer',
              '[{"user": "team:t1#member", "relation": "viewer", "object": "folder:f4"}]'), 'ok',
              'list_objects with a contextual folder share matches check');
select tap.set_eq(array(select permissions.fga_list_objects('user:a', 'folder', 'viewer',
                        '[{"user": "team:t1#member", "relation": "viewer", "object": "folder:f4"}]')),
                  '{folder:f1,folder:f2,folder:f4}', 'user:a views f1 (org), f2 (team cycle) and f4 (contextual)');

-- depth: 24 levels is fine, 25 is too complex
select tap.set_eq(array(select permissions.fga_list_objects('user:z23', 'report', 'viewer')), '{report:r1}',
                  'a 24-level answer is listed');
select tap.is(fga_cmp.try($$ select count(*)::text from permissions.fga_list_objects('user:z24', 'report', 'viewer') $$),
              'error openfga:2002', 'a 25-level answer raises 2002');
select tap.is(fga_cmp.list_objects('user:z24', 'report', 'viewer'), 'ok', 'and check agrees');
-- the walk stops expanding at level 25 (k5 for user:y and user:x): r1 is
-- also direct for y, so nothing behind the stop is new and the answer stands
select tap.set_eq(array(select permissions.fga_list_objects('user:y', 'report', 'viewer')), '{report:r1,report:r2}',
                  'a node first reached at level 25 that leads only to known objects: no error');
select tap.is(fga_cmp.list_objects('user:y', 'report', 'viewer'), 'ok', 'and check agrees');
-- for x, r1 lies only behind the stop
select tap.is(fga_cmp.try($$ select count(*)::text from permissions.fga_list_objects('user:x', 'report', 'viewer') $$),
              'error openfga:2002', 'an object only behind the level-25 stop raises 2002');
select tap.is(fga_cmp.list_objects('user:x', 'report', 'viewer'), 'ok', 'and check agrees');
select tap.is(fga_cmp.try($$ select count(*)::text from permissions.fga_list_objects('user:x', 'chain', 'member') $$),
              'error openfga:2002', 'listing the chain itself raises 2002 too');
-- a userset user's own relation weighs 0: from chain:k24#member, r1 is 24 levels away, from k25 25
select tap.is(fga_cmp.try($$ select string_agg(x, ',') from permissions.fga_list_objects('chain:k24#member', 'report', 'viewer') x $$),
              'report:r1', 'a userset user 24 levels from the answer lists it');
select tap.is(fga_cmp.list_objects('chain:k24#member', 'report', 'viewer'), 'ok', 'and check agrees');
select tap.is(fga_cmp.try($$ select count(*)::text from permissions.fga_list_objects('chain:k25#member', 'report', 'viewer') $$),
              'error openfga:2002', 'a userset user 25 levels from the answer raises 2002');
select tap.is(fga_cmp.list_objects('chain:k25#member', 'report', 'viewer'), 'ok', 'and check agrees');

select * from tap.finish();
