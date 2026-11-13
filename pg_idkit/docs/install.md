# Install

Install the extension files on a server you control, or load the SQL directly into a development database. Both methods below use a schema named `extensions`. Choose one method per database.

The implementation uses built-in SQL and PL/pgSQL functions and has no additional extension dependency. This repository does not yet provide a Postgres version test matrix for `pg_idkit`.

## Install as an extension

As the server administrator, copy the control and version files into the extension directory of the target Postgres installation. Run this from `pg_idkit/`, using the `pg_config` for that server:

```bash
cp pg_idkit.control pg_idkit--*.sql \
  "$(pg_config --sharedir)/extension/"
```

As a database role with permission to create schemas and extensions:

```sql
create schema if not exists extensions;
create extension pg_idkit with schema extensions version '0.0.4';
```

The control file sets `superuser = false` and does not fix a schema. Installation still requires the appropriate database and schema privileges. Examples elsewhere assume you chose `extensions`; substitute your schema if needed.

## Load the SQL directly

For a local experiment without server filesystem access, run this from `pg_idkit/` as a role allowed to create functions in the destination schema:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -c 'create schema if not exists extensions' \
  -c 'set search_path = extensions, pg_catalog' \
  -f pg_idkit--0.0.4.sql
```

This creates functions, without a `pg_extension` entry. `alter extension` and `drop extension` do not manage these functions. Use an empty development database to avoid replacing existing functions with the same names.

## Managed databases

The original README points to the [database.dev package](https://database.dev/kiwicopple/pg_idkit). Package availability and installation tooling are separate from the checked-in SQL. Check the version offered by your provider; these docs describe 0.0.4. If the provider has already made the extension available, use the `create extension` step above.

## Verify

```sql
select extensions.gen_random_uuid_v7();
-- A uuid value; different on each call.
```

For an extension installation, inspect its version and schema:

```sql
select e.extversion, n.nspname
from pg_extension as e
join pg_namespace as n on n.oid = e.extnamespace
where e.extname = 'pg_idkit';
-- 0.0.4 | extensions
```

## Upgrade and removal

After installing the version and upgrade SQL files on the server, the extension owner can upgrade an existing extension:

```sql
alter extension pg_idkit update to '0.0.4';
```

The repository contains upgrade steps from 0.0.1 through 0.0.4. Confirm the version with the query above.

To remove an extension installation, first remove dependent column defaults deliberately, then run `drop extension pg_idkit;`. Avoid `cascade`: it can remove those defaults for you. Existing ID values are ordinary `uuid` or `text` data and do not require the extension to read them.
