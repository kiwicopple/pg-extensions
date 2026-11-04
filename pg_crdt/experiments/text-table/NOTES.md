# Shape B: table-backed text documents (`ydoc_`)

Status: experiment, 2026-11-04. PL/pgSQL and SQL only; loads after `pg_crdt--0.0.1.sql` with `psql -f` and needs nothing pg_tle cannot install. Contract: [`research/text.md`](../../research/text.md).

| File | What |
| --- | --- |
| `impl.sql` | The implementation: tables, internals (`crdt._ydoc_*`), API (`crdt.ydoc_*`), privileges. |
| `test/run.sh` | Test runner (a throwaway cluster from `test/lib/cluster.sh`; `-v`, name filters, `--impl`). |
| `test/spec/*.sql` | Ten spec files, 124 assertions (table below). |
| `bench.sh` | Benchmarks; prints the Markdown in the "Benchmarks" section. `--quick` skips 1M and most of the trace. |
| `variants/bytea-keys.sql` | The first version, with byte-string fractional keys instead of bigint labels. Kept for the benchmark comparison only (the tests target `impl.sql`). |

## API

| Function | Returns | Labels | Notes |
| --- | --- | --- | --- |
| `ydoc_create()` | `bigint` | volatile | A new empty document. |
| `ydoc_value(doc)` | `text` | stable | Plain text; null for a missing document. `string_agg(content order by ord)`. |
| `ydoc_length(doc)` | `integer` | stable | Visible code points (a column of `ydoc_docs`). |
| `ydoc_insert(doc, pos, chars, replica)` | ops `jsonb` | volatile | Local edit. `replica` is an entry key (`id` or `id:device`). |
| `ydoc_delete(doc, pos, len, replica)` | ops `jsonb` | volatile | Local edit. |
| `ydoc_set(doc, new_text, replica, base default null)` | ops `jsonb` | volatile | Prefix/suffix diff, one delete and one insert. See "set and concurrent saves". |
| `ydoc_base(doc)` | `jsonb` | stable | `{"g": gen, "v": vv}`: what an editor started from, for `ydoc_set`'s `base`. |
| `ydoc_apply(doc, ops, replica default crdt.current_replica_id())` | void | volatile | Untrusted path: inserts only with the caller's ids (owner rule of `pn_apply_delta`), deletes of anyone's chars. |
| `ydoc_merge(doc, ops)` | void | volatile | Trusted path: ops from any replica (another server's `ops_since`). |
| `ydoc_ops_since(doc, vv default '{}')` | ops `jsonb` | stable | Inserts above `vv` in integration order (causal), joined into maximal runs; every delete. |
| `ydoc_version(doc)` | `jsonb` | stable | `{replica: highest seq}`; one index probe per replica. |
| `ydoc_drop(doc)` | void | volatile | Deletes the document and its rows. |

Positions and lengths count code points (`length()`), not UTF-16 units. Errors: `22004` null argument; `22023` malformed ops, a replica key that is not one, a position outside the text, a base that is not a version of the document, an insert whose originRight is not after its originLeft; `42501` no identity or a forged insert (`ydoc_apply`), or no table privileges (Postgres); `P0002` no such document.

## Design

### Tables

```
ydoc_docs(id, len, gen)                         one row per document; the row lock serializes writers
ydoc_items(doc, ord, ins, seq, ol_seq, or_seq,  one row per run of characters of one replica
           replica, ol_replica, or_replica,     pk (doc, replica, seq); index (doc, ord)
           del_gen, len, content)
ydoc_blocks(doc, lo, vis, n)                    positional index: label ranges with visible length and row count
ydoc_pending(doc, replica, seq, ol_*, or_*, content)   inserts waiting for their dependencies
ydoc_pending_deletes(doc, replica, seq, len)    deletes of ids not seen yet
```

A row is a run: ids `(replica, seq .. seq+len-1)`, the origins of its first char, its text, and `del_gen` (null while visible, else the write counter of the delete). Chars after the first have originLeft = their predecessor and the run's originRight, so a row splits into two valid runs anywhere, and two rows of one run are the same as one.

`ord` is a server-local cache of the YjsMod order, not part of the wire format. Other replicas integrate by origins; this database only needs `ord` to render (`string_agg(content order by ord)` on the `(doc, ord)` index) and to scan.

### Integration (YjsMod on rows)

Every write locks the document row first (`select ... for no key update`, which does not block foreign-key checks from the app's tables). Writes to one document are serialized, and under READ COMMITTED each statement after the lock sees the previous writer's commit. So each incoming run is integrated against a stable sequence:

1. Split rows so that originLeft ends a row and originRight starts one (one index probe each, `(doc, replica, seq)`).
2. Scan the rows strictly between them in `ord` order: an index range scan that is usually empty (no concurrent insert at that spot). The YjsMod loop runs on rows: only the first char of a row can change the scan state, because every later char has originLeft = its predecessor, which is to the right of our originLeft ("oleft > left: continue"). Positions of a scanned row's origins are compared as `(row label, offset)` pairs, found by id. After step 1 every candidate destination is a row boundary.
3. Insert the run as a new row (at most `_ydoc_run_cap()` = 256 chars per row) with a label between its neighbours, or append it to the predecessor's row when that row ends at `(replica, seq-1)`, is visible, has the same originRight and has room ("typing on"). Then apply any pending delete of the new ids.

This is the integrate rule of the contract, checked differentially against the JS reference (57 fixtures in three delivery modes, and 20,000 ops of the automerge-paper trace op for op; spec `50_fixtures`, `55_trace`).

### Order labels: list labelling, not fractional keys

The brief suggested a fractional key (bytea, `collate "C"` text or numeric). The first version used bytea keys compared bytewise, with "close to the left neighbour" allocation so that forward typing steps `lo+1`. It passed every test and replayed the automerge-paper trace correctly, but keys grew: 83,253 rows with an average key of 31.9 bytes, p99 156, **max 288 bytes**. Typing, backspacing and typing again at one place nests one level deeper each cycle, and so does deleting a run character by character (each split takes a key between the previous split key and its neighbour). Biasing split keys towards the right neighbour fixed backspacing and broke deleting from the left. Any allocation that only looks at the two neighbours has a pattern that nests.

The kept version uses **bigint labels with relabelling** (order maintenance / list labelling). A new row takes the midpoint of its neighbours' labels (appends step by 2^30). When two neighbours are adjacent integers, `_ydoc_relabel` takes k rows on each side (k = 8, 16, 32, ...) until the labels around that window leave at least 2^20 per row, or the window is the whole document, and spreads the window evenly. Block boundaries follow their row. Labels are always 8 bytes, and the `(doc, ord)` index is not unique so that a window can be rewritten in one `update` (uniqueness is an invariant the tests check). Rows are addressed by id `(replica, seq)` inside the write functions, because a split can relabel.

On the whole automerge-paper trace (259,778 ops), the labels made 1,692 relabels that rewrote 155,200 rows in total (0.6 rows per op, at most 2,048 in one relabel), at the same speed as the bytea keys. On the first 100,000 ops of the trace (bench section "Order key"): 183 against 179 us per op, 667 against 520 bytes of WAL per op (the relabels rewrite rows), keys of 8 bytes against an average of 28 and a maximum of 272, and a smaller order index (2.0 MB against 2.4 MB). The labels trade about 150 bytes of WAL per op for a key size that does not depend on the editing history. Tuning left: the 2^20 gap and 2^30 step (a larger gap means fewer, larger relabels).

### Positional index (blocks)

Local edits need position to item. The first version took a running sum (`sum(len) over (order by ord)`) over the whole document: 3.7 ms per insert at 100k chars. `ydoc_blocks` keeps, per label range of at most 512 rows, the visible length and row count. A position takes one running sum over the blocks and one over the rows of one block; every row change updates its block's counters (one HOT update), and a block splits in two at 512 rows. Insert at 100k chars: 0.3 ms. A tombstone never leaves its block, so blocks never merge.

Two planner traps, both found with `auto_explain`: a generic plan for "running sum from label X, stop at the first row past position P" cannot see that the scan stops early and chose a seq scan plus a sort of the document; and a PL/pgSQL `FOR` loop over the YjsMod scan did the same. Both queries now carry both bounds of the block (or of the origins) and the scan is an explicit cursor.

### Causal buffering

An insert is integrated when both origins and `(replica, seq-1)` are integrated (the same three conditions as the reference). So integrated ids of a replica have no gaps, the version vector is "highest seq", and `(replica, s)` is integrated iff `s <= clock`. A run that overlaps integrated ids keeps only its new tail. Runs that are not ready go to `ydoc_pending`; after each integration, the runs that waited on the new ids (by replica, by originLeft, by originRight: three indexes) are retried with an explicit stack, so a long chain delivered backwards costs O(n log n), not one full pass per link. Deletes of unseen ids wait in `ydoc_pending_deletes` and apply when the insert arrives.

### Sync out

`ydoc_ops_since(doc, vv)` returns the rows above `vv` (a row half above it is cut) in integration order, which is causal: a sequence (`ins`) stamped on each row, inherited by both halves of a split. Rows that continue one run (split by deletes or the row cap) are joined back into one insert. A fresh document applies the output without buffering (tested). Deletes carry no clock in the wire format, so every delete is sent, as islands of tombstoned ids (`[replica, seq, len]`). That makes `ops_since(current version)` O(tombstones): 8 ms at 100k chars in the benchmark.

### `set` and concurrent saves

`ydoc_set(doc, new_text, replica)` diffs against the current text: common prefix and suffix (a binary search on the UTF-8 bytes, moved back to character boundaries), one delete, one insert.

**The contract's claim that "concurrent saves from two editors who changed different paragraphs both survive" does not hold for this diff, in either shape.** The second save is diffed against a text that contains the first save, and the second editor's text does not, so the diff spans both paragraphs and reverts the first one (spec `10_set` pins this). The fix is a three-way diff: the editor reads `ydoc_base(doc)` (the write counter and the version vector) together with the text, and passes it back: `ydoc_set(doc, new_text, replica, base)`. The diff is then against the text at base (ids within the base vector, minus deletes stamped at or before the base's counter), its delete targets the ids visible at base, and its insert takes its origins in that version, so the CRDT merges it with whatever came after. Tested: two editors on different paragraphs, a delete next to an append, and two inserts at one place (not interleaved). The delete stamp (`del_gen`, a per-document write counter) exists for this. Shape A needs the same thing (a base version) to deliver the claim.

### Concurrency

Writers to one document serialize on its row lock; writers to different documents do not touch each other. Four dblink sessions running 150 transactions each against one document (inserts, deletes, `set`, `apply`) lost nothing and never deadlocked (`60_concurrency`); a writer that holds the lock in an open transaction makes the next wait, and the next then integrates against its version. A writer never takes two documents' locks, so there is no lock order to get wrong. Under REPEATABLE READ or SERIALIZABLE, a writer that waited on the lock gets `40001` and must retry, as for `pn_merge`.

### Security model

The tables belong to the extension and nobody but their owner has privileges on them. The functions are SECURITY INVOKER (no SECURITY DEFINER, per the conventions), so a call runs with the caller's table privileges, and a role without them gets `42501` from any `ydoc_` function. EXECUTE is granted to public, as for `pn_`; the table privileges are the gate.

The intended deployment (spec `31_wrapper`):

1. The DBA grants `select, insert, update, delete` on the five `crdt.ydoc_*` tables and `usage` on `crdt.ydoc_ins` and `crdt.ydoc_docs_id_seq` to the role that owns the app's functions (or to a trusted backend role).
2. The app's table references the document: `posts.body_doc bigint references crdt.ydoc_docs (id)`.
3. Untrusted clients call the app's SECURITY DEFINER functions, which check the app's own rule ("may this user edit post X"), then call `crdt.ydoc_apply(doc, ops, <identity>)` with the identity the app trusts (`session_user`, a JWT claim, a users-table lookup). `ydoc_apply` enforces that inserts carry only that identity's ids.
4. Reads go through an app function too. A view does not work: `crdt.ydoc_value` reads the tables with the caller's privileges, not the view owner's.

Row-level security on the `crdt.ydoc_*` tables would also work (policies that look up the app's table by `doc`), but policies on extension-owned tables are the app's to maintain and run on every row of every scan; the wrapper pattern checks once per call. Nothing assumes a platform: identity is an argument, defaulting to `crdt.current_replica_id()`.

### What I did not build

- **Tombstone and history compaction.** Deleted text stays in its row, because `ops_since` must send it to a replica that never saw the insert. A GC needs a stable version that every replica has passed.
- **Merging rows.** Rows only ever split (except "typing on"). Backspacing char by char leaves one tombstone row per char: the trace ends with 83,253 rows for 104,852 chars, about 200 bytes of heap and index per row. Adjacent tombstones of one run could merge into one row, but only when their `del_gen` stamps are equal, or the three-way `set` would see a wrong base; merging older than a horizon (the oldest base still in use) would work. A document typed or pasted in order is about one row per 256 chars.
- **A cached plain-text column.** Measured instead ("Cached plain text"): maintaining `body_text` on every edit costs 13-34 times the latency and 6-44 times the WAL of the edit (10k and 100k chars), because the whole text is rewritten (and TOASTed) each time. For full-text search across many posts, keep a cached column refreshed on a timer or on save (`update posts set body_text = crdt.ydoc_value(body_doc)`), not on every keystroke.
- **Deletes since a version.** `ops_since` sends all deletes. A server-local cursor (`since gen`) would let a client that syncs with one server get only new deletes (`del_gen > g`).
- **Limits for untrusted writers.** `ydoc_apply` buffers inserts whose dependencies are missing; a hostile client can fill `ydoc_pending` with runs that never become ready (seq far ahead). A cap per document, or rejecting seq gaps for the caller's own replica, would close it.
- **Rich text, cursors, undo, Yjs wire compatibility** (non-goals of the brief).

### Alternative: no order key (render from origins)

Without a stored order, render must rebuild the YjsMod order from origins: a tree walk (FugueMax tree) in a recursive CTE, with the sibling order of the integrate rule. Its cheapest possible form is a linked list walked by a recursive CTE, one index probe per row. Measured as a proxy (each row stores its successor's label): 4.5 ms against 0.8 ms at 10k chars, 22 ms against 4 ms at 100k (bench section "Render"). A real origin tree costs more: it also needs the scan order among siblings, and the tree of a typed document is as deep as its longest run of single-character rows. Integration without an order key would still need positions of origins, which is exactly the order. The order key wins on every read and costs one label per row.

## Tests

`experiments/text-table/test/run.sh` (Postgres 16.4, Postgres.app): **All passed: 10/10 files, 124/124 assertions.**

| File | Goal |
| --- | --- |
| `01_basics` | local insert/delete/value/length/version; ops returned by each edit; non-BMP positions; errors (22004, 22023, P0002); device keys; drop |
| `02_security` | no SECURITY DEFINER, PL/pgSQL and SQL only, pinned search_path on writers, VOLATILE writers, STABLE readers, no table privileges for anyone, no dynamic SQL |
| `10_set` | prefix/suffix diff; unicode; 300 random multibyte sets; three-way `set` with base (concurrent paragraphs, delete + append, same-spot inserts); without base the stale save reverts (pinned); base validation |
| `20_convergence` | 30 trials: two servers editing with local positional ops by several replicas, exchanging `ops_since` split into single runs, shuffled, duplicated: same text and version; every op ever returned, shuffled, into a fresh doc; three-server non-interleaving |
| `30_apply` | `ydoc_apply`: own ids, device keys, deletes of others; idempotent re-apply; identity from `crdt.current_replica_id()`; 42501 forged/no identity; 22023 for 13 kinds of malformed ops; buffering of missing origins and predecessors; early deletes; partial overlap; `ops_since` order and run joining |
| `31_wrapper` | the deployment model: no privileges for clients (42501), an app SECURITY DEFINER wrapper with its own check, `session_user` identity, reads through an app function |
| `40_order_keys` | `_ydoc_label` bounds; five adversarial patterns of 2,000 edits that force relabels (backward and forward at one spot, prepend, delete from the left and retype, backspace and retype) against a text model; 4,000 random edits against a model with every invariant every 50 steps; shuffled replay |
| `50_fixtures` | the 57 reference fixtures: shuffled with duplicates, causal, all in one call, and through an `ops_since` round trip; nothing left buffered; invariants |
| `55_trace` | automerge-paper: local edits generate exactly the reference's ops (first 20,000 patches); the reference's ops merged give the same text; the whole trace (batched ops) gives the final text (md5) |
| `60_concurrency` | dblink: a waiting writer integrates against the lock holder's version; four sessions x 150 transactions on one doc: every insert once, length adds up, no deadlock, invariants |

Invariants checked by `pg_temp.ydoc_check` (test/lib/helpers.sql): `docs.len` = block sums = `length(value)`; block counters equal their label ranges; block boundaries are row labels; labels unique and in bounds; `len = length(content)`; ids of each replica contiguous from 1.

## Benchmarks

Environment (from `bench.sh`): Postgres 16.4 (Postgres.app), Apple M4, 10 CPU, 24 GB, macOS 27.0.1; throwaway cluster with `fsync=off`, `full_page_writes=on`, `shared_buffers=512MB`. 2026-11-04. Numbers are from one run of `experiments/text-table/bench.sh` on the benchmark machine; the trace section is from `ONLY=trace` after a fix to the script.

Reading the numbers:

- **Edits are O(edit).** Insert and delete of one char cost 0.26-0.35 ms from 1k to 100k chars and 0.5-0.6 ms at 1M (the block running sum: 722 blocks), including the client round trip and commit. The WAL *records* of an edit stay at 0.5-1.5 kB at every size (one row insert, one or two HOT updates, two index entries, the block and document counters, the lock); what grows with the document is full-page images, because random positions touch pages that have not been written since the last checkpoint. Shape A rewrites the whole value.
- **Reads are O(document).** `value()` is a `string_agg` over the rows: 3.4 ms at 100k chars (26k rows), 60 ms at 1M. `set` renders, diffs and edits: 12 ms at 100k. `ops_since` sends every delete, so even "nothing new" costs a scan of the tombstones (7.8 ms at 100k).
- **Concurrency:** writers to one document serialize (about 3,300 inserts per second whatever the number of clients; latency grows with the queue); writers to different documents scale (11,700 per second with 8 clients). No lost insert, no deadlock.
- **The trace:** 259,778 single-char edits replay locally in 61 s (236 us per edit, 709 bytes of WAL per edit with a commit each); the reference's ops merge in 43 s; the batched ops in 1.5 s. The JS reference replays it in about 4.7 s in memory. Final text identical (md5) in all three.
- **Storage is the weak point.** About 89 bytes of heap per row plus about 65 bytes of index; the random-insert documents average 4 chars per row (45 times the text), and the real trace leaves 83k rows for 105k chars (18 MB) because each backspaced char becomes its own tombstone row. See "Merging rows" above.

### Latency and WAL by document size

Document built by random-position inserts of 8-char words from three replicas, one delete of 1-8 chars per ten steps (a fragmented document: about 4 chars per row). Latency: pgbench average, one client, one transaction per statement (includes the client round trip). WAL: bytes per transaction, measured after a CHECKPOINT and a warm-up run of the same statements (full_page_writes=on).

| size (chars) | rows | tombstone rows | blocks | build ms per row | insert 1 char | delete 1 char | paste 1k | set (300-char paragraph) | value() | version() | ops_since(current) | ops_since({}) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1000 | 261 | 26 | 1 | 0.23 | 0.266 ms | 0.255 ms | 0.589 ms | 1.388 ms | 0.145 ms | 0.162 ms | 0.345 ms | 0.982 ms |
| 10000 | 2602 | 269 | 8 | 0.13 | 0.272 ms | 0.262 ms | 0.565 ms | 4.036 ms | 0.402 ms | 0.165 ms | 1.002 ms | 8.148 ms |
| 100000 | 25895 | 2704 | 69 | 0.11 | 0.291 ms | 0.301 ms | 0.623 ms | 11.985 ms | 3.403 ms | 0.179 ms | 7.821 ms | 82.039 ms |
| 1000000 | 258473 | 26860 | 722 | 0.16 | 0.519 ms | 0.619 ms | 0.895 ms | 109.462 ms | 60.455 ms | 0.225 ms | 72.873 ms | 881.105 ms |

WAL bytes per edit, one transaction each: total (records + full-page images, from pg_waldump). Full-page images are the first change of each page after a checkpoint; random positions in a large document touch many pages, so they dominate there.

| size (chars) | insert 1 char | delete 1 char | paste 1k | set (300-char paragraph) |
|---|---|---|---|---|
| 1000 | 714 (689 + 0) | 497 (476 + 1) | 6947 (6577 + 262) | 3780 (3713 + 0) |
| 10000 | 933 (903 + 0) | 945 (913 + 3) | 6415 (3482 + 2866) | 11299 (10117 + 925) |
| 100000 | 2098 (985 + 1077) | 2263 (1463 + 759) | 11896 (3842 + 7957) | 29272 (16009 + 12754) |
| 1000000 | 18348 (1075 + 17171) | 16699 (1065 + 15541) | 28049 (3027 + 24865) | 338773 (15218 + 321986) |

Storage of the document as built (VACUUM FULL):

| size (chars) | text bytes | rows | avg row bytes | items heap | items indexes | blocks + docs | total bytes | total / text |
|---|---|---|---|---|---|---|---|---|
| 1000 | 1000 | 261 | 89 | 32768 | 40960 | 49152 | 122880 | 122.9x |
| 10000 | 10000 | 2602 | 89 | 286720 | 204800 | 49152 | 540672 | 54.1x |
| 100000 | 100000 | 25895 | 89 | 2793472 | 1679360 | 49152 | 4521984 | 45.2x |
| 1000000 | 1000000 | 258473 | 89 | 27811840 | 16359424 | 147456 | 44318720 | 44.3x |

### Positional index: blocks vs a running sum over the whole document

| size (chars) | variant | insert 1 char | delete 1 char |
|---|---|---|---|
| 10000 | blocks | 0.284 ms | 0.263 ms |
| 10000 | scan | 1.089 ms | 1.367 ms |
| 100000 | blocks | 0.311 ms | 0.346 ms |
| 100000 | scan | 3.698 ms | 4.241 ms |

### Render: order key vs pointer chasing (recursive CTE)

A proxy for 'no order key': each row stores the key of its successor, and render walks the list with a recursive CTE (one index probe per row). An order derived from origins alone needs at least this walk, plus the YjsMod sibling order.

| size (chars) | rows | string_agg order by ord | recursive walk |
|---|---|---|---|
| 10000 | 5926 | 0.37 ms | 4.02 ms |
| 100000 | 29535 | 3.65 ms | 21.59 ms |

### Cached plain text in the app's table (for full-text search)

posts(id, body_doc, body_text) with a GIN index on to_tsvector('simple', body_text). 'cached' = the edit also runs update posts set body_text = crdt.ydoc_value(body_doc). WAL per edit and latency, insert 1 char at a random position.

| size (chars) | variant | latency | WAL bytes per edit | FTS query on 1 post |
|---|---|---|---|---|
| 10000 | render on read | 0.299 ms | 3190 | 3.24 ms |
| 10000 | cached column | 3.896 ms | 17856 | 2.39 ms |
| 100000 | render on read | 0.330 ms | 3868 | 8.42 ms |
| 100000 | cached column | 11.084 ms | 168984 | 4.57 ms |

The FTS column measures one post: the cached query still reads the one row (no use for the GIN index in a one-row table); across many posts, the cached column with a GIN index is the only option that scales, and render on read is not one.

### Concurrency: N sessions inserting at random positions

pgbench -c N -j N, 300 transactions per client, 10k-char document. 'one doc': every client edits document 1 (writes serialize on its row lock). 'own doc': each client edits its own copy of it (documents 2-9; baseline).

| clients | one doc: tps | one doc: latency | own doc: tps | own doc: latency |
|---|---|---|---|---|
| 1 | 3348 | 0.299 ms | 3382 | 0.296 ms |
| 2 | 3752 | 0.533 ms | 6653 | 0.301 ms |
| 4 | 3289 | 1.216 ms | 10223 | 0.391 ms |
| 8 | 3170 | 2.523 ms | 11694 | 0.684 ms |

Every concurrent insert integrated exactly once (the version vector of document 1 counts the 9,000 inserts of the clients, warm-up runs included): t


### Offline merge

Two servers share a 10k-char document, then each makes N edits (random-position inserts of 1-8 chars, every fifth a delete) without syncing. Then each applies ydoc_ops_since(other, own version) from the other. Time of one merge call, and the size of the ops.

| N edits per side | ops_since + merge (ms) | ops bytes | converged |
|---|---|---|---|
| 100 | 14 | 8100 | t |
| 1000 | 94 | 47519 | t |
| 5000 | 443 | 227481 | t |

### Order key: byte-string fractional keys vs bigint labels with relabelling

First 100,000 ops of automerge-paper, local replay (insert/delete by position), commit every 1,000 ops.

| variant | us per op | WAL bytes per op | rows | avg key bytes | max key bytes | ord index bytes |
|---|---|---|---|---|---|---|
| labels | 183 | 667 | 24899 | 8.0 | 8 | 2048000 |
| bytea | 179 | 520 | 24899 | 28.1 | 272 | 2367488 |

### automerge-paper trace

| replay | calls | total s | us per call | WAL bytes per call | final text md5 ok |
|---|---|---|---|---|---|
| local insert/delete by position, commit per op | 259778 | 61.2 | 236 | 709 | t |
| ydoc_merge of batch, commit per call | 2598 | 1.5 | 579 | 4507 | t |
| ydoc_merge of ops, commit per call | 259778 | 42.6 | 164 | 763 | t |

Document after the trace (document 1, local replay):

| chars | text bytes | rows | tombstone rows | relabels (all three replays) | items + indexes (per doc, approx) |
|---|---|---|---|---|---|
| 104852 | 104852 | 83253 | 77463 | 3467 (315223 rows rewritten) | 18 MB |
