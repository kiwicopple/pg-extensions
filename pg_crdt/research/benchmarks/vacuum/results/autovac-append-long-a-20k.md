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
| 20 kB | yseq_ (lz4) | spread-append | 199.444257 | 1.69 | 174 | 230 | 251 | 306 | 1.93 | 130 | 240 / 147027 | 9 / 9 | 3.84 |

## Timelines (every 30 s)

### 20 kB, yseq_ (lz4), spread-append

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 1.7 | 0 | 0 | 0 / 0 |
| 30 | 96.7 | 46 | 47403 | 0 / 0 |
| 61 | 188.8 | 85 | 94565 | 0 / 0 |
| 91 | 230.0 | 105 | 26535 | 1 / 1 |
| 121 | 230.0 | 184 | 83108 | 1 / 1 |
| 151 | 209.1 | 64 | 32049 | 2 / 2 |
| 182 | 209.1 | 118 | 85581 | 2 / 2 |
| 212 | 217.9 | 104 | 34099 | 3 / 3 |
| 242 | 217.9 | 143 | 88063 | 3 / 3 |
| 272 | 220.7 | 112 | 32912 | 4 / 4 |
| 303 | 220.7 | 132 | 89648 | 4 / 4 |
| 334 | 223.3 | 107 | 36785 | 5 / 5 |
| 364 | 223.3 | 114 | 93055 | 5 / 5 |
| 394 | 234.1 | 96 | 37887 | 6 / 6 |
| 424 | 234.1 | 109 | 98557 | 6 / 6 |
| 455 | 306.0 | 48 | 8256 | 7 / 7 |
| 485 | 306.0 | 126 | 68456 | 7 / 7 |
| 515 | 232.7 | 119 | 13310 | 8 / 8 |
| 545 | 233.0 | 148 | 74382 | 8 / 8 |
| 576 | 251.0 | 92 | 13214 | 9 / 9 |

