import test from 'node:test';
import assert from 'node:assert/strict';
import { openYdoc, YdocRejectedError, isRejection, codePointIndex } from '../src/index.js';
import { cmpReplica, utf8Length } from '../src/doc.js';
import { memoryServer, mirror, patch, TransientError } from './helpers.js';

// A transport that records what it sends, and can be told to fail.
function spy(transport) {
  const sent = [];
  const s = {
    sent,
    failNext: null, // 'before' | 'after' | null
    inflight: 0,
    maxInflight: 0,
    async create(doc) { return transport.create(doc); },
    async apply(doc, op) {
      s.inflight++; s.maxInflight = Math.max(s.maxInflight, s.inflight);
      try {
        sent.push(JSON.parse(JSON.stringify(op)));
        const mode = s.failNext; s.failNext = null;
        if (mode === 'before') throw new TransientError('request lost');
        const res = await transport.apply(doc, op);
        if (mode === 'after') throw new TransientError('response lost');
        return res;
      } finally { s.inflight--; }
    },
    async opsSince(doc, vv) { return transport.opsSince(doc, vv); },
  };
  return s;
}

async function setup(...keys) {
  const server = memoryServer();
  server.create('d');
  const clients = [];
  for (const key of keys) {
    const t = spy(server.transport(key.split(':')[0]));
    const c = await openYdoc({ transport: t, doc: 'd', replica: key });
    clients.push(Object.assign(c, { t }));
  }
  return { server, clients };
}

test('open: a missing document fails with P0002; create: true creates it', async () => {
  const server = memoryServer();
  const transport = server.transport('alice');
  await assert.rejects(openYdoc({ transport, doc: 'nope', replica: 'alice:a' }), { code: 'P0002' });
  const c = await openYdoc({ transport, doc: 'new', replica: 'alice:a', create: true });
  assert.equal(c.value(), '');
  assert.equal(c.id, 'new');
  assert.equal(c.replica, 'alice:a');
  await assert.rejects(openYdoc({ transport, doc: 'new', replica: 'alice:a', create: true }), { code: '23505' });
});

test('open: refuses bad arguments', async () => {
  const transport = memoryServer().transport('alice');
  await assert.rejects(openYdoc({ transport, doc: 'd', replica: 'alice:' }), TypeError);
  await assert.rejects(openYdoc({ transport, doc: 'd', replica: '' }), TypeError);
  await assert.rejects(openYdoc({ transport, doc: '', replica: 'a' }), TypeError);
  await assert.rejects(openYdoc({ transport: {}, doc: 'd', replica: 'a' }), TypeError);
  await assert.rejects(openYdoc({ transport: { apply() {}, opsSince() {} }, doc: 'd', replica: 'a', create: true }), /transport.create/);
});

test('UTF-16 positions become code point positions in the ops', async () => {
  const { server, clients: [a] } = await setup('alice:laptop');
  a.insert(0, '\u{1F600}b'); // UTF-16 length 3, 2 code points
  a.insert(3, 'c');          // after "b": code point 2
  a.insert(2, '-');          // between the emoji and b: code point 1
  a.delete(0, 2);            // the emoji: one code point
  assert.equal(a.value(), '-bc');
  await a.sync();
  assert.equal(server.text('d'), '-bc');
  assert.equal(a.t.sent.length, 1, 'one batch');
  assert.deepEqual(a.t.sent[0], {
    v: {},
    i: [['alice:laptop', 1, null, null, '\u{1F600}bc'], ['alice:laptop', 4, ['alice:laptop', 1], ['alice:laptop', 2], '-']],
    d: [['alice:laptop', 1, 1]],
  });
});

test('edits refuse positions inside a surrogate pair and unstorable text, and queue nothing', async () => {
  const { clients: [a] } = await setup('alice:a');
  a.insert(0, 'x\u{1F600}y');
  const before = a.pending;
  assert.throws(() => a.insert(2, 'z'), /splits a surrogate pair/);
  assert.throws(() => a.delete(2, 1), /splits a surrogate pair/);
  assert.throws(() => a.delete(1, 1), /splits a surrogate pair/);
  assert.throws(() => a.delete(0, 5), RangeError);
  assert.throws(() => a.delete(0, -1), RangeError);
  assert.throws(() => a.insert(5, 'z'), RangeError);
  assert.throws(() => a.insert(0, '\uD800'), /lone surrogate/);
  assert.throws(() => a.insert(0, 'a\u0000'), /U\+0000/);
  a.insert(0, '');
  a.delete(1, 0);
  assert.equal(a.value(), 'x\u{1F600}y');
  assert.equal(a.pending, before);
});

