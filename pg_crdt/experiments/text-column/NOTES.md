# yseq_: collaborative text in a jsonb column (shape A)

Status: experiment, 2026-11-04. Contract: [`research/text.md`](../../research/text.md). Files in this directory:

| File | What |
| --- | --- |
| `impl.sql` | The `crdt.yseq` domain and the `yseq_` functions. Loads after `pg_crdt--0.0.1.sql` into the `crdt` schema. PL/pgSQL and SQL only. |
| `test/run.sh`, `test/spec/*.sql` | The test suite (same harness as `test/run.sh`: a throwaway cluster on a Unix socket, `lib/tap.sql`). |
| `bench.sh` | Latency, storage, WAL, merge, and the automerge-paper trace. `--quick` skips the 1M document; `--full-trace` replays the whole trace as one UPDATE per patch. Needs the trace files from `experiments/text-ref/regen-traces.sh`. |
| `bench-chunks.sh` | The chunk size sweep (including one chunk, the flat representation). |
| `alt/integrate-v1-splice.sql` | The first integration engine (one flat array, spliced), kept for the comparison below. |

## What it does

A `crdt.yseq` value is a YjsMod sequence (research/text.md, "Order") stored in one jsonb column:

```sql
create table posts (
    id bigint primary key,
    body crdt.yseq not null default crdt.yseq_empty(),
    body_text text generated always as (crdt.yseq_value(body)) stored
);
create index on posts using gin (to_tsvector('english', crdt.yseq_value(body)));
```

| Function | Behaviour |
| --- | --- |
| `yseq_empty()` | The empty document. |
| `yseq_value(s) -> text` | The text. IMMUTABLE: usable in stored generated columns, expression indexes and full-text indexes (`test/spec/31_generated.sql`). |
| `yseq_length(s) -> int` | Length in code points. |
| `yseq_version(s) -> jsonb` | Version vector `{"replica": count}` (characters integrated per replica key; pending runs not counted). |
| `yseq_insert(s, pos, content, replica)` | Insert before position `pos` (0-based, code points). |
| `yseq_delete(s, pos, len, replica)` | Delete `len` code points at `pos`. |
| `yseq_set(s, content, replica, base => null)` | Make the text equal `content` with one delete and one insert (common prefix and suffix, in code points). See "set() and concurrent saves". |
| `yseq_merge(a, b)`, `yseq_merge_agg(s)` | Full-state merge. Commutative, associative and idempotent on the document; `merge(x, null) = x`. |
| `yseq_apply(s, ops, replica default crdt.current_replica_id())` | The untrusted write path, like `pn_apply_delta`. Inserts only with the caller's id or `<id>:<device>` (42501 otherwise, and for a null replica); deletes of anyone's characters; malformed ops 22023; idempotent. `ops` is one op or an array of ops. |
| `yseq_ops_since(s, vv default '{}') -> jsonb` | `{"i": [...], "d": [...]}`: the insert runs the holder of `vv` lacks, in a causal order, and the whole delete set. |
| `yseq_diff(old, new) -> jsonb` | The op that takes `old` to `new`: inserts beyond `old`'s version, and only the deletes `old` lacks. |
| `yseq_is_valid(jsonb) -> boolean` | The full validator (envelope, chunks, runs, version vector, origin sides, pending ops). For tests, or a table CHECK on states from outside. |

The op a local edit generated: the edit functions return only the new state; `crdt.yseq_diff(old, new)` returns exactly the op (tested for every edit in `02_model`). In one statement, with the row lock taken first:

```sql
with old as (select body from posts where id = $1 for update)
update posts p
set body = crdt.yseq_insert(old.body, $2, $3, $4)
from old
where p.id = $1
returning crdt.yseq_diff(old.body, p.body);
```

On Postgres 18, `returning crdt.yseq_diff(old.body, new.body)` does the same without the CTE. `yseq_ops_since(new, yseq_version(old))` also works, but its `d` is the whole delete set.

Decisions on points the contract left open (they match the JS reference in `experiments/text-ref` unless noted):

