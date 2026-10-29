-- Goal: ListObjects and ListUsers on `base but not subtract` evaluated
-- set-based (designs/d-per-model.md §5: the walk to the base minus the walk to
-- the subtract) give exactly the per-candidate answer (_fga_rec on every
-- candidate, which is also what Check computes): for a computed and a
-- tupleToUserset subtract, a cyclic team graph and a chain in the base,
-- wildcards on both sides, userset users, contextual tuples, and the depth
-- limit (a base 25 levels deep raises 2002 unless the subtract removes it; a
-- recursive subtract has its removals rechecked, so one too deep raises).
-- Relations outside the set-based form (a union subtract, a non-monotone base,
-- an intersection) keep the per-candidate path; the compiled flags say which
-- is which. A recursive subtract (d/31_fga_cycles' shape) is set-based: both
-- paths compute its least fixpoint.
\ir ../../fixtures/fga_suite.sql
\ir ../../fixtures/fga_compare.sql

-- type user
-- type team
--   relations
--     define member: [user, user:*, team#member]
-- type group
--   relations
--     define member: [user, user:*]
-- type chain
--   relations
--     define member: [user, chain#member]
-- type folder
--   relations
--     define viewer: [user, team#member]
--     define blocked: [user, group#member]
-- type document
--   relations
--     define parent: [folder]
--     define editor: [user]
--     define blocked: [user, user:*, group#member]
--     define banned: [user, document#banned]
--     define viewer: ([user, user:*, team#member, chain#member] or editor or viewer from parent) but not blocked
--     define viewer2: [user, team#member] but not blocked from parent
--     define viewer3: [user, team#member] but not (blocked or editor)
--     define viewer4: editor but not banned
--     define viewer5: ([user] or viewer) but not blocked
--     define viewer6: viewer and editor
--     define viewer7: [user] but not banned       (d/31_fga_cycles' shape)
--     define cblock: [user, chain#member]
--     define viewer8: [user] but not cblock
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [
       {"type": "user"}, {"type": "user", "wildcard": {}}, {"type": "team", "relation": "member"}]}}}},
    {"type": "group", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [
       {"type": "user"}, {"type": "user", "wildcard": {}}]}}}},
    {"type": "chain", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [
       {"type": "user"}, {"type": "chain", "relation": "member"}]}}}},
    {"type": "folder",
     "relations": {"viewer": {"this": {}}, "blocked": {"this": {}}},
     "metadata": {"relations": {
       "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]},
       "blocked": {"directly_related_user_types": [{"type": "user"}, {"type": "group", "relation": "member"}]}}}},
    {"type": "document",
     "relations": {
       "parent": {"this": {}},
       "editor": {"this": {}},
       "blocked": {"this": {}},
       "banned": {"this": {}},
       "viewer": {"difference": {
         "base": {"union": {"child": [
           {"this": {}},
           {"computedUserset": {"relation": "editor"}},
           {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}},
         "subtract": {"computedUserset": {"relation": "blocked"}}}},
       "viewer2": {"difference": {
         "base": {"this": {}},
         "subtract": {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "blocked"}}}}},
       "viewer3": {"difference": {
         "base": {"this": {}},
         "subtract": {"union": {"child": [
           {"computedUserset": {"relation": "blocked"}},
           {"computedUserset": {"relation": "editor"}}]}}}},
       "viewer4": {"difference": {
         "base": {"computedUserset": {"relation": "editor"}},
         "subtract": {"computedUserset": {"relation": "banned"}}}},
       "viewer5": {"difference": {
         "base": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "viewer"}}]}},
         "subtract": {"computedUserset": {"relation": "blocked"}}}},
       "viewer6": {"intersection": {"child": [
         {"computedUserset": {"relation": "viewer"}},
         {"computedUserset": {"relation": "editor"}}]}},
       "viewer7": {"difference": {
         "base": {"this": {}},
         "subtract": {"computedUserset": {"relation": "banned"}}}},
       "cblock": {"this": {}},
       "viewer8": {"difference": {
         "base": {"this": {}},
         "subtract": {"computedUserset": {"relation": "cblock"}}}}},
     "metadata": {"relations": {
       "parent": {"directly_related_user_types": [{"type": "folder"}]},
       "editor": {"directly_related_user_types": [{"type": "user"}]},
       "blocked": {"directly_related_user_types": [
         {"type": "user"}, {"type": "user", "wildcard": {}}, {"type": "group", "relation": "member"}]},
       "banned": {"directly_related_user_types": [{"type": "user"}, {"type": "document", "relation": "banned"}]},
       "viewer": {"directly_related_user_types": [
         {"type": "user"}, {"type": "user", "wildcard": {}}, {"type": "team", "relation": "member"},
         {"type": "chain", "relation": "member"}]},
       "viewer2": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]},
       "viewer3": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]},
       "viewer5": {"directly_related_user_types": [{"type": "user"}]},
       "viewer7": {"directly_related_user_types": [{"type": "user"}]},
       "cblock": {"directly_related_user_types": [{"type": "user"}, {"type": "chain", "relation": "member"}]},
       "viewer8": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}$m$::jsonb) is not null as model_written;

