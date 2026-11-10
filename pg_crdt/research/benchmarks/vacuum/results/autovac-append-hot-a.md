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
| 1 kB | yseq_ (lz4) | hot-append | 49.901128 | 0.37 | 20.4 | 44.3 | 77.7 | 77.7 | 0.27 | 287 | 144 / 35437 | 1 / 2 | 1.00 |
| 5 kB | yseq_ (lz4) | hot-append | 49.959225 | 0.69 | 27.9 | 55.2 | 96.1 | 96.1 | 0.58 | 165 | 144 / 44858 | 1 / 3 | 1.21 |
| 20 kB | yseq_ (lz4) | hot-append | 50.428027 | 1.69 | 61.9 | 87.5 | 125 | 125 | 1.54 | 81 | 117 / 57048 | 1 / 3 | 1.76 |
| 100 kB | yseq_ (lz4) | hot-append | 50.779274 | 6.86 | 229 | 249 | 299 | 299 | 6.62 | 45 | 131 / 136187 | 2 / 2 | 4.57 |

## Timelines (every 30 s)

### 1 kB, yseq_ (lz4), hot-append

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.4 | 0 | 0 | 0 / 0 |
| 30 | 7.9 | 72 | 4392 | 0 / 0 |
| 61 | 23.5 | 88 | 13188 | 0 / 0 |
| 91 | 31.1 | 52 | 8451 | 0 / 1 |
| 121 | 50.1 | 135 | 25392 | 0 / 1 |
| 151 | 62.8 | 101 | 13874 | 1 / 2 |

### 5 kB, yseq_ (lz4), hot-append

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.7 | 0 | 0 | 0 / 0 |
| 31 | 10.7 | 30 | 5441 | 0 / 1 |
| 61 | 31.9 | 93 | 16540 | 0 / 1 |
| 91 | 38.8 | 70 | 12279 | 1 / 2 |
| 122 | 61.0 | 9 | 30544 | 1 / 2 |
| 152 | 70.9 | 61 | 19962 | 1 / 3 |

### 20 kB, yseq_ (lz4), hot-append

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 1.7 | 0 | 0 | 0 / 0 |
| 30 | 25.9 | 1 | 12466 | 0 / 1 |
| 60 | 61.9 | 28 | 31020 | 0 / 1 |
| 91 | 69.2 | 26 | 20009 | 1 / 2 |
| 121 | 97.9 | 116 | 48121 | 1 / 2 |
| 151 | 106.9 | 86 | 27703 | 1 / 3 |

### 100 kB, yseq_ (lz4), hot-append

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 6.9 | 0 | 0 | 0 / 0 |
| 30 | 111.4 | 58 | 51640 | 0 / 0 |
| 60 | 229.3 | 8 | 112188 | 1 / 0 |
| 90 | 229.7 | 48 | 64285 | 1 / 1 |
| 121 | 267.4 | 79 | 47 | 1 / 2 |
| 151 | 267.4 | 90 | 72833 | 1 / 2 |

