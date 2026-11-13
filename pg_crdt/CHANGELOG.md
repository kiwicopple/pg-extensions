# Changelog

## Unreleased: column-only scope

- Keep `crdt.pn` counters and experimental `crdt.yseq` text columns in the active extension.
- Move the table-backed `ydoc_` implementation, tests and JavaScript client to [research](research/ydoc/README.md). The extension no longer creates document tables or sequences. The [decision](research/scope.md) explains why these remain separate.
- Reorganize documentation into counter and text journeys, with separate operations, troubleshooting and reference pages.
- Document text-column WAL amplification, TOAST churn, retained deletion metadata, sync costs, quotas and integration limits alongside the tasks that encounter them.

This changes development sources; it is not an upgrade migration. Existing installations with table-backed documents need the matching old code and a planned migration. Do not drop or overwrite an existing installation to adopt this change.

## Earlier development history

The [archived changelog](research/ydoc/CHANGELOG.md) records the combined implementation and client before separation. Historical benchmarks and the build journal remain unchanged.
