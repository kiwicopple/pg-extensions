# Storage and performance

A counter can live in one column that you update, or in a table of insert-only deltas that you aggregate. This page compares the two, shows how to index the value, and says what the benchmarks measured. The numbers are observations from single runs on a laptop, not guarantees. The full report is in the [benchmark record](../../research/benchmarks/pn-counter.md).

## Two ways to store a counter

| | State column | Delta table |
| --- | --- | --- |
| Shape | One row, one `crdt.pn` column: `update t set s = crdt.pn_merge(s, $1)` | One row per change: `insert into deltas (counter, delta) values (...)` |
| Read the value | `crdt.pn_value(s)` | `crdt.pn_value(crdt.pn_merge_agg(delta))` |
| Write cost | Rewrites the state; grows with the number of replicas | One small insert, whatever the number of replicas |
| Locking | A row lock per counter | None between writers |
| Maintenance | None | Fold the deltas into a snapshot from time to time |
| Use it when | A counter has few writers: up to about 100 replicas | A counter has many writers, or writes are frequent |

Start with a state column. It needs one column and no maintenance. Move to deltas when a counter's state gets large.

### What the benchmarks measured

WAL written per write, in bytes. Each write raised one replica's entry, in its own transaction, on Postgres 16.4 on an Apple M4 laptop with `full_page_writes=on`. The delta table had a bigserial primary key and an index on the counter.

| Replicas | State stored | State column | Delta table |
| ---: | ---: | ---: | ---: |
| 10 | 480 B | 128 | 334 |
| 100 | 965 B | 398 | 349 |
| 1,000 | 8.9 kB | 9,941 | 349 |
| 10,000 | 84 kB | 92,037 | 349 |

The crossover is at about 100 replicas, or about 1 kB of state. Below it the state column logged *less* than a delta insert: the row stays inline and Postgres logs only the bytes that changed. Above about 2 kB the state is TOASTed, and each write rewrites and logs the whole compressed value: 28 times a delta insert at 1,000 replicas and 264 times at 10,000. The delta table's WAL did not depend on the number of replicas. A run on Postgres 18.6 agreed.

Reading the value from a delta table costs an aggregate: `pn_value(pn_merge_agg(d))` over 500 one-entry rows took about 18 ms, about 30 microseconds per row. That is why a delta table needs compaction to keep reads bounded.

What has not been measured: lz4 against the default TOAST compression, `fillfactor` for HOT updates, concurrent writers on one row, and OrioleDB.

## Keep counters as deltas

A delta is a small `crdt.pn` with one entry. Insert it, and read the counter with the aggregate:

```sql
create table like_deltas (
  id bigint generated always as identity primary key,
  post_id bigint not null,
  delta crdt.pn not null
);
create index on like_deltas (post_id);
```

```js tab="JavaScript"
const bobLiked = { t: 'pn', v: 1, p: { bob: 2 }, n: {} }
await client.query(
  'insert into like_deltas (post_id, delta) values ($1, $2)',
  [1, bobLiked],
)
await client.query(
  `insert into like_deltas (post_id, delta)
   values ($1, crdt.pn_increment(null, $2))`,
  [1, 'alice'],
)
```

```sql tab="SQL"
insert into like_deltas (post_id, delta)
values (1, '{"t": "pn", "v": 1, "p": {"bob": 2}, "n": {}}');

insert into like_deltas (post_id, delta)
values (1, crdt.pn_increment(null, 'alice'));
```

Inserts do not conflict, so writers never wait for each other and a retry cannot lose anything. Merge is idempotent, so a delta that is inserted twice only costs a row, and the value does not change. For deltas from a writer you do not trust, insert the result of `crdt.pn_apply_delta(null, delta)` from a [wrapper function](security.md). It returns the delta itself when it is valid and every entry belongs to the writer. Read the counter back with the aggregate:

```js tab="JavaScript"
const { rows: [counted] } = await client.query(
  `select crdt.pn_value(crdt.pn_merge_agg(delta)) as likes
   from like_deltas
   where post_id = $1`,
  [1],
)
console.log(counted.likes) // '3'
```

```sql tab="SQL"
select crdt.pn_value(crdt.pn_merge_agg(delta)) as likes
from like_deltas
where post_id = 1;
-- 3
```

`pn_merge_agg` returns null for no rows, like `sum`, so a counter with no deltas has a null value. Wrap it in `coalesce(..., 0)` when you need 0.

### Compact a delta table by hand

