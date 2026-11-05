# pg_crdt: pick up here

> Handoff written 2026-11-05 after sessions 5 and 6 (collaborative text). Branch `worktree-crdts`, worktree `.claude/worktrees/crdts`. Nothing is pushed. The latest commit at handoff is the one that adds this file.

## State

- **In the extension** (`pg_crdt--0.0.1.sql`):
  - `pn_` (PN-Counter).
  - `ydoc_`: collaborative text, table-backed. YjsMod order, causal validation V0–V7 for untrusted writers, three-way form saves (`ydoc_base` + `ydoc_set`), `ydoc_compact`, interned replica ids. Document ids are client-chosen text, and `ydoc_create` raises 23505 on an existing id.
- **Experiments:**
  - `experiments/text-column`: `yseq_`, the jsonb column alternative. Tested (221 assertions), not promoted.
  - `experiments/text-ref`: JS reference, fixtures, trace converter. `experiments/text-table`: notes, bench and the bytea-key variant (the code moved into the extension).
- **Tests:** `./test/run.sh` gives 24/24 files and 445/445 assertions. `./test/docker.sh` passes the same on PG16/17/18 with pg_tle and the control file. The trace spec SKIPs unless `experiments/text-ref/regen-traces.sh` has been run.
- **Read first:**
  - `research/journal.md` (sessions 5–6)
  - `research/text.md` (brief plus amendments)
  - `research/benchmarks/text.md` (column vs tables)
  - `experiments/text-ref/README.md` (validation rules V0–V7 and the convergence argument)
  - `experiments/text-table/NOTES.md` (ydoc design and costs)

## Decisions waiting for the user

1. **Names:** `ydoc_` (tables) and `yseq_` (column). The architecture rule is to name the algorithm variant. Renaming is cheap until the first release.
2. **Promote `yseq_` too, or leave it experimental?** The benchmark says it suits small documents (under about 5 kB) saved from a form.
3. **`drop extension` deletes every document** unless a user FK blocks it. This is standard for extension-owned tables and documented in install.md. Keep it, or add a guard?
4. **Public EXECUTE on `_ydoc_*` internals**, needed because the API is SECURITY INVOKER. The tables have no grants and are the real gate. Accept, or redesign?
5. **Pinned `search_path` on every PL/pgSQL function** costs about 18% on `ydoc_apply`. It is kept for safety.
6. **pg_dump config:** `pg_extension_config_dump` is set on the 9 ydoc tables and 4 sequences, so dumps include documents. Confirm.
7. **Production docs URL:** the placeholder is `https://pg-crdt.vercel.app`, and no Vercel project exists yet.
8. **Push and PR** the `worktree-crdts` branch when ready.

## Small fixes queued

- `ydoc_version` on an unknown doc returns `{}`; other functions raise P0002. Make it raise.
- The JS reference rejects `:` in item replica ids, while `ydoc_` and `yseq_` accept `<id>:<device>` keys. Pick one rule and add a fixture.
- `ydoc_rejected` keeps the last 100 per writer and doc; there is no purge API.
- `ops_since` always sends every delete, in both shapes. It needs delete versioning to send only the missing ones.

## Not built (follow-ups, roughly in priority order)

1. A client library, or at least a JS snippet: op generation, UTF-16 to code-point conversion, `v` tracking, and the sync loop against `ydoc_apply`/`ydoc_ops_since`.
2. Tombstone GC beyond `ydoc_compact`. Documents built from random-position inserts stay at about 45× the text size.
3. Full-text search: a cached text column refreshed on save is the documented recipe. An automatic one may be worth adding.
4. Rich text and marks, cursors and presence, undo.
5. Yjs wire compatibility (deliberately out of scope).
6. **`awset_`** (add-wins set) with the naive OR-set as its oracle. This was the next type before the text work started.
7. Compaction for `pn_` delta tables (from session 2).

## How to work (orchestrator mode)

The main conversation plans and delegates:
- `heavy-implementer` for engine changes;
- `light-implementer` for docs and mechanical changes;
- a fresh `general-purpose` adversarial reviewer after each significant change. Two reviews found 14 bugs that the fuzzing missed.
Append each session to `research/journal.md`, which the user will turn into a blog post.
