-- Goal: ListObjects on relations that are not monotone, evaluated set-based
-- over the rewrite tree (fga_relations.set_eval, phase 5 of session 5;
-- designs/d-per-model.md section 5): every leaf a walk, combined by union,
-- intersection and difference with _fga_rec's rules. It must give what Check
-- gives for every object, and what the per-candidate path (the candidates of
-- the positive walk, each checked by _fga_rec) gives, for: a union under the
-- subtract, an intersection with a computed relation and with `this`, a base
-- that depends on a relation that is not monotone, nested differences, a
-- subtract of a subtract, a tupleToUserset over a parent relation that is not
-- monotone (in the base and in the subtract), a conditioned subtract (the
-- API and the RLS helpers), userset users (the relation's own and a parent's),
-- contextual tuples and the depth limit. A relation that recurses through
-- itself is not set-based.
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
--     define fv: viewer but not blocked
-- type document
--   relations
--     define parent: [folder]
--     define editor: [user, team#member]
--     define blocked: [user, user:*, group#member]
--     define muted: [user]
--     define cmuted: [user with cx]
--     define viewer: [user, user:*, team#member, chain#member] or editor or viewer from parent
--     define v_unmuted: viewer but not (blocked or muted)
--     define v_and: viewer and editor
--     define v_and_this: [user, team#member] and viewer
--     define v_base_nm: v_unmuted or editor
--     define v_nested: (viewer but not blocked) but not muted
--     define v_dneg: viewer but not (blocked but not muted)
--     define v_ttu_nm: fv from parent
--     define v_ttu_sub: viewer but not fv from parent
--     define v_rec: [user, document#v_rec] but not blocked
--     define v_cond: viewer but not (cmuted or muted)
--     define v_deep: [chain#member] and viewer
-- condition cx(x: int) { x < 100 }
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
     "relations": {
       "viewer": {"this": {}},
       "blocked": {"this": {}},
       "fv": {"difference": {"base": {"computedUserset": {"relation": "viewer"}},
                             "subtract": {"computedUserset": {"relation": "blocked"}}}}},
     "metadata": {"relations": {
       "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]},
       "blocked": {"directly_related_user_types": [{"type": "user"}, {"type": "group", "relation": "member"}]}}}},
    {"type": "document",
     "relations": {
       "parent": {"this": {}},
       "editor": {"this": {}},
       "blocked": {"this": {}},
       "muted": {"this": {}},
       "cmuted": {"this": {}},
       "viewer": {"union": {"child": [
         {"this": {}},
         {"computedUserset": {"relation": "editor"}},
         {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}},
       "v_unmuted": {"difference": {
         "base": {"computedUserset": {"relation": "viewer"}},
         "subtract": {"union": {"child": [
           {"computedUserset": {"relation": "blocked"}},
           {"computedUserset": {"relation": "muted"}}]}}}},
       "v_and": {"intersection": {"child": [
         {"computedUserset": {"relation": "viewer"}},
         {"computedUserset": {"relation": "editor"}}]}},
       "v_and_this": {"intersection": {"child": [
         {"this": {}},
         {"computedUserset": {"relation": "viewer"}}]}},
       "v_base_nm": {"union": {"child": [
         {"computedUserset": {"relation": "v_unmuted"}},
         {"computedUserset": {"relation": "editor"}}]}},
       "v_nested": {"difference": {
         "base": {"difference": {"base": {"computedUserset": {"relation": "viewer"}},
                                 "subtract": {"computedUserset": {"relation": "blocked"}}}},
         "subtract": {"computedUserset": {"relation": "muted"}}}},
       "v_dneg": {"difference": {
         "base": {"computedUserset": {"relation": "viewer"}},
         "subtract": {"difference": {"base": {"computedUserset": {"relation": "blocked"}},
                                     "subtract": {"computedUserset": {"relation": "muted"}}}}}},
       "v_ttu_nm": {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "fv"}}},
       "v_ttu_sub": {"difference": {
         "base": {"computedUserset": {"relation": "viewer"}},
         "subtract": {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "fv"}}}}},
       "v_rec": {"difference": {
         "base": {"this": {}},
         "subtract": {"computedUserset": {"relation": "blocked"}}}},
       "v_cond": {"difference": {
         "base": {"computedUserset": {"relation": "viewer"}},
         "subtract": {"union": {"child": [
           {"computedUserset": {"relation": "cmuted"}},
           {"computedUserset": {"relation": "muted"}}]}}}},
       "v_deep": {"intersection": {"child": [
         {"this": {}},
         {"computedUserset": {"relation": "viewer"}}]}}},
     "metadata": {"relations": {
       "parent": {"directly_related_user_types": [{"type": "folder"}]},
       "editor": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]},
       "blocked": {"directly_related_user_types": [
         {"type": "user"}, {"type": "user", "wildcard": {}}, {"type": "group", "relation": "member"}]},
       "muted": {"directly_related_user_types": [{"type": "user"}]},
       "cmuted": {"directly_related_user_types": [{"type": "user", "condition": "cx"}]},
       "viewer": {"directly_related_user_types": [
         {"type": "user"}, {"type": "user", "wildcard": {}}, {"type": "team", "relation": "member"},
         {"type": "chain", "relation": "member"}]},
       "v_and_this": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]},
       "v_rec": {"directly_related_user_types": [{"type": "user"}, {"type": "document", "relation": "v_rec"}]},
       "v_deep": {"directly_related_user_types": [{"type": "chain", "relation": "member"}]}}}}
  ],
  "conditions": {"cx": {"name": "cx", "expression": "x < 100", "parameters": {"x": {"type_name": "TYPE_NAME_INT"}}}}
}$m$::jsonb) is not null as model_written;

