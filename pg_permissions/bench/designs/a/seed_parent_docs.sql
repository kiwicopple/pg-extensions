-- Benchmark seed, part 3b (Design A): link every document to its folder and
-- switch to A's single-branch policy (research/designs/a-tuple-core.md §12.1).
-- Loaded after the parents_proj_* workloads (seed_parents.sql).
--
-- document#viewer inherits folder#viewer, so org roles, folder viewers and
-- team/direct shares all come out of one list_objects() call, which walks to
-- every visible document.
--
-- Storage: one parent tuple per document (10k at small, 1M at large),
-- mirroring documents.folder_id. A real app would attach
-- permissions.sync_parent() to the table instead of seeding once.

\set ON_ERROR_STOP 1

select permissions.define_relation('document', 'parent');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}');

select permissions.set_parent('document', id::text, 'folder', folder_id::text)
from public.documents;

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);
