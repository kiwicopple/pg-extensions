# pg_crdt: pick up here

> Handoff written 2026-11-05 after sessions 5 and 6 (collaborative text); updated after session 7 (queued fixes, user decisions). Branch `worktree-crdts`, worktree `.claude/worktrees/crdts`. Nothing is pushed. The latest commit at handoff is the one that adds this file.

## State

- **In the extension** (`pg_crdt--0.0.1.sql`):
  - `pn_` (PN-Counter).
  - `ydoc_`: collaborative text, table-backed. YjsMod order, causal validation V0–V7 for untrusted writers, three-way form saves (`ydoc_base` + `ydoc_set`), `ydoc_compact`, interned replica ids. Document ids are client-chosen text, and `ydoc_create` raises 23505 on an existing id.
- **Client:** `client/` (session 8): `pg-crdt-client`, the JS client for `ydoc_`. Its engine `client/src/doc.js` is the reference; `experiments/text-ref/ref.mjs` re-exports it. Tests: `npm test --prefix client` (25 tests, incl. a 1,000-seed convergence fuzz) and `client/test/pg.sh` (4 tests on Postgres).
- **Experiments:**
  - `experiments/text-column`: `yseq_`, the jsonb column alternative. Tested (221 assertions), not promoted.
  - `experiments/text-ref`: JS reference, fixtures, trace converter. `experiments/text-table`: notes, bench and the bytea-key variant (the code moved into the extension).
- **Tests:** `./test/run.sh` gives 26/26 files and 471/471 assertions (session 7). `./test/docker.sh` passes the same on PG16/17/18 with pg_tle and the control file. The trace spec SKIPs unless `experiments/text-ref/regen-traces.sh` has been run.
- **Read first:**
  - `research/journal.md` (sessions 5–7)
  - `research/text.md` (brief plus amendments)
  - `research/benchmarks/text.md` (column vs tables)
  - `experiments/text-ref/README.md` (validation rules V0–V7 and the convergence argument)
  - `experiments/text-table/NOTES.md` (ydoc design and costs)

## Decisions (answered by the user, session 7, 2026-11-05)

1. **Names:** `ydoc_` (tables) and `yseq_` (column) are kept.
2. **`yseq_` stays experimental.** Not promoted into the extension.
3. **`drop extension` deletes every document.** Kept, and documented (install.md). No guard.
4. **Public EXECUTE on `_ydoc_*` internals:** accepted. The tables, which have no grants, are the gate.
5. **Pinned `search_path`** on every PL/pgSQL function: kept (about 18% on `ydoc_apply`).
6. **pg_dump config:** confirmed. `pg_extension_config_dump` stays on the 9 ydoc tables and 4 sequences.
7. **Production docs URL:** the placeholder `https://pg-crdt.vercel.app` stays; no Vercel project yet.
8. **Push and PR:** deferred, not yet. Nothing on `worktree-crdts` is pushed.

## Small fixes queued

- [x] **Done (session 7):** `ydoc_version` on an unknown doc now raises `P0002`, like the other ydoc_ functions (it is PL/pgSQL now, no longer an inlined SQL function). The readers `ydoc_value`, `ydoc_length` and `ydoc_base` still return null. Test: `63_text_ids`.
- [x] **Done (session 7):** replica key rule. Decision: align the JS reference with SQL. `ref.mjs` now accepts `<id>:<device>` (device non-empty, may contain `:`) and refuses over 256 bytes, as `crdt._ydoc_is_key` does. One shared fixture, `test/fixtures/replica-keys.json` (22 cases), is run by `experiments/text-ref/test.mjs` (local insert and trusted apply) and by the new spec `64_text_keys` (`ydoc_insert`, `ydoc_merge`, `ydoc_apply`). The two old JS tests that used `a:b` as an invalid id now use `a:`.
- [x] **Done (session 7):** `ydoc_rejected_purge(doc text, writer text default null) returns integer`: deletes the document's rows for one writer or all, returns the count, takes the document lock, P0002 for an unknown document, 22004 for a null one. SECURITY INVOKER like the rest, so the table grants gate it (granted to public by the existing name-pattern loop). Spec `65_text_rejected_purge`, `02_security` list, reference page `docs/reference/ydoc.md`, `errors.md`, CHANGELOG.
- [ ] `ops_since` always sends every delete, in both shapes. It needs delete versioning to send only the missing ones. (Not done; deliberately left for a later session.)

## Not built (follow-ups, roughly in priority order)

1. ~~A client library~~ **Done (session 8):** `client/` (`pg-crdt-client`), docs `docs/reference/client.md`. Open points: persistence of the queue across reloads, a way for a client to learn that a waiting op it sent was refused later, and engine performance for large documents (one object per char, O(n) integration).
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
