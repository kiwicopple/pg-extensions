# Install

Run one SQL file in your database to start using `pg_permissions`. You can paste it into a SQL editor or use the terminal installer below. No server files, compiler, Docker or pg_tle setup is needed.

You need Postgres 16, 17 or 18 and a database role allowed to create a schema and its objects. The installing role owns the objects. Use one installation method per database, and start with a fresh installation.

Already storing permissions? Follow [Upgrade an existing installation](#upgrade-an-existing-installation) instead of running a fresh-install file.

<span id="install-with-databasedev"></span>

## Paste into a SQL editor

1. Open the [SQL file for 0.1.0](https://raw.githubusercontent.com/kiwicopple/pg-extensions/main/pg_permissions/pg_permissions--0.1.0.sql) and copy its entire contents.
2. Open your database's SQL editor, connected as the installing role.
3. Paste the file between `begin;` and `commit;` as shown below, then run the whole script together. Replace the comment with the file contents.

```sql
begin;
-- Paste the complete pg_permissions--0.1.0.sql file here.

commit;
```

This creates the `permissions` schema and its objects in one transaction. An error rolls the installation back. If your editor leaves the transaction open after an error, run `rollback;` before trying again.

## Install from your terminal

With `curl` and the Postgres client (`psql`) installed, copy this block and replace the connection string with your database's connection string:

```bash
curl -fsSL https://raw.githubusercontent.com/kiwicopple/pg-extensions/main/install.sh -o install-pg-extension.sh &&
sh install-pg-extension.sh pg_permissions \
  --database 'postgresql://postgres@localhost:5432/postgres'
```

The username in the connection string is your login role. Omit the password to let `psql` prompt for it, or use `.pgpass`. You can also pass `--database "$DATABASE_URL"` if you already keep your connection string in that variable.

The installer downloads the latest default version declared in `pg_permissions.control` on `main`, then runs the full SQL in one transaction. It stops on errors and refuses an existing installation. It does not upgrade or remove objects.

### Choose a version or owner role

Add `--version 0.1.0` to install a specific SQL file. Add `--role app_owner` only when you want an existing role to own the objects; your login must be allowed to `SET ROLE` to it, and that role needs installation privileges:

```bash
sh install-pg-extension.sh pg_permissions \
  --database "$DATABASE_URL" \
  --version 0.1.0 \
  --role app_owner
```

To save ready-to-run SQL for an editor or migration without connecting to Postgres:

```bash
sh install-pg-extension.sh pg_permissions \
  --version 0.1.0 \
  --output pg_permissions-install.sql
```

The saved file already includes the transaction and schema setup. Run the entire file. For reproducible downloads, also pass `--ref` with a full Git commit SHA; a version selects a filename, while a commit pins its contents. See [installer options](https://github.com/kiwicopple/pg-extensions/blob/main/INSTALL.md).

## Check the install

Use a [server client](integrations/javascript.md#entry-points) or psql on a connection with no subject or JWT. These calls check that the extension is reachable and that an anonymous request has no permissions.

```js tab="JavaScript"
const { data: type, error } = await permissions.currentSubjectType()
if (error) throw error
const { data: canRead, error: checkError } = await permissions.rbac.hasPermission({
  permission: 'documents.read',
})
if (checkError) throw checkError
console.log(type, canRead) // 'user', false
```

```sql tab="SQL"
select permissions.current_subject_type();
-- user
select permissions.rbac_has_permission(
  permission => 'documents.read'
);
-- false
```

To list the RBAC functions, use this psql command:

```text
\df permissions.rbac_*
```

If the first query fails with `schema "permissions" does not exist`, the file did not run in this database. Check the connection string and the first installation error before trying again.

## Install directly

If you already have the repository, run this from `pg_permissions/`:

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -1 \
  -f pg_permissions--0.1.0.sql
```

The `-1` option installs in one transaction: new functions stay private until the script applies their final privileges, and errors roll everything back. The file creates the `permissions` schema with tables and functions for RBAC, OpenFGA and Cedar. A direct install creates ordinary database objects; `alter extension` does not manage them.

### Install as a non-superuser

The installing role needs `CREATE` on the database, but does not need to own the database or be a superuser. It owns all objects created by the file and is the admin in these docs. Use its login connection, or the terminal installer's `--role` option if your login can assume that role. The installer does not create or grant roles.

Application roles are separate from the owner role. Follow [Connect your application](integrations/javascript.md) for the runtime setup.

<span id="upgrade-from-001"></span>

## Upgrade an existing installation

Follow the [version-specific upgrade instructions](../CHANGELOG.md#upgrade-from-001) for a database that already contains permission data. Use the upgrade script for its installed version and review the security notes before upgrading.

## Back up and restore

A plain `psql` install creates ordinary objects. `pg_dump` dumps the schema `permissions` with its data, as it does for any other schema.

An install through `create extension` (pg_tle) is different. No table of the extension is marked with `pg_extension_config_dump`, so `pg_dump` writes `create extension` and no table data. A restore then gives empty tables. You lose all roles, assignments, models, tuples, Cedar policies and entities. The loss is safe: with no data, each check returns false or an empty result, so nobody gets access. Your application stops working until you load the data again.

To keep the data of such an install, use a physical backup. You can also export the tables of the schema `permissions` with `copy`, and load them after the restore. Test a restore before you rely on it.

## Next steps

[Check permissions](get-started/quickstart.md) for two users, then [use the checks in your backend](integrations/checks.md). [Choose a permission model](get-started/choose-a-model.md) for your access rules. The quickstart also includes optional RLS enforcement on a table.

## Advanced: pg_tle and Docker

Use pg_tle when you need a `pg_extension` entry, or Docker when you need a local test database. The commands below assume a repository checkout and run from `pg_permissions/`.

### pg_tle

[pg_tle](https://github.com/aws/pg_tle) lets a role install an extension from SQL, without access to the server file system. Load pg_tle with `shared_preload_libraries = 'pg_tle'`. A superuser enables it once in each database and lets the role that installs the extension use it:

```sql
create extension pg_tle;
grant pgtle_admin to app_owner;   -- the role that installs
```

Then, as that role in psql, install the file as a pg_tle extension and create the extension:

```sql
\set body `cat pg_permissions--0.1.0.sql`
select pgtle.install_extension(
  'pg_permissions',
  '0.1.0',
  'pg_permissions',
  :'body'
);
create extension pg_permissions;
```

Write `create extension pg_permissions;` without `with schema`. The file creates the schema `permissions` itself. You call each function as `permissions.name(...)`. The test suite runs this sequence on Postgres 16, 17 and 18 with pg_tle 1.5.3.

### Docker

The [Docker images](../docker/README.md) provide local Postgres 16, 17 and 18 with pg_tle available. To try the quickstart, start Postgres 17 and install the SQL file from the `pg_permissions/` directory:

```bash
cd docker
docker compose build
docker compose up -d --wait pg17
cd ..
psql -h localhost -p 54317 -U postgres -v ON_ERROR_STOP=1 -1 \
  -f pg_permissions--0.1.0.sql
```

For the JavaScript quickstart, set `DATABASE_URL=postgresql://postgres@localhost:54317/postgres`. These containers use `trust` authentication on the loopback interface and are intended for local tests.
