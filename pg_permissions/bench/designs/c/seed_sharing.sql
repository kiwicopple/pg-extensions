-- Benchmark seed, part 2: per-document sharing with nested teams.
-- Design C's native API (apply_model, grant, accessible, can). Same data shape
-- as bench/designs/a/seed_sharing.sql. bench/run.sh skips the sharing
-- workloads if this file fails to load.
--
-- Data comes from the shape tables (bench/seed_shape.sql), identical for every
-- design. With the default shape:
--
--   team k  -> md5('team' || k)::uuid, k in 1 .. teams
--   user u is a member of team (u % teams) + 1
--   team k > 3 is nested in team k / 4 (a 4-ary tree, so 500 teams is ~5 levels deep)
--   each team can view 5 documents; each user can edit 2 documents directly
--
-- Plus a fixture for write_nest_team and nest_check only (no document grants, so it doesn't
-- change what the share_* workloads see):
--   team md5('nest-src')::uuid with 1,000 members md5('nest-user' || i)::uuid

\set ON_ERROR_STOP 1

select count(*) from permissions.apply_model($json$
{
  "types": {
    "team": { "relations": { "member": ["user", "team#member"] } },
    "document": {
      "relations": { "editor": ["user", "team#member"], "viewer": ["user", "team#member"] },
      "implies":   { "editor": ["viewer"] }
    }
  }
}
$json$);

select count(permissions.grant('team', md5('team' || team)::uuid, 'member',
                               'user', md5('user' || u)::uuid))
from bench.team_members;

select count(permissions.grant('team', md5('team' || parent)::uuid, 'member',
                               'team', md5('team' || child)::uuid, 'member'))
from bench.team_parents;

select count(permissions.grant('document', md5('doc' || doc)::uuid, 'viewer',
                               'team', md5('team' || team)::uuid, 'member'))
from bench.team_grants;

select count(permissions.grant('document', md5('doc' || doc)::uuid, 'editor',
                               'user', md5('user' || u)::uuid))
from bench.user_grants;

-- write_nest_team fixture
select count(permissions.grant('team', md5('nest-src')::uuid, 'member', 'user', md5('nest-user' || i)::uuid))
from generate_series(1, 1000) i;

-- accessible() returns uuid[], so the share branch needs no unnest or cast:
-- the ::uuid[] is a no-op that makes Postgres treat the subquery as an array
-- (see designs/c-compiled-model.md, "RLS fast path").
drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
    or id  = any ((select permissions.accessible('document', 'viewer'))::uuid[])
);

drop policy documents_update on public.documents;
create policy documents_update on public.documents for update to authenticated using (
    permissions.has_permission('documents.edit', org_id)
    or permissions.can('document', id, 'editor')
);
