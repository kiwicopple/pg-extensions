-- Benchmark seed, part 3 (Design A): parent inheritance (PLAN.md §10 G10).
-- PROVISIONAL: uses Design A's zanzibar-level API. Load after seed_rbac.sql and
-- seed_sharing.sql. NOT loaded by bench/run.sh yet: it replaces the two-branch
-- select policy, so the share_* workloads would measure something else after it.
--
-- psql variables: docs, orgs
--
-- Every document gets one parent tuple pointing at its org's `tenant` object,
-- the object the rbac preset already stores scoped roles on. `document#viewer`
-- then inherits the preset's `documents.read` permission from the parent, so
-- the select policy needs a single fast-path branch:
--   org roles (rbac preset) + team shares (seed_sharing.sql), one list_objects().
--
-- Storage: one tuple per document (10k at small, 1M at large), mirroring
-- documents.org_id. A real app would attach permissions.sync_parent() to the
-- table instead of seeding once.

\set ON_ERROR_STOP 1

select permissions.define_relation('document', 'parent');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{documents.read}');

select permissions.set_parent('document', md5('doc' || n)::uuid::text, 'tenant', md5('org' || (n % :orgs))::uuid::text)
from generate_series(1, :docs) n;

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);
