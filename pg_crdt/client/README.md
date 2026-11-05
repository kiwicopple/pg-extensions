# pg-crdt-client

A JavaScript client for pg_crdt collaborative text (`ydoc_`): a local replica of one document, edits at UTF-16 positions, change events for an editor, an op queue and a sync loop through `crdt.ydoc_apply` and `crdt.ydoc_ops_since`, over a transport you write. Plain ESM with JSDoc types, no dependencies, no build step; Node.js 20+ and browsers.

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
