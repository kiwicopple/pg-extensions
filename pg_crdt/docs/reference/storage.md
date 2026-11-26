# Storage and limits

Start with one CRDT column in your own table. Measure its stored size, update latency and database write volume with the workload you expect. There is no universal safe size or edit rate.

## Counters

A counter keeps additions and subtractions for every writer that has contributed. Those totals only grow; a merge keeps the larger total for each writer. Entries are never removed. To start a counter over, use a new row and retire the old one.

For many writers or frequent updates, consider storing incoming deltas in separate rows. A delta carries only changed entries, but each entry is still a running total. Writes stay small; reads must merge the rows. The [delta-table example](../examples/counter-storage.sql) shows insertion, aggregation and combining old rows into a snapshot in one transaction. Validate client input with `pn_apply_delta` before storing it.

Combining delta rows reduces the number of rows to read. It does not remove writer entries from the merged state. The [counter benchmarks](../../research/benchmarks/pn-counter.md) compare the costs; their measurements are not capacity guarantees.

## Text

Text columns are experimental. They keep visible text plus the information needed to merge edits:

| Cost or limit | What it means for your app |
| --- | --- |
| Whole-value writes | Even a one-character edit replaces the entire stored state. |
| Database write volume | Large values use Postgres's TOAST storage. Replacing them creates old copies and writes to the recovery log, called WAL. |
| Retained history | Deleted characters keep their ids and ordering information, though their text is removed. There is no supported history cleanup or compaction API. |
| Sync work | Merge, apply and sync scan the document. Sync also sends all deletion ranges. |
| Form saves | Each request sends the full base state the form opened with. |
| Writer keys | Reusing a character id with different text can silently lose edits. Give each independent editor its own key. |
| Client features | No Yjs wire compatibility, packaged browser client, rich text, shared cursors or undo. |

Batching saves, LZ4 compression and tuning Postgres's automatic cleanup can reduce costs. Vacuum makes old row and TOAST space reusable; it cannot remove live CRDT history. Long transactions can delay cleanup. Replacing a document with fresh text loses its identity and breaks old offline copies, so it is not transparent compaction.

Before choosing live editing, test realistic document histories, simultaneous users, indexes and replication. Measure latency, state size, WAL, replication lag and disk growth over sustained editing. See the [text](../../research/benchmarks/text.md) and [vacuum/WAL](../../research/benchmarks/vacuum-wal.md) research for measured examples and their test conditions.

## Indexes and search

You can index `pn_value` or store `yseq_value` in a generated column. These SQL fragments use the tables from the [counter](../get-started/quickstart.md) and [text](../get-started/text.md) guides:

```sql
create index pages_visits on pages (crdt.pn_value(visits));

alter table notes add column body_text text
  generated always as (crdt.yseq_value(body)) stored;
create index notes_search on notes
  using gin (to_tsvector('english', body_text));

select id from notes
where to_tsvector('english', body_text)
  @@ plainto_tsquery('english', 'hello');
-- 1
```

Use `stored` on supported Postgres versions, including 18. Generated values and indexes add work to each write. Change feeds can carry the full changed state too; a notification alone does not sync devices.

For exact number ranges and quotas, see [numeric limits](limits.md). For backups and removal, see [operations](operations.md).
