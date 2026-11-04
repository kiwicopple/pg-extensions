# pg_crdt: Architecture options and recommendation

> Status: proposal, 2026-11-04. Synthesised from [`runtimes.md`](./runtimes.md), [`prior-art.md`](./prior-art.md) and [`sql-integration.md`](./sql-integration.md). Nothing here is benchmarked yet. Every performance claim is a hypothesis for the benchmark plan at the end.

## Constraints (fixed)

- **PL/pgSQL and SQL only.** No plv8, PL/Rust, C or WASM. This rules out reusing Yjs, Automerge, Loro or Diamond Types code inside Postgres. They are design references only.
- **Installable via pg_tle**, and also as a plain migration (one SQL file), so it runs on providers without pg_tle (Neon, Cloud SQL, AlloyDB, Azure). See `runtimes.md`, provider matrix.
- **Per-type namespacing**, so new CRDT types can be added without name collisions (user requirement, mirroring pg_permissions).
- **One blessed path per job, a small set of selectable types, no generality a use case does not need.**

## 1. Namespacing

### What pg_permissions actually does

pg_permissions does not use a schema per model. It has **one reserved schema** (`permissions`). Each model is a **name prefix** inside it: `rbac_*`, `fga_*`, `cedar_*`. Shared functions have no prefix, and internals start with `_`. See `sql-integration.md`, Part A, for file:line pointers.

### Recommendation: one `crdt` schema, one prefix per CRDT *variant*

The prefix must name the **algorithm variant**, not the family. pg_permissions prefixes `rbac`/`fga`/`cedar`, which are models, not "permission". If we use `set_` and `register_` (as in `prompt.md`), the second set or register variant has no name. LWW and MV registers merge differently. Add-wins and remove-wins sets merge differently.

| Prefix | Type | Phase |
| --- | --- | --- |
| `pn_` | PN-Counter | 1 |
| `awset_` | Add-wins observed-remove set (optimised, dots + causal context) | 1 |
| `lww_` | Last-writer-wins register | 1 |
| `lwwmap_` | LWW map (key → LWW register) | 1b |
| `mv_` | Multi-value register | later |
| `ormap_` | Observed-remove map | later |
| `doclog_` | Opaque document update log (store-and-relay) | 2a |
| `fugue_` | Native sequence/text CRDT in tables | 2b, experiment |
| `_` | Internal helpers (for example a shared dot-kernel merge) | n/a |

**Decided (2026-11-04):** one `crdt` schema, prefixes named after the specific algorithm. Exact spelling (`awset_`, `lww_`, ...) as in this table unless changed before the first release, because renaming later is a breaking change.

Every variant has the same verb set, so the API is predictable:

```sql
-- shape: crdt.<variant>_<verb>
select crdt.pn_empty();
select crdt.pn_increment(state, replica_id, 5);
select crdt.pn_decrement(state, replica_id, 2);
select crdt.pn_value(state);           -- bigint
select crdt.pn_merge(a, b);
select crdt.pn_merge_agg(state) from deltas;   -- aggregate

select crdt.awset_add(state, 'user_123', replica_id);
select crdt.awset_remove(state, 'user_123');
select crdt.awset_values(state);       -- setof / jsonb array
select crdt.awset_contains(state, 'user_123');
select crdt.awset_merge(a, b);

select crdt.lww_set(state, '"hello"'::jsonb, replica_id);
select crdt.lww_value(state);
select crdt.lww_merge(a, b);
```

Per-variant `_merge` is the only merge API. **Decided (2026-11-04): no generic `crdt.merge(a, b)` dispatcher for now.** It would add a dispatch branch to every call and make type errors happen at run time. Revisit later if there is demand.

Rejected alternatives, from `sql-integration.md`:
- **Schema per type** (`crdt_pn.increment`). More grants, more PostgREST `db-schemas` entries, more reserved names, and creating several schemas under pg_tle is unverified.
- **Core schema plus per-type schemas.** The same costs, for no gain over prefixes.

