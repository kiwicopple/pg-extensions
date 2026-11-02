-- Benchmark seed, part 3b (Design D): link every document to its folder and
-- switch to the single-branch FGA policy. Loaded after the parents_proj_*
-- workloads (seed_parents.sql).
--
-- document#viewer is `... or viewer from parent` in the model written by
-- seed_sharing.sql, so folder viewers and team/direct shares come out of one
-- fga_list_object_ids_current() call. Org roles still come from the RBAC
-- policy (seed_parents.sql explains why); A's single call also walks them to
-- every document of the user's orgs.
--
-- Storage: one parent tuple per document (10k at small, 1M at large),
-- `document:<id>#parent@folder:<folder_id>`, mirroring documents.folder_id.
-- Loaded with fga_write in chunks of 100 tuple keys, the Write cap (seed_sharing.sql).

\set ON_ERROR_STOP 1

select permissions.fga_write(jsonb_build_object('tuple_keys', keys, 'on_duplicate', 'ignore'))
from (
    select jsonb_agg(jsonb_build_object('user', 'folder:' || folder_id, 'relation', 'parent',
                                        'object', 'document:' || id)) as keys
    from (select id, folder_id, (row_number() over () - 1) / 100 as chunk from public.documents) d
    group by chunk
) w;

drop policy documents_select_fga on public.documents;
create policy documents_select_fga on public.documents for select to authenticated using (
    id = any (array(select permissions.fga_list_object_ids_current('document', 'viewer')::uuid))
);
