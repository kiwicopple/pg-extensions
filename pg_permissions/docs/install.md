# Install

Install the extension once in each Postgres database that will store permissions. It creates the `permissions` schema for RBAC, OpenFGA and Cedar. Then [connect your application](integrations/javascript.md) to assign permissions and check access.

<span id="install-with-databasedev"></span>

## Choose a method

| Method | Use it when |
| --- | --- |
| [Direct install](#install-directly) | You have psql or a SQL editor and the extension file. |
| [pg_tle](#pg_tle) | You want to register the SQL file as an extension through pg_tle. |
| [Docker](#docker) | You want a local database for trying the extension. |

Use one installation method per database. Each creates the `permissions` schema with its tables and functions.

## Requirements

- Postgres 16, 17 or 18.
- A direct install requires only Postgres. Registering the package with pg_tle also requires the pg_tle extension.
- No C code and no superuser rights. The extension is pure SQL.

The extension is one file, [`pg_permissions--0.1.0.sql`](../pg_permissions--0.1.0.sql), and a control file, [`pg_permissions.control`](../pg_permissions.control). The control file is for the pg_tle path and for tools that read it. A plain install uses only the SQL file.

## Install directly

Download the SQL file linked above, or run these commands from the `pg_permissions/` directory of the repository.

### Plain psql

Run the file once in each database:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -1 \
  -f pg_permissions--0.1.0.sql
```

The file creates the schema `permissions` with its tables and functions. The role that you connect as owns all of them.

Install in one transaction. The `-1` option keeps new functions private until the script has applied their final privileges, and rolls everything back if installation fails. In a SQL editor, wrap the file in `begin;` and `commit;`. `CREATE EXTENSION` through pg_tle already runs atomically.

Run the fresh-install script only on an empty installation. For an existing database, see [Upgrade an existing installation](#upgrade-an-existing-installation).

To install again, drop the schema first with `drop schema permissions cascade;`. Do this only in a database that has no data that you need. You will lose all permission data, including roles, models, tuples, Cedar policies, templates and entities, as well as dependent objects such as RLS policies.

On Supabase, paste the file into the SQL editor. You can also run it with `psql` as the `postgres` role. The roles `anon`, `authenticated` and `service_role` already exist on Supabase. Plain Postgres does not have them. The install does not need them. Create the role that your requests use to run.

### Install as a non-superuser

The role that installs the extension does not need superuser rights. It needs `CREATE` on the database, because the file creates the schema `permissions`. It does not need to own the database.

The role owns everything that the file creates. This role is the admin in these docs. For example, create the role and a database for it, then install as that role:

```bash
psql -U postgres \
  -c "create role app_owner nosuperuser createdb nologin" \
  -c "create database app owner app_owner"
psql -U postgres -d app -v ON_ERROR_STOP=1 -1 \
  -c "set session authorization app_owner" \
  -f pg_permissions--0.1.0.sql
```

The second command is a fragment. It needs the role and the database from the first command, and your own connection options. The test suite checks this install on each supported Postgres version. A non-superuser that owns the database installs the file. Each object belongs to that role. No function is written in C.

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

If the first query fails with `schema "permissions" does not exist`, the file did not run in this database. Run it again with `-v ON_ERROR_STOP=1` and read the first error.

<span id="upgrade-from-001"></span>

## Upgrade an existing installation

Follow the [version-specific upgrade instructions](../CHANGELOG.md#upgrade-from-001) for a database that already contains permission data. Use the upgrade script for its installed version and review the security notes before upgrading.

## Back up and restore

A plain `psql` install creates ordinary objects. `pg_dump` dumps the schema `permissions` with its data, as it does for any other schema.

An install through `create extension` (pg_tle) is different. No table of the extension is marked with `pg_extension_config_dump`, so `pg_dump` writes `create extension` and no table data. A restore then gives empty tables. You lose all roles, assignments, models, tuples, Cedar policies and entities. The loss is safe: with no data, each check returns false or an empty result, so nobody gets access. Your application stops working until you load the data again.

To keep the data of such an install, use a physical backup. You can also export the tables of the schema `permissions` with `copy`, and load them after the restore. Test a restore before you rely on it.

## Next steps

[Check permissions](get-started/quickstart.md) for two users, then [use the checks in your backend](integrations/checks.md). [Choose a permission model](get-started/choose-a-model.md) for your access rules. The quickstart also includes optional RLS enforcement on a table.
