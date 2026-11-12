# Steady state with autovacuum on (default settings)

Postgres: 16.4 (Postgres.app)
Machine:  Apple M4, 10 CPU, 24 GB, macOS 27.0.1
Date:     2026-11-10 19:32 +08
Settings: autovacuum=on, autovacuum_naptime=1min, autovacuum_vacuum_cost_delay=2ms, autovacuum_vacuum_cost_limit=-1, autovacuum_vacuum_scale_factor=0.2, autovacuum_vacuum_threshold=50, checkpoint_timeout=30min, default_toast_compression=pglz, fsync=on, full_page_writes=on, max_wal_size=2GB, shared_buffers=512MB, synchronous_commit=on, wal_compression=off, wal_level=replica
Code:     git cdea487; NDOCS=100; QUICK=0

100 documents per run. 'spread': 200 keystrokes/s in total over all documents (4 clients). 'hot': 50 keystrokes/s on one document (2 clients). Random positions in the first half of the document, except '-append': typing at the end. 180 s per run, sampled every 5 s. Sizes in MB: table + TOAST + indexes (for ydoc_ every crdt.ydoc_* table). 'live' is pgstattuple tuple_len (heap + TOAST) at the end. 'peak dead' is the largest n_dead_tup seen in a sample (heap / TOAST). 'autovacuums' counts autovacuum runs on the tables / their TOAST relations during the run.

## Summary

| size | shape | scenario | edits/s achieved | loaded | at 60 s | at 120 s | end | peak | live at end | end / live | peak dead heap / TOAST | autovacuums heap / TOAST | WAL MB/s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 kB | plain text (lz4) | hot-append | 49.084041 | 0.19 | 0.52 | 1.35 | 1.90 | 1.90 | 0.13 | 15 | 456 / 0 | 2 / 0 | 0.07 |
| 5 kB | plain text (lz4) | hot-append | 49.594244 | 0.62 | 14.1 | 16.2 | 16.7 | 16.7 | 0.42 | 40 | 144 / 8631 | 1 / 3 | 0.23 |
| 20 kB | plain text (lz4) | hot-append | 49.316271 | 1.58 | 35.1 | 42.3 | 44.6 | 44.6 | 1.37 | 33 | 135 / 20392 | 2 / 3 | 0.74 |
| 100 kB | plain text (lz4) | hot-append | 49.937268 | 6.80 | 209 | 211 | 213 | 213 | 6.45 | 33 | 121 / 95812 | 1 / 3 | 3.55 |

## Timelines (every 30 s)

### 1 kB, plain text (lz4), hot-append

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.2 | 0 | 0 | 0 / 0 |
| 30 | 0.5 | 90 | 0 | 0 / 0 |
| 61 | 0.5 | 90 | 0 | 0 / 0 |
| 91 | 0.4 | 59 | 0 | 1 / 0 |
| 121 | 1.5 | 371 | 0 | 1 / 0 |
| 151 | 1.9 | 206 | 0 | 2 / 0 |

### 5 kB, plain text (lz4), hot-append

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.6 | 0 | 0 | 0 / 0 |
| 30 | 6.4 | 43 | 3309 | 0 / 1 |
| 60 | 14.1 | 72 | 7683 | 0 / 1 |
| 91 | 16.1 | 144 | 3426 | 0 / 2 |
| 121 | 16.2 | 13 | 7923 | 0 / 2 |
| 151 | 16.7 | 119 | 3522 | 1 / 3 |

### 20 kB, plain text (lz4), hot-append

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 1.6 | 0 | 0 | 0 / 0 |
| 30 | 17.7 | 1 | 8141 | 0 / 1 |
| 61 | 38.7 | 55 | 18690 | 0 / 1 |
| 91 | 42.1 | 46 | 8897 | 1 / 2 |
| 122 | 42.4 | 76 | 19285 | 1 / 2 |
| 152 | 44.5 | 34 | 10184 | 2 / 3 |

### 100 kB, plain text (lz4), hot-append

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 6.8 | 0 | 0 | 0 / 0 |
| 30 | 108.6 | 45 | 50626 | 0 / 0 |
| 60 | 209.2 | 92 | 38 | 0 / 1 |
| 90 | 209.7 | 34 | 50358 | 0 / 1 |
| 121 | 212.7 | 38 | 1598 | 0 / 2 |
| 151 | 212.7 | 70 | 51612 | 0 / 2 |

