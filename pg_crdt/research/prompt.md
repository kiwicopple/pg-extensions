# Build `pg_crdt`: Trusted CRDTs for PostgreSQL

Build an open-source PostgreSQL extension called **`pg_crdt`**, using [pg_tle](https://github.com/aws/pg_tle), that enables developers to store, manipulate, and merge Conflict-free Replicated Data Types (CRDTs) directly inside PostgreSQL.

The goal is to make PostgreSQL a useful backend for local-first, offline-first, collaborative, and distributed applications, without requiring users to install custom native extension binaries.

## Research first

Study these projects before implementing anything:

- [aws/pg_tle](https://github.com/aws/pg_tle) — trusted PostgreSQL extensions and custom data types
- [supabase/pg_crdt](https://github.com/supabase/pg_crdt) — previous PostgreSQL CRDT implementation
- [Automerge](https://github.com/automerge/automerge) — document-oriented CRDTs
- [Yjs](https://github.com/yjs/yjs) — collaborative document CRDTs
- [Eg-walker paper](https://arxiv.org/pdf/2409.14252) — efficient collaborative text editing
- [Diamond Types](https://github.com/josephg/diamond-types) — optimized Eg-walker implementation

Reuse existing code or algorithms where practical. Don't reimplement complex algorithms unnecessarily.

## Goals

1. **Installable using `pg_tle`.** Avoid custom PostgreSQL C extensions and privileged server hooks.
2. **SQL-native API.** CRDTs should feel like ordinary PostgreSQL values with functions and operators.
3. **Deterministic convergence.** Concurrent updates must converge independently of merge order.
4. **Efficient storage.** Prefer compact binary representations when justified.
5. **Mergeable state.** Replicas should exchange serialized state or operations and merge them safely.
6. **Incremental synchronization.** Eventually support exchanging only changes a replica hasn't seen.
7. **Supabase compatibility.** Work with ordinary PostgreSQL tables, RLS, PostgREST, Realtime, and logical replication where feasible.

## Architecture

Investigate whether to use a custom PostgreSQL base type such as `crdt`, `bytea`, or `jsonb`.

Start with the simplest representation that works reliably through `pg_tle`. A custom type is desirable but not mandatory.

Compare three implementation options:

- PL/pgSQL for simple CRDTs.
- PLV8 for existing JavaScript implementations.
- PL/Rust for optimized implementations, if compatible with the trusted execution environment.

Check actual runtime support, extension privileges, binary dependencies, and deployment requirements. Don't assume every language or external crate is available in managed PostgreSQL.

Separate the design into:

- State representation and serialization
- Operations
- Merge algorithms
- Version and causal metadata
- SQL API
- Optional synchronization transport

## Initial CRDT implementations

Implement these in stages.

### 1. PN-Counter

A distributed counter supporting increments and decrements.

```sql
SELECT crdt.pn_increment(
  crdt.pn_empty(),
  'replica_a',
  5
);

SELECT crdt.pn_value(state);

SELECT crdt.pn_merge(state_a, state_b);
```

Use per-replica grow-only positive and negative counters with element-wise maximum merging. Document the replica-identity requirements.

### 2. Observed-Remove Set (OR-Set)

A set supporting concurrent additions and removals.

```sql
SELECT crdt.set_add(
  state,
  'user_123',
  'replica_a'
);

SELECT crdt.set_remove(state, 'user_123');

SELECT crdt.set_values(state);

SELECT crdt.set_merge(state_a, state_b);
```

Use unique addition tags and observed-remove semantics. Ensure deletion and re-addition behave correctly under concurrent merges.

### 3. Last-Writer-Wins Register

A value supporting deterministic conflict resolution.

```sql
SELECT crdt.register_set(
  state,
  '"hello"'::jsonb,
  'replica_a'
);

SELECT crdt.register_value(state);

SELECT crdt.register_merge(state_a, state_b);
```

Define a deterministic clock and tie-breaking policy. Explicitly document clock-skew and causality limitations.

### 4. Collaborative documents (second phase)

Investigate Eg-walker for collaborative text editing.

Proposed API:

```sql
SELECT crdt.document_new();

SELECT crdt.document_apply(
  state,
  changes
);

SELECT crdt.document_merge(
  state_a,
  state_b
);

SELECT crdt.document_text(state);
```

Prefer adapting an existing implementation, especially Diamond Types, if it can run inside the trusted-language environment.

Do not implement a complex text-editing CRDT from scratch as part of the initial MVP.

## PostgreSQL integration

Support ordinary PostgreSQL usage:

```sql
CREATE TABLE documents (
  id uuid PRIMARY KEY,
  state jsonb NOT NULL
);

UPDATE documents
SET state = crdt.set_merge(state, $1)
WHERE id = $2;
```

Explore:

- Custom types and implicit/explicit casts
- Merge operators such as `a || b`
- SQL aggregates for merging collections of states
- Binary serialization
- Schema versioning and upgrades
- Atomic updates using PostgreSQL transactions
- Integration with Realtime and PostgREST

Be particularly careful about concurrency. CRDT convergence does not automatically prevent lost updates caused by PostgreSQL transactions overwriting each other's state. Design safe transactional update patterns.

## Correctness requirements

For every mergeable state-based CRDT, verify:

- **Commutativity:** `merge(a, b) = merge(b, a)`
- **Associativity:** `merge(merge(a, b), c) = merge(a, merge(b, c))`
- **Idempotence:** `merge(a, a) = a`
- **Convergence:** replicas receiving the same logical updates eventually produce equivalent states
- **Serialization stability:** encode/decode round-trips preserve semantics

Test concurrent writes, duplicated messages, out-of-order delivery, offline replicas, deletions, and reconnections.

Add randomized/property-based tests wherever possible.

## Performance

Benchmark:

- State size as operations accumulate
- Merge latency
- Serialization/deserialization costs
- PostgreSQL update and WAL amplification
- Large document and set behavior
- Performance against native Rust implementations where applicable

Evaluate compaction, snapshots, tombstone garbage collection, and incremental state exchange. Don't introduce garbage collection that could break convergence for disconnected replicas.

## Deliverables

1. A short architecture document evaluating the implementation options and trade-offs.
2. A working `pg_tle`-installable MVP.
3. Implementations of PN-Counter, OR-Set, and LWW Register.
4. SQL examples demonstrating real-world usage.
5. Automated correctness tests and benchmarks.
6. A README explaining installation, limitations, security, and synchronization requirements.
7. A proposal for adding Eg-walker collaborative documents.

## Implementation instructions

- Use the existing repository as a starting point if one is available.
- Favor small, composable SQL functions.
- Avoid unnecessary dependencies.
- Keep the public API consistent across CRDT families.
- Treat serialization formats as versioned interfaces.
- Do not build a network synchronization service in the MVP.
- Keep transport separate from merge semantics.
- Prefer a working vertical slice over a broad unfinished framework.

**Start by researching `pg_tle`, the existing Supabase `pg_crdt` implementation, and the available trusted-language runtimes. Then choose an architecture and implement the PN-Counter end-to-end before expanding to other CRDTs.**
