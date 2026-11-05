# pg_crdt: Journal

## Session 1: 2026-11-04, research kickoff

- Created `pg_crdt/`. The user wrote the brief in [`prompt.md`](./prompt.md). They called it a brain dump, to be rethought from first principles.
- **User decisions:**
  - Implement in **PL/pgSQL only**: no plv8, PL/Rust, C or WASM.
  - Namespace each CRDT type the way pg_permissions namespaces its models, so new types can be added without collisions.
- Three parallel research tracks: [`runtimes.md`](./runtimes.md), [`prior-art.md`](./prior-art.md) and [`sql-integration.md`](./sql-integration.md). Combined in [`architecture.md`](./architecture.md).
- **Things that changed my mind:**
  - pg_permissions does *not* use a schema per model. It uses one schema with a prefix per model (`rbac_`, `fga_`, `cedar_`). pg_crdt should do the same: one `crdt` schema.
  - Prefixes must name the algorithm variant (`awset_`, `lww_`), not the family (`set_`, `register_`). Otherwise the second register variant has nowhere to go.
  - pg_tle base types *can* have PL/pgSQL I/O functions. They are still not worth it: no send/recv, no opclass without superuser, and the I/O functions can't be patched in upgrades. jsonb with a `{t, v}` envelope wins.
  - A single-statement `update ... set s = merge(s, $1)` is safe under READ COMMITTED. Client-side read-merge-write is not.
  - Supabase deprecated plv8 on PG17, and Automerge JS is WASM-only. Even without the user's decision, reusing JS libraries was a dead end.
  - Documents: store-and-relay of opaque updates first. A native Fugue table is an experiment. Eg-walker stays a proposal.
- **Next:** user decisions listed at the end of `architecture.md`, then specs plus the `pn_` vertical slice.

### Decisions after review (same day)

- One `crdt` schema, prefixes named after the specific algorithm (`pn_`, `awset_`, `lww_`), not the family.
- No generic `crdt.merge` dispatcher for now, because it would be slower. It may come later.
- Still open: whether server-readable collaborative text is in scope, and domain vs plain jsonb.
- **Server-readable where possible**, so values can be indexed. Collaborative text therefore means a native sequence CRDT (Fugue-style) in tables, not an opaque Yjs/Automerge log. Opaque types (`doclog_`) are deferred, not ruled out.
- **A domain per type** (`crdt.pn`, `crdt.awset`, ...), as part of the extension's value. Known risk: dropping the extension cascades to columns of that type. Must be documented. Also to test: whether a plain jsonb value needs an explicit cast to call domain-typed functions.
- OrioleDB ([`orioledb.md`](./orioledb.md)): helps with bloat, vacuum and full-page writes, but a changed value is still fully rewritten and WAL-logged. Verdict: storage-agnostic, OrioleDB as an optional accelerator. The delta table plus merge aggregate remains the real fix.

## Session 2: 2026-11-04, the PN-Counter slice

- Built the first vertical slice, test-first: `pg_crdt--0.0.1.sql` with the PN-Counter (`crdt.pn` domain, `pn_empty`, `pn_increment`, `pn_decrement`, `pn_value`, `pn_merge`, `pn_merge_agg`, `pn_is_valid`, `pn_apply_delta`, `current_replica_id`), `pg_crdt.control`, a test runner copied and simplified from pg_validate's, ten spec files, a benchmark script and [`benchmarks/pn-counter.md`](./benchmarks/pn-counter.md).
- **Tests:** 165 assertions in 10 files, all passing on Postgres 16.4 (local), and 16.15, 17.11 and 18.6 in Docker with pg_tle and the control file installed (`test/docker.sh`), so the pg_tle and `create extension` paths run as a non-superuser there. Property tests: commutativity, associativity, idempotence and identity over 1,000 random triples each; 60 convergence trials with shuffled, duplicated and stale delivery; an independent per-key max as the oracle for merge and for the aggregate.
- **Concurrency, proved with dblink:** a second session's `update ... set s = pn_merge(s, $1)` waits on the row lock and merges into the first session's committed version; 600 concurrent single-statement transactions from two sessions lose nothing. The negative control (read in one statement, write the merged value in another) does lose an update, so the test can see one.
- **The RLS path:** `pn_apply_delta(state, delta)` is a validating merge, not `SECURITY DEFINER` itself. The app wraps it in its own `SECURITY DEFINER` function and denies clients UPDATE on the column. The replica id comes from the JWT `sub`, else the `crdt.replica_id` setting. A delta may only touch the caller's id or `<id>:<device>`, may not lower a count, and must pass the full validator.
- **Open questions, settled (`test/spec/40_open_questions.sql`):**
  - *Does a plain jsonb value need an explicit cast to call a `crdt.pn` function?* No. Columns, PL/pgSQL variables and literals all coerce implicitly, and the coercion runs the CHECK once per value.
  - *Does the domain CHECK run on every function return?* Yes, whenever a `crdt.pn` is made from jsonb: PL/pgSQL, inlinable SQL and SQL-standard bodies alike. Counted with a spy constraint: `pn_merge` and `pn_increment` once per call, `pn_merge_agg` once per merge, `pn_empty()` once per call. Not for a `crdt.pn` passed through unchanged (`pn_merge(x, null)`, a `crdt.pn` column as an argument). It also runs on a null literal cast to the domain.
  - *Generated column and expression index on `pn_value`?* Both work (stored generated column, expression index used by the planner, CHECK constraint, `reindex` under `search_path = pg_catalog, pg_temp`). Postgres 18's virtual generated columns reject user-defined functions ("not yet supported"), so stored only.
