# Application examples

These examples show how to accept client updates through functions that check access. Run each setup in its own fresh test database with pg_crdt installed, as an administrator allowed to create and switch roles.

`app_owner` owns the tables and functions. `app_writer` may call the functions but cannot replace stored CRDT data. Your server signs users in and supplies their identity for each transaction. These examples assume clients cannot run arbitrary SQL.

## Counters

Run [counter-app.sql](../examples/counter-app.sql). It creates a post, gives Alice access, and defines `apply_visits(post_id, delta)`. The function checks row access, then calls `pn_apply_delta` to check entry ownership and merge the update.

```sql
begin;
set local role app_writer;
set local crdt.replica_id = 'alice';
select public.apply_visits(
  1,
  '{"t":"pn","v":1,"p":{"alice:phone":3},"n":{}}'
);
-- 3
commit;
```

Repeating this transaction still returns 3. A delta contains running totals, even when it includes only changed entries. The owner is the part before the first colon: Alice may send `alice:phone` and `alice:laptop`, but not Bob's entries. Ownership checks cannot prove that Alice's own count is truthful.

## Forms

Run [text-app.sql](../examples/text-app.sql) in a separate UTF8 database. It creates article tables and functions to create, open, save and sync text. Only listed editors may access an article.

The following example runs in **psql**. Its `\gset` command saves the original state in a variable. Alice and Bob start from that same base, then change different lines.

```sql
begin;
set local role app_writer;
set local crdt.replica_id = 'alice';
select public.create_article('Plans', E'Monday.\nBring snacks.');
-- 1
select base as original from public.open_article(1) \gset
commit;

-- As the database administrator, add Bob as an editor.
insert into public.article_editors values (1, 'bob');

begin;
set local role app_writer;
set local crdt.replica_id = 'alice';
select public.save_article(1, E'Tuesday.\nBring snacks.', :'original');
commit;

begin;
set local role app_writer;
set local crdt.replica_id = 'bob';
select public.save_article(1, E'Monday.\nBring cake.', :'original');
-- Tuesday.
-- Bring cake.
commit;
```

`open_article` returns the visible text and its full state, the base. `save_article` calls `yseq_set` with that base. Always send the base the form opened with: omitting it can undo another person's edits. After saving, reload text and base together. Reusing a base across saves has deletion/retyping edge cases; show the merged result to the user.

Each save sends the full base and rewrites the stored state. Review [text storage costs](storage.md#text) before using this for large documents or frequent saves.

## Call from your server

This JavaScript fragment uses a connected node-postgres `client`, authenticated `userId`, and the counter example above. `delta` is the client's update; `postId` is the requested post. Use parameters for values and one connection for the transaction.

```js
await client.query('begin')
try {
  await client.query(
    "select set_config('crdt.replica_id', $1, true)",
    [userId],
  )
  const { rows } = await client.query(
    'select public.apply_visits($1, $2) as visits',
    [postId, delta],
  )
  await client.query('commit')
  console.log(rows[0].visits) // bigint values are strings in node-postgres
} catch (error) {
  await client.query('rollback')
  throw error
}
```

The server chooses `userId` after authentication. A verified JWT claim takes priority over `crdt.replica_id`, so use one consistent identity source. Users with direct SQL access can set either setting themselves: their wrappers should pass `replica => session_user::text` and use that same identity for row access. See [identity settings](shared.md).

## Live editors

The text example also exposes `edit_article(id, ops)` and `sync_article(id, version)`. There is no packaged browser client. You must implement the same text ordering rules as the server; raw character positions or Yjs updates are not compatible. The [reference implementation](../../experiments/text-ref/README.md) is research code for comparison and tests.

A client needs to:

1. Fetch missing edits with `sync_article`, starting with version `{}`. A null response means missing or inaccessible, not an empty document.
2. Keep a local CRDT copy, a durable queue of unsent edits and a stable key for each independent editor.
3. Convert JavaScript string offsets to Unicode code points; reject U+0000 and lone surrogates.
4. Generate operations with the version seen before editing. Send them to `edit_article`, retrying the exact same operations on transient failure.
5. Fetch and integrate remote changes. Advance the local version only as edits are integrated, and avoid sending remote changes back as new edits.

A version records progress per writer. An operation describes inserts and deletes; see [the operation format](yseq.md#operations). Operations can wait for missing earlier edits, so a successful `edit_article` call does not guarantee every character is visible. It returns no separate pending status. Preserve the user's text when handling errors or quotas, and reload an authorized copy before recovery.

## Updates and retries

Use `update ... set value = crdt.pn_merge(value, incoming)` for trusted counter state, or the corresponding apply function for client input. Do not replace the column with a value computed from an earlier read.

For a trusted counter upsert, merge in `on conflict ... do update` as well. Subqueries reading other rows still see the statement's snapshot. Under REPEATABLE READ or SERIALIZABLE, error `40001` requires retrying the entire transaction.

Retrying the same recorded update is safe for the CRDT. Calling a fresh increment or insert after an uncertain commit can duplicate it. Consider other work in the transaction separately.
