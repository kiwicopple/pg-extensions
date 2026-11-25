# Install

Run one SQL file in your database to start using `pg_validate`. You can paste it into a SQL editor or use the terminal installer below. No server files, compiler, Docker or pg_tle setup is needed.

You need Postgres 16, 17 or 18 and a database role allowed to create a schema and its objects. The installing role owns the objects. Use one installation method per database, and start with a fresh installation.

## Paste into a SQL editor

1. Open the [SQL file for 0.0.1](https://raw.githubusercontent.com/kiwicopple/pg-extensions/main/pg_validate/pg_validate--0.0.1.sql) and copy its entire contents.
2. Open your database's SQL editor, connected as the installing role.
3. Paste the file between `begin;` and `commit;` as shown below, then run the whole script together. Replace the comment with the file contents.

```sql
begin;
-- Paste the complete pg_validate--0.0.1.sql file here.

commit;
```

This creates the `validate` schema and its objects in one transaction. An error rolls the installation back. If your editor leaves the transaction open after an error, run `rollback;` before trying again.

## Install from your terminal

With `curl` and the Postgres client (`psql`) installed, copy this block and replace the connection string with your database's connection string:

```bash
curl -fsSL https://raw.githubusercontent.com/kiwicopple/pg-extensions/main/install.sh -o install-pg-extension.sh &&
sh install-pg-extension.sh pg_validate \
  --database 'postgresql://postgres@localhost:5432/postgres'
```

The username in the connection string is your login role. Omit the password to let `psql` prompt for it, or use `.pgpass`. You can also pass `--database "$DATABASE_URL"` if you already keep your connection string in that variable.

The installer downloads the latest default version declared in `pg_validate.control` on `main`, then runs the full SQL in one transaction. It stops on errors and refuses an existing installation. It does not upgrade or remove objects.

### Choose a version or owner role

Add `--version 0.0.1` to install a specific SQL file. Add `--role app_owner` only when you want an existing role to own the objects; your login must be allowed to `SET ROLE` to it, and that role needs installation privileges:

```bash
sh install-pg-extension.sh pg_validate \
  --database "$DATABASE_URL" \
  --version 0.0.1 \
  --role app_owner
```

To save ready-to-run SQL for an editor or migration without connecting to Postgres:

```bash
sh install-pg-extension.sh pg_validate \
  --version 0.0.1 \
  --output pg_validate-install.sql
```

The saved file already includes the transaction and schema setup. Run the entire file. For reproducible downloads, also pass `--ref` with a full Git commit SHA; a version selects a filename, while a commit pins its contents. See [installer options](https://github.com/kiwicopple/pg-extensions/blob/main/INSTALL.md).

## Check the install

```sql
select validate.email(value => 'ada@example.com');
-- true
select count(*)
from validate.list_formats()
where builtin;
-- 42: 37 validators and 5 JSON Schema names
```

If the first query fails with `schema "validate" does not exist`, the install did not run in this database.

## Search path

Call every function with its schema, as `validate.email(...)`. Do not add `validate` to `search_path`. Some names are also names in `pg_catalog`: with `validate` on the path, `format('%s', x)` can resolve to `validate.format(name, value)` instead of the built-in `format`, and `uuid(x)` to a validator instead of a cast.
## Install directly

If you already have the repository, run this from `pg_validate/`:

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -1 \
  -f pg_validate--0.0.1.sql
```

The SQL creates the `validate` schema with validators and the format registry. The installing role owns the registry and can [allow other roles to register formats](registry.md#allow-a-role-to-register-formats).

A direct install creates ordinary database objects. `pg_dump` includes the functions, registry and all its rows. `alter extension` does not manage them. There is no in-place upgrade; do not rerun the install over an existing schema. Dropping `validate` with `cascade` also removes registered formats and constraints that use validators, so preserve them before rebuilding an installation.

## Advanced: extension management and Docker

Use pg_tle or server extension files when you need a `pg_extension` entry, or Docker for a local test database. Choose one installation method per database. Commands below run from `pg_validate/` in a repository checkout.

### Create extension

Copy both files into the server's extension directory, then create the extension in each database:

```bash
cp pg_validate.control pg_validate--0.0.1.sql \
  "$(pg_config --sharedir)/extension/"
```

```sql
create extension pg_validate;
```

Do not add `with schema`: the control file fixes the schema to `validate`. Any role with `CREATE` on the database can run this, because `superuser = false`. The role becomes the extension owner and owns the registry. It can register formats and let other roles do so; see [Custom formats](registry.md#allow-a-role-to-register-formats).

`drop extension pg_validate` removes the functions and the registry. The schema stays, because `create extension` created it before running the script; drop it with `drop schema validate` when it is empty.

### pg_tle

[pg_tle](https://github.com/aws/pg_tle) installs an extension from SQL, without access to the server's files. Load pg_tle with `shared_preload_libraries = 'pg_tle'`. A superuser enables it once per database and lets the installing role use it:

```sql
create extension pg_tle;
grant pgtle_admin to app_owner;   -- the role that installs
```

Then, as that role in psql, register the SQL file and create the extension:

```sql
\set body `cat pg_validate--0.0.1.sql`
select pgtle.install_extension(
  name => 'pg_validate',
  version => '0.0.1',
  description => 'Validators for common string formats',
  ext => :'body',
  schema => 'validate'
);
create extension pg_validate;
```

pg_tle refuses a name that also has a control file on the server. The test suite runs this sequence as a non-superuser on Postgres 16, 17 and 18 with pg_tle 1.5.3.

### Docker

The directory [`docker/`](../docker/README.md) has images for Postgres 16, 17 and 18 with pg_tle preloaded. From the `pg_validate/` directory:

```bash
cd docker
docker compose build
docker compose up -d --wait pg17
cd ..
psql -h localhost -p 54337 -U postgres -X -v ON_ERROR_STOP=1 -1 \
  -f pg_validate--0.0.1.sql
```

The containers use `trust` authentication on 127.0.0.1. Use them for local tests only.
