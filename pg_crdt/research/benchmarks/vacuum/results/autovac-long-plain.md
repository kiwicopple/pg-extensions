# Steady state with autovacuum on (default settings)

Postgres: 16.4 (Postgres.app)
Machine:  Apple M4, 10 CPU, 24 GB, macOS 27.0.1
Date:     2026-11-10 19:09 +08
Settings: autovacuum=on, autovacuum_naptime=1min, autovacuum_vacuum_cost_delay=2ms, autovacuum_vacuum_cost_limit=-1, autovacuum_vacuum_scale_factor=0.2, autovacuum_vacuum_threshold=50, checkpoint_timeout=30min, default_toast_compression=pglz, fsync=on, full_page_writes=on, max_wal_size=2GB, shared_buffers=512MB, synchronous_commit=on, wal_compression=off, wal_level=replica
Code:     git cdea487; NDOCS=100; QUICK=0

100 documents per run. 'spread': 200 keystrokes/s in total over all documents (4 clients). 'hot': 50 keystrokes/s on one document (2 clients). 600 s per run, sampled every 5 s. Sizes in MB: table + TOAST + indexes (for ydoc_ every crdt.ydoc_* table). 'live' is pgstattuple tuple_len (heap + TOAST) at the end. 'peak dead' is the largest n_dead_tup seen in a sample (heap / TOAST). 'autovacuums' counts autovacuum runs on the tables / their TOAST relations during the run.

## Summary

| size | shape | scenario | edits/s achieved | loaded | at 60 s | at 120 s | end | peak | live at end | end / live | peak dead heap / TOAST | autovacuums heap / TOAST | WAL MB/s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 5 kB | plain text (lz4) | spread | 200.279467 | 0.62 | 64.9 | 79.2 | 71.6 | 79.2 | 0.51 | 142 | 152 / 42515 | 6 / 9 | 1.09 |
| 20 kB | plain text (lz4) | spread | 200.954780 | 1.60 | 142 | 196 | 192 | 200 | 1.53 | 125 | 156 / 95359 | 7 / 10 | 3.28 |

## Timelines (every 30 s)

### 5 kB, plain text (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.6 | 0 | 0 | 0 / 0 |
| 30 | 32.6 | 82 | 17792 | 0 / 0 |
| 60 | 64.9 | 73 | 36350 | 0 / 0 |
| 90 | 79.2 | 99 | 9918 | 1 / 1 |
| 121 | 79.2 | 119 | 28254 | 1 / 1 |
| 151 | 63.5 | 45 | 10368 | 2 / 2 |
| 181 | 63.5 | 141 | 28623 | 2 / 2 |
| 211 | 64.1 | 64 | 10689 | 2 / 3 |
| 242 | 64.1 | 116 | 29106 | 2 / 3 |
| 272 | 64.9 | 126 | 11352 | 3 / 4 |
| 302 | 65.3 | 106 | 29154 | 3 / 4 |
| 333 | 65.4 | 51 | 11487 | 4 / 5 |
| 363 | 65.4 | 57 | 29787 | 4 / 5 |
| 393 | 65.5 | 59 | 12140 | 4 / 6 |
| 424 | 65.5 | 45 | 30089 | 4 / 6 |
| 455 | 66.9 | 57 | 13230 | 5 / 7 |
| 485 | 66.9 | 125 | 31617 | 5 / 7 |
| 516 | 69.9 | 115 | 12847 | 6 / 8 |
| 546 | 69.9 | 93 | 31318 | 6 / 8 |
| 576 | 71.6 | 98 | 13278 | 6 / 9 |

### 20 kB, plain text (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 1.6 | 0 | 0 | 0 / 0 |
| 30 | 60.8 | 97 | 28787 | 0 / 1 |
| 61 | 158.0 | 123 | 78955 | 0 / 1 |
| 91 | 195.7 | 111 | 30359 | 0 / 2 |
| 121 | 196.5 | 72 | 78727 | 0 / 2 |
| 152 | 196.9 | 104 | 30992 | 1 / 3 |
| 182 | 196.9 | 40 | 78736 | 1 / 3 |
| 212 | 196.9 | 48 | 31784 | 2 / 4 |
| 242 | 196.9 | 123 | 80912 | 2 / 4 |
| 273 | 196.9 | 80 | 33344 | 3 / 5 |
| 303 | 196.9 | 81 | 82768 | 3 / 5 |
| 333 | 197.7 | 47 | 34469 | 4 / 6 |
| 364 | 197.7 | 62 | 82517 | 4 / 6 |
| 394 | 200.3 | 90 | 34987 | 4 / 7 |
| 424 | 200.3 | 56 | 83763 | 4 / 7 |
| 454 | 200.3 | 89 | 36454 | 5 / 8 |
| 485 | 200.3 | 101 | 85126 | 5 / 8 |
| 515 | 200.3 | 122 | 35820 | 6 / 9 |
| 545 | 200.3 | 98 | 84295 | 6 / 9 |
| 575 | 192.0 | 43 | 36667 | 7 / 10 |

