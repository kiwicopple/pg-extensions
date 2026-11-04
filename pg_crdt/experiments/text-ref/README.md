# text-ref: JS reference for the pg_crdt text CRDT

Reference YjsMod sequence CRDT, validation rules for the untrusted write path, differential-test fixtures, and an editing-trace converter. Contract: `../../research/text.md` plus the rules below. Plain ESM, Node 23, no dependencies.

## Files

| File | What |
|---|---|
| `ref.mjs` | `Doc` (reference CRDT), `OpRejected`, `mergeOps`. One item per character in memory, runs only on the wire. |
| `sim.mjs` | Seeded PRNG (mulberry32) and the random honest multi-replica simulation. |
| `byz.mjs` | Byzantine-writer simulation: honest replicas plus ops that lie about origins, seqs, `v` and delete targets. |
| `test.mjs` | Self-tests. `node test.mjs` exits 0/1 (about 2 s). |
| `gen-fixtures.mjs` | Deterministic fixture generator (`node gen-fixtures.mjs`). |
| `fixtures-to-sql.mjs` | Emits `fixtures/fixtures.sql` from `fixtures/*.json`. |
| `fixtures/*.json` | 71 fixtures: `fuzz-001..050`, `unicode-replica-001..003`, `case-replica-001`, `non-interleave-001`, `empty-001`, `delete-all-001`, `malicious-001..012`, `malicious-repro-001`, `malicious-rules-001`. |
| `fixtures/fixtures.sql` | `\i`-able: drops and recreates `text_fixtures(name, ops jsonb, ops_causal jsonb, rejected jsonb, rejected_causal jsonb, expected text)`. Needs UTF8 client encoding. Values are dollar-quoted with a tag chosen not to occur in the data. |
| `convert-trace.mjs` | Replays an editing trace through `ref.mjs` and writes op files. |
| `regen-traces.sh` | Downloads the trace if missing (into `traces/raw/`) and runs the converter. |
| `traces/` | Generated and gitignored (`ops.jsonl` is 19 MB). `raw/` holds the untrusted download (sha256 `42c0ff17...a1546`). |

## Regenerate

```
node test.mjs
node gen-fixtures.mjs && node fixtures-to-sql.mjs     # deterministic; same bytes every run
./regen-traces.sh [--verify-remote]
```

`gen-fixtures.mjs` overwrites files in place and does not delete stale ones.

## Op format (as in the brief, plus `v`)

```json
{"v": {"alice": 5}, "i": [["bob", 1, ["alice", 5], null, "!"]], "d": [["alice", 2, 3]]}
```

`v` is the sender's version vector before the op: `{replica: highest seq it has integrated}`, only replicas with seq > 0. `i` and `d` are always present (possibly empty); consumers should still tolerate a missing key. Within an op, runs are processed in array order, and `v` is advanced run by run (see V2).

**Origin contract for senders.** `originLeft` and `originRight` must be adjacent in the sender's full sequence, tombstones included. A sender that picks `originRight` as the next visible character, with tombstones in between, is rejected by V5. `ref.mjs` inserts right after the visible character at `pos-1` and takes the next item (tombstone or not) as `originRight`.

## API (`ref.mjs`)

- `new Doc()`.
- `doc.localInsert(replica, pos, text)` and `doc.localDelete(replica, pos, len)` return `{v, i, d}`. Positions are code points.
- `doc.apply(op)` is the **trusted path** (server-to-server merge, local replay). It takes an object or a JSON string, ignores `v`, is idempotent, and validates the shape (throws `TypeError`). Inserts are buffered until their origins and the same replica's previous seq are present. Deletes are stored as tombstone intervals at once, so a delete of an unseen id takes effect when the insert arrives. **It is not safe against a byzantine writer** (see the repro below).
- `doc.apply(op, {validate: true})` is the **untrusted path**. It applies rules V1..V7 and returns `'accepted'` or `'pending'`. It throws `OpRejected` (`code` `'22023'`, `reason` starts with the rule id) if the op is rejected during this call. An op that waits (V7) and is decided by a later call is reported through `doc.onDecision(op, 'accepted'|'rejected', reason)`. A rejected op leaves no trace.
- `doc.text()`, `doc.length()`, `doc.versionVector()` (n = count of integrated chars, which equals the highest seq since there are no gaps), `doc.pendingCount()` (buffered runs plus waiting ops).
- `doc.opsSince(vv)` returns one catch-up op `{i, d}`: `i` is exactly the integrated inserts with `seq > vv[replica]`, as maximal runs in integration (causal) order; `d` is all deletes the doc knows. It has **no `v`** and cannot pass the validation rules (it merges runs created under different claims, so V5 would reject concurrent items that the original senders legitimately did not know). It is for the trusted path only. A server that forwards ops over an untrusted link must forward the original writer ops, not catch-up ops.
- `mergeOps(ops)` concatenates ops of one replica that were generated back to back (no foreign op applied in between), coalescing adjacent runs and deletes. The merged op's `v` is the first op's `v`.