- A local insert at `pos` puts the new run directly after the visible character `pos-1`. Its originRight is the next item, tombstones included.
- An insert run is ready when both origins and the same replica's `seq-1` are present. Until then it waits in the state (`"p"`). A delete of ids not seen yet waits too (`"x"`), and applies when they arrive.
- Re-applied ids are skipped without comparing content. A run that overlaps applied ids integrates only its new end.
- Item replica ids are replica keys: `<id>` or `<id>:<device>` (the `pn_` owner rule). The JS reference rejects `:` in item replica ids. No fixture uses one, so the two do not disagree on any fixture.
- `yseq_ops_since` sends deleted characters as U+FFFD, one per code point (see "Tombstones keep no text"). Pending runs are not sent; `yseq_merge` carries them.

## State representation

```
{"t": "yseq", "v": 1,
 "r": ["alice", "bob"],     replica keys; runs refer to them by 1-based index
 "c": [12, 3],              characters integrated per replica (the version vector)
 "n": [40, 7],              per chunk: visible characters
 "s": ["...", "..."],       per chunk: the visible text
 "m": ["{...}", "{...}"],   per chunk: the runs, an int[] literal, 7 ints per run
 "p": [],                   pending insert runs (wire format)
 "x": []}                   pending deletes (wire format)
```

A run is `[rep, seq, len, olrep, olseq, orrep, orseq]`: the characters `(r[rep], seq .. seq+|len|-1)`, visible when `len > 0` and tombstones when `len < 0`, with the origins of the first character (`0, 0` for null). Character k > 0 of a run has originLeft `(rep, seq+k-1)` and the run's originRight, as in the wire format. Runs are in document order. A chunk holds at most 128 runs, and adjacent runs in a chunk are merged whenever the result is a valid run, so typing on at the end of one's own run extends it.

The domain checks the envelope (an object with exactly these keys, `t` and `v` fixed, the others arrays) with containment and `jsonb - text[]` as `crdt.pn` does, plus what needs no look inside the chunks (strict jsonpath): matching lengths of `r`/`c` and `n`/`s`/`m`, replica keys that are strings, counts that are integers from 1, chunk lengths that are numbers, pending entries that are arrays of 5 and 3. Measured as casts of the 100k trace state: about 13 µs per value, against about 1 µs for the envelope alone; most of it is the scan of `n` (157 entries). Checking that the 157 chunk lengths are integers too would cost about 25 µs more, so that check and the chunk contents are left to `yseq_merge`'s boundary check (`_yseq_check`, 22023, about 1.2 ms at 100k: a regular expression over the runs and the pending entries) and to `yseq_is_valid`, the full check. (Review finding 4: before this, `"p": [1]` passed the domain and `yseq_merge` turned it into a garbage state.)

### Choices, and what was measured

All numbers in this section are from the benchmark machine (Apple M4, Postgres 16.4, Postgres.app).

**Run metadata as int[] literals inside jsonb strings, not jsonb arrays.** Parsing 100,000 small integers: `'{...}'::int[]` 1.6 ms; jsonb array to int[] via `translate(j::text, '[]', '{}')::int[]` 6.4 ms; `jsonb_array_elements` 15 ms. Writing them: `int[]::text` 3.9 ms, `to_jsonb(int[])` 9.5 ms. Stored, the text form is half the size (71 kB against 135 kB: jsonb stores each number as a numeric). Inside the functions the runs are a flat `int[]` with stride 7 (one array, one parse), which a PL/pgSQL loop reads at about 60 ns per element.

**Tombstones keep no text.** Like Yjs's `ContentDeleted`: a tombstone is only a length. The visible text is stored once, per chunk, so `yseq_value` is a concatenation of the chunk strings (0.1 ms in memory on the 100k document; the SELECT including detoast is in the read table below). The cost: `yseq_ops_since` cannot send the original text of a deleted character to a replica that never saw it. It sends U+FFFD with the delete set, which hides it on arrival, and the receiver needs the character only as a position. On the trace, 77,463 of 182,315 inserted characters are deleted, so the saving is about 40% of the inserted text.

**Chunks.** A local edit finds its chunk from `"n"` (one small array), then parses, edits and rewrites only that chunk's runs and text. The flat alternative, one chunk, parses and rewrites every run on every edit. The sweep (`bench-chunks.sh`, below) chose 128 runs.

**The integration engine.** `yseq_apply` and `yseq_merge` share `crdt._yseq_integrate`. It loads every run into memory (one parse of all chunks), integrates runs with YjsMod, applies deletes, and rewrites only the chunks that changed.

