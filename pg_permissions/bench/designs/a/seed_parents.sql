-- Benchmark seed, part 3a (Design A): folders for parent inheritance (PLAN.md
-- §10 G10), with the two-arm projection policy. Uses Design A's zanzibar-level
-- API. bench/run.sh loads it after the share_* workloads, because it replaces
-- the documents select policy; seed_parent_docs.sql follows.
--
-- Data comes from the shape tables (bench/seed_shape.sql), identical for every
-- design:
--   folder f -> md5('folder' || f)::uuid, about 10 per org, parent = the org's
--               `tenant` object (where the rbac preset stores scoped roles)
--   every 5th user is a viewer of one folder
--   documents are NOT linked yet: their folder is only the app column
--   documents.folder_id
--
-- Inheritance: tenant#documents.read (every scoped viewer/editor/admin role)
-- -> folder#viewer. The policy projects onto the app column: documents viewable
-- directly (team/direct shares) or in a viewable folder. Each arm is its own
-- walk; with no document parent tuples, the folder walk stops at folders.

\set ON_ERROR_STOP 1

select permissions.define_type('folder');
select permissions.define_relation('folder', 'parent');
select permissions.define_relation('folder', 'viewer', from_parent => '{documents.read}');

select permissions.set_parent('folder', md5('folder' || f)::uuid::text, 'tenant', md5('org' || org)::uuid::text)
from bench.folders;

select permissions.grant('folder', md5('folder' || f)::uuid::text, 'viewer', 'user', md5('user' || u)::uuid::text)
from bench.folder_viewers;

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
    or folder_id = any (array(select unnest(permissions.list_objects('folder', 'viewer'))::uuid))
);
