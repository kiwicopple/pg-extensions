# Keep pg_crdt focused on columns

Decision: 13 November 2026.

The active extension provides a counter column (`crdt.pn`) and an experimental collaborative-text column (`crdt.yseq`). It does not create document tables or install the `ydoc_` API.

We are keeping table-backed documents separate for now so the extension stays small in scope: applications own their rows, permissions, indexes and backups. The `ydoc_` design adds document tables, sequences, grants, maintenance and a separate client integration. That work is useful, but it should be developed and evaluated separately rather than expanding this extension's responsibilities.

This is a scope decision, not a claim that column storage performs better. Every text-column edit rewrites the entire state. WAL amplification, TOAST churn, retained deletion history and sync costs remain real limitations. The active documentation must explain them beside the relevant tasks. Large or frequently edited documents may need another design; moving the alternative to research does not make the column suitable for those workloads.

## Preserved work

The [research snapshot](ydoc/README.md) retains the combined implementation, tests, client and documentation from before the separation. Earlier experiments and benchmark reports remain unchanged. The snapshot is for isolated research databases; it is not a supported extension installation or a released replacement package. There is no commitment to a separate release or compatibility contract yet.

## Existing installations

This changes the development source for version 0.0.1; it is not an in-place upgrade script. Existing databases do not lose objects just because the source file changed. Do not reinstall over an existing schema or drop the old extension to adopt this layout: dropping it can destroy documents and dependent columns.

If you already use `ydoc_`, keep the matching old implementation and backup/restore procedure until you plan a migration. Exporting visible text alone loses CRDT history and cannot preserve outstanding client edits. There is no automatic conversion from a table-backed document to a text column. See the [archived installation guide](ydoc/docs/install.md) before removing anything.
