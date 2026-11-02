-- Benchmark seed, part 3b (design E, Cedar): every document gets its folder
-- as its parent, and the select policy becomes one list. Loaded after the
-- parents_proj_* workloads (seed_parents.sql).
--
-- folder_read's `resource in Folder` now reaches the folder's documents, so
-- folder viewers and shares come out of one cedar_list_resources_current
-- call: it walks the descendants of each linked folder. Org roles still come
-- from seed_rbac.sql's policy.
--
-- Storage: the parent of each document, one row of cedar_entity_parents per
-- document (10k at small, 1M at large), put in calls of 10,000 entities.

\set ON_ERROR_STOP 1

select count(permissions.cedar_put_entities(entities => es))
from (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Document', 'id', d.id),
                                          'parents', jsonb_build_array(jsonb_build_object('type', 'Folder', 'id', d.folder_id)))) as es
      from (select id, folder_id, row_number() over (order by id) as n from public.documents) d
      group by d.n / 10000) c;

drop policy documents_select_cedar on public.documents;
create policy documents_select_cedar on public.documents for select to authenticated using (
    id = any (array(select permissions.cedar_list_resources_current('Action::"read"', 'Document')::uuid))
);
