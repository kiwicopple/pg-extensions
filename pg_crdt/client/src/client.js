// A client for pg_crdt collaborative text (ydoc_): a local replica of one
// document, edited with UTF-16 positions, with a queue of local ops and a sync
// loop over a transport the application provides.
//
// Design (see ../README.md and docs/reference/client.md):
// - The local replica is the reference engine (./doc.js), the same code the
//   extension is differential-tested against.
// - Local edits become ops immediately; consecutive ops are merged into one
//   batch (mergeOps) until a remote change is integrated, or the batch reaches
//   MAX_RUNS runs. A batch that has been handed to the transport once is frozen
//   and re-sent byte for byte until the server answers, so a retry after a lost
//   response is an identical re-send, which ydoc_apply accepts as a no-op.
// - sync() pushes the batches in order through transport.apply (ydoc_apply),
//   then pulls transport.opsSince(local version) (ydoc_ops_since) and applies it
//   to the local replica on the trusted path (the server is trusted by the
//   client). Calls are serialized: one sync runs at a time.
// - A refusal (an error whose code is a SQLSTATE of class 22, 42, 54 or P0) is
//   permanent: the local replica now holds characters the server does not, so
//   the client stops syncing and reports it. Any other error is transient: the
//   queue is kept and the next sync() retries. The same split applies to a
//   failed transport.opsSince during sync(), except that no op was refused.
// - A listener that throws never breaks the client: every listener is called,
//   and each error is rethrown asynchronously (see reportError).

import { Doc, mergeOps, isReplicaKey } from './doc.js';
import { codePointIndex, checkStorable } from './utf16.js';

// ydoc_apply refuses an op with more than 256 runs (after joining runs that
// continue each other). Batches stay well below.
const MAX_RUNS = 128;

/**
 * The calls the client makes to the server. Implement them with any driver or
 * API layer: node-postgres, postgres.js, an RPC endpoint, fetch.
 *
 * @typedef {object} Transport
 * @property {(doc: string, op: Op) => Promise<string>} apply
 *   Send one op to `crdt.ydoc_apply(doc, op, writer)` (usually through your
 *   own wrapper, which decides the writer). Resolve with its result
 *   (`'accepted'` or `'pending'`). On failure, reject with an error whose
 *   `code` is the SQLSTATE when the server refused the op.
 * @property {(doc: string, vv: Record<string, number>) => Promise<Op | string>} opsSince
 *   Return `crdt.ydoc_ops_since(doc, vv)`, as an object or as JSON text.
 * @property {(doc: string) => Promise<unknown>} [create]
 *   Create the document (`crdt.ydoc_create(doc)`, through your wrapper). Only
 *   needed for `openYdoc({create: true})`.
 */

/**
 * An op in pg_crdt's wire format. Positions inside an op are ids, not indices.
 *
 * @typedef {object} Op
 * @property {Record<string, number>} [v] The sender's version vector before the op.
 * @property {Array<[string, number, [string, number] | null, [string, number] | null, string]>} i Inserts.
 * @property {Array<[string, number, number]>} d Deletes.
 */

/**
 * One replacement in UTF-16 positions of the text before the change event:
 * replace `text.slice(from, to)` with `insert`. The changes of one event are
 * sorted and do not overlap, and all refer to the old text (as CodeMirror's
 * `changes` do). To patch a plain string, apply them from last to first.
 *
 * @typedef {{from: number, to: number, insert: string}} Change
 */

/**
 * @typedef {object} ChangeEvent
 * @property {Change[]} changes
 * @property {boolean} local True for the client's own insert() and delete().
 */

/**
 * @typedef {object} RejectedEvent
 * @property {YdocRejectedError} error
 * @property {Op | null} op The op the server refused, or null when the refusal
 *   answered a pull (`transport.opsSince`) and no op was refused.
 */

/**
 * The server refused an op, or refused to send changes (`op` is null). The
 * client stops syncing; open the document again.
 */
export class YdocRejectedError extends Error {
  /**
   * @param {any} cause The transport's error.
   * @param {Op | null} op The refused op, or null for a failed pull.
   */
  constructor(cause, op) {
    super(`the server refused ${op ? 'an op' : 'to send changes'} (${cause?.code}): ${cause?.message ?? cause}`, { cause });
    this.name = 'YdocRejectedError';
    /** @type {string} The SQLSTATE. */
    this.code = cause?.code;
    /** @type {Op | null} */
    this.op = op;
  }
}

/**
 * True when `err` means the server refused an op for good: its `code` is a
 * SQLSTATE of class 22 (invalid op or rule V0 to V6), 42 (permission), 54
 * (a quota) or P0 (the document does not exist). Anything else (no code, a
 * connection error, a serialization failure) is treated as transient.
 *
 * @param {any} err
 * @returns {boolean}
 */