test('remote changes arrive as UTF-16 ranges of the old text', async () => {
  const { clients: [a, b] } = await setup('alice:a', 'bob:b');
  const events = [];
  b.on('change', (e) => events.push(e));
  a.insert(0, 'hello \u{1F600} world');
  await a.sync();
  await b.sync();
  assert.deepEqual(events, [{ changes: [{ from: 0, to: 0, insert: 'hello \u{1F600} world' }], local: false }]);

  events.length = 0;
  a.insert(8, '!');   // after the emoji
  a.delete(0, 1);     // the h
  a.insert(14, '?');  // at the end
  await a.sync();
  await b.sync();
  assert.equal(a.value(), 'ello \u{1F600}! world?');
  assert.deepEqual(events, [{
    changes: [{ from: 0, to: 1, insert: '' }, { from: 8, to: 8, insert: '!' }, { from: 14, to: 14, insert: '?' }],
    local: false,
  }]);
  assert.equal(patch('hello \u{1F600} world', events[0].changes), b.value());
  assert.equal(b.value(), a.value());
});

test('local edits emit local change events', async () => {
  const { clients: [a] } = await setup('alice:a');
  const events = [];
  const off = a.on('change', (e) => events.push(e));
  a.insert(0, 'ab\u{1F600}');
  a.delete(2, 2);
  off();
  a.insert(0, 'x');
  assert.deepEqual(events, [
    { changes: [{ from: 0, to: 0, insert: 'ab\u{1F600}' }], local: true },
    { changes: [{ from: 2, to: 4, insert: '' }], local: true },
  ]);
  assert.throws(() => a.on('nope', () => {}), TypeError);
});

test('a pull that changes nothing emits nothing', async () => {
  const { clients: [a, b] } = await setup('alice:a', 'bob:b');
  a.insert(0, 'abc');
  a.delete(1, 1);
  await a.sync();
  await b.sync();
  let n = 0;
  b.on('change', () => n++);
  await b.sync(); // the server sends every delete again
  await b.sync();
  assert.equal(n, 0);
});

test('typing is batched; a remote change starts a new batch', async () => {
  const { server, clients: [a, b] } = await setup('alice:a', 'bob:b');
  for (const ch of 'hello') a.insert(a.value().length, ch);
  await a.sync();
  assert.equal(a.t.sent.length, 1);
  assert.deepEqual(a.t.sent[0].i, [['alice:a', 1, null, null, 'hello']]);

  await b.sync();
  b.insert(0, '>');
  await b.sync();
  a.insert(5, '!');
  a.t.failNext = 'before';                 // keep the batch in the queue
  await assert.rejects(a.sync(), TransientError);
  // the failed sync froze the batch before sending; the pull of the next sync brings bob's '>'
  await a.sync();
  a.insert(0, '[');                         // after a remote change: a new batch
  a.insert(1, '(');
  await a.sync();
  const batches = a.t.sent.slice(1);
  assert.deepEqual(batches.map((op) => op.i.map((r) => r[4])), [['!'], ['!'], ['[(']]);
  assert.equal(server.text('d'), '[(>hello!');
  await b.sync();
  assert.equal(b.value(), '[(>hello!');
});

test('a lost response: the batch is re-sent unchanged and applied once', async () => {
  const { server, clients: [a, b] } = await setup('alice:a', 'bob:b');
  a.insert(0, 'abc');
  a.t.failNext = 'after';
  await assert.rejects(a.sync(), TransientError);
  assert.equal(a.pending, 1);
  assert.equal(server.text('d'), 'abc');   // the server did apply it
  a.insert(3, 'd');                        // more typing while offline
  await a.sync();
  assert.equal(a.pending, 0);
  assert.deepEqual(a.t.sent[1], a.t.sent[0], 're-sent byte for byte, not merged with the new typing');
  assert.deepEqual(a.t.sent[2].i, [['alice:a', 4, ['alice:a', 3], null, 'd']]);
  assert.equal(server.text('d'), 'abcd');
  await b.sync();
  assert.equal(b.value(), 'abcd');
  await a.sync();                          // nothing left: no apply call
  assert.equal(a.t.sent.length, 3);
});