-- teams t1 and t2 contain each other; everyone is in t3 and g2.
-- document:dd is 28 levels from user:deep through chain:k26 .. k0.
select permissions.fga_write('[
  {"user": "user:a", "relation": "member", "object": "team:t1"},
  {"user": "team:t1#member", "relation": "member", "object": "team:t2"},
  {"user": "team:t2#member", "relation": "member", "object": "team:t1"},
  {"user": "user:*", "relation": "member", "object": "team:t3"},
  {"user": "user:c", "relation": "member", "object": "team:t2"},
  {"user": "user:b", "relation": "member", "object": "group:g1"},
  {"user": "user:*", "relation": "member", "object": "group:g2"},
  {"user": "team:t1#member", "relation": "viewer", "object": "folder:f1"},
  {"user": "user:b", "relation": "viewer", "object": "folder:f2"},
  {"user": "user:c", "relation": "blocked", "object": "folder:f1"},
  {"user": "group:g1#member", "relation": "blocked", "object": "folder:f2"},
  {"user": "folder:f1", "relation": "parent", "object": "document:d1"},
  {"user": "folder:f2", "relation": "parent", "object": "document:d2"},
  {"user": "team:t3#member", "relation": "viewer", "object": "document:d3"},
  {"user": "user:*", "relation": "viewer", "object": "document:d4"},
  {"user": "user:b", "relation": "editor", "object": "document:d5"},
  {"user": "team:t2#member", "relation": "viewer", "object": "document:d6"},
  {"user": "user:d", "relation": "viewer", "object": "document:d7"},
  {"user": "team:t1#member", "relation": "viewer", "object": "document:d8"},
  {"user": "user:a", "relation": "blocked", "object": "document:d3"},
  {"user": "group:g1#member", "relation": "blocked", "object": "document:d4"},
  {"user": "user:*", "relation": "blocked", "object": "document:d6"},
  {"user": "group:g2#member", "relation": "blocked", "object": "document:d8"},
  {"user": "user:a", "relation": "viewer2", "object": "document:d1"},
  {"user": "user:b", "relation": "viewer2", "object": "document:d2"},
  {"user": "team:t1#member", "relation": "viewer2", "object": "document:d2"},
  {"user": "user:c", "relation": "viewer2", "object": "document:d9"},
  {"user": "user:b", "relation": "viewer3", "object": "document:d5"},
  {"user": "user:d", "relation": "viewer3", "object": "document:d7"},
  {"user": "team:t1#member", "relation": "viewer3", "object": "document:d3"},
  {"user": "user:a", "relation": "editor", "object": "document:d1"},
  {"user": "document:d2#banned", "relation": "banned", "object": "document:d1"},
  {"user": "document:d1#banned", "relation": "banned", "object": "document:d2"},
  {"user": "user:a", "relation": "viewer5", "object": "document:d7"},
  {"user": "user:a", "relation": "viewer7", "object": "document:d1"},
  {"user": "user:a", "relation": "viewer7", "object": "document:d3"},
  {"user": "user:deep", "relation": "viewer8", "object": "document:dx"},
  {"user": "user:a", "relation": "viewer8", "object": "document:dx"},
  {"user": "chain:k0#member", "relation": "cblock", "object": "document:dx"},
  {"user": "chain:k0#member", "relation": "viewer", "object": "document:dd"},
  {"user": "user:deep", "relation": "member", "object": "chain:k26"}]');
select permissions.fga_write(jsonb_agg(jsonb_build_object(
    'user', 'chain:k' || (j + 1) || '#member', 'relation', 'member', 'object', 'chain:k' || j)))
from generate_series(0, 25) j;

select tap.plan(145);

