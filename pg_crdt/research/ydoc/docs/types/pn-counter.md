# PN-Counter

Use a PN-Counter when several writers need to add to or subtract from a count independently. Each writer keeps its own running totals, and merging combines those totals without counting a repeated update twice. PN stands for positive-negative.

Store the counter in a `crdt.pn` column and use the `pn_` functions to update and read it. For a working example, start with the [quickstart](../get-started/quickstart.md).

## The state

A `crdt.pn` stores its state as JSON. The outer structure, called the envelope, identifies the type and format version. The `p` and `n` objects hold each writer's totals:

```json
{
  "t": "pn",
  "v": 1,
  "p": {"alice": 1, "bob": 2},
  "n": {"alice": 1}
}
```

| Key | Meaning |
| --- | --- |
| `t` | The type, always `"pn"`. |
| `v` | The format version, always `1` in 0.0.1. |
| `p` | For each [entry key](../guides/replicas-and-identity.md#replica-ids-and-entry-keys), the total it has ever added. |
| `n` | For each entry key, the total it has ever subtracted. |

Each total only grows. The value of the counter is `sum(p) - sum(n)`. Here that is 3 - 1 = 2.

## How it behaves

**Increment and decrement** add to the writer's own total: `pn_increment` to its entry in `p`, `pn_decrement` to its entry in `n`. A decrement does not subtract from `p`; it adds to `n`. An amount of 0 changes nothing, and a negative amount is an error.

**Merge** takes, for every entry key, the larger total in `p` and the larger total in `n`. This is why the order, the grouping and the number of merges do not matter:

- merging `a` with `b`, or `b` with `a`, gives the same state;
- merging three states in any grouping gives the same state;
- merging a state with itself, or applying an update twice, changes nothing.

So writers that have seen the same updates hold the same state, however the updates were delayed, reordered or repeated.

```sql
select crdt.pn_merge(
  '{"t": "pn", "v": 1, "p": {"a": 5}, "n": {}}',
  '{"t": "pn", "v": 1, "p": {"a": 3, "b": 2}, "n": {"a": 1}}'
);
-- {"n": {"a": 1}, "p": {"a": 5, "b": 2}, "t": "pn", "v": 1}
```

The first state has `a` at 5 and the second has `a` at 3, so `a` stays at 5. Only the second has `b` and the subtraction by `a`, so they are added. The value is 5 + 2 - 1 = 6. The same properties, checked in SQL:

```sql
with s(a, b) as (values (
  '{"t": "pn", "v": 1, "p": {"a": 5}, "n": {}}'::crdt.pn,
  '{"t": "pn", "v": 1, "p": {"a": 3, "b": 2}, "n": {"a": 1}}'::crdt.pn
))
select
  crdt.pn_merge(a, b) = crdt.pn_merge(b, a) as commutative,
  crdt.pn_merge(a, a) = a as idempotent
from s;
-- commutative | idempotent
-- ------------+-----------
-- t           | t
```

**The value** is summed in `numeric` and cast to `bigint`, so a sum beyond the bigint range raises `22003` instead of wrapping around. A null state has a null value.

**Null** is treated as the empty counter by `pn_increment`, `pn_decrement` and `pn_merge`: `pn_merge(x, null)` and `pn_merge(null, x)` are `x`.

## What a counter cannot do

- **Reset or set a value.** Totals only grow, and a merge keeps the larger one, so a lower total is ignored. Change a counter by a known amount with `pn_increment` or `pn_decrement`. To start over, use a new row.
- **Forget a writer.** Entries are never removed. The state grows with every replica id that has written, so keep device ids stable. See [Storage and performance](../guides/storage-and-performance.md).
- **Enforce a bound.** Two offline writers can each subtract from 1 and the merged value is -1. A `check` on the value rejects a merge that breaks it; it does not reconcile it. See the [overview](../overview.md#when-not-to-use-it).
- **Merge with `||`.** A domain resolves operators as its base type, and on `jsonb` the `||` operator means concatenation. It replaces the whole `p` map instead of taking maximums, and its result is plain `jsonb`:

```sql
select
  '{"t": "pn", "v": 1, "p": {"a": 5}, "n": {}}'::crdt.pn
  ||
  '{"t": "pn", "v": 1, "p": {"a": 3, "b": 2}, "n": {"a": 1}}'::crdt.pn;
-- {"n": {"a": 1}, "p": {"a": 3, "b": 2}, "t": "pn", "v": 1}
```

The `a` entry has dropped from 5 to 3. Merge is `pn_merge`.

## The `crdt.pn` domain

`crdt.pn` is a domain over `jsonb`. It reads and writes as JSON everywhere: psql, PostgREST, Realtime and drivers. A domain stores its base type, so a `crdt.pn` column costs the same as a `jsonb` column.

Its `check` validates the **envelope**: a JSON object with exactly the keys `t`, `v`, `p` and `n`, with `t` equal to `"pn"`, `v` equal to 1, and `p` and `n` objects. A value with another shape is rejected with SQLSTATE `23514`:

```sql
select '{"t": "other"}'::crdt.pn;
-- ERROR:  value for domain crdt.pn violates check constraint "pn_check"
```

The domain does not look at the entries. It runs on every merge result, so it must not cost more as the counter grows. In the benchmarks, checking every entry of a 10,000-replica state takes about 4 ms, and checking the envelope about 10 microseconds.

### Validate the entries when states come from outside

`crdt.pn_is_valid(state)` is the full validator: the envelope, and every count an integer from 0 to 9,223,372,036,854,775,807. [`pn_apply_delta`](../reference/pn.md#pn_apply_delta) runs it on every delta a client sends. If something else writes states from outside, add it to the table as a constraint:

```sql
create table posts (
  id bigint primary key,
  likes crdt.pn not null default crdt.pn_empty()
);
insert into posts (id) values (1);

alter table posts
  add constraint likes_valid
  check (crdt.pn_is_valid(likes));

update posts
set likes = '{"t": "pn", "v": 1, "p": {"a": -1}, "n": {}}';
-- ERROR:  new row for relation "posts" violates check constraint "likes_valid"
```

An entry that passes the envelope but is not a valid count does not break convergence: merge keeps the larger value under `jsonb`'s ordering, which is consistent for any JSON value. It breaks the value instead, because `pn_value` raises on an entry that is not a number.

### How the domain behaves

These points were settled by [`test/spec/40_open_questions.sql`](../../test/spec/40_open_questions.sql) on Postgres 16, 17 and 18.

- **No explicit cast is needed** to pass a `jsonb` column, variable or literal to a function that takes `crdt.pn`. Postgres coerces `jsonb` to `crdt.pn` implicitly, and the coercion runs the check once per value.
- **The check runs whenever a `crdt.pn` is made from `jsonb`**, including every function result built from `jsonb`: `pn_merge` and `pn_increment` check their result once per call. It does not run for a `crdt.pn` that is passed through unchanged (`pn_merge(x, null)`, or a `crdt.pn` column passed as an argument). It does run on a null literal cast to `crdt.pn`, which is why the check is null-safe.
- **Generated columns and expression indexes work**: `generated always as (crdt.pn_value(s)) stored`, `create index on t (crdt.pn_value(s))`, and `check` constraints. Postgres 18's *virtual* generated columns cannot call user-defined functions yet, so use `stored`.
- **There is no merge operator.** See above: merge is `pn_merge`.

## Benchmarks

A `crdt.pn` state column is cheap while the state stays under about 2 kB, which at about 12 bytes per replica is up to about 150 replicas: an increment is a HOT update that logged 176 to 357 bytes in the benchmarks. From about 170 replicas the state is TOASTed, every increment rewrites and logs the whole state, and the old copy is dead TOAST until `VACUUM` reclaims it: 13,700 bytes of WAL per increment at 1,000 replicas and 132,382 at 10,000. Counters with that many replicas are better kept as a delta table, which wrote 340 bytes per increment at any size. Its compaction recipe folded 20,000 rows in 0.52 s and took a read from 4.99 ms to 0.24 ms.

Size of one state, in bytes after TOAST compression, with every count drawn up to the given maximum (the digits of a count grow with the number of increments; [vacuum benchmarks](../../../benchmarks/vacuum-wal.md), state size):

| Replicas | Counts up to 1 | Up to 1,000 | Up to 10^6 | Up to 10^9 | Bytes per replica (up to 10^6) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 420 | 420 | 468 | 468 | 47 |
| 100 | 526 | 928 | 1,272 | 1,499 | 12.7 |
| 1,000 | 5,029 | 8,566 | 12,076 | 14,189 | 12.1 |
| 10,000 | 50,767 | 83,175 | 120,095 | 139,626 | 12.0 |

Cost per call of the functions, in microseconds, from states stored in a table (so TOAST reads are included), best of 3 ([PN-Counter benchmarks](../../../benchmarks/pn-counter.md), run A). 'Full' merges two states with the same replicas and independent counts, so about half the entries change. 'Delta' merges one changed entry, as `update t set s = crdt.pn_merge(s, $1)` does.

| Replicas | `pn_merge` full | `pn_merge` delta | `pn_increment` | `pn_value` | `pn_is_valid` |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 19.7 | 11.0 | 1.7 | 5.9 | 3.8 |
| 100 | 128 | 23 | 9.7 | 26 | 40 |
| 1,000 | 1,318 | 123 | 73 | 210 | 392 |
| 10,000 | 14,449 | 1,201 | 707 | 2,170 | 3,960 |

The state column under 20,000 increments on 100 counters, with autovacuum off, and under default autovacuum for 3 minutes (vacuum benchmarks). 'Cold' WAL starts right after a checkpoint and 'warm' does not; the share of full-page images is in parentheses. Sizes are in MB, with the number of times the live data in parentheses.

| Replicas | Stored state | After 20,000 increments | HOT | WAL bytes per increment, cold / warm | Default autovacuum, spread 200/s / hot row 100/s |
| ---: | ---: | ---: | ---: | --- | --- |
| 10 | 468 B | 0.16 (3.3x) | 100% | 212 / 176 (17%) | 0.14 / 0.28 |
| 100 | 1,269 B | 0.71 (5.7x) | 99% | 357 / 271 (22%) | not run |
| 1,000 | 12 kB | 265 (224x) | 99% | 14,341 / 13,700 (4%) | 172 (145x) / 85 (72x) |
| 10,000 | 120 kB | 2,392 (205x) | 100% | 138,564 / 132,382 (4%) | not run |

An earlier run with 500 writes against a smaller state (8.9 kB at 1,000 replicas and 84 kB at 10,000) logged 9,941 and 92,037 bytes per write, and a delta insert 334 to 349 bytes. The WAL follows the stored size of the state.

The delta table and its compaction: 100 counters, deltas from 1,000 replicas, 20,000 inserts, then the compaction recipe of [Storage and performance](../guides/storage-and-performance.md) for all counters in one statement. The extension has no compaction function, so these numbers are for that recipe.

| Step | Rows | Total MB | Dead tuples | Read one counter, ms | WAL |
| --- | ---: | ---: | ---: | ---: | --- |
| 20,000 inserts | 20,000 | 3.23 | 0 | 4.99 | 340 B per insert, no FPI |
| compaction (0.52 s) | 100 snapshots | 3.49 | 20,000 | 0.24 | 1.26 MB |
| `VACUUM` | 100 | 0.93 (heap truncated to 0.23, indexes keep 0.62) | 0 | 0.22 | |
| 20,000 more inserts | 20,100 | 4.08 | 0 | 5.04 | |
| compaction and `VACUUM` | 100 | 1.92 (indexes 1.23) | 0 | 0.26 | |
| `VACUUM FULL` | 100 | 0.45 | 0 | 0.26 | |

An index on a column that every write changes (for example `updated_at`) makes updates of a small counter 0% HOT, and at 10 replicas raised the WAL per increment from 148 to 693 bytes (4.7 times); at 1,000 replicas it added 1%.

Setup and caveats: Postgres 16.4 (Postgres.app) on an Apple M4 laptop. The call latencies used default settings (`shared_buffers` 128 MB, `fsync=off`); the state-column and delta-table runs used `shared_buffers=512MB`, `full_page_writes=on` and `wal_compression=off`, with `fsync=off` for the bloat and WAL runs and `fsync=on` for the autovacuum runs. Every figure is a single run. Noise is about 5%, so treat ratios of 1.3 or less as ties. The call latencies were also run on Postgres 18.6 in Docker and agreed within about 15%, and the state-column WAL within 0.2%; nothing else was run on Postgres 17 or 18. Not measured: concurrent writers on one row (lock waits), OrioleDB, `lz4` against `pglz` for large states, `fillfactor`, tuned autovacuum, long-running transactions that hold back `VACUUM`, replicas and logical decoding, and the cost of `pn_apply_delta`. Full results: [PN-Counter benchmarks](../../../benchmarks/pn-counter.md) and [vacuum, bloat and WAL benchmarks](../../../benchmarks/vacuum-wal.md).

## Next

- Functions: [PN-Counter functions](../reference/pn.md).
- Index the value and choose where to keep the state: [Storage and performance](../guides/storage-and-performance.md).
- Errors: [Errors](../reference/errors.md).
