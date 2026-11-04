# pg_crdt prior art

Research date: 2026-11-04. Scope was narrowed mid-research: pg_crdt will be **PL/pgSQL only**, so no JS, WASM or Rust library can run inside Postgres. Libraries are surveyed for design lessons and wire-format compatibility. Feasibility is judged as "can this be implemented reasonably in PL/pgSQL over jsonb, bytea and ordinary tables".

Convention: "verified" means I read the source or primary document. "unverified" means it comes from memory or a secondary source.

## 1. supabase/pg_crdt

There are two generations under one repo name.

**Original (2022).** Per the [Supabase blog post](https://supabase.com/blog/postgres-crdt), a Rust extension built with pgx wrapped the Yjs and Automerge Rust libraries. It added a column type `crdt.ydoc` (`content crdt.ydoc default crdt.new_ydoc()`). The post names three problems:
- Realtime reads the WAL, which carries a full copy of the row, so a one-character edit can broadcast the whole document.
- Frequently updated CRDT values produce a lot of WAL and dead tuples.
- Large values add (de)serialization cost on every update.

**Current repo** ([supabase/pg_crdt](https://github.com/supabase/pg_crdt), verified by cloning):
- It is not archived. Last push was 2025-04-11, 89 commits, about 650 stars, PostgreSQL License. The README still says "experimental".
- It is a **C extension** linking `libautomerge` (automerge-c). The Makefile has `SHLIB_LINK = -lc -lpq -lautomerge`, and `automerge.control` sets `superuser = false`, `schema = automerge`. About 350 lines of C and SQL in `src/automerge/`.
- It cannot be installed through pg_tle or on managed Postgres without Supabase shipping the shared library. It also does not use pgrx or yrs, so it is a different design from the 2022 one.
- Types: `autodoc` (a whole Automerge document, variable length, `storage = extended`) and `autochange` (one change).
- Casts: an **implicit** cast between `autodoc` and `jsonb` in both directions.
- Functions (all `LANGUAGE C`):
  - Merge and apply: `merge(autodoc, autodoc)`, `apply(autodoc, autochange)`.
  - Actors and changes: `get_actor_id`, `set_actor_id`, `get_changes(autodoc) -> setof autochange`, `get_change_hash`, `get_change_message`.
  - Scalar accessors: `get_/put_` for `str`, `int`, `double`, `bool`, `counter`, `text`, plus `inc_counter` and `splice_text`.
  - Rich text: `create_mark` and `get_marks`.
  - Conversion and queries: `from_jsonb`, `to_jsonb`, `autodoc_path_query` (jsonpath over the jsonb cast).
- Storage format: the Automerge binary document format, opaque to SQL. The README describes an "expanded datum" (the in-memory object mechanism in [TOAST docs](https://www.postgresql.org/docs/current/storage-toast.html#STORAGE-TOAST-INMEMORY)) to avoid re-parsing within a query. It does not reduce WAL, because the whole value is still rewritten on each UPDATE.
- `TODO.md` lists missing pieces: aggregate over changes (`select apply(doc, change) from changes`), unnesting a doc into changes, heads arguments, missing-deps diffing, and "explore syncChange support". So **there is no sync or diff API**.

Lessons for pg_crdt:
1. Whole-value CRDT columns rewrite the full value on every update, so WAL, TOAST and Realtime payloads are proportional to document size, not edit size. Small states (counters, sets, registers) are fine. Documents want an **append-only update log table** (insert-only, WAL proportional to the update).
2. Wrapping a native library gives high fidelity but no pg_tle installability.
3. `put_*(doc, key, val, insert bool, message text)` shows that exposing a library's mutators function by function is large API surface. A uniform small API per CRDT family is cheaper to keep consistent.
4. The implicit jsonb cast is convenient but lossy. It hides conflicts and metadata, so pg_crdt should make the "view" explicit (`crdt.pn_value`, `crdt.set_values`).

## 2. Text and document CRDT libraries

### Comparison

| | Yjs | yrs (y-crdt) | Automerge | Loro | Diamond Types |
|---|---|---|---|---|---|
| Sequence algorithm | YATA | YATA | RGA-style op IDs (Lamport) | Fugue; Eg-walker adaptation | Eg-walker (original impl) |
| Runtime | pure JS | Rust, WASM bindings (ywasm) | Rust core; JS is WASM-only | Rust; JS via WASM | Rust; JS via WASM |
| Pure-JS build | yes | no | **no** (see below) | no | no |
| License | MIT | MIT (GitHub API reports NOASSERTION; unverified) | MIT | MIT | ISC |
| Binary format | update v1 and v2, documented in code, not a normative spec | same as Yjs | [draft spec](https://automerge.org/automerge-binary-format-spec/), reference impl wins on conflict | [normative `docs/encoding.md`](https://github.com/loro-dev/loro/blob/main/docs/encoding.md) | [`BINARY.md`](https://github.com/josephg/diamond-types/blob/master/BINARY.md), explicitly unstable pre-1.0 |
| Incremental sync | state vector -> diff update | same | heads + bloom-filter sync; also change-hash based | version vector / frontiers, `export` updates since a version | version / frontier |
| Server can merge without library | no | no | no | no | no |

Sizes are mostly unverified. The npm listing shows `@automerge/automerge` 3.5.0 at 43.9 MB install size (not a bundle size). A third-party guide claims about 320 kB min+gz for Automerge versus about 18 kB for Yjs. I could not confirm that from a primary source, so treat it as unverified. None of it matters for PL/pgSQL.

### Yjs and yrs
- Algorithm: YATA. Each item has `origin` (left neighbour) and `originRight`. IDs are `(clientID, clock)`, with a random 53-bit client ID. Consecutive items from one client are merged into one run. Deletes are a separate delete set (ranges of IDs), a state-based CRDT with no deleter or timestamp ([INTERNALS.md](https://github.com/yjs/yjs/blob/main/INTERNALS.md)). GC drops deleted content and keeps only lengths.
- State vector: per client, the next expected clock. Sync is two steps ([y-protocols PROTOCOL.md](https://github.com/yjs/y-protocols/blob/master/PROTOCOL.md)): SyncStep1 sends the state vector, SyncStep2 replies with the missing structs plus the delete set. Updates are commutative and idempotent ([README](https://github.com/yjs/yjs/blob/main/README.md)).
- Wire format v1 (verified in part from `encoding.js` and `UpdateDecoder.js`):
  - Primitives are varuint, varstring and byte arrays.
  - The layout is: a client count; per client (descending client ID) a struct count, client ID, start clock, then structs; then the delete set.
  - Each struct starts with an info byte whose low bits give the content type (GC, deleted, JSON, binary, string, embed, format, type). Higher bits flag origin, rightOrigin and parentSub.
  - From memory (unverified): string lengths are counted in **UTF-16 code units**, and "any" content uses lib0's tagged encoding.
- Parsing a v1 update in PL/pgSQL is possible, because it is a simple varint stream with no compression. Producing a *correct, mergeable* update is the hard part: it needs YATA integration, handling of structs whose dependencies have not arrived (pending structs), delete-set coalescing, and exact UTF-16 length handling. See section 6 for the call.
- v2 is columnar with run-length encoding and is harder again.

### Automerge
- JS package `@automerge/automerge` 3.5.0 ("Javascript implementation of automerge, backed by @automerge/automerge-wasm", from its `package.json`). All entry points are WASM: `fullfat_base64`, `fullfat_node`, `fullfat_bundler`, and `/slim` with manual `initializeWasm` or `initializeBase64Wasm` ([docs](https://automerge.org/docs/reference/library-initialization/)). **There is no pure-JS build.** The page does not mention one.
- Automerge 3.0 cut memory use by about 10x by keeping history compressed at runtime. This is the project's own claim ([blog](https://automerge.org/blog/automerge-3/)).
- Binary format: chunks with magic `85 6f 4a 83`, a 4-byte SHA-256-prefix checksum, a type byte (document, change, compressed change) and a uLEB length. Columns use RLE, delta and boolean encodings, with optional DEFLATE. The spec is marked draft, has open questions, and says that where it differs from automerge-rs, the Rust implementation wins. Parsing needs hash verification over a topological traversal. This is too heavy for PL/pgSQL.
- Sync: peers exchange heads and Bloom filters of change hashes, based on [arXiv 2012.00472](https://arxiv.org/abs/2012.00472), over a reliable in-order stream ([`sync.rs`](https://github.com/automerge/automerge/blob/main/rust/automerge/src/sync.rs), verified). The protocol is per-peer-connection stateful.
- Data model: JSON-like documents with maps, lists, text, counters and marks. This is the closest match to what a `jsonb` document column suggests, but the cost is the whole library.

### Loro
- Fugue for text, with an Eg-walker adaptation to reduce compute and space. It also has movable trees and movable lists. Rust core, WASM for JS, MIT ([README](https://github.com/loro-dev/loro)).
- It has a normative encoding document, pinned to a commit. The envelope is `loro` magic, an xxHash32 checksum and a mode (3 = snapshot, 4 = updates). The body uses postcard, `serde_columnar` and LZ4 ([encoding.md](https://github.com/loro-dev/loro/blob/main/docs/encoding.md)). Reimplementing that in PL/pgSQL is unrealistic (LZ4, columnar postcard).
- Shallow snapshots drop history before a version, like a shallow git clone. This is a useful idea for compaction, but it needs a version all participants agree on.

### Diamond Types and Eg-walker
- Diamond Types is Rust, ISC, and still a work in progress (README: "WIP", plain text only, crates.io release "quite out of date"). The format is explicitly unstable: "There may be some last minute breaking changes to the file format before DT hits 1.0." It has a magic `DMNDTYPS`, a chunk tree with varints, and ignorable unknown chunks. JS packages are WASM (`diamond-types-node`, `diamond-types-web`).
- [Eg-walker paper](https://arxiv.org/abs/2409.14252) (Gentle and Kleppmann, EuroSys 2025), verified from the HTML version:
  - **Model:** an event graph. Each event is an insert or delete with an index position, a unique ID `(replica, seq)` and parent event IDs. The graph is append-only, and merging is a set union of events.
  - **State on disk:** the event graph (column-encoded, run-length compressed), plus optionally a cached copy of the final text. The CRDT-style internal structure is never persisted or sent over the network.
  - **Merge/replay:** topologically sort events and replay them. For concurrent events, build a temporary internal state with a "prepare" version and an "effect" version, retreating and advancing events to move between branches. Each event yields a transformed index operation.
  - **Critical versions:** where every earlier event happens-before every later one, the internal state can be discarded. A replica replays only from the latest critical version before the concurrent events. Non-concurrent remote events and local edits need no replay.
  - **Is the full graph required?** For concurrent merges and for reconstructing old versions, yes. The paper says history can be discarded only once no future event can be concurrent with an existing one. With offline replicas that is unknowable.
  - **Delivery assumption:** causal broadcast. A replica waits for missing parents before adding an event.
  - **Size:** about 20% to 3x the plain text size for the graph (paper section 4.5, as summarised by my fetch).
- **Does a server that only stores and relays the op log suffice?** Yes. The server only needs to hold an append-only set of events keyed by `(agent, seq)`, optionally check that parents exist, and serve events a peer lacks. No merge logic is needed server-side. It needs the replay algorithm only if it must render text or answer queries about content.
- [eg-walker-reference](https://github.com/josephg/eg-walker-reference) (BSD-2-Clause, verified): 991 lines for the causal graph plus 648 for the walker, TypeScript. Its README says document order matches "yjsmod" and "we believe this algorithm is isomorphic to FugueMax". It is "fully compatible with diamond types", tested with conformance data. Its internal item is `{opId, curState, endState, originLeft, rightParent}`, held in a spliced array in document order. That array-splice design maps poorly onto SQL.
- **Feasibility in PL/pgSQL:** a port is possible but is the largest and riskiest item in the project. It needs graph diff and dominator-style queries, an ordered mutable list with positional lookup, and per-step state retreat/advance. Row-by-row PL/pgSQL would be slow. Defer.

### Feasibility inside the database

| | plv8 | WASM | PL/pgSQL |
|---|---|---|---|
| Available on managed Postgres | Deprecated on Supabase Postgres 17, must be dropped before upgrade ([docs](https://supabase.com/docs/guides/database/extensions/plv8)) | No | Always |
| Automerge/Loro/DT | needs WASM, which plv8's V8 setup would have to expose (unverified) | n/a | no |
| Yjs (pure JS) | feasible in principle | n/a | no |

The plv8 deprecation and the user's scope change both point away from JS. pg_tle itself ([docs](https://github.com/aws/pg_tle)) supports plpgsql, plv8 and plperl examples, and a custom base type created with `pgtle.create_base_type` is stored internally as `bytea`, with `text <-> bytea` I/O functions written in the trusted language ([09_datatypes.md](https://github.com/aws/pg_tle/blob/main/docs/09_datatypes.md)).

## 3. State-based primitives

Common notation: replica ID `r`, state `S`. Merge must be commutative, associative and idempotent. All shapes below are jsonb-friendly.

### PN-Counter
- State: `{"p": {r: n}, "n": {r: n}}`, two grow-only maps from replica to a non-negative integer.
- `inc(S, r, k)` (k >= 0): `p[r] += k`. `dec(S, r, k)`: `n[r] += k`. Value: `sum(p) - sum(n)`.
- Merge: per replica, `max` in each map. This is a join-semilattice because each entry only grows.
- **Single-writer rule:** each replica ID must be written by exactly one writer at a time. Two writers sharing an ID both read `p[r] = 5`, both write 6, and one increment is lost after merge. For SQL, the ID is a session, device or user key, not a Postgres backend.
- Metadata: O(replicas ever seen). No tombstones, and entries cannot be removed safely because a returning replica would re-introduce its old value as "new".
- Delta: only the changed entries, for example `{"p": {"a": 7}}`. Merge of a delta is the same function.
- A single-statement `UPDATE t SET s = crdt.pn_increment(s, 'a', 1)` is safe under READ COMMITTED because Postgres re-evaluates the expression against the latest row version after waiting for the lock. Read-modify-write in the application is not safe.

### OR-Set (add-wins), three variants
1. **Original Shapiro OR-Set:** state is `(A, R)`, two grow-only sets of `(element, unique tag)`. `add(e)` puts `(e, fresh tag)` in A. `remove(e)` copies all currently observed `(e, tag)` pairs from A into R. Value is `{e : exists (e,t) in A \ R}`. Merge is union of both. Trivially correct, but both sets only grow (tombstones forever).
2. **Optimised add-wins set with dots and causal context** ([Bieniusa et al., "An optimized conflict-free replicated set"](https://arxiv.org/abs/1210.3368), which avoids tombstones to shrink metadata; and the causal δ-CRDT form in [Almeida, Shoker, Baquero, "Delta State Replicated Data Types"](https://arxiv.org/abs/1603.01529)). My description of the dot-store formulation is from memory of those papers, so the algorithm below is unverified against them, but I derived and checked it:
   - State: `E` maps element to a set of dots `(r, c)`, and `CC` is the causal context, a version vector `{r: max counter}`.
   - `add(e, r)`: `c = CC[r] + 1`; set `E[e] = {(r, c)}` (dropping older dots for `e`, which are now dominated); `CC[r] = c`.
   - `remove(e)`: delete `E[e]`. **Keep `CC` unchanged.** The context is how others learn the dots are gone.
   - Merge `(E1, CC1)` and `(E2, CC2)`, per element `e`:
     `E[e] = (E1[e] ∩ E2[e]) ∪ (E1[e] \ CC2) ∪ (E2[e] \ CC1)`; `CC = pointwise max(CC1, CC2)`. Drop elements with an empty dot set.
     A dot survives if both sides have it, or one side has it and the other side has not yet seen it. A dot that is in the other side's context but absent from its entries was removed there.
   - Value: elements with at least one dot.
   - Concurrent add and remove: the add's fresh dot is not in the remover's `CC`, so it survives (add wins). Remove then re-add: the new dot has a higher counter, so it survives.
   - Metadata: O(elements x concurrent dots) plus O(replicas). **No tombstones.** The version vector never shrinks, but it is O(replicas) and not O(history).
   - Proper contiguity: a version-vector context is only valid when all dots from `r` up to `CC[r]` have been seen. That holds for full-state merges. It does not hold for deltas (below).
   - jsonb shape: `{"v":1,"cc":{"a":3,"b":2},"e":{"user_123":["a:3"]}}`.
3. **Remove-wins** is the dual and is rarely wanted. Skip.

**Delta caveat (derived, important):** filtering `E` to dots the remote has not seen but shipping the full `CC` is wrong. The merge rule would treat the filtered-out dots as removed, because they are covered by the delta's context but absent from its entries. A correct delta carries a context equal to only the **new** dots (a dot cloud, or ranges `(remote.cc[r], local.cc[r]]` per replica). So deltas need a slightly richer context type than a version vector. For the MVP, ship full states (they are small for sets of modest size) and defer deltas.

**Recommended:** variant 2 for the product, with variant 1 as the property-test oracle (same observable value for any history). The merge is a short jsonb SQL function.

### LWW-Register
- State: `{"v": <jsonb>, "t": <timestamp>, "r": <replica>}`. Merge: keep the state with the greater `(t, r)` compared lexicographically. Deterministic as long as the tuple is unique per write.
- If the same `(t, r)` carries different values (a bug or misuse), break the final tie on canonical value text so merge stays deterministic. cr-sqlite orders `col_version`, then value, then `site_id` (flag `mergeEqualValues`), verified in [`changes_vtab_write.rs`](https://github.com/vlcn-io/cr-sqlite/blob/main/core/rs/core/src/changes_vtab_write.rs).

Clock choices:

| Clock | Preserves causality | Skew problem | Notes |
|---|---|---|---|
| Wall clock | no | a replica with a fast clock wins forever; a replica that wrote after observing the other's state can still lose | simplest |
| Lamport counter | yes | none, but time carries no real-world meaning, and a counter bump needs the observed state | `t = max(observed) + 1` |
| Hybrid logical clock (HLC) | yes | bounded by skew, stays near wall time | `(wall_ms, logical counter)`; update rule `wall = max(now, observed.wall)`, bump the counter on ties |

A pure-SQL HLC works naturally: `register_set(state, v, r)` can derive `t` from the **state it is writing over**, `t = greatest(now_ms, state.t_wall)` with the logical counter incremented on equal wall time. That gives "a write that observed another state beats it" with no extra clock input. Document that a client writing offline from an old state may still lose to a newer write from a replica with a faster clock. Metadata is O(1). No tombstones. A delta is the state itself.

### MV-Register
- Same dot machinery as the OR-Set. State: `{(value, dot)}` plus context `CC`. `set(v, r)`: replace all dots with `{(v, (r, CC[r]+1))}` and advance `CC`. Merge uses the same dot-survival rule as the OR-Set above. Value is the **set** of values (more than one means a concurrent conflict the application must resolve).
- Use it where silent loss is worse than showing conflicts. It is the same code as the OR-Set with elements replaced by values, so it costs little once the dot kernel exists.

### LWW-Map and OR-Map
- **LWW-Map (per-key LWW register):** state `{key: {"v":..., "t":..., "r":..., "d": deleted?}}`. Merge is per key as for the LWW-Register. Removal writes a tombstone with a fresh timestamp. This is the row/column model of cr-sqlite, and Ditto documents registers as LWW with HLC timestamps ([glossary](https://docs.ditto.live/home/glossary)).
- Tombstones cannot be dropped safely: dropping one lets an older concurrent write for that key resurrect. Safe GC needs causal stability (every replica has acknowledged a point), which is not knowable with offline replicas. The brief rules out GC that could break disconnected replicas, so keep tombstones and document the growth.
- **OR-Map (dot map):** `key -> nested CRDT` with one shared causal context. Removing a key removes only what the remover observed, so a concurrent update to the same key survives ("update wins"). This is more correct but needs recursive merge dispatch and shared contexts. From memory (unverified), the dot-store framework in the delta paper defines DotSet, DotFun and DotMap for exactly this.
- **Recommended:** LWW-Map first (flat, per-key LWW). It composes with the register code. Add OR-Map later as the dot kernel generalises.

### Summary of the shared kernel
The OR-Set, MV-Register and OR-Map are all instances of one "dot kernel": a map from dots to values plus a causal context. If pg_crdt writes one jsonb dot-kernel merge function, three types come almost free. The PN-Counter and LWW types do not need it.

## 4. Database-side CRDT systems

### cr-sqlite (most relevant)
Sources: [README](https://github.com/vlcn-io/cr-sqlite) and source (cloned 2026-11-04; last commit 2026-08-10).
- **Granularity:** a row is a map of columns. A table is upgraded with `SELECT crsql_as_crr('table')`. Each column is merged independently, by LWW by default. Counter, fractional-index and PERITEXT types are listed as in progress or partial.
- **Where merge happens:** inside the database. Changes are read from and written to a virtual table `crsql_changes` with columns `table, pk, cid, val, col_version, db_version, site_id, cl, seq`. Syncing is `INSERT INTO crsql_changes ...` on the receiver. Transport is out of scope.
- **Clock table** per CRR (from `bootstrap.rs`, verified): `<table>__crsql_clock(key, col_name, col_version, db_version, site_id, seq, PRIMARY KEY (key, col_name))`, plus `<table>__crsql_pks` mapping the primary key to an integer `key`, and a `site_id` table (16-byte random blob, ordinal).
- **Conflict rule** (verified in `did_cid_win`): first the causal length `cl` (delete and resurrect), then the higher `col_version`, then a comparison of values (NULL smallest), then optionally `site_id` as the final tie-break.
- **Deletion:** a row-level causal-length set, so a delete increments `cl` and a re-insert increments it again. This keeps tombstone information to one integer per row plus clock rows for columns.
- **Sync cursor:** `db_version` is a per-database logical clock. A peer asks for `db_version > x` and `site_id != theirs`. Peer cursors are stored in `crsql_tracked_peers(site_id, version, seq, tag, event)`.
- **Costs:** inserts are about 2.5x slower than normal tables, reads are about the same. Schema changes need `crsql_begin_alter` and `crsql_commit_alter`. History-free (state only), with a causal-event-log design planned for v2.
- Design lesson for SQL: this whole scheme maps directly to a Postgres table `crdt_changes(pk, col, val, col_version, db_version, site_id, cl)` merged with `INSERT ... ON CONFLICT DO UPDATE ... WHERE (excluded.cl, excluded.col_version, excluded.val, excluded.site_id) > (t.cl, ...)`. Plain SQL. Worth considering as the **row-level** API, separate from the opaque-value types.

### ElectricSQL
- **Legacy (to early 2024):** Rich-CRDTs layered over [Vaxine](https://github.com/electric-sql/vaxine) (AntidoteDB based), shadow tables and triggers in Postgres holding CRDT metadata, SQLite clients. Merge happened in the sync service and in triggers, with extensive schema changes. Development stopped; per third-party posts it was replaced by "Electric Next" ([PowerSync comparison](https://powersync.com/blog/electricsql-vs-powersync), [electric-next comparison](https://powersync.com/blog/electricsql-electric-next-vs-powersync)).
- **Current:** a read-path sync engine over Postgres "shapes", reached 1.0 in March 2025 per secondary sources. It leaves the write path to the developer and has no built-in CRDTs. A claim that Electric joined Databricks came from a search summary and is unverified.
- Lesson: the CRDT-in-triggers approach on user tables was found too invasive and was dropped.

### PowerSync
- Read path: service replicates Postgres into client SQLite by sync rules (buckets). Write path: a client upload queue sent to **your backend**, which stays authoritative. CRDTs are an application choice, such as Yjs blobs stored in a Postgres column ([comparison](https://powersync.com/blog/electricsql-vs-powersync)).
- Lesson: "store an opaque CRDT blob, merge in the client" is an accepted pattern. It maps to pg_crdt's store-and-relay option.

### Zero (Rocicorp)
- Resolves conflicts by server reconciliation (clients apply mutations optimistically, the server replays authoritative mutators); no CRDTs. The page I fetched states only "server reconciliation" ([docs](https://zero.rocicorp.dev/docs/sync)). Row/column granularity and Postgres replication details are unverified.
- Lesson: for many apps, authoritative server mutators are enough, and CRDTs are only needed for offline multi-writer data.

### Riak DT
- A library of state-based CRDTs in Erlang. The old database code is archived in a `prototype` branch and the repo is "a reusable library of QuickCheck tested implementations" ([README](https://github.com/basho/riak_dt)). Type list and delta support are unverified in my fetch. From memory: gcounter, pncounter, orswot (add-wins with a version vector, the same as variant 2 above), lwwreg and map (unverified).
- Lesson: QuickCheck-style property tests for each type are the norm. Matches the brief's property-test requirement.

### Redis Enterprise Active-Active
- Per [Redis docs](https://redis.io/active-active/) and secondary sources: vector clocks per object, counters sum increments, sets are add-wins, strings fall back to LWW by timestamp. The JSON docs use per-command "wins over" rules with the smaller instance ID winning some ties. Merge happens in the database on each instance.
- Lesson: expose the conflict policy per type in the name and docs. Redis maps familiar types onto CRDT semantics instead of a new vocabulary.

### AntidoteDB
- Geo-replicated key-value store built on CRDTs with "highly available transactions" ([repo](https://github.com/AntidoteDB/antidote), Apache-2.0, Erlang, not archived). Specific types and vector-clock details were not on the fetched page (unverified). From memory: counters, add-wins and remove-wins sets, LWW and multi-value registers, and maps.

### Ditto
- Documents are CRDT maps. A REGISTER is LWW and a MAP is add-wins; concurrent updates to different keys are both kept; the winning write is picked by an HLC timestamp ([glossary](https://docs.ditto.live/home/glossary), [types](https://docs.ditto.live/dql/types-and-definitions)). A [2023 Ditto blog](https://ditto.live/blog/dittos-delta-state-crdts) describes delta-state CRDTs with version vectors and tombstones; it predates the current design.
- Lesson: per-field LWW with HLC is the pragmatic default for document data.

### Couchbase Lite / Sync Gateway
- Not CRDTs. Revision trees with conflict detection and a resolver. Sync Gateway 4.0+ defaults to last-write-wins; Enterprise Edition allows a custom resolver ([docs](https://docs.couchbase.com/sync-gateway/current/conflict-resolution.html)). Older docs said "most revisions wins".
- Lesson: users do want a hook for custom resolution. A "register keeps all concurrent values" type (MV-Register) is the CRDT equivalent.

### Naming and API conventions observed
- cr-sqlite: `crsql_*` prefix, a changes virtual table as the sync interface, `site_id` for replica identity.
- supabase/pg_crdt: `automerge` schema, `get_/put_` accessors, implicit casts to jsonb.
- pg_crdt brief: `crdt.<family>_<verb>` (`pn_increment`, `set_add`, `register_set`) with `_merge`, `_value`. Consistent with common practice: pure functions over a state value.
- Replica identity everywhere is an opaque unique ID: a random 128-bit `site_id` (cr-sqlite), a random 53-bit client ID (Yjs), actor IDs (Automerge). pg_crdt takes it as a text argument.

## 5. Sync protocols and what plain SQL can do

| Protocol | Summary | Needs in SQL |
|---|---|---|
| Yjs | SyncStep1 = state vector, SyncStep2 = diff update + delete set, then incremental Updates | Parsing updates to compute a diff: not realistic (see below) |
| Automerge | per-peer state; heads + Bloom filters of change hashes; loop until quiescent | SHA-256 change hashes (available as `sha256()`), Bloom filters, per-peer state tables. Possible but heavy, and tied to the opaque format |
| Delta-state anti-entropy ([Almeida et al.](https://arxiv.org/abs/1603.01529)) | Ship delta groups; track per-neighbour acks; fall back to full state | Per-neighbour ack tables in SQL: feasible |
| cr-sqlite | pull changes with `db_version > last_seen` per peer | Trivially SQL |

What is achievable with plain SQL functions:
- **Whole-state sync:** `merge(a, b)` on full states. Always works; cost is state size.
- **Version-vector diff over rows:** if state is stored as rows with `(replica, seq)` identity (event log, sequence items, change rows), then `diff` is a SQL query `WHERE seq > vv[replica]`. The version vector is computed with `SELECT replica, max(seq) ... GROUP BY replica`. This covers a Yjs-like "state vector -> missing items" exchange without the Yjs format. It requires per-replica contiguity (no gaps). Enforce it by rejecting out-of-order inserts or by parking them until parents arrive.
- **Counter and LWW diffs:** the state is small enough to ship whole. For the counter, `diff(S, remote)` = entries with a strictly greater value than the remote's.
- **OR-Set diff:** needs the dot-cloud context described in section 3 to be correct. Defer.
- **Monotonic cursor:** an append-only log table with a server-assigned `bigserial` position gives "everything since N" with no CRDT knowledge. It fits Realtime and logical replication directly (inserts carry only the new row, not the whole document).
- Not achievable without a library: Yjs diff of an opaque blob, Automerge's Bloom filter negotiation on opaque Automerge documents.

## 6. Documents: PL/pgSQL feasibility

### (a) Can PL/pgSQL parse or produce Yjs v1 or Automerge?
- **Automerge:** no. Chunk checksums, columnar RLE/delta/boolean encodings, optional DEFLATE, hash verification by topological traversal, and a spec that defers to the Rust implementation.
- **Loro:** no. postcard plus `serde_columnar` plus LZ4, and a format pinned to library versions.
- **Diamond Types:** the format is unstable and its parser is not a good basis.
- **Yjs v1:** *parsing* is feasible (varints and strings in `bytea` with `get_byte` loops). But even reading it is not the point. To merge or diff, the server would also need YATA integration, pending-struct handling, delete-set coalescing, and UTF-16 length handling. Bugs would corrupt documents silently, because clients trust the server's updates to be valid Yjs.
- **Conclusion: treat document updates as opaque `bytea`.** The server stores and relays. It never inspects the payload.

What opaque store-and-relay looks like (my design, unverified against any production system; I believe this resembles common Yjs persistence setups):
- `crdt_doc_update(doc_id, pos bigserial, origin text, update bytea, created_at)`, insert-only.
- A client fetches `WHERE pos > :last_pos`. Clients merge locally with Yjs/Automerge/Loro. Server `pos` replaces the state-vector exchange (the server cannot compute a state vector from blobs).
- Compaction: a client uploads a full snapshot plus the highest `pos` it covered; the server deletes covered rows. This trusts clients and is not convergence-safe if the snapshot misses updates the client had not seen. Guard with "snapshot declares `covers_up_to = N`, server verifies it is >= its own known `pos` set when compacting", or leave compaction manual.
- Bonus: the same table works for any library, so it needs no format commitment.

### (b) Simplest correct sequence CRDT to implement relationally
All three are "grow-only set of rows plus a derived order", so **merge is union** (`INSERT ... ON CONFLICT DO NOTHING`), and only the *render* step differs.

**RGA (replicated growable array).** Each item has a unique timestamp ID and a reference to the item it was inserted after. Concurrent inserts after the same item are ordered by descending ID. Order is a tree pre-order. Weakness: [Fugue paper Table 1](https://arxiv.org/abs/2305.00583) shows RGA has no forward interleaving but does interleave backward insertions.

**Fugue** ([Weidner and Kleppmann](https://arxiv.org/abs/2305.00583), verified from the HTML version): a tree where each node has `(id, value, parent id, side L or R)`. Order is an in-order traversal: left children (siblings ordered by ID), the node, then right children. Insert after element `x`: if `x` has no right children, the new node is `x`'s right child; otherwise it is a left child of the next element in traversal order. Deleted nodes become tombstones but stay in the tree. Fugue is proven to minimise interleaving (FugueMax gets "maximal non-interleaving").

**Eg-walker event graph** (above): store original index-based operations plus parents. Render needs the replay algorithm.

| | Item rows (RGA/Fugue) | Event graph (Eg-walker) |
|---|---|---|
| Merge | union of rows | union of rows |
| Render text | one ordered query (recursive CTE) | replay with temporary CRDT state, hard in SQL |
| Local edit needs | position -> parent ID, so a render or cached index | none server-side, since the client sends `(pos, parents)` |
| Metadata per char | id, parent, side (about 3 refs) | id, parents, pos |
| Delete | monotone flag or separate delete set | a delete event |
| Wire compat | none (bespoke) | event shape is library-neutral, but the Diamond Types file format is unstable |
| Port effort | small | large |

**Recommended relational sequence design (if native text is wanted): Fugue, row-per-item.**

```
crdt_seq_item(
  doc_id, agent text, seq int,            -- primary key (doc_id, agent, seq)
  parent_agent text, parent_seq int,      -- null = root
  side char(1) check in ('L','R'),
  value text,                             -- one char, or a run
  deleted bool default false              -- monotone, merge by OR
)
```

- Document order is a depth-first in-order traversal, computed with `WITH RECURSIVE`, ordering by an array path of `(side_rank, agent, seq)` per ancestor. Left children rank before a node's own marker, right children after.
- Version vector for sync: `SELECT agent, max(seq) ... GROUP BY agent`. Diff is `WHERE seq > vv[agent]`.
- Known costs: typing forward builds a right-child chain of depth equal to the text length, so a recursive CTE iterates once per character. Real implementations store runs (Yjs, Diamond Types, Automerge all do run-length encoding). Runs require splitting a row when someone inserts into the middle, which complicates the PL/pgSQL. A per-doc cached rendering would be needed for any large document. I did not benchmark this.
- Position-to-ID lookup for local edits needs the render, so a client-side library should choose the parent IDs and send items. This makes the native type something a custom client must implement. It is not interoperable with Yjs clients.

**Event-graph table layout (alternative):**

```
crdt_event(doc_id, agent, seq, parents jsonb,   -- [[agent, seq], ...]
           kind char(1),                         -- 'i' | 'd'
           pos int, content text)
```
Text is derived only by a replay function. Server can still validate that parents exist and answer diffs by version vector. Cached text keyed by frontier is the paper's own "cached final state" optimisation.

## Implications for pg_crdt

### Algorithm variants
| Family | Use | Why |
|---|---|---|
| PN-Counter | per-replica `{p, n}` maps, per-key max merge | exactly as briefed; document the single-writer-per-replica-ID rule |
| Set | optimised add-wins set: element -> dots, plus version-vector context; keep the two-set Shapiro OR-Set as a test oracle | no tombstones, short merge; matches "observed remove" semantics and handles concurrent remove and re-add |
| Register | LWW with `(hlc, replica)` order, HLC derived from the state being overwritten; final tie-break on canonical value text | causality preserved for sequential writers, O(1) state, deterministic |
| Multi-value register | same dot kernel as the set | low marginal cost; gives a "keep conflicts" option |
| Map | LWW-Map (per-key LWW with tombstone values) first; OR-Map later on the dot kernel | flat, composes with registers; mirrors cr-sqlite and Ditto |
| Row-level API (later) | cr-sqlite-style change table | merge is plain SQL, sync is `db_version >` cursor |

Write one dot-kernel merge function and reuse it for the set, MV-register and OR-Map. Full-state exchange is the MVP. Real deltas for the set need the dot-cloud context and should be a later, separate decision. Do not garbage-collect tombstones or counter entries.

### Collaborative documents
- **Do not adapt Yjs, Automerge, Loro or Diamond Types.** None can run in PL/pgSQL, and none of their formats is realistic to parse or produce there. Automerge's spec defers to Rust, Loro's format needs LZ4 and columnar postcard, Diamond Types' format is unstable, and Yjs needs YATA integration to be safe.
- **Phase 2a (recommended): store-and-relay.** An insert-only update log table with an opaque `bytea` payload and a server-assigned position cursor. It works for every client library, adds no format commitment, and keeps WAL proportional to the edit (the main lesson of supabase/pg_crdt). Clients merge. Compaction is client-driven snapshots with an explicit covers-up-to position.
- **Phase 2b (optional, only if server-readable text is required):** a Fugue row-per-item table with union merge and a recursive-CTE render. This is simpler than Eg-walker. It will need run-length rows and a cached render to be usable beyond small documents, and it is bespoke (no existing client speaks it).
- **Eg-walker:** write up as a proposal. A store-and-relay event table (id, parents, op) is cheap if a client library speaks it, but the replay algorithm should be deferred. The reference implementation is about 1,600 lines of TypeScript built on mutable ordered arrays, which fit SQL poorly.
- Open question: whether Phase 2a should also offer a typed text API (`document_text`) at all. Without a library the server cannot derive text from opaque updates, so the proposed API would return the log, not text.

### Binary formats worth compat with
- **None at the storage layer for the MVP.** Use versioned jsonb (`{"v":1,"t":"pn", ...}`) for counters, sets, registers and maps. The brief says treat serialization as a versioned interface, and jsonb keeps merges writable in PL/pgSQL.
- **Treat Yjs update v1 as an opaque payload**, not a parsed format. Optionally, store alongside each update a client-supplied state vector (not validated by the server).
- **Do not target** Automerge, Loro or Diamond Types binary formats.
- Keep the **cr-sqlite changeset shape** (`table, pk, cid, val, col_version, db_version, site_id, cl, seq`) in mind if a row-level API is added. Compatibility with its wire format is not needed, but the shape is a proven target.

### Open questions
1. Should the first public types be jsonb values only, or a pg_tle `create_base_type` (stored as `bytea`, with I/O functions in the trusted language)? Operators like `||` then need `create_operator_func`. Not tested here.
2. Is Phase 2b (native Fugue text) in scope, or is Phase 2a plus a proposal enough?
3. Compaction for the update log: who is trusted to say a snapshot covers position N?
4. How are replica IDs assigned for server-side writes (session, user, device)? This is the main correctness hazard for counters.
5. Benchmarks are missing: jsonb merge cost at large set sizes, WAL amplification per update, recursive-CTE render time for 10k and 100k characters. None were run in this research.
