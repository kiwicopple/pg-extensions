// Test helpers: a seeded PRNG and an in-memory server that behaves like
// ydoc_apply / ydoc_ops_since, backed by the reference engine's untrusted path.
import { Doc, OpRejected } from '../src/doc.js';

export function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export class TransientError extends Error {
  constructor(msg) { super(msg); this.name = 'TransientError'; this.code = '08006'; }
}

function sqlError(code, message) {
  return Object.assign(new Error(message), { code });
}

const clone = (x) => JSON.parse(JSON.stringify(x));

/**
 * An in-memory "Postgres" with one Doc per document, validating every op as
 * ydoc_apply does (V0-V7, and inserts only under the writer's own keys).
 *
 * opts.rng      seeded random source (for delays and failures)
 * opts.failRate probability that a call fails: half before the server acts
 *               (request lost), half after (response lost)
 * opts.maxDelay number of macrotask turns a call may take (random interleaving)
 */
export function memoryServer({ rng = Math.random, failRate = 0, maxDelay = 0 } = {}) {
  const docs = new Map();
  const stats = { apply: 0, accepted: 0, pending: 0, failedBefore: 0, failedAfter: 0, opsSince: 0 };
  const delay = async () => {
    const n = maxDelay ? Math.floor(rng() * (maxDelay + 1)) : 0;
    for (let k = 0; k < n; k++) await new Promise((r) => setImmediate(r));
  };
  const get = (id) => {
    const d = docs.get(id);
    if (!d) throw sqlError('P0002', `document ${id} does not exist`);
    return d;
  };
  const server = {
    docs,
    stats,
    create(id) {
      if (docs.has(id)) throw sqlError('23505', `document ${id} already exists`);
      docs.set(id, new Doc());
    },
    text(id) { return get(id).text(); },
    /** A transport for the writer whose replica id is `writer`. */
    transport(writer) {
      return {
        async create(id) { await delay(); server.create(id); return id; },
        async apply(id, op) {
          stats.apply++;
          await delay();
          if (rng() < failRate / 2) { stats.failedBefore++; throw new TransientError('request lost'); }
          const d = get(id);
          op = clone(op);
          for (const run of op.i ?? []) {
            if (run[0].split(':')[0] !== writer) {
              throw sqlError('42501', `replica '${writer}' cannot insert characters of replica '${run[0]}'`);
            }
          }
          let status;
          try {
            status = d.apply(op, { validate: true });
          } catch (e) {
            if (e instanceof OpRejected) throw sqlError('22023', e.message);
            throw e;
          }
          stats[status]++;
          await delay();
          if (rng() < failRate / 2) { stats.failedAfter++; throw new TransientError('response lost'); }
          return status;
        },
        async opsSince(id, vv) {
          stats.opsSince++;
          await delay();
          if (rng() < failRate / 2) throw new TransientError('request lost');
          const out = JSON.stringify(get(id).opsSince(clone(vv)));
          await delay();
          return rng() < 0.5 ? out : JSON.parse(out); // either shape is allowed
        },
      };
    },
  };
  return server;
}

/** Apply change events to a string, as an editor would (last change first). */
export function patch(text, changes) {
  for (let k = changes.length - 1; k >= 0; k--) {
    const c = changes[k];
    text = text.slice(0, c.from) + c.insert + text.slice(c.to);
  }
  return text;
}

/** Follow a client's change events into a mirror string; returns () => mirror. */
export function mirror(client) {
  let text = client.value();
  client.on('change', (e) => {
    for (let k = 1; k < e.changes.length; k++) {
      if (e.changes[k].from <= e.changes[k - 1].to) throw new Error('changes overlap, touch or are unsorted');
    }
    text = patch(text, e.changes);
  });
  return () => text;
}
