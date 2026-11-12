# Bloat with autovacuum off

Postgres: 16.4 (Postgres.app)
Machine:  Apple M4, 10 CPU, 24 GB, macOS 27.0.1
Date:     2026-11-10 18:43 +08
Settings: autovacuum=off, autovacuum_naptime=1min, autovacuum_vacuum_cost_delay=2ms, autovacuum_vacuum_cost_limit=-1, autovacuum_vacuum_scale_factor=0.2, autovacuum_vacuum_threshold=50, checkpoint_timeout=30min, default_toast_compression=pglz, fsync=off, full_page_writes=on, max_wal_size=2GB, shared_buffers=512MB, synchronous_commit=on, wal_compression=off, wal_level=replica
Code:     git cdea487; NDOCS=100; QUICK=0

100 documents per run, 40-edit history each, then 20000 keystrokes (4 pgbench clients, random document and position, 80% insert / 20% delete of one character, one per transaction). Sizes in MB. 'live' is pgstattuple's tuple_len (heap + TOAST) after the run; 'dead TOAST' is dead_tuple_len of the TOAST relations; 'reusable' is pgstattuple free_space after VACUUM. For ydoc_ every crdt.ydoc_* table is included.

## Sizes

| size | shape | loaded total | after edits: total | heap | TOAST | indexes | dead heap tuples | dead TOAST tuples | dead TOAST MB | live MB | after VACUUM: total | reusable | returned to OS | VACUUM s | after VACUUM FULL | total / live (before VACUUM) | HOT % | WAL MB | WAL kB per edit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 kB | plain text (lz4) | 0.19 | 2.29 | 2.27 | 0.01 | 0.02 | 1126 | 0 | 0.00 | 0.14 | 2.29 | 2.09 | 0.00 | 0.0 | 0.18 | 17 | 95% | 8.68 | 0.44 |
| 1 kB | yseq_ (lz4) | 0.37 | 95.5 | 0.08 | 95.4 | 0.02 | 425 | 53917 | 56.0 | 0.60 | 95.5 | 93.2 | 0.00 | 0.1 | 0.74 | 158 | 100% | 98.9 | 5.06 |
| 1 kB | ydoc_ | 4.27 | 10.1 | 6.36 | 0.07 | 3.69 | 10511 | 0 | 0.00 | 3.54 | 10.1 | 2.24 | 0.00 | 0.0 | 7.09 | 2.9 | 100% | 19.2 | 0.98 |
| 5 kB | plain text (lz4) | 0.62 | 106 | 0.05 | 106 | 0.02 | 155 | 59959 | 84.4 | 0.45 | 106 | 104 | 0.00 | 0.1 | 0.56 | 238 | 100% | 98.6 | 5.05 |
| 5 kB | yseq_ (lz4) | 0.69 | 168 | 0.08 | 168 | 0.02 | 302 | 91559 | 127 | 1.03 | 168 | 164 | 0.00 | 0.1 | 1.23 | 163 | 100% | 177 | 9.08 |
| 5 kB | ydoc_ | 5.27 | 12.3 | 8.09 | 0.07 | 4.09 | 11969 | 0 | 0.00 | 4.42 | 12.3 | 3.02 | 0.00 | 0.1 | 8.58 | 2.8 | 100% | 23.0 | 1.18 |
| 20 kB | plain text (lz4) | 1.58 | 312 | 0.08 | 312 | 0.02 | 387 | 158071 | 268 | 1.40 | 312 | 306 | -0.01 | 0.1 | 1.64 | 222 | 100% | 305 | 15.6 |
| 20 kB | yseq_ (lz4) | 1.69 | 372 | 0.08 | 372 | 0.02 | 368 | 193476 | 327 | 2.05 | 372 | 364 | -0.01 | 0.1 | 2.23 | 182 | 100% | 391 | 20.0 |
| 20 kB | ydoc_ | 8.41 | 16.2 | 11.5 | 0.07 | 4.66 | 12386 | 0 | 0.00 | 6.37 | 16.2 | 4.39 | 0.00 | 0.0 | 11.3 | 2.5 | 100% | 27.3 | 1.40 |
| 100 kB | plain text (lz4) | 6.80 | 1344 | 0.08 | 1344 | 0.02 | 487 | 679854 | 1276 | 6.50 | 1344 | 1318 | -0.04 | 1.3 | 6.80 | 207 | 99% | 1415 | 72.5 |
| 100 kB | yseq_ (lz4) | 6.86 | 1420 | 0.08 | 1420 | 0.02 | 501 | 720651 | 1341 | 7.19 | 1420 | 1392 | -0.04 | 1.4 | 7.50 | 198 | 100% | 1508 | 77.2 |
| 100 kB | ydoc_ | 23.5 | 33.3 | 25.4 | 0.07 | 7.76 | 13573 | 0 | 0.00 | 16.4 | 33.3 | 8.09 | 0.00 | 0.1 | 24.8 | 2.0 | 100% | 41.2 | 2.11 |

'returned to OS' is the file size VACUUM gave back (it truncates only empty pages at the end of a file). HOT % is n_tup_hot_upd / n_tup_upd during the edits, over all the shape's tables (for ydoc_ the internal tables; the documents table is not updated).

### ydoc_ tables, 1 kB

Counters during the edits; sizes in MB.

