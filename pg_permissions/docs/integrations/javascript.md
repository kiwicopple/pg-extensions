# JavaScript setup

Use the `permissions` package to call the extension from Node, browsers, Deno, or Bun. A server connects over SQL; a browser or edge function uses PostgREST.

[Install the extension](../install.md) in your database first. You can use the client as your backend's authorization API without creating RLS policies. [Check access in your application](checks.md) shows how to enforce the returned decision. The model guides use the same client and include equivalent SQL calls. See the [client reference](../reference/javascript.md) for methods, return values, and errors.

## Install

```bash
npm install permissions
```

For a Node backend using node-postgres, also install the `pg` driver (`npm install pg`).

## Entry points

The package has two entry points. Choose the entry point from the place where the code runs.

| Entry point | Where it runs | How it connects | What it can call |
| --- | --- | --- | --- |
| `createServerClient(db)` | A server | SQL, as the role of the connection | Every function. It has the `admin` namespaces. |
| `createClient(url, key, options)` | A browser or an edge function | PostgREST or Supabase, as the signed-in user | The client functions only. It has no `admin`. |

`db` is a `pg` pool, or any object with `query(text, values)`. The role of the connection must have `execute` on the admin functions. See [Privileges](privileges.md).

Admin calls never go over HTTP. A browser does not need a service key. Do not send a service key to a browser.

On a server, create the client from a pool:

```js
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)
```

In a browser, create the client with the URL and the anon key of the Supabase project. Supply your application’s `getAccessToken` callback. It returns the signed-in user’s current JWT, or `null` when signed out.

```js
import { createClient } from 'permissions'

const SUPABASE_URL = 'https://your-project.supabase.co'
const SUPABASE_ANON_KEY = 'your-anon-key'

const permissions = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  accessToken: getAccessToken,
})
```

Before you use `createClient`, add `permissions` to **Exposed schemas** in the Supabase API settings.

For plain PostgREST, add `permissions` to `db-schemas`, and pass the option `restUrl`. The client then sends requests to `<restUrl>/rpc/<function>`. It does not add `/rest/v1`.

```js
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

```js
const alice = permissions.as({ id: 'alice' })
const { data: canRead, error } = await alice.rbac.hasPermission({
  permission: 'documents.read',
  scope: 'acme',
})
if (error) throw error
```

If your backend should also switch database roles, pass `role`. The role must exist, and the connection must be allowed to assume it.

The default `type` is `'user'`. The RBAC functions use the type `user` only. The Cedar principal is the type and the id, for example `user::"alice"`. See [subject types](identity.md#subject-type).

A browser client has no `as()`. The subject is the user of the access token.

## Get the current subject

Use `currentSubjectId()` and `currentSubjectType()` to inspect the identity on a client. A subject client reports the identity passed to `as()`. A signed-in browser client reports the identity from its JWT.

```js tab="JavaScript"
const team = permissions.as({ id: 'eng', type: 'team' })
const { data: id } = await team.currentSubjectId() // 'eng'
const { data: type } = await team.currentSubjectType() // 'team'
```

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', 'eng', true);
select set_config('permissions.subject_type', 'team', true);
select permissions.current_subject_id();    -- eng
select permissions.current_subject_type();  -- team
commit;
```

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

Use Node 20 or later, or a browser, Deno or Bun with `fetch`. The current client works with all three permission models in `pg_permissions` 0.1.0. For earlier client versions, see the [package changelog](../../js/CHANGELOG.md).