-- which relations are set-based
select tap.is(array(select format('%s:%s:%s:%s', r.relation, coalesce(r.diff_relation, '-'), coalesce(r.diff_tupleset, '-'),
                                  case when r.diff_recheck then 'recheck' else '-' end)
                    from permissions.fga_relations r
                    where r.model_id = (select id from permissions.fga_models order by seq desc limit 1)
                      and r.type = 'document' and r.relation like 'viewer%'
                    order by r.relation),
              '{viewer:blocked:-:-,viewer2:blocked:parent:-,viewer3:-:-:-,viewer4:banned:-:recheck,viewer5:-:-:-,viewer6:-:-:-,viewer7:banned:-:recheck,viewer8:cblock:-:recheck}',
              'set-based: computed and tupleToUserset subtracts, recursive ones rechecked; not a union subtract, a non-monotone base, an intersection');

-- ListObjects = { o | Check(o) } for every user and relation
select tap.is(fga_cmp.list_objects(u, 'document', r), 'ok', format('list_objects(%s, %s) matches check', u, r))
from unnest('{user:a,user:b,user:c,user:d,user:*,team:t1#member,team:t2#member,group:g1#member}'::text[]) u
cross join unnest('{viewer,viewer2,viewer3,viewer4,viewer5,viewer6,viewer7,viewer8}'::text[]) r;

-- ListUsers = { u | Check(u) } on every document but dd and dx
select tap.is(coalesce(string_agg(o || ': ' || res, '; ') filter (where res <> 'ok'), 'ok'), 'ok',
              format('list_users(%s, %s) matches check on d1..d9', r, f))
from unnest('{viewer,viewer2,viewer3,viewer4,viewer5,viewer6,viewer7,viewer8}'::text[]) r
cross join unnest('{user,team#member,group#member}'::text[]) f
cross join lateral (select o, fga_cmp.list_users(o, r, f) as res
                    from unnest('{document:d1,document:d2,document:d3,document:d4,document:d5,document:d6,document:d7,document:d8,document:d9}'::text[]) o) x
group by r, f
order by r, f;

-- a few answers spelled out
select tap.set_eq(array(select permissions.fga_list_objects('user:a', 'document', 'viewer')),
                  '{document:d1,document:d4}',
                  'user:a: d1 (folder via the team cycle), d4 (wildcard); d3 blocked, d6 and d8 blocked for everyone');
select tap.set_eq(array(select permissions.fga_list_objects('user:b', 'document', 'viewer')),
                  '{document:d2,document:d3,document:d5}',
                  'user:b: d2 (folder; blocked only on the folder), d3 (wildcard team), d5 (editor); d4 blocked through g1');
select tap.set_eq(array(select permissions.fga_list_objects('user:c', 'document', 'viewer2')), '{document:d2,document:d9}',
                  'user:c: d2 through the team cycle (its folder blocks only g1), d9 has no parent to block it');
select tap.set_eq(array(select permissions.fga_list_objects('user:b', 'document', 'viewer2')), '{}'::text[],
                  'user:b: d2 is blocked through its folder and group g1');
select tap.set_eq(array(select permissions.fga_list_users('document:d2', 'viewer2', '{user,team#member}')),
                  '{team:t1#member,team:t2#member,user:a,user:c}', 'list_users: the teams and their members stay, user:b is blocked through the folder');

-- d/31's shape: the subtract (banned) is recursive through document#banned
-- and d1, d2 ban each other, with no user. Least fixpoint: banned is empty,
-- so both d1 and d3 are listed, and Check agrees.
select tap.set_eq(array(select permissions.fga_list_objects('user:a', 'document', 'viewer7')), '{document:d1,document:d3}',
                  'd/31 shape: a userset cycle under the subtract bans nobody: d1 and d3');
select tap.set_eq(array(select permissions.fga_list_users('document:d1', 'viewer7', '{user}')), '{user:a}',
                  'd/31 shape: list_users on d1 lists user:a');
select tap.ok(permissions.fga_check('user:a', 'viewer7', 'document:d1'), 'd/31 shape: check agrees');

-- a recursive subtract too deep to decide: dx is blocked for user:deep only
-- through 27 levels of chain, so the subtract raises 2002 (rechecked), while
-- user:a (not in the chain) views dx
select tap.is(fga_cmp.try($$ select count(*)::text from permissions.fga_list_objects('user:deep', 'document', 'viewer8') $$),
              'error openfga:2002', 'a subtract that needs 25 levels raises 2002');
select tap.is(fga_cmp.list_objects('user:deep', 'document', 'viewer8'), 'ok', 'and check agrees');
select tap.set_eq(array(select permissions.fga_list_objects('user:a', 'document', 'viewer8')), '{document:dx}',
                  'user:a is not in the chain: dx is listed');

