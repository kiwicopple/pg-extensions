-- Benchmark seed, part 2: per-document sharing with nested teams (Design B's native API).
-- Same data shape as bench/designs/a/seed_sharing.sql; bench/run.sh skips the
-- sharing workloads if this file fails to load.
--
-- psql variables: docs, users, teams
--
--   team k  -> md5('team' || k)::uuid, k in 1 .. teams
--   user u is a member of team (u % teams) + 1          (parents edge user -> team)
--   team k > 3 is nested in team k / 4                  (parents edge team -> team; ~5 levels at 500 teams)
--   each team can view 5 documents; each user can edit 2 documents directly (role grants)
--
-- Membership is written before nesting, as in A, so the closure triggers do
-- the expensive direction (nesting a team that already has members).

\set ON_ERROR_STOP 1

select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');
select permissions.permit('doc viewers view', '{select}', 'document', roles => '{viewer}');
select permissions.permit('doc editors edit', '{update}', 'document', roles => '{editor}');

select permissions.add_parent('user', md5('user' || u)::uuid::text,
                              'team', md5('team' || ((u % :teams) + 1))::uuid::text)
from generate_series(1, :users) u;

select permissions.add_parent('team', md5('team' || k)::uuid::text,
                              'team', md5('team' || (k / 4))::uuid::text)
from generate_series(4, :teams) k;

select permissions.grant_role('team', md5('team' || k)::uuid::text, 'viewer',
                              'document', md5('doc' || ((k * 9973 + i * 7919) % :docs + 1))::uuid::text)
from generate_series(1, :teams) k, generate_series(1, 5) i;

select permissions.grant_role('user', md5('user' || u)::uuid::text, 'editor',
                              'document', md5('doc' || ((u * 104729 + i * 15485863) % :docs + 1))::uuid::text)
from generate_series(1, :users) u, generate_series(1, 2) i;

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
