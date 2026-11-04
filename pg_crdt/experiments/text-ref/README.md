# text-ref: JS reference for the pg_crdt text CRDT

Reference YjsMod sequence CRDT, differential-test fixtures, and an editing-trace converter. Contract: `../../research/text.md`. Plain ESM, Node 23, no dependencies.

## Files

| File | What |
|---|---|
| `ref.mjs` | `Doc` (reference CRDT) and `mergeOps`. One item per character in memory, runs only on the wire. |
| `sim.mjs` | Seeded PRNG (mulberry32) and the random multi-replica editing simulation shared by tests and the generator. |
| `test.mjs` | Self-tests. `node test.mjs` exits 0/1. |
| `gen-fixtures.mjs` | Deterministic fixture generator (`node gen-fixtures.mjs`). |
| `fixtures-to-sql.mjs` | Emits `fixtures/fixtures.sql` from `fixtures/*.json`. |
| `fixtures/*.json` | 57 fixtures: `fuzz-001..050`, `unicode-replica-001..003`, `case-replica-001`, `non-interleave-001`, `empty-001`, `delete-all-001`. |
| `fixtures/fixtures.sql` | `\i`-able: drops and recreates `text_fixtures(name, ops jsonb, ops_causal jsonb, expected text)`. Needs UTF8 client encoding. Values are dollar-quoted with a tag chosen not to occur in the data. |
| `convert-trace.mjs` | Replays an editing trace through `ref.mjs` and writes op files. |
| `regen-traces.sh` | Downloads the trace if missing (into `traces/raw/`) and runs the converter. |
| `traces/` | Generated and gitignored (`ops.jsonl` is 14 MB). `raw/` holds the untrusted download (sha256 `42c0ff17...a1546`). |

## Regenerate

```
node test.mjs
node gen-fixtures.mjs && node fixtures-to-sql.mjs     # deterministic; same bytes every run
./regen-traces.sh [--verify-remote]
```

`gen-fixtures.mjs` overwrites files in place and does not delete stale ones.

## API (`ref.mjs`)

- `new Doc()`.
- `doc.localInsert(replica, pos, text)` and `doc.localDelete(replica, pos, len)` return an op `{i: [...], d: [...]}`. Both keys are always present (possibly empty). Positions are code points. A local insert goes directly after the visible char at `pos-1`, so its `originRight` is the next item in the sequence, tombstones included.
- `doc.apply(op)` takes an object or a JSON string. It is idempotent and validates before changing state (throws `TypeError`). Inserts are buffered until their dependencies are present. Deletes are stored as tombstone intervals at once, so a delete of an unseen id takes effect when the insert arrives. `doc.pendingCount()` is the number of buffered runs.
- `doc.text()`, `doc.length()`, `doc.versionVector()` (`{replica: n}`; n = count of integrated chars, which equals the highest seq since there are no gaps).
- `doc.opsSince(vv)` returns one op: `i` is exactly the integrated inserts with `seq > vv[replica]`, as maximal runs, ordered by integration order (so causal; a fresh doc applies it without buffering). `d` is all deletes the doc knows (the doc cannot tell which ones the client lacks; deletes are idempotent). Buffered inserts are excluded.
- `mergeOps(ops)` concatenates ops and coalesces adjacent runs/deletes.

## Fixture format

```json
{ "ops": [ <op>, ... ], "ops_causal": [ <op>, ... ], "expected": "<final text>" }
```

- `ops`: every generated op, arbitrary delivery order (fully shuffled for odd fuzz numbers, locally swapped for even), with about 20% duplicates, at most 200 entries. Deletes can precede the inserts they target, and inserts can precede their origins. Needs an implementation that buffers.
- `ops_causal`: the same ops, no duplicates, in a random causal order: every op comes after the ops that created its origins, the same replica's previous seq, and its delete targets. An implementation without buffering can apply it in order. The generator asserts that the reference never buffers on it.
- Each op is single-run (one insert run or one delete set) except in the trace files.
- `unicode-replica-*` use replica ids `U+FFFD` and `U+1F600` (code point order is the opposite of UTF-16 order) plus `B`, `a`. `case-replica-001` uses `B, a, b, A` (C collation order, not locale order). These only pass with byte/code point comparison.
- The text pool includes non-BMP chars, combining marks, ZWJ, newline, backslash, quote and `$`.

## Trace (automerge-paper)

Source: josephg/editing-traces `sequential_traces/automerge-paper.json.gz`. Replayed as one replica `paper`, one op per patch (a patch is `[pos, del, ins]`; the trace's patches are pure inserts or pure deletes). Outputs in `traces/`:

- `automerge-paper.ops.jsonl`: 259778 ops, one per line.
- `automerge-paper.batch100.jsonl`: 2598 ops, 100 patches merged each (typed runs coalesced into one run).
- `automerge-paper.patches.jsonl`: `[pos, del, ins]` per line. Positions are code points. The trace has no non-BMP characters, so code points and UTF-16 units coincide here, and replay under code point semantics reproduces `endContent`.

If `startContent` were non-empty it is emitted as a first `[0,0,startContent]` patch (it is empty for this trace).

## Integrate rule vs upstream

`Doc._integrate` was checked against `integrateYjsMod` in josephg/reference-crdts `crdts.ts` (fetched 2026-11-04). The brief's pseudocode matches upstream: same scan loop, same `scanning` handling, same `oleft < left / == / >` and `oright < / == / >` punnet square, same tie-break `newItem.replica < other.replica` then break.

Differences from upstream that do not change the order:
- Upstream seqs start at 0. The brief starts them at 1.
- Upstream compares agent strings with JS `<` (UTF-16 code unit order). We use UTF-8 byte order (= code point order = Postgres `collate "C"`). These differ only for non-BMP vs U+E000..U+FFFF replica ids.
- Upstream integrates single items. Here runs are expanded to per-char items: char k>0 has `originLeft = (replica, seq+k-1)` and the run's `originRight`.

## Decisions on points the brief left open

- Causal readiness has three conditions: both origins are present, and the same replica's `seq-1` is present (no gaps, as upstream requires). The brief only mentions origins. Final text does not depend on this, but `ops_causal` satisfies both readings.
- A run that overlaps already-integrated ids (for example a partial re-send) skips the integrated prefix.
- `opsSince` always sends all deletes (see API).
- Idempotency is by id: a re-applied insert id is skipped without comparing content.
- Tombstones are never garbage collected.
