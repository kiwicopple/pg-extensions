# Update safely

Merge an incoming state in the same SQL statement that updates the row. This lets Postgres lock the row and merge against its current value, so concurrent writers do not overwrite each other's changes.

The examples below cover updates, creating a missing row, and retrying a transaction after a serialization error.

Run these examples as the table owner in a test database. Create the table below, or reuse `posts` from the [quickstart](../get-started/quickstart.md):

```sql
create table posts (
  id bigint primary key,
  likes crdt.pn not null default crdt.pn_empty()
);
insert into posts (id) values (1);
```

## Merge in the `set` clause, in one statement

Pass the incoming state or delta as the **argument** of `pn_merge`, and let the `update` read the current state:

```js tab="JavaScript"
const incoming = { t: 'pn', v: 1, p: { alice: 3 }, n: {} }
await client.query(
  `update posts
   set likes = crdt.pn_merge(likes, $1)
   where id = $2`,
  [incoming, 1],
)
```

```sql tab="SQL"
update posts
set likes = crdt.pn_merge(
  likes,
  '{"t": "pn", "v": 1, "p": {"alice": 3}, "n": {}}'
)
where id = 1;
```

`pn_increment` and `pn_decrement` in a `set` clause follow the same pattern, because they also read the column in the statement that writes it.

### Create the row if it does not exist

Use an upsert. On a conflict the `do update` branch merges into the row that is already there:

```js tab="JavaScript"
const first = { t: 'pn', v: 1, p: { alice: 1 }, n: {} }
await client.query(
  `insert into posts (id, likes)
   values ($1, $2)
   on conflict (id) do update
   set likes = crdt.pn_merge(posts.likes, excluded.likes)`,
  [2, first],
)
```

```sql tab="SQL"
insert into posts (id, likes)
values (2, '{"t": "pn", "v": 1, "p": {"alice": 1}, "n": {}}')
on conflict (id) do update
set likes = crdt.pn_merge(posts.likes, excluded.likes);
```

## Why one statement is safe

Under READ COMMITTED, the default isolation level, an `update` locks the row it changes. A second writer that wants the same row waits for the lock. When the first transaction commits, the second one re-evaluates its `set` expression against the row the first one committed, so its merge starts from the new state:

| Step | Writer A | Writer B |
| --- | --- | --- |
| 1 | `update ... set likes = pn_merge(likes, a)` locks the row | |
| 2 | | The same statement waits for the lock |
| 3 | Commits | |
| 4 | | Wakes up, evaluates `pn_merge(likes, b)` on A's committed row, writes |

Neither change is lost. [`test/spec/20_concurrency.sql`](../../test/spec/20_concurrency.sql) runs this with two concurrent sessions and 600 transactions each, and checks that nothing is lost.

## Do not read, merge in the client and write back

This pattern loses updates. It is a fragment, and it is wrong:

```js
// WRONG: another writer's update between the two queries is lost
const { rows: [row] } = await client.query(
  'select likes from posts where id = $1',
  [1],
)
const merged = mergeInTheClient(row.likes, mine)
await client.query(
  'update posts set likes = $1 where id = $2',
  [merged, 1],
)
```

Both writers can read the same state, merge their own change into it and write. The second `update` overwrites the first:

| Step | Writer A | Writer B |
| --- | --- | --- |
| 1 | `select likes` reads S0 | `select likes` reads S0 |
| 2 | Merges its change: S1 | Merges its change: S2 |
| 3 | `update ... set likes = S1` | |
| 4 | | `update ... set likes = S2`: A's change is gone |

The same specification, `20_concurrency`, runs this as a negative control and shows it losing updates.

A client that merges offline can still send its merged state. It sends it as the *argument* of `pn_merge`, as above, not as a replacement value. The server then merges it into whatever is stored.

## Keep other rows out of the `set` expression

A `set` expression that reads **other rows**, through a subquery or `update ... from`, reads them from the statement's snapshot, not from their latest version. A change to those rows that committed after the statement began is not seen. Read only the row you update:

This is a fragment, and it is wrong:

```sql
-- WRONG: the subquery sees the statement's snapshot of other rows
update posts
set likes = crdt.pn_merge(
  likes,
  (select likes from posts where id = 2)
)
where id = 1;
```

## Isolation levels and retries

Under READ COMMITTED, a concurrent update to the same row waits for the row lock. Under REPEATABLE READ and SERIALIZABLE, it can instead fail: if the row changed and committed after your transaction's snapshot, the `update` fails with SQLSTATE `40001` (`could not serialize access due to concurrent update`) and Postgres rolls the transaction back. Run the whole transaction again.

You can safely merge the same state or delta again, even after a lost connection leaves you unsure whether it committed. This property is called idempotence. It applies to the merge itself; consider any other work in the transaction before retrying it.

```js
async function withRetry(client, work, attempts = 5) {
  for (let attempt = 1; ; attempt++) {
    await client.query('begin isolation level repeatable read')
    try {
      const result = await work()
      await client.query('commit')
      return result
    } catch (error) {
      await client.query('rollback')
      if (error.code !== '40001' || attempt >= attempts) throw error
    }
  }
}

const retried = { t: 'pn', v: 1, p: { alice: 4 }, n: {} }
await withRetry(client, () =>
  client.query(
    `update posts
     set likes = crdt.pn_merge(likes, $1)
     where id = $2`,
    [retried, 1],
  ),
)
```

Use the helper on one client, and not on a pool: `begin`, the work and `commit` must run on the same connection.

## Rules at a glance

| Do | Do not |
| --- | --- |
| `update t set s = crdt.pn_merge(s, $1)` | Read `s`, merge in the client, write the result back |
| `insert ... on conflict do update set s = crdt.pn_merge(t.s, excluded.s)` | Replace the column with a value you computed from an earlier read |
| Read only the updated row in the `set` expression | Read other rows in a subquery or `update ... from` |
| Retry the whole transaction on `40001` | Retry a single statement inside a rolled-back transaction |
| Apply input from untrusted clients with [`pn_apply_delta`](security.md) | Merge it with `pn_merge` directly |
