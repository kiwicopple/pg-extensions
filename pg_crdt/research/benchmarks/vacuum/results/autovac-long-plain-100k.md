# Steady state with autovacuum on (default settings)

Postgres: 16.4 (Postgres.app)
Machine:  Apple M4, 10 CPU, 24 GB, macOS 27.0.1
Date:     2026-11-10 19:32 +08
Settings: autovacuum=on, autovacuum_naptime=1min, autovacuum_vacuum_cost_delay=2ms, autovacuum_vacuum_cost_limit=-1, autovacuum_vacuum_scale_factor=0.2, autovacuum_vacuum_threshold=50, checkpoint_timeout=30min, default_toast_compression=pglz, fsync=on, full_page_writes=on, max_wal_size=2GB, shared_buffers=512MB, synchronous_commit=on, wal_compression=off, wal_level=replica
Code:     git cdea487; NDOCS=100; QUICK=0

100 documents per run. 'spread': 200 keystrokes/s in total over all documents (4 clients). 'hot': 50 keystrokes/s on one document (2 clients). Random positions in the first half of the document, except '-append': typing at the end. 600 s per run, sampled every 5 s. Sizes in MB: table + TOAST + indexes (for ydoc_ every crdt.ydoc_* table). 'live' is pgstattuple tuple_len (heap + TOAST) at the end. 'peak dead' is the largest n_dead_tup seen in a sample (heap / TOAST). 'autovacuums' counts autovacuum runs on the tables / their TOAST relations during the run.

## Summary

| size | shape | scenario | edits/s achieved | loaded | at 60 s | at 120 s | end | peak | live at end | end / live | peak dead heap / TOAST | autovacuums heap / TOAST | WAL MB/s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 100 kB | plain text (lz4) | spread | 198.549784 | 6.82 | 739 | 1529 | 3885 | 3885 | 6.77 | 574 | 467 / 1773861 | 9 / 3 | 14.68 |

## Timelines (every 30 s)

### 100 kB, plain text (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 6.8 | 0 | 0 | 0 / 0 |
| 31 | 407.4 | 38 | 198503 | 0 / 0 |
| 61 | 806.6 | 49 | 402966 | 0 / 0 |
| 91 | 1204.9 | 110 | 607238 | 1 / 0 |
| 121 | 1578.9 | 223 | 810558 | 1 / 0 |
| 152 | 1751.6 | 322 | 89512 | 2 / 1 |
| 182 | 1753.1 | 207 | 291775 | 2 / 1 |
| 212 | 1907.2 | 358 | 495220 | 3 / 1 |
| 242 | 2314.6 | 127 | 703995 | 3 / 1 |
| 273 | 2656.5 | 251 | 914964 | 4 / 1 |
| 303 | 3056.6 | 194 | 1117483 | 4 / 1 |
| 333 | 3167.3 | 194 | 225590 | 5 / 2 |
| 364 | 3168.0 | 95 | 440362 | 5 / 2 |
| 394 | 3172.7 | 176 | 646267 | 6 / 2 |
| 424 | 3178.6 | 89 | 859242 | 6 / 2 |
| 454 | 3590.5 | 220 | 1069977 | 7 / 2 |
| 485 | 3744.0 | 170 | 1277457 | 7 / 2 |
| 515 | 3786.4 | 222 | 1493997 | 8 / 2 |
| 546 | 3832.2 | 176 | 1707531 | 8 / 2 |
| 576 | 3884.6 | 182 | 341021 | 9 / 3 |

