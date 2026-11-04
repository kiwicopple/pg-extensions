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
