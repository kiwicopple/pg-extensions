// N clients edit one document with random UTF-16 edits (emoji included) and
// random, overlapping sync calls, over an in-memory server that validates every
// op like ydoc_apply (the reference engine's untrusted path), delays calls by a
// random number of turns, and loses requests and responses. At the end every
// client syncs until it is quiet, and all texts must equal the server's. All
// along, each client's change events must patch a mirror string into value().
import test from 'node:test';
import assert from 'node:assert/strict';
import { openYdoc, YdocRejectedError } from '../src/index.js';
import { memoryServer, mirror, mulberry32 } from './helpers.js';

const POOL = ['a', 'b', 'c', ' ', '\n', 'é', 'é', '\u{1F600}', '\u{1F468}‍\u{1F469}', '中', '$', '\\', '"'];
const WRITERS = ['alice', 'bob', 'carol', '\u{1F600}', 'B'];

// A random UTF-16 boundary that does not split a surrogate pair.
function boundary(rng, text) {
  const cps = Array.from(text);
  const k = Math.floor(rng() * (cps.length + 1));
  let u = 0;
  for (let j = 0; j < k; j++) u += cps[j].length;
  return { u, k, cps };
}

async function trial(seed) {
  const rng = mulberry32(seed);
  const server = memoryServer({ rng, failRate: 0.15, maxDelay: 3 });
  server.create('doc');
  const n = 2 + Math.floor(rng() * 4);
  const clients = [];
  for (let k = 0; k < n; k++) {
    const writer = WRITERS[Math.floor(rng() * 3)];
    const transport = server.transport(writer);
    let c;
    for (;;) {
      try { c = await openYdoc({ transport, doc: 'doc', replica: `${writer}:${k}` }); break; }
      catch (e) { if (e.name !== 'TransientError') throw e; }
    }
    clients.push({ c, m: mirror(c), inflight: [] });
  }
  const errors = [];
  const kick = (cl) => {
    const p = cl.c.sync().catch((e) => { if (e instanceof YdocRejectedError || e.name !== 'TransientError') errors.push(e); });
    cl.inflight.push(p);
  };
  const steps = 40 + Math.floor(rng() * 80);
  for (let s = 0; s < steps; s++) {
    const cl = clients[Math.floor(rng() * n)];
    const r = rng();
    const text = cl.c.value();
    if (r < 0.45 || text.length === 0) {
      const { u } = boundary(rng, text);
      let ins = '';
      const len = 1 + Math.floor(rng() * (rng() < 0.2 ? 12 : 3));
      for (let j = 0; j < len; j++) ins += POOL[Math.floor(rng() * POOL.length)];
      cl.c.insert(u, ins);
    } else if (r < 0.7) {
      const { u, k, cps } = boundary(rng, text);
      if (k < cps.length) {
        const m = 1 + Math.floor(rng() * Math.min(4, cps.length - k));
        let len = 0;
        for (let j = k; j < k + m; j++) len += cps[j].length;
        cl.c.delete(u, len);
      }
    } else if (r < 0.9) {
      kick(cl);
    } else {
      const turns = Math.floor(rng() * 4);
      for (let t = 0; t < turns; t++) await new Promise((res) => setImmediate(res));
    }
    assert.equal(cl.m(), cl.c.value(), `seed ${seed}: mirror differs after step ${s}`);
  }
  await Promise.all(clients.flatMap((cl) => cl.inflight));
  // Quiesce: sync everyone until a full round leaves every client quiet.
  for (let round = 0; round < 50; round++) {
    for (const cl of clients) {
      for (let tries = 0; ; tries++) {
        try { await cl.c.sync(); break; }
        catch (e) { if (e.name !== 'TransientError' || tries > 50) throw e; }
      }
    }
    if (clients.every((cl) => cl.c.pending === 0 && cl.c.value() === server.text('doc'))) break;
  }
  assert.deepEqual(errors, [], `seed ${seed}: unexpected errors`);
  const want = server.text('doc');
  for (const [k, cl] of clients.entries()) {
    assert.equal(cl.c.pending, 0, `seed ${seed}: client ${k} has pending ops`);
    assert.equal(cl.c.value(), want, `seed ${seed}: client ${k} diverged`);
    assert.equal(cl.m(), want, `seed ${seed}: client ${k} mirror diverged`);
    assert.equal(cl.c._doc.text(), want, `seed ${seed}: client ${k} engine text`);
    assert.deepEqual(cl.c.version(), server.docs.get('doc').versionVector(), `seed ${seed}: client ${k} version`);
  }
  assert.equal(server.docs.get('doc').pendingCount(), 0, `seed ${seed}: ops left waiting on the server`);
  return server.stats;
}

test('random clients, edits and sync interleavings converge (1,000 seeds)', async () => {
  const total = { apply: 0, accepted: 0, pending: 0, failedBefore: 0, failedAfter: 0, opsSince: 0 };
  for (let seed = 1; seed <= 1000; seed++) {
    const stats = await trial(seed);
    for (const k of Object.keys(total)) total[k] += stats[k];
  }
  // The fuzz must exercise retries after lost requests and lost responses.
  assert.ok(total.failedBefore > 100 && total.failedAfter > 100, JSON.stringify(total));
  assert.equal(total.pending, 0, 'an honest client never has to wait on the server');
  console.log('# totals', JSON.stringify(total));
});
