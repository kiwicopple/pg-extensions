# `pg_permissions`

`pg_permissions` is an authorization extension for Postgres. It has one schema, `permissions`, with two permission models. You can use the models in row level security (RLS) policies.

- **RBAC** (`rbac_*` functions): roles that grant permissions. A user holds a role app-wide or in one tenant.
- **Relationships** (`fga_*` functions): an [OpenFGA](https://openfga.dev)-compatible engine. It has authorization models, tuples, Check, ListObjects, ListUsers and Read, with the error codes of OpenFGA.

The extension is pure SQL. It needs no other extension and no C code. It runs on Postgres 16, 17 and 18.

- Source: https://github.com/kiwicopple/pg-extensions/tree/pg_permissions/pg_permissions
- database.dev (dbdev): https://database.dev/kiwicopple/pg_permissions (not yet published)

## Features

- Roles with inheritance. Assign a role app-wide or in a scope, such as a tenant.
- Access to single objects, nested teams and folders, with the OpenFGA model language (schema 1.1).
- Conditions in [CEL](https://github.com/google/cel-spec) on tuples, for example access that expires.
- Functions for RLS policies that answer for the current user, with a fast path for tenant tables.
- Support for Supabase and PostgREST (the JWT `sub` claim). Plain Postgres uses a value that is local to the transaction.
- Denies across both models, with restrictive policies.
- Tests that include the OpenFGA test suites.

## Quick start

Run the SQL file once in a fresh database, from this directory:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f pg_permissions--0.1.0.sql
```

Then follow [Protect a table](docs/get-started/quickstart.md). It creates a role, grants Alice access to one organization, and verifies that Bob sees no rows. The walkthrough includes request identity and tests queries as an application database role.

[Install](docs/install.md) covers non-superuser installation, pg_tle, and Docker. The database.dev package is not published yet. The extension creates the `permissions` schema itself; do not add `with schema`.

## Documentation

Start with the [documentation map](docs/README.md) or [choose a permission model](docs/get-started/choose-a-model.md).

| Task | Guide |
| --- | --- |
| Set request identity | [Identity and request context](docs/integrations/identity.md) |
| Assign roles and permissions | [RBAC](docs/models/rbac/overview.md) |
| Share objects through relationships | [OpenFGA](docs/models/openfga/overview.md) |
| Add expiry or attribute conditions | [Conditions](docs/models/openfga/conditions.md) |
| Enforce access on a table | [RLS policies](docs/rls/policies.md) |
| Combine roles, shares, and denies | [Combine models](docs/rls/combine-models.md) |
| Look up a function | [Shared](docs/reference/shared.md), [RBAC](docs/reference/rbac.md), [OpenFGA](docs/reference/openfga.md) |
| Connect from JavaScript | [Setup](docs/integrations/javascript.md) and [reference](docs/reference/javascript.md) |

## JavaScript client

The npm package [`permissions`](js/README.md) is the JavaScript client for the extension. `createServerClient` calls every function over SQL on a server. `createClient` calls the client functions over PostgREST or Supabase in a browser.

```bash
npm install permissions
```

```ts
import { createClient } from 'permissions'

const permissions = createClient(
  'https://your-project.supabase.co',
  'your-anon-key'
)
const { data: canEdit } = await permissions.rbac.hasPermission({
  permission: 'documents.edit',
  scope: 'acme'
})
```

See [JavaScript client: setup](docs/integrations/javascript.md) for the methods and the errors. The RBAC and OpenFGA pages show each call next to the SQL.

## Development scripts

The file `package.json` in this directory is the entry point for the whole folder. It is private and has no dependencies. Run each script with `npm run <name>` from `pg_permissions/`. The scripts call the library in `js/` with pnpm and the documentation site in `site/` with npm.

| Script | What it does |
| --- | --- |
| `test` | Runs the extension test suite on a throwaway local Postgres. |
| `test:docker` | Runs the suite on Postgres 16, 17 and 18 with Docker. |
| `test:all` | Runs `test`, then `test:docker`. |
| `js:install` | Installs the dependencies of the JavaScript client. |
| `js:build` | Builds the client into `js/dist`. |
| `js:typecheck` | Type-checks the source, tests and examples. |
| `js:test` | Runs the unit tests. |
| `js:test:integration` | Runs the integration tests. They need Docker. |
| `js:check` | Runs the type check, the unit tests, a build, and the package export checks. |
| `js:docs` | Generates the API reference with TypeDoc. |
| `js:publish` | Runs `js:check`, then publishes `permissions` to npm. Needs your npm login. |
| `js:publish:dry` | Runs `js:check`, then `npm publish --dry-run`. Nothing is published. |
| `docs:install` | Installs the site dependencies from the lock file (`npm ci`). |
| `docs:sync` | Generates the site pages from `docs/` and `research/`. |
| `docs:dev` | Starts the site locally with hot reload. |
| `docs:build` | Syncs, builds the site into `site/dist`, and checks links and content. |
| `docs:preview` | Serves the built site locally. |
| `docs:check:quickstart` | Runs the quickstart SQL on a temporary Postgres. Needs the Postgres binaries. |
| `docs:publish` | Deploys the site to Vercel production with `npx vercel deploy --prod`. Needs your Vercel login. |
| `check` | Runs `js:check` and `docs:build`. Needs no Docker and no Postgres. |

The build output (`js/dist`, `site/dist`) and the generated site pages are never committed. The root `Makefile` targets `make docs`, `make docs.dev` and `make docs.sync` call the `docs:*` scripts.

### Deploy the docs on Vercel

Vercel builds the site from source. Create the project with the Root Directory `pg_permissions`. The install command, the build command and the output directory come from [`vercel.json`](vercel.json), so do not set them in the dashboard. The build needs Node 22.23.4 or later.

The Vercel Git integration deploys on every push to `main`. The script `docs:publish` is the manual alternative.

## Contributing

To run the tests, see [`test/README.md`](test/README.md). To run Postgres 16, 17 and 18 with pg_tle, see [`docker/README.md`](docker/README.md). Write documentation as described in [`STYLE.md`](STYLE.md). The documentation site (Astro + Starlight) is in [`site/`](site/README.md); `npm run docs:build` builds it.

For the design history and the benchmarks, see [`research/README.md`](research/README.md).
