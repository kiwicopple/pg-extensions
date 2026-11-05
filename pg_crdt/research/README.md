# pg_crdt: Research

Research record for pg_crdt, a Postgres extension for CRDTs, written in PL/pgSQL and installable via pg_tle.

- [`prompt.md`](./prompt.md): the starting brief.
- [`architecture.md`](./architecture.md): options and the recommended design (start here).
- [`runtimes.md`](./runtimes.md): pg_tle and PL/pgSQL capabilities, provider availability.
- [`prior-art.md`](./prior-art.md): supabase/pg_crdt, Yjs, Automerge, Loro, Diamond Types, Eg-walker, cr-sqlite and the CRDT algorithms.
- [`sql-integration.md`](./sql-integration.md): namespacing (following pg_permissions), concurrency, representation, WAL, RLS, versioning.
- [`orioledb.md`](./orioledb.md): can OrioleDB reduce write amplification? (Partly; optional accelerator only.)
- [`benchmarks/pn-counter.md`](./benchmarks/pn-counter.md): PN-Counter merge latency (SQL vs PL/pgSQL, merge shapes) and WAL per write (state column vs delta table).
- [`journal.md`](./journal.md): session log.
