-- Benchmark seed, part 2: per-document sharing with nested teams (Design B's native API).
-- Same data shape as bench/designs/a/seed_sharing.sql; bench/run.sh skips the
-- sharing workloads if this file fails to load.
--
-- Data comes from the shape tables (bench/seed_shape.sql), identical for every
-- design. With the default shape:
--
--   team k  -> md5('team' || k)::uuid, k in 1 .. teams
--   user u is a member of team (u % teams) + 1          (parents edge user -> team)
--   team k > 3 is nested in team k / 4                  (parents edge team -> team; ~5 levels at 500 teams)
--   each team can view 5 documents; each user can edit 2 documents directly (role grants)
--
-- Membership is written before nesting, as in A, so the closure triggers do
-- the expensive direction (nesting a team that already has members).
--
-- Plus a fixture for write_nest_team and nest_check only (no document grants,
-- so it doesn't change what the share_* workloads see):
--   team md5('nest-src')::uuid with 1,000 members md5('nest-user' || i)::uuid

\set ON_ERROR_STOP 1

select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');
select permissions.permit('doc viewers view', '{select}', 'document', roles => '{viewer}');
select permissions.permit('doc editors edit', '{update}', 'document', roles => '{editor}');

select permissions.add_parent('user', md5('user' || u)::uuid::text,
                              'team', md5('team' || team)::uuid::text)
from bench.team_members;

select permissions.add_parent('team', md5('team' || child)::uuid::text,
                              'team', md5('team' || parent)::uuid::text)
from bench.team_parents;

select permissions.grant_role('team', md5('team' || team)::uuid::text, 'viewer',
                              'document', md5('doc' || doc)::uuid::text)
from bench.team_grants;

select permissions.grant_role('user', md5('user' || u)::uuid::text, 'editor',
                              'document', md5('doc' || doc)::uuid::text)
from bench.user_grants;

-- write_nest_team / nest_check fixture
select permissions.add_parent('user', md5('nest-user' || i)::uuid::text, 'team', md5('nest-src')::uuid::text)
from generate_series(1, 1000) i;

-- Same two-branch policies as A (org roles or shares), written by hand.
-- permissions.apply_rls would add a forbid side; see designs/b-policy-first.md.
drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
    or id  = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
);

drop policy documents_update on public.documents;
create policy documents_update on public.documents for update to authenticated using (
    permissions.has_permission('documents.edit', org_id::text)
    or permissions.can('update', 'document', id::text)
);
