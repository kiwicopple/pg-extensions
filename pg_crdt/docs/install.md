# Install

pg_crdt is one SQL file. You need Postgres 16, 17 or 18 and a database role allowed to create a schema and its objects. For shared text, use a database with UTF8 encoding.

Choose one method below. Install into a database that does not already have pg_crdt; this version has no upgrade script.

## Paste into a SQL editor

Copy the complete [pg_crdt SQL file](https://raw.githubusercontent.com/kiwicopple/pg-extensions/main/pg_crdt/pg_crdt--0.0.1.sql) into your database's SQL editor. Put `begin;` before it and `commit;` after it, then run the whole script together.

This installs everything in a transaction: either all of it succeeds or none of it does. If an error leaves the transaction open, run `rollback;` before trying again.

## Or use your terminal

With `curl` and the Postgres client `psql` installed, replace the connection string and run:

```bash
curl -fsSL https://raw.githubusercontent.com/kiwicopple/pg-extensions/main/install.sh -o install-pg-extension.sh &&
sh install-pg-extension.sh pg_crdt \
  --database 'postgresql://postgres@localhost:5432/postgres'
```

The installer downloads the default version from `main` and runs it in one transaction. It refuses an existing installation.

## Check it worked

```sql
select crdt.pn_value(crdt.pn_empty());
-- 0
select crdt.yseq_value(crdt.yseq_new());
-- empty text
```

The functions and column types live in the `crdt` schema. Keep the `crdt.` prefix when using them.

For a pinned version, migration file, different owner or `create extension`, see [installation options](reference/installation.md).

Next: [try a counter](get-started/quickstart.md).
