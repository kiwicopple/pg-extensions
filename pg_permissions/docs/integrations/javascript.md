# JavaScript setup

Use the `permissions` package to call the extension from Node, browsers, Deno, or Bun. A server connects over SQL; a browser or edge function uses PostgREST.

Install `pg_permissions` in the database first. Model guides show SQL and JavaScript together. See the [client reference](../reference/javascript.md) for methods, return values, and errors.

## Install

```bash
npm install permissions
```

## Entry points

The package has two entry points. Choose the entry point from the place where the code runs.

| Entry point | Where it runs | How it connects | What it can call |
| --- | --- | --- | --- |
| `createServerClient(db)` | A server | SQL, as the role of the connection | Every function. It has the `admin` namespaces. |
| `createClient(url, key, options)` | A browser or an edge function | PostgREST or Supabase, as the signed-in user | The client functions only. It has no `admin`. |

`db` is a `pg` pool, or any object with `query(text, values)`. The role of the connection must have `execute` on the admin functions. See [Privileges](privileges.md).

Admin calls never go over HTTP. A browser does not need a service key. Do not send a service key to a browser.

On a server, create the client from a pool:

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)
```

In a browser, create the client with the URL and the anon key of the Supabase project. The option `accessToken` returns the JWT of the signed-in user:

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
```

Before you use `createClient`, add `permissions` to **Exposed schemas** in the Supabase API settings.

For plain PostgREST, add `permissions` to `db-schemas`, and pass the option `restUrl`. The client then sends requests to `<restUrl>/rpc/<function>`. It does not add `/rest/v1`.

```ts
import { createClient } from 'permissions'

const POSTGREST_URL = 'http://localhost:3000'
const USER_JWT = 'eyJ...'

const permissions = createClient(POSTGREST_URL, USER_JWT, {
  restUrl: POSTGREST_URL,
  accessToken: () => USER_JWT,
})
```

When `accessToken` returns `null`, the client sends the anon key. Then there is no subject, and each check is `false`.

## Check as a subject

On a server, the connection has no subject. The call `as(subject)` returns a client that runs each call for one subject. It gives the same answers as the browser client gives for that user. The client that `as()` returns has `rbac`, `fga` and `cedar` with the client methods only. It has no `admin`.

| Call | What it does |
| --- | --- |
| `as({ id, type?, role? })` | Runs each call in a transaction. The transaction sets `permissions.subject_id` to `id`, and `permissions.subject_type` to `type`. It clears `request.jwt.claims`. With `role`, it also runs `set local role`. |

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)

// Run each call with the privileges of a signed-in user.
const alice = permissions.as({ id: 'alice', role: 'authenticated' })
```

The default `type` is `'user'`. The RBAC functions use the type `user` only. The Cedar principal is the type and the id, for example `user::"alice"`. See [RBAC](identity.md#subject-type).

A browser client has no `as()`. The subject is the user of the access token.

## Get the current subject

`currentSubjectId()` calls `permissions.current_subject_id()`. `currentSubjectType()` calls `permissions.current_subject_type()`. These methods are methods of the client itself. They are not in the `rbac` namespace or the `fga` namespace.

They exist on `createClient`, on `createServerClient` and on the client that `as()` returns. `currentSubjectId()` returns `null` when there is no subject. A server client without `as()` has no subject. A browser client with the anon key has no subject.

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

## Use from a CDN

The package has a UMD bundle for a `<script>` tag. It sets the global `permissions`.

```html
<script
  src="https://cdn.jsdelivr.net/npm/permissions@0.2/dist/umd/permissions.js"
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

| `permissions` | `pg_permissions` | Runtime |
| --- | --- | --- |
| The first release with `cedar` | 0.1.0 | Node 20 or later. Browsers, Deno and Bun that have `fetch`. RBAC and OpenFGA also work with 0.0.1. |
| 0.2.x | 0.0.1 | Node 20 or later. Browsers, Deno and Bun that have `fetch`. |
