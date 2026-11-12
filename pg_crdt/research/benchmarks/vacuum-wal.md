# Vacuum, bloat and WAL: pn_, yseq_, ydoc_

2026-11-10. Scripts and how to run them: [`vacuum/`](./vacuum/README.md). Raw output of every run: [`vacuum/results/`](./vacuum/results/). This page measures what [`text.md`](./text.md) and [`pn-counter.md`](./pn-counter.md) did not: dead tuples and TOAST bloat under sustained writes, what VACUUM and autovacuum do about them, HOT updates, and WAL split into record payload and full-page images (FPI) with `pg_waldump`. Every text figure has a plain `text` column with the same edit stream next to it.

## The short version

- **Any value over about 2 kB that is rewritten on every edit bloats its TOAST table, and only VACUUM gets the space back.** That is how Postgres works, not something pg_crdt adds: a plain `text` column of 5 kB to 100 kB edited per keystroke grows the same way. yseq_ and pn_ state columns are such values. ydoc_ is not: it inserts and updates small rows.
- **yseq_ crosses the TOAST threshold at under 1 kB of text**, because its state is larger than the text and grows with the edit history: a 1 kB document with a 40-edit history is a 2.4 kB value, against 1.2 kB as plain text. A plain text column stays inline up to about 2 kB here, where HOT updates and page pruning clean up without VACUUM. From 5 kB up, yseq_ bloats 1.1 to 1.6 times as much as plain text at the same size (2.2 times in one autovacuum run). At 1 kB it is 40 times plain text (95 MB against 2.3 MB after 20,000 keystrokes on 100 documents).
- **With default autovacuum the table settles at about writes/s x value size x 60 to 70 s.** That is the dead TOAST written between two autovacuum passes (`autovacuum_naptime` is 1 min). At 200 keystrokes/s that is 65 MB for 100 plain 5 kB documents (0.5 MB of live data) and 190 MB at 20 kB. yseq_ does not settle under random-position keystrokes. Each one splits a run, so its state, and with it the dead TOAST per edit, keeps growing. 100 documents of 5 kB went 0.7, 140, 336 MB at 0, 3 and 10 min, against 65 to 80 MB for plain text. Typing at the end of the document fragments less: the same 5 kB run settled at 95 to 122 MB. But one document taking 50 keystrokes/s still grew without levelling off even then, because the 20% backspaces leave tombstones that the next characters cannot extend.
- **At 100 kB autovacuum's default cost limit cannot keep up** with 200 keystrokes/s (15 MB/s of new TOAST). Plain text reached 1.8 GB and yseq_ 2.0 GB in 3 minutes, for about 7 MB of live data. In a 10-minute run plain text reached 3.9 GB (574 times live) with three autovacuum passes over its TOAST, still climbing. A table like that needs its autovacuum tuned.
- **ydoc_ stays at 2 to 3 times its live data** at every size and in every scenario (5 to 37 MB for 100 documents), with 100% HOT updates on its internal tables. Most of its growth is new live rows, not dead ones.
- **yseq_ WAL is the value, not full-page images.** 96 to 100% of yseq_ WAL is record payload: the new TOAST chunks, that is, the whole compressed value per edit. FPIs are 0 to 4% (up to 10% in single runs with `wal_compression` on), with checkpoints every 30 s or none. `wal_compression` compresses only FPIs, so it does not help (its effect is within the run-to-run drift). This closes the open item in `text.md` ("WAL figure may be mostly full-page images"): it is not. The opposite holds for ydoc_: its records are a flat 0.8 to 1.3 kB per edit, and its FPIs are 40 to 84% of its WAL after a checkpoint. Checkpoints every 30 s instead of every 5 min nearly double ydoc_ WAL, and `wal_compression` cuts its WAL by about 30%.
- **pn_ state column**: inline and cheap up to about 150 replicas (137 to 357 bytes of WAL per increment, HOT, no TOAST). From about 170 replicas (2 kB) it is a TOASTed value with the same bloat profile as text: 265 MB after 20,000 increments at 1,000 replicas, a steady 85 to 172 MB under autovacuum. The delta table writes 340 bytes per increment at any size and does not bloat until it is compacted. The documented compaction recipe folds 20,000 rows in 0.5 s, and reads go from 5.0 ms to 0.24 ms.

