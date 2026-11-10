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
| 1 kB | yseq_ (lz4) | spread | 202.607542 | 0.37 | 45.3 | 62.7 | 88.2 | 88.2 | 0.82 | 107 | 167 / 43521 | 2 / 2 | 1.30 |
| 5 kB | yseq_ (lz4) | spread | 198.495113 | 0.69 | 71.9 | 105 | 140 | 140 | 1.36 | 103 | 101 / 65223 | 2 / 3 | 2.17 |
| 20 kB | yseq_ (lz4) | spread | 199.020516 | 1.69 | 190 | 219 | 267 | 267 | 2.44 | 109 | 114 / 127082 | 0 / 3 | 4.40 |
| 100 kB | yseq_ (lz4) | spread | 199.336214 | 6.86 | 799 | 1581 | 2016 | 2016 | 7.63 | 264 | 536 / 1048791 | 1 / 2 | 15.69 |
| 1 kB | yseq_ (lz4) | hot | 49.647142 | 0.37 | 50.7 | 115 | 200 | 200 | 0.32 | 621 | 120 / 93871 | 0 / 3 | 2.46 |
| 5 kB | yseq_ (lz4) | hot | 50.128450 | 0.69 | 81.9 | 163 | 259 | 259 | 0.65 | 400 | 5 / 119965 | 0 / 3 | 3.34 |
| 20 kB | yseq_ (lz4) | hot | 49.720056 | 1.69 | 147 | 265 | 411 | 411 | 1.65 | 249 | 97 / 190848 | 0 / 3 | 5.15 |
| 100 kB | yseq_ (lz4) | hot | 50.872510 | 6.86 | 298 | 518 | 777 | 777 | 6.80 | 114 | 107 / 307621 | 0 / 2 | 9.77 |

## Timelines (every 30 s)

### 1 kB, yseq_ (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.4 | 0 | 0 | 0 / 0 |
| 30 | 21.0 | 112 | 11929 | 0 / 0 |
| 61 | 50.5 | 81 | 28839 | 0 / 0 |
| 91 | 62.2 | 76 | 11716 | 1 / 1 |
| 121 | 70.9 | 129 | 35597 | 1 / 1 |
| 151 | 88.2 | 115 | 16279 | 2 / 2 |

### 5 kB, yseq_ (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.7 | 0 | 0 | 0 / 0 |
| 31 | 32.8 | 50 | 15716 | 1 / 1 |
| 61 | 80.0 | 77 | 42371 | 1 / 1 |
| 91 | 93.9 | 43 | 22142 | 2 / 2 |
| 122 | 118.1 | 66 | 57948 | 2 / 2 |
| 152 | 137.9 | 64 | 29428 | 2 / 3 |

### 20 kB, yseq_ (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 1.7 | 0 | 0 | 0 / 0 |
| 30 | 79.2 | 78 | 41413 | 0 / 1 |
| 60 | 189.9 | 55 | 98676 | 0 / 1 |
| 91 | 219.2 | 108 | 48160 | 0 / 2 |
| 121 | 232.9 | 102 | 114432 | 0 / 2 |
| 151 | 266.9 | 77 | 56927 | 0 / 3 |

### 100 kB, yseq_ (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 6.9 | 0 | 0 | 0 / 0 |
| 30 | 372.0 | 58 | 185961 | 0 / 1 |
| 60 | 799.2 | 80 | 404961 | 0 / 1 |
| 91 | 1239.0 | 364 | 627039 | 0 / 1 |
| 121 | 1654.1 | 442 | 860404 | 0 / 1 |
| 151 | 2012.6 | 305 | 20144 | 1 / 2 |

### 1 kB, yseq_ (lz4), hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.4 | 0 | 0 | 0 / 0 |
| 31 | 17.8 | 59 | 9032 | 0 / 1 |
| 61 | 59.0 | 20 | 30321 | 0 / 1 |
| 91 | 71.4 | 80 | 25122 | 0 / 2 |
| 122 | 128.8 | 74 | 64796 | 0 / 2 |
| 152 | 149.1 | 70 | 42386 | 0 / 3 |

### 5 kB, yseq_ (lz4), hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.7 | 0 | 0 | 0 / 0 |
| 31 | 29.8 | 2 | 14711 | 0 / 1 |
| 61 | 93.4 | 1 | 47539 | 0 / 1 |
| 91 | 108.4 | 3 | 37484 | 0 / 2 |
| 122 | 183.5 | 3 | 91592 | 0 / 2 |
| 152 | 201.6 | 2 | 56016 | 0 / 3 |

### 20 kB, yseq_ (lz4), hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 1.7 | 0 | 0 | 0 / 0 |
| 30 | 50.6 | 5 | 24885 | 0 / 1 |
| 60 | 146.8 | 4 | 74085 | 0 / 1 |
| 91 | 158.5 | 3 | 59225 | 0 / 2 |
| 121 | 293.2 | 5 | 145668 | 0 / 2 |
| 151 | 312.1 | 22 | 96058 | 0 / 3 |

### 100 kB, yseq_ (lz4), hot

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 6.9 | 0 | 0 | 0 / 0 |
| 30 | 145.8 | 1 | 69622 | 0 / 0 |
| 61 | 335.0 | 0 | 164284 | 0 / 0 |
| 91 | 341.1 | 4 | 124885 | 0 / 1 |
| 121 | 573.2 | 3 | 278759 | 0 / 1 |
| 151 | 644.2 | 89 | 129333 | 0 / 2 |