test('a failed pull keeps the pushed ops acknowledged', async () => {
  const server = memoryServer();
  server.create('d');
  const inner = server.transport('alice');
  let failPull = false;
  const transport = { ...inner, async opsSince(d, vv) { if (failPull) throw new TransientError('offline'); return inner.opsSince(d, vv); } };
  const a = await openYdoc({ transport, doc: 'd', replica: 'alice:a' });
  a.insert(0, 'x');
  failPull = true;
  await assert.rejects(a.sync(), TransientError);
  assert.equal(a.pending, 0);
  failPull = false;
  await a.sync();
  assert.equal(server.text('d'), 'x');
});

test('batches stay under the server run limit', async () => {
  const { server, clients: [a] } = await setup('alice:a');
  a.insert(0, 'ab');
  for (let k = 0; k < 300; k++) a.insert(1, String(k % 10)); // each insert starts a new run
  await a.sync();
  assert.ok(a.t.sent.length >= 3);
  for (const op of a.t.sent) assert.ok(op.i.length <= 128, `${op.i.length} runs`);
  assert.equal(server.text('d'), a.value());
});

test('a refused op stops the client and is reported once', async () => {
  const server = memoryServer();
  server.create('d');
  const t = spy(server.transport('bob'));             // the server says the writer is bob
  const c = await openYdoc({ transport: t, doc: 'd', replica: 'alice:x' });
  const seen = [];
  c.on('rejected', (e) => seen.push(e));
  c.insert(0, 'forged');
  const err = await c.sync().catch((e) => e);
  assert.ok(err instanceof YdocRejectedError);
  assert.equal(err.code, '42501');
  assert.equal(err.cause.code, '42501');
  assert.deepEqual(err.op.i[0][4], 'forged');
  assert.equal(c.error, err);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].error, err);
  c.insert(0, 'more');                                // local edits still work
  await assert.rejects(c.sync(), (e) => e === err);   // but sync does not try again
  assert.equal(t.sent.length, 1);
  assert.equal(seen.length, 1);
  assert.equal(server.text('d'), '');
});

test('isRejection: SQLSTATE classes 22, 42, 54 and P0 are permanent', () => {
  for (const code of ['22023', '22004', '22P02', '42501', '54000', 'P0002']) assert.equal(isRejection({ code }), true, code);
  for (const code of ['08006', '40001', '40P01', '57014', '53300', '55P03', 'ECONNRESET', undefined]) {
    assert.equal(isRejection({ code }), false, String(code));
  }
  assert.equal(isRejection(null), false);
  assert.equal(isRejection(new Error('x')), false);
});

test('sync calls are serialized, and calls made while one waits share the next run', async () => {
  const server = memoryServer({ maxDelay: 3, rng: () => 0.99 });
  server.create('d');
  const t = spy(server.transport('alice'));
  const a = await openYdoc({ transport: t, doc: 'd', replica: 'alice:a' });
  a.insert(0, 'a');
  const p1 = a.sync();
  const p1b = a.sync();          // p1 has not started: same run
  assert.equal(p1b, p1);
  await new Promise((r) => setTimeout(r, 0));
  a.insert(1, 'b');              // typed while p1 is in flight
  const p2 = a.sync();
  const p3 = a.sync();
  assert.equal(p3, p2);
  assert.notEqual(p2, p1);
  a.insert(2, 'c');
  await Promise.all([p1, p2]);
  assert.equal(t.maxInflight, 1);
  assert.equal(a.pending, 0);
  assert.equal(server.text('d'), 'abc');
});

test('reopening with the same key continues its numbering', async () => {
  const server = memoryServer();
  server.create('d');
  const t = server.transport('alice');
  const a1 = await openYdoc({ transport: t, doc: 'd', replica: 'alice:a' });
  a1.insert(0, 'one ');
  await a1.sync();
  a1.insert(4, 'lost'); // never synced: the tab was closed
  const a2 = await openYdoc({ transport: t, doc: 'd', replica: 'alice:a' });
  assert.equal(a2.value(), 'one ');
  a2.insert(4, 'two');
  await a2.sync();
  assert.equal(server.text('d'), 'one two');
  assert.deepEqual(a2.version(), { 'alice:a': 7 });
});

