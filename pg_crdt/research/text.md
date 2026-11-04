# pg_crdt: text documents (session 5 design brief)

> Status: working brief, 2026-11-04 (overnight session). Written by the orchestrator for the implementing agents. Results are appended at the end and in `journal.md`.

## Goal

Store collaboratively edited text (the canonical case: a blog post body edited by several people) in Postgres, PL/pgSQL and SQL only. Two storage shapes, the same algorithm, so the comparison measures storage and not semantics:

- **Shape A: column.** A `jsonb` domain you put on your own table: `create table posts (id ..., body crdt.<x> default crdt.<x>_empty())`. Pure functions, like `pn_`. Easy to adopt. Every edit rewrites the whole value (TOAST), so cost grows with document size.
- **Shape B: tables.** pg_crdt owns tables in the `crdt` schema (one row per run of characters). Your table holds a document id (`posts.body_doc bigint references crdt.<y>_docs`). Edits insert rows (WAL O(edit)). Reads render with `order by`.

Both must be server-readable: the plain text is available to SQL (full-text search, generated columns, `like`).

## Shared semantics: one op format, one order

All three implementations (A, B, and the JS reference) must produce **identical text** from the same set of ops. That lets us run differential tests.

### Ids
- A replica id is non-empty text without `:`. This is the existing pg_crdt rule (see `crdt.current_replica_id()` and the `pn_` key rules).
- Each character has an id `(replica, seq)`. `seq` is a per-replica counter that starts at 1, has no gaps, and goes up by one per inserted character. Run-length encoding: a run `(replica, seq, "abc")` holds the ids `seq`, `seq+1` and `seq+2`.

### Ops (JSON wire format)
```json
{"i": [["alice", 1, null, null, "Hello"], ["bob", 1, ["alice",5], null, "!"]],
 "d": [["alice", 2, 3]]}
```
- An insert run is `[replica, seq, originLeft, originRight, text]`. `originLeft` is the id `[replica, seq]` of the character immediately to the left when the run was inserted, or null at the start. `originRight` is the id of the character immediately to the right, or null at the end. Inside a run, character k>0 has originLeft = (replica, seq+k-1) and the same originRight as the run. So a run is exactly what you get from typing its characters one by one.
- A delete is `[replica, seq, len]`: it tombstones the ids `(replica, seq .. seq+len-1)`. Deletes are idempotent and commute with everything. Deleting an id you have not seen yet is allowed: keep the delete and apply it when the insert arrives.
- Text length and positions count Unicode code points (Postgres `length()` on text). Not UTF-16 units. Document this; JS clients must convert.

### Order: YjsMod (equal to FugueMax order)
Tombstones stay in the sequence. To integrate a new item with origins (ol, or):
```
left  = index of ol (-1 if null)
right = index of or (len if null)
dest = left + 1; scanning = false
for i = left+1 ..:
    if !scanning: dest = i
    if i == len or i == right: break
    o = item[i]
    oleft  = index of o.ol (-1 if null)
    oright = index of o.or (len if null)
    if oleft < left: break
    elif oleft == left:
        if oright < right: scanning = true; continue
        elif oright == right:
            if new.replica < o.replica: break      # text comparison, C collation
            else: scanning = false; continue
        else: scanning = false; continue
    else: continue        # oleft > left
insert at dest
```
This is `integrateYjsMod` from Seph Gentle's reference-crdts (`crdts.ts`). Check against the source if you can reach it. It does not interleave concurrent runs typed at the same spot. An item can be integrated only once its origins are present. Ops whose origins are missing wait until they arrive (causal delivery). Compare replica ids with `collate "C"`.

### Required behaviour (both shapes)
- `*_empty()`, `*_value(...) -> text`, `*_length`.
- Local edit API by position: `insert(doc, pos, text, replica)`, `delete(doc, pos, len, replica)`. Each returns (or records) the op it generated, so clients and other servers can be sent the delta.
- **`set(doc, new_text, replica)`**: diff the current text against new_text (common prefix and suffix, then one delete plus one insert in the middle) and apply. This is the blessed path for a plain form or ORM save: the app does `update posts set body = crdt.x_set(body, $1, $replica)`. Concurrent saves from two editors who changed different paragraphs both survive.
- **`apply(doc, ops jsonb, replica default crdt.current_replica_id())`**: the untrusted write path, like `pn_apply_delta`. It accepts inserts only with the caller's replica id (or `<id>:<device>`, owner rule as in `pn_`). Deletes may target anyone's characters. It rejects malformed ops (22023). Re-applying ops is a no-op (idempotent).
- **Sync out**: given what a client has (a version vector `{"alice": 12, "bob": 3}`), return the ops it lacks. Full-state merge for shape A: `merge(a, b)`.
- Convergence: any delivery order, with duplicates, gives the same text.

