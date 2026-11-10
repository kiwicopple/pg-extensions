# PN-Counter: storage, bloat, WAL

Postgres: 16.4 (Postgres.app)
Machine:  Apple M4, 10 CPU, 24 GB, macOS 27.0.1
Date:     2026-11-10 19:09 +08
Settings: autovacuum=off, autovacuum_naptime=1min, autovacuum_vacuum_cost_delay=2ms, autovacuum_vacuum_cost_limit=-1, autovacuum_vacuum_scale_factor=0.2, autovacuum_vacuum_threshold=50, checkpoint_timeout=30min, default_toast_compression=pglz, fsync=off, full_page_writes=on, max_wal_size=2GB, shared_buffers=512MB, synchronous_commit=on, wal_compression=off, wal_level=replica
Code:     git cdea487; NDOCS=100; QUICK=0

## State size

Stored size (pg_column_size, after TOAST compression) of one crdt.pn with R replicas, a third of them also in n, every count drawn up to the given maximum (the count's digits are what grows with the number of increments).

| replicas | counts up to 1 | up to 1,000 | up to 1,000,000 | up to 1,000,000,000 | as JSON text (up to 1,000,000) | bytes per replica (up to 1,000,000) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 89 | 89 | 89 | 93 | 58 | 89.0 |
| 10 | 420 | 420 | 468 | 468 | 331 | 46.8 |
| 100 | 526 | 928 | 1272 | 1499 | 3075 | 12.7 |
| 1000 | 5029 | 8566 | 12076 | 14189 | 30543 | 12.1 |
| 10000 | 50767 | 83175 | 120095 | 139626 | 305218 | 12.0 |

## State column: bloat with autovacuum off

100 counters, 20000 increments (4 clients, random counter and replica, one per transaction). Sizes in MB; columns as in bloat.md.

| replicas | stored state (bytes) | loaded total | after: total | heap | TOAST | dead heap tuples | dead TOAST tuples | dead TOAST MB | live MB | after VACUUM: total | reusable | after VACUUM FULL | total / live | HOT % | WAL per write (B) | us per write |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | 468 | 0.11 | 0.16 | 0.14 | 0.01 | 147 | 0 | 0.00 | 0.05 | 0.16 | 0.06 | 0.08 | 3.3 | 100% | 137 | 105 |
| 100 | 1269 | 0.19 | 0.71 | 0.69 | 0.01 | 459 | 0 | 0.00 | 0.13 | 0.71 | 0.53 | 0.16 | 5.7 | 99% | 254 | 130 |
| 1000 | 12095 | 1.42 | 265 | 0.08 | 265 | 934 | 140000 | 233 | 1.18 | 265 | 260 | 1.43 | 224 | 99% | 13710 | 613 |
| 10000 | 120138 | 12.0 | 2392 | 0.08 | 2392 | 390 | 1220000 | 2313 | 11.7 | 2392 | 2344 | 12.1 | 205 | 100% | 134211 | 5477 |

'us per write' is wall time x clients / writes (client round trip included, fsync off).

## State column: HOT updates with an index on another column

10000 increments per run. Index variants as in bloat.md.

| replicas | index | HOT % | indexes before (MB) | indexes after (MB) | total after (MB) | WAL per write (B) |
| --- | --- | --- | --- | --- | --- | --- |
| 10 | none | 100% | 0.02 | 0.02 | 0.16 | 148 |
| 10 | title index | 100% | 0.03 | 0.03 | 0.18 | 145 |
| 10 | updated_at index | 0% | 0.03 | 0.25 | 0.60 | 693 |
| 1000 | none | 99% | 0.02 | 0.02 | 133 | 13778 |
| 1000 | title index | 99% | 0.03 | 0.03 | 133 | 13777 |
| 1000 | updated_at index | 0% | 0.03 | 0.25 | 134 | 13937 |

## Delta table and compaction

100 counters, deltas from 1000 replicas, 20000 inserts (4 clients), then the compaction recipe for all counters in one statement:

```sql
with folded as (delete from deltas returning counter, d)
insert into snapshots (counter, state)
select counter, crdt.pn_merge_agg(d) from folded group by counter
on conflict (counter) do update set state = crdt.pn_merge(snapshots.state, excluded.state);
```

Then VACUUM, a second batch of 20000 inserts, VACUUM FULL. Sizes in MB (deltas and snapshots tables, with indexes). 'read ms' is the mean latency of reading one counter's value (snapshot merged with its deltas; pgbench, 500 reads).

| step | delta rows | snapshot rows | total | heap | indexes | dead tuples | reusable | read ms | WAL MB | seconds |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| empty | 0 | 0 | 0.04 | 0.00 | 0.02 | 0 | 0.00 | 0.155 | - | - |
| after 20000 inserts | 20000 | 0 | 3.23 | 2.59 | 0.62 | 0 | 0.04 | 4.985 | 6.48 | 0.4 |
| after compaction | 0 | 100 | 3.49 | 2.80 | 0.62 | 20000 | 0.07 | 0.242 | 1.26 | 0.52 |
| after VACUUM | 0 | 100 | 0.93 | 0.23 | 0.62 | 0 | 0.03 | 0.217 | - | 0.04 |
| after 20000 more inserts | 20000 | 100 | 4.08 | 2.82 | 1.19 | 0 | 0.08 | 5.042 | 6.47 | - |
| after compaction + VACUUM | 0 | 100 | 1.92 | 0.23 | 1.23 | 0 | 0.27 | 0.258 | - | - |
| after VACUUM FULL | 0 | 100 | 0.45 | 0.01 | 0.03 | 0 | 0.09 | 0.259 | - | - |

Snapshot state after both batches: 3101 bytes per counter on average. Insert WAL: 340 bytes per delta (LSN).

## WAL per write, decomposed

2000 writes per run, one client. 'cold' starts right after a CHECKPOINT, 'warm' follows it without one. Bytes per write; columns as in wal.md.

| write | replicas | phase | wal_compression | LSN | records | FPI | FPI share | heap | btree | other |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| state column | 10 | cold | off | 212 | 166 | 35 | 17% | 166 | 1 | 34 |
| state column | 10 | warm | off | 176 | 165 | 0 | 0% | 131 | 0 | 34 |
| state column | 10 | cold | lz4 | 182 | 165 | 7 | 4% | 138 | 0 | 34 |
| state column | 100 | cold | off | 357 | 268 | 76 | 22% | 308 | 2 | 34 |
| state column | 100 | warm | off | 271 | 259 | 0 | 0% | 225 | 0 | 34 |
| state column | 100 | cold | lz4 | 317 | 251 | 53 | 17% | 270 | 0 | 34 |
| state column | 1000 | cold | off | 14341 | 13626 | 637 | 4% | 13762 | 467 | 34 |
| state column | 1000 | warm | off | 13700 | 13625 | 0 | 0% | 13128 | 463 | 34 |
| state column | 1000 | cold | lz4 | 15014 | 13609 | 1325 | 9% | 14434 | 466 | 34 |
| state column | 10000 | cold | off | 138564 | 131794 | 6162 | 4% | 133889 | 4033 | 34 |
| state column | 10000 | warm | off | 132382 | 131794 | 0 | 0% | 127728 | 4032 | 34 |
| state column | 10000 | cold | lz4 | 136451 | 131798 | 4052 | 3% | 131780 | 4036 | 34 |
| delta insert | 1000 | cold | off | 339 | 328 | 0 | 0% | 156 | 135 | 37 |
| delta insert | 1000 | warm | off | 340 | 329 | 0 | 0% | 156 | 136 | 37 |
| delta insert | 1000 | cold | lz4 | 356 | 332 | 13 | 4% | 157 | 151 | 37 |

## State column: steady state with autovacuum on (default settings), fsync=on

Settings now: autovacuum=on, autovacuum_naptime=1min, autovacuum_vacuum_cost_delay=2ms, autovacuum_vacuum_cost_limit=-1, autovacuum_vacuum_scale_factor=0.2, autovacuum_vacuum_threshold=50, fsync=on.

'spread': 200 increments/s over all 100 counters (4 clients). 'hot': 100 increments/s on counter 1 (2 clients). 180 s per run. Columns as in autovac.md.

| replicas | scenario | writes/s achieved | loaded | at 60 s | at 120 s | end | peak | live at end | end / live | peak dead heap / TOAST | autovacuums heap / TOAST | WAL MB/s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | spread | 199.634454 | 0.11 | 0.14 | 0.14 | 0.14 | 0.14 | 0.05 | 2.9 | 69 / 0 | 0 / 0 | 0.03 |
| 10 | hot | 100.399432 | 0.11 | 0.17 | 0.23 | 0.28 | 0.28 | 0.05 | 5.7 | 62 / 0 | 0 / 0 | 0.01 |
| 1000 | spread | 199.821491 | 1.42 | 131 | 160 | 172 | 172 | 1.18 | 145 | 107 / 84383 | 1 / 3 | 2.66 |
| 1000 | hot | 101.267256 | 1.42 | 66.0 | 84.2 | 85.0 | 85.0 | 1.18 | 72 | 142 / 41125 | 0 / 3 | 1.35 |

