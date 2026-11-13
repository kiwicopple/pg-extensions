# Search documents

Use a stored generated text column and a full-text index to search a `crdt.yseq` document. The [application setup](../examples/text-app.sql) already creates both on `articles`; do not create them again if you used that script.

This SQL example is independent. Run it as the table owner in a test database with the extension installed:

```sql
create table searchable_notes (
  id bigint primary key,
  body crdt.yseq not null default crdt.yseq_new(),
  body_text text generated always as (crdt.yseq_value(body)) stored
);
create index searchable_notes_body_search
  on searchable_notes
  using gin (to_tsvector('english', body_text));

insert into searchable_notes (id, body)
values (1, crdt.yseq_set(crdt.yseq_new(), 'Bring cake.', 'alice'));

select id, body_text
from searchable_notes
where to_tsvector('english', body_text)
      @@ plainto_tsquery('english', 'cake');
-- 1 | Bring cake.
```

The generated column is current after each write. Use `stored` on Postgres 18 too: virtual generated columns cannot call this user-defined function. You can also use an expression index on `yseq_value`.

Computing the text and updating its index add work to every edit. Measure the cost with your actual indexes and document sizes; the CRDT update still rewrites the whole state. See [Text-column limits and performance](limits.md).

Give readers only the rows they may see, using table privileges and row-level security or an authorized search wrapper. Search access is separate from permission to edit a document.
