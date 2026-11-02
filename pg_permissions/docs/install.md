# Install

Install `pg_permissions` by running its SQL file in your database. The database.dev package is not published yet; its instructions below are for a future release.

## Choose a method

| Method | Use it when |
| --- | --- |
| [Direct install](#install-directly) | You have psql or a SQL editor and the extension file. Available now. |
| [pg_tle](#pg_tle) | You want to register the SQL file as an extension through pg_tle. |
| [Docker](#docker) | You want a local database for trying the extension. |
| [database.dev](#install-with-databasedev) | You want a versioned registry package after publication. Not available yet. |

Use one installation method per database. Each creates the `permissions` schema with its tables and functions.

## Requirements

- Postgres 16, 17 or 18.
- No other extension for a direct install. The database.dev method needs the extension pg_tle.
- No C code and no superuser rights. The extension is pure SQL.

The extension is one file, [`pg_permissions--0.1.0.sql`](../pg_permissions--0.1.0.sql), and a control file, [`pg_permissions.control`](../pg_permissions.control). The control file is for the pg_tle path and for tools that read it. A plain install uses only the SQL file.

## Install directly

Use these methods when you do not use database.dev. Each method installs the same SQL file. The next sections show plain `psql`, a non-superuser install, pg_tle by hand, and Docker.

### Plain psql

Run the file once in each database:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f pg_permissions--0.1.0.sql
```

The file creates the schema `permissions` with its tables and functions. The role that you connect as owns all of them.

Do not run the file twice in one database. A second run fails with `already exists` errors. To move a database from 0.0.1 to 0.1.0, see [Upgrade from 0.0.1](#upgrade-from-001).

To install again, drop the schema first with `drop schema permissions cascade;`. Do this only in a database that has no data that you need. You will lose all roles, models and tuples.

On Supabase, paste the file into the SQL editor. You can also run it with `psql` as the `postgres` role. The roles `anon`, `authenticated` and `service_role` already exist on Supabase. Plain Postgres does not have them. The install does not need them. Create the role that your requests use to run.

### Install as a non-superuser

The role that installs the extension does not need superuser rights. It needs `CREATE` on the database, because the file creates the schema `permissions`. It does not need to own the database.

The role owns everything that the file creates. This role is the admin in these docs. For example, create the role and a database for it, then install as that role:

```bash
psql -U postgres \
  -c "create role app_owner nosuperuser createdb nologin" \
  -c "create database app owner app_owner"
psql -U postgres -d app -v ON_ERROR_STOP=1 \
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

The directory [`docker/`](../docker/README.md) has images for Postgres 16, 17 and 18 with pg_tle preloaded. This is the quickest way to try the pg_tle path. From the `pg_permissions/` directory:

```bash
cd docker
docker compose build
docker compose up -d --wait pg17
cd ..
psql -h localhost -p 54317 -U postgres -v ON_ERROR_STOP=1 \
  -f pg_permissions--0.1.0.sql
```

The containers use `trust` authentication on 127.0.0.1. Use them for local tests only.

## Check the install

Connect to the database and call two functions. With no subject set, the first returns `user` and the second returns `false`:

```sql
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

## Upgrade from 0.0.1

A database that has 0.0.1 upgrades with the script [`pg_permissions--0.0.1--0.1.0.sql`](../pg_permissions--0.0.1--0.1.0.sql). The script keeps your roles, models and tuples. Run it once, as the role that owns the schema `permissions`.

For a plain install, run the script with `psql` in one transaction:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -1 \
  -f pg_permissions--0.0.1--0.1.0.sql
```

For a pg_tle install, register the script as an update path, then update the extension:

```sql
\set body `cat pg_permissions--0.0.1--0.1.0.sql`
select pgtle.install_update_path(
  'pg_permissions',
  '0.0.1',
  '0.1.0',
  :'body'
);
alter extension pg_permissions update to '0.1.0';
```

The test suite installs 0.0.1, runs the script, and compares every function, table and index with a fresh 0.1.0 install. It checks the pg_tle update path on Postgres 16, 17 and 18.

## Install with database.dev

[database.dev](https://database.dev/kiwicopple/pg_permissions) is a package registry for Postgres extensions. The package name is `kiwicopple@pg_permissions`. The package is not published yet. These steps are for the time after publication. Until then, [install directly](#install-directly).

The `dbdev` tool installs the package as a pg_tle extension. The package is pure SQL, so no server file is necessary. Postgres 16, 17 and 18 are supported.

Do the prerequisites first:

1. Install the `dbdev` command line tool on your computer. On macOS, run `brew install supabase/tap/dbdev`. For other systems, read the [dbdev CLI instructions](https://supabase.github.io/dbdev/cli/).
2. Enable pg_tle in the database. On Supabase, you can also enable it in the dashboard.

```sql
create extension if not exists pg_tle;
```

Do not use dbdev with a database that has only logical backups. The dbdev documentation says that a restore of a logical backup can fail when a database has a pg_tle extension. Use physical backups.

Then install the package:

1. Make the migration file. The command writes a file to the folder `migrations`:

   ```bash
   dbdev add -o "./migrations/" -v 0.1.0 \
     package -n kiwicopple@pg_permissions
   ```

2. Run the file in the database. Use `psql`, or the migration tool that you already use:

   ```bash
   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
     -f "./migrations/<generated file>"
   ```

The file calls `pgtle.install_extension` with the SQL of the package. It then runs this statement:

```sql
create extension "kiwicopple@pg_permissions" version '0.1.0';
```

Do not add the option `-s` to `dbdev add`. Do not write `with schema` in `create extension`. The extension file creates the schema `permissions` and puts each object in it, so a `schema` clause does not change where the objects are. You call each function as `permissions.name(...)`.

The name of the extension has an at sign, so always write it in double quotes. The `dbdev` documentation marks the in-database client (`dbdev.install`) as deprecated. This page uses the `dbdev add` command instead.

There is no upgrade path yet. To check the install, go to [Check the install](#check-the-install).

## Next steps

[Protect a table](get-started/quickstart.md) to verify access as two different users. Then [choose a permission model](get-started/choose-a-model.md) and [connect your application](integrations/identity.md).
