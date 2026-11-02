-- Benchmark seed, part 2: per-document sharing with nested teams.
-- PROVISIONAL: uses Design A's zanzibar-level API (define_type, define_relation,
-- grant, list_objects, check). bench/run.sh skips the sharing workloads if this
-- file fails to load.
--
-- Data comes from the shape tables (bench/seed_shape.sql), identical for every
-- design. With the default shape:
--
--   team k  -> md5('team' || k)::uuid, k in 1 .. teams
--   user u is a member of team (u % teams) + 1
--   team k > 3 is nested in team k / 4 (a 4-ary tree, so 500 teams is ~5 levels deep)
--   each team can view 5 documents; each user can edit 2 documents directly
--
-- Plus a fixture for write_nest_team and nest_check only (no document grants,
-- so it doesn't change what the share_* workloads see):
--   team md5('nest-src')::uuid with 1,000 members md5('nest-user' || i)::uuid

\set ON_ERROR_STOP 1

select permissions.define_type('team');
select permissions.define_type('document');
select permissions.define_relation('team', 'member');
select permissions.define_relation('document', 'editor');
select permissions.define_relation('document', 'viewer', '{editor}');

select permissions.grant('team', md5('team' || team)::uuid::text, 'member',
                         'user', md5('user' || u)::uuid::text)
from bench.team_members;

select permissions.grant('team', md5('team' || parent)::uuid::text, 'member',
                         'team', md5('team' || child)::uuid::text, 'member')
from bench.team_parents;

select permissions.grant('document', md5('doc' || doc)::uuid::text, 'viewer',
                         'team', md5('team' || team)::uuid::text, 'member')
from bench.team_grants;

select permissions.grant('document', md5('doc' || doc)::uuid::text, 'editor',
                         'user', md5('user' || u)::uuid::text)
from bench.user_grants;

-- write_nest_team / nest_check fixture
select permissions.grant('team', md5('nest-src')::uuid::text, 'member', 'user', md5('nest-user' || i)::uuid::text)
from generate_series(1, 1000) i;

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