Compaction is not built into the extension yet. This recipe folds a counter's deltas into a snapshot row, in one statement. The `delete` and the upsert commit together, a delta inserted while it runs is left for the next compaction, and the value never changes.

This is a recipe, not part of the extension:

```sql
create table like_snapshots (
  post_id bigint primary key,
  state crdt.pn not null
);

with folded as (
  delete from like_deltas
  where post_id = 1
  returning delta
)
insert into like_snapshots (post_id, state)
select 1, crdt.pn_merge_agg(delta)
from folded
having count(*) > 0
on conflict (post_id) do update
set state = crdt.pn_merge(like_snapshots.state, excluded.state);
```

The value is now the snapshot merged with whatever deltas remain. `pn_merge` takes null for either side, so the same query works before the first compaction:

```sql
select crdt.pn_value(
  crdt.pn_merge(
    (select state from like_snapshots where post_id = 1),
    (
      select crdt.pn_merge_agg(delta)
      from like_deltas
      where post_id = 1
    )
  )
);
-- 3
```

## Index the value

`pn_value` is `IMMUTABLE`, so a generated column or an expression index can use it. These examples use a table with a state column:

```sql
create table posts (
  id bigint primary key,
  likes crdt.pn not null default crdt.pn_empty()
);
insert into posts (id) values (1), (2);
update posts
set likes = crdt.pn_increment(likes, 'alice', amount => id * 10);

-- an expression index
create index posts_likes_value
  on posts (crdt.pn_value(likes));

select id
from posts
order by crdt.pn_value(likes) desc
limit 1;
-- 2
```

Or keep the number in its own column, which a query can read, sort and filter on like any other:

```sql
alter table posts
  add column like_count bigint
  generated always as (crdt.pn_value(likes)) stored;

select id, like_count from posts order by like_count desc;
-- id | like_count
-- ---+-----------
--  2 |         20
--  1 |         10
```

Both are recomputed whenever the state changes, so a write pays the cost of `pn_value` as well: in the benchmarks about 26 microseconds at 100 replicas and about 2 ms at 10,000.

> **Write `stored` on Postgres 18.** From Postgres 18 a generated column is *virtual* by default, and a virtual column cannot call a user-defined function such as `crdt.pn_value` yet. Without `stored` the `alter table` fails. A `stored` column works on Postgres 16, 17 and 18.

A constraint on the value works as well. It rejects a write that would break it, and does not reconcile the conflict: see [Limits](../reference/limits.md).

## Why a state column gets slower as it grows

- **Merge.** Merging a one-entry delta into a state took about 11 microseconds at 10 replicas, 23 at 100, 123 at 1,000 and 1.2 ms at 10,000. Merging two full states of 10,000 replicas took about 14 ms.
- **The check.** The domain checks the envelope only, which costs about 10 microseconds even at 10,000 replicas. Checking every entry with `pn_is_valid` takes about 4 ms at that size, so the full validator runs only where input comes from outside.
- **WAL.** Above about 2 kB of state, each write logs the whole value (the table above).
- **Change feeds.** Logical decoding sends the full new value of a changed column, so replication slots and change feeds carry the whole state for each change. Some feeds cap payloads (Supabase Realtime drops column values over 64 bytes from change payloads above 1 MB). Treat a change event as "this row changed", and fetch the row. A delta table sends only the delta.

## OrioleDB

[OrioleDB](https://github.com/orioledb/orioledb) is a storage engine for Postgres. It is optional, and `pg_crdt` does not depend on it. The extension is SQL on ordinary tables and does not choose a table access method.

The research record ([`orioledb.md`](../../research/orioledb.md)) looked at whether it helps a state column. As of that record (2026-11-04):

- **It removes dead tuples, most of VACUUM's work and full-page writes** for the many small updates a hot counter row gets. That helps small and medium states.
- **It does not change what a merge writes.** A changed `jsonb` value is still written and logged whole on every merge, and merge CPU and change-feed payloads are unchanged. So it does not lift the size limit of a state column, and does not make a state column better than a delta table for a counter with many writers.
- **It is in public beta, needs a patched Postgres** (self-hosted) **or a project created as OrioleDB** (on Supabase, with no point-in-time recovery).

Treat it as an optional accelerator for a state column of modest size, and keep deltas as the fix for large ones. The record's benchmark plan, heap against OrioleDB with 1 kB to 1 MB states, has not been run, and the test suite has not been run on OrioleDB.
