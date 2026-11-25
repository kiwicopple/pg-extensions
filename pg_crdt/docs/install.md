# Install

Run one SQL file in your database to start using `pg_crdt`. You can paste it into a SQL editor or use the terminal installer below. No server files, compiler, Docker or pg_tle setup is needed.

You need Postgres 16, 17 or 18 and a database role allowed to create a schema and its objects. The installing role owns the objects. Use one installation method per database, and start with a fresh installation.

Use a UTF8 database for collaborative text. For an older development build with table-backed documents, read the [migration note](../research/scope.md#existing-installations) first.

## Paste into a SQL editor

1. Open the [SQL file for 0.0.1](https://raw.githubusercontent.com/kiwicopple/pg-extensions/main/pg_crdt/pg_crdt--0.0.1.sql) and copy its entire contents.
2. Open your database's SQL editor, connected as the installing role.
3. Paste the file between `begin;` and `commit;` as shown below, then run the whole script together. Replace the comment with the file contents.

```sql
begin;
-- Paste the complete pg_crdt--0.0.1.sql file here.

commit;
```

This creates the `crdt` schema and its objects in one transaction. An error rolls the installation back. If your editor leaves the transaction open after an error, run `rollback;` before trying again.

## Install from your terminal

With `curl` and the Postgres client (`psql`) installed, copy this block and replace the connection string with your database's connection string:

```bash
curl -fsSL https://raw.githubusercontent.com/kiwicopple/pg-extensions/main/install.sh -o install-pg-extension.sh &&
sh install-pg-extension.sh pg_crdt \
  --database 'postgresql://postgres@localhost:5432/postgres'
```

The username in the connection string is your login role. Omit the password to let `psql` prompt for it, or use `.pgpass`. You can also pass `--database "$DATABASE_URL"` if you already keep your connection string in that variable.

The installer downloads the latest default version declared in `pg_crdt.control` on `main`, then runs the full SQL in one transaction. It stops on errors and refuses an existing installation. It does not upgrade or remove objects.

### Choose a version or owner role

Add `--version 0.0.1` to install a specific SQL file. Add `--role app_owner` only when you want an existing role to own the objects; your login must be allowed to `SET ROLE` to it, and that role needs installation privileges:

```bash
sh install-pg-extension.sh pg_crdt \
  --database "$DATABASE_URL" \
  --version 0.0.1 \
  --role app_owner
```

To save ready-to-run SQL for an editor or migration without connecting to Postgres:

```bash
sh install-pg-extension.sh pg_crdt \
  --version 0.0.1 \
  --output pg_crdt-install.sql
```

The saved file already includes the transaction and schema setup. Run the entire file. For reproducible downloads, also pass `--ref` with a full Git commit SHA; a version selects a filename, while a commit pins its contents. See [installer options](https://github.com/kiwicopple/pg-extensions/blob/main/INSTALL.md).

## Check the install

```sql
select crdt.pn_value(crdt.pn_empty());
-- 0
select crdt.yseq_value(crdt.yseq_new());
-- empty text
```

If Postgres reports that schema `crdt` does not exist, check that you installed into the database you are connected to.

## Install directly

If you already have the repository, run this from `pg_crdt/`:

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -1 \
  -f pg_crdt--0.0.1.sql
```

The SQL file creates `crdt` itself, with column types, functions and aggregates. It owns no document tables or sequences. Direct installs are ordinary database objects: `pg_dump` includes them alongside your tables, and `alter extension` does not manage them. There is no in-place upgrade; do not reinstall over an existing schema. Follow [Uninstall](operations/uninstall.md) to preserve data before removing it.

## Privileges after install

Every role can use the schema and call the functions. Calling a function returns a value; your table privileges decide who can store it. Use wrappers for untrusted client input. The extension does not authenticate users or authorize rows.

Always qualify extension names with `crdt.`. Do not add it to `search_path`. See [Identity settings and shared conventions](reference/shared.md).

## Backups

Read [Back up and restore](operations/backups.md). The CRDT state lives in your own table columns.

## Uninstall

Dropping the extension with `cascade` can delete dependent columns and their data. Follow [Uninstall](operations/uninstall.md) to preserve them first.

## Next

Try [your first counter](get-started/quickstart.md) or [your first shared document](get-started/text.md).

## Advanced: extension management

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