| table | rows inserted | updates | HOT % | dead tuples after edits | loaded | after edits | after VACUUM | after VACUUM FULL |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| crdt.ydoc_docs | 0 | 20000 | 100% | 2306 | 0.48 | 0.48 | 0.48 | 0.05 |
| crdt.ydoc_replicas | 100 | 0 | - | 0 | 0.12 | 0.16 | 0.16 | 0.09 |
| crdt.ydoc_items | 32229 | 20451 | 100% | 3485 | 2.54 | 8.16 | 8.16 | 6.52 |
| crdt.ydoc_blocks | 0 | 36324 | 100% | 4720 | 0.83 | 0.83 | 0.83 | 0.03 |
| crdt.ydoc_deps | 1129 | 0 | - | 0 | 0.16 | 0.34 | 0.34 | 0.26 |

### ydoc_ tables, 5 kB

Counters during the edits; sizes in MB.

| table | rows inserted | updates | HOT % | dead tuples after edits | loaded | after edits | after VACUUM | after VACUUM FULL |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| crdt.ydoc_docs | 0 | 20000 | 100% | 1946 | 0.48 | 0.48 | 0.48 | 0.05 |
| crdt.ydoc_replicas | 100 | 0 | - | 0 | 0.12 | 0.16 | 0.16 | 0.09 |
| crdt.ydoc_items | 38055 | 25953 | 100% | 5858 | 3.55 | 10.4 | 10.4 | 8.06 |
| crdt.ydoc_blocks | 10 | 42014 | 100% | 4165 | 0.83 | 0.83 | 0.83 | 0.03 |
| crdt.ydoc_deps | 933 | 0 | - | 0 | 0.13 | 0.27 | 0.27 | 0.21 |

### ydoc_ tables, 20 kB

Counters during the edits; sizes in MB.

| table | rows inserted | updates | HOT % | dead tuples after edits | loaded | after edits | after VACUUM | after VACUUM FULL |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| crdt.ydoc_docs | 0 | 20000 | 100% | 2018 | 0.48 | 0.48 | 0.48 | 0.05 |
| crdt.ydoc_replicas | 100 | 0 | - | 0 | 0.12 | 0.16 | 0.16 | 0.09 |
| crdt.ydoc_items | 39408 | 27310 | 100% | 6891 | 6.55 | 14.2 | 14.2 | 10.8 |
| crdt.ydoc_blocks | 93 | 43452 | 100% | 3477 | 0.98 | 0.98 | 0.98 | 0.04 |
| crdt.ydoc_deps | 786 | 0 | - | 0 | 0.12 | 0.23 | 0.23 | 0.18 |

### ydoc_ tables, 100 kB

Counters during the edits; sizes in MB.

| table | rows inserted | updates | HOT % | dead tuples after edits | loaded | after edits | after VACUUM | after VACUUM FULL |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| crdt.ydoc_docs | 0 | 20000 | 100% | 2011 | 0.48 | 0.48 | 0.48 | 0.05 |
| crdt.ydoc_replicas | 100 | 0 | - | 0 | 0.12 | 0.16 | 0.16 | 0.09 |
| crdt.ydoc_items | 39803 | 27761 | 100% | 6885 | 20.1 | 29.7 | 29.7 | 24.3 |
| crdt.ydoc_blocks | 200 | 43982 | 100% | 4677 | 2.52 | 2.54 | 2.54 | 0.06 |
| crdt.ydoc_deps | 629 | 0 | - | 0 | 0.12 | 0.22 | 0.22 | 0.16 |

## HOT updates with an index on another column

10000 keystrokes per run, as above. 'none': primary key only. 'title index': a btree on title, which the edits do not change. 'updated_at index': a btree on updated_at, and every edit also sets updated_at = now() (a common app pattern). Index sizes in MB, before and after the edits.

| size | shape | index | HOT % | indexes before | indexes after | total after (MB) | WAL kB per edit |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 kB | plain text (lz4) | none | 95% | 0.02 | 0.02 | 1.26 | 0.46 |
| 1 kB | plain text (lz4) | title index | 95% | 0.03 | 0.03 | 1.23 | 0.46 |
| 1 kB | plain text (lz4) | updated_at index | 0% | 0.03 | 0.25 | 1.68 | 0.61 |
| 1 kB | yseq_ (lz4) | none | 99% | 0.02 | 0.02 | 39.1 | 4.08 |
| 1 kB | yseq_ (lz4) | title index | 99% | 0.03 | 0.03 | 39.1 | 4.09 |
| 1 kB | yseq_ (lz4) | updated_at index | 0% | 0.03 | 0.25 | 39.5 | 4.23 |
| 20 kB | plain text (lz4) | none | 99% | 0.02 | 0.02 | 155 | 15.6 |
| 20 kB | plain text (lz4) | title index | 99% | 0.03 | 0.03 | 155 | 15.6 |
| 20 kB | plain text (lz4) | updated_at index | 0% | 0.03 | 0.25 | 155 | 15.7 |
| 20 kB | yseq_ (lz4) | none | 99% | 0.02 | 0.02 | 171 | 18.6 |
| 20 kB | yseq_ (lz4) | title index | 99% | 0.03 | 0.03 | 171 | 18.6 |
| 20 kB | yseq_ (lz4) | updated_at index | 0% | 0.03 | 0.25 | 171 | 18.8 |

