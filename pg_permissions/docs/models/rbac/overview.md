# Roles and permissions (RBAC)

Use RBAC when access follows a role, such as viewer, editor, or administrator. Assign roles across the application or within a scope such as an organization. Roles can inherit permissions from other roles.

This walkthrough starts in a fresh database with the extension installed. Create the roles here, then continue with [app-wide roles](app-wide.md) and [tenant-scoped roles](tenants.md). Read [identity](../../integrations/identity.md) and [privileges](../../integrations/privileges.md) before integrating the examples into a request handler.

## Use from JavaScript

An example that has a JavaScript equivalent shows it next to the SQL. The JavaScript examples use [the JavaScript client](../../integrations/javascript.md). Install the client first.

The admin calls use the server client:

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)
```

The other JavaScript examples on this page use `permissions`. They also use the ID constants in [Before you start](#before-you-start). Three things differ from SQL:

- Each method returns `{ data, error }`. It does not throw for a database error.
- The argument `user_id` is `userId`.
- A check for a user runs through `as({ id })`. It sets the subject for each call.

## Before you start

[Install the extension](../../install.md) first. The examples use psql variables for IDs. For example, `:'alice'` is the ID of Alice:

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

```ts tab="JavaScript"
const alice = '11111111-1111-1111-1111-111111111111'
const bob = '22222222-2222-2222-2222-222222222222'
const carol = '33333333-3333-3333-3333-333333333333'
const dave = '44444444-4444-4444-4444-444444444444'
const erin = '55555555-5555-5555-5555-555555555555'
const frank = '66666666-6666-6666-6666-666666666666'
const acme = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
const globex = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
```

In your application, these are arguments. The extension accepts any text as an ID. The examples use UUIDs because the example tables have `uuid` keys.

Statements that change roles run as the extension owner. This page calls that role the admin. Examples that start with `set local role authenticated` show what a client sees.

The examples use the Supabase role names `anon`, `authenticated` and `service_role`. Supabase has these roles. Plain Postgres does not have them, so create them to run the examples. The extension does not need them.

```sql
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
```

## Create roles

Define each role once, as the admin. A role has a name, a list of permissions, and a list of roles that it inherits. Here `editor` inherits `viewer`, and `admin` inherits `editor`:

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

```ts tab="JavaScript"
await permissions.rbac.admin.createRole({
  role: 'viewer',
  permissions: ['documents.read'],
})
await permissions.rbac.admin.createRole({
  role: 'editor',
  permissions: ['documents.edit'],
  inherits: ['viewer'],
})
await permissions.rbac.admin.createRole({
  role: 'admin',
  permissions: ['documents.delete', 'users.manage'],
  inherits: ['editor'],
})
```

A permission name is a free-form string, for example `documents.read`. A role works both app-wide and in any scope. Inheritance is transitive: `admin` has the permissions of `editor`, and the permissions that `editor` inherits from `viewer`.

Then assign the roles to users. These assignments are app-wide:

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

```ts tab="JavaScript"
await permissions.rbac.admin.assignRole({
  userId: alice,
  role: 'admin',
})
await permissions.rbac.admin.assignRole({
  userId: bob,
  role: 'editor',
})
await permissions.rbac.admin.assignRole({
  userId: carol,
  role: 'viewer',
})
```

Ask what a user can do. The result lists each permission that the user holds, directly or through inheritance. The order is not defined:

```sql tab="SQL"
select permissions.rbac_user_permissions(user_id => :'alice');
-- {documents.delete,documents.edit,documents.read,users.manage}
select permissions.rbac_user_permissions(user_id => :'dave');
-- {}: Dave has no role
```

```ts tab="JavaScript"
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

## Warnings and limits

- **Do not pass the second argument of `rbac_scopes_with_permission`.** The signature is `(permission text, plan_time_guard boolean)`. The extra argument makes Postgres call the function once for each query. If you pass a constant, each query calls the function twice. Call the function with the permission name only. A `grant` or `drop function` statement needs the full signature.
- **A mistake in a permission name denies access without an error.** Unknown names give false in RBAC. Keep the permission names in one place in your code. The OpenFGA functions work the other way: an unknown type or relation raises an error. See [Errors and limits](../../reference/errors.md).
- **Superusers and table owners skip RLS.** Test policies as the role that your clients use, for example `set role authenticated`, and not as `postgres`.
- **Set the subject for each transaction.** Use `set_config(..., true)`. Never use a session-level value behind a pooler.
- **Scoped and app-wide roles are separate.** A policy for a tenant table does not see app-wide roles. See [Rules](tenants.md#rules).

## Next step

Continue with [App-wide roles](app-wide.md).