- **Things that surprised me:**
  - The first `pn_merge` passed every property test and was quadratic: `a -> 'p' -> e.key` inside the sub-select over b's entries detoasts a and copies its map per entry. A full merge of two 10,000-replica states took 1.85 s; extracting the maps once made it 13 ms. One-entry deltas hid it. Correctness tests can't see this; benchmarks have to be part of the spec.
  - **SQL vs PL/pgSQL makes no difference** for merge: the same statement costs the same in both, from 10 to 10,000 replicas. The cost is building jsonb.
  - `jsonb ||` re-sorts every key of the map; `jsonb_set` on an existing key does not. `pn_merge` now uses `jsonb_set` when exactly one entry changes (a replica's own delta), which halves the delta merge at 1,000+ replicas. The `jsonb_set` loop, ruled out in the architecture, is the fastest for one-entry deltas and quadratic for full merges.
  - A full per-entry CHECK on the domain costs about 4 ms at 10,000 replicas and runs on every merge result, more than the merge. So **the domain checks only the envelope** (about 10 us, with `@>` and `jsonb - text[]`, which do not walk the nested maps; `value -> 'p'` and jsonpath `keyvalue()` both copy them). `pn_is_valid` is the full validator, enforced by `pn_apply_delta`. This is safe for convergence: merge keeps the larger entry under jsonb's total order, a semilattice for any JSON values, and a property test with junk entries (strings, nulls, objects) holds the laws. First version of the validator had a hole: `jsonb_typeof(state -> 'n')` is null when `n` is missing, a null CHECK passes, so a state without `n` was accepted. Coalesce, or operators that cannot return null.
  - **WAL crossover at about 100 replicas.** Below it, a state-column update logs *less* WAL than a delta insert (128 B vs 334 B at 10 replicas): the row is inline and Postgres logs only the changed bytes of a same-page update. Above about 2 kB the state is TOASTed and every write logs all of it: 9.9 kB at 1,000 replicas, 92 kB at 10,000 (28 and 264 times a delta insert). So the state column is right for small counters, and the delta table plus compaction for counters with many writers.
  - `create schema if not exists crdt` fails inside `create extension` when the control file or pg_tle has already made the schema (pg_validate had found the same). Use a DO block.
- **Next:** compaction for the delta table (merge into a snapshot row, delete folded deltas), then `awset_` with the naive OR-set as its oracle.

## Session 3: 2026-11-04, generic identity

The user reviewed the slice. Guiding principle: pg_crdt is generic Postgres and must work with any tool, not only Supabase. Identity must not assume UUIDs, `auth.uid()`, Supabase roles, or that a JWT is present at all.

- **Stale deltas are a no-op, not an error.** Session 2 rejected a delta that lowered a count (22023), to surface a replica that lost its state. But a lower total also looks exactly like a retry or a replayed older delta, and those must succeed: max-merge already ignores them. The check is gone. Lost-state recovery is now documentation: a writer reads its own entries back first, or uses a fresh device id; otherwise its next increments are swallowed until they pass the old total. Two writers sharing one key do the same.
- **Replica ids are generic text, with `:` reserved.** An id is any non-empty text without `:` (emails, integers as text, role names; no UUID assumption). An entry key is an id or `<id>:<device>`; the owner is the part before the first `:`, compared exactly, so `abc` can write `abc` and `abc:phone` but not `abcd` or `ab`. A caller identity with `:` is rejected (22023, like other malformed input), and so are malformed keys (`abc:`, `:x`) in `pn_increment`, `pn_decrement` and `pn_apply_delta`. `pn_merge` stays permissive: it must accept whatever another replica sends.
- **Identity is pluggable.** `pn_apply_delta(state, delta, replica text default crdt.current_replica_id())`. The app's SECURITY DEFINER wrapper passes the identity it trusts: `session_user` for direct SQL clients (not `current_user`, which is the definer), its own users table, a JWT claim, or `auth.uid()::text` on Supabase. A null replica is 42501. With the replica an argument, `pn_apply_delta` is pure, so it is now IMMUTABLE.
- **The default resolver** reads a JWT claim from `request.jwt.claims`, which is the PostgREST convention rather than a Supabase one; the claim name comes from `crdt.replica_id_claim`, default `sub`. Then the `crdt.replica_id` setting, which app servers set with `SET LOCAL`. The same order as pg_permissions' subject. Trust model, stated in the README and pinned by a test: any role can `SET` these settings, so a direct-SQL client can claim any id through the default; such deployments pass `session_user`.
- **Docs and tests are generic.** The README leads with the wrapper pattern and two identity sources (PostgREST JWT, app server or `session_user`), mentioning Supabase as one example. Spec 30 creates its own roles instead of relying on `authenticated`; only the grant check in `02_security` uses the PostgREST-convention roles, and only where they exist.

## Session 4: 2026-11-04, user documentation

- User docs in `docs/` and an Astro/Starlight site in `site/`. Copied from pg_validate's site, plus pg_permissions' code tabs. App examples use node-postgres first, then SQL. There is no client library.
- Pages: overview, install, quickstart, four guides (replicas and identity, safe updates, security, storage and performance), the PN-counter page, and a reference (shared, pn, errors, limits). Plus `STYLE.md` and `CHANGELOG.md`.
- Every SQL and JS example was run against a throwaway cluster. The install paths were run in Docker (pg_tle on PG18, control file on PG16).
- **Found while writing the docs:**
  - `drop extension` leaves the empty `crdt` schema behind.
  - A `pn_empty()` column default blocks `drop extension` even after the column is altered to jsonb.
  - The old README's error table missed several SQLSTATEs.
- Added a hand-written compaction recipe for delta tables: `delete ... returning` folded into a snapshot upsert in one statement. Compaction is not built in yet.
- The production URL is undecided. The placeholder is `https://pg-crdt.vercel.app` (`site/astro.config.mjs`, `research/navigation.json`).

## Session 5: 2026-11-04 to 11-05 (overnight), collaborative text

The user asked for a way to store text documents, the most common CRDT use case (a blog post body edited by several people). They suggested either a CRDT text column or tables in the `crdt` schema with a link to a document, and left it to run overnight. Brief: `research/text.md`.

- **Plan:** one algorithm, two storage shapes, measured against each other. The algorithm is YjsMod order (equal to FugueMax, no interleaving), with one JSON op format shared by three implementations:
  - a JS reference (`experiments/text-ref`), which also generates the fixtures and converts the automerge-paper editing trace (259,778 edits);
  - shape A, a `crdt.yseq` jsonb column (`experiments/text-column`);
  - shape B, extension-owned tables with a document id (`experiments/text-table`).
  All three must produce identical text, so the fixtures double as differential tests.
- **Shape A:** runs stored as `int[]` literals inside jsonb, which parse 4x faster than jsonb arrays. Runs are grouped in chunks of up to 128 (chosen by a sweep). Deleted characters keep no text. Merge became a linked-slot engine: at 100k chars with 1,000 edits per side, merge went from 2.4 s to 74 ms. Storage is 1.2 to 1.6x the plain text, but every keystroke rewrites the whole value: 114 kB of WAL per keystroke at 100 kB.
- **Shape B:** rows per run, and a server-local bigint order label with relabelling, so render is `order by`.
  - Fractional bytea keys were tried first. They reached 288 bytes on the trace.
  - Blocks hold prefix lengths for position lookup: 0.3 ms per insert at 100k, against 3.7 ms with a running sum.
  - Writes serialize per document on the document row lock.
  - Compaction merges adjacent runs (trace document: 149 to 26 bytes per char).
  - Replica ids are interned, which halves storage with UUID ids.
  - WAL is about 1 to 2 kB per keystroke at any size.
- **Head-to-head** (`research/benchmarks/text.md`): B is the default. Its cost per edit is flat from 1 kB to 1 MB. It is 10 to 60x cheaper in WAL per keystroke, about 3x faster for three-way saves, 8x faster for batched `apply`, and 2x the same-post throughput. The price is about 4x A's storage and tables the extension owns. A suits small documents saved from a form, where the team wants a plain column.
- **Things that surprised me:**
  - **My brief was wrong about `set()`.** Diffing a save against the *current* text reverts whatever other editors did since the form was loaded. So "edits to different paragraphs both survive" was false. Shape B found it. The fix is a three-way `set` against the base the editor loaded: a token in B, the loaded state in A. It took two more review rounds to get right, first for a second save from the same base, then for ops emitted after the writer's own later edits.
  - **The op format was not safe against untrusted writers.** A reviewer showed that one insert with an originRight that skips a character the writer had seen makes replicas diverge permanently (`aYXbc` against `aXbcY`). The JS reference had the same hole, so it was in the contract, not a porting bug. The fix is that every op carries the sender's version vector, and apply checks rules V0 to V7. The rules: origins covered; seqs contiguous; delete targets covered; the vector causally closed; originLeft before originRight; and no item the sender had seen strictly between the origins. Byzantine fuzz over 3,000+ seeds found 0 divergences, and turning off any of V1 to V5 brings divergence back. Equivocation (the same id with different content) is outside the rules. A single Postgres server settles it with the primary key, so the first arrival wins.
  - The two adversarial reviews found the same classes of bug in both shapes: uncapped replica-key length, quadratic CPU from one op with thousands of tiny runs, a parked op that blocks a writer forever, and missing `search_path` pins. Correctness fuzzing missed all of them. Each review came with a repro script.
  - Pinning `search_path` on every PL/pgSQL function costs about 18% on `ydoc_apply`. We kept it, because internal functions must stay executable by API callers.
  - Shape A's `int[]`-in-jsonb trick parses 4x faster than nested jsonb arrays, and halves the size.
- **Next:** the user reviews the names (`ydoc_`, `yseq_`), the promotion of `ydoc_` into the extension, and the pg_dump config for extension-owned tables. Not built: tombstone GC beyond compaction, rich text and marks, cursors, undo, a client library (JS clients must convert UTF-16 offsets to code points), and Yjs wire compatibility.

## Session 6: 2026-11-05, text document ids

The user asked that clients can create documents, so the public document id changes from a server-assigned bigint to client-choosable text: `ydoc_create(id text default gen_random_uuid()::text) returns text`, and every `ydoc_` function takes `doc text`.

- **Why text, not uuid.** Same reason replica ids are text: the extension stays generic. Text accepts UUIDs, UUIDv7 and ULIDs, Yjs room names and app keys (`post:123`) without the extension choosing an identity scheme. The only rules are non-empty, at most 256 bytes, no control characters; ids compare byte for byte (`collate "C"`), so `Post` and `post` are two documents.
- **Why the internal bigint stays.** 45 columns in the internal tables name a document (items, blocks, deps, replicas, pending, ...). Keeping a bigint there keeps rows and indexes small, and leaves every `_ydoc_*` internal untouched. `ydoc_docs` gets `uid text unique`; each public function resolves it once, in the same probe that takes the document row lock (`_ydoc_lock` returns the internal id), so a write does one lookup, not two. Latency of 1,000 inserts into a 100k document did not change (about 0.22 s before and after).
- **Why `23505` and not an idempotent create.** An idempotent create (`on conflict do nothing`, return the id) lets anyone squat on a predictable id: create `post:123` first and the owner's create silently succeeds against a document someone else already controls. So an existing id raises `unique_violation` with a hint, concurrent creates of one id give one success and one `23505` (the `on conflict` insert waits for the other transaction), and the app's wrapper decides what to do: the owner's retry gets its own post back, anyone else is refused. An id grants nothing, and existence is never proof of ownership; ownership lives in the app's own table.
- **Small things.** The default is `pg_catalog.gen_random_uuid()::text`, qualified because defaults run in the caller's context. The base token's `d` now holds the public id. Unknown documents still raise `P0002`; the readers still return null (`ydoc_version`: `{}`).
