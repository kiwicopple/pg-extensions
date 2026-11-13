# Save changes from a form

Keep the document state that the form loaded and send it back with the edited text. This state is the base. It lets the database apply the user's changes without replacing edits other people made elsewhere in the document.

Before starting, run [text-app.sql](../examples/text-app.sql) in a fresh test database. It creates `articles`, `article_editors` and the access wrappers described in [Control document access](access.md). Run the examples below in order in one psql session, or one Node.js module with the [connected client](../get-started/quickstart.md#before-you-start). The demonstration connection needs owner privileges to add Bob as an editor; real clients call only the wrappers.

The text column is experimental. Each save rewrites its whole state and sends the full base over the network. Deleted characters retain metadata forever. Read [Text-column limits and performance](limits.md) before using this for large documents or frequent saves.

## Create an article

Your server authenticates the user, then sets the identity and calls the wrapper in one transaction. Run the statements on one client: `pool.query` may use a different connection for each call. `asUser` runs one statement as a user, in its own transaction. The following examples use this helper.

```js tab="JavaScript"
async function asUser(user, sql, params) {
  await client.query('begin')
  await client.query(
    "select set_config('crdt.replica_id', $1, true)",
    [user],
  )
  try {
    const { rows } = await client.query(sql, params)
    await client.query('commit')
    return rows
  } catch (error) {
    await client.query('rollback')
    throw error
  }
}

const [article] = await asUser(
  'alice',
  'select public.create_article($1, $2) as id',
  ['Launch notes', 'We launch on Monday.\nBring snacks.'],
)
await client.query(
  'insert into public.article_editors values ($1, $2)',
  [article.id, 'bob'],
)
console.log(article.id) // '1'
```

```sql tab="SQL"
begin;
set local role app_writer;
set local crdt.replica_id = 'alice';
select public.create_article(
  'Launch notes',
  E'We launch on Monday.\nBring snacks.'
);
-- 1
commit;
insert into public.article_editors values (1, 'bob');
```

Alice is the author, and Bob is added as a second editor. (Adding editors is an ordinary write to your own table; here the database owner does it.)

Alice and Bob open the article at the same time. Each form gets the text and the base. node-postgres returns the base as a JavaScript object (a `crdt.yseq` is `jsonb`), and sends it back as JSON. The SQL keeps it in a psql variable with `\gset`:

```js tab="JavaScript"
const [articleAliceForm] = await asUser(
  'alice',
  'select body, base from public.open_article($1)',
  [1],
)
const [articleBobForm] = await asUser(
  'bob',
  'select body, base from public.open_article($1)',
  [1],
)
console.log(articleAliceForm.body)
// We launch on Monday.
// Bring snacks.
```

```sql tab="SQL"
begin;
set local role app_writer;
set local crdt.replica_id = 'alice';
select body from public.open_article(1);
--          body
-- ----------------------
--  We launch on Monday.+
--  Bring snacks.
select base as article_base from public.open_article(1) \gset
commit;
```

Alice changes the first line and saves. Then Bob, whose form still shows the old text, changes the second line and saves with the same base:

```js tab="JavaScript"
await asUser(
  'alice',
  'select public.save_article($1, $2, $3)',
  [1, 'We launch on Tuesday.\nBring snacks.', articleAliceForm.base],
)
const [articleBobSaved] = await asUser(
  'bob',
  'select public.save_article($1, $2, $3) as body',
  [1, 'We launch on Monday.\nBring cake.', articleBobForm.base],
)
console.log(articleBobSaved.body)
// We launch on Tuesday.
// Bring cake.
```

```sql tab="SQL"
begin;
set local role app_writer;
set local crdt.replica_id = 'alice';
select public.save_article(
  1,
  E'We launch on Tuesday.\nBring snacks.',
  :'article_base'
);
commit;

begin;
set local role app_writer;
set local crdt.replica_id = 'bob';
select public.save_article(
  1,
  E'We launch on Monday.\nBring cake.',
  :'article_base'
);
--     save_article
-- -----------------------
--  We launch on Tuesday.+
--  Bring cake.
commit;
```

Both changes are in the text. Bob's save changed only the line he edited, because it was diffed against the text of his base.

> **Warning:** without a base, `yseq_set` diffs against the current text. A form opened before another editor's save then reverts that save, between the first and the last character the form changed. Always pass the base that was read with the text.

The base is the whole value, so a form sends the document's state back on every save: a few kilobytes for a short post, about 450 kB at 100,000 characters in the benchmarks.


## Repeated saves and conflicting edits

After each successful save, reload the text and base together before the next editing session. Reusing one base across saves has edge cases: text deleted by an earlier save cannot be restored merely by typing it again against that same base. Changes in different places can merge, but the merge cannot infer what people intended when they replace the same passage. Show the merged text to the user.

## Next

[Search documents](search.md) using the generated text column. For edits sent as the user types, read [Connect a live editor](live-editor.md).
