# Manage roles and assignments

Assign, revoke, and replace roles from a trusted backend.

The examples continue [tenant-scoped roles](tenants.md). Use the same database and ID variables, and run management calls as the extension owner or an explicitly authorized backend role.

## Change and remove roles

Role definitions are immutable. To change the permissions of a role, drop the role and create it again. Then assign it again, because `rbac_drop_role` removes the assignments of the role. Manage role definitions through your backend or database migrations.

You can repeat `assignRole` or `unassignRole` for the same user, role, and scope. To remove a scoped assignment, pass the same `scope`. An app-wide unassignment does not remove the same role in a scope.

```js tab="JavaScript"
const assignedBob = await permissions.rbac.admin.assignRole({
  userId: bob,
  role: 'editor',
})
if (assignedBob.error) throw assignedBob.error
// already held: no change
const removedEditor = await permissions.rbac.admin.unassignRole({
  userId: dave,
  role: 'editor',
})
if (removedEditor.error) throw removedEditor.error
// Dave does not hold the role: no change
const removedUnknown = await permissions.rbac.admin.unassignRole({
  userId: dave,
  role: 'nonexistent',
})
if (removedUnknown.error) throw removedUnknown.error
// no change, no error
```

```sql tab="SQL"
select permissions.rbac_assign_role(
  user_id => :'bob',
  role => 'editor'
);
-- already held: no change
select permissions.rbac_unassign_role(
  user_id => :'dave',
  role => 'editor'
);
-- Dave does not hold the role: no change
select permissions.rbac_unassign_role(
  user_id => :'dave',
  role => 'nonexistent'
);
-- no change, no error
```

You cannot drop a role that another role inherits. When you drop a role, the extension deletes its assignments. You can reuse the name of a dropped role at once.

```js tab="JavaScript"
const createdAuditor = await permissions.rbac.admin.createRole({
  role: 'auditor',
  permissions: ['audit.read'],
  inherits: ['viewer'],
})
if (createdAuditor.error) throw createdAuditor.error
const assignedDave = await permissions.rbac.admin.assignRole({
  userId: dave,
  role: 'auditor',
})
if (assignedDave.error) throw assignedDave.error
const before = await permissions.rbac.admin.userPermissions({
  userId: dave,
})
// before.data: ['audit.read', 'documents.read']

const inUse = await permissions.rbac.admin.dropRole({
  role: 'viewer',
})
// inUse.error.message:
//   role 'viewer' is inherited by 'auditor', 'editor'

const droppedAuditor = await permissions.rbac.admin.dropRole({ role: 'auditor' })
if (droppedAuditor.error) throw droppedAuditor.error
const after = await permissions.rbac.admin.userPermissions({
  userId: dave,
})
// after.data: []: the assignment went with the role
```

```sql tab="SQL"
select permissions.rbac_create_role(
  role => 'auditor',
  permissions => '{audit.read}',
  inherits => '{viewer}'
);
select permissions.rbac_assign_role(
  user_id => :'dave',
  role => 'auditor'
);
select permissions.rbac_user_permissions(user_id => :'dave');
-- {audit.read,documents.read}

select permissions.rbac_drop_role(role => 'viewer');
-- ERROR:  role 'viewer' is inherited by 'auditor', 'editor'

select permissions.rbac_drop_role(role => 'auditor');
select permissions.rbac_user_permissions(user_id => :'dave');
-- {}: the assignment went with the role
```

Use `usersWithRole` to list user IDs. This includes users who inherited the role.

```js tab="JavaScript"
const { data: editors } = await permissions.rbac.admin.usersWithRole({
  role: 'editor',
})
// [alice, bob]: Alice (through admin) and Bob
```

```sql tab="SQL"
select * from permissions.rbac_users_with_role(role => 'editor');
-- Alice (through admin) and Bob
```

## Errors

The RBAC functions raise these errors. Each error has a `DETAIL` code and a `HINT`. The code names the cause. The hint tells you what to do. [Errors and limits](../../reference/errors.md#rbac-errors) describes each code.

| Function | Cause | `DETAIL` code | SQLSTATE |
| --- | --- | --- | --- |
| `rbac_create_role` | The role exists | `rbac:role_exists` | `23505` |
| `rbac_create_role` | A role in `inherits` does not exist | `rbac:unknown_role` | `22023` |
| `rbac_create_role` | A role and a permission have the same name | `rbac:name_overlap` | `22023` |
| `rbac_create_role` | `role`, `permissions` or `inherits` is `null` | `rbac:null_argument` | `22004` |
| `rbac_unassign_role` | `user_id` or `role` is `null` | `rbac:null_argument` | `22004` |
| `rbac_assign_role` | The role does not exist | `rbac:unknown_role` | `22023` |
| `rbac_assign_role` | `user_id` is null | `rbac:null_argument` | `22004` |
| `rbac_drop_role` | The role does not exist | `rbac:unknown_role` | `22023` |
| `rbac_drop_role` | Another role inherits the role | `rbac:role_in_use` | `2BP01` |

```js tab="JavaScript"
const exists = await permissions.rbac.admin.createRole({
  role: 'viewer',
  permissions: ['documents.read'],
})
// exists.error.message: role 'viewer' already exists
// exists.error.details: rbac:role_exists role='viewer'

const unknownParent = await permissions.rbac.admin.createRole({
  role: 'reviewer',
  permissions: ['audit.read'],
  inherits: ['nonexistent'],
})
// unknownParent.error.message:
//   unknown role 'nonexistent' in inherits of role 'reviewer'
// unknownParent.error.details:
//   rbac:unknown_role role='nonexistent'

const isPermission = await permissions.rbac.admin.createRole({
  role: 'documents.read',
  permissions: ['x.y'],
})
// isPermission.error.details: rbac:name_overlap

const isRole = await permissions.rbac.admin.createRole({
  role: 'moderator',
  permissions: ['viewer'],
})
// isRole.error.details: rbac:name_overlap

const noRole = await permissions.rbac.admin.assignRole({
  userId: bob,
  role: 'nonexistent',
})
// noRole.error.details: rbac:unknown_role role='nonexistent'

const noDrop = await permissions.rbac.admin.dropRole({
  role: 'nonexistent',
})
// noDrop.error.details: rbac:unknown_role role='nonexistent'
```

```sql tab="SQL"
select permissions.rbac_create_role(
  role => 'viewer',
  permissions => '{documents.read}'
);
-- ERROR:  role 'viewer' already exists
-- DETAIL:  rbac:role_exists role='viewer'
select permissions.rbac_create_role(
  role => 'reviewer',
  permissions => '{audit.read}',
  inherits => '{nonexistent}'
);
-- ERROR:  unknown role 'nonexistent' in inherits of role 'reviewer'
-- DETAIL:  rbac:unknown_role role='nonexistent'
select permissions.rbac_create_role(
  role => 'documents.read',
  permissions => '{x.y}'
);
-- ERROR:  role and permission names must not overlap: 'documents.read' is already a permission
-- DETAIL:  rbac:name_overlap
select permissions.rbac_create_role(
  role => 'moderator',
  permissions => '{viewer}'
);
-- ERROR:  role and permission names must not overlap: 'viewer' is already a role
-- DETAIL:  rbac:name_overlap
select permissions.rbac_assign_role(
  user_id => :'bob',
  role => 'nonexistent'
);
-- ERROR:  unknown role 'nonexistent'
-- DETAIL:  rbac:unknown_role role='nonexistent'
select permissions.rbac_drop_role(role => 'nonexistent');
-- ERROR:  unknown role 'nonexistent'
-- DETAIL:  rbac:unknown_role role='nonexistent'
```
