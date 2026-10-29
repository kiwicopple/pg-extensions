-- Benchmark seed, part 3a (Design D): folders, with the two-arm projection
-- policy. bench/run.sh loads it after the share_* workloads, because it
-- replaces the FGA select policy; seed_parent_docs.sql follows.
--
-- Data from the shape tables (bench/seed_shape.sql), as for every design:
--   every 5th user is a viewer of one folder: `folder:<f>#viewer@user:<u>`
--   documents are NOT linked yet: their folder is only the app column
--   documents.folder_id
--
-- Difference from A: A's folder#viewer inherits `documents.read` from the
-- org's tenant object, because A's rbac preset stores scoped roles as tuples.
-- D keeps org roles in rbac_*, so the folder relation holds folder viewers
-- only and org roles keep coming from seed_rbac.sql's documents_select
-- policy (permissive policies OR). bench.folders (folder -> org) isn't
-- written: every document of an org is in one of that org's folders, so the
-- RBAC arm on documents.org_id covers exactly what A's folder -> tenant link
-- adds. Visible sets are identical (the checksums compare them).
--
-- The FGA policy projects onto the app column: documents viewable directly
-- (team/direct shares) or in a folder the user views. Each arm is its own
-- ListObjects; with no document parent tuples, `viewer from parent` finds
-- nothing.

\set ON_ERROR_STOP 1

select permissions.fga_write(jsonb_build_object('tuple_keys', keys, 'on_duplicate', 'ignore'))
from (
    select jsonb_agg(jsonb_build_object('user', 'user:' || md5('user' || u)::uuid, 'relation', 'viewer',
                                        'object', 'folder:' || md5('folder' || f)::uuid)) as keys
    from (select u, f, (row_number() over () - 1) / 100 as chunk   -- the Write cap (seed_sharing.sql)
          from (select distinct u, f from bench.folder_viewers) d) v
    group by chunk
) w;

drop policy documents_select_fga on public.documents;
create policy documents_select_fga on public.documents for select to authenticated using (
    id = any (array(select permissions.fga_list_object_ids_current('document', 'viewer')::uuid))
    or folder_id = any (array(select permissions.fga_list_object_ids_current('folder', 'viewer')::uuid))
);