## 2. Representation

**Decision: `jsonb` with a versioned envelope.** Both the runtimes and the SQL integration research arrive here independently.

```json
{"t": "pn", "v": 1, "p": {"replica_a": 5}, "n": {"replica_b": 2}}
```

- `t` is the variant and `v` the format version. Every function checks `t`, and merge upgrades older `v` (the upgrade must commute with merge).
- **Domain per variant (decided)** (`crdt.pn` as a domain over jsonb, whose CHECK validates the envelope: `t`, `v`, and `p`/`n` objects. Per-entry validation is in `crdt.pn_is_valid`, which `pn_apply_delta` enforces, because a full check costs about 4 ms at 10k replicas). It gives readable column types and a cheap guard. It does **not** enable operators: a domain resolves as its base type, so there is no `||` merge operator. Merge is function-only. Settled by tests: plain jsonb coerces to the domain without an explicit cast.
- **Custom base type: rejected for the MVP.** pg_tle allows PL/pgSQL I/O functions, but the type is bytea-backed with no send/recv and no typmod. A btree/hash opclass needs superuser on most providers, which breaks `=`, `GROUP BY` and `DISTINCT`. I/O and operator functions cannot be replaced in upgrade scripts. It costs availability and patchability, and it only buys syntax.
- **bytea: rejected for state.** PL/pgSQL has no good binary tooling, and the JSON shape works with PostgREST and Realtime as it is. bytea is right only for the opaque document update log.

## 3. CRDT variants (phase 1)

From `prior-art.md`. All are state-based, with full-state exchange. Deltas are a later optimisation, and there is **no tombstone GC** in the MVP, so disconnected replicas never break convergence.

| Variant | State | Merge | Notes |
| --- | --- | --- | --- |
| `pn_` | `p`, `n`: map replica → bigint | per-key max on each map | Requires exactly one writer per replica id |
| `awset_` | element → set of dots; causal context = version vector | standard optimised OR-set join | Keep the naive two-set OR-set as the **test oracle** for property tests |
| `lww_` | value + HLC + replica id | larger (hlc, replica, canonical value text) wins | HLC is derived from the state being overwritten, so a write always beats what it saw. Document the skew limits |

Pitfall to test for (derived in `prior-art.md`, not from a paper): a set *delta* that filters entries but ships the full causal context deletes data on merge. If we add deltas, they need a dot-cloud context. Full-state merge avoids this.

## 4. Write path and concurrency

- **Safe pattern:** a single statement, `update t set s = crdt.X_merge(s, $1) where id = $2`, or `insert ... on conflict do update set s = crdt.X_merge(t.s, excluded.s)`. Under READ COMMITTED the second writer waits on the row lock and re-evaluates against the new row version.
- **Unsafe:** the client reads, merges locally and writes back. Also unsafe: SET expressions that read other rows (subquery or `update ... from`). Document this prominently.
- REPEATABLE READ and SERIALIZABLE raise 40001, and the client must retry.
- **Two storage shapes**, to be measured against each other:
  1. *State column.* Simple, but every merge rewrites the whole TOASTed value, so WAL and Realtime payloads scale with state size.
  2. *Delta table plus `X_merge_agg`.* Insert-only, so WAL is O(delta). Read cost is an aggregate, plus periodic compaction into a snapshot row.
- **OrioleDB** ([`orioledb.md`](./orioledb.md)): stay storage-agnostic, and document it as an optional accelerator. It removes bloat, vacuum and full-page writes, but a changed jsonb value is still fully rewritten and WAL-logged, and Realtime payloads are unchanged. It does not change which storage shape wins. Add it to benchmarks later (heap vs OrioleDB, 1 kB to 1 MB states).

## 5. Security

Row-level security cannot see inside a CRDT value. A writer that can update the column can forge another replica's counter entry or tags. The blessed path:

