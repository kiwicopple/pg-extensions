# pg_crdt: SQL API shape and Postgres integration

Research notes. Claims marked **(unverified)** come from memory or inference and were not confirmed against a source in this session.

## Part A: namespacing, following pg_permissions

### What pg_permissions does

One schema for the whole extension, a prefix per model inside it, and no prefix for functions shared by all models.

| Aspect | Convention | Pointer |
|---|---|---|
| Schema | A single reserved schema, `permissions`. There is no schema per model. | `pg_permissions/pg_permissions--0.1.0.sql:32`; `pg_permissions/research/decision.md:63` |
| Per-model names | Tables and functions carry the model prefix: `rbac_*`, `fga_*`, `cedar_*`. Counts of functions in the SQL file: 14 `fga`, 14 `cedar`, 9 `rbac`. | `decision.md:27` (per-model table sets), `decision.md:63`, `:107-110` |
| Shared functions | No prefix: `current_subject_id`, `current_subject_type`, `delete_subject`. Rule: "A prefix means a function for one model. No prefix means a function for both models." | `decision.md:107-110` |
| Internal | A leading `_` marks an internal function, for example `permissions._unfolded_null()`. It is still granted to public, so `_` is a naming signal, not an access control. | `decision.md:111`; grant at `pg_permissions--0.1.0.sql:10744-10760` |
| Parameter names | No `p_` prefix. One shared vocabulary, so named notation (`name => value`) reads well. | `decision.md:113-114` |
| Selecting a model | There is no switch. The app calls the functions of the model it wants. Models compose through RLS (permissive policies OR, restrictive AND). Adding a model is the "graduation path". | `decision.md:27-33` |
| Schema ownership check | An existing `permissions` schema must belong to the installer or a superuser, and nobody else may have CREATE on it. | `pg_permissions--0.1.0.sql:34-57` |
| Grants | Revoke all on tables and functions in the schema from public, strip inherited default grants, then `grant usage on schema ... to public` and grant execute on a short list of client-facing functions (the `*_current` functions, `rbac_has_*`). Writes are admin-only. | `pg_permissions--0.1.0.sql:10722-10760`; `decision.md:311` |
| search_path | Every function that sets `search_path` sets `pg_catalog, pg_temp`. | `pg_permissions--0.1.0.sql:59-` (comment block) |
| Install | `create extension pg_permissions;` without `with schema`. The file creates the schema itself. Calls are `permissions.name(...)`. Installs as a non-superuser under pg_tle (tested on PG 16-18, pg_tle 1.5.3). Install through database.dev was not tested. | `pg_permissions/docs/install.md:50, 87`; `decision.md:344`; `pg_permissions.control` (`superuser = false`) |

Recorded rationale for per-model prefixes in one schema (`decision.md:27-33`): each model follows its own spec and is optimised for itself, models are first-class rather than wrappers over a core, and a generic layer made following spec updates hard. The earlier single generic API was dropped because the same API carried different semantics per model. The schema name question (Q10) was settled with "schema `permissions`, prefixes `rbac_*` and `fga_*`" (`decision.md:63, 311`).

The decision record contains no discussion of schema-per-model, so the "why one schema" part is inferred: a single schema is one install unit, one grant surface and one name to expose. **(unverified inference)**

### Options for pg_crdt

The brief uses `crdt.pn_increment(...)`, `crdt.set_add(...)` (`pg_crdt/research/prompt.md`), which is already the single-schema-with-prefix shape.

**Option 1: one schema, type prefix (matches pg_permissions).**

```sql
select crdt.pn_increment(crdt.pn_empty(), 'replica_a', 5);
select crdt.pn_value(s), crdt.pn_merge(a, b);
select crdt.set_add(crdt.set_empty(), 'x', 'tag1');
select crdt.reg_set(crdt.reg_empty(), 'v', ts, 'replica_a');   -- LWW register
select crdt.doc_set(crdt.doc_empty(), '{profile,name}', '"Ann"', 'replica_a');
select crdt.merge(a, b);   -- shared, dispatches on the version/kind field
```

