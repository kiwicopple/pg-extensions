# Checkpoint frequency and full-page images

Postgres: 16.4 (Postgres.app)
Machine:  Apple M4, 10 CPU, 24 GB, macOS 27.0.1
Date:     2026-11-10 19:09 +08
Settings: autovacuum=off, autovacuum_naptime=1min, autovacuum_vacuum_cost_delay=2ms, autovacuum_vacuum_cost_limit=-1, autovacuum_vacuum_scale_factor=0.2, autovacuum_vacuum_threshold=50, checkpoint_timeout=5min, default_toast_compression=pglz, fsync=on, full_page_writes=on, max_wal_size=8GB, shared_buffers=512MB, synchronous_commit=on, wal_compression=off, wal_level=replica
Code:     git cdea487; NDOCS=100; QUICK=0

100 documents, 100 keystrokes/s (2 clients, random document and position, 80% insert / 20% delete) for 90 s after a CHECKPOINT, with checkpoint_timeout as given (max_wal_size 8GB, so only timed checkpoints). Bytes per edit from pg_waldump --stats=record.

| size | shape | checkpoint_timeout | checkpoints in run | edits | WAL per edit | records | FPI | FPI share | WAL MB/s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 5 kB | plain text (lz4) | 30s | 3 | 8920 | 5282 | 5056 | 226 | 4% | 0.50 |
| 5 kB | plain text (lz4) | 5min | 0 | 9051 | 5109 | 5059 | 50 | 1% | 0.49 |
| 5 kB | yseq_ (lz4) | 30s | 3 | 8870 | 8084 | 7722 | 363 | 4% | 0.76 |
| 5 kB | yseq_ (lz4) | 5min | 0 | 9115 | 7819 | 7754 | 65 | 1% | 0.76 |
| 5 kB | ydoc_ | 30s | 3 | 8983 | 2427 | 1116 | 1311 | 54% | 0.23 |
| 5 kB | ydoc_ | 5min | 0 | 8791 | 1382 | 1126 | 256 | 19% | 0.13 |
| 100 kB | plain text (lz4) | 30s | 3 | 9223 | 75551 | 73036 | 2516 | 3% | 7.38 |
| 100 kB | plain text (lz4) | 5min | 0 | 9170 | 73763 | 73020 | 743 | 1% | 7.17 |
| 100 kB | yseq_ (lz4) | 30s | 3 | 9133 | 78901 | 76123 | 2778 | 4% | 7.64 |
| 100 kB | yseq_ (lz4) | 5min | 0 | 9112 | 76916 | 76152 | 765 | 1% | 7.43 |
| 100 kB | ydoc_ | 30s | 3 | 9060 | 5945 | 1267 | 4679 | 79% | 0.57 |
| 100 kB | ydoc_ | 5min | 0 | 8958 | 3154 | 1305 | 1848 | 59% | 0.30 |

