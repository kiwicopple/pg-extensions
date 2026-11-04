# Roles and permissions (RBAC)

Use RBAC when access follows a role, such as viewer, editor, or administrator. Assign roles across the application or within a scope such as an organization. Roles can inherit permissions from other roles.

Store assignments in Postgres, then call `rbac.hasPermission` from your request handler. To have Postgres enforce a permission on every table query, you can also use it in an RLS policy.

This walkthrough starts in a fresh database with the extension installed. Create the roles here, then continue with [app-wide roles](app-wide.md) and [tenant-scoped roles](tenants.md). Read [identity](../../integrations/identity.md) and [privileges](../../integrations/privileges.md) before integrating the examples into a request handler.

## Use from JavaScript

[Install the JavaScript client](../../integrations/javascript.md), then create a server client with a database role that can manage permissions. Keep the connection string on your backend.

```js
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)
```

Use `permissions.rbac.admin` to define roles or change another user’s assignments. For a check in a request handler, use `permissions.as({ id })` with the user ID from your verified session. Each method returns `{ data, error }` by default. Handle `error` before acting on `data`.

## Before you start

The examples use these IDs for six users and two organizations. Define them as JavaScript constants or as variables in your psql session.

```js tab="JavaScript"
const alice = '11111111-1111-1111-1111-111111111111'
const bob = '22222222-2222-2222-2222-222222222222'
const carol = '33333333-3333-3333-3333-333333333333'
const dave = '44444444-4444-4444-4444-444444444444'
const erin = '55555555-5555-5555-5555-555555555555'
const frank = '66666666-6666-6666-6666-666666666666'
const acme = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
const globex = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
```

```sql tab="SQL"
\set alice  '11111111-1111-1111-1111-111111111111'
\set bob    '22222222-2222-2222-2222-222222222222'
\set carol  '33333333-3333-3333-3333-333333333333'
\set dave   '44444444-4444-4444-4444-444444444444'
\set erin   '55555555-5555-5555-5555-555555555555'
\set frank  '66666666-6666-6666-6666-666666666666'
\set acme   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
\set globex 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
```

In your application, these are arguments. The extension accepts any text as an ID. The examples use UUIDs because the example tables have `uuid` keys.

Statements that change roles run as the extension owner. This page calls that role the admin. Examples that start with `set local role authenticated` show what a client sees.

### Database roles for the optional RLS examples

The later RLS examples use the Supabase database role names `anon`, `authenticated` and `service_role`. Supabase has these roles. On plain Postgres, create them if you want to run those sections. The extension and the direct permission checks do not need them.

```sql
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
```

## Create roles

Define each role once, as the admin. A role has a name, a list of permissions, and a list of roles that it inherits. Here `editor` inherits `viewer`, and `admin` inherits `editor`:

```js tab="JavaScript"
const createdViewer = await permissions.rbac.admin.createRole({
  role: 'viewer',
  permissions: ['documents.read'],
})
if (createdViewer.error) throw createdViewer.error
const createdEditor = await permissions.rbac.admin.createRole({
  role: 'editor',
  permissions: ['documents.edit'],
  inherits: ['viewer'],
})
if (createdEditor.error) throw createdEditor.error
const createdAdmin = await permissions.rbac.admin.createRole({
  role: 'admin',
  permissions: ['documents.delete', 'users.manage'],
  inherits: ['editor'],
})
if (createdAdmin.error) throw createdAdmin.error
```

```sql tab="SQL"
select permissions.rbac_create_role(
  role => 'viewer',
  permissions => '{documents.read}'
);
select permissions.rbac_create_role(
  role => 'editor',
  permissions => '{documents.edit}',
  inherits => '{viewer}'
);
select permissions.rbac_create_role(
  role => 'admin',
  permissions => '{documents.delete,users.manage}',
  inherits => '{editor}'
);
```

A permission name is a free-form string, for example `documents.read`. A role works both app-wide and in any scope. Inheritance is transitive: `admin` has the permissions of `editor`, and the permissions that `editor` inherits from `viewer`.

Then assign the roles to users. These assignments are app-wide:

```js tab="JavaScript"
const assignedAlice = await permissions.rbac.admin.assignRole({
  userId: alice,
  role: 'admin',
})
if (assignedAlice.error) throw assignedAlice.error
const assignedBob = await permissions.rbac.admin.assignRole({
  userId: bob,
  role: 'editor',
})
if (assignedBob.error) throw assignedBob.error
const assignedCarol = await permissions.rbac.admin.assignRole({
  userId: carol,
  role: 'viewer',
})
if (assignedCarol.error) throw assignedCarol.error
```

```sql tab="SQL"
select permissions.rbac_assign_role(
  user_id => :'alice',
  role => 'admin'
);
select permissions.rbac_assign_role(
  user_id => :'bob',
  role => 'editor'
);
select permissions.rbac_assign_role(
  user_id => :'carol',
  role => 'viewer'
);
```

Ask what a user can do. The result lists each permission that the user holds, directly or through inheritance. The order is not defined:

```js tab="JavaScript"
const forAlice = await permissions.rbac.admin.userPermissions({
  userId: alice,
})
// forAlice.data, in any order:
// ['documents.delete', 'documents.edit',
//  'documents.read', 'users.manage']
const forDave = await permissions.rbac.admin.userPermissions({
  userId: dave,
})
// forDave.data: []: Dave has no role
```

```sql tab="SQL"
select permissions.rbac_user_permissions(user_id => :'alice');
-- {documents.delete,documents.edit,documents.read,users.manage}
select permissions.rbac_user_permissions(user_id => :'dave');
-- {}: Dave has no role
```

## Warnings and limits

- **Do not pass the second argument of `rbac_scopes_with_permission`.** The signature is `(permission text, plan_time_guard boolean)`. The extra argument makes Postgres call the function once for each query. If you pass a constant, each query calls the function twice. Call the function with the permission name only. A `grant` or `drop function` statement needs the full signature.
- **A mistake in a permission name denies access without an error.** Unknown names give false in RBAC. Keep the permission names in one place in your code. The OpenFGA functions work the other way: an unknown type or relation raises an error. See [Errors and limits](../../reference/errors.md).
- **Superusers and table owners skip RLS.** Test policies as the role that your clients use, for example `set role authenticated`, and not as `postgres`.
- **Set the subject for each transaction.** Use `set_config(..., true)`. Never use a session-level value behind a pooler.
- **Scoped and app-wide roles are separate.** A check for one scope does not include app-wide roles. See [Rules](tenants.md#rules).

## Next step

Continue with [App-wide roles](app-wide.md).
