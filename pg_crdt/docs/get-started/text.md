# Try shared text

Store a note that two people can edit independently. Run these SQL blocks in order as the table owner in a UTF8 test database with [pg_crdt installed](../install.md).

The text type, `crdt.yseq`, is **experimental**. Each edit rewrites the entire stored value, including information about past deletions. Start with short notes saved occasionally. See [storage limits](../reference/storage.md#text) for the costs.

## Create a note

`yseq_new()` gives each note a unique document id. `yseq_insert` adds text; `yseq_value` reads the visible result.

```sql
create table notes (
  id bigint primary key,
  body crdt.yseq not null default crdt.yseq_new()
);
insert into notes (id) values (1);

update notes
set body = crdt.yseq_insert(body, 0, 'Hello world', replica => 'alice')
where id = 1;

select crdt.yseq_value(body) from notes where id = 1;
-- Hello world
```

`replica` names the writer. Text positions start at zero and count Unicode code points. For example, an emoji can count as one position here but two JavaScript string units.

## Combine two edits

This query makes two copies of the same note. Bob adds a comma and Carol adds an exclamation mark. Merge keeps both edits:

```sql
select crdt.yseq_value(crdt.yseq_merge(
  crdt.yseq_insert(body, 5, ',', replica => 'bob'),
  crdt.yseq_insert(body, 11, '!', replica => 'carol')
)) as merged
from notes
where id = 1;
-- Hello, world!
```

This query only displays the result. To store changes, use the edit or merge function inside an `update`, as in the first example. Merge full states only from trusted servers; client edits need `yseq_apply` with [access checks](../guides/app.md).

## Save a form

For a text box with a Save button, use `yseq_set`. Keep the full document state that the form opened with. This is its **base**: the saved copy that tells Postgres what the user changed.

Your server reads the text and base together, then passes the edited text and that base to `yseq_set` in one update. Without the original base, saving an old form can undo someone else's changes. After saving, reload the text and base together and show the merged result.

The base is the whole state, so every save sends it back. The [form example](../reference/application.md#forms) includes the SQL setup and a working save.

## Before building a live editor

There is no ready-made browser client, rich text, shared cursors or undo. The format is not compatible with Yjs. A live editor needs its own sync code and a separate writer key for each independent editor. Reusing a key can lose text. See [live editor integration](../reference/application.md#live-editors).

Next: [application principles](../guides/app.md).