- Version 1 (`alt/integrate-v1-splice.sql`) kept the runs in one flat array in document order and spliced it with array slices on every split and insert. Slicing and concatenating a 95,000-element int[] costs about 0.5 ms in PL/pgSQL, and an integration does up to three splices plus lookups by `array_position` over all runs. Merging two replicas of the 100k document that diverged by 1,000 edits each took 2,400 ms.
- Version 2 (current) appends: runs made by splits and inserts get new slots at the end of the arrays (element assignment, amortized O(1) on PL/pgSQL's expanded arrays), and document order is a doubly linked list. YjsMod compares positions only inside the stretch it scans, so the scan marks the slots it passes (a position comparison becomes "was this slot scanned"); for originRight it walks forward to see which of two slots comes first. Characters are found by key `rep << 32 | seq` with `width_bucket` over the original runs sorted by first key (a binary search in C, about 2 us), a short list of the runs integrated in this call, and a chain from each split run to its right half. The same merge takes 74 ms.
- Version 2 after the review (finding 2): an apply with thousands of deletes was quadratic (8,000 deletes of every other character of a 40,000-character paste: 12.7 s), because each delete walked its chunk from the head and rewrote the chunk text, and chunks grow with splits. Now integration and deletion only change the run list; every changed chunk's text is rebuilt once at the end, from the old chunk text (for runs that were there) and the text carried by new slots. Two more traps: a slice of a PL/pgSQL array (`a[i:j]`) copies the whole array when the variable is in expanded form, and `substr` walks from the start of the text, so the rebuild uses element access, and splits the old text into characters when it has more than 100 pieces. Lookups resume along a chain from the previous hit when keys ascend (deletes are sorted), and the sorted index is rebuilt once chain walks have cost more than about twice the number of slots (random order). The same 8,000 deletes take 0.11 s, 8,000 inserts after random characters 0.17 s (1.0 s before), and both grow linearly (spec `32_review`).

**Fewer copies of the state.** Every `jsonb_set` or `||` copies the whole value: about 45 us for the 450 kB state of the trace document. A local edit now makes three copies (the chunk's runs, the chunk's text, and `n`, `c` and `r` in one `||`); the first version made four or five.

**Rejected: smaller encodings.** Two re-encodings of the runs of the trace document, measured on the stored size:

| Encoding | JSON text | stored (pglz) | stored (lz4) |
| --- | --- | --- | --- |
| current | 455,251 | 165,830 | 218,641 |
| originLeft/originRight seq as a delta from the run's seq when same replica | 381,607 (-16%) | 152,481 (-8%) | 199,024 (-9%) |
| field-major chunks (all reps, then all seqs, ...) | 455,251 | 158,961 (-4%) | 200,330 (-8%) |

Both cost a decoding loop in PL/pgSQL on every chunk parse (about 40 us per chunk, and about 4 ms for a full parse of the trace document), for 4 to 9% less stored. Not taken.

### Chunk size

`bench-chunks.sh`: the 10k and 100k trace documents re-chunked (by `crdt._yseq_normalize`, which fills chunks to half the maximum) and measured in memory, ms per call. The last column replays the first 40,000 trace patches (to 24,700 characters) with each setting.

| max runs per chunk | 10k: insert | 10k: set | 100k: chunks | 100k: insert | 100k: delete | 100k: set | 100k: apply 1 run | replay 40k patches |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 16 | 0.072 | 0.191 | 1,549 | 0.704 | 0.853 | 1.964 | 11.6 | 3.1 s |
| 32 | 0.055 | 0.163 | 775 | 0.466 | 0.456 | 1.262 | 10.7 | 2.4 s |
| 64 | 0.051 | 0.147 | 388 | 0.265 | 0.406 | 1.059 | 10.1 | 2.3 s |
| **128** | 0.064 | 0.172 | 194 | 0.213 | 0.258 | 0.860 | 10.0 | 2.9 s |
| 256 | 0.084 | 0.215 | 97 | 0.224 | 0.233 | 0.879 | 10.0 | 4.4 s |
| 1,024 | 0.285 | 0.607 | 25 | 0.424 | 0.477 | 1.186 | 10.0 | 13.0 s |
| flat (one chunk) | 0.378 | 0.806 | 1 | 5.714 | 6.063 | 12.090 | 27.0 | 21.3 s |

Small chunks make the chunk table (`n`, parsed on every edit) long; large chunks make the parse and rewrite of the edited chunk long. 64 and 128 are within noise of each other at 10k; 128 is better at 100k. Flat is 27 times slower than 128 for a one-character insert into the 100k document. The state size barely depends on chunk size: at 100k, 449 kB of JSON with 1,024-run chunks, 453 kB with 128, 481 kB with 16.

## Results

`bench.sh`, 2026-11-04, Apple M4 (10 CPU, 24 GB), macOS, Postgres 16.4 (Postgres.app), throwaway cluster with `fsync=off` and `full_page_writes=on`. Documents: prefixes of the automerge-paper trace replayed with `yseq_insert`/`yseq_delete` (1k: first 1,400 patches; 10k: first 15,000; 100k: the whole trace), and a 1M document made by pasting ten copies of the trace's final text and making 20,000 random edits (its text is repetitive, so it compresses unusually well).

### Storage

| document | chars | runs | chunks | text bytes | plain text stored | state (JSON text) | stored (pglz) | stored (lz4) | pglz / text |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1k (trace) | 1,286 | 51 | 1 | 1,286 | 1,290 | 2,576 | 1,783 | 1,907 | 1.39 |
| 10k (trace) | 10,472 | 791 | 11 | 10,472 | 4,749 | 30,071 | 12,937 | 16,948 | 1.24 |
| 100k (trace) | 104,852 | 12,396 | 157 | 104,852 | 40,258 | 455,251 | 165,830 | 218,641 | 1.58 |
| 1M (paste + edits) | 1,070,562 | 39,602 | 431 | 1,070,562 | 458,818 | 2,138,967 | 845,205 | 1,042,413 | 0.79 |

The state is the text plus about 28 bytes of run metadata per run (as JSON text). A heavily edited document (the trace: 182,315 characters typed, 77,463 deleted, one replica) stores about 1.6 times the size of its text and 4 times the size of the plain text column compressed. A document written mostly in order is close to its text size.

### Function latency, in memory

ms per call, best of 3; the state already detoasted (no table).

| document | insert 1 | delete 1 | paste 1k | set (1 paragraph) | value | length | apply 1 run | ops_since (nothing new) | ops_since (all) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1k | 0.045 | 0.047 | 0.046 | 0.103 | 0.018 | 0.017 | 0.22 | 0.13 | 0.31 |
| 10k | 0.063 | 0.068 | 0.078 | 0.255 | 0.024 | 0.019 | 0.81 | 0.92 | 3.4 |
| 100k | 0.252 | 0.277 | 0.281 | 0.985 | 0.101 | 0.058 | 10.1 | 14.1 | 50.7 |
| 1M | 2.48 | 1.48 | 0.69 | 6.67 | 1.08 | 0.25 | 32.3 | 37.2 | 682 |

Edits by position touch one chunk, so they stay well under a millisecond up to 100k characters; most of the 100k cost is copying the 450 kB state three times. `yseq_apply` and `yseq_ops_since` parse every run (2.7 ms for the 100k document) and sort them into a lookup index (3.2 ms), so they cost O(document) per call. `ops_since` also builds the whole delete set every time (about 11 ms at 100k).

### Edits as table updates

One UPDATE per transaction from psql, µs per statement as the client sees it, and WAL bytes per statement (pg_current_wal_insert_lsn difference over 200 statements after a CHECKPOINT; 40 for 1M). `pglz` is the default column compression; `lz4` is `alter table ... alter column body set compression lz4`.

| document | edit | yseq, pglz: µs | WAL | yseq, lz4: µs | WAL | plain text: µs | WAL |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1k | insert 1 char | 274 | 4,312 | 160 | 5,307 | 37 | 827 |
| 1k | delete 1 char | 243 | 4,116 | 169 | 4,909 | | |
| 1k | paste 1k | 349 | 4,017 | 253 | 4,067 | | |
| 1k | set (1 paragraph) | 359 | 2,156 | 334 | 2,500 | | |
| 10k | insert 1 char | 844 | 18,292 | 328 | 23,056 | 175 | 5,958 |
| 10k | delete 1 char | 782 | 17,395 | 308 | 22,466 | | |
| 10k | paste 1k | 904 | 17,298 | 390 | 21,387 | | |
| 10k | set (1 paragraph) | 956 | 16,512 | 541 | 18,352 | | |
| 100k | insert 1 char | 11,747 | 186,734 | 2,506 | 245,538 | 1,462 | 46,771 |
| 100k | delete 1 char | 10,939 | 185,365 | 2,023 | 244,280 | | |
| 100k | paste 1k | 11,765 | 189,405 | 2,216 | 245,832 | | |
| 100k | set (1 paragraph) | 12,510 | 185,024 | 3,382 | 241,314 | | |
| 1M | insert 1 char | 52,004 | 951,313 | 9,510 | 1,167,946 | 17,008 | 516,471 |
| 1M | delete 1 char | 47,534 | 951,136 | 10,109 | 1,167,814 | | |
| 1M | paste 1k | 52,625 | 1,018,459 | 12,004 | 1,235,134 | | |
| 1M | set (1 paragraph) | 61,577 | 1,017,015 | 20,157 | 1,233,588 | | |

Every edit rewrites and WAL-logs the whole stored value: from about 2 kB of state the value is TOASTed, and the WAL per edit is the compressed state size plus overhead. With pglz, compression is most of the time (10 of the 11.7 ms at 100k); lz4 is 4 to 5 times faster and writes about 30% more WAL. The function itself is a small part (0.25 ms of 2.5 ms at 100k with lz4).

### Reading the text

SELECT of `yseq_value(body)` from the table, ms, detoast included (best of 3 runs of 20):

| document | yseq_value (pglz) | yseq_value (lz4) | plain text column |
| --- | --- | --- | --- |
| 1k | 0.045 | 0.039 | 0.007 |
| 10k | 0.091 | 0.064 | 0.022 |
| 100k | 1.31 | 0.37 | 0.16 |
| 1M | 7.05 | 2.42 | 2.18 |

The cost is detoasting the whole state (text and runs). Searches should use a stored generated column or an expression index, which read the text once per write.

### Merge

Two copies of each document, each with N random concurrent edits (70% two-character inserts, 30% one-character deletes) by its own replica, then `yseq_merge(a, b)` in memory (best of 3). In every case `merge(a, b)` and `merge(b, a)` have the same canonical form.

| document | edits each | runs only in b | merge ms |
| --- | --- | --- | --- |
| 1k | 100 | 73 | 3.2 |
| 1k | 1,000 | 672 | 26.6 |
| 10k | 100 | 73 | 5.7 |
| 10k | 1,000 | 708 | 30.8 |
| 100k | 100 | 62 | 38.9 |
| 100k | 1,000 | 698 | 73.5 |
| 1M | 100 | 69 | 87.3 |

With engine version 1 the 100k / 1,000 merge took 2,400 ms (and 280 ms for 100 edits). After the review fixes (`bench.sh --quick`, same machine) the merges cost more: 53 ms (100 edits) and 97 ms (1,000 edits) at 100k, 30 ms at 10k / 1,000. The boundary check on both arguments is 2.4 ms of that, and rebuilding each changed chunk's text in one pass is slower than the old in-place splices when few pieces change. Edit latency, apply, reads and the trace replays did not change beyond noise.

### The automerge-paper trace

259,778 single-character patches, one replica, final text 104,852 characters. Every replay below ends with the trace's `endContent`.

| replay | time | per patch | WAL per statement |
| --- | --- | --- | --- |
| In memory: one `yseq_insert`/`yseq_delete` call per patch in a PL/pgSQL loop, no table | 31.8 s | 123 µs | |
| Table row, one UPDATE per patch, first 10,000 patches (lz4) | 1.7 s | 174 µs | 7,579 |
| Table row, one UPDATE per patch, first 10,000 patches (pglz) | 3.1 s | 309 µs | 6,141 |
| Table row, one UPDATE per patch, last 2,000 patches (lz4) | 4.8 s | 2,399 µs | 240,513 |
| Table row, one UPDATE per patch, last 2,000 patches (pglz) | 22.6 s | 11,286 µs | 182,372 |
| Table row, one UPDATE per patch, the whole trace (lz4; `bench.sh --full-trace`) | 489 s | 1,881 µs mean (189 µs in the first 10,000 patches, 2,700 to 5,000 µs in the last 40,000) | 115 kB mean; 30 GB in total |
| Batched: 2,598 `yseq_apply` calls of 100 patches each (the reference's `batch100` ops), table row, lz4 | 14.2 s | 5.5 ms per call (55 µs per patch) | 130,511 |
| Batched, pglz | 27.0 s | 10.4 ms per call (104 µs per patch) | 103,291 |

The JS reference replays the trace in about 4.7 s (experiments/text-ref). The whole-trace table replay checks the final length (104,852) only; the last-2,000 and batch100 replays compare the final text with `endContent`. Per-slice times of the whole-trace replay are noisy (other benchmarks shared the machine, and checkpoints add full-page images), so the mean is the useful number. With pglz the same replay would take roughly 4 to 5 times as long, judging from the first and last slices measured above.

## Size ceiling

Each edit costs a rewrite of the whole stored state, so the limit is set by write rate times state size, not by a hard maximum.

- **Keystroke-rate editing through the column** (an editor that sends every keystroke as an UPDATE): practical up to about 10,000 to 20,000 characters, a state of about 30 to 60 kB (13 to 25 kB stored). There an edit costs 0.3 to 1 ms and 17 to 23 kB of WAL. At 100,000 characters (450 kB state) each keystroke costs 2.5 ms (lz4) or 12 ms (pglz) and about 190 to 245 kB of WAL: ten keystrokes a second on one document write about 2 MB/s of WAL.
- **Save-rate editing** (`yseq_set` on form save, every few seconds or minutes): usable up to about 100,000 characters with lz4 (3.4 ms and 240 kB of WAL per save). At 1M characters a save costs 20 ms (lz4) to 60 ms (pglz) and 1.2 MB of WAL.
- Use `compression lz4` on the column: 4 to 5 times faster edits than the default pglz above 10k characters, for about 30% more WAL and storage.
- Batching helps: one `yseq_apply` of 100 patches costs about two single-patch UPDATEs.

Above those sizes, the table-backed shape (experiments/text-table), whose edits write O(edit) rows, is the better fit.

## set() and concurrent saves

research/text.md said that concurrent saves of different paragraphs both survive with a prefix/suffix `set`. That is true only if the diff is against the text the editor started from. Diffed against the current text, the result is exactly the editor's text: last-writer-wins for the whole text, which reverts every edit saved since the editor loaded it (pinned in `20_concurrency` and `12_sync`).

`yseq_set(state, content, replica, base => loaded)` is the three-way version. `loaded` is the column value the editor read with the text (an ORM already has it). The writer's own characters that the state has and the base has not (an earlier save or autosave from the same base) are first added to the base, with the deletes of those characters, so a second save from the same base replaces the first instead of inserting its text again (review finding 3: base "hello", saves "hello world" then "hello world!" gave "hello world world!"). Deletes by others since the base are not added, or the diff would undo them. The diff is then computed on that base, numbered after the replica's last character in either state, and integrated into the current state with `_yseq_integrate`. Two cases stay wrong and are documented misuse: a base that is not a version of the same document (the op lands on whatever ids happen to match), and a writer that deleted text in an earlier save and types it back in a later one from the same base (deletes carry no author, so its own earlier delete is not in the base and the text stays deleted). Tested: two editors on different paragraphs (in one session, and from two dblink sessions with the second save waiting on the row lock), a delete just before another editor's append, two inserts at one spot (not interleaved).

Why the base is the whole state and not a version vector token, as in shape B (`ydoc_base`): the text at a version needs (1) which characters were visible then, so each delete needs a stamp saying when it happened, and (2) the text of characters deleted since, which this shape does not store. Stamps would also stop adjacent tombstones from merging into one run unless their stamps are equal. The trace has 77,463 single-character delete patches that now merge into about 6,900 tombstone runs; with a stamp per delete they would be up to 77,463 runs, about 6 times the current 12,396 runs in total. A bounded log of recent deletes with their text would allow a small token for recent bases and is listed below as a follow-up. The cost of the current design is the payload: the client sends the state back (30 kB raw for the 10k document, 450 kB for 100k).

## Tests

`experiments/text-column/test/run.sh`: 11 files, 177 assertions, all passing on Postgres 16.4. The suite also passes with chunks of 4 runs and the bulk-delete path forced (`--impl` with an edited copy), which exercises chunk splits on almost every edit.

| File | Goal |
| --- | --- |
| `01_basics` | empty, value, length, version, insert, delete, set (minimal diff), set with base, null handling, errors (22004, 22023), the domain envelope |
| `02_model` | 40 random sessions of 150 edits from 3 replicas against a plain text model; every 10th state passes `yseq_is_valid`; `yseq_diff` of every checked edit reproduces it; 3,000 editor keystrokes ending in many chunks |
| `03_unicode` | code point positions, non-BMP, combining marks, ZWJ sequences; set() across shared UTF-8 lead and trail bytes; unicode replica ids; U+FFFD for deleted text in ops |
| `10_merge_laws` | 300 random triples with shared history: commutative, associative, idempotent, empty and null identities, valid results, `yseq_merge_agg` = fold, version = per-replica max |
| `11_convergence` | 40 trials of 2 to 5 replicas editing and syncing (merge and partial apply); the whole log shuffled with duplicates one op per call, all in one call, and every replica after the log, all equal; nothing pending; valid |
| `12_sync` | non-interleaving of concurrent typing at one spot (both merge orders, C collation), ops_since with version vectors, delete set, yseq_diff, causal order of ops_since, three-way set |
| `20_concurrency` | two dblink sessions: three-way set with a lock wait, stale set without base (pinned), 600 concurrent `yseq_insert`, `yseq_set` and `yseq_merge` transactions each lose nothing, negative control |
| `30_apply` | owner rule (id, device key, exact match), null and malformed caller ids, deletes of others, arrays of ops, idempotence, held inserts and deletes, 12 malformed ops (22023), default identity, labels and grants |
| `31_generated` | stored generated column, GIN full-text index and expression index used by the planner, `like`, REINDEX and updates under `search_path = pg_catalog, pg_temp` |
| `32_review` | regressions from the adversarial review: linear cost of 8,000 deletes and 8,000 random inserts in one apply, a second save from the same base, malformed states (23514, 22023), seq and len written as 1.0, seq 2147483647, pending entries that are not pending |
| `40_differential` | the JS reference fixtures except `malicious-*` (forged origins; they wait for the op format with a version vector) (`experiments/text-ref/fixtures/fixtures.sql`): shuffled ops with duplicates one per call, causal ops, all in one call, two halves merged, ops_since replayed; all equal to the reference text |

## Limitations

- Every edit rewrites the whole value (TOAST): WAL and time grow with the document (see "Size ceiling").
- `yseq_apply`, `yseq_merge` and `yseq_ops_since` parse every run on each call (about 5 to 10 ms at 100k characters, before TOAST).
- No tombstone garbage collection: deleted characters stay as runs forever (without their text).
- Ids are trusted to be unique: a replica that reuses ids with different text (two writers sharing one replica key) loses the second text silently, as in the reference. Use one replica key per writer session (`<user>:<device>`).
- `yseq_apply` ignores an op's `"v"` key for now (the new fixtures carry one); forged origins (review finding 1) are not handled yet.
- Many concurrent inserts at one spot still cost O(k) each in the YjsMod scan, as in any YjsMod implementation.
- `yseq_is_valid` rejects pending entries that are not pending (a pending delete of a present id, a pending run that is wholly present or ready), which only a hand-made state has. A writer that uses one replica key both locally and through `yseq_apply` can make such a state (see below).
- Pending runs and deletes from `yseq_apply` are not bounded: a client can park junk ops in the state (ops with a seq gap or unknown origins). An app should cap the state size or the pending count.
- Local edits do not retry pending ops (only `yseq_apply` and `yseq_merge` do), and a replica that writes both locally and through `yseq_apply` with the same key can collide with its own pending ids.
- `yseq_ops_since` sends the whole delete set every time.
- Positions are code points; JS clients must convert from UTF-16 indexes. Grapheme clusters (combining marks, ZWJ sequences) can be split by a position edit or by set()'s diff.
- Postgres 18 virtual generated columns do not accept user-defined functions; use stored ones.
- Tested on Postgres 16.4 only (Postgres.app); not yet through pg_tle or Docker.

## Follow-ups

- A bounded log of recent deletes (with their text) so that `yseq_set` can take a small version token as base, falling back to an error for bases older than the log.
- A delta form of `yseq_merge` for the common case (one replica's new runs) that skips the full parse, and an incremental delete set (or a delete-set version) for `yseq_ops_since`.
- Tombstone GC behind a horizon all replicas have passed.
- Rich text and marks, cursors, undo (non-goals tonight).
- Promotion into the extension file: reference entries, error table rows, `02_security`-style grant checks for the new functions.
