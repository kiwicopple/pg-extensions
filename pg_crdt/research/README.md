# pg_crdt: Research

The active extension now contains only counters and text columns. See the [scope decision](scope.md) and [table-backed document archive](ydoc/README.md). The records below describe the research at the time they were written.

Research record for pg_crdt, a Postgres extension for CRDTs, written in PL/pgSQL and installable via pg_tle.

- [`prompt.md`](./prompt.md): the starting brief.
- [`architecture.md`](./architecture.md): options and the recommended design (start here).
- [`runtimes.md`](./runtimes.md): pg_tle and PL/pgSQL capabilities, provider availability.
- [`prior-art.md`](./prior-art.md): supabase/pg_crdt, Yjs, Automerge, Loro, Diamond Types, Eg-walker, cr-sqlite and the CRDT algorithms.
- [`sql-integration.md`](./sql-integration.md): namespacing (following pg_permissions), concurrency, representation, WAL, RLS, versioning.
- [`orioledb.md`](./orioledb.md): can OrioleDB reduce write amplification? (Partly; optional accelerator only.)
- [`benchmarks/pn-counter.md`](./benchmarks/pn-counter.md): PN-Counter merge latency (SQL vs PL/pgSQL, merge shapes) and WAL per write (state column vs delta table).
- [`benchmarks/text.md`](./benchmarks/text.md): the two text shapes head to head (yseq_ column against ydoc_ tables).
- [`benchmarks/vacuum-wal.md`](./benchmarks/vacuum-wal.md): bloat, VACUUM and autovacuum, HOT updates and WAL split into records and full-page images, for pn_, yseq_ and ydoc_ against a plain text column.
- [`journal.md`](./journal.md): session log.