### Non-goals for tonight
Rich text and marks, cursors and presence, undo, history compaction (tombstone GC), Yjs or Automerge wire compatibility, a client library. Write them down as follow-ups.

## Layout (experiments, not yet in the extension)

```
pg_crdt/experiments/text-ref/      JS reference, fuzz fixtures, editing-trace converter (agent C)
pg_crdt/experiments/text-column/   shape A: impl.sql, test/, bench.sh, NOTES.md (agent A)
pg_crdt/experiments/text-table/    shape B: impl.sql, test/, bench.sh, NOTES.md (agent B)
```
Each `impl.sql` loads after `pg_crdt--0.0.1.sql` into the same `crdt` schema and follows `STYLE.md` and the conventions in the extension file: pinned `search_path`, no SECURITY DEFINER, `revoke from public` then explicit grants, IMMUTABLE/PARALLEL SAFE where true, and errors with the existing SQLSTATEs. When the experiment is promoted, it gets pasted into the extension file.

Prefixes (provisional): shape A `text_` (domain `crdt.text`)? No. Names must say the algorithm (architecture.md, section 1). Shape A is **`yseq_`** for now (YjsMod sequence, column) and shape B is **`ydoc_`** (table-backed). Rename at promotion time if a better name appears.

## Benchmarks (both shapes, same harness where possible)
- Document sizes: 1 kB, 10 kB, 100 kB, and 1 MB if feasible.
- Edit latency: insert one char at a random position, delete one char, paste 1 kB, `set` with a one-paragraph change.
- Read latency: render the full text.
- Storage: bytes per document (`pg_column_size` / `pg_total_relation_size`) against plain-text size.
- WAL bytes per edit (`pg_current_wal_lsn` diff), as in `bench/pn-counter.sh`.
- Replay a real editing trace (automerge-paper from josephg/editing-traces: about 260k single-char edits, final text about 100 kB), with op-by-op and batched timings.
- Offline merge: two replicas diverge by N concurrent edits, then merge.
- Concurrency: several sessions editing one document (lost updates? lock waits?).

## Amendment 1 (overnight): causal validation for untrusted writers

An adversarial review found that `apply` accepted any origins that exist. Alice writes "abc", bob sends `["bob",1,null,null,"Y"]`, and a third writer sends `["mal",1,null,["alice",2],"X"]`, whose originRight skips "a". The two delivery orders give `aYXbc` and `aXbcY`, and no merge brings them back together. The JS reference had the same hole, so it was in the contract.

Fix: each op carries `"v"`, the sender's version vector before the op. The untrusted path checks rules V0 to V7, documented with the convergence argument and ablation evidence in `experiments/text-ref/README.md`:
- **Static, on arrival:** shape (V0); origins covered by v advanced run by run (V1); a run's first seq is v[r]+1 (V2); delete targets are covered by v (V6, a security rule: no pre-deleting future text).
- **Dynamic, once the doc covers v:** v is causally closed (V3, needs a stored per-run dependency vector); originLeft is before originRight (V4); no item strictly between the origins is covered by v (V5).
- An op that claims items the server lacks waits (V7), so pending ops need a per-writer quota.

The whole op is accepted or rejected. The fuzz evidence: 0 divergences in 3,000+ byzantine seeds, and 0 honest ops rejected in 300 seeds. Turning off V1 to V5 one at a time causes divergence.

Two corrections to the brief:
- Origins are adjacent in the full sequence, tombstones included.
- Ops returned by `ops_since` carry no `v`, so they are for trusted catch-up only. **Equivocation** (two different ops with the same `(replica, seq)`) is not covered by the rules. A single Postgres server enforces one writer per id with the primary key, so the first arrival wins. Server-to-server merge stays a trusted path.

Also: `set(doc, new_text)` diffing against the current text reverts concurrent edits when the save is stale. Both shapes add a three-way `set` with a base (shape B: a token from `ydoc_base`; shape A: the loaded state).
