# pg_crdt

CRDTs (conflict-free replicated data types) for Postgres, written in SQL and PL/pgSQL only. A CRDT is a value that several writers can change independently and merge later, in any order, any number of times, and still agree on the result.

Version 0.0.1 has one type, the **PN-Counter**: a counter that can go up and down, where every writer (replica) keeps its own running totals. Use it for likes, votes, stock levels or quotas that are updated from several devices, regions or offline clients.

pg_crdt is plain Postgres: it works with any client, driver or API layer, and assumes no identity provider or platform roles.

The design and the decisions behind it are in [`research/architecture.md`](research/architecture.md). Benchmarks: [`research/benchmarks/pn-counter.md`](research/benchmarks/pn-counter.md).

## Install

pg_crdt is one SQL file, `pg_crdt--0.0.1.sql`. It creates the schema `crdt`. It needs no superuser and no C: the database owner can install it.

| Where | How |
| --- | --- |
| Any Postgres 16+, as a migration | `psql -f pg_crdt--0.0.1.sql` |
| With pg_tle (for example on RDS, Aurora or Supabase) | `select pgtle.install_extension('pg_crdt', '0.0.1', 'CRDTs', <file contents>, schema => 'crdt');` then `create extension pg_crdt;` |
| With the files in the extension directory | copy `pg_crdt.control` and `pg_crdt--0.0.1.sql` to `$(pg_config --sharedir)/extension/`, then `create extension pg_crdt;` |

The install refuses to use an existing `crdt` schema that belongs to another non-superuser role, or on which another role has CREATE: either could replace the functions.

> **Warning: dropping the extension drops your data.** `crdt.pn` is a type that belongs to the extension. `drop extension pg_crdt` fails while any column uses it, and `drop extension pg_crdt cascade` **drops those columns**, with their data. Copy the values to a `jsonb` column first if you need to uninstall (`alter table t alter column s type jsonb`).

## A counter in 30 seconds

```sql
create table posts (
  id bigint primary key,
  likes crdt.pn not null default crdt.pn_empty()
);
insert into posts (id) values (1);

-- each writer counts under its own replica id
update posts set likes = crdt.pn_increment(likes, 'alice') where id = 1;
update posts set likes = crdt.pn_increment(likes, 'bob', 2) where id = 1;
update posts set likes = crdt.pn_decrement(likes, 'alice') where id = 1;

select crdt.pn_value(likes) from posts where id = 1;   -- 2
select likes from posts where id = 1;
-- {"n": {"alice": 1}, "p": {"bob": 2, "alice": 1}, "t": "pn", "v": 1}
```

## The state

A `crdt.pn` is a `jsonb` value with an envelope:

```json
{
  "t": "pn",
  "v": 1,
  "p": {"alice": 1, "bob": 2},
  "n": {"alice": 1}
}
```

- `t` is the type and `v` the format version.
- `p` and `n` map each replica id to the total it has ever added (`p`) or subtracted (`n`). Each total only grows.
- The value is `sum(p) - sum(n)`.
- Merge takes, for every replica, the larger total in `p` and the larger in `n`. That is why merging twice, or in another order, gives the same state.

`crdt.pn` is a domain over `jsonb`. It reads and writes as JSON everywhere (psql, PostgREST, Realtime, drivers). Its CHECK validates the **envelope**: a JSON object with exactly the keys `t`, `v`, `p` and `n`, `t` = `"pn"`, `v` = 1, and `p` and `n` objects. It does not look at the entries, because it runs on every merge result and must not cost more as the counter grows: checking every entry of a 10,000-replica state takes about 4 ms, the envelope about 10 us.

`crdt.pn_is_valid(state)` is the full validator: the envelope, and every count an integer from 0 to 9,223,372,036,854,775,807. `pn_apply_delta` runs it on every client delta. If anything else writes states from outside, add it to the table:

```sql
alter table posts
  add constraint likes_valid
  check (crdt.pn_is_valid(likes));
```

An entry that slips through does not break convergence: merge keeps the larger value under `jsonb`'s ordering, which is consistent for any JSON value. It breaks the value: `pn_value` raises on a non-number.

## API

All functions are in schema `crdt`. Pure functions are `IMMUTABLE PARALLEL SAFE`.

