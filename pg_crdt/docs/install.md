# Install

Use one method per database. For a local trial, run the SQL file directly. For an extension managed by Postgres, use pg_tle or the server's extension directory.

Run file commands from the `pg_crdt/` directory. The extension needs no superuser privileges, but preparing pg_tle or copying server files can require an administrator. Use a UTF8 database for collaborative text.

Already using a development build with table-backed documents? Read the [scope and migration note](../research/scope.md#existing-installations) first. This source change is not an in-place upgrade.

## Choose a method

| Method | Use it when |
| --- | --- |
| [Direct install](#install-directly) | You want the functions without an extension object: a migration, a test database, any Postgres 16 or later. |
| [pg_tle](#pg_tle) | You cannot touch the server's files, but pg_tle is loaded (for example Amazon RDS, Aurora or Supabase). |
| [Create extension](#create-extension) | You can copy files into the server's extension directory. |

Use one method per database. Each creates the schema `crdt`, the column types `crdt.pn` and `crdt.yseq`, their functions and aggregates. The extension owns no document tables or sequences.

## Requirements

- Postgres 16, 17 or 18. The test suite runs on all three, with pg_tle and with the control file, in Docker (`./test/docker.sh`).
- No other extension, no C code and no superuser. The extension is SQL and PL/pgSQL.
- `CREATE` on the database, because the install creates the schema `crdt`.
- A UTF8 database for the `yseq_` column functions. The extension installs in any encoding, but in another one the `yseq_` functions that send deleted characters fail.

The extension is two files: [`pg_crdt.control`](../pg_crdt.control) and [`pg_crdt--0.0.1.sql`](../pg_crdt--0.0.1.sql). The control file sets `schema = crdt`, `relocatable = false` and `superuser = false`.

### The schema guard

The install refuses to use a `crdt` schema that already exists when another non-superuser role owns it, or when any other role has `CREATE` on it. Either role could drop or replace the functions, and with them the domain check and the identity check in `pn_apply_delta`. It fails with SQLSTATE `42501` and a hint. A schema that belongs to a superuser, or to the installing role, is accepted.

## Install directly

Run the SQL file once in each database:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f pg_crdt--0.0.1.sql
```

The file creates the schema `crdt` itself. The role you connect as owns every object.

Without an extension object, two things differ:

- `pg_dump` dumps the functions, the domains, the aggregates as ordinary objects, alongside your application tables. Restoring into an empty database works.
- There is no upgrade path. Do not reinstall over an existing schema. Follow [Uninstall](operations/uninstall.md) to preserve data before removing it.

## pg_tle

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

## Create extension

Copy both files into the server's extension directory, then create the extension in each database:

```bash
cp pg_crdt.control pg_crdt--0.0.1.sql \
  "$(pg_config --sharedir)/extension/"
```

```sql
create extension pg_crdt;
```

Do not add `with schema`: the control file fixes the schema to `crdt`. Any role with `CREATE` on the database can run this, because `superuser = false`. The role becomes the owner of the objects.


## Check the install

```sql
select crdt.pn_value(crdt.pn_empty());
-- 0
select crdt.yseq_value(crdt.yseq_new());
-- empty text
```

If Postgres reports that schema `crdt` does not exist, check that you installed into the database you are connected to.

## Privileges after install

Every role can use the schema and call the functions. Calling a function returns a value; your table privileges decide who can store it. Use wrappers for untrusted client input. The extension does not authenticate users or authorize rows.

Always qualify extension names with `crdt.`. Do not add it to `search_path`. See [Identity settings and shared conventions](reference/shared.md).

## Backups

Read [Back up and restore](operations/backups.md). The CRDT state lives in your own table columns.

## Uninstall

Dropping the extension with `cascade` can delete dependent columns and their data. Follow [Uninstall](operations/uninstall.md) to preserve them first.

## Next

Try [your first counter](get-started/quickstart.md) or [your first shared document](get-started/text.md).