export function isRejection(err) {
  return typeof err?.code === 'string' && /^(22|42|54|P0)/.test(err.code);
}

// The engine, plus a record of the items that a remote apply turns into
// tombstones, so the client can compute change events.
class TrackedDoc extends Doc {
  constructor() {
    super();
    /** @type {Set<object> | null} */
    this.killed = null;
  }
  _markDeleted(it) {
    if (this.killed && !it.del) this.killed.add(it);
    super._markDeleted(it);
  }
}

export class YdocClient {
  /**
   * Use `openYdoc`, which also loads the document.
   *
   * @param {Transport} transport
   * @param {string} doc
   * @param {string} replica
   */
  constructor(transport, doc, replica) {
    if (!transport || typeof transport.apply !== 'function' || typeof transport.opsSince !== 'function') {
      throw new TypeError('transport must have apply(doc, op) and opsSince(doc, vv)');
    }
    if (typeof doc !== 'string' || doc === '') throw new TypeError('doc must be a non-empty string');
    if (!isReplicaKey(replica)) {
      throw new TypeError(`replica must be an entry key (an id, or <id>:<device>), got ${JSON.stringify(replica)}`);
    }
    checkStorable(replica); // Postgres cannot store U+0000 or a lone surrogate in a key
    this._transport = transport;
    this._id = doc;
    this._replica = replica;
    this._doc = new TrackedDoc();
    this._text = '';
    /** @type {Op | null} the batch that local edits still extend */
    this._open = null;
    /** @type {Op[]} frozen batches, sent in order, each re-sent unchanged until acknowledged */
    this._outbox = [];
    /** @type {YdocRejectedError | null} */
    this._error = null;
    this._listeners = { change: new Set(), rejected: new Set() };
    this._running = null;
    this._next = null;
  }

  /** The document id. */
  get id() { return this._id; }
  /** The entry key this client writes under. */
  get replica() { return this._replica; }
  /** The number of local batches the server has not acknowledged. */
  get pending() { return this._outbox.length + (this._open ? 1 : 0); }
  /** The refusal that stopped this client, or null. */
  get error() { return this._error; }

  /** The text of the local replica. */
  value() { return this._text; }

  /** The local version vector `{key: highest seq}`. */
  version() { return this._doc.versionVector(); }

  /**
   * Insert `text` before UTF-16 index `index` (0 is the start, `value().length` the end).
   *
   * @param {number} index
   * @param {string} text
   * @throws {RangeError} `index` is outside the text or inside a surrogate pair.
   * @throws {TypeError} `text` has a lone surrogate or U+0000.
   */
  insert(index, text) {
    checkStorable(text);
    const cp = codePointIndex(this._text, index);
    if (text === '') return;
    this._queue(this._doc.localInsert(this._replica, cp, text));
    this._text = this._text.slice(0, index) + text + this._text.slice(index);
    this._emit('change', { changes: [{ from: index, to: index, insert: text }], local: true });
  }

  /**
   * Delete `length` UTF-16 units from `index`.
   *
   * @param {number} index
   * @param {number} length
   * @throws {RangeError} The range is outside the text, or cuts a surrogate pair.
   */
  delete(index, length) {
    if (!Number.isInteger(length) || length < 0) throw new RangeError(`length ${length} is not a whole number >= 0`);
    const a = codePointIndex(this._text, index);
    const b = codePointIndex(this._text, index + length);
    if (length === 0) return;
    this._queue(this._doc.localDelete(this._replica, a, b - a));
    this._text = this._text.slice(0, index) + this._text.slice(index + length);
    this._emit('change', { changes: [{ from: index, to: index + length, insert: '' }], local: true });
  }

  /**
   * Listen to `'change'` (a ChangeEvent, after every local or remote change of
   * the text) or `'rejected'` (a RejectedEvent, once, when the server refuses
   * an op or refuses to send changes). Returns a function that removes the
   * listener. A listener that throws does not affect the client or the other
   * listeners: its error is rethrown asynchronously (an uncaught exception in
   * Node, `window.onerror` in a browser).
   *
   * @overload
   * @param {'change'} type
   * @param {(e: ChangeEvent) => void} fn
   * @returns {() => void}
   */
  /**
   * @overload
   * @param {'rejected'} type
   * @param {(e: RejectedEvent) => void} fn
   * @returns {() => void}
   */
  /**
   * @param {'change' | 'rejected'} type
   * @param {(e: any) => void} fn
   * @returns {() => void}
   */
  on(type, fn) {
    const set = this._listeners[type];
    if (!set) throw new TypeError(`unknown event ${JSON.stringify(type)}`);
    set.add(fn);
    return () => set.delete(fn);
  }

