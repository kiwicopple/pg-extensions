# Table-backed documents: research snapshot

This directory preserves the implementation before table-backed documents were separated from the active extension on 13 November 2026. Read the [scope decision](../scope.md) for the reason and existing-installation implications.

The SQL snapshot includes counters, text columns and `ydoc_`, so it can reproduce the old document and client tests. It is not installed by the active extension. Use a throwaway database; do not load it alongside the current extension or into an application database.

## Contents

- `pg_crdt--0.0.1.sql` and `pg_crdt.control`: the combined implementation.
- `test/`: the original test runner, specs and helpers. The document specs are numbered 50 to 65.
- `client/`: the JavaScript client for `ydoc_`, with its tests.
- `docs/`: the documentation snapshot, including installation, the application walkthrough and API reference. Its examples describe the archived implementation.
- `CHANGELOG.md`: the history before separation.

The client and active column differential tests share the reference engine in `../../experiments/text-ref/engine.mjs`. Fixtures and traces remain in `../../experiments/text-ref/`. The snapshot tests resolve those paths explicitly.

## Run the research tests

From `pg_crdt/`, with local Postgres binaries and Node.js available:

```sh
npm run test:research
```

This runs the document specs, client unit/convergence tests and client Postgres integration tests. These tests are separate from the active extension suite. Optional editing traces must be generated as described in `../../experiments/text-ref/README.md`.

The documentation snapshot is retained for research, not published as current API documentation. Some historical links describe the original directory layout. Current guides start at [pg_crdt documentation](../../docs/README.md).
