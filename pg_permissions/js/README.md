# permissions

`permissions` is the JavaScript client for [`pg_permissions`](https://permissions.dev), an authorization extension for Postgres. The extension has three permission models: roles (RBAC), relationships (OpenFGA) and policies (Cedar). The client calls the functions of each model.

The client has no runtime dependency. It works in Node, in browsers, in Deno and in Bun.

## Install

```bash
npm install permissions
```

`permissions` 0.3.0 adds Cedar and needs `pg_permissions` 0.1.0 for Cedar. RBAC and OpenFGA work with `pg_permissions` 0.0.1 or 0.1.0. See [Install](../docs/install.md) for the database steps.

## Choose an entry point

The package has two entry points. Each entry point has a different trust level.

| Entry point | Where it runs | How it connects | Functions |
| --- | --- | --- | --- |
| `createServerClient(db)` | A server | SQL, as the role of the connection | All functions, with the `admin` namespaces |
| `createClient(url, key, options)` | A browser or an edge function | PostgREST or Supabase, as the signed-in user | The checks for the current user only. No `admin`. |

Admin calls never go over HTTP. A browser never needs a service key.

The browser client has nine methods. They call ten functions of the extension that Postgres grants to every role.

| Method | Result |
| --- | --- |
| `rbac.hasPermission({ permission, scope })` | `boolean` |
| `rbac.hasRole({ role, scope })` | `boolean` |
| `rbac.scopesWithPermission({ permission })` | `string[]` |
| `fga.check({ relation, object })` | `boolean` |
| `fga.listObjects({ type, relation, idsOnly })` | `string[]` |
| `cedar.isAuthorized({ action, resource, resourceAttrs })` | `boolean` |
| `cedar.listResources({ action, resourceType })` | `string[]` |
| `currentSubjectId()` | `string`, or `null` when there is no subject |
| `currentSubjectType()` | `string`. The default is `'user'`. |

## Quick start: Node with pg

Use `createServerClient` on a server. Pass it a `pg` pool, or any object with `query(text, values)`.

The role of the connection must have `execute` on the admin functions. See the privileges section of [RBAC](https://permissions.dev/rbac/#privileges).

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)

// Create the roles once, for example in a migration.
await permissions.rbac.admin.createRole({
  role: 'viewer',
  permissions: ['documents.read'],
})
await permissions.rbac.admin.createRole({
  role: 'editor',
  permissions: ['documents.edit'],
  inherits: ['viewer'],
})

// Give alice the editor role in the scope 'acme'.
await permissions.rbac.admin.assignRole({
  userId: 'alice',
  role: 'editor',
  scope: 'acme',
})

// List what alice can do in 'acme'.
const { data, error } = await permissions.rbac.admin.userPermissions({
  userId: 'alice',
  scope: 'acme',
})
if (error) throw error
console.log(data) // ['documents.edit', 'documents.read']
```

The `fga` namespace works in the same way. This example writes a model and a tuple, and then checks access.

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)

// The model: a document has a viewer relation, and a user can be
// a viewer.
const model = {
  schema_version: '1.1',
  type_definitions: [
    { type: 'user' },
    {
      type: 'document',
      relations: { viewer: { this: {} } },
      metadata: {
        relations: {
          viewer: {
            directly_related_user_types: [{ type: 'user' }],
          },
        },
      },
    },
  ],
}
await permissions.fga.admin.writeAuthorizationModel(model)

// Anne can view document 1.
await permissions.fga.admin.writeTuple({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:1',
})

// Check access.
const { data: allowed } = await permissions.fga.admin.check({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:1',
})
console.log(allowed) // true
```

The server client also has `permissions.admin.deleteSubject({ type, id })`. Call it when you delete a user account. It deletes the assignments and the tuples of the subject, and it returns the number of rows that it deleted.

## Quick start: Supabase

Use `createClient` in a browser or in an edge function. It has the same arguments as the `createClient` of supabase-js.

1. In the Supabase dashboard, go to Project Settings, then API (Data API). Add `permissions` to **Exposed schemas**.
2. Create the roles, the assignments and the tuples on a server, with `createServerClient` or with SQL.
3. Create the client in the app. Pass the access token of the session.

```ts
import {
  createClient as createSupabaseClient,
} from '@supabase/supabase-js'
import { createClient } from 'permissions'

const SUPABASE_URL = 'https://your-project.supabase.co'
const SUPABASE_ANON_KEY = 'your-anon-key'

// The Supabase client holds the session of the signed-in user.
const supabase = createSupabaseClient(SUPABASE_URL, SUPABASE_ANON_KEY)

// The access token of the session, or null when there is no session.
async function getAccessToken(): Promise<string | null> {
  const { data } = await supabase.auth.getSession()
  return data.session?.access_token ?? null
}

// The same arguments as supabase-js.
const permissions = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  accessToken: getAccessToken,
})

// Check as the signed-in user.
const { data: canEdit } = await permissions.rbac.hasPermission({
  permission: 'documents.edit',
  scope: 'acme',
})
const { data: canView } = await permissions.fga.check({
  relation: 'viewer',
  object: 'document:1',
})
const { data: ids } = await permissions.fga.listObjects({
  type: 'document',
  relation: 'viewer',
  idsOnly: true,
})
```

Each request has the headers `apikey` and `Authorization: Bearer <token>`. When `accessToken` returns `null`, the client sends the anon key. Then no subject exists, and each check is `false`.

Do not send a service key to a browser. The browser client does not need one, because it cannot call admin functions.

## Quick start: plain PostgREST

Pass the PostgREST URL as `restUrl`. The client then sends requests to `<restUrl>/rpc/<function>`. It does not add `/rest/v1`.

```ts
import { createClient } from 'permissions'

const POSTGREST_URL = 'http://localhost:3000'
const USER_JWT = 'eyJ...'

const permissions = createClient(POSTGREST_URL, USER_JWT, {
  restUrl: POSTGREST_URL,
  accessToken: () => USER_JWT,
})

const { data } = await permissions.rbac.hasPermission({
  permission: 'documents.read',
})
```

PostgREST must list the schema `permissions` in `db-schemas`. To use another schema name, pass `db: { schema: 'my_schema' }`.

## Cedar policies

The `cedar` client calls the Cedar model of the extension. A server puts the policies and the entities with `cedar.admin`. A browser checks the current user with `cedar.isAuthorized` and `cedar.listResources`.

A uid is Cedar text, `'Document::"q3"'`, or an object, `{ type: 'Document', id: 'q3' }`. The client turns an object into Cedar text and escapes `"` and `\` in the id. To build the text yourself, use `uid(type, id)`. Do not join strings: an id with a `"` gives the error `cedar:invalid_uid`.

### Put policies and entities

The role of the connection must have `execute` on the Cedar admin functions.

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)

