-- Benchmark seed, part 2 (Design D): per-document sharing with nested teams,
-- as OpenFGA tuples (fga_*). The RBAC side (org roles) stays in rbac_* from
-- bench/seed_rbac.sql: D composes the two models in RLS with one permissive
-- policy each (research/designs/d-per-model.md §6), so this seed adds an FGA policy
-- next to seed_rbac.sql's documents_select instead of replacing it. Permissive
-- policies OR, so the visible set is A's `org roles or shares` policy.
--
-- Data comes from the shape tables (bench/seed_shape.sql), identical for every
-- design; see designs/a/seed_sharing.sql for the default shape.
--
-- The authorization model is written once, here, for every later phase:
--
--   type user
--   type team
--     relations
--       define member: [user, team#member]
--   type folder
--     relations
--       define viewer: [user]
--   type document
--     relations
--       define parent: [folder]
--       define editor: [user]
--       define viewer: [user, team#member] or editor or viewer from parent
--
-- Team k > 3 nested in team k / 4 is `team:<k/4>#member@team:<k>#member`.
-- Folders and document parents get tuples in seed_parents.sql and
-- seed_parent_docs.sql; until then `viewer from parent` finds nothing.
-- Org roles are not in the FGA model at all (they are rbac_* rows), so folders
-- have no parent: an org role reaches a document through the RBAC policy.
--
-- Loading: fga_write, the native Write API (each tuple validated against the
-- model, then one set-based insert), with every tuple key of a seed in
-- chunks of 100 per call, the cap on a Write (2053 above it, as OpenFGA;
-- design doc §4). Until phase 2 of session 5 there was no cap and the seeds
-- wrote chunks of 50,000, so seed times in baselines before then are not
-- comparable. `distinct` because a Write may not name a tuple twice.
--
-- Plus a fixture for write_nest_team and nest_check only (no document grants,
-- so it doesn't change what the share_* workloads see):
--   team md5('nest-src')::uuid with 1,000 members md5('nest-user' || i)::uuid

\set ON_ERROR_STOP 1

select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [
       {"type": "user"}, {"type": "team", "relation": "member"}]}}}},
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
       "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]}}}}
  ]}$m$::jsonb) is not null as model_written;

select permissions.fga_write(jsonb_build_object('tuple_keys', keys, 'on_duplicate', 'ignore'))
from (
    select jsonb_agg(jsonb_build_object('user', u, 'relation', r, 'object', o)) as keys
    from (
        select u, r, o, (row_number() over () - 1) / 100 as chunk
        from (
            select distinct 'user:' || md5('user' || u)::uuid as u, 'member' as r, 'team:' || md5('team' || team)::uuid as o
            from bench.team_members
          union all
            select distinct 'team:' || md5('team' || child)::uuid || '#member', 'member', 'team:' || md5('team' || parent)::uuid
            from bench.team_parents
          union all
            select distinct 'team:' || md5('team' || team)::uuid || '#member', 'viewer', 'document:' || md5('doc' || doc)::uuid
            from bench.team_grants
          union all
            select distinct 'user:' || md5('user' || u)::uuid, 'editor', 'document:' || md5('doc' || doc)::uuid
            from bench.user_grants
          union all
            -- write_nest_team / nest_check fixture
            select 'user:' || md5('nest-user' || i)::uuid, 'member', 'team:' || md5('nest-src')::uuid
            from generate_series(1, 1000) i
        ) t
    ) c
    group by chunk
) w;

create policy documents_select_fga on public.documents for select to authenticated using (
    id = any (array(select permissions.fga_list_object_ids_current('document', 'viewer')::uuid))
);

create policy documents_update_fga on public.documents for update to authenticated using (
    permissions.fga_check_current('editor', 'document:' || id)
);
