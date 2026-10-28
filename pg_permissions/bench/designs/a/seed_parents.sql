-- Benchmark seed, part 3 (Design A): parent inheritance (PLAN.md §10 G10).
-- Uses Design A's zanzibar-level API. bench/run.sh loads it after the share_*
-- workloads, because it replaces the documents select policy.
--
-- Data comes from the shape tables (bench/seed_shape.sql), identical for every
-- design:
--   folder f -> md5('folder' || f)::uuid, about 10 per org, parent = the org's
--               `tenant` object (where the rbac preset stores scoped roles)
--   document -> parent = its folder (documents.folder_id)
--   every 5th user is a viewer of one folder
--
-- Inheritance: tenant#documents.read (every scoped viewer/editor/admin role)
-- -> folder#viewer -> document#viewer, so the select policy is A's single
-- fast-path branch: org roles, folder viewers and team/direct shares all come
-- out of one list_objects() call, which walks to every visible document.
--
-- Storage: one parent tuple per document (10k at small, 1M at large),
-- mirroring documents.folder_id. A real app would attach
-- permissions.sync_parent() to the table instead of seeding once.

\set ON_ERROR_STOP 1

select permissions.define_type('folder');
select permissions.define_relation('folder', 'parent');
select permissions.define_relation('folder', 'viewer', from_parent => '{documents.read}');
select permissions.define_relation('document', 'parent');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}');

select permissions.set_parent('folder', md5('folder' || f)::uuid::text, 'tenant', md5('org' || org)::uuid::text)
from bench.folders;

select permissions.grant('folder', md5('folder' || f)::uuid::text, 'viewer', 'user', md5('user' || u)::uuid::text)
from bench.folder_viewers;

select permissions.set_parent('document', id::text, 'folder', folder_id::text)
from public.documents;

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);