## Setup and caveats

| | |
| --- | --- |
| Postgres | 16.4 (Postgres.app), native |
| Machine | Apple M4, 10 CPU, 24 GB, macOS 27.0.1, laptop SSD |
| Code | git `cdea487` (extension `pg_crdt--0.0.1.sql`, `experiments/text-column/impl.sql`), unchanged |
| Cluster | throwaway, Unix socket, `shared_buffers=512MB`, `full_page_writes=on`, `wal_compression=off` unless a row says otherwise, `checkpoint_timeout=30min`, default TOAST compression `pglz` (the text columns use `compression lz4` as documented, except the rows marked pglz), data checksums off (the initdb default before PG 18) |
| Bloat (autovacuum off) and WAL runs | `fsync=off` as in `text.md`, `max_wal_size=2GB` (bloat) or `8GB` (WAL) |
| Autovacuum runs | `fsync=on`, autovacuum at its defaults (naptime 1min, scale factor 0.2, threshold 50, cost limit 200, cost delay 2ms), `max_wal_size=2GB` |
| Checkpoint runs | `fsync=on`, autovacuum off, `checkpoint_timeout` 30s or 5min (the default), `max_wal_size=8GB` so only timed checkpoints happen |

**Workload.** 100 documents per table, built as in `bench/text-compare.sh`: generated prose of 1, 5, 20 or 100 kB typed in one insert, then a 40-edit history by three replicas. The measured edits are keystrokes: one character per transaction, 80% insert and 20% delete, at a random position in the first half of the document. This is `text.md`'s 'random' keystroke, the pessimistic pattern for yseq_, because every insert splits a run. The append runs type at the end of the document instead. The edits go through the blessed API (`update ... set body = crdt.yseq_insert(body, ...)`; `select crdt.ydoc_insert(...)`; plain: `overlay(body placing 'x' ...)`). pn_: 100 counters, `update ... set s = crdt.pn_increment(s, <random replica>, 1)`.

**Counts used.** Bloat: 20,000 keystrokes per run (200 per document), 4 clients. HOT variants: 10,000. WAL: 2,000 keystrokes per run, 1 client. Autovacuum: 180 s per run at 200 keystrokes/s spread over the 100 documents ('spread', 4 clients) or 50/s on one document ('hot', 2 clients); 10-minute spread runs for plain text (5, 20, 100 kB) and yseq_ (5, 20 kB); and the append variants (yseq_ and plain, hot row at every size; yseq_ spread at 5 and 20 kB for 10 minutes). The 10-minute and append runs were added after the first pass showed yseq_ still growing at 3 minutes; they use the same scripts (`SCENARIOS=spread-append` etc.). Checkpoints: 100 keystrokes/s for 90 s.

