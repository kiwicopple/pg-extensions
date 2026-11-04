# RBAC API

The JavaScript examples use a server client called `permissions`, created with `throwOnError: true` so a failed call stops the example. See [JavaScript setup](../integrations/javascript.md) to create the client.

Examples are fragments: they illustrate a call using existing data, rather than forming a script to run in order. For runnable setup, follow the [RBAC walkthrough](../models/rbac/overview.md). Management and explicit-subject functions require [admin privileges](../integrations/privileges.md); current-subject helpers are granted to `PUBLIC`.

## RBAC functions

These functions manage roles and assignments. Admin only. A role grants permissions and can inherit other roles. An assignment gives a user a role, app-wide (`scope` is `null`) or in one scope.

### `rbac_create_role`

Creates a role with the permissions that it grants and the roles that it inherits. Role definitions are immutable.

Errors: `rbac:role_exists` (`23505`) when the role exists. `rbac:name_overlap` (`22023`) when a name is both a role and a permission. `rbac:unknown_role` (`22023`) when `inherits` names an unknown role. `rbac:null_argument` (`22004`) when `role`, `permissions` or `inherits` is `null`. An empty array, `'{}'`, is valid for `permissions` and `inherits`.

```js tab="JavaScript"
await permissions.rbac.admin.createRole({
  role: 'viewer',
  permissions: ['documents.read'],
})
await permissions.rbac.admin.createRole({
  role: 'editor',
  permissions: ['documents.edit'],
  inherits: ['viewer'],
})
```

```sql tab="SQL"
-- permissions.rbac_create_role(
--   role text,
--   permissions text[],
--   inherits text[] default '{}'
-- ) returns void

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

Deletes a role and its assignments. You cannot drop a role that another role inherits.

Errors: `rbac:unknown_role` (`22023`) for an unknown role. `rbac:role_in_use` (`2BP01`) when another role inherits the role.

```js tab="JavaScript"
await permissions.rbac.admin.createRole({
  role: 'temp',
  permissions: ['temp.use'],
})
await permissions.rbac.admin.dropRole({ role: 'temp' })
```

```sql tab="SQL"
-- permissions.rbac_drop_role(role text) returns void

select permissions.rbac_create_role(
  role => 'temp',
  permissions => '{temp.use}'
);
select permissions.rbac_drop_role(role => 'temp');
```

### `rbac_assign_role`

Gives a user a role. When `scope` is `null`, the role applies app-wide. Otherwise it applies in that scope only. A repeated call changes nothing.

Errors: `rbac:unknown_role` (`22023`) for an unknown role. `rbac:null_argument` (`22004`) when `user_id` is `null`.

```js tab="JavaScript"
await permissions.rbac.admin.assignRole({ userId: 'alice', role: 'editor' })
await permissions.rbac.admin.assignRole({ userId: 'alice', role: 'viewer', scope: 'acme' })
await permissions.rbac.admin.assignRole({ userId: 'bob', role: 'viewer', scope: 'acme' })
```

```sql tab="SQL"
-- permissions.rbac_assign_role(
--   user_id text,
--   role text,
--   scope text default null
-- ) returns void

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

Removes an assignment. The call changes nothing when the user does not have the role, or when the role does not exist. An app-wide call leaves the assignments in scopes unchanged.

Errors: `rbac:null_argument` (`22004`) when `user_id` or `role` is `null`.

```js tab="JavaScript"
await permissions.rbac.admin.unassignRole({
  userId: 'bob',
  role: 'viewer',
  scope: 'acme',
})
```

```sql tab="SQL"
-- permissions.rbac_unassign_role(
--   user_id text,
--   role text,
--   scope text default null
-- ) returns void

select permissions.rbac_unassign_role(
  user_id => 'bob',
  role => 'viewer',
  scope => 'acme'
);
```

### `rbac_user_permissions`

Returns the permissions of a user, sorted, with inherited permissions. When `scope` is `null`, it returns the app-wide permissions. Otherwise it returns the permissions in that scope. The result is `{}` when the user has none.

