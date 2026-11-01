# `permissions` JS library: plan

The status is implemented (phases 1-6). The code and its TSDoc are now the source of truth for the API. This file records the plan and the deviations from it.

## Deviations from the plan

- **Transport kind `'subject'`.** `as()` and `withSubject()` return a transport of kind `'subject'`, not `'sql'`. A client on it has no `admin`, at type level and at runtime, because the calls run as the end user.
- **Extra shape `'rows'`.** `Transport.rpc` has a fifth shape, `'rows'`, for `returns table` functions (`fga_read_authorization_models`).
- **8 PUBLIC functions, not 9.** `_unfolded_null` is internal. The 8 are `current_subject_id`, `current_subject_type`, 3 `rbac_*` and 3 `fga_*` current-subject functions. The clients wrap 6 of them.
- **`deleteStore` needs the owner.** `service_role` has no grant on `fga_delete_store`, as the docs say. Use the role that installed the extension.
- **Node.** Development uses Node 24 (`.nvmrc`). The runtime needs Node 20 or later (`engines`).
- **CDN bundle.** A UMD bundle is at `dist/umd/permissions.js`, with the global `permissions` (`unpkg` and `jsdelivr` fields).

## Goal

Publish the npm package `permissions`, owned by kiwicopple and currently at 0.1.1. It is a JS client for the pg_permissions extension. Its architecture and API conventions follow supabase-js. That means standalone sub-clients composed by an umbrella `createClient`, `{ data, error }` results, `PostgrestError`-shaped errors, and `.admin` namespaces for privileged calls.

## Decisions (2026-11-01)

1. **Location.** The library lives in this repo at `pg_permissions/js/`. It tests against `../pg_permissions--0.0.1.sql` directly.
2. **One published package with subpath exports.** We own only the unscoped `permissions` name, so the "collection of libraries" becomes subpaths, not scoped packages. Each subpath works alone, and the public API is the same as it would be with split packages. If we get an npm scope later, we can split them out.
   - `permissions`: the umbrella (`createClient`, `createServerClient`) and re-exports of everything.
   - `permissions/rbac`: `RbacClient`.
   - `permissions/fga`: `FgaClient`.
   - `permissions/postgrest`: PostgREST transport.
   - `permissions/sql`: SQL transport.
3. **Transports.**
   - **SQL is the server-side path and covers every function.** It takes any object with `query(text, values) => Promise<{ rows }>`, such as `pg` Pool or Client, `@neondatabase/serverless` or PGlite. There are no runtime dependencies.
   - **PostgREST is the client-side path.** It covers only the 9 PUBLIC current-subject functions. The `admin` namespaces do not exist on a PostgREST client, at type level or at runtime. Admin calls never go over HTTP, so nobody has to ship a service key to a browser.
4. **Test runner.** Vitest.
5. **Tooling.** pnpm, tsdown (ESM and CJS, with `.d.mts` and `.d.cts`), Vitest, `attw` and `publint`. We do not use Nx because there is one package. Docs come from TypeDoc. The first release is `0.2.0`, because 0.1.1 is already published.

## Public API

### Client side (browser or edge, through PostgREST and Supabase)

```ts
import { createClient } from 'permissions'

async function getAccessToken() {
  const { data } = await supabase.auth.getSession()
  return data.session?.access_token ?? null
}

const permissions = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  accessToken: getAccessToken,
  global: { fetch, headers }, // same shape as supabase-js
  db: { schema: 'permissions' },
  throwOnError: false,
})

// { data: boolean, error }
await permissions.rbac.hasPermission({
  permission: 'documents.edit',
  scope: 'acme',
})
await permissions.rbac.hasRole({ role: 'editor', scope: 'acme' })

// string[]
await permissions.rbac.scopesWithPermission({
  permission: 'documents.read',
})

// boolean
await permissions.fga.check({
  relation: 'viewer',
  object: 'document:1',
})

// string[] ('document:1')
await permissions.fga.listObjects({
  type: 'document',
  relation: 'viewer',
})

// string[] ('1')
await permissions.fga.listObjects({
  type: 'document',
  relation: 'viewer',
  idsOnly: true,
})
```

- The URL is the Supabase project URL. `/rest/v1` is appended, as supabase-js does. To use plain PostgREST, pass `{ restUrl }` or use `new RbacClient(restUrl, …)`.
- The request is `POST {rest}/rpc/{fn}` with the headers `Content-Profile: <schema>`, `apikey` and `Authorization: Bearer <accessToken() ?? key>`. The auth headers are added by one `fetchWithAuth` wrapper.
- **Setup requirement:** the `permissions` schema must be in PostgREST `db-schemas`. In Supabase this is the "Exposed schemas" setting.

### Server side (direct SQL)