  /**
   * Push the local ops (transport.apply), then pull and apply what the server
   * has that this replica lacks (transport.opsSince). One sync runs at a time:
   * a call made while one runs waits for it and then runs once more (calls
   * made in the meantime share that run). Safe to call again after any
   * failure; unacknowledged ops are re-sent unchanged.
   *
   * @returns {Promise<void>} Rejects with the transport's error (transient:
   *   retry later), or with a YdocRejectedError (permanent).
   */
  sync() {
    if (this._next) return this._next;
    const prev = this._running ?? Promise.resolve();
    const run = prev.catch(() => {}).then(() => {
      this._next = null;
      this._running = run;
      return this._syncOnce();
    });
    run.finally(() => { if (this._running === run) this._running = null; }).catch(() => {});
    this._next = run;
    return run;
  }

  async _syncOnce() {
    if (this._error) throw this._error;
    if (this._open) { this._outbox.push(this._open); this._open = null; }
    while (this._outbox.length) {
      const op = this._outbox[0];
      try {
        await this._transport.apply(this._id, op);
      } catch (err) {
        if (isRejection(err)) this._reject(err, op);
        throw err;
      }
      this._outbox.shift();
    }
    let ops;
    try {
      ops = await this._transport.opsSince(this._id, this._doc.versionVector());
    } catch (err) {
      if (isRejection(err)) this._reject(err, null);
      throw err;
    }
    this._applyRemote(ops);
  }

  // Stop the client: record the refusal, tell the listeners, throw it.
  // `op` is null when the refusal answered a pull.
  _reject(cause, op) {
    this._error = new YdocRejectedError(cause, op);
    this._emit('rejected', { error: this._error, op });
    throw this._error;
  }

  async _pull() {
    const ops = await this._transport.opsSince(this._id, this._doc.versionVector());
    this._applyRemote(ops);
  }

  _queue(op) {
    if (this._open) {
      const merged = mergeOps([this._open, op]);
      if (merged.i.length <= MAX_RUNS) { this._open = merged; return; }
      this._outbox.push(this._open);
    }
    this._open = op;
  }

  // Apply a catch-up op from the server and emit the change, in UTF-16
  // positions of the old text. Items are never moved or revived, so walking
  // the items in order and comparing "visible before" with "visible now" gives
  // the exact changes.
  _applyRemote(ops) {
    const doc = this._doc;
    const n0 = doc.nextN;
    const killed = new Set();
    doc.killed = killed;
    try {
      doc.apply(ops);
    } finally {
      doc.killed = null;
    }
    if (doc.nextN === n0 && killed.size === 0) return;
    // Local ops made from now on see foreign items: they start a new batch.
    if (doc.nextN !== n0 && this._open) { this._outbox.push(this._open); this._open = null; }

    /** @type {Change[]} */
    const changes = [];
    let pos = 0;
    let cur = null;
    for (const it of doc.items) {
      const was = it.n < n0 && (!it.del || killed.has(it));
      const is = !it.del;
      if (was === is) {
        if (was) { cur = null; pos += it.ch.length; }
        continue;
      }
      if (!cur) { cur = { from: pos, to: pos, insert: '' }; changes.push(cur); }
      if (was) { cur.to += it.ch.length; pos += it.ch.length; }
      else cur.insert += it.ch;
    }
    if (!changes.length) return;
    let text = this._text;
    for (let k = changes.length - 1; k >= 0; k--) {
      const c = changes[k];
      text = text.slice(0, c.from) + c.insert + text.slice(c.to);
    }
    this._text = text;
    this._emit('change', { changes, local: false });
  }

  // Call every listener; one that throws neither stops the others nor breaks
  // the caller (an edit, a sync, a refusal).
  _emit(type, event) {
    for (const fn of [...this._listeners[type]]) {
      try {
        fn(event);
      } catch (err) {
        reportError(err);
      }
    }
  }
}

// Rethrow a listener's error where nothing in the client can catch it: on a
// timer, so it surfaces as an uncaught exception (Node) or `window.onerror`
// (browsers), as an error in a DOM event listener does.
function reportError(err) {
  setTimeout(() => { throw err; }, 0);
}

/**
 * Open a document: load it from the server with `opsSince(doc, {})`, then
 * return a client that edits it under the entry key `replica`.
 *
 * `replica` must be used by one live client at a time (for example the user's
 * replica id and a device id kept in local storage, `alice:7f3a`). The server
 * accepts inserts only under the writer's own replica id or its device keys.
 *
 * @param {object} options
 * @param {Transport} options.transport
 * @param {string} options.doc The document id.
 * @param {string} options.replica The entry key to write under.
 * @param {boolean} [options.create] Call `transport.create(doc)` first.
 * @returns {Promise<YdocClient>}
 */
export async function openYdoc({ transport, doc, replica, create = false }) {
  const client = new YdocClient(transport, doc, replica);
  if (create) {
    if (typeof transport.create !== 'function') throw new TypeError('create: true needs transport.create(doc)');
    await transport.create(doc);
  }
  await client._pull();
  return client;
}