| Function | Returns | Notes |
| --- | --- | --- |
| `pn_empty()` | `crdt.pn` | The counter with no entries; value 0. |
| `pn_increment(state crdt.pn, replica text, amount bigint default 1)` | `crdt.pn` | Adds `amount` to `p[replica]`. A null state counts as empty. `amount` must be 0 or more (0 is a no-op). |
| `pn_decrement(state crdt.pn, replica text, amount bigint default 1)` | `crdt.pn` | Adds `amount` to `n[replica]`. Same rules. |
| `pn_value(state crdt.pn)` | `bigint` | `sum(p) - sum(n)`. Null for a null state. Usable in generated columns and expression indexes. |
| `pn_merge(a crdt.pn, b crdt.pn)` | `crdt.pn` | Per-replica max of `p` and of `n`. `pn_merge(x, null) = pn_merge(null, x) = x`. |
| `pn_merge_agg(crdt.pn)` | `crdt.pn` | Aggregate: merges every state in a group. Null for no rows (like `sum`); skips nulls. Parallel safe. |
| `pn_is_valid(state jsonb)` | `boolean` | The full validator: the envelope and every count. Null for null. |
| `pn_apply_delta(state crdt.pn, delta crdt.pn, replica text default crdt.current_replica_id())` | `crdt.pn` | `pn_merge` for a delta from an untrusted writer whose identity is `replica`. See [Untrusted writers](#untrusted-writers). |
| `current_replica_id()` | `text` | The default writer identity: a JWT claim from `request.jwt.claims` (`sub`, or the claim named by `crdt.replica_id_claim`), else the `crdt.replica_id` setting, else null. |

Errors:

| SQLSTATE | When |
| --- | --- |
| `22004` | `pn_increment` / `pn_decrement` with a null replica or amount. |
| `22023` | A negative amount; a malformed replica key (empty, `abc:`, `:x`); `pn_apply_delta` with a replica that is empty or contains `:`, a malformed key or an invalid count. |
| `22003` | An entry would pass the bigint maximum. |
| `23514` | A value that is not a `crdt.pn` envelope (the domain CHECK). |
| `42501` | `pn_apply_delta` with a null replica (no identity), or with an entry owned by another replica. |

### Examples

```sql
select crdt.pn_value(
  crdt.pn_merge(
    '{"t": "pn", "v": 1, "p": {"a": 5}, "n": {}}',
    '{"t": "pn", "v": 1, "p": {"a": 3, "b": 2}, "n": {"a": 1}}'
  )
);
-- 6: p = {a: 5, b: 2}, n = {a: 1}

-- a counter kept as insert-only deltas, read with the aggregate
select counter_id, crdt.pn_value(crdt.pn_merge_agg(delta))
from like_deltas
group by counter_id;

-- index the value
create index on posts (crdt.pn_value(likes));
alter table posts
  add column like_count bigint
  generated always as (crdt.pn_value(likes)) stored;
```

A `jsonb` value passes to any of these functions without a cast: Postgres coerces `jsonb` to `crdt.pn` implicitly, and the coercion runs the CHECK.

## Writing safely

**Merge in the `SET` clause, in one statement:**

```sql
update posts
set likes = crdt.pn_merge(likes, $1)
where id = $2;

-- or, creating the row if needed
insert into posts (id, likes)
values ($2, $1)
on conflict (id) do update
set likes = crdt.pn_merge(posts.likes, excluded.likes);
```

Under READ COMMITTED, a second writer waits for the row lock and then applies its merge to the row the first writer committed, so no update is lost. `test/spec/20_concurrency.sql` checks this with two concurrent sessions and 600 transactions each.

**Never read, merge in the client, and write the result back:**

```sql
-- WRONG: another writer's update between the two statements is lost
select likes from posts where id = 1;                 -- client merges locally
update posts set likes = '<merged value>' where id = 1;
```

The same spec shows this losing an update. A client that merges offline must still send its state (or a delta) as the *argument* of `pn_merge`, not as a replacement value. Also keep other rows out of the `SET` expression (a subquery or `update ... from`): they are read from the statement's snapshot, not the latest version. Under REPEATABLE READ or SERIALIZABLE a concurrent update raises `40001`; retry.

## Replica ids

A **replica id** is any non-empty text without `:`: a user id, an email address, an integer as text, a database role name, a region. pg_crdt does not assume UUIDs or any identity provider.

An **entry key** in `p` or `n` is a replica id, or `<replica id>:<device>` with a non-empty device suffix (which may contain more `:`). One writer identity can then own several replicas, for example `alice:phone` and `alice:laptop`. The owner of a key is the part before the first `:`. `pn_increment` and `pn_decrement` reject malformed keys (`''`, `abc:`, `:x`) with `22023`; `pn_merge` accepts whatever another replica sends.

### One writer per key

Each entry key must have **one writer at a time**. If two writers share a key, both may read `p[a] = 5` and both write 6: after merge the counter has counted one increment instead of two.

- A key names a writer that keeps its own count: a device, an app instance, a job. Not a Postgres backend.
- With `pn_increment` inside a single `UPDATE` (as above), the row lock serialises writers, so server-side increments under a shared key are safe. The rule matters when a writer keeps its own copy of the state and sends totals.
- Entries are never removed: a replica that comes back would re-add its old total as new. The state grows with every replica that ever wrote: in the benchmarks, 10,000 replicas take 120 kB stored.

### A replica that lost its state

A writer that sends totals must start from its own entries on the server. If a device loses its local state (reinstall, cleared storage) and starts counting from 0 again under the same key, its new totals stay below the old one, and merge ignores them until they pass it: its next increments are **silently swallowed**. Two writers sharing one key cause the same thing. So, before sending deltas again, either:

- read its own entries back from the server (`likes -> 'p' -> 'alice:phone'` and the same in `n`) and continue from them; or
- use a fresh device id (`alice:phone-2`).

`pn_apply_delta` cannot detect this: a lower total looks exactly like a retry or a replayed older delta, which must succeed (next section).

## Untrusted writers

Row-level security decides which rows a writer may change; it cannot see inside a `crdt.pn`. A writer that can update the column can raise another replica's entry, and max-merge keeps the forgery forever. So:

1. Do not grant writers UPDATE on the state column.
2. Give them a `SECURITY DEFINER` function of your app that applies their delta with `crdt.pn_apply_delta`, passing the identity your app trusts.

`pn_apply_delta(state crdt.pn, delta crdt.pn, replica text default crdt.current_replica_id())`:

- rejects (`42501`) a null `replica` (no identity);
- rejects (`22023`) a `replica` that is empty or contains `:`;
- rejects (`23514`, from the domain) a delta that is not a `crdt.pn` envelope, and (`22023`) one with a count that is not an integer from 0 to the bigint maximum (`pn_is_valid`) or a malformed key;
- rejects (`42501`) any entry whose owner is not `replica`: allowed are `replica` itself and `replica:<device>`;
- otherwise returns `pn_merge(state, delta)`. Entries lower than the server's are ignored, so a retry or a replayed older delta succeeds and changes nothing.

`crdt.pn_apply_delta` itself is not `SECURITY DEFINER`: it needs no privileges, and the extension cannot know which table your app writes. Your function decides which rows a writer may change (check ownership in it, or keep row-level security on with a policy that applies to its owner).

### Where the identity comes from

The `replica` argument is whatever your app trusts. The default, `crdt.current_replica_id()`, returns the first of:

1. **A JWT claim** from the setting `request.jwt.claims`. That is the PostgREST convention: PostgREST, and APIs that follow it (Supabase is one), put the verified token's claims there for each request. The claim is `sub` unless the setting `crdt.replica_id_claim` names another one (`email`, `user_id`, ...). A numeric claim is read as text.
2. **The setting `crdt.replica_id`**, which an app server sets for each transaction: `set local crdt.replica_id = '...'`.
3. Otherwise null, and `pn_apply_delta` rejects the write.

This is the same order pg_permissions uses for its subject (JWT `sub`, then a setting).

**Trust model.** Any role can `SET` a custom setting, including `request.jwt.claims` and `crdt.replica_id`. The default resolver is therefore only safe when writers cannot run their own SQL: behind PostgREST, or behind an app server that sets the identity itself. For writers with direct SQL access (each with its own database role), pass `session_user` explicitly. Inside a `SECURITY DEFINER` function `current_user` is the function's owner; `session_user` is the role that logged in.

### Example: the wrapper

The table, with no UPDATE for writers:

```sql
create table public.posts (
  id bigint primary key,
  likes crdt.pn not null default crdt.pn_empty()
);
alter table public.posts enable row level security;
create policy posts_read
  on public.posts
  for select
  to app_writer
  using (true);
grant select on public.posts to app_writer;
```

Identity from the default resolver (a PostgREST JWT, or an app server's `set local crdt.replica_id`):

```sql
create function public.like_post(post_id bigint, delta crdt.pn)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  result bigint;
begin
  update public.posts
  set likes = crdt.pn_apply_delta(likes, delta)
  where id = post_id
  returning crdt.pn_value(likes) into result;
  return result;
end;
$$;
```

Identity from the database role, for direct SQL clients:

```sql
create function public.like_post_as_role(post_id bigint, delta crdt.pn)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  result bigint;
begin
  update public.posts
  set likes = crdt.pn_apply_delta(
    likes,
    delta,
    replica => session_user::text
  )
  where id = post_id
  returning crdt.pn_value(likes) into result;
  return result;
end;
$$;
```

Any other source works the same way: `replica => (select external_id::text from app.users where ...)`, a claim you read yourself, or a platform helper such as Supabase's `auth.uid()::text`.

Grant the wrappers to your own roles, not to `public`:

```sql
revoke all on function
  public.like_post(bigint, crdt.pn),
  public.like_post_as_role(bigint, crdt.pn)
from public;
grant execute on function
  public.like_post(bigint, crdt.pn),
  public.like_post_as_role(bigint, crdt.pn)
to app_writer;
```

With PostgREST, `app_writer` is the role your JWTs name (Supabase calls it `authenticated`). The `crdt` functions themselves are granted to `public` and need no further grants.

A writer sends its own new totals. Over HTTP to a PostgREST-style API:

```js
const delta = {
  t: "pn",
  v: 1,
  p: { [userId]: myLikesTotal },
  n: {},
};
await fetch(`${apiUrl}/rpc/like_post`, {
  method: "POST",
  headers: {
    Authorization: `Bearer ${jwt}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({ post_id: 1, delta }),
});
```

From an app server, in one transaction:

```sql
begin;
set local crdt.replica_id = 'user-1842';
select public.like_post(
  1,
  '{"t": "pn", "v": 1, "p": {"user-1842": 3}, "n": {}}'
);
commit;
```

## How the domain behaves

Settled by `test/spec/40_open_questions.sql` on Postgres 16, 17 and 18:

- **No explicit cast is needed** to pass a `jsonb` column, variable or literal to a function that takes `crdt.pn`. The implicit coercion runs the CHECK once per value.
- **The CHECK runs whenever a `crdt.pn` is made from `jsonb`**, including every function result built from `jsonb` (PL/pgSQL, SQL, inlined or not): `pn_merge` and `pn_increment` check their result once per call. It does not run for a `crdt.pn` passed through unchanged (`pn_merge(x, null)`, a `crdt.pn` column passed as an argument). It also runs on a null literal cast to `crdt.pn`, which is why the CHECK is null-safe.
- **Generated columns and expression indexes work**: `generated always as (crdt.pn_value(s)) stored`, `create index on t (crdt.pn_value(s))`, and CHECK constraints. Postgres 18's *virtual* generated columns cannot call user-defined functions yet, so use `stored`.
- There is no `||` merge operator. A domain resolves operators as its base type, and on `jsonb` `||` means concatenation. Merge is `pn_merge`.

## Limitations

- **One type so far.** Add-wins sets, LWW registers and maps are planned (`research/architecture.md`, section 8).
- **State grows with replicas, and so does the WAL of a state column.** Up to about 100 replicas (1 kB) the state stays in the row and an update logs only the bytes that changed: 128 B of WAL per write at 10 replicas, less than inserting a delta row (about 350 B). Above about 2 kB the state is TOASTed and every write rewrites and logs all of it: 10 kB per write at 1,000 replicas, 92 kB at 10,000. For counters with many writers, insert deltas into a table and read with `pn_merge_agg`, compacting now and then (compaction is not built yet). See the [benchmarks](research/benchmarks/pn-counter.md).
- **Change feeds carry the whole state.** Logical decoding sends the full new value of a changed column, and some feeds cap payloads (Supabase Realtime, for example, drops values over 64 bytes from change payloads above 1 MB). Treat a change event as "this row changed" and refetch.
- **No tombstone collection, no deltas by version vector, no upgrade path yet** (this is 0.0.1).
- The default identity resolver is only as strong as the settings it reads (see the [trust model](#where-the-identity-comes-from)).

## Tests

```bash
./test/run.sh            # throwaway Postgres; pg_tle and the control-file install SKIP
./test/docker.sh         # Postgres 16, 17, 18 with pg_tle and the control file
make test.pg_crdt        # from the repository root
```

See [`test/README.md`](test/README.md).