test('a delete of text typed in the same batch', async () => {
  const { server, clients: [a, b] } = await setup('alice:a', 'bob:b');
  b.insert(0, 'XY');
  await b.sync();
  await a.sync();
  a.insert(1, 'abc');
  a.delete(2, 1);
  a.delete(0, 1);   // bob's X
  await a.sync();
  assert.equal(a.t.sent.length, 1);
  assert.equal(server.text('d'), 'acY');
});

test('engine helpers: code point order and UTF-8 length without Buffer', () => {
  const ids = ['b', 'a', '�', '\u{1F600}', '', 'B', 'ab', 'a', 'é', ''];
  const byBytes = (x, y) => Buffer.compare(Buffer.from(x, 'utf8'), Buffer.from(y, 'utf8'));
  for (const x of ids) for (const y of ids) assert.equal(cmpReplica(x, y), byBytes(x, y), `${x} vs ${y}`);
  assert.equal(cmpReplica('\uD800', '�'), byBytes('\uD800', '�')); // lone surrogate as U+FFFD
  for (const s of ['', 'abc', 'é', '中', '\u{1F600}', 'a\uD800b', '\uDC00']) {
    assert.equal(utf8Length(s), Buffer.byteLength(s, 'utf8'), JSON.stringify(s));
  }
});

test('the mirror helper agrees with value() through local and remote edits', async () => {
  const { clients: [a, b] } = await setup('alice:a', 'bob:b');
  const mb = mirror(b);
  a.insert(0, 'The \u{1F600} cat');
  await a.sync();
  await b.sync();
  b.insert(0, '> ');
  await b.sync();
  a.delete(4, 2);
  a.insert(4, 'grey');
  await a.sync();
  await b.sync();
  assert.equal(mb(), b.value());
  assert.equal(b.value(), '> The grey cat');
  assert.equal(codePointIndex(b.value(), b.value().length), Array.from(b.value()).length);
});

// Run fn, then collect the errors that the client rethrew on timers (a throwing
// listener's errors surface as uncaught exceptions). node:test's own handler is
// parked meanwhile, so the errors do not fail the test.
async function uncaught(fn) {
  const saved = process.listeners('uncaughtException');
  process.removeAllListeners('uncaughtException');
  const errors = [];
  const onError = (e) => errors.push(e);
  process.on('uncaughtException', onError);
  try {
    await fn();
    await new Promise((r) => setTimeout(r, 20));
  } finally {
    process.off('uncaughtException', onError);
    for (const l of saved) process.on('uncaughtException', l);
  }
  return errors;
}

test('a throwing change listener does not break edits or later listeners', async () => {
  const { clients: [a] } = await setup('alice:a');
  const seen = [];
  a.on('change', () => { throw new Error('boom 1'); });
  a.on('change', (e) => seen.push(e));
  const errors = await uncaught(() => {
    a.insert(0, 'abc');      // does not throw
    a.delete(0, 1);
  });
  assert.equal(a.value(), 'bc');
  assert.equal(a.pending, 1);
  assert.equal(seen.length, 2, 'the second listener still ran');
  assert.deepEqual(errors.map((e) => e.message), ['boom 1', 'boom 1'], 'errors are rethrown asynchronously');
  await a.sync();
  assert.equal(a.pending, 0);
});

test('a throwing change listener does not abort a sync that brings remote changes', async () => {
  const { server, clients: [a, b] } = await setup('alice:a', 'bob:b');
  a.insert(0, 'hello');
  await a.sync();
  await b.sync();
  b.on('change', () => { throw new Error('boom'); });
  const seen = [];
  b.on('change', (e) => seen.push(e));
  b.insert(0, '>');   // a local change: its listener error is isolated too
  a.insert(5, '!');
  await a.sync();
  const errors = await uncaught(async () => {
    await b.sync();   // resolves although the listener throws on the remote change
  });
  assert.equal(b.value(), '>hello!');
  assert.equal(b.pending, 0);
  assert.equal(server.text('d'), '>hello!');
  assert.equal(seen.length, 2);
  assert.equal(seen[1].local, false);
  assert.equal(errors.length, 2);
});

