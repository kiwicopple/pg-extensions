# PN-Counter functions

Every function of the PN-Counter, in schema `crdt`. The type is the domain `crdt.pn` over `jsonb`: see [PN-Counter](../types/pn-counter.md) for its state and behavior, [Shared](shared.md) for naming, privileges and replica ids, and [Errors](errors.md) for every SQLSTATE.

Unless an entry says otherwise, a function is `IMMUTABLE PARALLEL SAFE`, is not `STRICT`, is not `security definer`, and has `EXECUTE` granted to `public`.

| Function | Returns | Purpose |
| --- | --- | --- |
| [`pn_empty()`](#pn_empty) | `crdt.pn` | The counter with no entries; value 0. |
| [`pn_increment(state, replica, amount)`](#pn_increment) | `crdt.pn` | Add to a replica's total of additions. |
| [`pn_decrement(state, replica, amount)`](#pn_decrement) | `crdt.pn` | Add to a replica's total of subtractions. |
| [`pn_value(state)`](#pn_value) | `bigint` | `sum(p) - sum(n)`. |
| [`pn_merge(a, b)`](#pn_merge) | `crdt.pn` | The larger total of every replica, for `p` and `n`. |
| [`pn_merge_agg(state)`](#pn_merge_agg) | `crdt.pn` | Aggregate: merge every state in a group. |
| [`pn_is_valid(state)`](#pn_is_valid) | `boolean` | The full validator: envelope and every count. |
| [`pn_apply_delta(state, delta, replica)`](#pn_apply_delta) | `crdt.pn` | Merge a delta from a writer you do not trust. |

A `jsonb` value passes to any function that takes `crdt.pn` without a cast. Postgres coerces it implicitly, and the coercion runs the domain's check (SQLSTATE `23514` when the value is not an envelope).

## Functions

### `pn_empty`

```text
crdt.pn_empty() returns crdt.pn
```

The counter with no entries: `{"t": "pn", "v": 1, "p": {}, "n": {}}`. Its value is 0. Use it as the default of a state column.

**Privileges.** `EXECUTE` to `public`. **Errors.** None.

```sql
select crdt.pn_empty();
-- {"n": {}, "p": {}, "t": "pn", "v": 1}
```

### `pn_increment`

```text
crdt.pn_increment(
  state crdt.pn,
  replica text,
  amount bigint default 1
) returns crdt.pn
```

Adds `amount` to `p[replica]`. `replica` is an [entry key](shared.md#replica-ids-and-entry-keys): trusted code supplies it, and the function does not check who the caller is. Use [`pn_apply_delta`](#pn_apply_delta) for input from a client.

**Behavior**

- A null `state` counts as the empty counter.
- `amount` must be 0 or more. An amount of 0 returns the state unchanged.
- An entry is created on its first increment, at `amount`.
- The result passes the domain's check once per call.

**Privileges.** `EXECUTE` to `public`.

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22004` | `replica` or `amount` is null. |
| `22023` | `amount` is negative (the hint points to `pn_decrement`), or `replica` is not a valid entry key (`''`, `abc:`, `:x`). |
| `22003` | The entry would pass 9,223,372,036,854,775,807 (`bigint out of range`). |

```sql
select crdt.pn_increment(null, 'alice:phone', 3);
-- {"n": {}, "p": {"alice:phone": 3}, "t": "pn", "v": 1}
select crdt.pn_increment(crdt.pn_empty(), 'alice', amount => -1);
-- ERROR:  crdt.pn_increment: amount must be zero or more, got -1
```

### `pn_decrement`

```text
crdt.pn_decrement(
  state crdt.pn,
  replica text,
  amount bigint default 1
) returns crdt.pn
```

Adds `amount` to `n[replica]`. It follows the same rules and raises the same errors as [`pn_increment`](#pn_increment). Its hint for a negative amount points to `pn_increment`. A decrement raises the total of subtractions; it never lowers an entry of `p`.

```sql
select crdt.pn_decrement(null, 'alice', 2);
-- {"n": {"alice": 2}, "p": {}, "t": "pn", "v": 1}
```

### `pn_value`

```text
crdt.pn_value(state crdt.pn) returns bigint
```

`sum(p) - sum(n)`, summed in `numeric` and cast to `bigint`. `STRICT`: the value of a null state is null. It has sub-selects, so Postgres cannot inline it, but it is `IMMUTABLE` and can back a generated column or an expression index.

**Privileges.** `EXECUTE` to `public`.

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22003` | The result is outside the `bigint` range. |
| `22023` | An entry is not a number. Only a state that did not pass [`pn_is_valid`](#pn_is_valid) can have one. |

```sql
select crdt.pn_value(
  '{"t": "pn", "v": 1, "p": {"a": 5, "b": 2}, "n": {"a": 1}}'
);
-- 6
```

### `pn_merge`

```text
crdt.pn_merge(a crdt.pn, b crdt.pn) returns crdt.pn
```

For every entry key, takes the larger total in `p` and the larger in `n`. The result has exactly the keys `t`, `v`, `p` and `n`.

**Behavior**

- Commutative, associative and idempotent. `pn_merge(x, x) = x`.
- `pn_merge(x, null) = pn_merge(null, x) = x`, and `pn_merge(null, null)` is null.
- It does not check keys or counts: it accepts whatever another replica sends. Entries are compared under `jsonb`'s ordering, which is consistent for any JSON value, so even invalid entries converge.
- Use it in the `set` clause of one statement: `update t set s = crdt.pn_merge(s, $1)`. See [Update safely](../guides/safe-updates.md).
- Cost: in the benchmarks, merging a one-entry delta into a 10,000-replica state took about 1.2 ms, and merging two 10,000-replica states about 14 ms.

**Privileges.** `EXECUTE` to `public`.

**Errors.** None of its own. The result passes the domain's check.

```sql
select crdt.pn_merge(
  '{"t": "pn", "v": 1, "p": {"a": 5}, "n": {}}',
  '{"t": "pn", "v": 1, "p": {"a": 3, "b": 2}, "n": {"a": 1}}'
);
-- {"n": {"a": 1}, "p": {"a": 5, "b": 2}, "t": "pn", "v": 1}
```

### `pn_merge_agg`

```text
crdt.pn_merge_agg(crdt.pn) returns crdt.pn
```

An aggregate that merges every state in a group, for example the rows of an insert-only delta table. It returns null for no rows, like `sum`, and skips null inputs. Its combine function is `pn_merge`, so partial results from parallel workers merge in any grouping and order. It is `PARALLEL SAFE`.

**Privileges.** `EXECUTE` to `public`. **Errors.** None of its own.

```sql
create table like_deltas (
  id bigint generated always as identity primary key,
  post_id bigint not null,
  delta crdt.pn not null
);
insert into like_deltas (post_id, delta)
values
  (1, crdt.pn_increment(null, 'alice')),
  (1, crdt.pn_increment(null, 'bob', 2)),
  (2, crdt.pn_decrement(null, 'alice'));

select post_id, crdt.pn_value(crdt.pn_merge_agg(delta)) as likes
from like_deltas
group by post_id
order by post_id;
-- post_id | likes
-- --------+------
--       1 |     3
--       2 |    -1
```

### `pn_is_valid`

```text
crdt.pn_is_valid(state jsonb) returns boolean
```

The full validator. It is true when the value is an envelope (a JSON object with exactly the keys `t`, `v`, `p` and `n`, `t` equal to `"pn"`, `v` equal to 1, and `p` and `n` objects) **and** every entry in `p` and `n` is a number that is a whole number from 0 to 9,223,372,036,854,775,807. It does not check the keys of the entries: that is `pn_apply_delta`'s job.

It takes `jsonb`, not `crdt.pn`, so it can look at values that fail the domain. It is null for a null argument, and false (never an error) for anything else that is not valid. `1e3` counts as a whole number; `1.5` and `-1` do not.

Use it in a constraint on a table that something else writes, or on states from outside. Checking every entry costs more as the state grows: in the benchmarks about 4 ms for 10,000 replicas, against about 10 microseconds for the domain's envelope check.

**Privileges.** `EXECUTE` to `public`. **Errors.** None.

```sql
select crdt.pn_is_valid(
  '{"t": "pn", "v": 1, "p": {"a": 1.5}, "n": {}}'
);
-- false
select crdt.pn_is_valid(crdt.pn_increment(null, 'a', 2));
-- true
```

### `pn_apply_delta`

```text
crdt.pn_apply_delta(
  state crdt.pn,
  delta crdt.pn,
  replica text default crdt.current_replica_id()
) returns crdt.pn
```

`pn_merge` for a delta from a writer you do not trust. `replica` is the identity of the writer. A delta may only contain entries that the writer owns: `replica` itself and `replica:<device>`.

**Labels.** `IMMUTABLE PARALLEL SAFE`, `search_path` pinned to `pg_catalog, pg_temp`. It is not `security definer`: it needs no privileges, and the extension cannot know which table your application writes. Your own `security definer` function calls it. See [Accept writes from untrusted clients](../guides/security.md).

**Checks**, in this order. The first that fails raises the error:

1. `replica` is not null.
2. `replica` is a replica id: non-empty, without `:`.
3. A null `delta` returns `state` unchanged.
4. The delta passes [`pn_is_valid`](#pn_is_valid): every count a whole number from 0 to the bigint maximum.
5. Every key of the delta is a well-formed entry key.
6. Every key of the delta belongs to `replica`.

Then it returns `pn_merge(coalesce(state, pn_empty()), delta)`. Entries of the delta that are lower than the stored ones are ignored, so a retry or a replayed older delta succeeds and changes nothing. The same holds for a writer that restarts from 0: its new totals are swallowed until they pass the old ones. See [A replica that lost its state](../guides/replicas-and-identity.md#a-replica-that-lost-its-state).

Because the arguments are `crdt.pn`, a `delta` that is not an envelope fails with `23514` before the function runs.

**Default identity.** The default of `replica` is evaluated by the caller: [`current_replica_id()`](shared.md#current_replica_id). It is only as strong as whoever can set the settings it reads. For writers that can run their own SQL, pass `replica => session_user::text`.

**Privileges.** `EXECUTE` to `public`.

**Errors**

| SQLSTATE | When |
| --- | --- |
| `42501` | `replica` is null (no identity), or an entry belongs to another replica. |
| `22023` | `replica` is empty or contains `:`; a count is not a whole number from 0 to the bigint maximum; a key is malformed. |
| `23514` | `delta` (or `state`) is not a `crdt.pn` envelope. |

```sql
select crdt.pn_apply_delta(
  state => crdt.pn_empty(),
  delta => '{"t": "pn", "v": 1, "p": {"alice:phone": 3}, "n": {}}',
  replica => 'alice'
);
-- {"n": {}, "p": {"alice:phone": 3}, "t": "pn", "v": 1}

select crdt.pn_apply_delta(
  state => crdt.pn_empty(),
  delta => '{"t": "pn", "v": 1, "p": {"bob": 3}, "n": {}}',
  replica => 'alice'
);
-- ERROR:  crdt.pn_apply_delta: replica 'alice' cannot write entry p.'bob' of another replica
```
