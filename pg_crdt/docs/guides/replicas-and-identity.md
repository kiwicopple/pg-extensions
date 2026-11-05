# Replicas and identity

Every change to a counter is recorded under the name of the writer that made it. This page explains what that name is, the one rule about it that you must keep, how to recover from breaking it, and how the extension finds out who a writer is when a client sends its own counts.

## Replica ids and entry keys

A **replica id** is any non-empty text without a colon: a user id, an email address, an integer as text, a database role name, a region. pg_crdt does not assume UUIDs or any identity provider.

An **entry key** is what appears in the state's `p` and `n` maps. It is a replica id, or `<replica id>:<device>` with a non-empty device suffix. The suffix may itself contain colons. One writer identity can then own several replicas, such as `alice:phone` and `alice:laptop`. The **owner** of a key is the part before the first colon.

| Key | Valid | Owner |
| --- | --- | --- |
| `alice` | yes | `alice` |
| `42` | yes | `42` |
| `alice@example.com` | yes | `alice@example.com` |
| `alice:phone` | yes | `alice` |
| `alice:phone:2` | yes | `alice` |
| (empty string) | no | |
| `abc:` | no, the device suffix is empty | |
| `:x` | no, the replica id is empty | |

`pn_increment` and `pn_decrement` reject a malformed key with SQLSTATE `22023`:

```sql
select crdt.pn_increment(crdt.pn_empty(), 'abc:');
-- ERROR:  crdt.pn_increment: 'abc:' is not a replica key
-- HINT:  A replica key is a non-empty id without ":", optionally followed by ":<device>".
```

`pn_merge` accepts whatever keys another replica sends: it must merge any state it is given. Use [`pn_apply_delta`](security.md) for input you do not trust.

## One writer per key

An entry key must have **one writer at a time**. If two writers share a key, both can read `p[a] = 5` and both write 6. After the merge the counter has counted one increment instead of two.

- A key names a writer that keeps its own count: a device, an app instance, a job. It does not name a Postgres backend or a connection.
- Increments inside a single `update`, such as `set likes = crdt.pn_increment(likes, 'alice')`, are safe under a shared key. The row lock serialises the writers, and each one increments the value the previous one committed. The rule matters when a writer keeps its own copy of the state and sends totals.
- Keep device ids stable. Entries are never removed, so a new id for every session adds an entry that stays for good, and a replica that comes back would re-add its old total as new. In the benchmarks a state with 10,000 replicas takes 120 kB.

## A replica that lost its state

A writer that sends totals must start from its own entries on the server. If a device loses its local state (a reinstall, cleared storage) and starts counting from 0 under the same key, its new totals stay below the old one. Merge ignores them until they pass it, so its next increments are **silently swallowed**. Two writers that share a key cause the same thing.

Here the server has `alice:phone` at 5. The phone starts over, counts 2 likes and sends its totals:

```sql
create table posts (
  id bigint primary key,
  likes crdt.pn not null default crdt.pn_empty()
);
insert into posts (id) values (1);

update posts
set likes = crdt.pn_increment(likes, 'alice:phone', 5)
where id = 1;

update posts
set likes = crdt.pn_merge(
  likes,
  '{"t": "pn", "v": 1, "p": {"alice:phone": 2}, "n": {}}'
)
where id = 1;

select crdt.pn_value(likes) from posts where id = 1;
-- 5
```

The value is 5, not 7: the 2 new likes vanished without an error. `pn_apply_delta` cannot detect this either. A lower total looks exactly like a retry or a replayed older delta, which must succeed.

Before it sends totals again, a writer has two ways out:

- **Read its own entries back from the server and continue from them.** The phone asks for its totals, then sends the server's number plus what it has counted since.
- **Use a fresh device id**, such as `alice:phone-2`. The old entry stays, and the new one starts at 0.

To read the entries back:

```js tab="JavaScript"
const { rows: [own] } = await client.query(
  `select
     coalesce((likes -> 'p' ->> $1)::bigint, 0) as added,
     coalesce((likes -> 'n' ->> $1)::bigint, 0) as subtracted
   from posts
   where id = $2`,
  ['alice:phone', 1],
)
console.log(own) // { added: '5', subtracted: '0' }
```

