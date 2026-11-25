# Install SQL packages

Install functions directly in your database. You need no compiler, server filesystem access or pg_tle. Choose a package:

| Package | SQL editor instructions | Schema | Postgres |
| --- | --- | --- | --- |
| `pg_idkit` | [Install ID generators](pg_idkit/docs/install.md) | `extensions` | 13+ |
| `pg_crdt` | [Install counters and collaborative text](pg_crdt/docs/install.md) | `crdt` | 16–18 |
| `pg_permissions` | [Install authorization](pg_permissions/docs/install.md) | `permissions` | 16–18 |
| `pg_validate` | [Install validators](pg_validate/docs/install.md) | `validate` | 16–18 |

Each guide starts with a SQL file you can copy into your database's SQL editor. To install from a terminal, you need `curl` and the Postgres client, `psql`. Replace the connection string and package name:

```bash
curl -fsSL https://raw.githubusercontent.com/kiwicopple/pg-extensions/main/install.sh -o install-pg-extension.sh &&
sh install-pg-extension.sh pg_crdt \
  --database 'postgresql://postgres@localhost:5432/postgres'
```

The username in the URI is the login role. Leave out the password to use the `psql` password prompt or `.pgpass`. A libpq connection string such as `host=localhost dbname=app user=app_owner` also works. The installer uses `DATABASE_URL` when you omit `--database`; it requires an explicit connection rather than guessing a local database.

The login role owns the objects by default. It needs permission to create the package's schema and objects. To use another existing owner role, add `--role app_owner`. This uses `SET LOCAL ROLE`, so the login must be allowed to assume it. The script does not create roles or grant application permissions. See [Postgres role switching](https://www.postgresql.org/docs/current/sql-set-role.html) for the permission rules.

## Versions and downloads

By default, the installer reads the package's `default_version` from its control file on `main`. This means the repository's current default, not a GitHub release or a database.dev package. Select a specific SQL file with `--version`:

```bash
sh install-pg-extension.sh pg_idkit \
  --database "$DATABASE_URL" \
  --role app_owner \
  --version 0.0.5
```

For a reproducible migration, add `--ref` with a full Git commit SHA. `--version` chooses the SQL filename; `--ref` pins the source contents. To pin the installer too, replace `main` in its download URL with the same commit (one containing `install.sh`).

Save SQL for review, a SQL editor or your migration runner:

```bash
sh install-pg-extension.sh pg_validate \
  --version 0.0.1 \
  --output pg_validate-install.sql
```

`--output` does not require `psql` or connect to a database. It refuses to overwrite a file. The output includes `begin;`, `commit;`, installation checks and any schema or role setup. Run the entire file; if your migration runner manages transactions, let it own the transaction instead of nesting the file's `begin` and `commit`.

Run `sh install-pg-extension.sh --help` for all options. Install multiple packages with separate invocations; each has its own version and transaction.

## What the installer does

It downloads the complete SQL before connecting and runs it with `psql -X` and `ON_ERROR_STOP`, inside one transaction. Any SQL error rolls back the installation. It checks the minimum Postgres version and refuses an existing extension or package schema. `pg_idkit` can share an existing `extensions` schema, but the installer refuses to replace any of its function names there.

The result is ordinary functions, types and tables, depending on the package. `pg_dump` includes them. There is no `pg_extension` entry, so `alter extension` and `drop extension` do not manage this installation. Follow the package's upgrade instructions for an existing database. The installer never drops data or automatically upgrades a package.

## Troubleshooting

| Message | Next step |
| --- | --- |
| `psql` is missing | Install the Postgres client, or use `--output` and a SQL editor. |
| Connection or password error | Use the provider's Postgres connection string, including required SSL options. Check its host, database and login role. |
| Permission denied for database or schema | Connect as the installing owner, or have the database administrator grant that owner the required `CREATE` privileges. |
| Permission denied to set role | Omit `--role` to install as the login, or use a login allowed to assume that owner role. |
| Schema or functions already exist | Check whether this database is already installed. Use its documented upgrade procedure; do not drop a schema containing application data to retry. |
| SQL download failed | Check the package version and Git ref. Failed downloads never run SQL against the database. |

## Developing the installer

Run the CLI and failure-path checks with `python3 -m unittest discover -s test -p 'test_install.py'`. To include real SQL, role ownership, reinstall and rollback checks against a disposable Docker database, set `INSTALL_TEST_IMAGE=postgres:17` for the same command. The tests create and remove their own container and use the checked-out SQL files, without connecting to an existing database.
