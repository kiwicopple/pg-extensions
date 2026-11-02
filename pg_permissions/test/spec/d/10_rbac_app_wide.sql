-- Goal: rbac preset, app-wide roles (research/plan.md §6, RBAC scenario step 1 and 5)
-- The extension's copy of test/spec/10_rbac_app_wide.sql (the prototypes' version,
-- in their unprefixed API): the same assertions, with the rbac_* names.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/d/rbac_roles.sql
select permissions.rbac_assign_role(:'alice', 'admin');
select permissions.rbac_assign_role(:'bob',   'editor');
select permissions.rbac_assign_role(:'carol', 'viewer');

select tap.plan(17);

-- what each user can do
select tap.set_eq(permissions.rbac_user_permissions(:'alice'), '{documents.read,documents.edit,documents.delete,users.manage}', 'admin gets its own and all inherited permissions');
select tap.set_eq(permissions.rbac_user_permissions(:'bob'),   '{documents.read,documents.edit}', 'editor gets edit plus inherited read');
select tap.set_eq(permissions.rbac_user_permissions(:'carol'), '{documents.read}', 'viewer gets read only');
select tap.set_eq(permissions.rbac_user_permissions(:'dave'),  '{}', 'a user with no roles has no permissions');

select set_config('permissions.subject_id', :'carol', false);
select tap.is(permissions.rbac_has_permission('documents.read'),   true,  'Carol (viewer) can read');
select tap.is(permissions.rbac_has_permission('documents.edit'),   false, 'Carol (viewer) cannot edit');
select tap.is(permissions.rbac_has_permission('documents.delete'), false, 'Carol (viewer) cannot delete');

select set_config('permissions.subject_id', :'bob', false);
select tap.is(permissions.rbac_has_permission('documents.edit'),   true,  'Bob (editor) can edit');
select tap.is(permissions.rbac_has_permission('users.manage'),     false, 'Bob (editor) cannot manage users');

select set_config('permissions.subject_id', :'alice', false);
select tap.is(permissions.rbac_has_permission('users.manage'),     true,  'Alice (admin) can manage users');

-- roles
select set_config('permissions.subject_id', :'bob', false);
select tap.is(permissions.rbac_has_role('editor'), true,  'rbac_has_role is true for a directly assigned role');
select tap.is(permissions.rbac_has_role('viewer'), true,  'rbac_has_role is true for an inherited role');
select tap.is(permissions.rbac_has_role('admin'),  false, 'rbac_has_role is false for a role that inherits yours');

-- unknown names deny rather than error, so a stale policy can't break queries
select tap.is(permissions.rbac_has_permission('documents.nonexistent'), false, 'unknown permission is false');
select tap.is(permissions.rbac_has_role('nonexistent'), false, 'unknown role is false');
select tap.is(permissions.rbac_has_role('documents.read'), false, 'a permission name is not a role');

-- app-wide roles don't apply inside a scope (no hidden inheritance)
select set_config('permissions.subject_id', :'alice', false);
select tap.is(permissions.rbac_has_permission('documents.read', :'acme'), false, 'an app-wide role does not grant anything in a scope');

select * from tap.finish();