```sql tab="SQL"
select
  coalesce((likes -> 'p' ->> 'alice:phone')::bigint, 0) as added,
  coalesce((likes -> 'n' ->> 'alice:phone')::bigint, 0) as subtracted
from posts
where id = 1;
-- added | subtracted
-- ------+-----------
--     5 |          0
```

The phone counted 2 likes since the reinstall, so its next state says `{"alice:phone": 7}`. Merging that gives the right value:

```js tab="JavaScript"
const resumed = { t: 'pn', v: 1, p: { 'alice:phone': 7 }, n: {} }
await client.query(
  `update posts
   set likes = crdt.pn_merge(likes, $1)
   where id = $2`,
  [resumed, 1],
)
```

```sql tab="SQL"
update posts
set likes = crdt.pn_merge(
  likes,
  '{"t": "pn", "v": 1, "p": {"alice:phone": 7}, "n": {}}'
)
where id = 1;

select crdt.pn_value(likes) from posts where id = 1;
-- 7
```

## Where the identity comes from

When a client sends a state or a delta, something has to say whose entries it may contain. That is the `replica` argument of [`pn_apply_delta`](../reference/pn.md#pn_apply_delta). It is whatever your application trusts, and its default is `crdt.current_replica_id()`, which returns the first of these that is set:

1. **A JWT claim** from the setting `request.jwt.claims`. This is the PostgREST convention: PostgREST, and APIs that follow it (Supabase is one), put the claims of the verified token there for each request. The claim is `sub`, unless the setting `crdt.replica_id_claim` names another one (`email`, `user_id`, and so on). A numeric claim is read as text.
2. **The setting `crdt.replica_id`**, which an app server sets for each transaction.
3. Otherwise null, and `pn_apply_delta` rejects the write with SQLSTATE `42501`.

Set a setting for one transaction with `set local`. Because `set local` cannot take a parameter, an application passes its value with `set_config(name, value, true)`, where `true` means transaction-local:

```js tab="JavaScript"
await client.query('begin')
await client.query(
  "select set_config('crdt.replica_id', $1, true)",
  ['user-1842'],
)
const { rows: [who] } = await client.query(
  'select crdt.current_replica_id() as id',
)
await client.query('commit')
console.log(who.id) // 'user-1842'
```

```sql tab="SQL"
begin;
set local crdt.replica_id = 'user-1842';
select crdt.current_replica_id();
-- user-1842
commit;
```

An API layer that follows the PostgREST convention sets `request.jwt.claims` itself. The same function reads it, and a different claim can be chosen:

```sql
begin;
set local request.jwt.claims =
  '{"sub": "u-7", "email": "ada@example.com"}';
select crdt.current_replica_id();
-- u-7
set local crdt.replica_id_claim = 'email';
select crdt.current_replica_id();
-- ada@example.com
commit;
```

Details of the resolver, including edge cases, are in [Shared](../reference/shared.md#current_replica_id).

### Choose the identity source

| Your writers are | Identity to pass | Wrapper |
| --- | --- | --- |
| Clients of an API that puts a verified JWT in `request.jwt.claims` | The default: the claim, `sub` unless you configure another | [JWT wrapper](security.md#identity-from-a-jwt-claim) |
| Clients of your app server, which authenticates them | The default, with the server running `set local crdt.replica_id` per transaction | [App server wrapper](security.md#identity-from-your-app-server) |
| People or services with their own database roles | `replica => session_user::text` | [Role wrapper](security.md#identity-from-the-database-role) |
| Anything else (your own users table, a platform helper) | `replica => <any text>` | Same wrapper, different argument |

## Trust model

Any role can `set` a custom setting, including `request.jwt.claims` and `crdt.replica_id`. The default resolver is therefore only as strong as whoever can set those settings:

- It is safe when writers **cannot run their own SQL**: behind PostgREST, or behind an app server that sets the identity itself.
- It is **not safe for writers with direct SQL access**. Such a client can run `set crdt.replica_id = 'someone-else'` and write as that replica. Give each of them a database role and pass `session_user` explicitly.

Inside a `security definer` function `current_user` is the function's owner, so use `session_user`, the role that logged in. `session_user` does not change with `set role`, but it does change with `set session authorization`, which only a superuser can run.

The extension does not decide which rows a writer may change, and it does not authenticate anyone. It checks one thing: that every entry in a delta belongs to the identity you pass.
