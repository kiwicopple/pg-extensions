# Install

Install `pg_crdt` with `create extension` when the extension files are on the server, through pg_tle when they are not, or by running its SQL file directly. The database owner can do any of these: the extension needs no superuser and no C code.

> **Warning: dropping the extension drops your data.** `crdt.pn` is a type that belongs to the extension. `drop extension pg_crdt` fails while any column uses it, and `drop extension pg_crdt cascade` **drops those columns**, with their data. The collaborative text documents live in the extension's own tables (`crdt.ydoc_*`), so **dropping the extension drops every document**, even without `cascade`, unless a foreign key of yours points at them. Read [Uninstall](#uninstall) before you remove the extension from a database that has data in it. The same holds for `drop schema crdt cascade` after a direct install.

## Choose a method

| Method | Use it when |
| --- | --- |
| [Direct install](#install-directly) | You want the functions without an extension object: a migration, a test database, any Postgres 16 or later. |
| [pg_tle](#pg_tle) | You cannot touch the server's files, but pg_tle is loaded (for example Amazon RDS, Aurora or Supabase). |
| [Create extension](#create-extension) | You can copy files into the server's extension directory. |

Use one method per database. Each creates the schema `crdt` with the type, the functions, the aggregate, and the tables and sequences that hold collaborative text documents.

## Requirements

- Postgres 16, 17 or 18. The test suite runs on all three, with pg_tle and with the control file, in Docker (`./test/docker.sh`).
- No other extension, no C code and no superuser. The extension is SQL and PL/pgSQL.
- `CREATE` on the database, because the install creates the schema `crdt`.

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

- `pg_dump` dumps the functions, the domain, the aggregate and the `crdt.ydoc_*` tables, with their documents, as ordinary objects. Restoring into an empty database works.
- There is no upgrade path. To reinstall, run `drop schema crdt cascade;`. That drops the domain, and with it every column of type `crdt.pn`, with its data.

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

## Backups

With `create extension` (pg_tle or the control file), `pg_dump` writes `create extension pg_crdt` instead of the objects. The collaborative text tables and their sequences are marked as the extension's configuration (`pg_extension_config_dump`), so the dump still contains every document, and a restore sets the sequences after them: new documents get new ids. Restoring needs the extension available on the target server (the files, or pg_tle with the extension registered). After a direct install, the tables are ordinary tables and are dumped like yours.

Include the schema `crdt` in your dumps: a dump of only `public` (`pg_dump -n public`) has rows that point at documents it does not contain.

## Check the install

```sql
select crdt.pn_value(crdt.pn_empty());
-- 0
select crdt.pn_value(
  crdt.pn_increment(crdt.pn_empty(), 'alice', 3)
);
-- 3
```

If a query fails with `schema "crdt" does not exist`, the install did not run in this database.

## Privileges after install

The install removes the default grants (and the installing role's default privileges) from every function, table and sequence in `crdt`, then grants `EXECUTE` on the whole API and `USAGE` on the schema to `public`. The PN-Counter functions are pure or read only the caller's own settings, so none needs privileges of its own. Who may write which rows is your decision: see [Accept writes from untrusted clients](guides/security.md).

The `crdt.ydoc_*` tables and sequences have no grants at all. The `ydoc_` functions run with the caller's privileges, so they fail with `42501` until you grant the tables to the role that owns your wrapper functions. See [Set up the roles and grants](guides/collaborative-text.md#set-up-the-roles-and-grants).

## Always qualify names

Call every function as `crdt.pn_merge(...)` and write the column type as `crdt.pn`. You do not need `crdt` on `search_path`, and you should not add it: the functions are written so that they work under the `search_path = pg_catalog, pg_temp` that maintenance commands such as `VACUUM` and `REINDEX` use for index expressions and generated columns.

## Uninstall

Dropping the extension removes the type and the collaborative text tables. Postgres refuses while a column, default, generated column, index or constraint uses the type, or while a foreign key references `crdt.ydoc_docs`. It does not refuse because the tables hold documents: **a plain `drop extension pg_crdt` drops every document** when nothing of yours references them. Copy out the text you want to keep first, for example into a `text` column with `update posts set body = crdt.ydoc_value(body_doc)`.

Then, per table:

1. Copy the state to plain `jsonb`. The values do not change; only the column type does.
2. Remove the objects that call a `crdt` function: column defaults, generated columns, expression indexes and check constraints, and foreign keys to `crdt.ydoc_docs`.
3. Drop the extension.

This is a fragment: replace the table and column names with your own.

```sql
alter table posts alter column likes type jsonb;
alter table posts alter column likes drop default;
-- also drop generated columns, indexes and constraints that call crdt
drop extension pg_crdt;
```

`drop extension` leaves the empty schema `crdt` behind, because `create extension` created the schema before it ran the script. Remove it with `drop schema crdt;` when you no longer need it.

A direct install has no extension object. After steps 1 and 2, `drop schema crdt cascade;` removes the functions, the aggregate, the type and the document tables. It drops nothing of yours, because nothing depends on them any more.

Do not use `cascade` before you have copied the data: it drops the columns, and the foreign keys to the documents along with the documents. A plain `drop extension` is a safety check for your columns: it fails with SQLSTATE `2BP01` and names the dependent column, default, index or foreign key.