-- contextual tuples on both sides
select tap.is(fga_cmp.list_objects('user:a', 'document', 'viewer',
              '[{"user": "user:a", "relation": "blocked", "object": "document:d1"},
                {"user": "user:a", "relation": "viewer", "object": "document:d10"}]'), 'ok',
              'contextual block and share: list_objects matches check');
select tap.set_eq(array(select permissions.fga_list_objects('user:a', 'document', 'viewer',
                        '[{"user": "user:a", "relation": "blocked", "object": "document:d1"},
                          {"user": "user:a", "relation": "viewer", "object": "document:d10"}]')),
                  '{document:d4,document:d10}', 'the contextual block removes d1, the contextual share adds d10');
select tap.is(fga_cmp.list_objects('user:c', 'document', 'viewer2',
              '[{"user": "folder:f1", "relation": "parent", "object": "document:d9"}]'), 'ok',
              'contextual parent link: list_objects matches check');
select tap.set_eq(array(select permissions.fga_list_objects('user:c', 'document', 'viewer2',
                        '[{"user": "folder:f1", "relation": "parent", "object": "document:d9"}]')),
                  '{document:d2}', 'a contextual parent link blocks d9 through folder f1');
select tap.is(fga_cmp.list_users('document:d4', 'viewer', 'user',
              '[{"user": "user:c", "relation": "member", "object": "group:g1"}]'), 'ok',
              'contextual group membership: list_users matches check');

-- depth: dd is 28 levels from user:deep
select tap.is(fga_cmp.try($$ select count(*)::text from permissions.fga_list_objects('user:deep', 'document', 'viewer') $$),
              'error openfga:2002', 'a base 28 levels deep raises 2002');
select tap.is(fga_cmp.list_objects('user:deep', 'document', 'viewer'), 'ok', 'and check agrees');
select tap.is(fga_cmp.try($$ select count(*)::text from permissions.fga_list_objects('user:deep', 'document', 'viewer',
              '[{"user": "user:deep", "relation": "blocked", "object": "document:dd"}]') $$),
              '2', 'unless the subtract removes it (d3 and d4 remain, through wildcards)');
select tap.is(fga_cmp.list_objects('user:deep', 'document', 'viewer',
              '[{"user": "user:deep", "relation": "blocked", "object": "document:dd"}]'), 'ok', 'and check agrees');

-- the per-candidate path on the same store gives the same lists
create temp table set_based as
select u, r, array(select x from permissions.fga_list_objects(u, 'document', r) x order by x) as objects
from unnest('{user:a,user:b,user:c,user:d,user:*,team:t1#member,team:t2#member,group:g1#member}'::text[]) u
cross join unnest('{viewer,viewer2,viewer4,viewer7}'::text[]) r;
create temp table set_based_users as
select o, r, array(select x from permissions.fga_list_users(o, r, '{user,team#member,group#member}') x order by x) as users
from unnest('{document:d1,document:d2,document:d3,document:d4,document:d5,document:d6,document:d7,document:d8,document:d9}'::text[]) o
cross join unnest('{viewer,viewer2,viewer4,viewer7}'::text[]) r;
create temp table saved as select * from permissions.fga_relations where diff_relation is not null;
update permissions.fga_relations set diff_relation = null, diff_tupleset = null where diff_relation is not null;
create temp table per_candidate as
select u, r, array(select x from permissions.fga_list_objects(u, 'document', r) x order by x) as objects
from set_based;
create temp table per_candidate_users as
select o, r, array(select x from permissions.fga_list_users(o, r, '{user,team#member,group#member}') x order by x) as users
from set_based_users;
update permissions.fga_relations x set diff_relation = s.diff_relation, diff_tupleset = s.diff_tupleset
from saved s where (x.model_id, x.type, x.relation) = (s.model_id, s.type, s.relation);

select tap.is(s.objects, p.objects, format('set-based = per-candidate: list_objects(%s, %s)', s.u, s.r))
from set_based s join per_candidate p using (u, r)
order by s.r, s.u;
select tap.is(coalesce(string_agg(format('%s: %s vs %s', s.o, s.users, p.users), '; ') filter (where s.users <> p.users), 'same'),
              'same', format('set-based = per-candidate: list_users(d1..d9, %s)', s.r))
from set_based_users s join per_candidate_users p using (o, r)
group by s.r
order by s.r;

select * from tap.finish();