## Validation rules (untrusted path)

An op is accepted or rejected as a unit (atomically). Let `v` be the claimed vector, and `vadv` be `v` advanced run by run: before the first run `vadv = v`; after run `[r, s, ol, or, text]`, `vadv[r] = s + len(text) - 1`.

Static rules: they depend on the op alone, and fire on arrival, before any waiting.
- **V0 (shape).** `v` is present, replica ids are valid (non-empty, no `:`), every `v[r] >= 1`. The usual shape rules for `i` and `d`.
- **V1 (origins covered).** For every run, both origins `(q, t)` satisfy `t <= vadv[q]` (using `vadv` before that run).
- **V2 (own seq).** For every run, `vadv[r] == s - 1` (using `vadv` before that run). This pins the first char of a replica's run to the claimed history, and lets a later run of the same op chain after an earlier one.
- **V6 (deletes covered).** Every delete `[r, s, len]` has `s + len - 1 <= vadv_final[r]`, where `vadv_final` is `vadv` after the last run. An untrusted writer cannot delete ids it does not claim to have seen, so pre-deleting someone's future text is impossible. Honest ops therefore never need held deletes.

Dynamic rules: they depend on the doc, and are evaluated once the doc covers `v`.
- **V7 (wait).** The op stays pending until the local doc covers `v`: `count[r] >= v[r]` for every `r` in `v`. Origins are then guaranteed to be present.
- **V3 (closed).** `v` is the version vector of a causally closed state: for every `r` in `v`, every direct dependency (origin) of the items `(r, 1..v[r])` is covered by `v`. Implementation: each item stores the cumulative per-replica maximum of its replica's origin seqs (`dp`), so the check is `dp(r, v[r]) <= v` for each `r`.
- **V4 (order).** `originLeft` is strictly before `originRight` in document order.
- **V5 (nothing between).** No item strictly between `originLeft` and `originRight` in document order is covered by `vadv` (`seq <= vadv[its replica]`). Items not covered (concurrent with the op) may lie between them.

A run that is already fully integrated (same ids) is skipped as a duplicate; its deletes are re-applied idempotently.

### Original repro

alice writes `abc`; bob honestly sends `["bob",1,null,null,"Y"]` with `v: {}`; mal sends `v: {alice: 3}`, `["mal",1,null,["alice",2],"X"]`. On the trusted path the two delivery orders give two different texts. On the untrusted path, `X` is rejected by V5 (alice:1 is covered and lies between null and alice:2) in every order, and every replica ends with `abcY`. Fixture `malicious-repro-001`; test "original repro".

### Why this converges

Think of every accepted insert `x` as claiming to be created by a replica whose state was `K(x)`: the items covered by `x.v`. V2 puts all of the replica's own earlier items in `K(x)`, V3 closes `K(x)` under origins, and V7 means every replica deciding `x` holds all of `K(x)`. `x` is not in its own `K(x)` (`v[r] = s-1`), so the claims form a partial order, and any linear extension of it is a legal honest execution: each item created by a replica in a causally closed state. In such an execution the YjsMod integrate rule gives a delivery-order-independent result (the property the reference-crdts fuzzer checks), provided every item's origins were adjacent in its creator's sequence. V1 and V4 say the origins exist in `K(x)` and are in order; V5 says nothing in `K(x)` lies between them, and the order of the items of `K(x)` is the same on every replica (induction on the order of acceptance). Items outside `K(x)` may lie between the origins, exactly as concurrent edits do for an honest sender.

