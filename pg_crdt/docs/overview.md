# What pg_crdt does

pg_crdt stores counters and collaborative plain text in Postgres columns. Several writers can change their own copies independently and combine them later. Copies that receive the same updates reach the same result, even when delivery is delayed, repeated or out of order.

These values are conflict-free replicated data types, or CRDTs. The extension is SQL and PL/pgSQL and works with any Postgres client or API layer. It does not provide authentication, networking or automatic replication between devices.

## Choose your starting point

| You need | Start with |
| --- | --- |
| A count updated by independent devices or services | [Your first counter](get-started/quickstart.md) |
| A short plain-text document with independent edits | [Your first shared document](get-started/text.md) |
| A live editor | First read [the integration requirements](text/live-editor.md) and [column limitations](text/limits.md) |

## When not to use it

Use an ordinary column when one service already coordinates every write. A CRDT adds state and processing that you may not need.

Counters cannot enforce a minimum or maximum across disconnected writers. A database constraint can reject a merge that breaks a rule, but it cannot reconcile it. Strict inventory or balance rules need coordination.

Text columns are experimental. They rewrite the whole state on every edit, retain deletion metadata indefinitely and scan the document during merge and sync. Large documents or sustained keystroke-rate editing may exceed your latency, storage or WAL budget. There is no packaged live-editor client, rich text, cursor sharing or undo.

## How it fits in Postgres

A `crdt.pn` or `crdt.yseq` column stores JSON with a validated outer structure. Your application owns the rows, grants, row policies, indexes and backups. All extension functions are in `crdt`; always qualify their names.

Local edits and merges must run in the same statement that updates the column. For untrusted client input, expose authorized wrapper functions using `pn_apply_delta` or `yseq_apply`. Calling a merge function alone does not establish a writer's identity or right to change a row.

## The types

| Type | Status |
| --- | --- |
| `crdt.pn` | Counter that records additions and subtractions per writer |
| `crdt.yseq` | Experimental plain-text column using YjsMod ordering |
| Table-backed documents (`ydoc_`) | Preserved separately in research; not installed |
| Sets, registers and maps | Planned; not implemented |

We keep the active extension focused on column values so its responsibilities stay simple. Table-backed documents have their own storage, grants, maintenance and client lifecycle and remain [separate research](../research/scope.md). This choice does not remove the limitations of column storage.

## What a CRDT gives you

Merge order and grouping do not affect the final result, and applying the same update twice does not duplicate it. These properties are called commutativity, associativity and idempotence. They apply to merging recorded changes; repeating a new local increment or insert can still create an additional change.

Read [How counters merge](types/pn-counter.md) or [How text merges](types/collaborative-text.md) when you need the details.

## Next

[Install pg_crdt](install.md), then choose the counter or text quickstart above.
