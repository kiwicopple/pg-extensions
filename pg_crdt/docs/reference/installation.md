# Installation options

For a first install, use the [short installation guide](../install.md). These options are for managing a database over time.

## Pin a version or save a migration

After downloading the installer as shown in the guide, choose a SQL version with `--version`. To pin its contents too, add `--ref` with a full Git commit SHA.

```bash
sh install-pg-extension.sh pg_crdt \
  --database "$DATABASE_URL" \
  --version 0.0.1
```

Add `--role app_owner` to install as an existing owner role; your login must be allowed to switch to it. To save SQL without connecting, use `--output pg_crdt-install.sql` instead of `--database`. The saved file includes the transaction and schema setup.

See [all installer options](https://github.com/kiwicopple/pg-extensions/blob/main/INSTALL.md).

## Install from a checkout

Run from `pg_crdt/`:

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -1 \
  -f pg_crdt--0.0.1.sql
```

A direct SQL install creates ordinary database objects. Include the `crdt` schema in backups. It has no `pg_extension` entry and no in-place upgrade. Do not reinstall over an existing schema. See [backups and removal](operations.md).

For an older build containing `ydoc_` tables, read the [existing-installation note](../../research/scope.md#existing-installations). There is no automatic migration to text columns.

## Extension management

Use pg_tle or the server extension directory when you need a `pg_extension` entry. Choose one of these instead of a direct SQL install. Commands below run from `pg_crdt/`. Preparing pg_tle or copying server files can require an administrator.

### The schema guard

The install refuses to use a `crdt` schema that already exists when another non-superuser role owns it, or when any other role has `CREATE` on it. Either role could drop or replace the functions, and with them the domain check and the identity check in `pn_apply_delta`. It fails with SQLSTATE `42501` and a hint. A schema that belongs to a superuser, or to the installing role, is accepted.

### pg_tle

[pg_tle](https://github.com/aws/pg_tle) installs an extension from SQL, without access to the server's files. Load pg_tle with `shared_preload_libraries = 'pg_tle'`. A superuser enables it once per database and lets the installing role use it:

```sql
create extension pg_tle;
grant pgtle_admin to app_owner;   -- the role that installs
```

Then, as that role in psql, register the SQL file and create the extension:

```sql
\set body `cat pg_crdt--0.0.1.sql`
select pgtle.install_extension(
  name => 'pg_crdt',
  version => '0.0.1',
  description => 'CRDTs',
  ext => :'body',
  schema => 'crdt'
);
create extension pg_crdt;
```

pg_tle refuses a name that also has a control file on the server. Without psql, pass the file's contents as the `ext` argument from your own tooling. The schema is `crdt`, set in `install_extension`.

### Create extension

Copy both files into the server's extension directory, then create the extension in each database:

```bash
cp pg_crdt.control pg_crdt--0.0.1.sql \
  "$(pg_config --sharedir)/extension/"
```

```sql
create extension pg_crdt;
```

Do not add `with schema`: the control file fixes the schema to `crdt`. Any role with `CREATE` on the database can run this, because `superuser = false`. The role becomes the owner of the objects.
