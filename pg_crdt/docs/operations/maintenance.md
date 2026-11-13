# Maintain storage

The active extension has no background maintenance worker and no document compaction function. Application tables use ordinary Postgres vacuum and index maintenance.

## Counter columns and delta tables

Keep writer ids stable: each new counter entry remains in the state. For a large counter, use a delta table and periodically combine rows into a snapshot. The [storage guide](../guides/storage-and-performance.md#compact-a-delta-table-by-hand) contains the transactional recipe. This reduces delta rows; it does not remove writer entries from the merged counter.

## Text columns

Every edit creates a new state value and leaves an old row/TOAST version for vacuum. Monitor state size, dead tuples, WAL volume, replication lag and edit latency. Set autovacuum thresholds for the application table based on measurements, and avoid long transactions that prevent cleanup.

LZ4 compression and batching may reduce write costs, but each stored edit still rewrites the full state. Ordinary vacuum reuses dead space and does not compact the CRDT's live deletion metadata. There is no tombstone garbage collection or supported history-reset procedure.

Replacing a document with fresh text loses its identity and history. Offline clients still refer to the old character ids, so do not use that as transparent compaction. Any application-level reset needs a new document identity and a coordinated client transition.

Read [Text-column limits and performance](../text/limits.md) before setting capacity expectations. If sustained editing exceeds your budget, choose another design; table-backed documents remain research only.
