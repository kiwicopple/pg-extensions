# Accept writes from untrusted clients

Use this guide when clients send their own counts: a browser, a phone, or a service that you do not run. You give them a function that applies their delta and refuses to record anything under another writer's name. They get no `update` on the column.

The examples work with any role setup, and any API layer or driver. Roles named `app_writer`, `alice` and `bob` are examples: grant to your own.

## Why `update` access is not enough

Row-level security decides which rows a writer may change. It cannot see inside a `crdt.pn` value. A writer that can update the column can send a state that raises another replica's entry, say `{"p": {"bob": 1000000}}`, and max-merge keeps the larger total forever. Nothing in the database can tell a forged entry from a real one afterwards.

So:

1. Writers get **no `update` on the state column**.
2. They call a `security definer` function of your application. It applies their delta with `crdt.pn_apply_delta`, passing the identity your application trusts.
3. You grant `execute` on that function to your own roles, not to `public`.

`pn_apply_delta` is `pn_merge` plus the checks for input you do not trust. It rejects a delta that has an entry owned by anyone but the identity you pass, a malformed key, or a count that is not a whole number from 0 to 9,223,372,036,854,775,807. It ignores entries that are lower than what is stored, so a retry or a replayed older delta succeeds and changes nothing. The full contract is in the [reference](../reference/pn.md#pn_apply_delta).

## Set up the table and a role

Writers read the table but do not write it. Revoke `update` if they had it, or never grant it. If writers must edit other columns, grant those by column (`grant update (title) on public.posts to app_writer`) and leave the counter out.

```sql
create role app_writer nologin;

create table public.posts (
  id bigint primary key,
  likes crdt.pn not null default crdt.pn_empty()
);
insert into public.posts (id) values (1);

alter table public.posts enable row level security;
create policy posts_read
  on public.posts
  for select
  to app_writer
  using (true);
grant select on public.posts to app_writer;
```

`app_writer` stands for whatever role your writers connect as. With PostgREST it is the role your tokens name. Supabase calls it `authenticated`, and you would not grant `anon`.

## Write the wrapper

Create the wrapper as the role that owns the table. `security definer` makes it run with that role's privileges, so it can update the column that writers cannot. Pin `search_path`, and qualify every name in it.

This one identifies the writer with the default, `crdt.current_replica_id()`. It reads a JWT claim, or the `crdt.replica_id` setting. See [Replicas and identity](replicas-and-identity.md#where-the-identity-comes-from).

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
  if not found then
    raise exception 'post % not found', post_id
      using errcode = 'P0002';
  end if;
  return result;
end;
$$;
```

This one is for clients that connect with their own database role. It passes `session_user` explicitly, because the default resolver would read settings that such a client can set to anything. `session_user` is the role that logged in. Inside a `security definer` function, `current_user` is the function's owner.

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
    state => likes,
    delta => delta,
    replica => session_user::text
  )
  where id = post_id
  returning crdt.pn_value(likes) into result;
  if not found then
    raise exception 'post % not found', post_id
      using errcode = 'P0002';
  end if;
  return result;
end;
$$;
```

Any other source of identity works the same way: `replica => (select external_id::text from app.users where ...)`, a claim that you read yourself, or a platform helper such as Supabase's `auth.uid()::text`. The wrapper decides, and `pn_apply_delta` enforces.

## Grant the wrappers to your roles

Postgres grants `execute` on a new function to `public` by default. Take that away, then grant the wrappers to the roles that should call them:

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

The `crdt` functions themselves are granted to `public` at install and need no further grants. Because `public` can execute `pn_apply_delta`, anyone can call it directly. That is harmless: it only returns a value, and it writes to no table.

## Call the wrapper

A writer sends its own new totals as a delta: a state with only the entries it owns. Its totals only grow, so it sends the running total, not the amount since the last call. A writer that has lost its totals must read them back first: see [A replica that lost its state](replicas-and-identity.md#a-replica-that-lost-its-state).

### Identity from a JWT claim

An API layer that follows the PostgREST convention verifies the token, switches to the role named in it and puts the claims in `request.jwt.claims` for the request. The default resolver then returns `sub`. A client calls the function over HTTP. The JavaScript example is a fragment: `userId`, `myLikesTotal`, `apiUrl` and `jwt` are your application's values, and it needs no Postgres driver.

```js tab="JavaScript"
const delta = {
  t: 'pn',
  v: 1,
  p: { [userId]: myLikesTotal },
  n: {},
}
await fetch(`${apiUrl}/rpc/like_post`, {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${jwt}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({ post_id: 1, delta }),
})
```

```sql tab="SQL"
-- what the API layer does for the request, as a superuser
begin;
set local role app_writer;
set local request.jwt.claims = '{"sub": "user-1842"}';
select public.like_post(
  1,
  '{"t": "pn", "v": 1, "p": {"user-1842": 3}, "n": {}}'
);
-- 3
commit;
```

To use another claim than `sub`, set `crdt.replica_id_claim` for the database (`alter database app set crdt.replica_id_claim = 'email'`) or per request.

### Identity from your app server

Your server authenticates the user, then runs the call in one transaction that sets the identity first. Use `set_config(name, value, true)`, the parameter-friendly form of `set local`. Run the three statements on one client. A pool hands each `pool.query` a different connection, so check out a client for the transaction.

```js tab="JavaScript"
const serverDelta = {
  t: 'pn',
  v: 1,
  p: { 'user-2001': 4 },
  n: {},
}
await client.query('begin')
await client.query(
  "select set_config('crdt.replica_id', $1, true)",
  ['user-2001'],
)
const { rows: [served] } = await client.query(
  'select public.like_post($1, $2) as likes',
  [1, serverDelta],
)
await client.query('commit')
console.log(served.likes) // '7'
```

```sql tab="SQL"
begin;
set local role app_writer;
set local crdt.replica_id = 'user-2001';
select public.like_post(
  1,
  '{"t": "pn", "v": 1, "p": {"user-2001": 4}, "n": {}}'
);
-- 7
commit;
```

In this example the server connects as `app_writer`. The value is 7: the 3 of the previous example and the 4 of this one. If the server connects as a more privileged role, it runs `set local role app_writer` first, or you grant the wrapper to that role as well.

### Identity from the database role

Each writer has a database role and connects with it. The role name is the replica id, so alice's delta may contain only the entries `alice` and `alice:<device>`. This wrapper passes `session_user`, so a client cannot claim another name by changing a setting.

```sql
create role alice login in role app_writer;
create role bob login in role app_writer;
```

```js tab="JavaScript"
const aliceClient = new pg.Client({
  connectionString: process.env.ALICE_DATABASE_URL, // logs in as alice
})
await aliceClient.connect()

const aliceDelta = { t: 'pn', v: 1, p: { alice: 2 }, n: {} }
const { rows: [byRole] } = await aliceClient.query(
  'select public.like_post_as_role($1, $2) as likes',
  [1, aliceDelta],
)
await aliceClient.end()
console.log(byRole.likes) // '9'
```

```sql tab="SQL"
-- as a superuser, standing in for the role that logged in
set session authorization alice;
select public.like_post_as_role(
  1,
  '{"t": "pn", "v": 1, "p": {"alice": 2}, "n": {}}'
);
-- 9
reset session authorization;
```

The value is 9: 3, plus 4, plus alice's 2.

## What gets rejected

All of these raise an error and change nothing. Each runs in its own transaction, as a writer in the role `app_writer`.

A delta with an entry that belongs to someone else (SQLSTATE `42501`):

```sql
begin;
set local role app_writer;
set local crdt.replica_id = 'user-2001';
select public.like_post(
  1,
  '{"t": "pn", "v": 1, "p": {"user-1842": 100}, "n": {}}'
);
-- ERROR:  crdt.pn_apply_delta: replica 'user-2001' cannot write entry p.'user-1842' of another replica
rollback;
```

A write with no identity at all (SQLSTATE `42501`). Nothing set the claim or the setting:

```sql
begin;
set local role app_writer;
select public.like_post(
  1,
  '{"t": "pn", "v": 1, "p": {"user-2001": 5}, "n": {}}'
);
-- ERROR:  crdt.pn_apply_delta: the writer has no replica id
rollback;
```

A count that is not a whole number from 0 to the bigint maximum (SQLSTATE `22023`):

```sql
begin;
set local role app_writer;
set local crdt.replica_id = 'user-2001';
select public.like_post(
  1,
  '{"t": "pn", "v": 1, "p": {"user-2001": -5}, "n": {}}'
);
-- ERROR:  crdt.pn_apply_delta: the delta has an entry that is not an integer from 0 to 9223372036854775807
rollback;
```

A direct update of the column, by a writer who was not given the right (SQLSTATE `42501`):

```sql
begin;
set local role app_writer;
update public.posts
set likes = crdt.pn_empty();
-- ERROR:  permission denied for table posts
rollback;
```

A delta that repeats an older total succeeds and changes nothing, so retries are safe. Here user-2001 sends 4 again after having sent 4:

```sql
begin;
set local role app_writer;
set local crdt.replica_id = 'user-2001';
select public.like_post(
  1,
  '{"t": "pn", "v": 1, "p": {"user-2001": 4}, "n": {}}'
);
-- 9
commit;
```

## What the wrapper still decides

`pn_apply_delta` guards the entries of the counter. It does not know your tables, so the wrapper decides the rest:

- **Which rows a writer may change.** The example lets any writer like any post. If a row belongs to a group or an owner, check that in the wrapper's `where` clause with the same identity that you pass to `pn_apply_delta`. Alternatively keep row-level security on with a policy that applies to the function's owner (the table owner bypasses it unless you `force` it).
- **The trust model.** The default identity is only as strong as whoever can set the settings it reads: see [Trust model](replicas-and-identity.md#trust-model). For writers that can run their own SQL, pass `session_user` or your own lookup.
- **What the function returns.** The examples return the new value. Return the writer's own entries instead if clients need them to recover their state.

## Checklist

| Check | Why |
| --- | --- |
| Writers have no `update` on the state column | Otherwise they can forge any entry, and the forgery stays |
| The wrapper is `security definer` with `set search_path = pg_catalog, pg_temp` | A caller's `search_path` must not change what it calls |
| `execute` on the wrapper is revoked from `public` and granted to your roles | New functions are executable by `public` |
| The identity passed to `pn_apply_delta` comes from something the client cannot set | Otherwise the client names itself |
| The wrapper checks which rows the writer may change | `pn_apply_delta` does not know your tables |
