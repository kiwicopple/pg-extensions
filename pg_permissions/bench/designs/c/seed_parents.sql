-- Benchmark seed, part 3a (Design C): folders for parent inheritance (PLAN.md
-- §10 G10), with the two-arm projection policy. Design C's native API
-- (apply_model, set_parent, accessible). bench/run.sh loads it after the
-- share_* workloads, because it replaces the documents select policy;
-- seed_parent_docs.sql follows.
--
-- Data comes from the shape tables (bench/seed_shape.sql), identical for every
-- design:
--   folder f -> md5('folder' || f)::uuid, about 10 per org, parent = the org's
--               preset `tenant` object (where scoped roles live)
--   every 5th user is a viewer of one folder
--   documents are NOT linked yet: their folder is only the app column
--   documents.folder_id
--
-- The model adds `documents.read` as a permission on folder and document that
-- inherits from the parent, all the way up to the preset's
-- tenant.documents.read (every scoped viewer/editor/admin role). The policy
-- projects onto the app column: documents where the caller holds `viewer`
-- (shares; a relation, so no parent expansion) or in a folder with
-- documents.read.

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

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'viewer'))::uuid[])
    or folder_id = any ((select permissions.accessible('folder', 'documents.read'))::uuid[])
);