**Option 2: schema per type.**

```sql
select crdt_pn.increment(crdt_pn.empty(), 'replica_a', 5);
select crdt_set.add(crdt_set.empty(), 'x', 'tag1');
select crdt_doc.set(crdt_doc.empty(), '{profile,name}', '"Ann"', 'replica_a');
```

**Option 3: shared core schema plus per-type schemas.**

```sql
select crdt.merge(a, b);               -- core: dispatch, version, replica-id helpers
select crdt.replica_id();              -- core: derived from auth.uid()
select crdt_pn.increment(crdt.empty('pn'), 'replica_a', 5);
```

| Concern | 1. One schema + prefix | 2. Schema per type | 3. Core + per-type |
|---|---|---|---|
| Matches pg_permissions | Yes | No | No |
| Collisions between types | Prefix prevents it, enforced by convention only | Schema enforces it | Schema enforces it |
| Adding a type later | Add `xx_*` functions in the same schema. Upgrade script touches one schema. | New schema, new grants, new PostgREST config | Same as 2 |
| `search_path` ergonomics | Callers write `crdt.pn_value(...)`. Shorter names need `set search_path` and then risk clashes with other schemas. | Short names after `set search_path = crdt_pn`, but you can only put a few on the path | Mixed |
| PostgREST exposure | One entry in `db-schemas` exposes everything. Uses `Accept-Profile: crdt` when it is not the first schema. Exposing the whole schema also exposes internal `_` functions unless their EXECUTE is revoked. | One entry per type. Each needs USAGE. Requests for an unlisted schema return PGRST106. | Several entries |
| Grants and ownership check | One schema to lock down, as pg_permissions does at `:34-57` and `:10722-10760` | N schemas, N copies of the check | N+1 |
| pg_tle | One schema is the proven path (pg_permissions installs it with `create extension` as a non-superuser). | Extension SQL can create several schemas **(unverified under pg_tle; pg_permissions only creates one)**. Dropping and upgrading get fiddlier. | Same as 2 |
| dbdev packaging | One control file, one schema name to document. Schema name collisions with user schemas are one risk. | Reserves N names | Reserves N+1 names |
| Operators | Operators live in the schema of their functions, so `||` is schema-qualified at definition and found through `search_path` at use. The same applies to every option. See B4. | Same | Same |

### Recommendation

Option 1. One `crdt` schema, a short prefix per type (`pn_`, `gc_`, `set_`, `reg_`, `doc_`), `_` for internals, no prefix for functions that apply to every type (`crdt.merge`, `crdt.replica_id`, `crdt.state_version`). This is the pg_permissions rule applied directly, and it keeps one install unit, one grant block, one PostgREST schema entry and one pg_tle schema. Two points to settle before implementation: whether `crdt` is a safe schema name (pg_permissions reserved `permissions` the same way and refuses to install into a schema it does not trust), and whether a prefix rule such as `pn_`/`set_` is enough or the doc type should use `doc_` and `text_` from the start.

## Part B: Postgres integration

### B1. Lost updates

**Verdict.** `UPDATE t SET s = crdt.merge(s, $1) WHERE id = $2` is safe under READ COMMITTED, and also safe when `$1` is a parameter or a column of the same row. It is not safe if the merge input is derived from a read made in an earlier statement of the same transaction and applied by overwrite, nor if `s` is read through a subquery or another table.

