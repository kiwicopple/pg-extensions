# Text-column limits and performance

`crdt.yseq` is experimental. It keeps the document and its edit history in one column. This makes ownership, indexing and backups straightforward, but every edit rewrites the whole value. Use it first for short documents saved occasionally, and measure your workload before adopting live editing.

There is no universal safe document-size limit. Visible text size, retained history, writer count, edit frequency, indexes and concurrent sessions all affect the cost.

## Storage and algorithm limits

These are measured in the [text benchmarks](../../research/benchmarks/text.md) and the [vacuum, bloat and WAL benchmarks](../../research/benchmarks/vacuum-wal.md), single runs on a laptop that show how the cost grows, not what you will get:

- **Every edit rewrites the whole value.** A one-character edit writes a new copy of the state. The WAL of one keystroke was about 3.4 kB at 1 kB of text, 7.1 kB at 5 kB, 18.5 kB at 20 kB and 78.7 kB at 100 kB, and the state crosses the 2 kB TOAST threshold at under 1 kB of text.
- **TOAST churn at keystroke rate.** Each edit leaves a dead copy of the value until `VACUUM` reclaims it. Under default autovacuum a table of documents edited per keystroke settles at many times its live size, VACUUM makes the space reusable without returning it, and at 100 kB documents and 200 keystrokes a second autovacuum did not keep up. This is how Postgres treats any large value that is rewritten often: from 5 kB up, a plain `text` column with the same edits bloated and logged within 1.1 to 1.6 times as much. Put `compression lz4` on the column, and tune autovacuum for the table when documents are large and edited per keystroke. If those costs remain unacceptable, use a different storage or collaboration design; the active extension has no table-backed alternative.
- **No tombstone collection.** Deleted characters stay in the state as runs, without their text, so the state grows with the edit history and not only with the text.
- **No equivocation detection.** A run that repeats ids already present is skipped without comparing its text. Two writers that share one entry key lose text silently: give each editor and device its own key, and merge only states from servers you trust.
- **Merge, apply and ops_since are O(document).** `yseq_merge`, `yseq_apply` and `yseq_ops_since` read every run of the state on every call.
- **A three-way save sends the whole state.** The base of `yseq_set` is the value the form read, not a small token, because the state does not keep the text of deleted characters.
- **Edits return the state, not the op.** Use `yseq_diff(old, new)` for the op.
- **UTF8 databases only.** In another encoding, the functions that send deleted characters fail on a state that has any.

Every function and its errors: [Collaborative text column functions](../reference/yseq.md).


## WAL amplification and disk space

Postgres writes changes to its write-ahead log (WAL) for recovery and replication. A one-character edit can produce kilobytes of WAL because the entire compressed CRDT value is replaced. TOAST is Postgres's storage for large column values; old copies remain until vacuum can reclaim them.

| Text size | WAL per keystroke in the cited run |
| --- | ---: |
| 1 kB | about 3.4 kB |
| 5 kB | about 7.1 kB |
| 20 kB | about 18.5 kB |
| 100 kB | about 78.7 kB |

These are observations from the [text](../../research/benchmarks/text.md) and [vacuum/WAL](../../research/benchmarks/vacuum-wal.md) research, not capacity guarantees. The benchmark environment was Postgres 16.4 on an Apple M4 laptop, with `shared_buffers=512MB`, `full_page_writes=on` and `wal_compression=off` unless noted. Latency/WAL/bloat runs used `fsync=off`; autovacuum runs used `fsync=on`. Each figure is a single run with roughly 5% noise. The reports distinguish workloads and settings; ratios of 1.3 or less should be treated as ties.

Default autovacuum did not keep up in the measured 100 kB-document workload at 200 keystrokes per second. Ordinary vacuum makes dead space reusable; it generally does not return the file space to the operating system. Long transactions can delay reclamation. Compression and autovacuum tuning may help, but neither removes live CRDT history or the whole-value rewrite.

## Network, indexes and concurrency

- A form sends its whole base state. A short visible document can have a large base after many edits; the benchmarks measured about 450 kB at 100,000 characters.
- Change feeds and logical decoding can carry the full changed column. Budget replication traffic as well as client traffic; notification alone does not provide CRDT sync.
- A generated text column and search index are recomputed or maintained on writes. They add work to the CRDT edit.
- Writers to one row wait for its lock. Independent editing does not remove database contention. Under REPEATABLE READ or SERIALIZABLE, retry the whole transaction on `40001`.
- Deleted characters retain ids and origins, but not their original text. There is no tombstone garbage collection or column compaction API. Vacuum cannot remove that live metadata.

## Correctness and feature limits

The document is plain text. Rich text, presence, cursors and undo belong to the application. Operations are not the Yjs wire format. No production client adapter is supplied for columns.

Give every independent writer a unique, stable entry key. The column does not detect conflicting content under reused character ids. Only merge states from trusted peers; use a wrapper around `yseq_apply` for client operations.

Form saves require the original base to preserve concurrent edits. After saving, reload the text and base together. Repeated saves against an old base have deletion/retyping edge cases, and a CRDT cannot infer intent for overlapping replacements. Display the merged result. A base without a document id cannot reliably distinguish documents: use `yseq_new()` for new rows.

Read [numeric and quota limits](../reference/yseq.md#limits) before batching edits. The server limits operation runs, writer keys and pending data. Positions count Unicode code points, not UTF-16 units or grapheme clusters; a displayed character can contain several code points. Use a UTF8 database.

## Evaluate before deployment

Test your expected document sizes and edit histories with realistic writer counts, burst rates, indexes and durability settings. Measure edit latency, state size, WAL bytes, replication lag and vacuum behavior over sustained runs. Include recovery after disconnects and rejected operations. The research does not establish performance on every Postgres version, tuned autovacuum, long-running transactions, or your replication setup.

The table-backed alternative remains [separate research](../../research/scope.md). It is not an escape hatch installed by pg_crdt. If column costs exceed your budget, choose another design before committing to the API.
