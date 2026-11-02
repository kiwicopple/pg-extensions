-- Goal: rbac preset, tenant-scoped roles (research/plan.md §6, RBAC scenario steps 3 and 5)
-- The extension's copy of test/spec/11_rbac_tenant.sql (the prototypes' version,
-- in their unprefixed API): the same assertions, with the rbac_* names.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/d/rbac_roles.sql
select permissions.rbac_assign_role(:'alice', 'admin',  :'acme');
select permissions.rbac_assign_role(:'bob',   'editor', :'acme');
select permissions.rbac_assign_role(:'bob',   'viewer', :'globex');
select permissions.rbac_assign_role(:'carol', 'admin');   -- app-wide only

select tap.plan(13);

select set_config('permissions.subject_id', :'bob', false);
select tap.is(permissions.rbac_has_permission('documents.edit', :'acme'),   true,  'Bob can edit in acme');
select tap.is(permissions.rbac_has_permission('documents.edit', :'globex'), false, 'Bob cannot edit in globex');
select tap.is(permissions.rbac_has_permission('documents.read', :'globex'), true,  'Bob can read in globex');
select tap.is(permissions.rbac_has_permission('documents.read'),            false, 'scoped roles do not grant app-wide permissions');

select tap.set_eq(permissions.rbac_scopes_with_permission('documents.edit'), array[:'acme'], 'scopes where Bob can edit: acme');
select tap.set_eq(permissions.rbac_scopes_with_permission('documents.read'), array[:'acme', :'globex'], 'scopes where Bob can read: acme and globex (via inheritance in acme)');

select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(permissions.rbac_scopes_with_permission('documents.read'), '{}', 'app-wide roles do not appear as scopes');
select tap.is(permissions.rbac_has_role('admin'), true, 'Carol is an app-wide admin');
select tap.is(permissions.rbac_has_role('admin', :'acme'), false, 'but not an admin of acme');

-- admin queries from the scenario
select tap.set_eq(permissions.rbac_user_permissions(:'bob', :'globex'), '{documents.read}', 'Bob''s permissions in globex');
select tap.set_eq(permissions.rbac_user_permissions(:'bob', :'acme'), '{documents.read,documents.edit}', 'Bob''s permissions in acme');
select tap.set_eq(array(select permissions.rbac_users_with_role('admin', :'acme')), array[:'alice'], 'admins of acme: Alice');
select tap.set_eq(array(select permissions.rbac_users_with_role('viewer', :'acme')), array[:'alice', :'bob'], 'viewers of acme include users who inherit viewer');

select * from tap.finish();
