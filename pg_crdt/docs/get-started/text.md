# Your first shared document

Create a text column, edit it as two writers, and combine two independent copies. This example runs as the database owner in an empty UTF8 test database with [pg_crdt installed](../install.md). It does not expose writes to browsers.

`crdt.yseq` is experimental. Every edit rewrites the whole document state, including retained deletion metadata. Start with short documents and occasional saves; [read the storage and sync limits](../text/limits.md) before choosing it for your application.

## Create a document

```sql
create table notes (
  id bigint primary key,
  body crdt.yseq not null default crdt.yseq_new()
);
insert into notes (id) values (1);

update notes
set body = crdt.yseq_insert(body, 0, 'Hello world', replica => 'alice')
where id = 1;

update notes
set body = crdt.yseq_insert(body, 5, ',', replica => 'bob')
where id = 1;

select crdt.yseq_value(body) from notes where id = 1;
-- Hello, world
```

`yseq_new()` gives the document a unique id. Each edit runs inside one `update`, so Postgres locks the row while it changes. Positions count Unicode code points, starting at zero; JavaScript string offsets need conversion.

## Merge independent changes

This query creates two copies from the current document: Carol adds an exclamation mark, and Dave adds a prefix. Merging keeps both changes.

```sql
select crdt.yseq_value(crdt.yseq_merge(
  crdt.yseq_insert(body, 12, '!', replica => 'carol'),
  crdt.yseq_insert(body, 0, '> ', replica => 'dave')
)) as merged
from notes
where id = 1;
-- > Hello, world!
```

The query shows the merged result without storing it. To save incoming state from a trusted peer, merge it in the `set` clause of an `update`. A browser's edits must go through a wrapper using `yseq_apply`; `yseq_merge` does not enforce writer ownership.

## Next

[Save changes from a form](../text/forms.md) builds a small application with access checks. It uses separate `articles` tables, so you can keep the `notes` table from this example.
