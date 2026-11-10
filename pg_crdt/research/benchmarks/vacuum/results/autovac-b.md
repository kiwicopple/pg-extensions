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
| 1 kB | ydoc_ | spread | 200.084103 | 4.27 | 7.67 | 10.4 | 13.1 | 13.1 | 5.14 | 2.6 | 9631 / 0 | 9 / 0 | 0.18 |
| 5 kB | ydoc_ | spread | 198.981422 | 5.27 | 9.16 | 12.6 | 16.6 | 16.6 | 6.64 | 2.5 | 9959 / 0 | 9 / 0 | 0.22 |
| 20 kB | ydoc_ | spread | 200.639568 | 8.41 | 12.6 | 16.5 | 20.5 | 20.5 | 8.80 | 2.3 | 11667 / 0 | 8 / 0 | 0.25 |
| 100 kB | ydoc_ | spread | 200.744412 | 23.5 | 27.4 | 32.4 | 36.5 | 36.5 | 18.9 | 1.9 | 11072 / 0 | 9 / 0 | 0.34 |
| 1 kB | ydoc_ | hot | 50.836250 | 4.27 | 4.54 | 4.69 | 4.87 | 4.87 | 1.51 | 3.2 | 823 / 0 | 5 / 0 | 0.03 |
| 5 kB | ydoc_ | hot | 49.393556 | 5.27 | 5.59 | 6.05 | 6.17 | 6.17 | 2.08 | 3.0 | 5506 / 0 | 5 / 0 | 0.05 |
| 20 kB | ydoc_ | hot | 50.661794 | 8.41 | 8.84 | 9.11 | 9.40 | 9.40 | 4.25 | 2.2 | 796 / 0 | 5 / 0 | 0.06 |
| 100 kB | ydoc_ | hot | 49.320919 | 23.5 | 23.9 | 24.5 | 25.3 | 25.3 | 14.5 | 1.7 | 2117 / 0 | 5 / 0 | 0.12 |

## Timelines (every 30 s)

### 1 kB, ydoc_, spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 4.3 | 0 | 0 | 0 / 0 |
| 30 | 5.9 | 8009 | 0 | 0 / 0 |
| 60 | 7.7 | 598 | 0 | 3 / 0 |
| 90 | 9.2 | 6169 | 0 | 3 / 0 |
| 121 | 10.5 | 1085 | 0 | 6 / 0 |
| 151 | 11.8 | 6348 | 0 | 6 / 0 |

### 5 kB, ydoc_, spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 5.3 | 0 | 0 | 0 / 0 |
| 30 | 6.9 | 9457 | 0 | 0 / 0 |
| 61 | 9.3 | 1282 | 0 | 3 / 0 |
| 91 | 10.7 | 9345 | 0 | 3 / 0 |
| 121 | 12.9 | 1597 | 0 | 6 / 0 |
| 152 | 14.8 | 8131 | 0 | 6 / 0 |

### 20 kB, ydoc_, spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 8.4 | 0 | 0 | 0 / 0 |
| 31 | 9.9 | 6758 | 0 | 2 / 0 |
| 61 | 13.0 | 10539 | 0 | 2 / 0 |
| 92 | 14.0 | 6503 | 0 | 5 / 0 |
| 122 | 17.0 | 8901 | 0 | 5 / 0 |
| 152 | 18.4 | 8664 | 0 | 8 / 0 |

### 100 kB, ydoc_, spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 23.5 | 0 | 0 | 0 / 0 |
| 30 | 26.2 | 10023 | 0 | 0 / 0 |
| 61 | 27.9 | 6601 | 0 | 3 / 0 |
| 91 | 31.4 | 10258 | 0 | 3 / 0 |
| 121 | 32.5 | 9372 | 0 | 6 / 0 |
| 151 | 35.1 | 9586 | 0 | 6 / 0 |

### 1 kB, ydoc_, hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 4.3 | 0 | 0 | 0 / 0 |
| 30 | 4.4 | 214 | 0 | 0 / 0 |
| 60 | 4.5 | 726 | 0 | 2 / 0 |
| 91 | 4.6 | 823 | 0 | 2 / 0 |
| 121 | 4.7 | 143 | 0 | 4 / 0 |
| 151 | 4.8 | 241 | 0 | 4 / 0 |

### 5 kB, ydoc_, hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 5.3 | 0 | 0 | 0 / 0 |
| 30 | 5.5 | 429 | 0 | 0 / 0 |
| 60 | 5.6 | 220 | 0 | 1 / 0 |
| 91 | 5.8 | 1222 | 0 | 1 / 0 |
| 121 | 6.1 | 184 | 0 | 4 / 0 |
| 152 | 6.1 | 429 | 0 | 4 / 0 |

### 20 kB, ydoc_, hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 8.4 | 0 | 0 | 0 / 0 |
| 30 | 8.6 | 569 | 0 | 0 / 0 |
| 61 | 8.8 | 41 | 0 | 1 / 0 |
| 91 | 9.0 | 394 | 0 | 1 / 0 |
| 121 | 9.1 | 362 | 0 | 3 / 0 |
| 152 | 9.2 | 569 | 0 | 3 / 0 |

### 100 kB, ydoc_, hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 23.5 | 0 | 0 | 0 / 0 |
| 31 | 23.7 | 792 | 0 | 0 / 0 |
| 61 | 24.0 | 1230 | 0 | 2 / 0 |
| 91 | 24.2 | 1683 | 0 | 2 / 0 |
| 122 | 24.5 | 1877 | 0 | 3 / 0 |
| 152 | 25.0 | 1950 | 0 | 3 / 0 |

