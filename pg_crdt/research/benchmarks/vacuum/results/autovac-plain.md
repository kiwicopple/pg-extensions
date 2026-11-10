# Steady state with autovacuum on (default settings)

Postgres: 16.4 (Postgres.app)
Machine:  Apple M4, 10 CPU, 24 GB, macOS 27.0.1
Date:     2026-11-10 18:43 +08
Settings: autovacuum=on, autovacuum_naptime=1min, autovacuum_vacuum_cost_delay=2ms, autovacuum_vacuum_cost_limit=-1, autovacuum_vacuum_scale_factor=0.2, autovacuum_vacuum_threshold=50, checkpoint_timeout=30min, default_toast_compression=pglz, fsync=on, full_page_writes=on, max_wal_size=2GB, shared_buffers=512MB, synchronous_commit=on, wal_compression=off, wal_level=replica
Code:     git cdea487; NDOCS=100; QUICK=0

100 documents per run. 'spread': 200 keystrokes/s in total over all documents (4 clients). 'hot': 50 keystrokes/s on one document (2 clients). 180 s per run, sampled every 5 s. Sizes in MB: table + TOAST + indexes (for ydoc_ every crdt.ydoc_* table). 'live' is pgstattuple tuple_len (heap + TOAST) at the end. 'peak dead' is the largest n_dead_tup seen in a sample (heap / TOAST). 'autovacuums' counts autovacuum runs on the tables / their TOAST relations during the run.

## Summary

| size | shape | scenario | edits/s achieved | loaded | at 60 s | at 120 s | end | peak | live at end | end / live | peak dead heap / TOAST | autovacuums heap / TOAST | WAL MB/s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 kB | plain text (lz4) | spread | 200.814747 | 0.19 | 1.06 | 1.25 | 1.16 | 1.25 | 0.15 | 7.9 | 616 / 0 | 2 / 0 | 0.09 |
| 5 kB | plain text (lz4) | spread | 199.956268 | 0.62 | 49.2 | 64.2 | 64.6 | 64.6 | 0.46 | 140 | 97 / 33996 | 0 / 3 | 1.03 |
| 20 kB | plain text (lz4) | spread | 198.337538 | 1.58 | 152 | 192 | 186 | 192 | 1.43 | 130 | 114 / 92399 | 0 / 3 | 3.11 |
| 100 kB | plain text (lz4) | spread | 202.483982 | 6.80 | 768 | 1491 | 1784 | 1784 | 6.55 | 272 | 419 / 973646 | 2 / 2 | 14.53 |
| 1 kB | plain text (lz4) | hot | 50.856375 | 0.19 | 2.38 | 2.95 | 3.17 | 3.17 | 0.13 | 25 | 758 / 0 | 2 / 0 | 0.04 |
| 5 kB | plain text (lz4) | hot | 50.116534 | 0.62 | 11.2 | 14.7 | 17.4 | 17.4 | 0.42 | 41 | 3 / 8412 | 0 / 3 | 0.31 |
| 20 kB | plain text (lz4) | hot | 50.073336 | 1.58 | 43.9 | 50.7 | 57.8 | 57.8 | 1.37 | 42 | 5 / 26911 | 0 / 3 | 0.95 |
| 100 kB | plain text (lz4) | hot | 49.764117 | 6.80 | 217 | 219 | 246 | 246 | 6.46 | 38 | 4 / 113046 | 0 / 2 | 3.99 |

## Timelines (every 30 s)

### 1 kB, plain text (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.2 | 0 | 0 | 0 / 0 |
| 30 | 0.6 | 296 | 0 | 0 / 0 |
| 60 | 1.1 | 564 | 0 | 0 / 0 |
| 91 | 1.2 | 270 | 0 | 1 / 0 |
| 121 | 1.2 | 431 | 0 | 1 / 0 |
| 151 | 1.2 | 240 | 0 | 2 / 0 |

### 5 kB, plain text (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.6 | 0 | 0 | 0 / 0 |
| 30 | 22.7 | 10 | 12097 | 0 / 1 |
| 61 | 54.6 | 77 | 30478 | 0 / 1 |
| 91 | 64.2 | 25 | 13062 | 0 / 2 |
| 121 | 64.2 | 24 | 30906 | 0 / 2 |
| 152 | 64.4 | 62 | 13536 | 0 / 3 |

### 20 kB, plain text (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 1.6 | 0 | 0 | 0 / 0 |
| 30 | 73.3 | 65 | 35555 | 0 / 1 |
| 61 | 167.9 | 67 | 84201 | 0 / 1 |
| 91 | 192.0 | 29 | 36671 | 0 / 2 |
| 122 | 192.0 | 69 | 83959 | 0 / 2 |
| 152 | 186.4 | 65 | 38192 | 0 / 3 |

### 100 kB, plain text (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 6.8 | 0 | 0 | 0 / 0 |
| 30 | 363.3 | 88 | 176870 | 0 / 1 |
| 60 | 768.2 | 84 | 383420 | 0 / 1 |
| 90 | 1194.9 | 138 | 601428 | 1 / 1 |
| 121 | 1539.2 | 419 | 804850 | 1 / 1 |
| 151 | 1781.8 | 207 | 31015 | 2 / 2 |

### 1 kB, plain text (lz4), hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.2 | 0 | 0 | 0 / 0 |
| 30 | 1.1 | 260 | 0 | 0 / 0 |
| 61 | 2.6 | 639 | 0 | 0 / 0 |
| 91 | 3.0 | 297 | 0 | 1 / 0 |
| 121 | 3.0 | 691 | 0 | 1 / 0 |
| 152 | 3.2 | 287 | 0 | 2 / 0 |

### 5 kB, plain text (lz4), hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.6 | 0 | 0 | 0 / 0 |
| 30 | 5.8 | 2 | 3657 | 0 / 1 |
| 61 | 12.2 | 2 | 8259 | 0 / 1 |
| 91 | 13.6 | 2 | 3663 | 0 / 2 |
| 121 | 16.2 | 2 | 8412 | 0 / 2 |
| 152 | 17.4 | 1 | 3828 | 0 / 3 |

### 20 kB, plain text (lz4), hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 1.6 | 0 | 0 | 0 / 0 |
| 30 | 22.8 | 2 | 10920 | 0 / 1 |
| 61 | 47.6 | 2 | 24933 | 0 / 1 |
| 91 | 50.1 | 4 | 11893 | 0 / 2 |
| 122 | 55.8 | 5 | 26911 | 0 / 2 |
| 152 | 57.8 | 2 | 14010 | 0 / 3 |

### 100 kB, plain text (lz4), hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 6.9 | 0 | 0 | 0 / 0 |
| 30 | 110.1 | 3 | 52217 | 0 / 0 |
| 60 | 217.1 | 1 | 107069 | 0 / 0 |
| 91 | 217.2 | 2 | 54013 | 0 / 1 |
| 121 | 237.1 | 1 | 1061 | 0 / 2 |
| 151 | 237.1 | 2 | 61288 | 0 / 2 |