```ts
import { createServerClient } from 'permissions'

const permissions = createServerClient(pool, { throwOnError: false })

// Admin: an explicit subject, run as the pool's role
await permissions.rbac.admin.createRole({
  role: 'editor',
  permissions: ['documents.edit'],
  inherits: ['viewer'],
})
await permissions.rbac.admin.dropRole({ role })
await permissions.rbac.admin.assignRole({ userId, role, scope })
await permissions.rbac.admin.unassignRole({ userId, role, scope })

// string[]
await permissions.rbac.admin.userPermissions({ userId, scope })
await permissions.rbac.admin.usersWithRole({ role, scope })

// { authorizationModelId }
await permissions.fga.admin.writeAuthorizationModel(model)
await permissions.fga.admin.readAuthorizationModel({
  authorizationModelId, // optional
})

// { id, createdAt }[]
await permissions.fga.admin.readAuthorizationModels()

await permissions.fga.admin.write({
  writes,
  deletes,
  onDuplicate,
  onMissing,
  authorizationModelId,
})
await permissions.fga.admin.writeTuple({ user, relation, object })
await permissions.fga.admin.deleteTuple({ user, relation, object })

// { tuples, continuationToken }
await permissions.fga.admin.read({
  object,
  relation,
  user,
  pageSize,
  continuationToken,
})

await permissions.fga.admin.check({
  user,
  relation,
  object,
  contextualTuples,
  context,
  authorizationModelId,
})
await permissions.fga.admin.listObjects({
  user,
  type,
  relation,
  contextualTuples,
  context,
  authorizationModelId,
})
await permissions.fga.admin.listUsers({
  object,
  relation,
  userFilters,
  contextualTuples,
  context,
  authorizationModelId,
})
await permissions.fga.admin.deleteStore()

// number
await permissions.admin.deleteSubject({ type: 'user', id })

// Current-subject checks for a given subject. These run in a
// transaction with set_config('permissions.subject_id', id, true).
// The subject is { id, type?: 'user', role?: 'authenticated' }.
const alice = permissions.as({ id: 'alice' })
await alice.rbac.hasPermission({
  permission: 'documents.edit',
  scope: 'acme',
})
await alice.fga.check({ relation: 'viewer', object: 'document:1' })
```

- **FGA naming.** The JS side uses OpenFGA SDK names and camelCase: `user`, `authorizationModelId` and `continuationToken`. The transport maps them to the SQL names: `subject`, `model_id`, `continuation_token`, `on_duplicate` and `on_missing`.
- **Never send `plan_time_guard`.** It is the hidden second argument of `rbac_scopes_with_permission`.
- **Standalone clients.** The constructor shape is the same everywhere:
  - `new RbacClient(restUrl, { headers, fetch, schema })` for PostgREST.
  - `new RbacClient({ transport: sqlTransport(pool) })` for SQL.
  - `FgaClient` takes the same arguments.

### Errors

- `PermissionsError extends Error` has `{ message, details, hint, code }`, the same fields as `PostgrestError`. It also has a parsed `reason`:
  - `{ model: 'rbac', code: 'unknown_role', context: { role: 'x' } }`. This parses DETAIL `rbac:<code>[ key='value' …]`.
  - `{ model: 'openfga', code: 2001, name: 'authorization_model_not_found' }`. This parses `openfga:<num> <name>`.
  - `null` for plain Postgres errors such as 42501 or 57014.
- `PermissionsFetchError` covers network failures. `PermissionsHttpError` covers non-2xx responses whose body is not a PostgREST error.
- The type guards are `isPermissionsError`, `isRbacError(e, code?)` and `isFgaError(e, code?)`.
- The fixtures are the DETAIL strings in `pg_permissions/docs/errors-and-limits.md`.

### Types

- One optional generic narrows names: `createClient<{ permissions: 'documents.read' | …; roles: 'viewer' | … }>()`.
- Generating types from a database or an FGA model comes later. It is out of scope for v1.

## Layout

```
pg_permissions/js/
  package.json
  tsdown.config.ts
  tsconfig.json
  vitest.config.ts
  typedoc.json
  src/
    index.ts                 umbrella: createClient,
                             createServerClient, re-exports
    lib/errors.ts            PermissionsError, guards,
                             DETAIL parser
    lib/fetch.ts             fetchWithAuth, resolveFetch
    lib/types.ts             Result<T>, options, Transport
    transport/postgrest.ts   rpc over HTTP (PUBLIC only)
    transport/sql.ts         rpc over query(); withSubject
                             transaction
    rbac/RbacClient.ts       client methods, RbacAdminApi
    fga/FgaClient.ts         client methods, FgaAdminApi
                             (name mapping)
  test/
    unit/                    mocked fetch and fake query():
                             request shapes, mapping, errors
    integration/             same specs on both transports
    docker-compose.yml       postgres:17 + postgrest/postgrest,
                             mounts ../../pg_permissions--0.0.1.sql
    setup.sql                roles anon/authenticated/
                             service_role, grants, JWT secret
```

`Transport.rpc(fn, args, shape)` uses `shape` in `'scalar' | 'set' | 'record' | 'void'`. The SQL transport builds `select … from permissions.fn(name => $1, …)` with named arguments only.

## Phases

1. **Scaffold.** package.json with exports for 5 subpaths and per-condition types, tsdown, Vitest, attw and publint. `pnpm build && pnpm test && pnpm check:exports` passes on empty modules.
2. **Core.** Errors and the DETAIL parser, `fetchWithAuth`, both transports and `as()` subject transactions. Unit tests.
3. **RBAC.** `RbacClient` and its admin API. Integration tests on SQL (all methods) and PostgREST (client methods). Confirm how PostgREST returns `void`, `setof` and booleans.
4. **FGA.** `FgaClient` and its admin API, the name mapping, `read` pagination (OUT and INOUT columns), and errors at the 100-key and 1000-result caps. Integration tests.
5. **Umbrella.** `createClient`, `createServerClient`, re-exports and type tests. Examples: a Supabase browser example and a Node server example.
6. **Docs and release.** TypeDoc, a README in STE (`pg_permissions/STYLE.md`) and a permissions.dev quickstart. `npm publish` 0.2.0 only when the user asks.

Spike (optional, in phase 3): check whether `pg_permissions--0.0.1.sql` installs in PGlite. If it does, the SQL integration tests can run without Docker.

## Open checks to confirm in integration tests

- What PostgREST returns for `void` functions, for `setof text`, and for `fga_read`'s OUT and INOUT record (an object, or an array with one item).
- That `rbac_scopes_with_permission` over PostgREST works without the guard argument.
- That PostgREST passes DETAIL and HINT through as `details` and `hint`.
