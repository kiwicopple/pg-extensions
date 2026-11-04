# Overview

`pg_crdt` adds conflict-free replicated data types (CRDTs) to Postgres. A CRDT is a value that several writers can change independently and merge later, in any order and any number of times, and still agree on the result. The extension is SQL and PL/pgSQL only: it needs no C, no other extension and no superuser, and it works with any client, driver or API layer. It assumes no identity provider and no platform roles.

Version 0.0.1 has one type, the [PN-Counter](types/pn-counter.md): a counter that can go up and down, where every writer keeps its own running totals. The other types in [the roadmap](#the-types) are planned, not built.

## What a CRDT gives you

Most data has one writer at a time: a row lock decides who goes first, and the second writer sees the first one's result. That model breaks when writers cannot talk to each other when they write: a phone that is offline, a second region that accepts writes while the link between regions is down, a background job that counts events in batches. If each of them overwrites the same number, the last writer wins and the others are lost.

A CRDT changes the question. Each writer records only what it did, in a shape that has a merge function with three properties:

- **Commutative.** Merging `a` with `b` gives the same state as merging `b` with `a`. Order does not matter.
- **Associative.** Merging three states in any grouping gives the same result.
- **Idempotent.** Merging a state with itself, or applying the same update twice, changes nothing. A retry is harmless.

Any set of writers that has seen the same updates then holds the same state, however the updates were delayed, reordered or repeated. The extension's test suite checks all three properties on 1,000 random cases each, and checks convergence under shuffled, duplicated and stale delivery.

For a counter the shape is simple. Each writer keeps the total it has ever added and the total it has ever subtracted. The value is the sum of all additions minus the sum of all subtractions. Merging takes the larger total for every writer. See [PN-Counter](types/pn-counter.md).

## When to use pg_crdt

Use it when writers can change the same value without coordinating, and you want the database to keep every change:

- likes, votes, view counts, stock levels, quotas, or any counter that several devices, regions or services update (see [When not to use it](#when-not-to-use-it) for limits that must always hold);
- a count that an offline-capable client changes locally and syncs later;
- a count that many server processes update, where you want deltas you can insert without taking a row lock (see [Storage and performance](guides/storage-and-performance.md)).

Start with the [quickstart](get-started/quickstart.md).

## When not to use it

- **A value with a rule that must always hold.** A merge always succeeds and never refuses a change, so it cannot keep a counter at or above zero while writers are disconnected. You can add a `check` on the value, but then a merge that breaks it is rejected, not reconciled. Inventory that must never go negative needs coordination, which a CRDT exists to avoid.
- **One writer at a time anyway.** If a single service updates a row under a lock, an ordinary `bigint` column is simpler and cheaper.
- **A very large number of distinct writers.** The state keeps an entry for every writer that ever counted, and entries are never removed. Counters with thousands of writers are better kept as inserted deltas. See [Limits](reference/limits.md).
- **Anything that is not a counter, yet.** Sets, registers, maps and text are planned.

## How it fits in Postgres

- A type is a `jsonb` value with a versioned envelope, wrapped in a domain such as `crdt.pn`. It reads and writes as JSON in psql, drivers and REST APIs, and works with ordinary columns, indexes and generated columns.
- All functions are in one schema, `crdt`, with a name prefix for each type (`pn_`). The verbs are the same for every type: `pn_empty`, `pn_increment`, `pn_value`, `pn_merge`.
- You write a merge as one SQL statement, `update ... set s = crdt.pn_merge(s, $1)`. The row lock then makes it safe. See [Update safely](guides/safe-updates.md).
- Row-level security cannot see inside a CRDT value, so clients you do not trust get a wrapper function around `pn_apply_delta` instead of direct `UPDATE`. See [Accept writes from untrusted clients](guides/security.md).

## The types

| Prefix | Type | Status |
| --- | --- | --- |
| `pn_` | PN-Counter: a counter that goes up and down. | **Built** (0.0.1). |
| `awset_` | Add-wins set: add and remove elements; a concurrent add beats a remove. | Planned. |
| `lww_` | Last-writer-wins register: one value, the latest write wins. | Planned. |
| `lwwmap_` | Map of keys to last-writer-wins values. | Planned. |
| `fugue_` | Text and other sequences stored in tables, readable by the server. | Planned as an experiment. |

Only the PN-Counter exists today, and no date is set for the others. Every type will follow the same conventions as `pn_`: a domain over `jsonb`, an IMMUTABLE `_value`, a `_merge`, and a `_merge_agg` aggregate where it applies. The reasoning, and the alternatives that were considered, are in the [architecture record](../research/architecture.md).

## Where to go next

| You want to | Read |
| --- | --- |
| Install the extension | [Install](install.md) |
| Count something in a few minutes | [Quickstart](get-started/quickstart.md) |
| Name your writers | [Replicas and identity](guides/replicas-and-identity.md) |
| Write without losing updates | [Update safely](guides/safe-updates.md) |
| Let clients send their own counts | [Accept writes from untrusted clients](guides/security.md) |
| Choose between a state column and deltas | [Storage and performance](guides/storage-and-performance.md) |
