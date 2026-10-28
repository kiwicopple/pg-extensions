-- Benchmark seed, part 2: per-document sharing with nested teams.
-- PROVISIONAL: uses Design A's zanzibar-level API (define_type, define_relation,
-- grant, list_objects, check). bench/run.sh skips the sharing workloads if this
-- file fails to load.
--
-- psql variables: docs, users, teams
--
--   team k  -> md5('team' || k)::uuid, k in 1 .. teams
--   user u is a member of team (u % teams) + 1
--   team k > 1 is nested in team k / 4 (a 4-ary tree, so 500 teams is ~5 levels deep)
--   each team can view 5 documents; each user can edit 2 documents directly

\set ON_ERROR_STOP 1

select permissions.define_type('team');
select permissions.define_type('document');
select permissions.define_relation('team', 'member');
select permissions.define_relation('document', 'editor');
select permissions.define_relation('document', 'viewer', '{editor}');

select permissions.grant('team', md5('team' || ((u % :teams) + 1))::uuid::text, 'member',
                         'user', md5('user' || u)::uuid::text)
from generate_series(1, :users) u;

select permissions.grant('team', md5('team' || (k / 4))::uuid::text, 'member',
                         'team', md5('team' || k)::uuid::text, 'member')
from generate_series(4, :teams) k;

select permissions.grant('document', md5('doc' || ((k * 9973 + i * 7919) % :docs + 1))::uuid::text, 'viewer',
                         'team', md5('team' || k)::uuid::text, 'member')
from generate_series(1, :teams) k, generate_series(1, 5) i;

select permissions.grant('document', md5('doc' || ((u * 104729 + i * 15485863) % :docs + 1))::uuid::text, 'editor',
                         'user', md5('user' || u)::uuid::text)
from generate_series(1, :users) u, generate_series(1, 2) i;

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
    or id  = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);

drop policy documents_update on public.documents;
create policy documents_update on public.documents for update to authenticated using (
    permissions.has_permission('documents.edit', org_id::text)
    or permissions.check('document', id::text, 'editor')
);
