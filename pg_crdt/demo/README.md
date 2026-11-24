# Homepage counter demo

The homepage shows two independent devices. Edits change only that device’s local copy. **Sync both devices** sends both devices’ running totals to Postgres and merges the returned state into each local copy. **Replay last sync** sends the identical payload again. The value stays the same; edits made since that sync remain pending.

Each page load or **Start over** creates a separate visitor session. This is a two-device simulation within one page, not a shared global counter or a cross-tab editor. Local edits live in memory and disappear when the page closes. Sessions last 24 hours; expired database rows are removed in batches of 100 during subsequent writes. There is no background cleanup when the demo is idle.

Without server configuration, the UI explicitly says **Browser preview** and merges in JavaScript. With configuration, it says **Live Postgres** and every sync runs the actual `crdt.pn_apply_delta` function. A database failure shows an error and preserves local edits; it never switches to simulated success.

## Provision Postgres

Use a dedicated Postgres **16, 17, or 18** database with UTF-8 encoding. No extension allowlist, custom server binary, pg_tle, or superuser is required: the extension is SQL and PL/pgSQL.

The setup account needs `CREATE` on the database and permission to create the runtime role. Use an empty database with no existing `crdt` or `crdt_demo` schema. If the provider cannot let you create roles, have its administrator run the role/grant statements in `setup.sql`.

Make its TLS endpoint reachable from Vercel and place the function region near the database. For serverless hosting, use the provider’s pooled connection URL when available. The code uses no named prepared statements or session identity settings, so transaction pooling is supported. The pool in each function instance is capped at two connections.

## Install once

Run from `pg_crdt/`. Use your provider’s CA certificate if it is not trusted by your system. These commands prompt for the administrator password rather than saving it in shell history:

```sh
export PGHOST=YOUR_DATABASE_HOST
export PGPORT=5432
export PGDATABASE=YOUR_DEMO_DATABASE
export PGUSER=YOUR_SETUP_USER
export PGSSLMODE=verify-full

psql -W -v ON_ERROR_STOP=1 -f pg_crdt--0.0.1.sql
psql -W -v ON_ERROR_STOP=1 -f demo/setup.sql
psql -W -c '\password crdt_demo_app'
```

The last command prompts for a password for `crdt_demo_app`. The runtime role has access to the demo table and CRDT functions, with no ownership or schema creation rights. The table has row-level security enabled with a policy for this server role; the API checks signed session ownership before issuing queries. Do not use the setup account in Vercel.

Check the installation with the runtime user:

```sh
PGUSER=crdt_demo_app psql -W -c \
  'select crdt.pn_value(crdt.pn_empty()); select count(*) from crdt_demo.counters;'
```

Both results should be `0` before anyone uses the demo. Do not rerun installation over an existing schema. See the main [installation guide](../docs/install.md) for other installation methods.

## Connect the site

Set these **server-only** environment variables in the existing Vercel project, then redeploy:

| Variable | Value |
| --- | --- |
| `CRDT_DEMO_DATABASE_URL` | The TLS connection URL for `crdt_demo_app`, including the database name. URL-encode password characters. Use `sslmode=verify-full` with a trusted certificate. |
| `CRDT_DEMO_SECRET` | A random signing secret of at least 32 characters. Generate one with `openssl rand -hex 32`. |
| `CRDT_DEMO_DATABASE_CA` | Optional provider CA certificate in PEM format. Required when the provider's CA is not in Node's trust store, including the tested Supabase pooler. Accepts literal or escaped newlines. |

When a provider CA is configured, the API uses it with certificate and hostname verification enabled, overriding SSL options in the connection URL. In Vercel, paste the certificate contents as `CRDT_DEMO_DATABASE_CA`; no certificate file path is needed. Do not prefix these variables with `PUBLIC_`. Never commit credentials. Rotating the signing secret invalidates existing sessions.

Keep the Vercel Root Directory as `pg_crdt`. The existing static documentation build remains unchanged; `api/counter.mjs` adds a Node.js function at `/api/counter`. The install command installs both the function dependencies and the site dependencies. This follows Vercel’s [Node.js functions convention](https://vercel.com/docs/functions/runtimes/node-js).

For local development, copy `site/.env.example` to `site/.env`, fill in the runtime settings (including a provider CA when needed), and run:

```sh
npm run docs:install
npm run docs:dev
```

Astro’s dev middleware runs the same API handler as Vercel. Restart the dev server after changing environment variables. A plain static `docs:preview` has no API and always uses browser preview mode.

## Check the live demo

1. Confirm the badge says **Live Postgres**.
2. Add three on Alice’s laptop and subtract one on Bob’s phone. Their values should be `3` and `-1`, while the stored value is `0`.
3. Sync. Both devices and Postgres should show `2`.
4. Replay. All three should still show `2`.
5. Add another local change, then replay the old sync. The new edit should stay local until you sync again.
6. Start over. The new session starts at `0` without changing other visitors’ counters.

## Bounds and operations

The API accepts only two fixed replica keys, whole totals from 0 to 10,000, and bodies up to 2 KiB. Signed session tokens bind requests to a server-issued counter ID. The parameterized upsert merges into the stored value atomically, including concurrent first writes. All API responses use `Cache-Control: no-store`; database errors and credentials are never sent to the browser.

This is an anonymous public demo. Tokens isolate sessions but do not limit how many sessions someone creates. Configure a Vercel Firewall rate limit for `/api/counter` before exposing it to heavy traffic. Monitor database storage; for idle deployments, expired rows can also be removed by an operator with `delete from crdt_demo.counters where expires_at < now()`.

Run `npm run test:demo` for browser-model and API tests, including the real extension SQL and runtime-role grants in an embedded Postgres engine (PGlite). These tests do not verify a hosted server’s TLS or network connectivity. Run `npm run docs:build` for the documentation build and link/content checks.
