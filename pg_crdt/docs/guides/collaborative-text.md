# Collaborative text for a blog post

Build a blog post whose body several people edit at once. By the end you have a `posts` table whose body is a [collaborative text](../types/collaborative-text.md) document, wrapper functions that decide who may edit which post, form saves that keep every editor's change, live editing by streaming ops, full-text search, and a maintenance job that compacts documents.

**Prerequisites.** [Install the extension](../install.md) in an empty test database and run the examples in order, as the database owner, in one psql session or one Node.js module with a connected `client` (see the [quickstart](../get-started/quickstart.md#before-you-start)). The page creates the roles `app_owner` and `app_writer`. They are examples: use your own.

**Who does what.**

| Database role | Does |
| --- | --- |
| The database owner (or the role that installed the extension) | Installs the extension and grants its tables to `app_owner`. |
| `app_owner` | Owns `posts` and the wrapper functions. It is the only role with privileges on the `crdt.ydoc_*` tables. |
| `app_writer` | The role your application or API layer connects as for users. It may call the wrappers and nothing else. |

The wrappers are `security definer` functions of `app_owner`. Each one checks your application's rule (is this user an editor of this post?) and then calls a `crdt.ydoc_` function with the identity your application trusts. This is the same pattern as for counters in [Accept writes from untrusted clients](security.md).

## Set up the roles and grants

A text document lives in the extension's tables, not in a column of yours. At install nobody but their owner has privileges on them, and the `ydoc_` functions run with the caller's privileges, so a role without grants gets `42501` from every `ydoc_` function. Grant the tables and sequences to the role that owns your wrappers, and to no client role. `references` on `crdt.ydoc_docs` lets that role's tables point at documents with a foreign key, to the document id `uid`.

> **Warning:** do not grant these tables to `app_writer`, `public` or a role that your API layer exposes. A role with privileges on them can rewrite any document directly, under any writer's name.

```sql
create role app_owner nologin;
create role app_writer nologin;

grant select, insert, update, delete
  on crdt.ydoc_docs, crdt.ydoc_replicas, crdt.ydoc_items,
     crdt.ydoc_blocks, crdt.ydoc_pending,
     crdt.ydoc_pending_deletes, crdt.ydoc_deps,
     crdt.ydoc_pending_ops, crdt.ydoc_rejected
  to app_owner;
grant references on crdt.ydoc_docs to app_owner;
grant usage on all sequences in schema crdt to app_owner;
grant create on schema public to app_owner;
```

## Create the posts table

The post keeps the document id in `body_doc`, a foreign key to `crdt.ydoc_docs (uid)`. The id is text: the client may choose it (see [Create a post](#create-a-post)). That the post's `body_doc` names a document, and that the author is its editor, is how your application records who owns the document: the extension does not. Editors are listed in `post_editors`: that is your application's rule, and the wrappers check it. `body_text` is a copy of the text for search, refreshed on save (see [Search the posts](#search-the-posts)). `text_gen` and `compact_gen` record the document's write counter at the last refresh and compaction.

```sql
set role app_owner;

create table public.posts (
  id bigint generated always as identity primary key,
  title text not null,
  body_doc text not null references crdt.ydoc_docs (uid),
  body_text text not null default '',
  text_gen bigint not null default 0,
  compact_gen bigint not null default 0
);

create table public.post_editors (
  post_id bigint references public.posts (id) on delete cascade,
  editor text not null,
  primary key (post_id, editor)
);

reset role;
```

The writer's identity in these examples is the setting `crdt.replica_id`, which your app server sets per transaction after it has authenticated the user (`set local`). `crdt.current_replica_id()` reads it, or a JWT claim when an API layer such as PostgREST verifies a token. A client that has direct SQL access can set any setting, so for such clients pass `session_user` or your own lookup instead. See [Replicas and identity](replicas-and-identity.md#where-the-identity-comes-from).

## Write the wrappers

Create every wrapper as `app_owner`, pin `search_path`, and qualify every name. `create_post` makes the document, the post and its first editor in one transaction. It writes the first text with `crdt.ydoc_set` under the author's replica id. The client may pass the id of the document, `doc_id`, so that it knows the id before the server answers and can retry safely. Without one, the document gets a random UUID.

`crdt.ydoc_create(id)` raises `23505` when a document with that id exists, and never returns the existing document: if it did, a client could pick the id of someone else's document and be handed it. The wrapper decides what that means for your application. Here, the author who already made a post with this id gets that post back (a retry after a lost response), and anyone else is refused.

```sql
set role app_owner;

create function public.create_post(
  title text,
  body text,
  doc_id text default null
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  author text := crdt.current_replica_id();
  doc text;
  post_id bigint;
begin
  if author is null then
    raise exception 'no user' using errcode = '42501';
  end if;
  if doc_id is null then
    doc := crdt.ydoc_create();
  else
    begin
      doc := crdt.ydoc_create(doc_id);
    exception when unique_violation then
      select p.id into post_id
      from public.posts p
      join public.post_editors e on e.post_id = p.id
      where p.body_doc = doc_id and e.editor = author;
      if found then
        return post_id;
      end if;
      raise exception 'document id % is already in use', doc_id
        using errcode = '23505',
              hint = 'Choose another id, such as a random UUID.';
    end;
  end if;
  perform crdt.ydoc_set(doc, body, replica => author);
  insert into public.posts (title, body_doc, body_text)
  values (title, doc, body)
  returning id into post_id;
  insert into public.post_editors values (post_id, author);
  return post_id;
end;
$$;
```

A form that edits a post needs the text and its version. `open_post` reads both in one statement, so the version matches the text. The version (`crdt.ydoc_base`) is a small `jsonb` value. The form sends it back on save.

```sql
create function public.open_post(post_id bigint)
returns table (title text, body text, base jsonb)
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
begin atomic
  select p.title,
         crdt.ydoc_value(p.body_doc),
         crdt.ydoc_base(p.body_doc)
  from public.posts p
  join public.post_editors e on e.post_id = p.id
  where p.id = open_post.post_id
    and e.editor = crdt.current_replica_id();
end;
```

`save_post` takes the whole new text from the form and the base it was opened at. `crdt.ydoc_set` with a base diffs the new text against the text at the base, not against the current text, so a change that another editor saved in the meantime survives (a three-way merge). It then refreshes `body_text` for search, and returns the merged text.

```sql
create function public.save_post(
  post_id bigint,
  body text,
  base jsonb
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  writer text := crdt.current_replica_id();
  doc text;
  merged text;
begin
  select p.body_doc into doc
  from public.posts p
  join public.post_editors e on e.post_id = p.id
  where p.id = save_post.post_id and e.editor = writer;
  if not found then
    raise exception 'not an editor of post %', post_id
      using errcode = '42501';
  end if;
  perform crdt.ydoc_set(doc, body, replica => writer, base => base);
  merged := crdt.ydoc_value(doc);
  update public.posts p
  set body_text = merged,
      text_gen = (crdt.ydoc_base(doc) ->> 'g')::bigint
  where p.id = save_post.post_id;
  return merged;
end;
$$;
```

Live editors send ops instead of whole texts. `edit_post` hands them to `crdt.ydoc_apply`, the write path for input you do not trust: it accepts inserts only under the writer's own replica id (or `<replica id>:<device>`), and checks that the op is consistent with what the writer says it has seen. `sync_post` returns the ops that an editor at version `vv` lacks, and the version to ask from next time.

```sql
create function public.edit_post(post_id bigint, ops jsonb)
returns text
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  writer text := crdt.current_replica_id();
  doc text;
begin
  select p.body_doc into doc
  from public.posts p
  join public.post_editors e on e.post_id = p.id
  where p.id = edit_post.post_id and e.editor = writer;
  if not found then
    raise exception 'not an editor of post %', post_id
      using errcode = '42501';
  end if;
  return crdt.ydoc_apply(doc, ops, replica => writer);
end;
$$;

create function public.sync_post(post_id bigint, vv jsonb)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
return (
  select jsonb_build_object(
    'ops', crdt.ydoc_ops_since(p.body_doc, vv),
    'version', crdt.ydoc_version(p.body_doc)
  )
  from public.posts p
  join public.post_editors e on e.post_id = p.id
  where p.id = sync_post.post_id
    and e.editor = crdt.current_replica_id()
);

reset role;
```

A view over `crdt.ydoc_value` would not work for readers: the function reads the tables with the privileges of the caller, not of the view's owner. Reads go through a `security definer` function, like `open_post`.

Postgres grants `execute` on a new function to `public`. Take that away and grant the wrappers to `app_writer`:

```sql
revoke all on function
  public.create_post(text, text, text),
  public.open_post(bigint),
  public.save_post(bigint, text, jsonb),
  public.edit_post(bigint, jsonb),
  public.sync_post(bigint, jsonb)
from public;
grant execute on function
  public.create_post(text, text, text),
  public.open_post(bigint),
  public.save_post(bigint, text, jsonb),
  public.edit_post(bigint, jsonb),
  public.sync_post(bigint, jsonb)
to app_writer;
```

`app_writer` can execute the `crdt.ydoc_` functions (they are granted to `public`) but has no privileges on their tables, so a direct call fails:

```sql
set role app_writer;
select crdt.ydoc_value('0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d');
-- ERROR:  permission denied for table ydoc_docs
reset role;
```

## Create a post

Your server authenticates the user, then sets the identity and calls the wrapper in one transaction. Run the statements on one client: a pool hands each `pool.query` a different connection.

The client chooses the id of the document. A random UUID is a good id: `crypto.randomUUID()` in a browser or Node.js, or a UUIDv7 or ULID if you want ids that sort by time. The examples use a fixed one so that their output is the same every time.

```js tab="JavaScript"
const docId = '0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d' // crypto.randomUUID() in a real client

await client.query('begin')
await client.query(
  "select set_config('crdt.replica_id', $1, true)",
  ['alice'],
)
const { rows: [created] } = await client.query(
  'select public.create_post($1, $2, $3) as id',
  ['Launch notes', 'We launch on Monday.\nBring snacks.', docId],
)
await client.query(
  'insert into public.post_editors values ($1, $2)',
  [created.id, 'bob'],
)
await client.query('commit')
console.log(created.id) // '1'
```

```sql tab="SQL"
begin;
set local role app_writer;
set local crdt.replica_id = 'alice';
select public.create_post(
  'Launch notes',
  E'We launch on Monday.\nBring snacks.',
  '0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d'
);
-- 1
commit;
insert into public.post_editors values (1, 'bob');
```

Alice is the author, and bob is added as a second editor. (Adding editors is an ordinary write to your own table; here the database owner does it.)

### Create a document with a client-chosen id

The id is the client's to choose, and the extension does not decide whose it is: an id names a document and grants nothing, and that a document exists is never proof that the caller owns it. What protects a document is your wrapper (it records the owner, here in `posts` and `post_editors`, and checks it on every call) and the tables' privileges (clients have none).

- **A retry returns the same post.** If alice's request succeeded but the response was lost, she sends it again with the same id. `ydoc_create` raises `23505`, and the wrapper finds that she is already an editor of the post with that id, so it returns that post. Nothing is created twice.
- **Someone else's id is refused.** The wrapper raises `23505` again, and does not say whose document it is or what it contains.
- **Pick random ids.** `ydoc_create` never hands out an existing document, but an id that others can guess (`post:1`) lets them take it before you do, and then your create fails. A UUID, UUIDv7 or ULID cannot be guessed.

`asUser` runs one statement as a user, in its own transaction. The sections below use it too.

```js tab="JavaScript"
async function asUser(user, sql, params) {
  await client.query('begin')
  await client.query(
    "select set_config('crdt.replica_id', $1, true)",
    [user],
  )
  const { rows } = await client.query(sql, params)
  await client.query('commit')
  return rows
}

const [retried] = await asUser(
  'alice',
  'select public.create_post($1, $2, $3) as id',
  ['Launch notes', 'We launch on Monday.\nBring snacks.', docId],
)
console.log(retried.id) // '1'

try {
  await asUser(
    'mallory',
    'select public.create_post($1, $2, $3) as id',
    ['Mine now', 'Spam', docId],
  )
} catch (err) {
  await client.query('rollback')
  console.log(err.code, err.message)
  // 23505 document id 0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d is already in use
}
```

```sql tab="SQL"
begin;
set local role app_writer;
set local crdt.replica_id = 'alice';
select public.create_post(
  'Launch notes',
  E'We launch on Monday.\nBring snacks.',
  '0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d'
);
-- 1
commit;

begin;
set local role app_writer;
set local crdt.replica_id = 'mallory';
select public.create_post('Mine now', 'Spam', '0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d');
-- ERROR:  document id 0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d is already in use
-- HINT:  Choose another id, such as a random UUID.
rollback;
```

## Save from a form

Alice and bob open the post at the same time. Each form gets the text and the base.

```js tab="JavaScript"
const [aliceForm] = await asUser(
  'alice',
  'select body, base from public.open_post($1)',
  [1],
)
const [bobForm] = await asUser(
  'bob',
  'select body, base from public.open_post($1)',
  [1],
)
console.log(aliceForm.base)
// { d: '0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d', g: 1, v: { alice: 34 } }
```

```sql tab="SQL"
begin;
set local role app_writer;
set local crdt.replica_id = 'alice';
select body, base from public.open_post(1);
--          body         |                                   base
-- ----------------------+---------------------------------------------------------------------------
--  We launch on Monday.+| {"d": "0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d", "g": 1, "v": {"alice": 34}}
--  Bring snacks.        |
commit;
```

`d` is the document's id, `g` its write counter and `v` its version vector: alice's replica id has written 34 characters. Alice changes the first line and saves. Then bob, whose form still shows the old text, changes the second line and saves with the same base:

```js tab="JavaScript"
await asUser(
  'alice',
  'select public.save_post($1, $2, $3)',
  [1, 'We launch on Tuesday.\nBring snacks.', aliceForm.base],
)
const [bobSaved] = await asUser(
  'bob',
  'select public.save_post($1, $2, $3) as body',
  [1, 'We launch on Monday.\nBring cake.', bobForm.base],
)
console.log(bobSaved.body)
// We launch on Tuesday.
// Bring cake.
```

```sql tab="SQL"
begin;
set local role app_writer;
set local crdt.replica_id = 'alice';
select public.save_post(
  1,
  E'We launch on Tuesday.\nBring snacks.',
  '{"d": "0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d", "g": 1, "v": {"alice": 34}}'
);
commit;

begin;
set local role app_writer;
set local crdt.replica_id = 'bob';
select public.save_post(
  1,
  E'We launch on Monday.\nBring cake.',
  '{"d": "0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d", "g": 1, "v": {"alice": 34}}'
);
--        save_post
-- -----------------------
--  We launch on Tuesday.+
--  Bring cake.
commit;
```

Both changes are in the text. Bob's save changed only the line he edited, because it was diffed against the text at his base.

> **Warning:** without a base, `ydoc_set` diffs against the current text. A form opened before another editor's save then reverts that save, between the first and the last character the form changed. Always pass the base that was read with the text.

A form that is open for a long time can outlive a compaction: `save_post` then fails with SQLSTATE `22023` and the message `base ... is older than its last compaction`. Reopen the post and apply the user's change again, or save without a base if one editor is enough.

A user who is not an editor is refused by your rule, before the extension is called:

```sql
begin;
set local role app_writer;
set local crdt.replica_id = 'mallory';
select public.save_post(1, 'Spam', '{"d": "0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d", "g": 1, "v": {}}');
-- ERROR:  not an editor of post 1
rollback;
```

## Stream edits from an editor

A live editor keeps its own replica of the document and sends each edit as an op as the user types. It needs an implementation of the same algorithm in the client: the op format and the YjsMod order are specified in [`research/text.md`](../../research/text.md), and [`experiments/text-ref`](../../experiments/text-ref/) has the JavaScript reference implementation that the extension is tested against. pg_crdt does not ship a client library.

An op is a JSON object:

```json
{
  "v": {"alice": 38, "bob": 4},
  "i": [["bob:laptop", 1, ["alice", 19], ["alice", 20], " at 10am"]],
  "d": []
}
```

| Key | Meaning |
| --- | --- |
| `v` | The version vector the editor had before this op: for each entry key, the highest sequence number it has. |
| `i` | Inserts: `[key, seq, originLeft, originRight, text]`. The characters get the ids `[key, seq]`, `[key, seq + 1]`, and so on. The origins are the ids of the characters to the left and right when the text was typed (`null` at the start or end). |
| `d` | Deletes: `[key, seq, length]`, the ids of the deleted characters. |

Each editor uses its own entry key: the user's replica id and a device suffix, such as `bob:laptop`. The form saves above write under `bob`, so the editor must not reuse that key: two writers that number their characters under one key would collide. `crdt.ydoc_apply` accepts inserts under the writer's replica id and any of its device keys, and deletes of any character.

Bob's editor first catches up. It asks for everything since an empty version vector, applies the ops locally, and keeps the version:

```js tab="JavaScript"
const [sync] = await asUser(
  'bob',
  'select public.sync_post($1, $2) as s',
  [1, {}],
)
console.log(sync.s.version) // { bob: 4, alice: 38 }
```

```sql tab="SQL"
begin;
set local role app_writer;
set local crdt.replica_id = 'bob';
select public.sync_post(1, '{}') -> 'version';
-- {"bob": 4, "alice": 38}
commit;
```

The version says that alice's replica id has written 38 characters (34, then `Tues`) and bob's 4 (`cake`). Bob types ` at 10am` after `Tuesday` and his editor sends one op for the run. Its origins are the ids of the characters on either side when he typed it: `["alice", 19]`, the `y` of `Tuesday` (it is the `y` of the original `Monday`: alice's save replaced only `Mon`), and `["alice", 20]`, the full stop. `edit_post` returns `accepted`:

```js tab="JavaScript"
const typed = {
  v: { alice: 38, bob: 4 },
  i: [['bob:laptop', 1, ['alice', 19], ['alice', 20], ' at 10am']],
  d: [],
}
const [edited] = await asUser(
  'bob',
  'select public.edit_post($1, $2) as status',
  [1, typed],
)
console.log(edited.status) // 'accepted'
```

```sql tab="SQL"
begin;
set local role app_writer;
set local crdt.replica_id = 'bob';
select public.edit_post(
  1,
  '{
    "v": {"alice": 38, "bob": 4},
    "i": [["bob:laptop", 1, ["alice", 19], ["alice", 20], " at 10am"]],
    "d": []
  }'
);
-- accepted
commit;
```

Alice's editor, which was at the same version, asks for what it lacks and gets bob's op back:

```js tab="JavaScript"
const [aliceSync] = await asUser(
  'alice',
  'select public.sync_post($1, $2) as s',
  [1, { alice: 38, bob: 4 }],
)
console.log(aliceSync.s.ops.i)
// [ [ 'bob:laptop', 1, [ 'alice', 19 ], [ 'alice', 20 ], ' at 10am' ] ]
```

```sql tab="SQL"
begin;
set local role app_writer;
set local crdt.replica_id = 'alice';
select public.sync_post(1, '{"alice": 38, "bob": 4}') -> 'ops' -> 'i';
-- [["bob:laptop", 1, ["alice", 19], ["alice", 20], " at 10am"]]
commit;
```

`crdt.ydoc_ops_since` returns the inserts above the version in the order the server integrated them, so the editor can apply them without waiting for missing origins, and every delete the document knows (deletes are idempotent, so applying one twice is harmless). Poll it, or call it when your application learns that the post changed, for example from a `notify` that your wrappers send.

An op whose `v` names characters the server does not have yet is kept and returns `pending`. The server applies it when the missing ops arrive. An op that breaks a rule is refused as a whole, with SQLSTATE `22023` and the rule in the message. An insert under another user's key is refused with `42501`:

```sql
begin;
set local role app_writer;
set local crdt.replica_id = 'bob';
select public.edit_post(
  1,
  '{
    "v": {"alice": 38, "bob": 4, "bob:laptop": 8},
    "i": [["alice", 39, ["bob:laptop", 8], ["alice", 20], "?"]],
    "d": []
  }'
);
-- ERROR:  crdt.ydoc_apply: replica 'bob' cannot insert characters of replica 'alice'
rollback;
```

Streamed edits do not refresh `body_text`: rendering and rewriting the whole text on every keystroke costs far more than the edit (in the benchmarks, 13 to 34 times the latency of the edit at 10,000 and 100,000 characters). The maintenance job below refreshes it.

## Search the posts

`body_text` is an ordinary column, so it takes an ordinary full-text index. It cannot be a generated column: `crdt.ydoc_value` reads tables, so it is `STABLE`, and generated columns need `IMMUTABLE` functions.

```sql
create index posts_body_search
  on public.posts
  using gin (to_tsvector('english', body_text));
```

Search it like any text column. A reader that may see every post needs `select` on `posts` (or a `security definer` search function that filters what the user may read):

```js tab="JavaScript"
const { rows: found } = await client.query(
  `select id, title
   from public.posts
   where to_tsvector('english', body_text)
         @@ plainto_tsquery('english', $1)`,
  ['cake'],
)
console.log(found) // [ { id: '1', title: 'Launch notes' } ]
```

```sql tab="SQL"
select id, title
from public.posts
where to_tsvector('english', body_text)
      @@ plainto_tsquery('english', 'cake');
--  id |    title
-- ----+--------------
--   1 | Launch notes
```

A form save refreshes `body_text` at once. After streamed edits it lags until the next run of the maintenance job.

## Compact on a schedule

Every delete leaves a tombstone row, and typing splits runs of characters into rows, so a document that is edited for a long time grows. `crdt.ydoc_compact(doc, horizon)` merges adjacent rows that continue one run, and tombstones stamped at or before `horizon`, a value of the document's write counter. The text, the version and the ops that peers receive do not change.

The horizon is also the oldest base that `ydoc_set` still accepts. This job compacts each document up to the write counter it saw on its previous run, so a form that was opened since then can still save. It also refreshes `body_text` for posts that changed since the last refresh. Run it as `app_owner` from a scheduler (pg_cron, or your application's job runner), for example every ten minutes.

```sql
set role app_owner;

create function public.maintain_posts()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  p record;
  g bigint;
  removed integer := 0;
begin
  for p in
    select id, body_doc, text_gen, compact_gen from public.posts
  loop
    g := (crdt.ydoc_base(p.body_doc) ->> 'g')::bigint;
    removed := removed
      + crdt.ydoc_compact(p.body_doc, horizon => p.compact_gen);
    update public.posts
    set compact_gen = g,
        body_text = case when g > p.text_gen
                         then crdt.ydoc_value(p.body_doc)
                         else body_text end,
        text_gen = g
    where id = p.id;
  end loop;
  return removed;
end;
$$;

revoke all on function public.maintain_posts() from public;
reset role;
```

```sql
set role app_owner;
select public.maintain_posts();
-- 0
select body_text from public.posts where id = 1;
--            body_text
-- -------------------------------
--  We launch on Tuesday at 10am.+
--  Bring cake.
reset role;
```

The first run uses the horizon 0, so it merges only runs that are split but not deleted (none here). Later runs use the write counter of the run before. Each call of `ydoc_compact` takes the document's lock, like an edit, and reads all of its rows, so a job over many posts should handle them in batches, and only the posts that changed (`text_gen` against the write counter tells you which).

## Delete a post

A document is not deleted with the post: `crdt.ydoc_drop` deletes it and its rows. Do both in one wrapper:

```sql
set role app_owner;

create function public.delete_post(post_id bigint)
returns void
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  doc text;
begin
  delete from public.posts p
  where p.id = delete_post.post_id
    and exists (
      select 1 from public.post_editors e
      where e.post_id = p.id
        and e.editor = crdt.current_replica_id()
    )
  returning p.body_doc into doc;
  if not found then
    raise exception 'not an editor of post %', post_id
      using errcode = '42501';
  end if;
  perform crdt.ydoc_drop(doc);
end;
$$;

revoke all on function public.delete_post(bigint) from public;
grant execute on function public.delete_post(bigint) to app_writer;
reset role;
```

## Backups and uninstalling

- **pg_dump.** With `create extension` (pg_tle or the control file), the document tables and their sequences are marked as configuration tables, so `pg_dump` includes the documents and restores the sequences after them. A direct install (`psql -f`) has no extension object: the tables are ordinary tables in the schema `crdt`, dumped like yours. Either way, back up the schema `crdt` with your own tables: a dump of only `public` has posts that point at documents it does not contain.
- **Dropping the extension drops every document.** The `crdt.ydoc_*` tables belong to the extension. `drop extension pg_crdt` is refused while a foreign key such as `posts.body_doc` points at them, and `drop extension pg_crdt cascade` drops that foreign key and every document. See [Uninstall](../install.md#uninstall).

## Checklist

- The `crdt.ydoc_*` tables and sequences are granted to the owner of your wrappers only.
- Every wrapper is `security definer`, pins `search_path`, checks your own rule, and passes an identity that your application trusts.
- Forms pass the base they read with the text.
- Live editors write under device keys (`bob:laptop`), and catch up with `ydoc_ops_since`.
- Search reads a cached text column, refreshed on save and by the maintenance job.
- A scheduled job compacts documents, with a horizon no newer than the oldest base you want to accept.

## Next

- How the document behaves and what it cannot do: [Collaborative text](../types/collaborative-text.md).
- Every function, error and limit: [Collaborative text functions](../reference/ydoc.md).
- The measurements behind these recommendations: [text benchmarks](../../research/benchmarks/text.md).