- Revoke direct UPDATE on state columns from writers.
- The app writes SECURITY DEFINER wrappers around a validating merge per variant (`crdt.pn_apply_delta(state, delta, replica)`), which checks that a delta touches only entries owned by `replica` (the id, or `<id>:<device>`; `:` is reserved in ids). Stale entries are a no-op, so retries succeed.
- **Identity is pluggable** (decided in session 3). The wrapper passes whatever identity the app trusts: `session_user` for direct SQL clients, a lookup in its own users table, a JWT claim, or a platform helper such as Supabase's `auth.uid()::text`. The default argument, `crdt.current_replica_id()`, reads a JWT claim from `request.jwt.claims` (the PostgREST convention; claim configurable with `crdt.replica_id_claim`, default `sub`), then the `crdt.replica_id` setting that app servers and server-side jobs set with `SET LOCAL`. Any role can set those settings, so the default is safe only for writers that cannot run their own SQL.
- pg_crdt assumes no platform: no UUID ids, no `auth` schema, no Supabase roles.

## 6. Integration notes

- **Realtime:** `postgres_changes` payloads are capped at 1 MB, and above that, columns over 64 bytes are dropped. Treat events as "row changed" and refetch.
- **PostgREST:** jsonb state works over plain REST. Apply functions are RPCs.
- **Indexing:** expose `X_value` as IMMUTABLE so it works in generated columns and expression indexes.
- **Functions:** use `LANGUAGE sql` for small accessors (inlinable: single SELECT, no FROM, no `SET` clause). Use PL/pgSQL for validation and control flow. Write merges as one set-based statement, never a `jsonb_set` loop. Mark pure functions `IMMUTABLE PARALLEL SAFE`.

## 7. Collaborative documents

- **Phase 2a, `doclog_`: store-and-relay.** An insert-only table of opaque `bytea` updates (Yjs or Automerge, whatever the client uses), with a server-assigned position cursor. Clients sync with "give me updates after position N". Compaction is client-driven (a client uploads a snapshot that covers positions up to N). Open question: who is trusted to declare that coverage. The server never parses the format, so no format compatibility is needed.
- **Phase 2b, `fugue_`: experiment only.** A row-per-item (later run-length) Fugue table with union merge and a recursive-CTE render. Do this only if server-readable text is a real requirement. Measure the size ceiling first.
- **Eg-walker:** a written proposal only. Merge is event-graph union (so 2a already stores what it needs), but replay to text in PL/pgSQL is the hard part.

## 8. Plan

1. **Spec first** (as in pg_permissions): property tests for commutativity, associativity, idempotence, convergence under shuffled and duplicated delivery, and round-trip, per variant.
2. **Vertical slice: `pn_` end to end.** Envelope, functions, aggregate, optional domain, apply function for untrusted writers, tests, pg_tle install plus a plain migration install.
3. Benchmark the two storage shapes and SQL vs PL/pgSQL merge for `pn_`, before writing `awset_`.
4. `awset_` (with the oracle), then `lww_`, then `lwwmap_`.
5. `doclog_`.

### Benchmarks to run

- Merge latency vs state size (replicas, elements): SQL vs PL/pgSQL.
- WAL bytes per merge: state column vs delta table.
- State growth over N operations, including the set with churn (no GC).
- Domain over jsonb vs plain jsonb overhead.

## Decisions needed from the user

1. ~~Prefix naming per variant~~: decided, yes.
2. ~~Generic `crdt.merge` dispatcher~~: decided, not now.
3. ~~Server-readable text~~: decided, yes. Every type is server-readable where possible, so values can be indexed. Opaque types like `doclog_` are deferred, not ruled out.
4. ~~Domain vs plain jsonb~~: decided, a domain per type (for example `crdt.pn`), as part of the extension's value. Mitigate the drop risk in the docs. Test the cast and overload behaviour in the first slice.