Why it works. Under READ COMMITTED the second updater waits on the row lock. When the first commits, "the second updater ... will attempt to apply its operation to the updated version of the row", and the WHERE clause is re-evaluated against that version ([PostgreSQL: Transaction Isolation](https://www.postgresql.org/docs/current/transaction-iso.html)). The docs' own example is `UPDATE accounts SET balance = balance + 100.00 WHERE acctnum = 12345;`, where the second statement "start[s] with the updated version of the account's row". The page does not state explicitly that SET expressions are recomputed from the new row version. It is implied by the example, and this is how the executor behaves in practice (it re-runs the projection in EvalPlanQual) **(unverified against source in this session)**. Because merge is commutative, associative and idempotent, the result is the same whichever order the two statements apply.

Hazards named by the same page: "it is possible for an updating command to see an inconsistent snapshot: it can see the effects of concurrent updating commands on the same rows it is trying to update, but it does not see effects of those commands on other rows." So anything in SET that reads other rows (a subquery, `UPDATE ... FROM`) sees the statement's snapshot, not the latest committed data. Merge in SET must only use the row's own column and parameters.

| Pattern | READ COMMITTED | REPEATABLE READ / SERIALIZABLE |
|---|---|---|
| Single `UPDATE ... SET s = merge(s, $1)` | Safe (above) | Concurrent update raises 40001 (`could not serialize access due to concurrent update`). Client must retry. **(unverified in this session; standard documented behaviour)** |
| `INSERT ... ON CONFLICT (id) DO UPDATE SET s = merge(t.s, excluded.s)` | Safe, atomic upsert **(unverified in this session)** | 40001 on conflict with a concurrent change. Retry. |
| Client reads `s`, merges locally, writes the whole result | Lost update: it overwrites a concurrent change. Safe only with `SELECT ... FOR UPDATE` in the same transaction (the lock holds the row until commit) or optimistic version check. | Same code raises 40001 and works with retry. |
| `SELECT ... FOR UPDATE` then `UPDATE` | Safe, serialises writers. Costs lock waits. | Serialization failure if the row changed since the snapshot. |
| Merge done in a trigger on a different table | Beware: reads of other tables in the trigger see statement snapshot. | |

Rule to state in docs: always merge in the `SET`, never in the client. A client that wants to merge locally for offline use must still send its state or delta to the server as a parameter of the merge, not as a replacement value.

### B2. Representation

| | jsonb | bytea | Domain over jsonb | pg_tle base type |
|---|---|---|---|---|
| PostgREST in/out | Native JSON, readable, usable as filters (`s->>...`) | Hex string (`\x...`) in JSON, no filtering | As jsonb, plus constraint checks | Text via the type's I/O function (stored internally as bytea per pg_tle docs). Needs a cast for JSON. |
| Compactness | Larger. Keys repeat, numbers are numeric. | Smallest | As jsonb | As bytea |
| Validation | `CHECK` constraint calling a validator | Same | Domain `CHECK` runs on every cast and insert (cost) | I/O function validates on input |
| Install via pg_tle | Trivial | Trivial | Trivial | Requires `pgtle_admin`, `create_shell_type`/`create_base_type`, IMMUTABLE STRICT I/O functions; `=` needs an operator class or equality is byte-wise ([pg_tle datatypes doc](https://github.com/aws/pg_tle/blob/main/docs/09_datatypes.md)) |
| Operator overloading | On jsonb itself `||` already exists with different semantics, so overloading is impossible. A domain does not get its own operator resolution: domain operands resolve to the base type's operators. So `||` on a domain over jsonb is jsonb concatenation. | Same, `||` is bytea concat | Same | A new type can own `||` |

Consequence: a custom `||` merge operator requires a distinct type. With jsonb or a domain over it, the operator would need another symbol, or merge should be function-only. **(operator-resolution-on-domains claim is from memory, unverified in this session)**

Under the PL/pgSQL-only rule (B2a), jsonb is the default. Start with jsonb for the first stages: human-readable, works through PostgREST and Realtime, inspectable by tests. Keep the type behind a wrapper domain so a later move to bytea or a base type changes one definition. A base type is attractive for operators and strict validation but costs `pgtle_admin`, and pg_tle documents no binary send/receive for it **(page silent)**.

**Realtime.** Per [Supabase Realtime limits](https://supabase.com/docs/guides/realtime/limits): `postgres_changes` payload max is 1,024 KB on all plans. Broadcast max is 256 KB (free) or 3,000 KB (paid). If a `postgres_changes` payload exceeds the limit, `new` and `old` include only fields whose values are 64 bytes or less, so a large CRDT state column would be omitted and clients must refetch. Practical consequence: Realtime should signal "row changed" (id, version) and clients fetch or merge the state with a query, or the app broadcasts small deltas.

**Logical replication.** Updates need a replica identity, the primary key by default, FULL logs the whole old row ([PostgreSQL: Logical Replication Publication](https://www.postgresql.org/docs/current/logical-replication-publication.html)). Use the primary key so the old CRDT state is not logged each update. For unchanged TOASTed columns, pgoutput sends an "unchanged TOAST" marker instead of the value **(from memory, the fetched page did not cover it; verify in the message-format docs)**. A merge that changes the column sends the full new value.

**Indexing the materialised value.** Store the CRDT state in one column and derive queryable values separately. A generated column (`generated always as (crdt.pn_value(state)) stored`) needs the function to be IMMUTABLE and the generated column recomputes on each update **(generated-column requirements from memory, unverified)**. Expression indexes have the same IMMUTABLE requirement. Merge and value functions that depend only on their arguments can honestly be IMMUTABLE. Mark them `PARALLEL SAFE` too. Alternatives: a trigger that maintains a plain `value` column, or a materialised view for read-heavy aggregates. `STRICT`: decide how NULL states merge (a NULL state should usually mean "empty").

### B2a. Constraint: PL/pgSQL and SQL only (no plv8, PL/Rust, C)

Scope decision from the user: all code is PL/pgSQL or LANGUAGE sql.

- **pg_tle base types do not need C.** The pg_tle docs say it lets you write support functions in a trusted language "in place of" C, and their examples use SQL and PL/pgSQL for I/O and operator functions ([pg_tle datatypes doc](https://github.com/aws/pg_tle/blob/main/docs/09_datatypes.md)). The type is stored as bytea internally, so the I/O function converts text to bytea and back. So a base type is possible without C, but it needs `pgtle_admin`, IMMUTABLE STRICT I/O functions, and every input and output call runs PL/pgSQL (slow per call, **unmeasured**). Binary send/receive is not covered by the page, so binary-protocol clients get text. The doc does not say whether a given managed host allows base types, only that pg_tle 1.1.1 or later supports them.
- **Default for the PL/pgSQL-only build:** plain `jsonb` (stage 1), optionally behind a domain over jsonb for a `CHECK` validator and a stable type name. A domain does not change operator resolution (B2), so merge is function-only: `crdt.merge(a, b)`, `crdt.merge_agg`. Keep bytea and a base type as later options if measurement shows jsonb size or parse cost matters. bytea is awkward without C because PL/pgSQL has no efficient byte-level manipulation beyond `get_byte`, `set_byte`, `substring`, so merging a binary state means decoding to jsonb or arrays anyway **(inference)**.
- **Inlining.** The planner inlines only simple LANGUAGE sql functions (single SELECT, not volatile, not SECURITY DEFINER, no SET clause, among other conditions) **(from memory of the inlining rules in `inline_function`; unverified here)**. PL/pgSQL functions are never inlined: each call has a function-call and plan-cache overhead. Consequences:
  - Cheap accessors and projections should be LANGUAGE sql IMMUTABLE PARALLEL SAFE: `pn_value(s)` (`select coalesce(sum(value::bigint),0) from jsonb_each_text(s->'p')` minus the same for `n`) and `crdt.state_version(s)`. This lets them be used in expression indexes and generated columns, and the planner may fold them.
  - A merge of jsonb maps can be written in pure SQL with `jsonb_object_agg` over a `full join` of `jsonb_each` and `greatest` (counter) or union of arrays (set), so `pn_merge` and `merge_agg`'s transition function can be LANGUAGE sql. Whether it beats PL/pgSQL for merge needs a benchmark (merge is dominated by building the output jsonb, not call overhead). **Unmeasured.**
  - Use PL/pgSQL where there is control flow: dispatch on `t`, validation that raises errors with codes, the `SECURITY DEFINER` apply functions in B5, upgrade logic, loops over an op-log. Note a `SET search_path` clause on a function (needed for SECURITY DEFINER hardening) also prevents inlining, so the public SQL-callable accessors should stay invoker, schema-qualified, and without a SET clause.
  - Aggregates take function names, so `sfunc` and `combinefunc` can be sql functions without any other change.
- **Algorithm cost.** The document (sequence/text) CRDT with Eg-walker or Yjs-style structures is the case where PL/pgSQL-only will be slowest, as tree and sequence work is loop-heavy and runs per row. This stays as a risk to benchmark. It is outside this document's scope.

### B3. WAL and update amplification

Every merge produces a new row version with the whole state. If the state is TOASTed (rows wider than the 2 kB threshold), a changed value is compressed and rewritten out of line in full, while an unchanged one is not touched: "an UPDATE of a row with out-of-line values incurs no TOAST costs if none of the out-of-line values change" ([TOAST docs](https://www.postgresql.org/docs/current/storage-toast.html)). Since the CRDT column changes on every merge, it pays the full TOAST rewrite each time. Also old TOAST chunks become dead until VACUUM. Expect cost proportional to state size, not delta size. HOT updates need the new tuple on the same page and no changed indexed column. A state column in an expression index disqualifies HOT. If the state is out of line, the heap tuple is small, so HOT still works as long as the state itself is not indexed **(HOT interaction with TOAST is from memory, unverified)**. Choices: `ALTER COLUMN ... SET COMPRESSION lz4`, a `fillfactor` below 100 on the table, and `toast_tuple_target` adjustment ([TOAST docs](https://www.postgresql.org/docs/current/storage-toast.html)).

| Strategy | Write cost | Read cost | Notes |
|---|---|---|---|
| Whole-state column, `merge` in UPDATE | O(state) WAL per write | O(1) | Simplest. Fine for counters, small sets, small docs. |
| Op-log or delta table, append-only, compaction job | O(delta) WAL | Aggregate over deltas or read compacted snapshot plus tail | Fits incremental sync (goal 6). Compaction is a merge into a snapshot row followed by delete of folded deltas (needs causal context so that deletion is safe). |
| Delta rows plus `crdt.merge_agg(delta)` | O(delta) | Aggregate scan | Counter cells and set tags shard well. Can be parallel (B4). |
| Sharded state (one row per replica or per key) | Per-shard O(small) | Aggregate across shards | Reduces row contention. Merge by aggregation. |

Recommend: ship the whole-state column first, document the size ceiling, design the delta-table path as the second storage mode, measure both (the pg_permissions project's approach is to compare and measure).

### B4. Operators and aggregates

- **`||` operator.** Only possible on a distinct type (B2). On jsonb it already means concatenation. Offer `crdt.merge(a, b)` always, and add an operator only if a base type is adopted. If so, use a custom operator symbol is also an option, such as `<@>` or `+~` **(naming only, taste)**.
- **Aggregate.** `create aggregate crdt.merge_agg(jsonb) (sfunc = crdt.merge, stype = jsonb, combinefunc = crdt.merge, parallel = safe)`. The docs: parallel aggregation needs the aggregate itself marked `PARALLEL SAFE` ("the parallel-safety markings of the aggregate's support functions are not consulted by the planner, only the marking of the aggregate itself"). For a non-`internal` state type the combine function may be strict, and a NULL state is skipped and the other state is taken ([CREATE AGGREGATE](https://www.postgresql.org/docs/current/sql-createaggregate.html)). Strict merge as combine function therefore treats NULL as identity, which is the right CRDT meaning. Partial aggregates may be combined in any grouping and order, which is safe only because merge is commutative, associative and idempotent (the docs do not state this requirement. It is inference from the partial-aggregation model). Use no `INITCOND` or an `empty` state; with a NULL initial state a strict sfunc starts from the first input.
- **Equality.** On jsonb, `=` is semantic (key order does not matter), but two states can be logically equivalent and still differ (for example a counter with a zero entry vs without). Provide `crdt.equals(a, b)` that compares normalised or observable values, and a canonicalising function so property tests (`merge(a,b) = merge(b,a)`, idempotence, associativity) compare canonical forms. With a base type, `=` must be defined with an operator class and defaults to byte equality ([pg_tle datatypes doc](https://github.com/aws/pg_tle/blob/main/docs/09_datatypes.md)).

### B5. RLS and forged state

A client that can write the state column can send any state: raise another replica's counter entry (max-merge makes it permanent), forge OR-Set tags to resurrect or hide elements, or craft a version field. RLS policies decide which rows a user may update. They do not see inside the merged value. Options:

1. **Do not accept raw state from clients.** Expose only `SECURITY DEFINER` functions (RPC through PostgREST) such as `crdt.pn_apply(table, id, delta)` which derive the replica id server-side and merge. Revoke UPDATE on the state column (column privileges) from `authenticated`.
2. **Bind replica identity to the caller.** Inside the function, `replica := auth.uid()::text` (Supabase) or `current_setting('request.jwt.claims', true)::jsonb->>'sub'`. Ignore any client-supplied replica id. A user may own several devices, so allow `replica_id = sub || ':' || device` and check the prefix **(design suggestion, not verified)**.
3. **Validate the delta.** A delta may touch only keys belonging to the caller's replica: for the PN-counter, each entry `p[r]`/`n[r]` must have `r` equal to the caller's replica id, and values must be non-negative and (if the replica's current value is known) not less than it. For the OR-Set, added tags must be of the form `replica:counter`, with the replica prefix equal to the caller's, and removed tags must be tags already present in the state. The document type has the same check on actor ids in operations.
4. **Validate full states** (when whole-state sync is required): a `BEFORE UPDATE` trigger or `CHECK` calling a validator that rejects state where entries for other replicas decreased or changed (compare `old` and `new` restricted to other replicas). Cost is O(state).
5. **Shared documents** where users are allowed to write on behalf of each other need an explicit trust statement: a CRDT cannot make a malicious writer safe, only convergent. Hard limits on size and entry counts are needed against abuse.

`SECURITY DEFINER` functions need `set search_path = pg_catalog, pg_temp` and schema-qualified references, as pg_permissions does (`pg_permissions--0.1.0.sql`, search_path comment block), and EXECUTE should be revoked from public and granted explicitly. Remember these RPC functions are exposed by PostgREST if the schema is in `db-schemas` and the role has USAGE and EXECUTE ([PostgREST schemas](https://docs.postgrest.org/en/stable/references/api/schemas.html)). The page fetched did not describe EXECUTE rules for RPC. **(unverified here)**

### B6. Versioning the serialisation format

- Put a version and kind in every state: `{"v":1,"t":"pn","p":{...},"n":{...}}` (jsonb) or a header byte pair (bytea). `crdt.merge` dispatches on `t` and rejects unknown `v` with a clear error instead of silently merging.
- Merge across versions: `merge(v1, v2)` should first upgrade to the newest known version (`crdt.upgrade(state)`), and the upgrade must itself commute with merge, so an upgraded state merged with a stale one equals the upgrade of their merge. Design versions to be additive (new optional fields, ignored when absent) to keep this true.
- Provide `crdt.state_version(s)`, `crdt.upgrade(s)`, and a migration `UPDATE ... SET s = crdt.upgrade(s) WHERE crdt.state_version(s) < N` in the extension upgrade script (`ALTER EXTENSION ... UPDATE` under pg_tle; pg_permissions ships `--0.0.1--0.1.0.sql` upgrade scripts, `pg_permissions/pg_permissions--0.0.1--0.1.0.sql`).
- With a base type, the version byte sits in the binary header and I/O functions handle old versions on input.
- Clients that run an older library may send an older version. Accepting and upgrading on the server is the safe default.

## Sources

- https://www.postgresql.org/docs/current/transaction-iso.html
- https://www.postgresql.org/docs/current/storage-toast.html
- https://www.postgresql.org/docs/current/logical-replication-publication.html
- https://www.postgresql.org/docs/current/sql-createaggregate.html
- https://supabase.com/docs/guides/realtime/limits
- https://docs.postgrest.org/en/stable/references/api/schemas.html
- https://github.com/aws/pg_tle/blob/main/docs/09_datatypes.md
- https://aws.amazon.com/blogs/database/create-custom-postgresql-data-types-using-trusted-language-extensions/
