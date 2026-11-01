-- The roles from the RBAC scenario in research/plan.md §6, created through the preset API.
-- Run as the test superuser (role management is admin-only).
select permissions.create_role('viewer', '{documents.read}');
select permissions.create_role('editor', '{documents.edit}', '{viewer}');
select permissions.create_role('admin',  '{documents.delete,users.manage}', '{editor}');