const policy = `permit (
  principal in Team::"eng",
  action == Action::"view",
  resource in Folder::"reports"
);`
await permissions.cedar.admin.putPolicy({
  policyId: 'eng-reports',
  policy,
})

const entities = [
  {
    uid: { type: 'user', id: 'alice' },
    parents: [{ type: 'Team', id: 'eng' }],
  },
  {
    uid: { type: 'Document', id: 'q3' },
    parents: [{ type: 'Folder', id: 'reports' }],
  },
]
await permissions.cedar.admin.putEntities(entities)
```

`putPolicy` also takes `policyJson`, a policy in the JSON format of Cedar. `policyId` names the policy. An `@id` annotation does not.

The admin methods are the SQL functions in camelCase:

| Method | SQL function | Result |
| --- | --- | --- |
| `putPolicy({ policyId, policy, policyJson })` | `cedar_put_policy` | `null` |
| `deletePolicy({ policyId })` | `cedar_delete_policy` | `null` |
| `policies()` | `cedar_policies` | `PolicyInfo[]` |
| `putTemplate({ templateId, template, templateJson })` | `cedar_put_template` | `null` |
| `linkTemplate({ policyId, templateId, principal, resource })` | `cedar_link_template` | `null` |
| `deleteTemplate({ templateId })` | `cedar_delete_template` | `null` |
| `templates()` | `cedar_templates` | `TemplateInfo[]` |
| `putEntities(entities)` | `cedar_put_entities` | `null` |
| `deleteEntities(uids)` | `cedar_delete_entities` | `number`, the entities deleted |
| `readEntities({ type, ids })` | `cedar_read_entities` | Entity JSON |
| `isAuthorized({ principal, action, resource, context, entities })` | `cedar_is_authorized` | `AuthorizationResponse` |

### Check a request for any principal

`admin.isAuthorized` answers a full Cedar request. The response has the shape of the `response` of `isAuthorized` in `@cedar-policy/cedar-wasm`, Cedar's own JavaScript API.

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)

const request = {
  principal: { type: 'user', id: 'alice' },
  action: 'Action::"view"',
  resource: 'Document::"q3"',
  context: { mfa: true },
}
const { data } = await permissions.cedar.admin.isAuthorized(request)
// {
//   decision: 'allow',
//   diagnostics: { reason: ['eng-reports'], errors: [] },
// }
```

| Field | Content |
| --- | --- |
| `decision` | `'allow'` or `'deny'` |
| `diagnostics.reason` | The ids of the policies that decided. For a deny, the forbids that hold. Empty for the default deny. |
| `diagnostics.errors` | `{ policyId, error: { message } }` for each policy that failed to evaluate. That policy was skipped. |