-- teams t1 and t2 contain each other; everyone is in t3 and g2.
-- document:dd is 27 levels from user:deep through chain:k26 .. k0.
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
  {"user": "user:d", "relation": "viewer", "object": "folder:f2"},
  {"user": "user:c", "relation": "blocked", "object": "folder:f1"},
  {"user": "group:g1#member", "relation": "blocked", "object": "folder:f2"},
  {"user": "folder:f1", "relation": "parent", "object": "document:d1"},
  {"user": "folder:f2", "relation": "parent", "object": "document:d2"},
  {"user": "folder:f1", "relation": "parent", "object": "document:d9"},
  {"user": "team:t3#member", "relation": "viewer", "object": "document:d3"},
  {"user": "user:*", "relation": "viewer", "object": "document:d4"},
  {"user": "team:t2#member", "relation": "viewer", "object": "document:d6"},
  {"user": "user:d", "relation": "viewer", "object": "document:d7"},
  {"user": "team:t1#member", "relation": "viewer", "object": "document:d8"},
  {"user": "chain:k0#member", "relation": "viewer", "object": "document:dd"},
  {"user": "user:b", "relation": "editor", "object": "document:d5"},
  {"user": "user:a", "relation": "editor", "object": "document:d1"},
  {"user": "team:t2#member", "relation": "editor", "object": "document:d6"},
  {"user": "user:c", "relation": "editor", "object": "document:d3"},
  {"user": "user:a", "relation": "blocked", "object": "document:d3"},
  {"user": "group:g1#member", "relation": "blocked", "object": "document:d4"},
  {"user": "user:*", "relation": "blocked", "object": "document:d6"},
  {"user": "group:g2#member", "relation": "blocked", "object": "document:d8"},
  {"user": "user:a", "relation": "muted", "object": "document:d1"},
  {"user": "user:b", "relation": "muted", "object": "document:d2"},
  {"user": "user:c", "relation": "muted", "object": "document:d6"},
  {"user": "user:d", "relation": "muted", "object": "document:d4"},
  {"user": "user:a", "relation": "v_and_this", "object": "document:d1"},
  {"user": "team:t2#member", "relation": "v_and_this", "object": "document:d8"},
  {"user": "user:b", "relation": "v_and_this", "object": "document:d4"},
  {"user": "user:a", "relation": "v_rec", "object": "document:d1"},
  {"user": "document:d1#v_rec", "relation": "v_rec", "object": "document:d2"},
  {"user": "chain:k0#member", "relation": "v_deep", "object": "document:dd"},
  {"user": "chain:k3#member", "relation": "v_deep", "object": "document:d4"},
  {"user": "user:b", "relation": "cmuted", "object": "document:d5", "condition": {"name": "cx", "context": {"x": 1}}},
  {"user": "user:c", "relation": "cmuted", "object": "document:d3", "condition": {"name": "cx", "context": {"x": 500}}},
  {"user": "user:deep", "relation": "member", "object": "chain:k26"},
  {"user": "user:e", "relation": "member", "object": "chain:k3"}]');
