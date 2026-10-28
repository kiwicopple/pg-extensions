-- Benchmark seed, part 3b (Design C): link every document to its folder and
-- switch to C's single-branch policy (designs/c-compiled-model.md section 9).
-- Loaded after the parents_proj_* workloads (seed_parents.sql).
--
-- accessible('document', 'documents.read') expands grants on containers to
-- their documents, so it returns every visible document id.
--
-- Storage: one parents row per document (10k at small, 1M at large),
-- mirroring documents.folder_id.

\set ON_ERROR_STOP 1

select count(permissions.set_parent('document', id, 'folder', folder_id))
from public.documents;

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'documents.read'))::uuid[])
);
