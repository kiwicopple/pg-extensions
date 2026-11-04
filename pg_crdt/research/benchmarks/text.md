# Text CRDT benchmarks: column (`yseq_`) against tables (`ydoc_`)

2026-11-05. Script: [`bench/text-compare.sh`](../../bench/text-compare.sh). It loads `pg_crdt--0.0.1.sql` and both `impl.sql` files into one database of one throwaway cluster (the two shapes use different prefixes and coexist) and runs the same workloads on both, so every row here comes from one run on one machine. The per-shape numbers in the two `NOTES.md` files come from different runs and settings; where they differ from this page, this page is the comparison.

Design: [`research/text.md`](../text.md). Shape A is `experiments/text-column` (a `crdt.yseq` jsonb column, with `compression lz4`). Shape B is `experiments/text-table` (table-backed documents; the app's table holds `body_doc bigint`), since promoted into the extension (`pg_crdt--0.0.1.sql`; `bench/text-compare.sh` now loads it from there). Both use the YjsMod order and the causal rules V0 to V7 on the untrusted path.

## Setup

| | |
| --- | --- |
| Postgres | 16.4 (Postgres.app), native |
| Machine | Apple M4, 10 CPU, 24 GB, macOS 27.0.1 |
| Cluster | throwaway, Unix socket; `shared_buffers=512MB`, `fsync=off`, `full_page_writes=on`, `wal_compression=off`, `synchronous_commit=on`, `checkpoint_timeout=30min`, `max_wal_size=8GB`, autovacuum on, default `pglz` TOAST compression except where a column says lz4 |
| Code | `b8bffd2` plus the uncommitted review fixes to both `impl.sql` files as they were at 00:56 (md5 `0b12b421...` for A, `7c4401fe...` for B). Four earlier full runs, made on the committed files and while the fixes were being written, agree with it (see "Noise"). |
| Run | `bench/text-compare.sh` (full, about 4 minutes), single run; see "Noise" |

**The posts table.** 1,000 posts of about 5 kB (average 5,285 bytes of prose) and one of 100 kB (106,595 bytes). Each has an edit history: the first text typed by `alice`, then 40 random edits (800 for the 100 kB post) by `alice`, `bob` and `carol`: 70% inserts of one to five words, 30% deletes of 5 to 40 characters. A 5 kB post ends with about 100 runs (B: 100 item rows). Both shapes replay the same plan, and the script checks that every post has the same text in A, B and the plain copy. The text is generated from a vocabulary of 4,000 pseudo-words with Zipf-like frequencies.

**Schemas compared.**

| Name | Table |
| --- | --- |
| plain text | `posts_plain(id, title, body text)`, and a copy with `compression lz4` for the latency baseline |
| A | `posts_a(id, title, body crdt.yseq compression lz4)`; `posts_a_pglz` with the default compression for storage only |
| A + GIN | the same, plus `create index using gin (to_tsvector('english', crdt.yseq_value(body)))` |
| B | `posts_b(id, title, body_doc bigint references crdt.ydoc_docs)` and the nine `crdt.ydoc_*` tables |
| B + cache | `posts_b_fts(id, title, body_doc, body_text)` with a GIN index on `to_tsvector('english', body_text)`; `body_text` is refreshed with `crdt.ydoc_value(body_doc)` |

**Method.** Latency: `pgbench` with one client (more in f), one statement per transaction (`-M simple`), the per-transaction log, so mean and 95th percentile are what the client sees, round trip included. WAL: `pg_current_wal_insert_lsn()` before and after a run that follows a `CHECKPOINT`, divided by the transactions, with `full_page_writes=on`, so the first touch of each page after the checkpoint is in the number as a full-page image. Every edit run uses a fresh post built from the same plan. Edits go through the blessed API: A as `update posts set body = crdt.yseq_insert(body, pos, 'x', 'bench') where id = ...`, B as `select crdt.ydoc_insert((select body_doc from posts_b where id = ...), pos, 'x', 'bench')`. B's call returns the op; A's does not (an app that needs A's op adds `returning crdt.yseq_diff(...)`, which is not measured).

Limitations: one machine, one Postgres version, a laptop SSD (the same workload with `fsync=on` is in x and does not change the picture on this machine, where the flush is cheap; a server with a slower flush would make WAL volume matter more). The 5 kB and 100 kB posts are lightly edited. The heavily edited case is the automerge-paper document in workload e. `ydoc_compact` is not part of the default setup.

## a. Storage

1,001 posts. Sizes after `vacuum full`: table, TOAST and indexes (`pg_total_relation_size`, including the primary key); B adds the nine `crdt.ydoc_*` tables.

| schema | table + TOAST (MB) | indexes (MB) | `crdt.ydoc_*` (MB) | total (MB) | KB per post | total / plain text (pglz) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| plain text, pglz (default) | 4.11 | 0.04 | 0 | 4.15 | 4.2 | 1.00 |
| plain text, lz4 | 5.42 | 0.04 | 0 | 5.46 | 5.6 | 1.32 |
| A: yseq, pglz | 5.52 | 0.04 | 0 | 5.55 | 5.7 | 1.34 |
| A: yseq, lz4 | 6.11 | 0.04 | 0 | 6.15 | 6.3 | 1.48 |
| B: ydoc | 0.06 | 0.04 | 23.28 | 23.38 | 23.9 | 5.64 |

With full-text search support (a GIN index, and for B the cached text column, whose TOAST data is in the table column):

| schema | table + TOAST (MB) | indexes (MB) | `crdt.ydoc_*` (MB) | total (MB) | KB per post | total / plain text + GIN |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| plain text + GIN | 4.11 | 3.35 | 0 | 7.46 | 7.6 | 1.00 |
| A + GIN on the expression | 6.11 | 3.35 | 0 | 9.46 | 9.7 | 1.27 |
| B + cached text + GIN | 4.12 | 3.36 | 23.28 | 30.77 | 31.5 | 4.12 |

Stored size of single posts, in bytes:

| post | plain text | A, pglz | A, lz4 | A state as JSON text | B item rows | B item heap bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 kB (post 1) | 5,174 | 4,813 | 5,446 | 7,044 | 100 | 13,567 |
| 100 kB | 106,595 | 84,067 | 95,908 | 146,029 | 1,983 | 272,153 |

B stores a row per run: the 5 kB post is 100 rows and 13.6 kB of heap, and with the indexes and the block, document and dependency tables the posts average 23.9 KB (about 230 bytes per run). That is 3.8 times A with lz4 (23.4 MB against 6.15 MB). `ydoc_compact` on all 1,001 documents took 0.5 s and removed 17% of the rows (101,480 to 84,033) and about 6% of the bytes (42.05 to 39.45 MB, a figure that also counts the workloads' scratch documents), because random-position edits leave runs that cannot merge.

## b. Keystroke editing

One character per statement. 'random' edits a random position in the first half of the post, 'cursor' types forward from the middle, 'backspace' deletes backwards from the middle. 1,000 transactions per run on 5 kB posts, 500 on 100 kB posts. Mean and p95 in ms, WAL in bytes per edit.

| post | edit | shape | mean ms | p95 ms | WAL B per edit |
| --- | --- | --- | ---: | ---: | ---: |
| 5 kB | insert, random | plain text (lz4) | 0.07 | 0.09 | 5,545 |
| 5 kB | insert, random | A | 0.28 | 0.41 | 18,564 |
| 5 kB | insert, random | A + GIN | 0.79 | 0.92 | 33,340 |
| 5 kB | insert, random | B | 0.32 | 0.38 | 985 |
| 5 kB | insert, random | B + cache refreshed on every keystroke | 1.17 | 1.30 | 26,390 |
| 5 kB | delete, random | A | 0.27 | 0.41 | 15,080 |
| 5 kB | delete, random | A + GIN | 0.75 | 0.85 | 31,369 |
| 5 kB | delete, random | B | 0.29 | 0.36 | 1,189 |
| 5 kB | insert, cursor | A | 0.18 | 0.22 | 6,611 |
| 5 kB | insert, cursor | A + GIN | 0.70 | 0.70 | 23,899 |
| 5 kB | insert, cursor | B | 0.25 | 0.26 | 404 |
| 5 kB | backspace | A | 0.18 | 0.22 | 6,174 |
| 5 kB | backspace | A + GIN | 0.66 | 0.69 | 19,842 |
| 5 kB | backspace | B | 0.29 | 0.38 | 1,101 |
| 100 kB | insert, random | plain text (lz4) | 0.69 | 0.95 | 82,054 |
| 100 kB | insert, random | A | 0.85 | 1.14 | 114,391 |
| 100 kB | insert, random | A + GIN | 9.94 | 10.2 | 236,373 |
| 100 kB | insert, random | B | 0.36 | 0.40 | 1,970 |
| 100 kB | insert, random | B + cache refreshed on every keystroke | 11.6 | 11.3 | 216,216 |
| 100 kB | delete, random | A | 0.79 | 0.98 | 112,583 |
| 100 kB | delete, random | A + GIN | 9.93 | 10.4 | 272,550 |
| 100 kB | delete, random | B | 0.31 | 0.36 | 3,765 |
| 100 kB | insert, cursor | A | 0.73 | 0.87 | 106,983 |
| 100 kB | insert, cursor | A + GIN | 9.89 | 9.94 | 245,624 |
| 100 kB | insert, cursor | B | 0.33 | 0.34 | 1,275 |
| 100 kB | backspace | A | 0.67 | 0.81 | 106,042 |
| 100 kB | backspace | A + GIN | 9.67 | 9.37 | 263,383 |
| 100 kB | backspace | B | 0.35 | 0.41 | 5,133 |

Where the shapes cross, random-position insert of one character, 1,000 transactions, fresh posts of 1, 5, 20, 50 and 100 kB (8 edits per kB). Each cell is mean ms / WAL bytes per edit.

| post | plain text (lz4) | A | A + GIN | B |
| --- | --- | --- | --- | --- |
| 1 kB | 0.03 / 703 | 0.21 / 11,123 | 0.35 / 15,301 | 0.30 / 861 |
| 5 kB | 0.06 / 5,569 | 0.29 / 19,168 | 0.78 / 32,775 | 0.32 / 1,084 |
| 20 kB | 0.15 / 17,707 | 0.39 / 36,664 | 2.34 / 88,186 | 0.34 / 1,287 |
| 50 kB | 0.33 / 39,309 | 0.53 / 69,886 | 5.35 / 183,962 | 0.35 / 1,465 |
| 100 kB | 0.62 / 83,006 | 0.89 / 122,390 | 10.3 / 314,534 | 0.37 / 1,712 |

A's WAL per edit at 1 kB (11 kB) is more than twice what a one-kilobyte value should need; I did not decompose it. The likely cause is full-page images of the heap and TOAST pages that each update starts on, but that was not checked with `pg_waldump`.

Also with `fsync=on` (x, cluster restarted, 500 and 250 transactions): 5 kB random insert A 0.24 ms, B 0.34 ms; 100 kB A 0.81 ms, B 0.39 ms; WAL as above. On this machine a commit flush costs almost nothing, so latency does not change.

## c. Form save

The app loads a post, the user rewrites one 300-character paragraph, the app saves the whole text. 200 saves per run, each from the previous text. The new text comes from a table, the same for every shape, so no client-to-server transfer is in the timing. A: `update posts set body = crdt.yseq_set(body, $text, 'bench', base => body)`. B: `select crdt.ydoc_set(body_doc, $text, 'bench', crdt.ydoc_base(body_doc))`. The 'two-way' rows have no base: the diff runs against the current text, which reverts concurrent saves that the editor had not loaded. The final text of every run is checked against the last saved text.

| post | shape | mean ms | p95 ms | WAL B per save |
| --- | --- | ---: | ---: | ---: |
| 5 kB | plain text (lz4) | 0.13 | 0.25 | 6,455 |
| 5 kB | A, three-way | 3.15 | 3.89 | 13,975 |
| 5 kB | A, two-way | 0.45 | 0.53 | 13,363 |
| 5 kB | A + GIN, three-way | 4.29 | 5.58 | 80,838 |
| 5 kB | B, three-way | 1.16 | 1.81 | 4,626 |
| 5 kB | B, two-way | 0.83 | 1.16 | 4,627 |
| 5 kB | B + cache (save and refresh in one transaction) | 2.26 | 2.74 | 38,181 |
| 100 kB | plain text (lz4) | 0.25 | 0.62 | 75,119 |
| 100 kB | A, three-way | 11.8 | 13.2 | 118,152 |
| 100 kB | A, two-way | 1.60 | 1.76 | 112,896 |
| 100 kB | A + GIN, three-way | 21.7 | 22.7 | 323,154 |
| 100 kB | B, three-way | 3.35 | 3.90 | 7,547 |
| 100 kB | B, two-way | 2.31 | 2.64 | 9,296 |
| 100 kB | B + cache | 14.9 | 15.7 | 179,988 |

Two things the timing leaves out. A's base is the whole loaded column value (7,044 bytes of JSON for the 5 kB post, 146,029 for the 100 kB post). In this run the base is `body` itself, so nothing crosses the network; an app that keeps the base between loading the form and saving it holds or ships that state. B's base is `{"g": n, "v": {...}}`, a few dozen bytes. And A's three-way `set` costs 7 times its two-way `set` (3.15 against 0.45 ms at 5 kB, 11.8 against 1.60 ms at 100 kB); B's costs 1.4 times.

## d. Reads

pgbench, one client, 2,000 transactions per run, one statement each, mean / p95 in ms. The posts are in shared_buffers.

Render the body of one post (a random post for 5 kB):

| post | plain text | A: `yseq_value(body)` | B: `ydoc_value(body_doc)` | B: cached `body_text` |
| --- | ---: | ---: | ---: | ---: |
| 5 kB | 0.03 / 0.04 | 0.06 / 0.07 | 0.09 / 0.09 | 0.04 / 0.04 |
| 100 kB | 0.26 / 0.32 | 0.27 / 0.35 | 0.43 / 0.48 | 0.26 / 0.31 |

List 50 posts with `left(text, 200)` (`where id between $1 and $1 + 49`, 500 transactions):

| query | mean ms | p95 ms |
| --- | ---: | ---: |
| plain text column | 0.17 | 0.19 |
| A: `left(crdt.yseq_value(body), 200)` | 0.67 | 0.70 |
| B: `left(crdt.ydoc_value(body_doc), 200)` | 1.04 | 1.10 |
| B: `left(body_text, 200)` from the cached column | 0.17 | 0.18 |

Full-text search: `to_tsvector('english', ...) @@ to_tsquery('simple', 'cula & gehagef')`, 63 of the 1,001 posts match. The index rows use a GIN index (A on the expression over `yseq_value(body)`, B on the cached column). The 'no index' rows tokenize every post per query.

| query | mean ms | p95 ms |
| --- | ---: | ---: |
| plain text, GIN | 0.06 | 0.06 |
| A, expression GIN index | 0.07 | 0.07 |
| B, GIN on cached `body_text` | 0.06 | 0.06 |
| A, no index | 375 | 389 |
| B, no index, no cache | 381 | 392 |

The cached column costs: filling it for 1,001 posts (`update posts_b_fts set body_text = crdt.ydoc_value(body_doc)`, GIN index in place) took 609 ms. Per keystroke it is too dear (b: 1.17 ms and 26 kB of WAL at 5 kB, 11.6 ms and 216 kB at 100 kB, against 0.32 and 0.36 ms for the edit alone). Per save it roughly doubles the cost at 5 kB (c: 2.26 against 1.16 ms) and quadruples it at 100 kB (14.9 against 3.35 ms). The cache lags the document by the refresh interval. A's index is always current, and costs 2.8 times the keystroke at 5 kB (0.79 against 0.28 ms) and 12 times at 100 kB (9.94 against 0.85 ms), because every update of `body` recomputes `to_tsvector` for the whole text.

## e. The untrusted write path

The automerge-paper editing trace (259,778 single-character edits by one writer, final text 104,852 characters), as ops with `v`, through `yseq_apply` (an UPDATE of the row) and `ydoc_apply`, one call per transaction, replica id `paper`. Both replays end with the trace's final text (md5 checked). 'batch100' is the reference's batching: 2,598 calls of 100 patches. 'single ops' is one op per call, the first 5,000 ops (the document grows from 0 to about 2.5 kB).

| replay | shape | calls | total s | mean ms per call | p95 ms | WAL B per call |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| batch100 | A: `yseq_apply` | 2,598 | 16.0 | 6.16 | 10.9 | 126,486 |
| batch100 | B: `ydoc_apply` | 2,598 | 2.0 | 0.75 | 1.49 | 3,797 |
| single ops | A: `yseq_apply` | 5,000 | 3.6 | 0.73 | 1.01 | 4,500 |
| single ops | B: `ydoc_apply` | 5,000 | 1.9 | 0.38 | 0.44 | 614 |

**A heavily edited 100 kB post.** The post the batch100 replay leaves: the trace's final text after 182,315 typed and 77,463 deleted characters. Random-position insert of one character, 500 transactions, and the render of the body. B's bytes are the document's item rows scaled by the table-wide ratio of heap plus indexes to heap (an estimate that includes free space of the other documents); A's are the stored, compressed column value.

| shape | runs / item rows | stored bytes | render ms | insert 1 char mean / p95 ms | WAL B per edit |
| --- | ---: | ---: | ---: | ---: | ---: |
| A | 12,397 | 219,749 | 0.49 | 2.23 / 2.42 | 280,347 |
| B, as replayed | 13,822 | about 1.92 MB | 1.48 | 0.40 / 0.45 | 4,541 |
| B after `ydoc_compact` | 13,366 | about 1.86 MB | 1.43 | 0.40 / 0.47 | 4,521 |

The batched replay leaves B with 13,822 rows. A replay that applies one patch per call leaves 83,253 rows (`text-table/NOTES.md`), so the row count of a B document depends on how its edits arrived.

## f. Concurrency

`pgbench -c N`, each session inserts one character at a random position per transaction under its own replica id. 'same post': all sessions edit one post. 'own posts': each session edits its own post of the same size (no contention; the scaling baseline). 300 transactions per session on 5 kB posts, 100 on 100 kB posts. The READ COMMITTED rows are the default isolation level; the REPEATABLE READ row sets `default_transaction_isolation`. 'lost' is acknowledged inserts missing from the final length of the post. Failed transactions are not retried; `tps` is as pgbench reports it, and the latency columns come from the per-transaction log.

| post | sessions | case | shape | isolation | tps | mean ms | p95 ms | failed | lost |
| --- | ---: | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| 5 kB | 4 | same post | A | read committed | 2,864 | 1.39 | 2.03 | 0 | 0 |
| 5 kB | 4 | same post | B | read committed | 2,597 | 1.47 | 4.13 | 0 | 0 |
| 5 kB | 8 | same post | A | read committed | 2,035 | 3.88 | 5.96 | 0 | 0 |
| 5 kB | 8 | same post | B | read committed | 2,395 | 2.91 | 9.71 | 0 | 0 |
| 5 kB | 8 | own posts | A | read committed | 10,871 | 0.72 | 1.47 | 0 | 0 |
| 5 kB | 8 | own posts | B | read committed | 10,995 | 0.71 | 1.21 | 0 | 0 |
| 5 kB | 8 | same post | A | repeatable read | 2,651 | 0.39 | 0.59 | 2,034 | 0 |
| 5 kB | 8 | same post | B | repeatable read | 1,604 | 0.62 | 1.17 | 2,090 | 0 |
| 100 kB | 4 | same post | A | read committed | 1,064 | 3.74 | 4.66 | 0 | 0 |
| 100 kB | 4 | same post | B | read committed | 2,235 | 1.52 | 5.11 | 0 | 0 |
| 100 kB | 8 | same post | A | read committed | 951 | 8.35 | 10.2 | 0 | 0 |
| 100 kB | 8 | same post | B | read committed | 2,056 | 3.24 | 6.87 | 0 | 0 |
| 100 kB | 8 | own posts | A | read committed | 3,127 | 2.50 | 3.96 | 0 | 0 |
| 100 kB | 8 | own posts | B | read committed | 7,928 | 0.98 | 1.65 | 0 | 0 |

Writers to one post serialize in both shapes (A on the row lock, B on the lock of the `ydoc_docs` row), so same-post throughput is flat from 4 to 8 sessions. Neither lost an edit. Under READ COMMITTED neither raised an error. Under REPEATABLE READ both fail about 85% of transactions with serialization failures (2,034 and 2,090 of 2,400) and the application must retry. B's p95 under contention is 1.6 to 2 times A's at 5 kB (4.1 against 2.0 ms at 4 sessions, 9.7 against 6.0 at 8), while its mean is about the same.

## Noise

Five full runs were made on the same machine one after the other (the first three before the size sweep and the heavily edited post were added to the script). For the keystroke, save, apply and size-sweep rows they agree within about 5%, with two exceptions: A's 100 kB random-insert mean was 0.84 to 1.06 ms across runs, and the same-post concurrency rows at 5 kB move by up to 25% (B at 8 sessions: 1,552 to 2,565 tps). WAL per edit varies by a few percent with full-page images. Treat ratios of 1.3 or less as ties.

## What this means

**Headline** (5 kB post / 100 kB post, from the tables above):

| | A: column | B: tables |
| --- | --- | --- |
| Storage per post (plain text, pglz: 4.2 KB at 5 kB) | 6.3 KB | 23.9 KB |
| Keystroke, random position: latency | 0.28 / 0.85 ms | 0.32 / 0.36 ms |
| Keystroke: WAL per edit | 18.6 kB / 114 kB | 1.0 kB / 2.0 kB |
| Keystroke on the heavily edited 100 kB post | 2.2 ms, 280 kB WAL | 0.40 ms, 4.5 kB WAL |
| Three-way form save | 3.15 / 11.8 ms | 1.16 / 3.35 ms |
| Render one post | 0.06 / 0.27 ms | 0.09 / 0.43 ms |
| List 50 posts, first 200 characters | 0.67 ms | 1.04 ms |
| `apply`, 100 patches per call | 6.16 ms, 126 kB WAL | 0.75 ms, 3.8 kB WAL |
| Eight sessions on one post (100 kB) | 951 tps | 2,056 tps |

**Where A wins.** Storage: 6.3 KB per post against 23.9 KB, so B is 3.8 times larger (5.6 times the default plain text column); with a full-text index 9.7 against 31.5 KB. Reads: rendering is 1.5 to 1.6 times faster (B reads and joins rows), and A is within 10% of a plain column at 100 kB. Small documents, per-keystroke latency: at 1 to 5 kB A's keystroke is 0.18 to 0.29 ms and B's 0.25 to 0.32 ms (cursor typing 0.18 against 0.25 ms), a difference that sits under the client round trip. Full-text search needs no extra column: the expression GIN index reads current text. Operational simplicity: one jsonb column, so the post's privileges, row-level security, backups and logical replication cover the document without extra tables.

**Where B wins.** WAL per edit: A rewrites the whole value, so its WAL grows with the document (11 kB at 1 kB, 19 kB at 5 kB, 37 kB at 20 kB, 122 kB at 100 kB) while B's stays at 0.9 to 1.7 kB: 18 times less at 5 kB and 58 times less at 100 kB (b; 71 times in the size sweep). One person typing ten characters a second in a 5 kB post writes about 190 kB/s of WAL with A (random positions) or 66 kB/s (typing at the cursor), against 10 and 4 kB/s with B; an hour of that is about 670 MB (or 240 MB) against 35 MB (or 15 MB) per editor. Edit latency at 20 kB and above: B stays at 0.34 to 0.37 ms from 1 to 100 kB, A goes from 0.21 to 0.89 ms, and to 2.2 ms on the heavily edited 100 kB document. The untrusted path: `ydoc_apply` is 8 times faster per 100-patch call and writes 33 times less WAL; on one-patch calls 1.9 times faster and 7 times less WAL. The three-way save: 2.7 times faster at 5 kB, 3.5 times at 100 kB, with a token as base instead of the whole state. Contention on a large post: at 100 kB B's same-post throughput is 2.1 to 2.2 times A's.

**Where neither wins.** Same-post concurrency at 5 kB is the same within noise (2,000 to 2,900 tps for both): the serialization is on one row either way, and B's tail is a little worse. Isolation: identical behavior under REPEATABLE READ. Unindexed search: 375 to 381 ms for 1,001 posts in both, because `to_tsvector` costs more than the render. The edit itself is a sub-millisecond operation in both at every size up to 100 kB.

**The search choice costs the shapes differently.** With full-text search the shapes' keystroke costs swap: A + GIN is 0.79 ms at 5 kB and 9.9 ms at 100 kB, and writes 33 and 236 kB per edit, because the index expression runs on every update. B keeps its 0.32 and 0.36 ms, and pays for search at refresh time instead (0.6 s to refresh 1,001 posts, 1.1 to 11.6 ms more per save), with a cache that is stale between refreshes. A with the search index is 1.7 times slower per keystroke at 1 kB, 2.8 times at 5 kB and 12 times at 100 kB than A without it; B with a cache refreshed on save keeps keystrokes cheap but searches old text.

**Crossover points.**
- Document size, latency: A is faster per keystroke below about 5 kB, tied from 5 to 20 kB, slower above 20 kB; with a search index A is slower at every size (0.35 against 0.30 ms already at 1 kB).
- Document size, WAL: B writes less at every size measured, including 1 kB (861 against 11,123 bytes).
- Edit rate: this is the cost that grows with edits, not documents. At save-rate editing (a save every few seconds to minutes) A's 14 kB per save at 5 kB is not a problem; at keystroke rate (autosave per character, or op streaming through `apply`) A's WAL is 18 to 58 times B's.
- Edit history: B's storage depends on how fragmented the document is (about 230 bytes per run in these posts, including indexes and side tables). The trace document costs about 1.9 MB in B against 220 kB in A (18 against 2.1 bytes per character); a lightly edited 5 kB post costs 3.8 times A. A's cost per edit depends on the same fragmentation: 2.2 ms against 0.85 ms at 100 kB.

## Recommendation

For a CRDT text column on a blog post table edited by several people, make **B (table-backed, `ydoc_`) the blessed default** and keep A as a documented option for narrow cases.

The numbers behind it:
- "Edited by several people" means ops arriving through `apply` and saves that need a base. B handles an `apply` of 100 patches in 0.75 ms and 3.8 kB of WAL where A takes 6.16 ms and 126 kB, and its base is a token where A's is the whole state. A's three-way save is 3.15 ms against 1.16 ms at 5 kB.
- A's costs grow with the two things that grow in a collaborative product, document size and edit rate (WAL per keystroke 18.6 kB at 5 kB, 114 kB at 100 kB; 2.2 ms and 280 kB for a document with the trace's edit history). B's per-edit cost is flat from 1 kB to 100 kB (0.30 to 0.37 ms, 0.9 to 1.7 kB). A has cliffs; B has a flat cost.
- B's price is storage, 23.9 KB per 5 kB post (3.8 times A), which is 24 MB for a thousand posts, plus the operational weight of extension-owned tables (privileges on the `crdt.ydoc_*` tables, the wrapper pattern of `text-table/NOTES.md`, backup and replication scope that must include the extension's tables), plus a cached text column for search that lags the document.

What would flip it to A: documents under about 5 kB, edited at save rate only (no op streaming, no per-keystroke autosave), where the team wants the document in an ordinary column (row-level security, an ORM), a search index that is always current (A + GIN costs 0.79 ms per keystroke and 4.3 ms per save at 5 kB), and the smallest storage (6.3 against 23.9 KB). A blog post body that one or two people save from a form fits. A post that several people edit live does not. If the extension offers one shape, B is the one that does not become a problem when a post grows or a second editor joins; A's advantages are real but belong to the narrow case.

Two findings matter independent of the choice:
- A's three-way `yseq_set` is 7 times slower than its two-way form (3.15 against 0.45 ms at 5 kB), and it needs the loaded state as base. Without a base both shapes revert concurrent saves (documented in both NOTES). If A stays, the base handling is the first thing to optimize.
- `to_tsvector` on every update is the dominant cost of searchable A at 20 kB and above. A cached text column refreshed on save would be the better design for A at those sizes too. It was not measured: a stored generated column, the variant in A's NOTES, recomputes the text on every update like the index does, so it is expected to cost about the same.
