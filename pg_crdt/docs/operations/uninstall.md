# Uninstall

Back up the database first. `drop extension pg_crdt cascade` can delete every column of type `crdt.pn` or `crdt.yseq`, along with dependent generated columns and indexes. A direct install's `drop schema crdt cascade` has the same risk.

## Preserve the data

1. If you need readable text after removal, copy `yseq_value(body)` into an ordinary `text` column, or remove the generation expression from an existing stored text column.
2. Preserve the full CRDT state as ordinary `jsonb` if you may need its history. Plain text or a counter's visible number is not a substitute for that state.
3. Remove defaults, generated expressions, indexes, constraints and application functions that depend on the extension. Convert CRDT columns to `jsonb`.
4. Drop the extension without `cascade`. If Postgres reports SQLSTATE `2BP01`, inspect the dependency it names before continuing.

This is a fragment for a table with `body`, stored generated `body_text`, and `likes` columns. Adapt it to your schema and inspect all dependencies first:

```sql
alter table posts alter column body_text drop expression;
alter table posts alter column body drop default;
alter table posts alter column likes drop default;
-- Remove other indexes, constraints and functions that depend on crdt.
alter table posts alter column body type jsonb;
alter table posts alter column likes type jsonb;
drop extension pg_crdt;
```

An extension install can leave an empty `crdt` schema; remove it with `drop schema crdt` when no longer needed. A direct SQL install has no extension object. After removing dependencies, remove its objects with `drop schema crdt cascade` only after confirming your application data is preserved.

## Earlier table-backed builds

The `ydoc_` tables belonged to the old extension. Dropping that extension can delete every document even without `cascade` when no application foreign key blocks it. Use the [archived uninstall guide](../../research/ydoc/docs/install.md#uninstall); the column procedure above is not a migration for those documents. There is no automatic conversion to `crdt.yseq`.
