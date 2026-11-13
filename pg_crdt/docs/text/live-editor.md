# Connect a live editor

A live editor keeps a local CRDT copy and sends operations describing inserts and deletes. The active extension has no packaged JavaScript client for text columns. The archived `ydoc_` client is not a compatible transport: it uses document ids and a different apply response.

Use this guide when you are prepared to implement and test an editor adapter. For a simpler integration, use [form saves](forms.md). A live editor must use the same ordering and validation rules as the server; sending raw character positions over the network is not sufficient. The [reference implementation](../../experiments/text-ref/README.md) is research code and a source for tests, not a supported browser SDK.

## Set up the server

Run [text-app.sql](../examples/text-app.sql) once in a fresh test database. It defines `edit_article(article_id, ops)` and `sync_article(article_id, version)` with editor access checks. Create an article and its editors as shown in [Save changes from a form](forms.md).

Your server authenticates each request, sets the identity for that transaction, and calls the wrapper on the same database connection. Never let the browser choose the authenticated identity. Grant it no direct update access to `articles`.

| Request | Wrapper | Response |
| --- | --- | --- |
| Load or fetch missing edits | `sync_article(id, version)` | Object with `ops` and `version`; null when no accessible article matches |
| Send edits | `edit_article(id, ops)` | No value (`void`); an error rejects the write |

The following is a server-side fragment. It needs an authenticated `writerId`, an `articleId` the caller may edit, an operation `op` from the editor, and a connected node-postgres `client`.

```js
await client.query('begin')
try {
  await client.query(
    "select set_config('crdt.replica_id', $1, true)",
    [writerId],
  )
  await client.query(
    'select public.edit_article($1, $2)',
    [articleId, op],
  )
  await client.query('commit')
  // Acknowledge the committed write through your API.
} catch (error) {
  await client.query('rollback')
  throw error
}
```

## Implement the editor adapter

1. Load operations with an empty version vector, `{}`, and integrate them before editing. Treat a null wrapper response as missing or inaccessible, not an empty document.
2. Give each independent editor its own entry key, such as `bob:laptop`. Do not share a key between tabs, devices, or form saves. Reusing ids with different text can silently lose edits in a column.
3. Convert editor UTF-16 offsets to Unicode code points. An emoji can occupy two JavaScript string units but one Postgres position. Reject lone surrogates and U+0000, which Postgres cannot store.
4. Apply edits locally and queue operations with the version observed before the edit. See [the operation format](../types/collaborative-text.md#ops).
5. Send queued operations through `edit_article`, then fetch missing operations through `sync_article`. Preserve the exact operations for retries; repeating an accepted operation is harmless. Do not regenerate it with new character ids after a timeout.
6. Integrate remote edits and map them to your editor without sending them back as new local edits. Track the local integrated version; do not advance it beyond changes you have actually applied.

An operation whose dependencies have not arrived can remain pending inside the state. A successful call does not guarantee that all its text is visible. The underlying `yseq_apply` returns state, which `edit_article` stores without returning it. The wrapper has no `accepted`/`pending` status response.

## Handle disconnection and rejection

Persist unsent edits if users must survive closing or reloading the page. The extension supplies no local queue, durable browser storage, presence, cursor sharing, rich text or undo.

Retry transient failures with the same operations. On invalid input or an ownership/quota error, keep the user's visible text, report the failure, and reload an authorized copy before deciding how to recover. Do not keep submitting later operations that depend on rejected character ids. See [Troubleshooting](../operations/troubleshooting.md).

## Budget for each sync

Every apply rewrites the full column. Merge, apply and fetching missing operations scan the stored document. Every sync sends all deletion ranges, and deleted characters are represented by U+FFFD plus deletions that hide them. A version vector does not make this a constant-cost incremental protocol.

Batching reduces database round trips and full-value rewrites, but each operation must remain within [the quotas](../reference/yseq.md#limits). Measure latency, WAL and storage under your real edit history. See [Text-column limits and performance](limits.md).
