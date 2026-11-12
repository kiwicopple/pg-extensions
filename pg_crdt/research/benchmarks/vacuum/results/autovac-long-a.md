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
| 5 kB | yseq_ (lz4) | spread | 200.088467 | 0.69 | 90.6 | 112 | 336 | 336 | 2.77 | 121 | 372 / 153217 | 9 / 9 | 3.95 |
| 20 kB | yseq_ (lz4) | spread | 199.311877 | 1.69 | 181 | 224 | 581 | 581 | 4.35 | 133 | 173 / 285930 | 6 / 10 | 6.64 |

## Timelines (every 30 s)

### 5 kB, yseq_ (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0.7 | 0 | 0 | 0 / 0 |
| 30 | 43.4 | 21 | 21519 | 0 / 0 |
| 60 | 90.6 | 240 | 47838 | 0 / 0 |
| 91 | 111.9 | 173 | 16744 | 1 / 1 |
| 121 | 112.3 | 308 | 53066 | 1 / 1 |
| 151 | 138.1 | 248 | 23274 | 2 / 2 |
| 181 | 138.1 | 201 | 66392 | 2 / 2 |
| 212 | 171.7 | 174 | 28923 | 3 / 3 |
| 242 | 172.5 | 208 | 79327 | 3 / 3 |
| 272 | 200.5 | 309 | 32710 | 4 / 4 |
| 302 | 200.5 | 142 | 91704 | 4 / 4 |
| 333 | 235.5 | 200 | 37763 | 5 / 5 |
| 363 | 235.5 | 116 | 103273 | 5 / 5 |
| 393 | 259.4 | 290 | 41787 | 6 / 6 |
| 424 | 259.4 | 220 | 114310 | 6 / 6 |
| 455 | 294.9 | 284 | 47791 | 7 / 7 |
| 485 | 294.9 | 255 | 126514 | 7 / 7 |
| 516 | 315.8 | 164 | 55702 | 8 / 8 |
| 546 | 315.8 | 234 | 138491 | 8 / 8 |
| 576 | 336.4 | 315 | 59668 | 9 / 9 |

### 20 kB, yseq_ (lz4), spread

| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |
| ---: | ---: | ---: | ---: | --- |
| 0 | 1.7 | 0 | 0 | 0 / 0 |
| 30 | 69.0 | 106 | 34688 | 0 / 1 |
| 60 | 181.0 | 54 | 93226 | 0 / 1 |
| 91 | 223.4 | 93 | 41188 | 1 / 2 |
| 121 | 224.1 | 59 | 109793 | 1 / 2 |
| 151 | 271.9 | 60 | 47540 | 1 / 3 |
| 181 | 271.9 | 98 | 125268 | 1 / 3 |
| 212 | 307.4 | 33 | 55733 | 2 / 4 |
| 242 | 307.4 | 11 | 140759 | 2 / 4 |
| 272 | 350.6 | 122 | 59096 | 3 / 5 |
| 303 | 350.6 | 46 | 155828 | 3 / 5 |
| 333 | 405.4 | 100 | 60526 | 3 / 6 |
| 363 | 405.6 | 124 | 166186 | 3 / 6 |
| 393 | 428.8 | 71 | 73808 | 4 / 7 |
| 424 | 428.8 | 108 | 186598 | 4 / 7 |
| 454 | 491.0 | 112 | 63774 | 4 / 8 |
| 484 | 491.0 | 88 | 182216 | 4 / 8 |
| 514 | 433.7 | 85 | 93745 | 5 / 9 |
| 545 | 455.5 | 79 | 220996 | 5 / 9 |
| 575 | 580.5 | 95 | 62092 | 6 / 10 |

