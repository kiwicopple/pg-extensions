# pg-crdt-client

Use `pg-crdt-client` to connect a JavaScript editor to a pg_crdt document stored in the extension's tables (`ydoc_`). It keeps a local copy, queues edits for sync, and reports remote changes to your editor. You provide the transport that calls `crdt.ydoc_apply` and `crdt.ydoc_ops_since` on your server.

The client uses JavaScript string positions (UTF-16) and handles conversion for Postgres. It runs in Node.js 20+ and browsers, uses ESM with JSDoc types, and needs no dependencies or build step.

```js
import { openYdoc } from './src/index.js'

const post = await openYdoc({ transport, doc: 'post-1', replica: 'bob:laptop' })
post.on('change', ({ changes, local }) => { /* patch the editor */ })
post.insert(0, 'Hello \u{1F600}')
await post.sync()
```

Documentation: [`docs/reference/client.md`](../docs/reference/client.md). Example transport: [`docs/examples/node-postgres-transport.mjs`](../docs/examples/node-postgres-transport.mjs).

| File | What |
| --- | --- |
| `src/index.js` | The public API: `openYdoc`, `YdocClient`, `YdocRejectedError`, `isRejection`, `codePointIndex`, `utf16Index`. |
| `src/client.js` | The client: queue, batches, sync, change events, refusals. |
| `src/utf16.js` | Position conversion and the check for text Postgres cannot store. |
| `src/doc.js` | The engine: the YjsMod reference CRDT that the extension is differential-tested against (`experiments/text-ref/ref.mjs` re-exports it). |
| `test/` | `npm test` (unit and convergence, no database) and `./test/pg.sh` (Postgres). See [`test/README.md`](../test/README.md#the-javascript-client). |
