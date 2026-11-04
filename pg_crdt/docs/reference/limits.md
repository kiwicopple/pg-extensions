# Limits

What `pg_crdt` 0.0.1 does not do, and the numbers that bound what it does. The measurements are single runs on a laptop, in the [benchmark report](../../research/benchmarks/pn-counter.md): they show how the cost grows, not what you will get.

## Numbers

| Limit | Value | What happens past it |
| --- | --- | --- |
| A count (an entry of `p` or `n`) | 0 to 9,223,372,036,854,775,807, a whole number | `pn_increment` and `pn_decrement` raise `22003`. `pn_apply_delta` rejects the delta with `22023`. |
| The value, `sum(p) - sum(n)` | The `bigint` range | `pn_value` raises `22003`. |
| An amount for `pn_increment` or `pn_decrement` | 0 to 9,223,372,036,854,775,807 | A negative amount raises `22023`. |
| An entry key | A replica id, or `<replica id>:<device>`: non-empty, the replica id without `:` | `22023` from `pn_increment`, `pn_decrement` and `pn_apply_delta`. `pn_merge` accepts any key. |
| Format version | `v = 1` | A state with another `v` fails the domain's check with `23514`. |
| Postgres versions | 16, 17, 18 | Not tested on others. |

## Behavior

- **One type.** Only the PN-Counter is built. Add-wins sets, last-writer-wins registers and maps, and text are planned: see the [overview](../overview.md#the-types).
- **The state grows with the number of replicas.** An entry is added for every replica id that writes, and entries are never removed. In the benchmarks a state with 10 replicas was 496 bytes, 100 replicas 1.3 kB, 1,000 replicas 12 kB and 10,000 replicas 120 kB (TOAST-compressed at about 9 bytes per entry from 1,000 replicas up).
- **Cost grows with the state.** Merging a one-entry delta into a state took about 11 microseconds at 10 replicas and about 1.2 ms at 10,000. Merging two 10,000-replica states took about 14 ms. `pn_is_valid` took about 4 ms at 10,000 replicas, which is why the domain checks the envelope only.
- **So does the WAL of a state column.** Up to about 100 replicas (1 kB) the state stays in the row, and an update logs only the bytes that changed: 128 bytes of WAL per write at 10 replicas, less than inserting a delta row (about 350 bytes). Above about 2 kB the state is TOASTed, and every write rewrites and logs all of it: about 10 kB per write at 1,000 replicas and 92 kB at 10,000. For counters with many writers, insert deltas into a table and read with `pn_merge_agg`. See [Storage and performance](../guides/storage-and-performance.md).
- **Compaction of a delta table is not built.** A table of deltas grows until you fold it into a snapshot yourself. [Storage and performance](../guides/storage-and-performance.md#compact-a-delta-table-by-hand) shows how.
- **Change feeds carry the whole state.** Logical decoding sends the full new value of a changed column, and some feeds cap payloads (Supabase Realtime, for example, drops column values over 64 bytes from change payloads above 1 MB). Treat a change event as "this row changed" and fetch the row.
- **No invariants.** A counter cannot be kept above zero across disconnected writers. A `check` on `pn_value` rejects a merge that breaks it, and does not reconcile it.
- **No reset, no removal of a writer.** Totals only grow. See [PN-Counter](../types/pn-counter.md#what-a-counter-cannot-do).
- **No merge operator.** There is no `||` for merging: on `jsonb` it means concatenation. Use `pn_merge`.
- **A lost state is silent.** A writer that restarts from 0 under its old key is ignored until it passes its old total. `pn_apply_delta` cannot detect it. See [Replicas and identity](../guides/replicas-and-identity.md#a-replica-that-lost-its-state).
- **The default identity is only as strong as the settings it reads.** See [Trust model](../guides/replicas-and-identity.md#trust-model).
- **No tombstone collection, no deltas by version vector, and no upgrade path** (this is 0.0.1). See [Versioning](shared.md#versioning).
- **Postgres 18 virtual generated columns** cannot call user-defined functions yet. Use `stored`.
- **The schema is fixed.** The extension is not relocatable: it always installs into `crdt`.
- **Dropping the extension drops columns** that use `crdt.pn`. See [Install](../install.md#uninstall).
- **No client library.** The examples use plain node-postgres. Any driver works, because the state is `jsonb`.
