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
| 5 kB | yseq_ (lz4) | spread-append | 199.107382 | 0.69 | 71.6 | 89.9 | 122 | 122 | 0.96 | 127 | 216 / 58126 | 8 / 9 | 1.70 |

## Timelines (every 30 s)

### 5 kB, yseq_ (lz4), spread-append

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.7 | 0 | 0 | 0 / 0 |
| 30 | 35.3 | 60 | 17161 | 0 / 0 |
| 60 | 71.6 | 18 | 36443 | 0 / 0 |
| 91 | 89.9 | 86 | 12067 | 0 / 1 |
| 121 | 89.9 | 155 | 37456 | 0 / 1 |
| 151 | 95.0 | 154 | 14004 | 1 / 2 |
| 181 | 95.0 | 128 | 38380 | 1 / 2 |
| 212 | 96.0 | 133 | 14600 | 2 / 3 |
| 242 | 96.0 | 113 | 38400 | 2 / 3 |
| 272 | 96.2 | 53 | 15182 | 3 / 4 |
| 303 | 96.8 | 95 | 40362 | 3 / 4 |
| 334 | 98.1 | 111 | 16926 | 4 / 5 |
| 364 | 98.1 | 99 | 45236 | 4 / 5 |
| 394 | 106.8 | 189 | 20672 | 5 / 6 |
| 424 | 107.0 | 125 | 50845 | 5 / 6 |
| 455 | 117.3 | 50 | 20645 | 6 / 7 |
| 485 | 117.3 | 76 | 51510 | 6 / 7 |
| 515 | 120.8 | 112 | 22298 | 7 / 8 |
| 545 | 120.8 | 113 | 52888 | 7 / 8 |
| 576 | 122.4 | 114 | 22768 | 8 / 9 |

