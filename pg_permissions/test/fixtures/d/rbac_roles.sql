-- The roles from the RBAC scenario in research/plan.md §6, created through the extension's rbac_* API (the prototypes' copy is ../rbac_roles.sql).
-- Run as the test superuser (role management is admin-only).
select permissions.rbac_create_role('viewer', '{documents.read}');
select permissions.rbac_create_role('editor', '{documents.edit}', '{viewer}');
select permissions.rbac_create_role('admin',  '{documents.delete,users.manage}', '{editor}');
