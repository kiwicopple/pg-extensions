# Quickstart: a counter column

In this guide, you will add a like counter to a table, update it as two writers, and merge a count from an offline phone. You will also retry that merge to see why it does not count the same likes twice. You can complete the guide in a few minutes without setting up database roles.

## Before you start

[Install the extension](../install.md) in an empty test database, as the database owner. Run the SQL examples in one psql session, or select JavaScript and run them in one Node.js module (for example `quickstart.mjs`).

For JavaScript, set `DATABASE_URL` to your test database and install the driver. The examples use plain [node-postgres](https://node-postgres.com). Every JavaScript example on this page and in the other guides assumes this connected `client`:

```sh
npm install pg
```

```js
import pg from 'pg'

const client = new pg.Client({
  connectionString: process.env.DATABASE_URL,
})
await client.connect()
```

## Create a table with a counter

`crdt.pn` is the column type of the PN-Counter, a counter that goes up and down. A new counter is `crdt.pn_empty()`: no entries, value 0.

```sql
create table posts (
  id bigint primary key,
  title text not null,
  likes crdt.pn not null default crdt.pn_empty()
);
insert into posts (id, title) values (1, 'Hello');
```

## Count as two writers

Give each writer a name, called its replica id. This can be a user id or a device name. `pn_increment` records how much that writer has added, and `pn_decrement` records how much it has subtracted.

Keep each change in one `update` statement, as below. Postgres then locks the row while it reads and updates the counter, so simultaneous writes do not overwrite each other.

```js tab="JavaScript"
await client.query(
  `update posts
   set likes = crdt.pn_increment(likes, $1)
   where id = $2`,
  ['alice', 1],
)
await client.query(
  `update posts
   set likes = crdt.pn_increment(likes, $1, $2)
   where id = $3`,
  ['bob', 2, 1],
)
await client.query(
  `update posts
   set likes = crdt.pn_decrement(likes, $1)
   where id = $2`,
  ['alice', 1],
)
```

```sql tab="SQL"
update posts
set likes = crdt.pn_increment(likes, 'alice')
where id = 1;

update posts
set likes = crdt.pn_increment(likes, 'bob', amount => 2)
where id = 1;

update posts
set likes = crdt.pn_decrement(likes, 'alice')
where id = 1;
```

Alice adds 1 and then subtracts 1. Bob adds 2. The counter adds up their contributions, giving a total of 2.

## Read the value

`crdt.pn_value` returns the number as a `bigint`. node-postgres returns a `bigint` as a string.

```js tab="JavaScript"
const { rows: [post] } = await client.query(
  `select crdt.pn_value(likes) as likes
   from posts
   where id = $1`,
  [1],
)
console.log(post.likes) // '2'
```

```sql tab="SQL"
select crdt.pn_value(likes) as likes
from posts
where id = 1;
-- 2
```

The state itself is JSON. Each replica id has its total of additions (`p`) and of subtractions (`n`):

```js tab="JavaScript"
const { rows: [row] } = await client.query(
  'select likes from posts where id = $1',
  [1],
)
console.log(row.likes)
// { n: { alice: 1 }, p: { bob: 2, alice: 1 }, t: 'pn', v: 1 }
```

```sql tab="SQL"
select likes from posts where id = 1;
-- {"n": {"alice": 1}, "p": {"bob": 2, "alice": 1}, "t": "pn", "v": 1}
```

The value is `sum(p) - sum(n)`, which is 3 - 1 = 2. `t` and `v` are the type and the format version. Postgres prints the keys of a `jsonb` value in its own order, not the order in which they were written.

## Merge a count from another place

A phone that was offline counted 5 likes under its own id, `carol`. When it syncs, it sends its state. You merge it with `pn_merge` in the `set` clause of an `update`:

```js tab="JavaScript"
const fromCarol = { t: 'pn', v: 1, p: { carol: 5 }, n: {} }
await client.query(
  `update posts
   set likes = crdt.pn_merge(likes, $1)
   where id = $2`,
  [fromCarol, 1],
)
```

```sql tab="SQL"
update posts
set likes = crdt.pn_merge(
  likes,
  '{"t": "pn", "v": 1, "p": {"carol": 5}, "n": {}}'
)
where id = 1;
```

Merge takes the larger total for every replica id, so it is safe to repeat. If the phone's message arrives twice, or the app retries after a timeout, nothing is counted twice:

```js tab="JavaScript"
const again = { t: 'pn', v: 1, p: { carol: 5 }, n: {} }
await client.query(
  `update posts
   set likes = crdt.pn_merge(likes, $1)
   where id = $2`,
  [again, 1],
)
const { rows: [merged] } = await client.query(
  'select crdt.pn_value(likes) as likes from posts where id = $1',
  [1],
)
console.log(merged.likes) // '7'
```

```sql tab="SQL"
update posts
set likes = crdt.pn_merge(
  likes,
  '{"t": "pn", "v": 1, "p": {"carol": 5}, "n": {}}'
)
where id = 1;

select crdt.pn_value(likes) from posts where id = 1;
-- 7
```

The value is 7: Alice and Bob's 2, plus Carol's 5, counted once.

## Use this in your application

- **Merge inside the `update`.** Never read the state, merge it in your application and write the result back: another writer's change in between is lost. See [Update safely](../guides/safe-updates.md).
- Give each independent writer its own replica id. Two offline writers that send totals under the same id can lose counts. See [Replicas and identity](../guides/replicas-and-identity.md).
- **Here the server chose the ids.** `alice`, `bob` and `carol` above came from trusted code. If clients send their own counts, a client can send an entry that claims to be someone else's, and merge keeps it forever. Give such clients a wrapper function instead of `update` access: see [Accept writes from untrusted clients](../guides/security.md).

## Next steps

- Count under a device suffix, and recover a lost device: [Replicas and identity](../guides/replicas-and-identity.md).
- Index the value or keep many writers' counts as deltas: [Storage and performance](../guides/storage-and-performance.md).
- Every function: [PN-Counter functions](../reference/pn.md).