select permissions.fga_write(jsonb_agg(jsonb_build_object(
    'user', 'chain:k' || (j + 1) || '#member', 'relation', 'member', 'object', 'chain:k' || j)))
from generate_series(0, 25) j;
-- a cmuted tuple whose condition can't be evaluated without a request
-- context (x is missing): an error in a subtract
select permissions.fga_write('[{"user": "user:a", "relation": "cmuted", "object": "document:d9", "condition": {"name": "cx"}}]');
-- the depth limit at its boundary: users y24 and y25 are 24 and 25 levels
-- from document:dd through chain:k23 and k24; users z21 .. z24 reach folder
-- fz through a team chain c24 .. c0 (zN in cN), and document dz2 has fz as
-- parent and is viewable by them directly
select permissions.fga_write(jsonb_agg(jsonb_build_object(
    'user', 'team:c' || (j + 1) || '#member', 'relation', 'member', 'object', 'team:c' || j)))
from generate_series(0, 23) j;
select permissions.fga_write('[
  {"user": "user:y24", "relation": "member", "object": "chain:k23"},
  {"user": "user:y25", "relation": "member", "object": "chain:k24"},
  {"user": "team:c0#member", "relation": "viewer", "object": "folder:fz"},
  {"user": "folder:fz", "relation": "parent", "object": "document:dz2"}]');
select permissions.fga_write(jsonb_agg(x))
from generate_series(21, 24) n,
     lateral (values (jsonb_build_object('user', 'user:z' || n, 'relation', 'member', 'object', 'team:c' || n)),
                     (jsonb_build_object('user', 'user:z' || n, 'relation', 'viewer', 'object', 'document:dz2'))) v(x);

create temp table rels (r text);
insert into rels values ('v_unmuted'), ('v_and'), ('v_and_this'), ('v_base_nm'), ('v_nested'), ('v_dneg'),
                        ('v_ttu_nm'), ('v_ttu_sub'), ('v_rec'), ('v_cond'), ('v_deep');
create temp table users (u text);
insert into users values ('user:a'), ('user:b'), ('user:c'), ('user:d'), ('user:e'), ('user:*'), ('user:deep'),
                         ('team:t1#member'), ('team:t2#member'), ('group:g1#member'),
                         ('folder:f1#fv'), ('document:d1#v_unmuted');

select tap.plan(195);

-- which relations are set-based
select tap.is(array(select format('%s:%s:%s', r.type, r.relation, case when r.set_eval then 'set' else '-' end)
                    from permissions.fga_relations r
                    where r.model_id = (select id from permissions.fga_models order by seq desc limit 1)
                      and not r.monotone
                    order by r.type, r.relation),
              '{document:v_and:set,document:v_and_this:set,document:v_base_nm:set,document:v_cond:set,document:v_deep:set,document:v_dneg:set,document:v_nested:set,document:v_rec:-,document:v_ttu_nm:set,document:v_ttu_sub:set,document:v_unmuted:set,folder:fv:set}',
              'set_eval: every relation that is not monotone, but the one that recurses through itself');

