// Integration test against a real Postgres with the extension installed.
// Run it with ./pg.sh, which starts a throwaway cluster and sets
// PG_CRDT_CLIENT_DB; without that variable every test is skipped.
//
// The clients use the example node-postgres transport from
// docs/examples/node-postgres-transport.mjs unchanged. Its `client.query` is a
// small stand-in for node-postgres that runs each statement through psql
// (no npm dependency): parameters become psql variables (quoted by psql),
// objects are sent as JSON text as node-postgres does, rows come back as
// JSON, and an error carries its SQLSTATE in `code`.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { openYdoc, YdocRejectedError } from '../src/index.js';
import { pgTransport } from '../../docs/examples/node-postgres-transport.mjs';
import { mirror, mulberry32, TransientError } from './helpers.js';

const DB = process.env.PG_CRDT_CLIENT_DB;
const skip = DB ? false : 'PG_CRDT_CLIENT_DB is not set (run client/test/pg.sh)';

function psqlQuery(sql, params = []) {
  const args = ['-X', '-q', '-tA', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose', '-d', DB];
  params.forEach((p, k) => {
    const v = p !== null && typeof p === 'object' ? JSON.stringify(p) : String(p);
    args.push('-v', `p${k + 1}=${v}`);
  });
  const body = sql.replace(/\$(\d+)/g, (_, n) => `:'p${n}'`);
  const input = `select coalesce(json_agg(t), '[]'::json) from (${body}) t;\n`;
  return new Promise((resolve, reject) => {
    const ps = spawn('psql', args, { env: { ...process.env, PGCLIENTENCODING: 'UTF8' } });
    let out = '', err = '';
    ps.stdout.setEncoding('utf8').on('data', (d) => { out += d; });
    ps.stderr.setEncoding('utf8').on('data', (d) => { err += d; });
    ps.on('error', reject);
    ps.on('close', (code) => {
      if (code === 0) return resolve({ rows: JSON.parse(out) });
      const m = err.match(/ERROR:\s+([0-9A-Z]{5}):\s*([^\n]*)/);
      reject(Object.assign(new Error(m ? m[2] : err.trim()), { code: m ? m[1] : undefined }));
    });
    ps.stdin.end(input);
  });
}
const pg = { query: psqlQuery };
const one = async (sql, params) => Object.values((await psqlQuery(sql, params)).rows[0])[0];
const serverText = (doc) => one('select crdt.ydoc_value($1)', [doc]);

let docN = 0;
const newDoc = () => `client-test-${process.pid}-${++docN}`;

test('two clients sync through ydoc_apply and ydoc_ops_since and agree with ydoc_value', { skip }, async () => {
  const doc = newDoc();
  const alice = await openYdoc({ transport: pgTransport(pg, 'alice'), doc, replica: 'alice:laptop', create: true });
  const bob = await openYdoc({ transport: pgTransport(pg, 'bob'), doc, replica: 'bob:phone' });
  const bobView = mirror(bob);

  alice.insert(0, 'Hello \u{1F600} world');
  await alice.sync();
  await bob.sync();
  assert.equal(bob.value(), 'Hello \u{1F600} world');

  // concurrent edits on both sides, around the emoji (UTF-16 indices)
  alice.insert(8, '!');                  // after the emoji
  alice.delete(0, 1);
  bob.insert(6, '\u{1F44D}\u{1F3FD} ');  // before the emoji
  bob.insert(bob.value().length, '.');
  await Promise.all([alice.sync(), bob.sync()]);
  await alice.sync();
  await bob.sync();

  const want = await serverText(doc);
  assert.equal(alice.value(), want);
  assert.equal(bob.value(), want);
  assert.equal(bobView(), want);
  assert.equal(want, 'ello \u{1F44D}\u{1F3FD} \u{1F600}! world.');
  assert.equal(await one('select crdt.ydoc_length($1)', [doc]), Array.from(want).length);
  assert.deepEqual(await one('select crdt.ydoc_version($1)', [doc]), alice.version());
});

test('a lost response: the re-sent op is accepted once', { skip }, async () => {
  const doc = newDoc();
  const base = pgTransport(pg, 'alice');
  let loseNext = false;
  const transport = {
    ...base,
    async apply(d, op) {
      const res = await base.apply(d, op);
      if (loseNext) { loseNext = false; throw new TransientError('response lost'); }
      return res;
    },
  };
  const a = await openYdoc({ transport, doc, replica: 'alice:a', create: true });
  a.insert(0, 'abc');
  loseNext = true;
  await assert.rejects(a.sync(), TransientError);
  assert.equal(await serverText(doc), 'abc');
  a.insert(3, 'd');
  await a.sync();
  assert.equal(a.pending, 0);
  assert.equal(await serverText(doc), 'abcd');
});

test('a refused op is reported with the SQLSTATE and stops the client', { skip }, async () => {
  const doc = newDoc();
  await openYdoc({ transport: pgTransport(pg, 'alice'), doc, replica: 'alice:a', create: true });
  const forger = await openYdoc({ transport: pgTransport(pg, 'mallory'), doc, replica: 'alice:x' });
  const seen = [];
  forger.on('rejected', (e) => seen.push(e));
  forger.insert(0, 'forged');
  const err = await forger.sync().catch((e) => e);
  assert.ok(err instanceof YdocRejectedError);
  assert.equal(err.code, '42501');
  assert.match(err.message, /cannot insert characters of replica 'alice:x'/);
  assert.equal(seen.length, 1);
  assert.equal(await serverText(doc), '');
});

test('random edits by three clients with overlapping syncs, plus server-side saves and compaction', { skip }, async () => {
  const pool = ['a', 'b', ' ', '\n', 'é', '\u{1F600}', 'é', '中', "'", '\\', '$'];
  for (let seed = 1; seed <= 8; seed++) {
    const rng = mulberry32(seed);
    const doc = newDoc();
    const keys = [['alice', 'alice:1'], ['bob', 'bob:1'], ['alice', 'alice:2']];
    const clients = [];
    for (const [k, [writer, key]] of keys.entries()) {
      const c = await openYdoc({ transport: pgTransport(pg, writer), doc, replica: key, create: k === 0 });
      clients.push({ c, m: mirror(c), inflight: [] });
    }
    for (let s = 0; s < 100; s++) {
      const cl = clients[Math.floor(rng() * clients.length)];
      const r = rng();
      const cps = Array.from(cl.c.value());
      const k = Math.floor(rng() * (cps.length + 1));
      const u = cps.slice(0, k).join('').length;
      if (r < 0.45 || cps.length === 0) {
        let ins = '';
        for (let j = 0, n = 1 + Math.floor(rng() * 4); j < n; j++) ins += pool[Math.floor(rng() * pool.length)];
        cl.c.insert(u, ins);
      } else if (r < 0.7) {
        if (k < cps.length) cl.c.delete(u, cps.slice(k, k + 1 + Math.floor(rng() * 3)).join('').length);
      } else if (r < 0.93) {
        cl.inflight.push(cl.c.sync());   // not awaited: real concurrent psql sessions
      } else if (r < 0.97) {
        // a form save by another writer on the server (two-way ydoc_set), then compaction
        const txt = await serverText(doc);
        await psqlQuery('select crdt.ydoc_set($1, $2, $3)', [doc, txt + ' [saved]', 'carol']);
        await psqlQuery('select crdt.ydoc_compact($1)', [doc]);
      } else {
        await Promise.all(clients.flatMap((x) => x.inflight));
      }
    }
    await Promise.all(clients.flatMap((x) => x.inflight));
    for (let round = 0; round < 2; round++) for (const cl of clients) await cl.c.sync();
    const want = await serverText(doc);
    for (const [k, cl] of clients.entries()) {
      assert.equal(cl.c.value(), want, `seed ${seed}: client ${k}`);
      assert.equal(cl.m(), want, `seed ${seed}: client ${k} change events`);
      assert.equal(cl.c.pending, 0);
    }
    assert.deepEqual(await one('select crdt.ydoc_version($1)', [doc]), clients[0].c.version());
    assert.equal(await one('select count(*)::int from crdt.ydoc_pending_ops w join crdt.ydoc_docs d on d.id = w.doc where d.uid = $1', [doc]), 0);
    assert.equal(await one('select count(*)::int from crdt.ydoc_rejected w join crdt.ydoc_docs d on d.id = w.doc where d.uid = $1', [doc]), 0);
  }
});
