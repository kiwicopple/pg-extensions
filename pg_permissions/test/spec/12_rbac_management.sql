-- Goal: rbac preset, managing roles and assignments safely (research/plan.md §6)
\ir ../fixtures/ids.sql
\ir ../fixtures/rbac_roles.sql
select permissions.assign_role(:'bob', 'editor');
select permissions.assign_role(:'bob', 'editor', :'acme');

select tap.plan(15);

-- assignments
select tap.lives_ok(format($$ select permissions.assign_role(%L, 'editor') $$, :'bob'), 'assigning the same role twice is idempotent');
select tap.set_eq(permissions.user_permissions(:'bob'), '{documents.read,documents.edit}', 'and changes nothing');
select tap.throws_ok(format($$ select permissions.assign_role(%L, 'nonexistent') $$, :'bob'), null, 'assigning an unknown role fails');

select permissions.unassign_role(:'bob', 'editor');
select tap.set_eq(permissions.user_permissions(:'bob'), '{}', 'unassign_role removes the app-wide role');
select tap.set_eq(permissions.user_permissions(:'bob', :'acme'), '{documents.read,documents.edit}', 'but leaves the same role in other scopes');
select tap.lives_ok(format($$ select permissions.unassign_role(%L, 'editor') $$, :'bob'), 'unassigning a role the user does not hold is a no-op');

-- defining roles
select tap.throws_ok($$ select permissions.create_role('viewer', '{documents.read}') $$, null, 'creating a role that exists fails');
select tap.throws_ok($$ select permissions.create_role('auditor', '{audit.read}', '{nonexistent}') $$, null, 'inheriting an unknown role fails');
select tap.throws_ok($$ select permissions.create_role('documents.read', '{x.y}') $$, null, 'a role cannot share a name with a permission');
select tap.throws_ok($$ select permissions.create_role('auditor', '{viewer}') $$, null, 'a permission cannot share a name with a role');

-- a new role works immediately, including for existing permissions
select permissions.create_role('auditor', '{documents.read,audit.read}');
select permissions.assign_role(:'dave', 'auditor');
select tap.set_eq(permissions.user_permissions(:'dave'), '{documents.read,audit.read}', 'a role added later works, sharing an existing permission');

-- dropping roles
select tap.throws_ok($$ select permissions.drop_role('viewer') $$, null, 'dropping a role that another role inherits fails');
select permissions.drop_role('auditor');
select tap.set_eq(permissions.user_permissions(:'dave'), '{}', 'dropping a role removes its assignments');
select tap.set_eq(permissions.user_permissions(:'bob', :'acme'), '{documents.read,documents.edit}', 'and leaves other roles intact');
select tap.lives_ok($$ select permissions.create_role('auditor', '{audit.read}') $$, 'a dropped role name can be reused');

select * from tap.finish();
