-- Benchmark seed, part 6 (Design D only): what OpenFGA conditions cost, on a
-- conditioned copy of the sharing graph. Added in phase 5 of session 5.
--
-- Writes a second model (it becomes the latest; every relation of the first
-- is unchanged, so the earlier workloads' walks are the same) that adds:
--
--   type cteam
--     relations
--       define member: [user with active, cteam#member with active]
--   type document
--     relations
--       define cviewer: [user, cteam#member with active] or editor or viewer from parent
--
--   condition active(expires: timestamp) {
--     expires > timestamp("2000-01-01T00:00:00Z")
--   }
--
-- and copies the team graph into cteam tuples, every one with the condition
-- and the same stored context {"expires": "2100-01-01T00:00:00Z"} (true): the
-- memberships (user -> cteam, cteam -> cteam: walked inside the recursion of
-- the forward walk) and the team grants (cteam#member -> document#cviewer:
-- the walk's leaves), plus the nest_check fixture (cteam md5('nest-src')
-- with its 1,000 members, nested in cteam :teams, as seed_nest.sql does for
-- team). So `cviewer` is `viewer` with a condition on every membership and
-- team grant, over the same data: the plain_* and cond_* workloads compare
-- them, and the checksum of this phase must equal the parents phase's.
--
-- The condition reads only the tuple's stored context because the RLS
-- helpers (fga_*_current) pass no request context (research/designs/d-conditions.md):
-- a condition that needs a request parameter is denied there. One shared
-- context is the case where evaluating once per distinct (condition,
-- context) pays most; bench/designs/d/conditions_cost.sql measures distinct
-- contexts too.
--
-- The select policy is replaced by the same policy on cviewer.

\set ON_ERROR_STOP 1

select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [
       {"type": "user"}, {"type": "team", "relation": "member"}]}}}},
    {"type": "cteam", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [
       {"type": "user", "condition": "active"}, {"type": "cteam", "relation": "member", "condition": "active"}]}}}},
    {"type": "folder", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "document",
     "relations": {
       "parent": {"this": {}},
       "editor": {"this": {}},
       "viewer": {"union": {"child": [
         {"this": {}},
         {"computedUserset": {"relation": "editor"}},
         {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}},
       "cviewer": {"union": {"child": [
         {"this": {}},
         {"computedUserset": {"relation": "editor"}},
         {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}}},
     "metadata": {"relations": {
       "parent": {"directly_related_user_types": [{"type": "folder"}]},
       "editor": {"directly_related_user_types": [{"type": "user"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]},
       "cviewer": {"directly_related_user_types": [{"type": "user"}, {"type": "cteam", "relation": "member", "condition": "active"}]}}}}
  ],
  "conditions": {
    "active": {"name": "active",
      "expression": "expires > timestamp(\"2000-01-01T00:00:00Z\")",
      "parameters": {"expires": {"type_name": "TYPE_NAME_TIMESTAMP"}}}}
}$m$::jsonb) is not null as model_written;

select permissions.fga_write(jsonb_build_object('tuple_keys', keys, 'on_duplicate', 'ignore'))
from (
    select jsonb_agg(jsonb_build_object('user', u, 'relation', r, 'object', o,
                                        'condition', '{"name": "active", "context": {"expires": "2100-01-01T00:00:00Z"}}'::jsonb)) as keys
    from (
        select u, r, o, (row_number() over () - 1) / 100 as chunk   -- the Write cap (seed_sharing.sql)
        from (
            select distinct 'user:' || md5('user' || u)::uuid as u, 'member' as r, 'cteam:' || md5('team' || team)::uuid as o
            from bench.team_members
          union all
            select distinct 'cteam:' || md5('team' || child)::uuid || '#member', 'member', 'cteam:' || md5('team' || parent)::uuid
            from bench.team_parents
          union all
            select distinct 'cteam:' || md5('team' || team)::uuid || '#member', 'cviewer', 'document:' || md5('doc' || doc)::uuid
            from bench.team_grants
          union all
            -- cond_nest_check fixture (seed_sharing.sql and seed_nest.sql for team)
            select 'user:' || md5('nest-user' || i)::uuid, 'member', 'cteam:' || md5('nest-src')::uuid
            from generate_series(1, 1000) i
          union all
            select 'cteam:' || md5('nest-src')::uuid || '#member', 'member', 'cteam:' || md5('team' || :teams)::uuid
        ) t
    ) c
    group by chunk
) w;

select (:teams::bigint * 9973 + 7919) % :docs + 1 as nest_doc \gset
select permissions.fga_check('user:' || md5('nest-user' || 1)::uuid, 'cviewer',
                             'document:' || md5('doc' || :nest_doc)::uuid) as nest_ok \gset
\if :nest_ok
\else
do $$ begin raise exception 'cond_nest_check fixture: the check is false for nest-user 1'; end $$;
\endif

drop policy documents_select_fga on public.documents;
create policy documents_select_fga on public.documents for select to authenticated using (
    id = any (array(select permissions.fga_list_object_ids_current('document', 'cviewer')::uuid))
);
