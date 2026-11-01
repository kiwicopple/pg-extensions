# `pg_permissions`

`pg_permissions` is an authorization extension for Postgres. It has one schema, `permissions`, with two permission models. You can use the models in row level security (RLS) policies.

- **RBAC** (`rbac_*` functions): roles that grant permissions. A user holds a role app-wide or in one tenant.
- **Relationships** (`fga_*` functions): an [OpenFGA](https://openfga.dev)-compatible engine. It has authorization models, tuples, Check, ListObjects, ListUsers and Read, with the error codes of OpenFGA.

The extension is pure SQL. It needs no other extension and no C code. It runs on Postgres 16, 17 and 18.

- Source: https://github.com/kiwicopple/pg-extensions/tree/main/pg_permissions
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

Install the extension with one of two methods.

**database.dev (dbdev).** The package is `kiwicopple@pg_permissions`. It is not published yet. Enable pg_tle, generate a migration with the `dbdev` command line tool, and run it:

```bash
dbdev add -o "./migrations/" -v 0.0.1 package -n kiwicopple@pg_permissions
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "./migrations/<generated file>"
```

**Direct.** Run the SQL file once in each database:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f pg_permissions--0.0.1.sql
```

[Install](docs/install.md) has the full steps for both methods, and for a non-superuser install, pg_tle and Docker. The extension creates its own schema `permissions`. Do not use `with schema`.

Define two roles, and give a user the `editor` role in one organization. The role `editor` inherits `viewer`:

```sql
select permissions.rbac_create_role(role => 'viewer', permissions => '{documents.read}');
select permissions.rbac_create_role(role => 'editor', permissions => '{documents.edit}', inherits => '{viewer}');
select permissions.rbac_assign_role(
    user_id => '11111111-1111-1111-1111-111111111111',
    role    => 'editor',
    scope   => 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
```

Add an RLS policy. The policy lets a user read the rows of each organization where the user has `documents.read`:

```sql
create table public.documents (
    id     uuid primary key default gen_random_uuid(),
    org_id uuid not null,
    title  text not null
);
create index on public.documents (org_id);
alter table public.documents enable row level security;
grant select on public.documents to authenticated;

create policy documents_select on public.documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid)));
```

The example uses the role `authenticated` of Supabase. On plain Postgres, create it first. The extension finds the current user in the JWT of the request (Supabase and PostgREST). On plain Postgres, set `permissions.subject_id` at the start of each transaction. See [RBAC](docs/rbac.md#identity).

## Documentation

| Page | What it covers |
| --- | --- |
| [Index](docs/README.md) | The list of pages, and how to choose a model |
| [Install](docs/install.md) | Install with database.dev, with psql, as a non-superuser, with pg_tle and with Docker |
| [RBAC](docs/rbac.md) | Identity, roles, permissions, scopes and privileges |
| [The OpenFGA model](docs/fga.md) | Authorization models, tuples, Check, ListObjects, ListUsers and Read |
| [OpenFGA conditions](docs/conditions.md) | CEL conditions on tuples |
| [RLS policies](docs/rls.md) | RLS policies for RBAC, and for both models together |
| [Function reference](docs/reference.md) | The signature of each function |
| [Errors and limits](docs/errors-and-limits.md) | Error codes and limits |
| [JavaScript client](docs/javascript.md) | The npm package `permissions` |

## JavaScript client

The npm package [`permissions`](js/README.md) is the JavaScript client for the extension. `createServerClient` calls every function over SQL on a server. `createClient` calls the client functions over PostgREST or Supabase in a browser.

```bash
npm install permissions
```

```ts
import { createClient } from 'permissions'

const permissions = createClient('https://your-project.supabase.co', 'your-anon-key')
const { data: canEdit } = await permissions.rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' })
```

See [JavaScript client](docs/javascript.md) for the methods and the errors.

## Contributing

To run the tests, see [`test/README.md`](test/README.md). To run Postgres 16, 17 and 18 with pg_tle, see [`docker/README.md`](docker/README.md). Write documentation as described in [`STYLE.md`](STYLE.md).

For the design history and the benchmarks, see [`research/README.md`](research/README.md).
