# Shape B: table-backed text documents (`ydoc_`)

> **Promoted, 2026-11-05.** `ydoc_` is now part of the extension: the section "ydoc_: collaborative text" of [`pg_crdt--0.0.1.sql`](../../pg_crdt--0.0.1.sql), with user docs in [`docs/types/collaborative-text.md`](../../docs/types/collaborative-text.md). `impl.sql` moved there (its last experiment version is in git history: commit `e1eff4e`, `pg_crdt/experiments/text-table/impl.sql`). The spec files moved to [`test/spec/`](../../test/spec/) as `50_text_*` to `62_text_*` (the experiment's `02_security` was folded into the extension's `02_security`), `test/lib/helpers.sql` to `test/lib/text-helpers.sql`, and they run with the main suite (`./test/run.sh text`). This file stays as the design record; the file and test names below are the experiment's.
>
> | Experiment | Now |
> | --- | --- |
> | `impl.sql` | `pg_crdt--0.0.1.sql`, section `ydoc_` |
> | `test/spec/01_basics`, `10_set`, `20_convergence`, `30_apply`, `31_wrapper`, `35_validate`, `36_review`, `37_relabel_small`, `40_order_keys`, `45_compact`, `50_fixtures`, `55_trace`, `60_concurrency` | `test/spec/50_text_basics`, `51_text_set`, `52_text_convergence`, `53_text_apply`, `54_text_wrapper`, `55_text_validate`, `56_text_review`, `57_text_relabel_small`, `58_text_order_keys`, `59_text_compact`, `60_text_fixtures`, `61_text_trace`, `62_text_concurrency` |
> | `test/spec/02_security` | `test/spec/02_security` (the extension's, extended) |
> | `bench.sh`, `variants/` | here; `bench.sh` loads the extension file, and a variant loads after the extension file without its `ydoc_` section |

Status (before promotion): experiment, 2026-11-04. PL/pgSQL and SQL only; loads after `pg_crdt--0.0.1.sql` with `psql -f` and needs nothing pg_tle cannot install. Contract: [`research/text.md`](../../research/text.md).

| File | What |
| --- | --- |
| `bench.sh` | Benchmarks; prints the Markdown in the "Benchmarks" section. `--quick` skips 1M and most of the trace. |
| `variants/bytea-keys.sql` | The first version, with byte-string fractional keys instead of bigint labels. Kept for the benchmark comparison only. |

## API

| Function | Returns | Labels | Notes |
| --- | --- | --- | --- |
| `ydoc_create()` | `bigint` | volatile | A new empty document. |
| `ydoc_value(doc)` | `text` | stable | Plain text; null for a missing document. `string_agg(content order by ord)`. |
| `ydoc_length(doc)` | `integer` | stable | Visible code points (a column of `ydoc_docs`). |
| `ydoc_insert(doc, pos, chars, replica)` | ops `jsonb` | volatile | Local edit. `replica` is an entry key (`id` or `id:device`). Every local edit returns `{"v", "i", "d"}`; `v` is the document's version vector before the edit, so the op passes `ydoc_apply` elsewhere. |
| `ydoc_delete(doc, pos, len, replica)` | ops `jsonb` | volatile | Local edit. |
| `ydoc_set(doc, new_text, replica, base default null)` | ops `jsonb` | volatile | Prefix/suffix diff, one delete and one insert. See "set and concurrent saves". |
| `ydoc_base(doc)` | `jsonb` | stable | `{"g": gen, "v": vv}`: what an editor started from, for `ydoc_set`'s `base`. |
| `ydoc_apply(doc, ops, replica default crdt.current_replica_id())` | `text` | volatile | Untrusted path: inserts only with the caller's ids (owner rule of `pn_apply_delta`); the op must carry `v` and pass the causal rules V0-V7, as a whole. Returns `'accepted'` or `'pending'` (waits for ids named in `v`). See "Causal validation". |
| `ydoc_merge(doc, ops)` | void | volatile | Trusted path: ops from any replica (another server's `ops_since`, a replay). Ignores `v`; not safe against a byzantine writer. |
| `ydoc_ops_since(doc, vv default '{}')` | ops `jsonb` | stable | Inserts above `vv` in integration order (causal), joined into maximal runs; every delete. No `v`: catch-up ops are for `ydoc_merge` only. |
| `ydoc_version(doc)` | `jsonb` | stable | `{replica: highest seq}`; one index probe per replica. |
| `ydoc_compact(doc, horizon default null)` | `integer` | volatile | Maintenance: merges adjacent rows of one run with the same visibility; tombstones stamped at or before `horizon` (default: now) merge. Returns rows removed. See "Compaction". |
| `ydoc_drop(doc)` | void | volatile | Deletes the document and its rows. |

Positions and lengths count code points (`length()`), not UTF-16 units. Errors: `22004` null argument; `22023` malformed ops, a replica key that is not one (or is longer than 256 bytes), a number not written as digits, a base from another document, a position outside the text, a base that is not a version of the document, an insert whose originRight is not after its originLeft, an op that breaks a causal rule (the message names it: `V0`..`V6`), the same ids re-sent with other content or origins; `54000` a limit of the untrusted path (`ydoc_apply`): too many waiting ops for the writer, more than 256 runs in one op, more than 16 device keys per owner, origins further apart than the scan budget; `42501` no identity or a forged insert (`ydoc_apply`), or no table privileges (Postgres); `P0002` no such document.

## Design

### Tables

```
ydoc_docs(id, len, gen, horizon)                one row per document; the row lock serializes writers
ydoc_replicas(doc, id int, name)                replica ids (entry keys), interned per document
ydoc_items(doc, ord, ins, seq, replica,         one row per run of characters of one replica
           ol_seq, ol_replica, or_seq, or_replica,  replicas as interned ints; pk (doc, replica, seq); index (doc, ord)
           del_gen, len, content)
ydoc_blocks(doc, lo, vis, n)                    positional index: label ranges with visible length and row count
ydoc_pending(doc, replica, seq, ol_*, or_*, content)   inserts waiting for their dependencies
ydoc_pending_deletes(doc, replica, seq, len)    deletes of ids not seen yet (trusted path)
ydoc_deps(doc, replica, seq, dp)                rule V3: a replica's cumulative dependencies, where they change
ydoc_pending_ops(doc, id, writer, op, bytes)    untrusted ops waiting for ids named in v (V7), quota per writer
ydoc_rejected(doc, writer, op, reason, at)      waiting ops rejected when finally decided
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

### Compaction (storage)

Rows only split during editing. The automerge-paper trace ends with 83,253 rows for 104,852 chars, and 77,463 of them are tombstones: every backspace splits the char off its run and stamps it with its own `del_gen`. Most of those tombstones are consecutive ids of one run, adjacent in the order, with the same originRight, so they are one run again, except for their stamps.

`crdt.ydoc_compact(doc, horizon default null)` merges each maximal chain of rows (in `ord` order) that continue one run (same replica, consecutive seqs, the right row's originLeft the left row's last char, the same originRight) and have the same visibility: both visible, both deleted with equal stamps, or both deleted at or before `horizon`. A merged tombstone keeps the latest stamp of its chain, which is still at or before the horizon, so the text at any base at or after the horizon is exact. The horizon is stored per document, and `ydoc_set` refuses a base older than it with `22023` and a hint to re-read (or to save without base, a two-way diff). Refusing is deliberate: a wrong base text widens the diff, which reverts or duplicates other editors' text. Chains do not cross block boundaries (a block's `lo` must stay a row label), a merged row holds at most about twice the run cap (256 chars), and the merged row keeps the smallest `ins`, which keeps `ops_since` causal.

Nothing a reader or a peer sees changes: the text, the ids, the version vector, and the text of `ops_since` (spec `45_compact`). The fixtures still match the reference with a compaction after every 5 ops, and the local replay of the trace still generates the reference's ops op for op with a compaction every 2,000 patches (spec `50_fixtures`, `55_trace`), because origins name ids and never rows.

Effect on the trace document, measured right after the replay: **83,253 rows and 15.6 MB become 12,636 rows and 2.7 MB (149 to 26 bytes per char of text)**. The bench table ("Storage: ydoc_compact") measures after 3,000 extra random edits: 16,399 rows, 32 bytes per char, compaction in 281 ms.

When to run it: on save, or from a scheduled job, with `horizon` = the oldest base an editor may still send (the write counter `g` of `ydoc_base` at the start of the oldest open editing session), or the default (now) when the app does not use three-way `set`. It takes the document's lock like any write, and costs a scan of the document's rows.

What I measured and did not change:

- **Run extension on typing** (candidate 1 of the brief) was already in the first version ("typing on" above): an insert directly after the replica's own last char, with that char's originRight, extends the row in place. Disabled in a variant (`... and false`), the full trace replay (local, commit every 5,000 ops, one run each on a dev cluster) makes 182,315 rows instead of 83,253, a 33.7 MB item table instead of 15.5 MB, 3,684 bytes of WAL per op instead of 714, and 1,319 us per op instead of 377. The extension's HOT update is much smaller than a new row with two index entries, and one row per typed char also exhausts the label gaps at the typing spot (more relabels). It cannot help after a backspace: the reference's convention makes the next char's originLeft the visible char before the deleted one, so the new char does not continue the run (Yjs does the same).
- **Interning replica ids**: done next, see "Interned replica ids".
- **fillfactor 90** on the item table leaves 10% of each page free for HOT updates (a split updates the left part, a delete stamps a row); `VACUUM FULL` keeps that free space. Lowering it to 100 would save 10% of the heap and turn those updates into new tuples with index entries.

### Causal validation (untrusted path)

Amendment 1 of `research/text.md`: an untrusted writer could pick origins that exist but were not adjacent for it, and two delivery orders then gave two texts. `ydoc_apply` now implements rules V0-V7 of `experiments/text-ref/README.md` (the reference's `apply(op, {validate: true})`); `ydoc_merge` stays the trusted path. In order:

1. Shape (both paths), then the owner rule (42501).
2. **Static rules** on the op alone (`_ydoc_vstatic`), before any lock or wait: V0 (`v` present, entry keys, counts >= 1), V1 (both origins covered by `v` advanced run by run), V2 (a run starts at `v[replica] + 1`), V6 (delete targets covered by the advanced `v`, so nobody can pre-delete text it has not seen).
3. **V7.** If the document lacks an id that `v` names, the op is stored in `ydoc_pending_ops` and the call returns `'pending'`. Each writer may have `_ydoc_pending_max_ops()` = 100 waiting ops of at most `_ydoc_pending_max_bytes()` = 256 kB in total per document; beyond that, 54000. Every write to the document (trusted, untrusted, local) ends by deciding the waiting ops it made decidable (`_ydoc_drain_ops`), each in a subtransaction: an op that fails then, with a rule or with any other error, is undone, logged in `ydoc_rejected` (writer, op, SQLSTATE and message; the last `_ydoc_rejected_max()` = 100 per writer and document are kept), and does not fail the innocent caller.
4. **Dynamic rules** once the document covers `v` (`_ydoc_vapply`, lock held): V3 (`v` is causally closed: for each replica in `v`, the stored cumulative dependencies of its item `v[r]` are covered by `v`), then per run V4 (originLeft before originRight) and V5 (no row strictly between the origins holds an id covered by the advanced `v`). V4 and V5 run inside `_ydoc_integrate`, on the same `(l_ord, r_ord)` range the YjsMod scan walks; for honest typing it is empty. Then the deletes, whose targets V6 guarantees are present, so the untrusted path never needs `ydoc_pending_deletes`.

The op is accepted or rejected as a whole: any rule raises 22023, which undoes everything the op did in the caller's statement (or in the subtransaction of a waiting op). The rule's id is in the message.

**V3's dependency vector.** dp(r, n) is the per-replica maximum origin seq over items (r, 1..n), other replicas only. It is constant along a run (later chars' originLeft is the same replica, their originRight the run's), so `ydoc_deps` stores a row only at the first seq of a run whose origins raise it, holding the whole map (jsonb keyed by interned replica id); dp(r, n) is the row with the highest seq <= n, one index probe. It is maintained on every path (all items can be named by a later untrusted op's `v`). A document written by one replica, like the trace, has no rows; the 3-writer random documents get about one row per insert (see the storage table). The V3 check costs one probe per replica in `v`.

**Equivocation.** `(doc, replica, seq)` is the primary key, so the first arrival wins. A run whose ids are already present must match what is stored (first char's origins, later chars' implied origins, text): an identical re-send is accepted as a no-op, anything else is refused with 22023, on both paths. A partial overlap is refused on the untrusted path (only equivocation produces one there); on the trusted path the overlap must match and the new tail is integrated. This turns a silent divergence on the trusted path into an error at the server that sees both versions; the README explains why `v` cannot prevent equivocation in general (it needs one writer per id: here, the owner rule plus the primary key).

**Local edits emit `v`.** `ydoc_insert`, `ydoc_delete` and two-way `ydoc_set` put the document's version vector before the edit in the op (one probe per replica). The op passes the rules on any other document: on the trace, the generated ops equal the reference's ops including `v` (20,000 patches, spec `55_trace`). A three-way `ydoc_set` works against an extended base: the base's vector, plus the writer's own items, plus their causal closure (repeatedly adding the stored dependencies of every replica's last covered item). It diffs against the text of that version and uses it as the op's `v`, so a second save from one base does not insert the first save's text again, and peers accept the op (it is closed, covers the writer's clock, and its origins are adjacent in it). A stale editor's text is then compared with everything the writer had seen: text the writer's own later edits depended on, and that the stale text lacks, is deleted by the save. The base token carries the document id; a base from another document is 22023.

**Catch-up ops are trusted only.** `ydoc_ops_since` returns ops without `v`, joined from runs created under different claims; `ydoc_apply` refuses them (V0, or 42501 for other writers' ids). A server that relays over an untrusted link must forward the writers' original ops.

**Cost** (same bench, the previous commit 934bfe2 against this one; one run each on the benchmark machine):

| | before | after |
|---|---|---|
| trace, 259,778 ops through `ydoc_apply` (commit per op) | 219 us/op, 784 B WAL (rules not checked, `v` ignored) | 300 us/op, 759 B WAL (+37%) |
| trace through `ydoc_merge` (trusted) | 201 us/op | 200 us/op |
| trace, batched (2,598 ops of 100 patches) through `ydoc_apply` | 631 us/op | 695 us/op |
| trace, local insert/delete by position (now also builds `v`) | 241 us/op, 704 B WAL | 280 us/op, 698 B WAL (+16%) |
| insert 1 char, 1k / 10k / 100k / 1M chars (pgbench) | 0.27 / 0.30 / 0.33 / 0.52 ms | 0.32 / 0.35 / 0.39 / 0.55 ms |
| delete 1 char, same sizes | 0.24 / 0.27 / 0.34 / 0.61 ms | 0.27 / 0.31 / 0.35 / 0.66 ms |
| `ydoc_deps` (V3), trace (one writer) | | 0 rows, 0 bytes |
| `ydoc_deps`, random 3-writer documents 100k / 1M chars | | 611 rows, 147 kB (3% of the total) / 1,996 rows, 328 kB (0.7%) |

The validated path costs about 80 us per op over the old untrusted path: the static checks, one probe per replica for V7 and V3, the V5 range query (empty for typing), and the re-keying of `v` by interned id. Local edits pay about 40 us for the version vector of their op (`ydoc_version` was rewritten for this: a backwards loose index scan, 23 us for three replicas instead of 134). The dependency vector is cheap because it is a cumulative maximum: it saturates, so it changes at a small fraction of runs.

**Cost of the review fixes** (b8bffd2 against this version, same bench, one run each): insert 1 char 0.32 / 0.35 / 0.39 / 0.55 ms at 1k / 10k / 100k / 1M chars became 0.34 / 0.38 / 0.42 / 0.68 ms; delete 0.27 / 0.31 / 0.35 / 0.66 became 0.28 / 0.32 / 0.37 / 0.72 ms; the trace through `ydoc_apply` 300 became 348 us per op, through `ydoc_merge` 200 became 229, local edits 280 became 282. Most of it is the pinned `search_path` on every PL/pgSQL function (a GUC save and restore per call, about a dozen calls per op): measured alone on 60,000 trace ops in one transaction, pinning the internal functions too costs nothing measurable on `ydoc_merge` and 18% on `ydoc_apply` (568 against 674 us per op). The alternative, pinning only the API functions (the internals inherit their caller's pinned path), is safe only if nobody calls the internals directly with a hostile path; they must stay executable by the callers of the API, so it was not taken.

### Interned replica ids

Rows named replicas by text three times (`replica`, `ol_replica`, `or_replica`), and the primary key once more. `crdt.ydoc_replicas(doc, id, name)` interns them per document (dense ids: max + 1 under the document's lock): items hold 4-byte integers, and the integer columns sit together after the 8-byte ones (no padding). Names are translated at the boundary only: ops in (`_ydoc_try` interns the run's replica when it integrates, and looks up its origins), ops out (`ops_since`, the ops returned by local edits, `ydoc_version` join the names back), and `ydoc_set`'s base vector (re-keyed by integer once per call). The integer never leaves the database. The YjsMod tie-break compares the **names** (`collate "C"`), looked up for the one row being compared, only when originLeft and originRight both tie, which is rare; the unicode-replica and case-replica fixtures pin it. The buffers (`ydoc_pending`, `ydoc_pending_deletes`) keep names, so input that never becomes ready (forged or far-ahead ids) does not grow `ydoc_replicas`. A replica's first insert in a document writes one row there. The first version interned for the whole database with a unique name index: two transactions on different documents that interned the same new names in opposite orders deadlocked (review finding 9), and the names outlived `ydoc_drop`. Per document, interning happens under the lock the write already holds, and `ydoc_drop` deletes the names.

Measured on the automerge-paper trace (bench section "Replica id length", two runs of each version, averages; the WAL columns of single runs vary by 30% with relabels and full-page images, so they are left out here):

| replica ids | version | bytes per char | after ydoc_compact | insert 1 char | delete 1 char | value() | replay us per op |
|---|---|---|---|---|---|---|---|
| `paper` | text names | 148.7 | 31.8 | 0.35 ms | 0.42 ms | 4.2 ms | 382 |
| `paper` | interned | 134.5 | 29.0 | 0.37 ms | 0.39 ms | 3.9 ms | 338 |
| 36-char UUID | text names | 264.5 | 54.5 | 0.36 ms | 0.40 ms | 4.8 ms | 344 |
| 36-char UUID | interned | 134.5 | 29.0 | 0.40 ms | 0.45 ms | 4.2 ms | 336 |

Kept: storage no longer depends on the length of replica ids (UUIDs: -49%, and -47% after compaction; `paper`: -10%), replay and render are as fast or faster, and single edits cost 0.02-0.05 ms more (the name lookups for the returned op and the interning probe; the writer's own id is not looked up again).

### Review fixes (2026-11-05)

An adversarial review of the validated version found the following. Each has a regression in `test/spec/36_review.sql` (or `37_relabel_small.sql`); the reviewer's differential fuzzer against `ref.mjs` (`/tmp/ydrev/fuzz.mjs`: honest and byzantine ops, two delivery orders with duplicates, compactions, local edits, a mid-way catch-up merge) now reports 0 failing seeds for seeds 1-150 and 1000-1100 with shrunk constants and 1-100 with the defaults.

| Finding | Fix |
| --- | --- |
| A parked op whose decision raised something other than 22023 (a 6 kB device key overflowed the name index: 54000) escaped `_ydoc_drain_ops` and blocked every later write to the document | Replica keys are capped at `_ydoc_key_max()` = 256 bytes everywhere (ops, `v`, local edits, the identity); the drain catches every error, logs it, and never fails the caller |
| A second three-way `set` from one base inserted the first save's text again, and its `v` (base + own clock) failed V3/V5 on peers | Extended base (base + own items + causal closure) for both the base text and the op's `v` |
| Runs buffered on the trusted path stayed stuck when their origin arrived through `ydoc_apply` (decided later) or a local edit | `_ydoc_vapply`, `_ydoc_insert_at` and the three-way `set` drain the trusted buffer after integrating |
| V5 cost: 3,000 chained one-char runs with `v` {} read the whole document once per run (4.6 s on 20k rows) | Runs that continue each other are joined before checking (47 ms); at most `_ydoc_runs_max()` = 256 runs per op; the rows an op may read for V5 and the YjsMod scan together are capped at `_ydoc_scan_max()` = 250,000 (54000 beyond) |
| Device-key bloat: 300 keys of 2 kB made every later `v` 601 kB | The 256-byte cap, at most `_ydoc_devices_max()` = 16 device keys per owner and document (54000), names interned per document and deleted by `ydoc_drop` |
| `_ydoc_relabel` moved block labels in one update and could hit the (doc, lo) primary key (23505) | Two phases: out of the label range, then onto the new labels |
| `ydoc_version` (PL/pgSQL) had no pinned `search_path`: an exact-type `\|\|` on the caller's path ran inside it | Every PL/pgSQL function pins `search_path = pg_catalog, pg_temp`; every SQL function has a SQL-standard body; `02_security` asserts both |
| `ydoc_rejected` grew without bound; `1.0` passed the number check and failed a cast with 22P02; a base from another document was accepted; `ydoc_delete` at position 2147483647 overflowed (22003) | The last 100 rejections per writer and document; numbers must be written as digits (22023); the base names its document; the range check is in bigint |
| Interning deadlock between two documents | Interning per document (above) |

originLeft = originRight used to be refused on arrival as malformed; it now goes through V7 and V4 like in the reference, so every server decides it the same way.

### Security model

The tables belong to the extension and nobody but their owner has privileges on them. The functions are SECURITY INVOKER (no SECURITY DEFINER, per the conventions), so a call runs with the caller's table privileges, and a role without them gets `42501` from any `ydoc_` function. EXECUTE is granted to public, as for `pn_`; the table privileges are the gate.

The intended deployment (spec `31_wrapper`):

1. The DBA grants `select, insert, update, delete` on the nine `crdt.ydoc_*` tables and `usage` on `crdt.ydoc_ins`, `crdt.ydoc_docs_id_seq` and `crdt.ydoc_replicas_id_seq` to the role that owns the app's functions (or to a trusted backend role).
2. The app's table references the document: `posts.body_doc bigint references crdt.ydoc_docs (id)`.
3. Untrusted clients call the app's SECURITY DEFINER functions, which check the app's own rule ("may this user edit post X"), then call `crdt.ydoc_apply(doc, ops, <identity>)` with the identity the app trusts (`session_user`, a JWT claim, a users-table lookup). `ydoc_apply` enforces that inserts carry only that identity's ids.
4. Reads go through an app function too. A view does not work: `crdt.ydoc_value` reads the tables with the caller's privileges, not the view owner's.

Row-level security on the `crdt.ydoc_*` tables would also work (policies that look up the app's table by `doc`), but policies on extension-owned tables are the app's to maintain and run on every row of every scan; the wrapper pattern checks once per call. Nothing assumes a platform: identity is an argument, defaulting to `crdt.current_replica_id()`.

### What I did not build


- **Tombstone and history compaction.** Deleted text stays in its row, because `ops_since` must send it to a replica that never saw the insert. A GC needs a stable version that every replica has passed.
- **Automatic compaction.** `ydoc_compact` is a call the app makes. Doing it inside edits would need the horizon on every write; a scheduled job is simpler.
- **A cached plain-text column.** Measured instead ("Cached plain text"): maintaining `body_text` on every edit costs 13-34 times the latency and 6-44 times the WAL of the edit (10k and 100k chars), because the whole text is rewritten (and TOASTed) each time. For full-text search across many posts, keep a cached column refreshed on a timer or on save (`update posts set body_text = crdt.ydoc_value(body_doc)`), not on every keystroke.
- **Deletes since a version.** `ops_since` sends all deletes. A server-local cursor (`since gen`) would let a client that syncs with one server get only new deletes (`del_gen > g`).
- **Rich text, cursors, undo, Yjs wire compatibility** (non-goals of the brief).

### Alternative: no order key (render from origins)

Without a stored order, render must rebuild the YjsMod order from origins: a tree walk (FugueMax tree) in a recursive CTE, with the sibling order of the integrate rule. Its cheapest possible form is a linked list walked by a recursive CTE, one index probe per row. Measured as a proxy (each row stores its successor's label): 4.5 ms against 0.8 ms at 10k chars, 22 ms against 4 ms at 100k (bench section "Render"). A real origin tree costs more: it also needs the scan order among siblings, and the tree of a typed document is as deep as its longest run of single-character rows. Integration without an order key would still need positions of origins, which is exactly the order. The order key wins on every read and costs one label per row.

## Tests

`experiments/text-table/test/run.sh` (Postgres 16.4, Postgres.app): **All passed: 14/14 files, 195/195 assertions.**

| File | Goal |
| --- | --- |
| `01_basics` | local insert/delete/value/length/version; ops returned by each edit; non-BMP positions; errors (22004, 22023, P0002); device keys; drop |
| `02_security` | no SECURITY DEFINER, PL/pgSQL and SQL only, pinned search_path on writers, VOLATILE writers, STABLE readers, no table privileges for anyone, no dynamic SQL |
| `10_set` | prefix/suffix diff; unicode; 300 random multibyte sets; three-way `set` with base (concurrent paragraphs, delete + append, same-spot inserts); without base the stale save reverts (pinned); base validation |
| `20_convergence` | 30 trials: two servers editing with local positional ops by several replicas, exchanging `ops_since` split into single runs, shuffled, duplicated: same text and version; every op ever returned, shuffled, into a fresh doc; three-server non-interleaving |
| `30_apply` | `ydoc_apply`: own ids, device keys, deletes of others; idempotent re-apply; identity from `crdt.current_replica_id()`; 42501 forged/no identity; 22023 for 13 kinds of malformed ops; buffering of missing origins and predecessors; early deletes; partial overlap; `ops_since` order and run joining |
| `35_validate` | rules V0-V7 one case each (22023 with the rule in the message); the review's repro in both orders (abcY); V7 waits, then accepted, or rejected into `ydoc_rejected` without failing the caller; the waiting quota (54000); atomicity (second run breaks a rule, first not applied); equivocation refused on both paths, identical re-send accepted; catch-up ops refused by `ydoc_apply`; 150 honest local ops from three writers pass in order and shuffled |
| `36_review` | regressions for the review findings above: over-long keys, a parked op failing with 54000 does not block the document, the device quota, repeated three-way saves accepted by peers, a base from another document, trusted buffers drained after the untrusted path, joined chained runs, the runs cap and the scan budget, an evil operator on the caller's `search_path`, the bounded rejection log, `1.0` numbers, delete overflow, no interning deadlock (dblink), originLeft = originRight decided by V4 |
| `37_relabel_small` | 1,500 random edits with shrunk tuning constants (relabels all the time) against a model: block labels never collide |
| `31_wrapper` | the deployment model: no privileges for clients (42501), an app SECURITY DEFINER wrapper with its own check, `session_user` identity, reads through an app function |
| `40_order_keys` | `_ydoc_label` bounds; five adversarial patterns of 2,000 edits that force relabels (backward and forward at one spot, prepend, delete from the left and retype, backspace and retype) against a text model; 4,000 random edits against a model with every invariant every 50 steps; shuffled replay |
| `45_compact` | two documents with the same 3,000 edits (backspace bursts), one compacted every 200: same text, version and `ops_since` text, fewer rows, invariants; three-way `set` with a base at the horizon equals the twin's result; an older base is refused (22023); the horizon keeps newer tombstones apart |
| `50_fixtures` | the 71 reference fixtures (57 honest, 14 malicious). Untrusted path: every op through `ydoc_apply`, shuffled with duplicates and causal: the text, and exactly the reference's rejected positions (in-call 22023 plus later rejections in `ydoc_rejected`), no op left waiting, no quota hit. Trusted path (without the ops the reference rejects): shuffled with duplicates, shuffled with `ydoc_compact` every 5 ops, causal, all in one call, and through an `ops_since` round trip; nothing left buffered; invariants |
| `55_trace` | automerge-paper: local edits generate exactly the reference's ops (`v`, `i`, `d`); the reference's ops through `ydoc_apply` are all accepted and give the same text; (first 20,000 patches, with `ydoc_compact` every 2,000); the reference's ops merged give the same text; the whole trace (batched ops) gives the final text (md5) |
| `60_concurrency` | dblink: a waiting writer integrates against the lock holder's version; four sessions x 150 transactions on one doc: every insert once, length adds up, no deadlock, invariants |

Invariants checked by `pg_temp.ydoc_check` (test/lib/helpers.sql): `docs.len` = block sums = `length(value)`; block counters equal their label ranges; block boundaries are row labels; labels unique and in bounds; `len = length(content)`; ids of each replica contiguous from 1.

## Benchmarks

Environment (from `bench.sh`): Postgres 16.4 (Postgres.app), Apple M4, 10 CPU, 24 GB, macOS 27.0.1; throwaway cluster with `fsync=off`, `full_page_writes=on`, `shared_buffers=512MB`. 2026-11-04. Numbers are from one run of `experiments/text-table/bench.sh` on the benchmark machine, with interned replica ids and the causal rules (2026-11-05); the size and trace sections were re-run after the review fixes (`ONLY=sizes,trace`).

Reading the numbers:

- **Edits are O(edit).** Insert and delete of one char cost 0.28-0.42 ms from 1k to 100k chars and 0.68-0.72 ms at 1M (the block running sum: 722 blocks), including the client round trip and commit. The WAL *records* of an edit stay at 0.5-1.5 kB at every size (one row insert, one or two HOT updates, two index entries, the block and document counters, the lock); what grows with the document is full-page images, because random positions touch pages that have not been written since the last checkpoint. Shape A rewrites the whole value.
- **Reads are O(document).** `value()` is a `string_agg` over the rows: 3.5 ms at 100k chars (26k rows), 53 ms at 1M. `set` renders, diffs and edits: 12 ms at 100k. `ops_since` sends every delete, so even "nothing new" costs a scan of the tombstones (8.3 ms at 100k).
- **Concurrency:** writers to one document serialize (about 3,300 inserts per second whatever the number of clients; latency grows with the queue); writers to different documents scale (11,700 per second with 8 clients). No lost insert, no deadlock.
- **The trace:** 259,778 single-char edits replay locally in 73 s (282 us per edit, 701 bytes of WAL per edit with a commit each); the reference's ops go through the untrusted path (`ydoc_apply`, rules V0-V7) in 90 s (348 us) and the trusted path (`ydoc_merge`) in 60 s (229 us); the batched ops in about 2 s. The JS reference replays it in about 4.7 s in memory. Final text identical (md5) in all five replays.
- **Storage was the weak point; compaction fixes the common case.** About 89 bytes of heap per row plus about 65 bytes of index. The real trace leaves 83k rows for 105k chars (15.6 MB, 149 bytes per char) because each backspaced char becomes its own tombstone row; `ydoc_compact` folds them (32 bytes per char in the table below, which includes 3,000 pgbench edits made before the compaction; 26 bytes per char right after the replay). It does not help the random-insert documents (45 times the text): their rows are live short runs separated by other runs, and nothing can merge them.
- **Before and after compaction** (trace document, from "Storage: ydoc_compact"):

| | rows | total bytes | bytes per char | insert 1 char | WAL per insert | delete 1 char | WAL per delete | value() |
|---|---|---|---|---|---|---|---|---|
| before | 83,253 | 15,613,952 | 148.9 | 0.366 ms | 3,472 | 0.398 ms | 3,772 | 4.0 ms |
| after | 16,399 | 3,358,720 | 32.0 | 0.315 ms | 1,993 | 0.360 ms | 1,854 | 1.9 ms |

  Edits get cheaper, not dearer: the WAL records stay at 1.3-1.5 kB, and there are fewer pages to take full-page images of. The compaction itself took 281 ms and 12 MB of WAL (it rewrites the merged rows). For the random 100k document the "after" row is larger than "before" because the measured edits of the "before" row (3,000 of them) land in between and compaction found only 987 rows to remove.

### Latency and WAL by document size

Document built by random-position inserts of 8-char words from three replicas, one delete of 1-8 chars per ten steps (a fragmented document: about 4 chars per row). Latency: pgbench average, one client, one transaction per statement (includes the client round trip). WAL: bytes per transaction, measured after a CHECKPOINT and a warm-up run of the same statements (full_page_writes=on).

| size (chars) | rows | tombstone rows | blocks | build ms per row | insert 1 char | delete 1 char | paste 1k | set (300-char paragraph) | value() | version() | ops_since(current) | ops_since({}) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1000 | 261 | 26 | 1 | 0.25 | 0.342 ms | 0.283 ms | 0.643 ms | 1.470 ms | 0.122 ms | 0.108 ms | 0.304 ms | 1.060 ms |
| 10000 | 2602 | 269 | 8 | 0.14 | 0.375 ms | 0.321 ms | 0.708 ms | 3.797 ms | 0.400 ms | 0.102 ms | 1.122 ms | 8.573 ms |
| 100000 | 25895 | 2704 | 69 | 0.14 | 0.422 ms | 0.367 ms | 0.831 ms | 12.278 ms | 3.577 ms | 0.105 ms | 10.128 ms | 86.984 ms |
| 1000000 | 258473 | 26860 | 722 | 0.19 | 0.684 ms | 0.723 ms | 1.032 ms | 127.264 ms | 55.574 ms | 0.230 ms | 100.193 ms | 926.825 ms |

WAL bytes per edit, one transaction each: total (records + full-page images, from pg_waldump). Full-page images are the first change of each page after a checkpoint; random positions in a large document touch many pages, so they dominate there.

| size (chars) | insert 1 char | delete 1 char | paste 1k | set (300-char paragraph) |
|---|---|---|---|---|
| 1000 | 693 (670 + 0) | 522 (500 + 0) | 3272 (3215 + 0) | 2973 (2915 + 0) |
| 10000 | 907 (879 + 0) | 954 (908 + 17) | 5936 (3507 + 2363) | 9299 (8252 + 829) |
| 100000 | 2323 (1048 + 1237) | 2648 (1449 + 1157) | 14676 (3237 + 11338) | 28971 (15660 + 12821) |
| 1000000 | 14157 (900 + 13177) | 16131 (1054 + 14986) | 26984 (2984 + 23858) | 342811 (14845 + 326389) |

Storage of the document as built (VACUUM FULL):

| size (chars) | text bytes | rows | avg row bytes | items heap | items indexes | deps rows (V3) | deps bytes | blocks + docs + deps | total bytes | total / text |
|---|---|---|---|---|---|---|---|---|---|---|
| 1000 | 1000 | 261 | 89 | 32768 | 40960 | 56 | 32768 | 81920 | 155648 | 155.6x |
| 10000 | 10000 | 2602 | 89 | 286720 | 204800 | 185 | 73728 | 122880 | 614400 | 61.4x |
| 100000 | 100000 | 25895 | 89 | 2793472 | 1679360 | 611 | 147456 | 196608 | 4669440 | 46.7x |
| 1000000 | 1000000 | 258473 | 89 | 27811840 | 16359424 | 1996 | 327680 | 475136 | 44646400 | 44.6x |

### Positional index: blocks vs a running sum over the whole document

| size (chars) | variant | insert 1 char | delete 1 char |
|---|---|---|---|
| 10000 | blocks | 0.360 ms | 0.313 ms |
| 10000 | scan | 1.052 ms | 1.336 ms |
| 100000 | blocks | 0.448 ms | 0.408 ms |
| 100000 | scan | 3.943 ms | 4.084 ms |

### Render: order key vs pointer chasing (recursive CTE)

A proxy for 'no order key': each row stores the key of its successor, and render walks the list with a recursive CTE (one index probe per row). An order derived from origins alone needs at least this walk, plus the YjsMod sibling order.

| size (chars) | rows | string_agg order by ord | recursive walk |
|---|---|---|---|
| 10000 | 5909 | 0.39 ms | 3.94 ms |
| 100000 | 29565 | 3.55 ms | 22.17 ms |

### Cached plain text in the app's table (for full-text search)

posts(id, body_doc, body_text) with a GIN index on to_tsvector('simple', body_text). 'cached' = the edit also runs update posts set body_text = crdt.ydoc_value(body_doc). WAL per edit and latency, insert 1 char at a random position.

| size (chars) | variant | latency | WAL bytes per edit | FTS query on 1 post |
|---|---|---|---|---|
| 10000 | render on read | 0.344 ms | 1567 | 3.18 ms |
| 10000 | cached column | 3.960 ms | 18442 | 2.45 ms |
| 100000 | render on read | 0.439 ms | 4179 | 8.37 ms |
| 100000 | cached column | 10.821 ms | 157299 | 4.25 ms |

The FTS column measures one post: the cached query still reads the one row (no use for the GIN index in a one-row table); across many posts, the cached column with a GIN index is the only option that scales, and render on read is not one.

### Concurrency: N sessions inserting at random positions

pgbench -c N -j N, 300 transactions per client, 10k-char document. 'one doc': every client edits document 1 (writes serialize on its row lock). 'own doc': each client edits its own copy of it (documents 2-9; baseline).

| clients | one doc: tps | one doc: latency | own doc: tps | own doc: latency |
|---|---|---|---|---|
| 1 | 2557 | 0.391 ms | 2576 | 0.388 ms |
| 2 | 2777 | 0.720 ms | 4946 | 0.404 ms |
| 4 | 2125 | 1.882 ms | 7986 | 0.501 ms |
| 8 | 2282 | 3.505 ms | 10723 | 0.746 ms |

Every concurrent insert integrated exactly once (the version vector of document 1 counts the 9,000 inserts of the clients, warm-up runs included): t


### Offline merge

Two servers share a 10k-char document, then each makes N edits (random-position inserts of 1-8 chars, every fifth a delete) without syncing. Then each applies ydoc_ops_since(other, own version) from the other. Time of one merge call, and the size of the ops.

| N edits per side | ops_since + merge (ms) | ops bytes | converged |
|---|---|---|---|
| 100 | 14 | 8100 | t |
| 1000 | 108 | 47519 | t |
| 5000 | 505 | 227481 | t |

### Order key: byte-string fractional keys vs bigint labels with relabelling

First 100,000 ops of automerge-paper, local replay (insert/delete by position), commit every 1,000 ops.

| variant | us per op | WAL bytes per op | rows | avg key bytes | max key bytes | ord index bytes |
|---|---|---|---|---|---|---|
| labels | 208 | 596 | 24899 | 8.0 | 8 | 2048000 |
| bytea | 177 | 499 | 24899 | 28.1 | 272 | 2367488 |

### Storage: ydoc_compact

Before and after crdt.ydoc_compact(doc) (horizon = now). 'trace': the automerge-paper document after a local replay (commit every 5,000 ops). 'random 100k': the 100k-char random-insert document of the size table. Sizes after VACUUM FULL. Latency and WAL per edit as in the size table (pgbench, warm-up run, records + full-page images); value() is the render.

| document | state | rows | tombstone rows | total bytes | bytes per char | insert 1 char | delete 1 char | value() | WAL per insert | WAL per delete |
|---|---|---|---|---|---|---|---|---|---|---|
| trace | before | 83253 | 77463 | 14131200 | 134.8 | 0.412 ms | 0.461 ms | 3.810 ms | 3212 (1458 + 1711) | 5141 (2973 + 2101) |
| trace | after | 16388 | 7851 | 3063808 | 29.2 | 0.404 ms | 0.388 ms | 1.844 ms | 1770 (1260 + 474) | 1789 (1303 + 445) |
| random_100k | before | 31758 | 8142 | 5554176 | 39.3 | 0.378 ms | 0.396 ms | 4.148 ms | 2696 (1072 + 1587) | 3190 (1274 + 1871) |
| random_100k | after | 34242 | 8340 | 5971968 | 42.3 | 0.383 ms | 0.380 ms | 4.336 ms | 2827 (1074 + 1714) | 3255 (1183 + 2027) |

- trace: ydoc_compact removed 70646 rows in 263 ms, 11 MB of WAL.
- random_100k: ydoc_compact removed 972 rows in 136 ms, 688 kB of WAL.

### Replica id length: 'paper' vs a 36-char UUID

automerge-paper, local replay as replica R (commit every 5,000 ops), then pgbench edits as a second replica of the same kind (insert/delete 1 char, 500 each, warm-up run; WAL = records + full-page images), value(); sizes after VACUUM FULL, before and after ydoc_compact(doc).

| replica ids | rows | bytes per char | bytes per char after compact | insert 1 char | delete 1 char | value() | WAL per insert | WAL per delete | replay us per op |
|---|---|---|---|---|---|---|---|---|---|
| short | 83253 | 134.5 | 29.0 | 0.417 ms | 0.414 ms | 3.893 ms | 2885 (1171 + 1674) | 3113 (1381 + 1687) | 367 |
| uuid | 83253 | 134.5 | 29.0 | 0.419 ms | 0.451 ms | 3.880 ms | 3061 (1221 + 1799) | 5291 (2891 + 2333) | 367 |

### automerge-paper trace

| replay | calls | total s | us per call | WAL bytes per call | final text md5 ok |
|---|---|---|---|---|---|
| local insert/delete by position, commit per op | 259778 | 73.2 | 282 | 701 | t |
| ydoc_apply (validated) of batch, commit per call | 2598 | 2.2 | 859 | 3826 | t |
| ydoc_apply (validated) of ops, commit per call | 259778 | 90.3 | 348 | 788 | t |
| ydoc_merge of batch, commit per call | 2598 | 1.8 | 699 | 3833 | t |
| ydoc_merge of ops, commit per call | 259778 | 59.5 | 229 | 743 | t |

Document after the trace (document 1, local replay):

| chars | text bytes | rows | tombstone rows | relabels (all five replays) | items + indexes (per doc, approx) |
|---|---|---|---|---|---|
| 104852 | 104852 | 83253 | 77463 | 5242 (475246 rows rewritten) | 15 MB |