Errors: none.

```js tab="JavaScript"
const { data: appPermissions } = await permissions.rbac.admin.userPermissions({
  userId: 'alice',
})
// ['documents.edit', 'documents.read']
const { data: acmePermissions } = await permissions.rbac.admin.userPermissions({
  userId: 'alice',
  scope: 'acme',
})
// ['documents.read']
```

```sql tab="SQL"
-- permissions.rbac_user_permissions(
--   user_id text,
--   scope text default null
-- ) returns text[]

select permissions.rbac_user_permissions(user_id => 'alice');
-- {documents.edit,documents.read}
select permissions.rbac_user_permissions(
  user_id => 'alice',
  scope => 'acme'
);
-- {documents.read}
```

### `rbac_users_with_role`

Returns the ids of the users that have the role. The result includes users that have the role through a role that inherits it.

Errors: none.

```js tab="JavaScript"
const { data: appViewers } = await permissions.rbac.admin.usersWithRole({
  role: 'viewer',
})
// ['alice'] through her editor role
const { data: acmeViewers } = await permissions.rbac.admin.usersWithRole({
  role: 'viewer',
  scope: 'acme',
})
// ['alice']
```

```sql tab="SQL"
-- permissions.rbac_users_with_role(
--   role text,
--   scope text default null
-- ) returns setof text

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

The examples use `const alice = permissions.as({ id: 'alice' })` on a backend that has already verified Alice's identity. A browser client calls the same methods for the user in its access token.

### `rbac_has_permission`

Returns `true` when the current subject has the permission, through a role that it holds directly or by inheritance. When `scope` is `null`, only app-wide assignments count. Otherwise only the assignments in that scope count. An unknown permission gives `false`.

Errors: none.

```js tab="JavaScript"
const { data: canEdit } = await alice.rbac.hasPermission({
  permission: 'documents.edit',
})
// true
const { data: canEditAcme } = await alice.rbac.hasPermission({
  permission: 'documents.edit',
  scope: 'acme',
})
// false
```

```sql tab="SQL"
-- permissions.rbac_has_permission(
--   permission text,
--   scope text default null
-- ) returns boolean

begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.rbac_has_permission(permission => 'documents.edit');
-- true
select permissions.rbac_has_permission(
  permission => 'documents.edit',
  scope => 'acme'
);
-- false: alice is a viewer in acme
commit;
```

### `rbac_has_role`

Returns `true` when the current subject has the role, directly or through a role that inherits it. The scope rule is the same as for `rbac_has_permission`. An unknown role gives `false`.

Errors: none.

```js tab="JavaScript"
const { data: appViewer } = await alice.rbac.hasRole({ role: 'viewer' })
// true through her editor role
const { data: acmeViewer } = await alice.rbac.hasRole({ role: 'viewer', scope: 'acme' })
// true
```

```sql tab="SQL"
-- permissions.rbac_has_role(
--   role text,
--   scope text default null
-- ) returns boolean

begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.rbac_has_role(role => 'viewer');
-- true: editor inherits viewer
select permissions.rbac_has_role(
  role => 'viewer',
  scope => 'acme'
);
-- true
commit;
```

### `rbac_scopes_with_permission`

Returns the scopes in which the current subject has the permission. App-wide assignments do not appear. The result is `{}` when there is none. The order is not defined. This is the fast function for policies on tables with a tenant column.

Do not pass `plan_time_guard`. The extension ignores it. Its default value makes sure that the planner does not evaluate the call before the query runs.

Errors: none.

```js tab="JavaScript"
const { data: scopes } = await alice.rbac.scopesWithPermission({
  permission: 'documents.read',
})
// ['acme']
```

```sql tab="SQL"
-- permissions.rbac_scopes_with_permission(
--   permission text,
--   plan_time_guard boolean default permissions._unfolded_null()
-- ) returns text[]

begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.rbac_scopes_with_permission(
  permission => 'documents.read'
);
-- {acme}
commit;
```
