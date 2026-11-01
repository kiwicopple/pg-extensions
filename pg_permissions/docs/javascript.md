# JavaScript client

This page describes `permissions`, the JavaScript client for `pg_permissions`. The client calls the functions of the extension from Node, from a browser, from Deno and from Bun. Each function of the client calls one SQL function.

The client needs `pg_permissions` 0.0.1 in the database. See [Install](install.md). The README of the npm package has more examples.

```bash
npm install permissions
```

## Entry points

The package has two entry points. Choose the entry point from the place where the code runs.

| Entry point | Where it runs | How it connects | What it can call |
| --- | --- | --- | --- |
| `createServerClient(db)` | A server | SQL, as the role of the connection | Every function. It has the `admin` namespaces. |
| `createClient(url, key, options)` | A browser or an edge function | PostgREST or Supabase, as the signed-in user | The client functions only. It has no `admin`. |

`db` is a `pg` pool, or any object with `query(text, values)`. The role of the connection must have `execute` on the admin functions. See [Privileges](reference.md#privileges).

Admin calls never go over HTTP. A browser does not need a service key. Do not send a service key to a browser.

## Quick start

On a server, create the client from a pool:

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const permissions = createServerClient(new pg.Pool({ connectionString: process.env.DATABASE_URL }))

await permissions.rbac.admin.createRole({ role: 'editor', permissions: ['documents.edit'] })
await permissions.rbac.admin.assignRole({ userId: 'alice', role: 'editor', scope: 'acme' })
```

In a browser, create the client with the URL and the anon key of the Supabase project:

```ts
import { createClient } from 'permissions'

const permissions = createClient('https://your-project.supabase.co', 'your-anon-key', {
  accessToken: async () => 'the-jwt-of-the-signed-in-user',
})

const { data: canEdit } = await permissions.rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' })
```

Before you use `createClient`, add `permissions` to **Exposed schemas** in the Supabase API settings. For plain PostgREST, add `permissions` to `db-schemas`, and pass the option `restUrl`.

## Methods

Each method returns a `Promise` of `{ data, error }`. The tables show the type of `data`.

### Client methods

These methods answer for the current subject. They exist on both entry points. On a server, `as({ id })` sets the subject.

| Method | SQL function | `data` |
| --- | --- | --- |
| `rbac.hasPermission({ permission, scope? })` | `rbac_has_permission` | `boolean` |
| `rbac.hasRole({ role, scope? })` | `rbac_has_role` | `boolean` |
| `rbac.scopesWithPermission({ permission })` | `rbac_scopes_with_permission` | `string[]` |
| `fga.check({ relation, object })` | `fga_check_current` | `boolean` |
| `fga.listObjects({ type, relation })` | `fga_list_objects_current` | `string[]`, as `type:id` |
| `fga.listObjects({ type, relation, idsOnly: true })` | `fga_list_object_ids_current` | `string[]`, as `id` |

### Subject methods

`permissions.as(subject)` returns a client that has `rbac` and `fga` with the client methods only. It has no `admin`.

| Call | What it does |
| --- | --- |
| `as({ id, type?, role? })` | Runs each call in a transaction. The transaction sets `permissions.subject_id` to `id`. With `role`, it also runs `set local role`. |

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const permissions = createServerClient(new pg.Pool({ connectionString: process.env.DATABASE_URL }))

const alice = permissions.as({ id: 'alice', role: 'authenticated' })
const { data: canView } = await alice.fga.check({ relation: 'viewer', object: 'document:1' })
```

### Admin methods

These methods exist only on `createServerClient`, and on a standalone client with an SQL transport. They take an explicit subject.

| Method | SQL function | `data` |
| --- | --- | --- |
| `rbac.admin.createRole({ role, permissions, inherits? })` | `rbac_create_role` | `null` |
| `rbac.admin.dropRole({ role })` | `rbac_drop_role` | `null` |
| `rbac.admin.assignRole({ userId, role, scope? })` | `rbac_assign_role` | `null` |
| `rbac.admin.unassignRole({ userId, role, scope? })` | `rbac_unassign_role` | `null` |
| `rbac.admin.userPermissions({ userId, scope? })` | `rbac_user_permissions` | `string[]` |
| `rbac.admin.usersWithRole({ role, scope? })` | `rbac_users_with_role` | `string[]` |
| `fga.admin.writeAuthorizationModel(model)` | `fga_write_authorization_model` | `{ authorizationModelId }` |
| `fga.admin.readAuthorizationModel({ authorizationModelId? })` | `fga_read_authorization_model` | The model, with its `id` |
| `fga.admin.readAuthorizationModels()` | `fga_read_authorization_models` | `{ id, createdAt }[]` |
| `fga.admin.write({ writes?, deletes?, onDuplicate?, onMissing?, authorizationModelId? })` | `fga_write` | `null` |
| `fga.admin.writeTuple({ user, relation, object })` | `fga_write_tuple` | `null` |
| `fga.admin.deleteTuple({ user, relation, object })` | `fga_delete_tuple` | `null` |
| `fga.admin.read({ object?, relation?, user?, pageSize?, continuationToken? })` | `fga_read` | `{ tuples, continuationToken }` |
| `fga.admin.check({ user, relation, object, ... })` | `fga_check` | `boolean` |
| `fga.admin.listObjects({ user, type, relation, ... })` | `fga_list_objects` | `string[]` |
| `fga.admin.listUsers({ object, relation, userFilters, ... })` | `fga_list_users` | `string[]` |
| `fga.admin.deleteStore()` | `fga_delete_store` | `null` |
| `admin.deleteSubject({ type, id })` | `delete_subject` | `number` |

In `check`, `listObjects` and `listUsers`, `...` stands for the options `contextualTuples`, `context` and `authorizationModelId`.

`fga.admin.deleteStore()` works only for the role that owns the extension. Do not grant `fga_delete_store` to `service_role`.

### Names of arguments

The FGA methods use the names of the OpenFGA SDK, in camel case. The client maps them to the SQL names.

| JavaScript | SQL |
| --- | --- |
| `user` | `subject` |
| `authorizationModelId` | `model_id` |
| `contextualTuples` | `contextual_tuples` |
| `continuationToken` | `continuation_token` |
| `pageSize` | `page_size` |
| `userFilters` | `user_filters` |
| `userId` | `user_id` |
| `onDuplicate`, `onMissing` | `on_duplicate` and `on_missing` in the `writes` and `deletes` arguments |

A scope of `null` or `undefined` means app-wide.

## Errors

A method does not throw for a database error. It returns the error in `error`. To throw the error, pass `throwOnError: true` in the options.

`PermissionsError` extends `Error`. It has the fields `message`, `details`, `hint` and `code`, as the `PostgrestError` of supabase-js has. It also has `reason`, which is the `DETAIL` code, parsed.

| Cause | Error class | `reason` |
| --- | --- | --- |
| An RBAC error of the extension, such as `rbac:unknown_role role='admn'` | `PermissionsError` | `{ model: 'rbac', code: 'unknown_role', context: { role: 'admn' } }` |
| An OpenFGA error of the extension, such as `openfga:2001 authorization_model_not_found` | `PermissionsError` | `{ model: 'openfga', code: 2001, name: 'authorization_model_not_found' }` |
| An error from Postgres, such as `42501` or `57014` | `PermissionsError` | `null` |
| The request did not reach the server, or the database connection failed | `PermissionsFetchError` | `null` |
| An error status from PostgREST, with no PostgREST error body | `PermissionsHttpError`, with `status` and `body` | `null` |
| A wrong function name or argument name | A plain `Error`. The client always throws it. | Not applicable |

[Errors and limits](errors-and-limits.md) lists each `DETAIL` code.

Use the type guards `isPermissionsError`, `isRbacError` and `isFgaError` to test an error. `isRbacError` takes an optional code. `isFgaError` takes an optional number or name.

```ts
import { createClient, isFgaError, isRbacError } from 'permissions'

const permissions = createClient('https://your-project.supabase.co', 'your-anon-key')

const { error } = await permissions.fga.check({ relation: 'viewr', object: 'document:1' })

if (isFgaError(error, 2000)) {
  console.log(error.hint) // Did you mean 'viewer'? ...
} else if (isRbacError(error, 'unknown_role')) {
  console.log(error.reason.context.role)
}
```

## Other imports

The subpaths `permissions/rbac`, `permissions/fga`, `permissions/sql` and `permissions/postgrest` each export one part of the package. A standalone client takes a PostgREST URL, or a transport:

```ts
import pg from 'pg'
import { RbacClient } from 'permissions/rbac'
import { sqlTransport } from 'permissions/sql'

const rbac = new RbacClient({ transport: sqlTransport(new pg.Pool({ connectionString: process.env.DATABASE_URL })) })
await rbac.admin.assignRole({ userId: 'alice', role: 'editor', scope: 'acme' })
```

To catch a wrong name at build time, pass a type argument, for example `createServerClient<{ roles: 'viewer' | 'editor' }>(pool)`.

## Compatibility

| `permissions` | `pg_permissions` | Runtime |
| --- | --- | --- |
| 0.2.x | 0.0.1 | Node 20 or later. Browsers, Deno and Bun that have `fetch`. |