The SQL function returns `reasons` and `errors[].policy_id`. The client renames them to match Cedar.

### Check the current user

`isAuthorized` and `listResources` answer for the current subject. The principal is `current_subject_type()::"current_subject_id()"`, for example `user::"alice"`. Write the policies with that type.

```ts
import { createClient } from 'permissions'

const SUPABASE_URL = 'https://your-project.supabase.co'
const SUPABASE_ANON_KEY = 'your-anon-key'

const permissions = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)

const { data: canView } = await permissions.cedar.isAuthorized({
  action: 'Action::"view"',
  resource: { type: 'Document', id: 'q3' },
})

// ['q3', ...]: ids, without the type
const { data: ids } = await permissions.cedar.listResources({
  action: 'Action::"view"',
  resourceType: 'Document',
})
```

These methods fail closed:

- Without a subject, the answer is `false` or `[]`.
- When a forbid that applies fails to evaluate, the answer is `false`. `admin.isAuthorized` can allow the same request and report the error.

`resourceAttrs` replaces the attributes of the resource for one check. Use it for a row that is not a stored entity. `listResources` returns stored entities only.

The same methods exist on the clients of `as()`, which give the same answers as the browser client. The browser client and the clients of `as()` have no `admin`.

## Check as one subject

On a server, `as()` runs the checks for one subject. It gives the same answers as the browser client gives for that user.

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)

// Run the checks as alice, with the privileges of a signed-in user.
const alice = permissions.as({ id: 'alice', role: 'authenticated' })

const { data: canEdit } = await alice.rbac.hasPermission({
  permission: 'documents.edit',
  scope: 'acme',
})
const { data: canView } = await alice.fga.check({
  relation: 'viewer',
  object: 'document:1',
})
```

Each call runs in its own transaction. The transaction sets `permissions.subject_id` to the id. When you set `role`, it also runs `set local role`.

The subject is `{ id, type?, role? }`. The default `type` is `'user'`. The clients that `as()` returns have no `admin` namespace.

## Get the current subject

`currentSubjectId()` returns the id of the current subject. It calls `permissions.current_subject_id()`. The data is `null` when there is no subject, for example with the anon key.

`currentSubjectType()` returns the type of the current subject. It calls `permissions.current_subject_type()`. The default is `'user'`.

The methods exist on `createClient`, on `createServerClient` and on the client that `as()` returns.

```ts
import { createClient } from 'permissions'

const SUPABASE_URL = 'https://your-project.supabase.co'
const SUPABASE_ANON_KEY = 'your-anon-key'

async function getAccessToken(): Promise<string> {
  return 'the-jwt-of-the-signed-in-user'
}

const permissions = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  accessToken: getAccessToken,
})

// The id of the subject: 'alice', or null.
const { data: id } = await permissions.currentSubjectId()

// The type of the subject: 'user'.
const { data: type } = await permissions.currentSubjectType()
```

On a server, the connection has no subject, so `currentSubjectId()` returns `null`. Use `as()` to set the subject.

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)

const team = permissions.as({ id: 'eng', type: 'team' })

const { data: id } = await team.currentSubjectId() // 'eng'
const { data: type } = await team.currentSubjectType() // 'team'
```

## Results and errors

Each method returns `{ data, error }`. Exactly one of the two is `null`.

```ts
import { createClient } from 'permissions'

const SUPABASE_URL = 'https://your-project.supabase.co'
const SUPABASE_ANON_KEY = 'your-anon-key'

const permissions = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)

const { data, error } = await permissions.rbac.hasRole({
  role: 'editor',
})
if (error) {
  console.error(error.message)
} else {
  console.log(data) // boolean
}
```

To throw the error instead, set `throwOnError: true`. You can set it in `createClient`, in `createServerClient` and in the constructors of the standalone clients.

```ts
import { createClient } from 'permissions'

const SUPABASE_URL = 'https://your-project.supabase.co'
const SUPABASE_ANON_KEY = 'your-anon-key'

const permissions = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  throwOnError: true,
})

const result = await permissions.rbac.hasPermission({
  permission: 'documents.edit',
})
const canEdit = result.data
```

A mistake in your code always throws. For example, an unknown function name or an unknown argument name throws a plain `Error`.

### The error object

`PermissionsError` extends `Error`. It has the fields of the `PostgrestError` of supabase-js, and one more field.

| Field | Content |
| --- | --- |
| `message` | What went wrong. |
| `details` | The `DETAIL` text of the error, for example `rbac:unknown_role role='admn'`. |
| `hint` | How to fix the error. |
| `code` | The SQLSTATE, for example `22023`. It is an empty string when the error does not come from Postgres. |
| `reason` | The `DETAIL` text, parsed. It is `null` for an error from Postgres, such as `42501`. |

`reason` has one of three forms:

- `{ model: 'rbac', code: 'unknown_role', context: { role: 'admn' } }`
- `{ model: 'openfga', code: 2001, name: 'authorization_model_not_found' }`
- `{ model: 'cedar', code: 'unknown_policy', context: { policy_id: 'x' } }`

Two subclasses cover failures that have no error body. `PermissionsFetchError` means that the request did not reach the server. `PermissionsHttpError` means that the response has an error status and no PostgREST error body. It has `status` and `body`.

Use the type guards to test an error:

```ts
import pg from 'pg'
import {
  createServerClient,
  isFgaError,
  isPermissionsError,
  isRbacError,
} from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)

const { error } = await permissions.rbac.admin.createRole({
  role: 'editor',
  permissions: ['documents.edit'],
})

if (isRbacError(error, 'role_exists')) {
  console.log('The role exists:', error.reason.context.role)
} else if (isFgaError(error, 'authorization_model_not_found')) {
  console.log('Write a model first:', error.reason.code) // 2001
} else if (isPermissionsError(error)) {
  console.log(error.code, error.message, error.hint)
}
```

`isFgaError` accepts the error number or the error name. `isCedarError(error, code)` tests a `cedar:` code, as `isRbacError` tests an `rbac:` code. [Errors and limits](https://permissions.dev/errors-and-limits/) lists every code.

## Import one part of the package

The package has subpaths. Each subpath works alone.

| Import | Content |
| --- | --- |
| `permissions` | `createClient`, `createServerClient`, and the exports of each subpath below |
| `permissions/rbac` | `RbacClient` |
| `permissions/fga` | `FgaClient` |
| `permissions/cedar` | `CedarClient` and `uid` |
| `permissions/sql` | `sqlTransport` |
| `permissions/postgrest` | `postgrestTransport` |

The constructors of `RbacClient`, `FgaClient` and `CedarClient` take a PostgREST URL, or a transport. Only a client on an SQL transport has `admin`.

```ts
import pg from 'pg'
import { FgaClient } from 'permissions/fga'
import { RbacClient } from 'permissions/rbac'
import { sqlTransport } from 'permissions/sql'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})

// Browser: PostgREST, with the JWT of the user.
const REST_URL = 'https://your-project.supabase.co/rest/v1'
const headers = {
  apikey: 'your-anon-key',
  Authorization: 'Bearer your-user-jwt',
}
const rbac = new RbacClient(REST_URL, { headers })

await rbac.hasPermission({
  permission: 'documents.edit',
  scope: 'acme',
})

// Server: SQL, with admin.
const transport = sqlTransport(pool)
const fga = new FgaClient({ transport })

await fga.admin.writeTuple({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:1',
})

// Server, as one subject: the checks only.
const anneTransport = transport.withSubject({ id: 'anne' })
const anne = new FgaClient({ transport: anneTransport })

await anne.check({ relation: 'viewer', object: 'document:1' })
```

## Narrow the names

Pass a type argument to catch a wrong name at build time. Each key is optional.

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

type Names = {
  permissions: 'documents.read' | 'documents.edit'
  roles: 'viewer' | 'editor'
}

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient<Names>(pool)

// ok: 'editor' is in Names
await permissions.rbac.admin.assignRole({
  userId: 'alice',
  role: 'editor',
})

await permissions.rbac.admin.assignRole({
  userId: 'alice',
  // @ts-expect-error 'owner' is not in Names
  role: 'owner',
})
```

`createClient<Names>()` and `new RbacClient<Names>()` take the same type argument.

## Use from a CDN

The package has a UMD bundle for a `<script>` tag. It sets the global `permissions`.

```html
<script
  src="https://cdn.jsdelivr.net/npm/permissions@0.3/dist/umd/permissions.js"
></script>
<script>
  const url = 'https://your-project.supabase.co'
  const anonKey = 'your-anon-key'
  const client = permissions.createClient(url, anonKey)

  const check = client.rbac.hasPermission({
    permission: 'documents.read',
  })
  check.then(({ data, error }) => {
    console.log(data, error)
  })
</script>
```

## Compatibility

| `permissions` | `pg_permissions` | Models |
| --- | --- | --- |
| 0.3.x | 0.1.0 (Cedar); 0.0.1 or 0.1.0 (RBAC, OpenFGA) | RBAC, OpenFGA and Cedar |
| 0.2.x | 0.0.1 or 0.1.0 | RBAC and OpenFGA |

The runtime is Node 20 or later, or a browser, Deno or Bun that has `fetch`.

The package ships ESM and CommonJS, with types for both.

## Links

- Documentation: https://permissions.dev
- The JavaScript client page: https://permissions.dev/javascript/
- Source and issues: https://github.com/kiwicopple/pg-extensions/tree/main/pg_permissions/js

## License

MIT