-- ListObjects = { o | Check(o) } for every user and relation (the API, mode r;
-- an error on either side counts as the answer)
select tap.is(fga_cmp.list_objects(u, 'document', r), 'ok', format('list_objects(%s, %s) matches check', u, r))
from users cross join rels order by r, u;

-- the same lists from the per-candidate path, on the same store
create temp table set_based as
select u, r, fga_cmp.try(format('select coalesce(array_agg(x order by x), ''{}'')::text from permissions.fga_list_objects(%L, ''document'', %L) x', u, r)) as got
from users cross join rels;
create temp table saved as select model_id, type, relation from permissions.fga_relations where set_eval;
update permissions.fga_relations set set_eval = false where set_eval;
create temp table per_candidate as
select u, r, fga_cmp.try(format('select coalesce(array_agg(x order by x), ''{}'')::text from permissions.fga_list_objects(%L, ''document'', %L) x', u, r)) as got
from users cross join rels;
update permissions.fga_relations x set set_eval = true from saved s where (x.model_id, x.type, x.relation) = (s.model_id, s.type, s.relation);

select tap.is(coalesce(string_agg(format('%s: %s vs %s', s.u, s.got, p.got), '; ') filter (where s.got <> p.got), 'same'),
              'same', format('set-based = per-candidate: list_objects(*, document, %s)', s.r))
from set_based s join per_candidate p using (u, r)
group by s.r order by s.r;

-- the RLS helpers (mode d: an evaluation error denies), set-based and per-candidate
create function pg_temp.current_list(p_user text, p_rel text)
returns text language plpgsql as $$
declare r text;
begin
    perform set_config('permissions.subject_id', split_part(p_user, ':', 2), true);
    select coalesce(array_agg(x order by x), '{}')::text into r
    from permissions.fga_list_object_ids_current('document', p_rel) x;
    return r;
exception when others then
    return 'error ' || sqlerrm;
end;
$$;
create temp table cur_set as
select u, r, pg_temp.current_list(u, r) as got
from users cross join rels where u ~ '^user:[a-e]$';
update permissions.fga_relations set set_eval = false where set_eval;
create temp table cur_cand as
select u, r, pg_temp.current_list(u, r) as got
from users cross join rels where u ~ '^user:[a-e]$';
update permissions.fga_relations x set set_eval = true from saved s where (x.model_id, x.type, x.relation) = (s.model_id, s.type, s.relation);
select tap.is(coalesce(string_agg(format('%s: %s vs %s', s.u, s.got, p.got), '; ') filter (where s.got <> p.got), 'same'),
              'same', format('RLS helper, set-based = per-candidate: %s', s.r))
from cur_set s join cur_cand p using (u, r)
group by s.r order by s.r;

-- a few answers spelled out
select tap.set_eq(array(select permissions.fga_list_objects('user:a', 'document', 'v_unmuted')),
                  '{document:d4,document:d9}',
                  'v_unmuted, user:a: d1 muted, d3 blocked, d6 blocked for everyone, d8 blocked through g2');
select tap.set_eq(array(select permissions.fga_list_objects('user:c', 'document', 'v_and')), '{document:d3,document:d6}',
                  'v_and, user:c: editor of d3, and of d6 through team t2; both viewable');
select tap.set_eq(array(select permissions.fga_list_objects('user:a', 'document', 'v_and_this')), '{document:d1,document:d8}',
                  'v_and_this, user:a: direct on d1, through t2 (t1 and t2 contain each other) on d8');
select tap.set_eq(array(select permissions.fga_list_objects('user:a', 'document', 'v_dneg')), '{document:d1,document:d4,document:d9}',
                  'v_dneg, user:a: d1 is muted, so its block (none) does not count; d3 blocked, d6 and d8 blocked');
