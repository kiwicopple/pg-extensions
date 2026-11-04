# JavaScript client reference

The client maps methods to SQL functions. Client methods answer for the current subject; admin methods accept explicit subjects or change permission data.

Create a client using [JavaScript setup](../integrations/javascript.md). The [RBAC](../models/rbac/overview.md), [OpenFGA](../models/openfga/overview.md) and [Cedar](../models/cedar/overview.md) guides show each operation alongside SQL.

## Results and errors

Methods return a `Promise` containing `{ data, error }`. On success, `error` is `null`. A write that returns no data also sets `data` to `null`. By default, a database error sets `data` to `null` and fills `error`.

To throw the error, pass `throwOnError: true` in the options of `createClient` or `createServerClient`:

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool, {
  throwOnError: true,
})
```

`PermissionsError` extends `Error`. It has the fields `message`, `details`, `hint` and `code`, as the `PostgrestError` of supabase-js has. It also has `reason`, which is the `DETAIL` code, parsed.

| Cause | Error class | `reason` |
| --- | --- | --- |
| An RBAC error of the extension, such as `rbac:unknown_role role='admn'` | `PermissionsError` | `{ model: 'rbac', code: 'unknown_role', context: { role: 'admn' } }` |
| An OpenFGA error of the extension, such as `openfga:2001 authorization_model_not_found` | `PermissionsError` | `{ model: 'openfga', code: 2001, name: 'authorization_model_not_found' }` |
| A Cedar error of the extension, such as `cedar:unknown_policy policy_id='x'` | `PermissionsError` | `{ model: 'cedar', code: 'unknown_policy', context: { policy_id: 'x' } }` |
| An error from Postgres, such as `42501` or `57014` | `PermissionsError` | `null` |
| The request did not reach the server, or the database connection failed | `PermissionsFetchError` | `null` |
| An error status from PostgREST, with no PostgREST error body | `PermissionsHttpError`, with `status` and `body` | `null` |
| A wrong function name or argument name | A plain `Error`. The client always throws it. | Not applicable |

[Errors and limits](errors.md) lists each `DETAIL` code.

Use the type guards `isPermissionsError`, `isRbacError`, `isFgaError` and `isCedarError` to test an error. `isRbacError` and `isCedarError` take an optional code. `isFgaError` takes an optional number or name.

```ts
import { createClient, isFgaError, isRbacError } from 'permissions'

const SUPABASE_URL = 'https://your-project.supabase.co'
const SUPABASE_ANON_KEY = 'your-anon-key'

const permissions = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)

const { error } = await permissions.fga.check({
  relation: 'viewr',
  object: 'document:1',
})

if (isFgaError(error, 2000)) {
  console.log(error.hint) // Did you mean 'viewer'? ...
} else if (isRbacError(error, 'unknown_role')) {
  console.log(error.reason.context.role)
}
```

## Methods

The tables show the SQL function that each method calls, and the type of `data`. For examples of each call, see the [RBAC](rbac.md), [OpenFGA](openfga.md), [Cedar](cedar.md) and [shared API](shared.md) references.

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
| `cedar.isAuthorized({ action, resource, resourceAttrs? })` | `cedar_is_authorized_current` | `boolean` |
| `cedar.listResources({ action, resourceType })` | `cedar_list_resources_current` | `string[]`, as `id` |
| `currentSubjectId()` | `current_subject_id` | `string`, or `null` when there is no subject |
| `currentSubjectType()` | `current_subject_type` | `string`. The default is `'user'`. |

### Admin methods

These methods exist only on `createServerClient`, and on a standalone client with an SQL transport. They manage permission data or answer questions about a subject you specify.

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
| `cedar.admin.putPolicy({ policyId, policy?, policyJson? })` | `cedar_put_policy` | `null` |
| `cedar.admin.deletePolicy({ policyId })` | `cedar_delete_policy` | `null` |
| `cedar.admin.policies()` | `cedar_policies` | `PolicyInfo[]` |
| `cedar.admin.putTemplate({ templateId, template?, templateJson? })` | `cedar_put_template` | `null` |
| `cedar.admin.linkTemplate({ policyId, templateId, principal?, resource? })` | `cedar_link_template` | `null` |
| `cedar.admin.deleteTemplate({ templateId })` | `cedar_delete_template` | `null` |
| `cedar.admin.templates()` | `cedar_templates` | `TemplateInfo[]` |
| `cedar.admin.putEntities(entities)` | `cedar_put_entities` | `null` |
| `cedar.admin.deleteEntities(uids)` | `cedar_delete_entities` | `number`, the entities deleted |
| `cedar.admin.readEntities({ type?, ids? })` | `cedar_read_entities` | `CedarEntity[]` |
| `cedar.admin.isAuthorized({ principal, action, resource, context?, entities? })` | `cedar_is_authorized` | `{ decision, diagnostics: { reason, errors } }` |
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

A uid argument of a Cedar method is Cedar text, `'Document::"q3"'`, or an object, `{ type: 'Document', id: 'q3' }`. The client turns an object into Cedar text, and escapes `"` and `\` in the id. `uid(type, id)` builds the same text, and it is the JavaScript form of the SQL function [`cedar_uid`](cedar.md#cedar_uid). The Cedar methods have no `plan_time_guard` argument.

`cedar.admin.isAuthorized` returns the shape of the `response` of `@cedar-policy/cedar-wasm`. The SQL function returns `reasons` and `errors[].policy_id`. The client renames them to `diagnostics.reason` and `diagnostics.errors[].policyId`.

A scope of `null` or `undefined` means app-wide. The client does not change the keys inside `context`, in a tuple condition, or in a model.

## Other imports

The subpaths `permissions/rbac`, `permissions/fga`, `permissions/cedar`, `permissions/sql` and `permissions/postgrest` each export one part of the package. A standalone client takes a PostgREST URL, or a transport:

```ts
import pg from 'pg'
import { RbacClient } from 'permissions/rbac'
import { sqlTransport } from 'permissions/sql'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const transport = sqlTransport(pool)
const rbac = new RbacClient({ transport })
```

To catch a wrong name at build time, pass a type argument, for example `createServerClient<{ roles: 'viewer' | 'editor' }>(pool)`.
