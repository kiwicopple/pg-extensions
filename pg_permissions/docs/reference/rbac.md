# RBAC SQL functions

Each entry gives the SQL signature, behavior, return type, errors, and corresponding JavaScript method. Functions are in the `permissions` schema.

Examples are fragments: they illustrate a call using existing data, rather than forming a script to run in order. For runnable setup, follow the [RBAC walkthrough](../models/rbac/overview.md). Management and explicit-subject functions require [admin privileges](../integrations/privileges.md); current-subject helpers are granted to `PUBLIC`.

## RBAC functions

These functions manage roles and assignments. Admin only. A role grants permissions and can inherit other roles. An assignment gives a user a role, app-wide (`scope` is `null`) or in one scope.

### `rbac_create_role`

```text
permissions.rbac_create_role(
  role text,
  permissions text[],
  inherits text[] default '{}'
) returns void
```

Creates a role with the permissions that it grants and the roles that it inherits. Role definitions are immutable.

Errors: `rbac:role_exists` (`23505`) when the role exists. `rbac:name_overlap` (`22023`) when a name is both a role and a permission. `rbac:unknown_role` (`22023`) when `inherits` names an unknown role. `rbac:null_argument` (`22004`) when `role`, `permissions` or `inherits` is `null`. An empty array, `'{}'`, is valid for `permissions` and `inherits`.

JavaScript: `rbac.admin.createRole({ role, permissions, inherits? })`.

```sql
select permissions.rbac_create_role(
  role => 'viewer',
  permissions => '{documents.read}'
);
select permissions.rbac_create_role(
  role => 'editor',
  permissions => '{documents.edit}',
  inherits => '{viewer}'
);
```

### `rbac_drop_role`

```text
permissions.rbac_drop_role(role text) returns void
```

Deletes a role and its assignments. You cannot drop a role that another role inherits.

Errors: `rbac:unknown_role` (`22023`) for an unknown role. `rbac:role_in_use` (`2BP01`) when another role inherits the role.

JavaScript: `rbac.admin.dropRole({ role })`.

```sql
select permissions.rbac_create_role(
  role => 'temp',
  permissions => '{temp.use}'
);
select permissions.rbac_drop_role(role => 'temp');
```

### `rbac_assign_role`

```text
permissions.rbac_assign_role(
  user_id text,
  role text,
  scope text default null
) returns void
```

Gives a user a role. When `scope` is `null`, the role applies app-wide. Otherwise it applies in that scope only. A repeated call changes nothing.

Errors: `rbac:unknown_role` (`22023`) for an unknown role. `rbac:null_argument` (`22004`) when `user_id` is `null`.

JavaScript: `rbac.admin.assignRole({ userId, role, scope? })`.

```sql
select permissions.rbac_assign_role(
  user_id => 'alice',
  role => 'editor'
);
select permissions.rbac_assign_role(
  user_id => 'alice',
  role => 'viewer',
  scope => 'acme'
);
select permissions.rbac_assign_role(
  user_id => 'bob',
  role => 'viewer',
  scope => 'acme'
);
```

### `rbac_unassign_role`

```text
permissions.rbac_unassign_role(
  user_id text,
  role text,
  scope text default null
) returns void
```

Removes an assignment. The call changes nothing when the user does not have the role, or when the role does not exist. An app-wide call leaves the assignments in scopes unchanged.

Errors: `rbac:null_argument` (`22004`) when `user_id` or `role` is `null`.

JavaScript: `rbac.admin.unassignRole({ userId, role, scope? })`.

```sql
select permissions.rbac_unassign_role(
  user_id => 'bob',
  role => 'viewer',
  scope => 'acme'
);
```

### `rbac_user_permissions`

```text
permissions.rbac_user_permissions(
  user_id text,
  scope text default null
) returns text[]
```

Returns the permissions of a user, sorted, with inherited permissions. When `scope` is `null`, it returns the app-wide permissions. Otherwise it returns the permissions in that scope. The result is `{}` when the user has none.

Errors: none.

JavaScript: `rbac.admin.userPermissions({ userId, scope? })`.

```sql
select permissions.rbac_user_permissions(user_id => 'alice');
-- {documents.edit,documents.read}
select permissions.rbac_user_permissions(
  user_id => 'alice',
  scope => 'acme'
);
-- {documents.read}
```

### `rbac_users_with_role`

```text
permissions.rbac_users_with_role(
  role text,
  scope text default null
) returns setof text
```

Returns the ids of the users that have the role. The result includes users that have the role through a role that inherits it.

Errors: none.

JavaScript: `rbac.admin.usersWithRole({ role, scope? })`.

```sql
select permissions.rbac_users_with_role(role => 'viewer');
-- alice: through editor
select permissions.rbac_users_with_role(
  role => 'viewer',
  scope => 'acme'
);
-- alice
```

## Current-subject helpers

These functions are granted to `PUBLIC` and answer for the current subject. Only subjects of type `user` hold RBAC roles. Without a subject, checks return `false` and the scope list is empty. App-wide assignments and scoped assignments are separate.

### `rbac_has_permission`

```text
permissions.rbac_has_permission(
  permission text,
  scope text default null
) returns boolean
```

Returns `true` when the current subject has the permission, through a role that it holds directly or by inheritance. When `scope` is `null`, only app-wide assignments count. Otherwise only the assignments in that scope count. An unknown permission gives `false`.

Errors: none.

JavaScript: `rbac.hasPermission({ permission, scope? })`.

```sql
select set_config('permissions.subject_id', 'alice', false);
select permissions.rbac_has_permission(permission => 'documents.edit');
-- true
select permissions.rbac_has_permission(
  permission => 'documents.edit',
  scope => 'acme'
);
-- false: alice is a viewer in acme
```

### `rbac_has_role`

```text
permissions.rbac_has_role(
  role text,
  scope text default null
) returns boolean
```

Returns `true` when the current subject has the role, directly or through a role that inherits it. The scope rule is the same as for `rbac_has_permission`. An unknown role gives `false`.

Errors: none.

JavaScript: `rbac.hasRole({ role, scope? })`.

```sql
select permissions.rbac_has_role(role => 'viewer');
-- true: editor inherits viewer
select permissions.rbac_has_role(
  role => 'viewer',
  scope => 'acme'
);
-- true
```

### `rbac_scopes_with_permission`

```text
permissions.rbac_scopes_with_permission(
  permission text,
  plan_time_guard boolean default permissions._unfolded_null()
) returns text[]
```

Returns the scopes in which the current subject has the permission. App-wide assignments do not appear. The result is `{}` when there is none. The order is not defined. This is the fast function for policies on tables with a tenant column.

Do not pass `plan_time_guard`. The extension ignores it. Its default value makes sure that the planner does not evaluate the call before the query runs.

Errors: none.

JavaScript: `rbac.scopesWithPermission({ permission })`.

```sql
select permissions.rbac_scopes_with_permission(
  permission => 'documents.read'
);
-- {acme}
```
