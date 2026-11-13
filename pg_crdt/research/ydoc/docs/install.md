# Install

Choose one installation method per database: run the SQL file directly, use pg_tle, or copy the extension files to the server and run `create extension`. `pg_crdt` itself needs no superuser privileges or C code. Preparing pg_tle or copying server files may require an administrator; the steps below explain who runs each command.

> **Warning: dropping the extension drops your data.** `crdt.pn` and `crdt.yseq` are types that belong to the extension. `drop extension pg_crdt` fails while any column uses them, and `drop extension pg_crdt cascade` **drops those columns**, with their data (and generated columns that call `crdt.yseq_value`). The collaborative text documents live in the extension's own tables (`crdt.ydoc_*`), so **dropping the extension drops every document**, even without `cascade`, unless a foreign key of yours points at them. Read [Uninstall](#uninstall) before you remove the extension from a database that has data in it. The same holds for `drop schema crdt cascade` after a direct install.

## Choose a method

| Method | Use it when |
| --- | --- |
| [Direct install](#install-directly) | You want the functions without an extension object: a migration, a test database, any Postgres 16 or later. |
| [pg_tle](#pg_tle) | You cannot touch the server's files, but pg_tle is loaded (for example Amazon RDS, Aurora or Supabase). |
| [Create extension](#create-extension) | You can copy files into the server's extension directory. |

Use one method per database. Each creates the schema `crdt` with the types (`crdt.pn`, and `crdt.yseq` for collaborative text in a column), the functions, the aggregates, and the tables and sequences that hold collaborative text documents.

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

- `pg_dump` dumps the functions, the domains, the aggregates and the `crdt.ydoc_*` tables, with their documents, as ordinary objects. Restoring into an empty database works.
- There is no upgrade path. To reinstall, run `drop schema crdt cascade;`. That drops the domains, and with them every column of type `crdt.pn` or `crdt.yseq`, with its data.

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

If you installed with `create extension`, the dump contains a `create extension pg_crdt` command. Make the extension available on the target server before restoring: either copy its files or register it with pg_tle.

The dump also includes your collaborative text documents. The extension marks its document tables and sequences for backup with `pg_extension_config_dump`. Restoring resets the sequences so new documents get new ids.

After a direct SQL install, the extension's tables are ordinary tables. Postgres dumps and restores them like your own tables.

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

After installation, every role can use the `crdt` schema and call the public API: the installer grants `USAGE` on the schema and `EXECUTE` on the functions to `public`. Before applying those grants, it removes existing grants, including privileges inherited from the installing role's defaults.

Calling a counter function does not write to a table. Your table privileges and wrapper functions decide who can save its result. See [Accept writes from untrusted clients](guides/security.md).

The `crdt.ydoc_*` tables and sequences have no grants at all. The `ydoc_` functions run with the caller's privileges, so they fail with `42501` until you grant the tables to the role that owns your wrapper functions. See [Set up the roles and grants](guides/collaborative-text.md#set-up-the-roles-and-grants).

## Always qualify names

Call every function as `crdt.pn_merge(...)` and write the column type as `crdt.pn`. You do not need `crdt` on `search_path`, and you should not add it: the functions are written so that they work under the `search_path = pg_catalog, pg_temp` that maintenance commands such as `VACUUM` and `REINDEX` use for index expressions and generated columns.

## Uninstall

Dropping the extension removes the types (`crdt.pn`, `crdt.yseq`) and the collaborative text tables. Postgres refuses, with `2BP01`, while a column, default, generated column, index, constraint or SQL-standard function uses a type or a function of the extension, or while a foreign key references `crdt.ydoc_docs`. It does not refuse because the tables hold documents: **a plain `drop extension pg_crdt` drops every document** when nothing of yours references them. Copy out the text you want to keep first, for example into a `text` column with `update posts set body = crdt.ydoc_value(body_doc)`.

Then, per table:

1. Keep the text of a `crdt.yseq` column: turn its generated text column into an ordinary one (`alter table posts alter column body_text drop expression`), or copy `crdt.yseq_value(body)` into a `text` column.
2. Copy the state to plain `jsonb`. The values do not change; only the column type does.
3. Remove the objects that call a `crdt` function: column defaults, generated columns, expression indexes and check constraints, your own SQL-standard functions that read the column, and foreign keys to `crdt.ydoc_docs`.
4. Drop the extension.

This is a fragment: replace the table and column names with your own.

```sql
alter table posts alter column body_text drop expression;
alter table posts alter column body type jsonb;
alter table posts alter column body drop default;
alter table posts alter column likes type jsonb;
alter table posts alter column likes drop default;
-- also drop generated columns, indexes and constraints that call crdt
drop extension pg_crdt;
```

`drop extension` leaves the empty schema `crdt` behind, because `create extension` created the schema before it ran the script. Remove it with `drop schema crdt;` when you no longer need it.

A direct install has no extension object. After steps 1 to 3, `drop schema crdt cascade;` removes the functions, the aggregates, the types and the document tables. It drops nothing of yours, because nothing depends on them any more.

Do not use `cascade` before you have copied the data: it drops the columns, and the foreign keys to the documents along with the documents. A plain `drop extension` is a safety check for your columns: it fails with SQLSTATE `2BP01` and names the dependent column, default, index or foreign key.
