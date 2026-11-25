# Install

Run one SQL file in your database to start using `pg_idkit`. You can paste it into a SQL editor or use the terminal installer below. No server files, compiler, Docker or pg_tle setup is needed.

You need Postgres 13 or later and a database role allowed to create a schema and its objects. The installing role owns the objects. Use one installation method per database, and start with a fresh installation.

## Paste into a SQL editor

1. Open the [SQL file for 0.0.5](https://raw.githubusercontent.com/kiwicopple/pg-extensions/main/pg_idkit/pg_idkit--0.0.5.sql) and copy its entire contents.
2. Open your database's SQL editor, connected as the installing role.
3. Paste the file between `begin;` and `commit;` as shown below, then run the whole script together. Replace the comment with the file contents.

```sql
begin;
create schema if not exists extensions;
set local search_path = extensions, pg_catalog, pg_temp;

-- Paste the complete pg_idkit--0.0.5.sql file here.

commit;
```

This creates the `extensions` schema and its objects in one transaction. An error rolls the installation back. If your editor leaves the transaction open after an error, run `rollback;` before trying again.

## Install from your terminal

With `curl` and the Postgres client (`psql`) installed, copy this block and replace the connection string with your database's connection string:

```bash
curl -fsSL https://raw.githubusercontent.com/kiwicopple/pg-extensions/main/install.sh -o install-pg-extension.sh &&
sh install-pg-extension.sh pg_idkit \
  --database 'postgresql://postgres@localhost:5432/postgres'
```

The username in the connection string is your login role. Omit the password to let `psql` prompt for it, or use `.pgpass`. You can also pass `--database "$DATABASE_URL"` if you already keep your connection string in that variable.

The installer downloads the latest default version declared in `pg_idkit.control` on `main`, then runs the full SQL in one transaction. It stops on errors and refuses an existing installation. It does not upgrade or remove objects.

### Choose a version or owner role

Add `--version 0.0.5` to install a specific SQL file. Add `--role app_owner` only when you want an existing role to own the objects; your login must be allowed to `SET ROLE` to it, and that role needs installation privileges:

```bash
sh install-pg-extension.sh pg_idkit \
  --database "$DATABASE_URL" \
  --version 0.0.5 \
  --role app_owner
```

To save ready-to-run SQL for an editor or migration without connecting to Postgres:

```bash
sh install-pg-extension.sh pg_idkit \
  --version 0.0.5 \
  --output pg_idkit-install.sql
```

The saved file already includes the transaction and schema setup. Run the entire file. For reproducible downloads, also pass `--ref` with a full Git commit SHA; a version selects a filename, while a commit pins its contents. See [installer options](https://github.com/kiwicopple/pg-extensions/blob/main/INSTALL.md).

## Verify

```sql
select extensions.gen_random_uuid_v7();
-- A uuid value; different on each call.
```

## Load the SQL directly

If you already have the repository, run this from `pg_idkit/`:

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -1 \
  -c 'create schema if not exists extensions' \
  -c 'set local search_path = extensions, pg_catalog, pg_temp' \
  -f pg_idkit--0.0.5.sql
```

SQL-editor and terminal installs create ordinary functions, without a `pg_extension` entry. `pg_dump` includes them; `alter extension` and `drop extension` do not manage them. Do not rerun the raw SQL over existing functions. The terminal installer checks for collisions before loading it.

If your application connects as another role, the schema owner can grant it access (replace `app_user` with that existing role):

```sql
grant usage on schema extensions to app_user;
```

The functions have Postgres's default function execution privileges. ULID generation uses the built-in `gen_random_uuid()` and needs no additional extension.

## Advanced: extension management

Use the following options when you need Postgres to track the functions as an extension. Choose these instead of a direct SQL installation.

### Install as an extension

As the server administrator, copy the control and version files into the extension directory of the target Postgres installation. Run this from `pg_idkit/`, using the `pg_config` for that server:

```bash
cp pg_idkit.control pg_idkit--*.sql \
  "$(pg_config --sharedir)/extension/"
```

As a database role with permission to create schemas and extensions:

```sql
create schema if not exists extensions;
create extension pg_idkit with schema extensions version '0.0.5';
```

The control file sets `superuser = false` and does not fix a schema. Installation still requires the appropriate database and schema privileges. Examples elsewhere assume you chose `extensions`; substitute your schema if needed.

For an extension installation, inspect its version and schema:

```sql
select e.extversion, n.nspname
from pg_extension as e
join pg_namespace as n on n.oid = e.extnamespace
where e.extname = 'pg_idkit';
-- 0.0.5 | extensions
```

### Managed databases

The original README points to the [database.dev package](https://database.dev/kiwicopple/pg_idkit). Package availability and installation tooling are separate from the checked-in SQL. Check the version offered by your provider; these docs describe 0.0.5. If the provider has already made the extension available, use the `create extension` step above.

## Upgrade and removal

After installing the version and upgrade SQL files on the server, the extension owner can upgrade an existing extension:

```sql
alter extension pg_idkit update to '0.0.5';
```

The repository contains upgrade steps from 0.0.1 through 0.0.5. Confirm the version with the query above.

To remove an extension installation, first remove dependent column defaults deliberately, then run `drop extension pg_idkit;`. Avoid `cascade`: it can remove those defaults for you. Existing ID values are ordinary `uuid` or `text` data and do not require the extension to read them.
