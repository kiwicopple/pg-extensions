# Install

Install `pg_validate` with `create extension` when the extension files are on the server, through pg_tle when they are not, or by running its SQL file directly. The database.dev package is not published yet.

## Choose a method

| Method | Use it when |
| --- | --- |
| [Create extension](#create-extension) | You can copy files into the server's extension directory. |
| [pg_tle](#pg_tle) | You cannot touch the server's files, but pg_tle is loaded (Supabase, Amazon RDS, Aurora). |
| [Direct install](#install-directly) | You want the functions without an extension object, for example in a test database. |
| [Docker](#docker) | You want a local database for trying the extension. |

Use one method per database. Each creates the schema `validate` with the validators, the registry table and its functions.

## Requirements

- Postgres 16, 17 or 18.
- No other extension, no C code and no superuser. The extension is SQL and PL/pgSQL.
- `CREATE` on the database, because the extension creates the schema `validate`.

The extension is two files: [`pg_validate.control`](../pg_validate.control) and [`pg_validate--0.0.1.sql`](../pg_validate--0.0.1.sql). The control file sets `schema = validate`, `relocatable = false` and `superuser = false`.

## Create extension

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

## pg_tle

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

## Install directly

Run the SQL file once in each database:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f pg_validate--0.0.1.sql
```

The file creates the schema `validate` itself. The role you connect as owns every object.

Without an extension object, two things differ:

- `pg_dump` dumps the functions, the registry table and all of its rows, built-in rows included, as ordinary objects. Restoring into an empty database works.
- There is no upgrade path. To reinstall, run `drop schema validate cascade;`, which also removes registered formats and any constraint that calls a validator.

On Supabase, prefer pg_tle (or database.dev, once published). Pasting the file into the SQL editor also works.

## Docker

The directory [`docker/`](../docker/README.md) has images for Postgres 16, 17 and 18 with pg_tle preloaded. From the `pg_validate/` directory:

```bash
cd docker
docker compose build
docker compose up -d --wait pg17
cd ..
psql -h localhost -p 54337 -U postgres -v ON_ERROR_STOP=1 \
  -f pg_validate--0.0.1.sql
```

The containers use `trust` authentication on 127.0.0.1. Use them for local tests only.

## Check the install

```sql
select validate.email(value => 'ada@example.com');
-- true
select count(*)
from validate.list_formats()
where builtin;
-- 54: 44 validators and 10 JSON Schema names
```

If the first query fails with `schema "validate" does not exist`, the install did not run in this database.

## Search path

Call every function with its schema, as `validate.email(...)`. Do not add `validate` to `search_path`. Some names are also names in `pg_catalog`: with `validate` on the path, `format('%s', x)` can resolve to `validate.format(name, value)` instead of the built-in `format`, and `uuid(x)` to a validator instead of a cast.
