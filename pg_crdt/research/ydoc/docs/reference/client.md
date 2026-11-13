# JavaScript client

Use `pg-crdt-client` to connect a JavaScript live editor to a [collaborative text](../types/collaborative-text.md) document. The client keeps a local copy, applies edits immediately, and queues them to send to the server. It receives other writers' edits through `crdt.ydoc_ops_since` and sends yours through `crdt.ydoc_apply`.

Pass positions as JavaScript string offsets (UTF-16 units); the client converts them to the Unicode code points used by the extension. It reports remote changes as ranges your editor can apply, and tells you when the server rejects an edit.

It is plain ESM JavaScript with JSDoc types: no dependencies and no build step. It runs in Node.js 20 or later and in current browsers. Its engine is the reference implementation that the extension is tested against, so the client and the server order text the same way. The library is not published to npm yet: copy [`client/src`](../../client/src/) into your project, or import it from a checkout.

It does not talk to Postgres by itself. You give it a *transport*, two functions that reach your server however your application does: node-postgres, postgres.js, an RPC endpoint or `fetch`. It covers plain text only: rich text, cursors, presence and undo are out of scope, as they are for the extension.

This page continues [Collaborative text for a blog post](../guides/collaborative-text.md), whose wrappers `edit_post` and `sync_post` are what a browser's transport calls in the end.

