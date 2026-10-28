-- Benchmark seed, part 3 (Design C): parent inheritance (PLAN.md §10 G10).
-- Design C's native API (apply_model, set_parent, accessible). bench/run.sh
-- loads it after the share_* workloads, because it replaces the documents
-- select policy.
--
-- Data comes from the shape tables (bench/seed_shape.sql), identical for every
-- design:
--   folder f -> md5('folder' || f)::uuid, about 10 per org, parent = the org's
--               preset `tenant` object (where scoped roles live)
--   document -> parent = its folder (documents.folder_id), one parents row each
--   every 5th user is a viewer of one folder
--
-- The model adds `documents.read` as a permission on folder and document that
-- inherits from the parent, all the way up to the preset's
-- tenant.documents.read (every scoped viewer/editor/admin role). The parent
-- chain may name `tenant` even though the model can't define it. The select
-- policy is C's single branch (designs/c-compiled-model.md section 9):
-- accessible() returns every visible document id.

\set ON_ERROR_STOP 1

select count(*) from permissions.apply_model($json$
{
  "types": {
    "team": { "relations": { "member": ["user", "team#member"] } },
    "folder": {
      "parent":      ["tenant"],
      "relations":   { "viewer": ["user"] },
      "permissions": { "documents.read": ["viewer", "parent->documents.read"] }
    },
    "document": {
      "parent":      ["folder"],
      "relations":   { "editor": ["user", "team#member"], "viewer": ["user", "team#member"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "documents.read": ["viewer", "parent->documents.read"] }
    }
  }
}
$json$);

select count(permissions.set_parent('folder', md5('folder' || f)::uuid, 'tenant', md5('org' || org)::uuid))
from bench.folders;

select count(permissions.grant('folder', md5('folder' || f)::uuid, 'viewer', 'user', md5('user' || u)::uuid))
from bench.folder_viewers;

select count(permissions.set_parent('document', id, 'folder', folder_id))
from public.documents;

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'documents.read'))::uuid[])
);