Decisions are also deterministic: static rules read only the op, and dynamic rules read only `K(x)` (ids, origins, relative order), which is identical on every replica that has decided the ops it depends on. A rejected op creates no ids, so its dependents (ops whose `v` covers it, or the same writer's later ops, via V2) wait forever on every replica, identically.

V6 is not needed for convergence (deletes commute); it closes the pre-delete hole. V1, V2, V3, V4, V5 are each needed: the ablation test turns each off in turn and the byzantine fuzz finds diverging replicas.

### Not covered: equivocation

Two different ops that use the same `(replica, seq)` with different content break convergence (first arrival wins; test "KNOWN HOLE"). Nothing in `v` can prevent it: it needs one writer per replica id, enforced by whoever sequences writes (in one database, the owner rule plus the primary key on `(replica, seq)`), or content-addressed ids. Server-to-server merge must therefore be trusted, or must reject an id seen with two different contents.

### Cost

- V0, V1, V2, V6: O(|v| + runs + deletes).
- V7: O(|v|) per attempt; an op waiting on a missing dependency is retried when something integrates. A claim of unseen items makes the op wait forever, so the pending queue needs a quota per writer.
- V3: O(|v|) probes if each item (or each run) stores the cumulative dependency vector of its replica's prefix. `ref.mjs` stores one `Map` per item, shared between neighbours when unchanged. A Postgres implementation can store it per run.
- V4 and V5: a range scan over the doc between `originLeft` and `originRight`. For honest typing that range is empty (adjacent origins); with concurrent edits it holds the concurrent items, which the integrate scan walks anyway. In a table-backed implementation this is a scan over the sibling rows between the two origins in sequence order. The worst case is a byzantine op whose origins are far apart: it costs O(range) once and is then rejected (or, if every item in the range is uncovered, it is legal).
- The rules need the origin positions (`indexOf` in `ref.mjs`), which the integrate rule needs anyway.

### Evidence (all runs seeded and reproducible)

- Honest fuzz through the untrusted path (`test.mjs`, 300 seeds, 2-6 replicas, random order, duplicates, non-BMP text): 25,412 honest ops, 0 rejected, all replicas converge, 0 stuck.
- Byzantine fuzz (`byz.mjs`): honest replicas plus untrusted ops with reversed or equal origins, skipped items, `v` lowered to hide items, claims that are not closed, claims above what exists, forged and reused seqs, chained runs, unseen delete targets. Every op gets the same decision (accepted, rejected, never applicable) on 3-5 honest replicas and 2 fresh replicas, all fed in different random orders with duplicates, and all texts and version vectors agree. `test.mjs` runs 600 seeds (28,809 ops accepted, 9,685 rejected, 3,206 never applicable; 3,647 untrusted ops accepted). A separate run of 3,000 seeds with default settings (143,807 accepted, 48,660 rejected, 18,327 untrusted ops accepted) and 2,000 seeds over four other configurations (5 replicas and 150 ops, 70% untrusted ops, 70% continued writers, honest replicas that never see untrusted ops) also found 0 divergences.
- Ablation (one rule off, same fuzz): over 300 seeds V1, V2 and V5 diverge in 37, 24 and 59 seeds; V3 and V4 are rarer (8 and 4 diverging seeds out of 1,500). V6 off never diverges (it is a security rule, not a convergence rule). `test.mjs` asserts that V1..V5 each diverge within 1,500 seeds.

## Fixture format

```json
{ "ops": [...], "ops_causal": [...], "rejected": [3, 17], "rejected_causal": [5], "expected": "<final text>" }
```

Every op carries `v`. Replay `ops` and `ops_causal` through the untrusted path (rules above) unless you test a trusted-path implementation, in which case `rejected` is empty for every non-`malicious-*` fixture and `v` can be ignored.

- `ops`: every generated op, arbitrary delivery order (fully shuffled for odd numbers, locally swapped for even), with about 20% duplicates, at most 200 entries. Deletes can precede the inserts they target, and inserts can precede their origins. Needs an implementation that buffers (V7).
- `ops_causal`: the same ops without duplicates, in a random order in which every op comes after the creators of all ids it claims in `v`. An implementation without buffering can apply it in order; the generator asserts that the validated reference never waits on it.
- `rejected`: positions in `ops` (duplicates included) that must be rejected. `rejected_causal`: the same for `ops_causal`. The final text excludes the rejected ops. Empty for honest fixtures.
- Statically rejected ops (V0, V1, V2, V6) never wait: they are rejected on arrival even if their `v` claims ids that do not exist. In `malicious-*` fixtures no op is left pending forever.
- `malicious-001..012`: honest replicas that never see the untrusted ops, plus untrusted ops from fresh replica ids that lie as in the byzantine fuzz (reasons across the fixtures: V1 19, V2 17, V3 43, V4 18, V5 124, V6 119 rejections, duplicates included). `malicious-repro-001` is the reviewer's repro. `malicious-rules-001` has one op per rule, an atomicity case (first run fine, second run V5: nothing applied), and two accepted look-alikes.
- `unicode-replica-*` use replica ids `U+FFFD` and `U+1F600` (code point order is the opposite of UTF-16 order) plus `B`, `a`. `case-replica-001` uses `B, a, b, A` (C collation order, not locale order). These only pass with byte/code point comparison.
- The text pool includes non-BMP chars, combining marks, ZWJ, newline, backslash, quote and `$`.

## Trace (automerge-paper)

Source: josephg/editing-traces `sequential_traces/automerge-paper.json.gz`. Replayed as one replica `paper`, one op per patch (a patch is `[pos, del, ins]`; the trace's patches are pure inserts or pure deletes). Outputs in `traces/`:

- `automerge-paper.ops.jsonl`: 259,778 ops, one per line, each with `v` (`{"paper": n}`).
- `automerge-paper.batch100.jsonl`: 2,598 ops, 100 patches merged each (typed runs coalesced into one run, `v` of the first patch).
- `automerge-paper.patches.jsonl`: `[pos, del, ins]` per line. Positions are code points. The trace has no non-BMP characters, so code points and UTF-16 units coincide here, and replay under code point semantics reproduces `endContent`.

Final text: 104,852 code points. JS timings on this machine: local replay about 5 s; `apply` (trusted) op by op 6 s and batch100 4 s; `apply` with validation op by op 10 s and batch100 3.7 s (the validated rules add the `dp` bookkeeping and an empty range scan per insert). All validated applies accept every op.

If `startContent` were non-empty it is emitted as a first `[0,0,startContent]` patch (it is empty for this trace).

## Integrate rule vs upstream

`Doc._integrate` was checked against `integrateYjsMod` in josephg/reference-crdts `crdts.ts` (fetched 2026-11-04). The brief's pseudocode matches upstream: same scan loop, same `scanning` handling, same `oleft < left / == / >` and `oright < / == / >` punnet square, same tie-break `newItem.replica < other.replica` then break.

Differences from upstream that do not change the order:
- Upstream seqs start at 0. The brief starts them at 1.
- Upstream compares agent strings with JS `<` (UTF-16 code unit order). We use UTF-8 byte order (= code point order = Postgres `collate "C"`). These differ only for non-BMP vs U+E000..U+FFFF replica ids.
- Upstream integrates single items. Here runs are expanded to per-char items: char k>0 has `originLeft = (replica, seq+k-1)` and the run's `originRight`.

## Decisions on points the brief left open

- Trusted-path readiness has three conditions: both origins are present, and the same replica's `seq-1` is present (no gaps, as upstream requires). Final text does not depend on this.
- A run that overlaps already-integrated ids is skipped on the trusted path. On the untrusted path a partial overlap is rejected (only equivocation produces one; a full duplicate is a no-op).
- `opsSince` always sends all deletes and no `v`.
- Idempotency is by id: a re-applied insert id is skipped without comparing content (see equivocation).
- Tombstones are never garbage collected.
- `Doc` accepts `{rules: {...}}` to switch individual rules off. This is a test hook for the ablation experiment, not a feature.
