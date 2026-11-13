# Errors and limits: capacity limits

The active extension supports `crdt.pn` counters and experimental `crdt.yseq` text columns. It does not install document tables, a background worker or a client SDK. See [the scope decision](../../research/scope.md).

## Numbers

| Limit | Value | On overflow or invalid input |
| --- | --- | --- |
| Counter entry or increment/decrement amount | Whole number from 0 to 9,223,372,036,854,775,807 | `22003` for overflow; `22023` for invalid amounts or client counts |
| Counter value | Signed `bigint` range | `pn_value` raises `22003` |
| Counter entry key | Non-empty replica id without `:`, optionally a non-empty device suffix | `22023` from local edits or apply; merge does not validate keys |
| State format version | `v = 1` | Domain check fails with `23514` |
| Text entry key | At most 256 bytes | `22023` |
| Text device keys per owner (`yseq_apply`) | 32 per state | `54000` |
| Text insert runs per operation | 128 after joining, 4,096 before | `22023` |
| Waiting text data per writer | 256 insert runs plus deletes, and 64 kB JSON | `54000` |
| Text positions, lengths and sequence numbers | `integer`, up to 2,147,483,647 | `22003` or `22023` |
| Database encoding for text | UTF8 | Sync involving deleted characters fails in other encodings |
| Tested Postgres versions | 16, 17, 18 | Other versions are not covered by the suite |

See [Text column functions](yseq.md#limits) for function-specific details and [Errors](errors.md) for exact conditions.

## Counters

Entries are never removed, and totals cannot be reset under an existing key. State size and merge costs grow with writer count. A lost local state can silently suppress new increments until its totals exceed the stored ones. Disconnected writers cannot enforce a minimum or maximum balance. JSON concatenation is not a CRDT merge.

Large state columns rewrite and log the whole value. Change feeds may carry the whole changed state too. Use [delta tables](../guides/storage-and-performance.md) when appropriate; their compaction is an application task.

## Collaborative text

Every edit rewrites the whole state, and retained deletion metadata grows with edit history. Merge, apply and sync scan the document; sync sends all deletion ranges. Form saves send a full base state. There is no tombstone collection, compaction API, detection of conflicting content under reused ids, Yjs wire compatibility, or packaged live-editor adapter.

Read [Text-column limits and performance](../text/limits.md) for WAL amplification, TOAST bloat, indexes, network costs, Unicode, concurrency, form-save edge cases and benchmark caveats. These limitations are part of choosing the column approach, not optional tuning notes.

## Installation and lifecycle

The schema is fixed to `crdt`. Postgres 18 generated columns that call these functions must be `stored`. Version 0.0.1 has no upgrade scripts or automatic state migration. Dropping the extension with `cascade` can remove your columns and data: follow [Uninstall](../operations/uninstall.md).