select tap.set_eq(array(select permissions.fga_list_objects('user:d', 'document', 'v_dneg')), '{document:d2,document:d3,document:d4,document:d7}',
                  'v_dneg, user:d: d2 through folder f2, d3 through t3, d4 (wildcard; not blocked for d), d7 direct');
select tap.set_eq(array(select permissions.fga_list_objects('folder:f1#fv', 'document', 'v_ttu_nm')), '{document:d1,document:d9}',
                  'v_ttu_nm: a parent''s own userset (folder:f1#fv) reaches the documents under f1');
select tap.set_eq(array(select permissions.fga_list_objects('user:a', 'document', 'v_ttu_nm')), '{document:d1,document:d9}',
                  'v_ttu_nm, user:a: f1 through team t1, not blocked');
select tap.set_eq(array(select permissions.fga_list_objects('user:c', 'document', 'v_ttu_nm')), '{}'::text[],
                  'v_ttu_nm, user:c: blocked on f1');
select tap.set_eq(array(select permissions.fga_list_objects('user:b', 'document', 'v_cond')), '{document:d3,document:d4}',
                  'v_cond, user:b: d5 cmuted (x 1 < 100), d2 muted');
select tap.set_eq(array(select permissions.fga_list_objects('user:c', 'document', 'v_cond')),
                  '{document:d1,document:d3,document:d4,document:d8,document:d9}',
                  'v_cond, user:c: d3 stays (cmuted with x 500: false), d6 muted; d1, d8, d9 through t1 (t2 contains it)');

-- depth: dd is 27 levels from user:deep, d4 four levels from user:e
select tap.is(fga_cmp.try($$ select count(*)::text from permissions.fga_list_objects('user:deep', 'document', 'v_deep') $$),
              'error openfga:2002', 'an intersection 27 levels deep raises 2002');
select tap.set_eq(array(select permissions.fga_list_objects('user:e', 'document', 'v_deep')), '{document:d4,document:dd}',
                  'v_deep, user:e: d4 through chain k3, dd through k3 .. k0 (4 levels)');

-- at the boundary of the depth limit: Check (the user probe of the
-- bidirectional search), the leveled walk, a tupleToUserset over a relation
-- that is not monotone (one level more), and a subtract 25 levels deep (an
-- error, not a removal)
select tap.is(permissions.fga_check('user:y24', 'viewer', 'document:dd'), true, 'check: dd is 24 levels from user:y24');
select tap.is(fga_cmp.try($$ select permissions.fga_check('user:y25', 'viewer', 'document:dd')::text $$),
              'error openfga:2002', 'check: dd is 25 levels from user:y25: 2002');
select tap.is(fga_cmp.list_objects(u, 'document', r), 'ok', format('depth boundary: list_objects(%s, %s) matches check', u, r))
from unnest('{user:y24,user:y25,user:z21,user:z22,user:z23,user:z24}'::text[]) u
cross join unnest('{v_unmuted,v_deep,v_ttu_nm,v_ttu_sub}'::text[]) r
order by u, r;

-- contextual tuples on both sides
select tap.is(fga_cmp.list_objects('user:a', 'document', 'v_unmuted',
              '[{"user": "user:a", "relation": "muted", "object": "document:d9"},
                {"user": "user:a", "relation": "viewer", "object": "document:d10"}]'), 'ok',
              'contextual mute and share: list_objects matches check');
select tap.set_eq(array(select permissions.fga_list_objects('user:a', 'document', 'v_unmuted',
                        '[{"user": "user:a", "relation": "muted", "object": "document:d9"},
                          {"user": "user:a", "relation": "viewer", "object": "document:d10"}]')),
                  '{document:d4,document:d10}', 'the contextual mute removes d9, the contextual share adds d10');

select * from tap.finish();