**Noise and caveats.**
- The generated text (pseudo-words, as in `text.md`) compresses poorly: lz4 stores 5 kB of it in 4.2 kB and 100 kB in 66 kB. Real prose compresses better, so a plain column of real text TOASTs at a somewhat larger size and its TOAST values are smaller; yseq_'s state compresses about as well as before (it is mostly run metadata at small sizes).
- Single runs. Sizes and WAL bytes are deterministic to a few percent. Autovacuum timing is not: where a pass lands decides whether a sample sees the peak or the trough, so read the autovacuum sizes to about 20%.
- The WAL runs edit the same documents run after run (7 runs of 2,000 keystrokes per shape). yseq_'s state grows with every edit, so its later rows are larger. Compare the FPI columns across `wal_compression` settings, not the totals.
- yseq_ per-edit costs depend on the document's edit history. These documents have a 40-edit history, so at 100 kB their WAL per keystroke (77 kB) is lower than `text.md`'s 800-edit post (114 kB).
- A laptop SSD with fsync almost free. VACUUM durations (at most 1.4 s for 1.4 GB) are fast because everything is in the OS cache; on a server, VACUUM of a GB-sized TOAST table is I/O-bound.
- Not measured: Postgres 17 and 18 (Docker was available, skipped for time; PG 18 enables data checksums by default, which adds FPIs for hint bits, and PG 17 changed VACUUM's dead-tuple storage), tuned autovacuum (per-table `autovacuum_vacuum_cost_limit`, lower `autovacuum_naptime`, `toast.autovacuum_vacuum_scale_factor`), `fillfactor` on the documents table, long-running transactions that hold back VACUUM (they make every number here worse in proportion to their length), replicas and logical decoding, `ydoc_compact` under sustained edits, and the latency effect of bloat (reads here stay in shared_buffers).

## yseq_ (text column) and the plain text baseline

**Bloat with autovacuum off** (100 documents, 20,000 keystrokes, then VACUUM; MB; [`bloat.md`](./vacuum/results/bloat.md)):

| size | shape | loaded | after edits | dead TOAST | live | after VACUUM | reusable after VACUUM | after VACUUM FULL | after / live | HOT |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 kB | plain text | 0.19 | 2.29 | 0 | 0.14 | 2.29 | 2.09 | 0.18 | 17 | 95% |
| 1 kB | yseq_ | 0.37 | 95.5 | 56.0 | 0.60 | 95.5 | 93.2 | 0.74 | 158 | 100% |
| 5 kB | plain text | 0.62 | 106 | 84.4 | 0.45 | 106 | 104 | 0.56 | 238 | 100% |
| 5 kB | yseq_ | 0.69 | 168 | 127 | 1.03 | 168 | 164 | 1.23 | 163 | 100% |
| 20 kB | plain text | 1.58 | 312 | 268 | 1.40 | 312 | 306 | 1.64 | 222 | 100% |
| 20 kB | yseq_ | 1.69 | 372 | 327 | 2.05 | 372 | 364 | 2.23 | 182 | 100% |
| 100 kB | plain text | 6.80 | 1,344 | 1,276 | 6.50 | 1,344 | 1,318 | 6.80 | 207 | 99% |
| 100 kB | yseq_ | 6.86 | 1,420 | 1,341 | 7.19 | 1,420 | 1,392 | 7.50 | 198 | 100% |

'dead TOAST' is pgstattuple's dead_tuple_len. The rest of the gap between file and live data is space that page pruning had already freed. 'reusable' is pgstattuple free_space after VACUUM.

**Steady state with default autovacuum** (MB at the end of the run; 'x live' is total over pgstattuple live bytes; [`autovac-a.md`](./vacuum/results/autovac-a.md), [`autovac-plain.md`](./vacuum/results/autovac-plain.md), [`autovac-long-a.md`](./vacuum/results/autovac-long-a.md), [`autovac-long-plain.md`](./vacuum/results/autovac-long-plain.md), [`autovac-long-plain-100k.md`](./vacuum/results/autovac-long-plain-100k.md)):

| size | spread 200/s, 3 min: plain | yseq_ | spread, 10 min: plain | yseq_ (live at end) | hot row 50/s, 3 min: plain | yseq_ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 kB | 1.25 (8x) | 88 (107x) | | | 3.2 (25x) | 200 (621x) |
| 5 kB | 65 (140x) | 140 (103x) | 72, peak 79 | 336 (2.8 MB live) | 17 (41x) | 259 (400x) |
| 20 kB | 192 (130x) | 267 (109x) | 192, peak 200 | 581 (4.4 MB live) | 58 (42x) | 411 (249x) |
| 100 kB | 1,784 (272x) | 2,016 (264x) | 3,885 (574x), rising | not run | 246 (38x) | 777 (114x) |

**The same with typing at the end of the document** instead of random positions (80% characters, 20% backspaces; MB at the end; [`autovac-append-hot-a.md`](./vacuum/results/autovac-append-hot-a.md), [`autovac-append-hot-plain.md`](./vacuum/results/autovac-append-hot-plain.md), [`autovac-append-long-a-5k.md`](./vacuum/results/autovac-append-long-a-5k.md), [`autovac-append-long-a-20k.md`](./vacuum/results/autovac-append-long-a-20k.md)):

| size | hot row 50/s, 3 min: plain | yseq_ (x live) | spread 200/s, 10 min: yseq_ |
| --- | ---: | ---: | --- |
| 1 kB | 1.90 | 77.7 (287x), rising | |
| 5 kB | 16.7 | 96.1 (165x), rising | 122 (127x); 95 to 97 from minute 3 to 5 |
| 20 kB | 44.6 | 125 (81x), rising | 251, peak 306 (130x) |
| 100 kB | 213 | 299 (45x) | |

**WAL per keystroke** (bytes, pg_waldump; 'cold' right after a CHECKPOINT, 'warm' with no checkpoint since the previous 2,000 edits; [`wal.md`](./vacuum/results/wal.md)):

| size | plain: cold total (FPI) | warm | yseq_ lz4: cold total (FPI) | warm | yseq_ pglz: cold total (FPI) | 10 keystrokes/s on one document, yseq_ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 kB | 541 (70) | 432 | 3,376 (130) | 3,706 | 3,016 (118) | 34 kB/s |
| 5 kB | 5,292 (226) | 5,102 | 7,118 (293) | 7,449 | 6,271 (261) | 71 kB/s |
| 20 kB | 16,504 (734) | 15,826 | 18,459 (796) | 18,419 | 16,883 (729) | 185 kB/s |
| 100 kB | 76,648 (3,399) | 73,314 | 78,733 (3,477) | 75,978 | 72,724 (3,215) | 790 kB/s |

At a fixed rate of 100 keystrokes/s over 100 documents for 90 s ([`ckpt.md`](./vacuum/results/ckpt.md)), yseq_ wrote 0.76 MB/s at 5 kB and 7.4 to 7.6 MB/s at 100 kB, the same with checkpoints every 30 s (FPI 4%) or none (FPI 1%). Plain text: 0.49 to 0.50 and 7.2 to 7.4 MB/s.

Findings:
1. **The yseq_ column has a plain TOAST problem, not a special one.** From 5 kB up, its bloat, its VACUUM behavior and its WAL are within 1.1 to 1.6 times a plain `text compression lz4` column with the same edits. A team that would put a 20 kB text body in a column and autosave it per keystroke has the same bloat with or without pg_crdt. Where yseq_ is worse is the bottom of the range: its state crosses the 2 kB TOAST threshold below 1 kB of text (a 1 kB document is a 2.4 kB value), where plain text is still inline and cleaned up by HOT pruning (2.3 MB against 95 MB after 20,000 keystrokes).
2. **VACUUM makes the space reusable and gives none of it back.** After VACUUM, 97 to 98% of the yseq_ and plain TOAST files was free space and the files kept their size. Only VACUUM FULL (or pg_repack) returns it, which rewrites the table under an exclusive lock. With autovacuum off, every keystroke leaves the whole old value behind: the TOAST file grew by 4.8 kB per keystroke at 1 kB, 8.4 kB at 5 kB, 18.5 kB at 20 kB and 71 kB at 100 kB.
3. **Under default autovacuum the size is set by the write rate, not the data.** A TOASTed column settles at about writes/s x value size x 60 to 70 s: plain 5 kB at 200/s, 65 to 80 MB over 10 minutes; plain 20 kB, about 195 MB; a hot 100 kB row at 50/s, 237 to 246 MB. That is 40 to 140 times the live data at keystroke rates, harmless in absolute terms for a few documents, and it scales with the number of documents being edited at once. yseq_ under random-position keystrokes does not settle, because the value itself keeps growing: in the 10-minute 5 kB run its live data went from 0.7 to 2.8 MB, its WAL per keystroke averaged 20 kB (11 kB over the 3-minute run), and the table reached 336 MB. Typing at the end of the document fragments less: spread over 100 documents, yseq_ settled at 95 to 122 MB at 5 kB and 250 to 306 MB at 20 kB over 10 minutes, 1.3 to 1.9 times plain text. One document taking 50 keystrokes/s still grew without levelling off at 1 to 20 kB (78 to 125 MB after 3 minutes, against 2 to 45 MB for plain text). The backspaces leave tombstones, and the next character inserted before a tombstone starts a new run. So yseq_'s steady state depends on how its documents are edited. Plain text's does not.
4. **The cliff is at 100 kB and keystroke rates.** At 200 keystrokes/s on 100 kB documents (15 MB/s of new TOAST) one autovacuum pass with the default cost limit did not finish within the 3-minute run (one TOAST pass in 180 s). Plain and yseq_ reached 1.8 and 2.0 GB, still climbing. Plain text, run for 10 minutes, reached 3.9 GB for 6.8 MB of live data (574 times), with three autovacuum passes over its TOAST, still climbing. yseq_ was not run for 10 minutes at 100 kB (disk space); at 3 minutes it was 13% above plain. Here a per-table autovacuum setting (a higher `autovacuum_vacuum_cost_limit`, or no cost delay) is required, not optional, and the same holds for a plain text column of that size edited at that rate.
5. **HOT is not the issue.** The heap row of a TOASTed value is a few dozen bytes, so 99 to 100% of updates are HOT with or without an index on another column. An index on a column every edit changes (`updated_at`) makes them 0% HOT and grows that index 8 times in 10,000 edits, but adds only 1 to 4% to yseq_ WAL and nothing to its bloat, which is all TOAST.

## ydoc_ (table-backed text)

**Bloat** (100 documents, 20,000 keystrokes, all `crdt.ydoc_*` tables; MB):

| size | loaded | after edits | live | after VACUUM | reusable | after VACUUM FULL | after / live | HOT (internal tables) | item rows inserted | dead tuples after edits |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 kB | 4.27 | 10.1 | 3.54 | 10.1 | 2.24 | 7.09 | 2.9 | 100% | 32,229 | 10,511 |
| 5 kB | 5.27 | 12.3 | 4.42 | 12.3 | 3.02 | 8.58 | 2.8 | 100% | 38,055 | 11,969 |
| 20 kB | 8.41 | 16.2 | 6.37 | 16.2 | 4.39 | 11.3 | 2.5 | 100% | 39,408 | 12,386 |
| 100 kB | 23.5 | 33.3 | 16.4 | 33.3 | 8.09 | 24.8 | 2.0 | 100% | 39,803 | 13,573 |

**Steady state with default autovacuum** (MB at the end of 3 minutes): spread 200/s: 13.1, 16.6, 20.5, 36.5 at 1, 5, 20, 100 kB (1.9 to 2.6 times live); hot row 50/s: 4.9, 6.2, 9.4, 25.3 (1.7 to 3.2 times live). It grows by about 3 to 4.3 MB a minute at 200 keystrokes/s, and most of that growth is live: new item rows (about 2 per keystroke) and their index entries. Peak dead tuples were 10,000 to 12,000 (spread) and under 6,000 (hot), all in the heaps; no TOAST is written ([`autovac-b.md`](./vacuum/results/autovac-b.md)).

**WAL per keystroke** (bytes; cold / warm; FPI share):

| size | cold, off | warm, off | cold, pglz | cold, lz4 | after VACUUM, off / lz4 / pglz | 100/s for 90 s, checkpoints every 30 s / none |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| 1 kB | 1,952 (40%) | 993 (1%) | 1,618 (38%) | 1,910 (51%) | 2,749 / 1,953 / 1,844 | |
| 5 kB | 2,390 (47%) | 1,117 (2%) | 1,971 (45%) | 2,354 (53%) | 3,343 / 2,435 / 2,302 | 2,427 (54%) / 1,382 (19%) |
| 20 kB | 3,461 (63%) | 1,412 (12%) | 2,686 (58%) | 3,172 (61%) | 4,497 / 3,337 / 3,116 | |
| 100 kB | 8,341 (84%) | 2,656 (49%) | 4,171 (71%) | 4,562 (74%) | 7,368 / 5,415 / 5,042 | 5,945 (79%) / 3,154 (59%) |

Findings:
1. **ydoc_ has no TOAST bloat and little dead space.** Its writes are one or two small row inserts and HOT updates of the item, block and document rows (fillfactor 90 and 50 leave room for them). After 20,000 keystrokes, VACUUM found 2 to 8 MB reusable, against 93 to 1,392 MB for yseq_. Under autovacuum the tables stay at 2 to 3 times live at every size.
2. **What grows is live data.** About 2 item rows per random-position keystroke (the split and the new character), 0.3 to 0.5 kB per keystroke including indexes. This is the storage cost `text.md` already reports, not bloat. `ydoc_compact` and VACUUM FULL are the tools; the compaction under sustained edits was not measured here.
3. **ydoc_'s WAL is mostly full-page images, so checkpoint settings matter for it.** Its records are a flat 0.8 to 1.3 kB per keystroke at every size. What varies is FPIs: random positions touch item and block pages that have not been logged since the last checkpoint. Checkpoints every 30 s instead of every 5 min nearly double its WAL (5 kB: 1.4 to 2.4 kB per keystroke; 100 kB: 3.2 to 5.9 kB). In the runs after VACUUM (the same pages, one setting after another), `wal_compression` cut ydoc_'s FPI bytes by 33 to 40% with lz4 and 39 to 49% with pglz, and its total WAL by 26 to 33%. In the cold runs the effect ranged from +24% to -58%, because each cold run touches a different set of pages. yseq_ gains nothing from either.
4. **Per document, at 10 keystrokes/s,** ydoc_ writes 10 to 24 kB/s at 1 to 5 kB and 27 to 83 kB/s at 100 kB (warm to cold), against yseq_'s 34 to 790 kB/s. At 100 keystrokes/s spread over 100 documents, 0.13 to 0.23 MB/s at 5 kB and 0.30 to 0.57 MB/s at 100 kB, against 0.76 and 7.5 MB/s for yseq_.

## pn_ (PN-Counter)

**State size** (bytes stored, after compression; [`pn.md`](./vacuum/results/pn.md)):

| replicas | counts up to 1 | up to 1,000 | up to 10^6 | up to 10^9 | per replica (10^6) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 420 | 420 | 468 | 468 | 47 |
| 100 | 526 | 928 | 1,272 | 1,499 | 12.7 |
| 1,000 | 5,029 | 8,566 | 12,076 | 14,189 | 12.1 |
| 10,000 | 50,767 | 83,175 | 120,095 | 139,626 | 12.0 |

**State column under 20,000 increments, autovacuum off, and under default autovacuum** (MB unless noted):

| replicas | stored state | after 20,000 increments (x live) | reusable after VACUUM | HOT | WAL per increment cold / warm (FPI) | autovacuum 3 min: spread 200/s / hot row 100/s |
| ---: | ---: | ---: | ---: | ---: | --- | --- |
| 10 | 468 B | 0.16 (3.3x) | 0.06 | 100% | 212 / 176 B (17%) | 0.14 / 0.28 |
| 100 | 1,269 B | 0.71 (5.7x) | 0.53 | 99% | 357 / 271 B (22%) | |
| 1,000 | 12 kB | 265 (224x) | 260 | 99% | 14,341 / 13,700 B (4%) | 172 (145x) / 85 (72x) |
| 10,000 | 120 kB | 2,392 (205x) | 2,344 | 100% | 138,564 / 132,382 B (4%) | |

**Delta table** (100 counters, deltas from 1,000 replicas, 20,000 inserts, then the compaction recipe of `docs/guides/storage-and-performance.md` for all counters in one statement):

| step | rows | total MB | dead tuples | read one counter (ms) | WAL |
| --- | ---: | ---: | ---: | ---: | --- |
| 20,000 inserts | 20,000 | 3.23 | 0 | 4.99 | 340 B per insert, no FPI |
| compaction (0.52 s) | 100 snapshots | 3.49 | 20,000 | 0.24 | 1.26 MB |
| VACUUM | 100 | 0.93 (heap truncated to 0.23; indexes keep 0.62) | 0 | 0.22 | |
| 20,000 more inserts | 20,100 | 4.08 | 0 | 5.04 | |
| compaction + VACUUM | 100 | 1.92 (indexes 1.23) | 0 | 0.26 | |
| VACUUM FULL | 100 | 0.45 | 0 | 0.26 | |

Findings:
1. **The pn_ state column has a size cliff at about 170 replicas.** At about 12 bytes per replica after compression, a state passes the 2 kB TOAST threshold there. Below it a write is a HOT update logging only the changed bytes (137 to 357 bytes of WAL) and the dead row versions are pruned without VACUUM (0.16 to 0.71 MB after 20,000 increments). Above it every increment rewrites and logs the whole state (13.7 kB at 1,000 replicas, 132 kB at 10,000) and leaves it behind as dead TOAST, the yseq_ pattern. The state grows with the number of replicas, not increments: the counts' digits add up to 2.8 times from counts of 1 to counts of 10^9.
2. **Under default autovacuum a 1,000-replica counter settles at writes/s x 12 kB x about 70 s**: 85 MB for a hot counter at 100 increments/s, 160 to 172 MB for 100 counters at 200/s, against 1.2 MB of live data. Small counters (10 replicas) stayed under 0.3 MB.
3. **The delta table does not bloat until compaction, and compaction is cheap.** Inserts write 340 bytes of WAL each at any size, never update, and leave no dead tuples. Reads degrade with the backlog: 5 ms with 200 deltas per counter. The hand-written compaction folded 20,000 rows in 0.52 s with 1.26 MB of WAL and brought reads back to 0.24 ms. It leaves 20,000 dead rows for VACUUM. VACUUM truncated the heap (compaction had emptied it), but the btree indexes kept their pages and grew again with the next batch (0.62 to 1.23 MB). Compaction is not built into the extension, so these numbers are for the documented recipe.
4. **An index on a column every write changes hurts small counters most.** With an `updated_at` index set on every increment, HOT drops from 100% to 0% and WAL per increment goes from 148 to 693 bytes at 10 replicas (4.7 times). At 1,000 replicas it adds 1%, because the TOAST write dominates.

## What this changes

- **For the docs of yseq_:** state the TOAST behavior plainly, next to the plain text figures, since most of it is Postgres and not pg_crdt. The column bloats like any TOASTed column updated per keystroke. Its state crosses 2 kB at about 1 kB of text, and under random-position edits it grows with the history, so the bloat ceiling rises over time. At save rate (a save every few seconds or minutes) the steady-state size scales down with the write rate: by the formula above, 10 saves/s across a table of 100 kB documents is about 50 MB of TOAST churn (not measured). Keystroke-rate autosave on many documents at 20 kB and above needs tuned autovacuum on that table, or ydoc_.
- **For the docs of ydoc_:** no TOAST bloat, 2 to 3 times live under default autovacuum. Its WAL is FPI-heavy, so `wal_compression` (about 30% less) and a longer `checkpoint_timeout` with a larger `max_wal_size` (up to 45% less) reduce it.
- **For pn_:** the state column is the right default below about 150 replicas. Above that, use the delta table plus compaction, or accept TOAST churn of 12 bytes x replicas per write.
- **The open item from `text.md`** ("A's WAL may be mostly full-page images") is resolved: it is record payload, 96 to 100%.