> **`ydoc_` only, for now.** The client and its transports target the table-backed `ydoc_` documents. It has no transport for a [`crdt.yseq` column](yseq.md). The ops are the same format, so for a column your application applies a client's ops with [`yseq_apply`](yseq.md#yseq_apply) in an `update` of its row (it returns the new state, not `'accepted'`) and answers pulls with [`yseq_ops_since`](yseq.md#yseq_ops_since), as the guide's [`edit_article` and `sync_article`](../guides/collaborative-text.md#write-the-article-wrappers) do. `yseq_ops_since` sends deleted characters as U+FFFD, hidden by the deletes it sends with them. The `yseq_` edit functions return the new state, not an op: for the op of a server-side edit, take `yseq_diff(old, new)`.

## Open a document

`openYdoc` loads the document with `opsSince(doc, {})` and returns a client that writes under the [entry key](shared.md#replica-ids-and-entry-keys) `replica`. This is a fragment: `transport` is one of the transports in the next section.

```js
import { openYdoc } from './pg-crdt-client/src/index.js'

const post = await openYdoc({
  transport,
  doc: '0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d',
  replica: 'bob:laptop',
})
console.log(post.value()) // the text of the document
```

With `create: true` it first calls `transport.create(doc)`, which raises `23505` when the id exists (see [`ydoc_create`](ydoc.md#ydoc_create)). A client must load the document before it edits, so `openYdoc` fails when the server cannot be reached: retry it.

Choose the key with care:

- **One live client per key.** Two clients that number characters under one key make ops the server refuses (`22023`). Keep a device id per browser or device, for example in local storage, and write under `<replica id>:<device id>`.
- **Not the replica id itself** when forms also save under it: `ydoc_set` in the guide writes under `bob`, so bob's editor writes under `bob:laptop`.
- **The owner must be the writer.** `ydoc_apply` accepts inserts only under the writer's replica id and its device keys, and at most 16 device keys per owner and document.

Reopening with the same key after the previous client has gone is safe: the new client loads the key's characters from the server and continues their numbering. Edits that the previous client had not synced are lost.

## Write a transport

| Method | Called with | Returns | On failure |
| --- | --- | --- | --- |
| `apply(doc, op)` | The document id, and one op `{v, i, d}` | The result of `ydoc_apply`: `'accepted'` or `'pending'` | Reject with an error whose `code` is the SQLSTATE when the server refused the op |
| `opsSince(doc, vv)` | The document id, and the client's version vector | The result of `ydoc_ops_since`: an op `{i, d}`, as an object or as JSON text | Reject with an error whose `code` is the SQLSTATE when the server refused (the document is gone, access was revoked); any other error is transient |
| `create(doc)` (optional) | The document id | Anything | Reject with any error |

The client uses the `code` to decide what a failure means: see [Refused ops](#refused-ops). node-postgres and postgres.js errors already carry the SQLSTATE in `code`.

### node-postgres

For trusted server code that edits as a writer it has authenticated, such as an app server, a bot or an import job, [`docs/examples/node-postgres-transport.mjs`](../examples/node-postgres-transport.mjs) is a complete transport. The integration test of the client runs it unchanged.

```js
export function pgTransport(client, writer) {
  return {
    async create(doc) {
      await client.query('select crdt.ydoc_create($1)', [doc])
    },
    async apply(doc, op) {
      const { rows } = await client.query(
        'select crdt.ydoc_apply($1, $2, $3) as status',
        [doc, op, writer],
      )
      return rows[0].status
    },
    async opsSince(doc, vv) {
      const { rows } = await client.query(
        'select crdt.ydoc_ops_since($1, $2) as ops',
        [doc, vv],
      )
      return rows[0].ops
    },
  }
}
```

It calls the `crdt` functions directly, so its database role needs the [table grants](ydoc.md#tables). To go through your wrappers instead, change the two statements, for example to `select public.edit_post($1, $2) as status` and `select public.sync_post($1, $2) -> 'ops' as ops`.

### A browser

A browser has no database connection. Its transport calls your API, and your server authenticates the user and calls the wrappers. This is a fragment: the routes `/api/posts/:id/ops` and `/api/posts/:id/sync` are your application's, and pass the SQLSTATE back in the response body when the database refuses the op.

```js
const postId = 1

async function call(path, body) {
  const res = await fetch(`/api/posts/${postId}/${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
  const json = await res.json()
  if (!res.ok) {
    throw Object.assign(new Error(json.message), { code: json.code })
  }
  return json
}

const transport = {
  async apply(doc, op) {
    return (await call('ops', op)).status   // edit_post(post_id, ops)
  },
  async opsSince(doc, vv) {
    return (await call('sync', vv)).ops     // sync_post(post_id, vv) -> 'ops'
  },
}
```

## Edit

`insert(index, text)` and `delete(index, length)` take UTF-16 positions, the positions of JavaScript strings and of editors such as CodeMirror, Monaco or a `textarea`. An emoji outside the Basic Multilingual Plane is two units here and one position in the document; the client converts.

```js
post.insert(0, '\u{1F680} ')         // '🚀 ' is 3 UTF-16 units
post.insert(3, 'Launch: ')
post.delete(0, 3)
console.log(post.value())
```

The edit is applied to the local replica at once, and its op is queued for the next `sync()`. An edit is refused, and changes nothing, when:

- the index is outside the text, or falls between the two halves of a surrogate pair (inside an emoji): `RangeError`;
- the text has a lone surrogate or U+0000, which Postgres cannot store: `TypeError`.

Inserting `''` or deleting 0 units changes nothing and queues nothing, but the index is still checked: it throws `RangeError` when it is outside the text or inside a surrogate pair.

## Show remote changes

`on('change', listener)` calls the listener after every change of the text, with `{changes, local}`. `local` is true for the client's own `insert` and `delete`. Each change is `{from, to, insert}`: replace `from` to `to` of the text *before* the event with `insert`, in UTF-16 units. The changes of one event are sorted, do not overlap, and all refer to the text before the event, as CodeMirror's `changes` do. To patch a plain string, apply them from last to first. `on` returns a function that removes the listener.

A listener that throws cannot break the client: every listener is called, `insert`, `delete` and `sync()` behave as if it had not thrown, and the error is rethrown on a timer, where nothing in the client can catch it (an uncaught exception in Node, `window.onerror` in a browser). Catch errors inside your listener if you want to handle them. This holds for `rejected` listeners too.

This is a fragment for CodeMirror 6: `view` is an `EditorView`, and edits that came from the server are marked so that they are not sent back.

```js
import { Annotation } from '@codemirror/state'
import { EditorView } from '@codemirror/view'

const fromServer = Annotation.define()

post.on('change', ({ changes, local }) => {
  if (!local) {
    view.dispatch({ changes, annotations: fromServer.of(true) })
  }
})

const sendEdits = EditorView.updateListener.of((update) => {
  if (!update.docChanged) return
  if (update.transactions.some((tr) => tr.annotation(fromServer))) return
  const edits = []
  update.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
    edits.push([fromA, toA, inserted.toString()])
  })
  for (const [from, to, text] of edits.reverse()) {
    post.delete(from, to - from)
    post.insert(from, text)
  }
})
```

`iterChanges` reports positions in the text before the transaction, so the edits are applied from last to first.

## Sync

`sync()` sends the queued ops through `transport.apply`, in order, then asks `transport.opsSince` for what the local replica lacks and applies it. It returns a promise.

- **One sync at a time.** A call made while a sync runs waits for it and then runs once more; calls made in the meantime share that run. You can call `sync()` whenever you like.
- **Safe to retry.** On any failure the queue is kept, and the next `sync()` sends the same ops again. An op that the server already applied (the response was lost) is sent unchanged, and `ydoc_apply` accepts an identical re-send without changing anything.
- **Batched.** Edits made between two syncs travel as one op, and typing in one place joins into one run. A batch is closed by a sync and when a pull integrates characters that the replica did not have (a pull that only brings deletes or nothing new does not close it), and stays under the server's limit of 256 runs per op.
- **In memory.** The queue lives as long as the client. `pending` is the number of batches the server has not acknowledged; warn the user before they close a page while it is not 0.

When to call it is your application's choice. This fragment syncs shortly after the user stops typing, every few seconds to receive other editors' changes, and when the browser comes back online. Call it also when your application learns that the post changed, for example from a `notify` that your wrappers send.

```js
let typing
post.on('change', ({ local }) => {
  if (!local) return
  clearTimeout(typing)
  typing = setTimeout(() => post.sync().catch(console.warn), 300)
})
setInterval(() => post.sync().catch(console.warn), 5000)
window.addEventListener('online', () => post.sync().catch(console.warn))
```

## Refused ops

A failure of `transport.apply` or `transport.opsSince` during `sync()` whose `code` is a SQLSTATE of one of these classes means that the server refused the op for good:

| Class | Examples | Meaning |
| --- | --- | --- |
| `22` | `22023` | The op breaks a rule: malformed, one of the causal rules V0 to V6, or ids reused with other content (two clients on one key) |
| `42` | `42501` | Your wrapper refused the writer, or an insert carries another writer's key |
| `54` | `54000` | A quota: too many device keys, too many waiting ops |
| `P0` | `P0002` | The document does not exist (for example, dropped while the client was open) |

The local replica then holds characters that the server will never have, and every later op of the key depends on them. So the client stops: it calls the `rejected` listeners once with `{error, op}`, sets `error`, and every `sync()` from then on rejects with that `YdocRejectedError`, without calling the transport. Local edits still work, so the editor does not break, but they are not sent. To recover, keep what the user typed (`value()`) if you want to offer it, and open the document again.

When the refusal answers `opsSince` (the document was dropped, or the writer's access was revoked), no op was refused: the ops sent earlier in that sync were acknowledged, and `op` is `null` in the event and on the error. The client stops in the same way.

Any other failure (no `code`, a connection error, `40001`, `57014`) is transient, from either call: `sync()` rejects with the transport's error and keeps the queue. `openYdoc` has no client to stop yet, so when its first `opsSince` fails it rejects with the transport's error as it is, whatever the code.

```js
post.on('rejected', ({ error }) => {
  console.error(error.code, error.message)
  // show the user that their last edits were not saved, then reopen
})
```

`ydoc_apply` returns `'pending'` when an op names characters the server does not have yet. The client counts that as delivered. A client that syncs with one database never gets it, because everything its ops name came from that database or from the client itself. If a waiting op is refused later, it is recorded in [`crdt.ydoc_rejected`](ydoc.md#tables), which the client does not read.

## API

Import from `client/src/index.js` (the package's main entry, `pg-crdt-client`).

| Name | Signature | Description |
| --- | --- | --- |
| `openYdoc` | `openYdoc({transport, doc, replica, create = false}): Promise<YdocClient>` | Load a document and return its client. `TypeError` for an invalid `transport`, `doc` or key (including a key with U+0000 or a lone surrogate, which Postgres cannot store); nothing is created or loaded then. |
| `value` | `client.value(): string` | The local text. |
| `insert` | `client.insert(index: number, text: string): void` | Insert `text` before UTF-16 index `index`. |
| `delete` | `client.delete(index: number, length: number): void` | Delete `length` UTF-16 units from `index`. |
| `sync` | `client.sync(): Promise<void>` | Push the queue, then pull. See [Sync](#sync). |
| `on` | `client.on('change' \| 'rejected', listener): () => void` | Listen to changes or to a refusal; returns a function that removes the listener. |
| `version` | `client.version(): Record<string, number>` | The local version vector `{key: highest seq}`. |
| `pending` | `client.pending: number` | Batches the server has not acknowledged. |
| `error` | `client.error: YdocRejectedError \| null` | The refusal that stopped the client. |
| `id`, `replica` | `client.id: string`, `client.replica: string` | The document id and the entry key. |
| `YdocRejectedError` | `class extends Error { code, op, cause }` | `code` is the SQLSTATE, `op` the refused op (`null` when `opsSince` was refused), `cause` the transport's error. |
| `isRejection` | `isRejection(err): boolean` | True for a SQLSTATE of class 22, 42, 54 or P0. |
| `codePointIndex` | `codePointIndex(text: string, index: number): number` | The code point position of a UTF-16 index, for calling `ydoc_insert` or `ydoc_delete` from JavaScript yourself. `RangeError` inside a surrogate pair. |
| `utf16Index` | `utf16Index(text: string, cp: number): number` | The inverse. |

`client/src/doc.js` (`pg-crdt-client/doc`) is the engine itself: `Doc`, `mergeOps` and the validation rules, documented in [`experiments/text-ref`](../../../../experiments/text-ref).

## Limits

- **Memory and time grow with the document.** The engine keeps one object per character, tombstones included, and is written for correctness first: integrating a remote character searches the document. On the benchmark machine, the engine replayed the automerge-paper trace (about 260,000 edits, 104,852 characters) locally in about 5 seconds, and applied it as ops in about 6.
- **Every pull carries every delete** of the document, because `ydoc_ops_since` sends them all, and a pull that changes the text walks the whole document to compute the change ranges.
- **Nothing is persisted.** The replica and the queue are in memory. Store `value()` yourself if you want to show something before the document loads.
- **No awareness of other editors.** Cursors and presence are your application's (a channel next to the document).

## How it is tested

The tests are in [`client/test`](../../client/test/): run `npm test` in `client/` for the unit and convergence tests, and `client/test/pg.sh` for the integration test against Postgres. See the [test suite](../../test/README.md#the-javascript-client).

- Position conversion, including emoji, ZWJ sequences, combining marks and lone surrogates.
- The ops the client sends, batching, retries after a lost request and after a lost response, the run limit, refusals and serialized syncs, against an in-memory server that validates every op as `ydoc_apply` does.
- 1,000 seeded runs of 2 to 5 clients with random edits, overlapping syncs, delays, and lost requests and responses: every client ends with the server's text, and its change events reproduce its text at every step.
- Against Postgres 16, 17 and 18: two clients through `ydoc_apply` and `ydoc_ops_since` that agree with `ydoc_value`; a lost response; a forged key refused with `42501`; and random edits by three clients with concurrent syncs, interleaved with `ydoc_set` saves and `ydoc_compact`.
