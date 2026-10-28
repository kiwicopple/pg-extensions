-- Benchmark seed, part 3a (Design B): folders for parent inheritance (PLAN.md
-- §10 G10), with the two-arm projection policy. Design B's native API.
-- bench/run.sh loads it after the share_* workloads, because it replaces the
-- documents select policy; seed_parent_docs.sql follows.
--
-- Data comes from the shape tables (bench/seed_shape.sql), identical for every
-- design:
--   folder f -> md5('folder' || f)::uuid, about 10 per org, parents edge
--               folder -> the org's `tenant` entity (where the rbac preset
--               stores scoped roles)
--   every 5th user holds `viewer` on one folder
--   documents are NOT linked yet: their folder is only the app column
--   documents.folder_id (a `via` column)
--
-- Policies: org roles reach documents through the folder's tenant (`via =>
-- 'tenant'`; every preset role implies viewer), folder viewers through the
-- folder (`via => 'folder'`). The select policy is the permit side of
-- rls_expression('select', 'document', 'id', '{"folder": "folder_id"}'):
-- an id arm for shares and a folder_id arm that projects org and folder access
-- onto folder ids. Like seed_sharing.sql it leaves out the forbid side, since
-- there are no forbids.

\set ON_ERROR_STOP 1

select permissions.define_role('folder', 'viewer');

select permissions.add_parent('folder', md5('folder' || f)::uuid::text, 'tenant', md5('org' || org)::uuid::text)
from bench.folders;

select permissions.grant_role('user', md5('user' || u)::uuid::text, 'viewer', 'folder', md5('folder' || f)::uuid::text)
from bench.folder_viewers;

select permissions.permit('doc org readers', '{select}', 'document', roles => '{viewer}', via => 'tenant');
select permissions.permit('doc folder viewers', '{select}', 'document', roles => '{viewer}', via => 'folder');

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
    or folder_id = any (array(select unnest(permissions.ids('select', 'document', 'folder'))::uuid))
);