test('a throwing rejected listener does not mask the YdocRejectedError', async () => {
  const server = memoryServer();
  server.create('d');
  const t = spy(server.transport('bob'));
  const c = await openYdoc({ transport: t, doc: 'd', replica: 'alice:x' });
  const seen = [];
  c.on('rejected', () => { throw new Error('boom'); });
  c.on('rejected', (e) => seen.push(e));
  c.insert(0, 'forged');
  let err;
  const errors = await uncaught(async () => { err = await c.sync().catch((e) => e); });
  assert.ok(err instanceof YdocRejectedError);
  assert.equal(err.code, '42501');
  assert.equal(c.error, err);
  assert.equal(seen.length, 1);
  assert.deepEqual(errors.map((e) => e.message), ['boom']);
});

test('open refuses replica keys that Postgres cannot store, and opens nothing', async () => {
  const server = memoryServer();
  const transport = server.transport('alice');
  for (const replica of ['a\u0000:1', 'a:1\u0000', '\u0000', 'a\uD800:1', 'a:\uDC00', 'a\uD83D']) {
    await assert.rejects(openYdoc({ transport, doc: 'new', replica, create: true }), TypeError, JSON.stringify(replica));
  }
  assert.equal(server.docs.has('new'), false, 'create was not called');
  const c = await openYdoc({ transport, doc: 'new', replica: '\u{1F600}:\u{1F4F1}', create: true });
  assert.equal(c.replica, '\u{1F600}:\u{1F4F1}');
});

// A transport whose opsSince fails with `code` once `armed` is set.
function pullFails(code) {
  const server = memoryServer();
  server.create('d');
  const inner = server.transport('alice');
  const state = { armed: false, calls: 0 };
  const transport = {
    ...inner,
    async opsSince(d, vv) {
      state.calls++;
      if (state.armed) throw Object.assign(new Error('refused'), { code });
      return inner.opsSince(d, vv);
    },
  };
  return { server, transport, state };
}

test('a permanent opsSince failure stops the client like a refused op, with op null', async () => {
  for (const code of ['P0002', '42501', '22023', '54000']) {
    const { server, transport, state } = pullFails(code);
    const c = await openYdoc({ transport, doc: 'd', replica: 'alice:a' });
    const seen = [];
    c.on('rejected', (e) => seen.push(e));
    c.insert(0, 'x');
    state.armed = true;
    const err = await c.sync().catch((e) => e);
    assert.ok(err instanceof YdocRejectedError, code);
    assert.equal(err.code, code);
    assert.equal(err.op, null);
    assert.equal(err.cause.code, code);
    assert.equal(c.error, err);
    assert.equal(c.pending, 0, 'the push before the pull was acknowledged');
    assert.equal(server.text('d'), 'x');
    assert.equal(seen.length, 1);
    assert.deepEqual(seen[0], { error: err, op: null });
    const calls = state.calls;
    await assert.rejects(c.sync(), (e) => e === err);
    assert.equal(state.calls, calls, 'no further transport calls');
    assert.equal(seen.length, 1);
  }
});

test('a transient opsSince failure keeps the client running', async () => {
  const server = memoryServer();
  server.create('d');
  const inner = server.transport('alice');
  let fail = false;
  const transport = { ...inner, async opsSince(d, vv) { if (fail) throw new TransientError('offline'); return inner.opsSince(d, vv); } };
  fail = false;
  const c = await openYdoc({ transport, doc: 'd', replica: 'alice:a' });
  fail = true;
  await assert.rejects(c.sync(), TransientError);
  assert.equal(c.error, null);
  fail = false;
  c.insert(0, 'ok');
  await c.sync();
  assert.equal(server.text('d'), 'ok');
});

test('open: a permanent opsSince failure is the transport error itself (no client yet)', async () => {
  const { transport, state } = pullFails('P0002');
  state.armed = true;
  await assert.rejects(openYdoc({ transport, doc: 'd', replica: 'alice:a' }), (e) => e.code === 'P0002' && !(e instanceof YdocRejectedError));
});
