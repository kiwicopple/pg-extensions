-- Goal: rbac preset, managing roles and assignments safely (PLAN.md §6)
-- The extension's copy of test/spec/12_rbac_management.sql (the prototypes' version,
-- in their unprefixed API): the same assertions, with the rbac_* names.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/d/rbac_roles.sql
select permissions.rbac_assign_role(:'bob', 'editor');
select permissions.rbac_assign_role(:'bob', 'editor', :'acme');

select tap.plan(15);

-- assignments
select tap.lives_ok(format($$ select permissions.rbac_assign_role(%L, 'editor') $$, :'bob'), 'assigning the same role twice is idempotent');
select tap.set_eq(permissions.rbac_user_permissions(:'bob'), '{documents.read,documents.edit}', 'and changes nothing');
select tap.throws_ok(format($$ select permissions.rbac_assign_role(%L, 'nonexistent') $$, :'bob'), null, 'assigning an unknown role fails');

select permissions.rbac_unassign_role(:'bob', 'editor');
select tap.set_eq(permissions.rbac_user_permissions(:'bob'), '{}', 'rbac_unassign_role removes the app-wide role');
select tap.set_eq(permissions.rbac_user_permissions(:'bob', :'acme'), '{documents.read,documents.edit}', 'but leaves the same role in other scopes');
select tap.lives_ok(format($$ select permissions.rbac_unassign_role(%L, 'editor') $$, :'bob'), 'unassigning a role the user does not hold is a no-op');

-- defining roles
select tap.throws_ok($$ select permissions.rbac_create_role('viewer', '{documents.read}') $$, null, 'creating a role that exists fails');
select tap.throws_ok($$ select permissions.rbac_create_role('auditor', '{audit.read}', '{nonexistent}') $$, null, 'inheriting an unknown role fails');
select tap.throws_ok($$ select permissions.rbac_create_role('documents.read', '{x.y}') $$, null, 'a role cannot share a name with a permission');
select tap.throws_ok($$ select permissions.rbac_create_role('auditor', '{viewer}') $$, null, 'a permission cannot share a name with a role');

-- a new role works immediately, including for existing permissions
select permissions.rbac_create_role('auditor', '{documents.read,audit.read}');
select permissions.rbac_assign_role(:'dave', 'auditor');
select tap.set_eq(permissions.rbac_user_permissions(:'dave'), '{documents.read,audit.read}', 'a role added later works, sharing an existing permission');

-- dropping roles
select tap.throws_ok($$ select permissions.rbac_drop_role('viewer') $$, null, 'dropping a role that another role inherits fails');
select permissions.rbac_drop_role('auditor');
select tap.set_eq(permissions.rbac_user_permissions(:'dave'), '{}', 'dropping a role removes its assignments');
select tap.set_eq(permissions.rbac_user_permissions(:'bob', :'acme'), '{documents.read,documents.edit}', 'and leaves other roles intact');
select tap.lives_ok($$ select permissions.rbac_create_role('auditor', '{audit.read}') $$, 'a dropped role name can be reused');

select * from tap.finish();
