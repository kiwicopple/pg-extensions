# Keep pg_crdt focused on columns

Decision: 13 November 2026.

The active extension provides a counter column (`crdt.pn`) and an experimental collaborative-text column (`crdt.yseq`). It does not create document tables or install the `ydoc_` API.

We are keeping table-backed documents separate for now so the extension stays small in scope: applications own their rows, permissions, indexes and backups. The `ydoc_` design adds document tables, sequences, grants, maintenance and a separate client integration. That work is useful, but it should be developed and evaluated separately rather than expanding this extension's responsibilities.

This is a scope decision, not a claim that column storage performs better. Every text-column edit rewrites the entire state. WAL amplification, TOAST churn, retained deletion history and sync costs remain real limitations. The active documentation must explain them beside the relevant tasks. Large or frequently edited documents may need another design; moving the alternative to research does not make the column suitable for those workloads.

## Preserved work

The [research snapshot](ydoc/README.md) retains the combined implementation, tests, client and documentation from before the separation. Earlier experiments and benchmark reports remain unchanged. The snapshot is for isolated research databases; it is not a supported extension installation or a released replacement package. There is no commitment to a separate release or compatibility contract yet.
