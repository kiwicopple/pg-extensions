-- Benchmark seed, part 3b (Design B): link every document to its folder in
-- the parents table and switch to B's single-branch policy. Loaded after the
-- parents_proj_* workloads (seed_parents.sql).
--
-- With documents as parents-table children, ids('select', 'document') returns
-- every document below an anchor the caller holds (research/designs/b-policy-first.md,
-- "Partial evaluation for RLS": "resources linked by parents rows below an
-- anchor"), plus the shares, so one call covers everything. This is B's only
-- single-expression form: without document rows, folder_id = any(ids(..,
-- 'folder')) alone would miss the per-document shares.
--
-- Storage: one parents row and two closure rows (folder, tenant) per document
-- (10k at small, 1M at large), mirroring documents.folder_id.

\set ON_ERROR_STOP 1

select permissions.add_parent('document', id::text, 'folder', folder_id::text)
from public.documents;

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
);
