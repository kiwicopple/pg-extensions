// Deterministic fixture generator. Usage: node gen-fixtures.mjs   (writes fixtures/*.json, then run fixtures-to-sql.mjs)
// Files are overwritten in place; stale fixtures from an older generator version are not removed.
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import assert from 'node:assert/strict';
import { Doc } from './ref.mjs';
import { mulberry32, ri, pick, shuffle, simulate } from './sim.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, 'fixtures');
mkdirSync(outDir, { recursive: true });

// Random topological order of the log: an op becomes ready when every op that created
// an id it references (origins, same replica's previous seq, delete targets) is placed.
function causalOrder(rnd, log) {
  const creator = new Map(); // replica -> array seq-1 -> op index
  log.forEach((op, k) => {
    for (const [r, s, , , text] of op.i) {
      let a = creator.get(r); if (!a) creator.set(r, (a = []));
      const n = Array.from(text).length;
      for (let q = 0; q < n; q++) a[s - 1 + q] = k;
    }
  });
  const who = (r, s) => creator.get(r)?.[s - 1];
  const deps = log.map((op, k) => {
    const ds = new Set();
    for (const [r, s, ol, or] of op.i) {
      for (const id of [ol, or, s > 1 ? [r, s - 1] : null]) if (id) ds.add(who(id[0], id[1]));
    }
    for (const [r, s, len] of op.d) for (let q = 0; q < len; q++) ds.add(who(r, s + q));
    ds.delete(k);
    for (const x of ds) assert.ok(x !== undefined, 'dangling dependency');
    return ds;
  });
  const placed = new Set(), out = [];
  const remaining = new Set(log.keys());
  while (remaining.size) {
    const ready = [...remaining].filter((k) => [...deps[k]].every((x) => placed.has(x)));
    assert.ok(ready.length, 'cycle in deps');
    const k = pick(rnd, ready);
    placed.add(k); remaining.delete(k); out.push(k);
  }
  return out;
}

// Delivery order for `ops`: arbitrary order, some duplicates, total <= 200.
function deliveryOrder(rnd, log, mode) {
  const order = log.map((_, k) => k);
  if (mode === 'shuffled') shuffle(rnd, order);
  else { // mostly causal, with local swaps (out-of-order but near)
    for (let k = 0; k < order.length * 0.4; k++) {
      const i = ri(rnd, 0, order.length - 1), j = Math.min(order.length - 1, i + ri(rnd, 1, 6));
      [order[i], order[j]] = [order[j], order[i]];
    }
  }
  const room = Math.max(0, 200 - order.length);
  const dups = Math.min(room, Math.floor(order.length * 0.2));
  for (let d = 0; d < dups; d++) order.splice(ri(rnd, 0, order.length), 0, pick(rnd, log.map((_, k) => k)));
  return order;
}

function write(name, log, expected, rnd, mode) {
  const ops = deliveryOrder(rnd, log, mode).map((k) => log[k]);
  const causal = causalOrder(rnd, log).map((k) => log[k]);
  // self-check: both orders reproduce `expected`; causal order never needs buffering
  const a = new Doc(); for (const o of ops) a.apply(o);
  assert.equal(a.text(), expected); assert.equal(a.pendingCount(), 0);
  const b = new Doc();
  for (const o of causal) { b.apply(o); assert.equal(b.pendingCount(), 0, `${name}: causal order needed buffering`); }
  assert.equal(b.text(), expected);
  const fmt = (arr) => '[\n' + arr.map((o) => '  ' + JSON.stringify(o)).join(',\n') + '\n]';
  const json = `{\n"ops": ${fmt(ops)},\n"ops_causal": ${fmt(causal)},\n"expected": ${JSON.stringify(expected)}\n}\n`;
  JSON.parse(json);
  writeFileSync(join(outDir, name + '.json'), json);
  return { name, replicas: Object.keys(a.versionVector()).length, generated: log.length, delivered: ops.length, len: Array.from(expected).length };
}

const NAMES = ['alice', 'bob', 'carol', 'dave', 'Eve', 'zed'];
const summary = [];
// 50 general fuzz fixtures
for (let n = 1; n <= 50; n++) {
  const rnd = mulberry32(1000 + n);
  const nr = ri(rnd, 2, 5);
  const names = shuffle(rnd, NAMES.slice()).slice(0, nr);
  const { log, expected } = simulate(5000 + n, {
    names, nOps: ri(rnd, 15, 160), syncProb: pick(rnd, [0.05, 0.15, 0.4]),
    maxRun: pick(rnd, [3, 8, 20]), delProb: pick(rnd, [0.15, 0.3, 0.45]),
  });
  summary.push(write(`fuzz-${String(n).padStart(3, '0')}`, log, expected, rnd, n % 2 ? 'shuffled' : 'near-causal'));
}
// replica ids whose code point order differs from UTF-16 order (U+FFFD vs U+1F600) and from locale order
for (let n = 1; n <= 3; n++) {
  const rnd = mulberry32(2000 + n);
  const names = n === 3 ? ['\u{1F600}', '�', 'B', 'a'] : ['\u{1F600}', '�'];
  const { log, expected } = simulate(7000 + n, { names, nOps: 80, syncProb: 0.05, maxRun: 4 });
  summary.push(write(`unicode-replica-${String(n).padStart(3, '0')}`, log, expected, rnd, 'shuffled'));
}
// case-sensitive replica ids (C collation: "B" < "a")
{
  const rnd = mulberry32(2100);
  const { log, expected } = simulate(7100, { names: ['B', 'a', 'b', 'A'], nOps: 80, syncProb: 0.05, maxRun: 4 });
  summary.push(write('case-replica-001', log, expected, rnd, 'shuffled'));
}
// the classic: concurrent "aaaa" / "bbbb" typed at the same spot, one char at a time
{
  const rnd = mulberry32(2200);
  const base = new Doc(), A = new Doc(), B = new Doc();
  const o0 = base.localInsert('base', 0, 'XY'); A.apply(o0); B.apply(o0);
  const log = [o0];
  for (let k = 0; k < 4; k++) log.push(A.localInsert('alice', 1 + k, 'a'));
  for (let k = 0; k < 4; k++) log.push(B.localInsert('bob', 1 + k, 'b'));
  for (const o of log.slice(5)) A.apply(o);
  for (const o of log.slice(1, 5)) B.apply(o);
  assert.equal(A.text(), B.text());
  summary.push(write('non-interleave-001', log, A.text(), rnd, 'shuffled'));
}
// empty doc, and delete-everything
{
  const rnd = mulberry32(2300);
  summary.push(write('empty-001', [], '', rnd, 'shuffled'));
  const d = new Doc(); const log = [d.localInsert('alice', 0, 'hello \u{1F600} world')];
  log.push(d.localDelete('alice', 0, d.length()));
  summary.push(write('delete-all-001', log, '', rnd, 'shuffled'));
}
for (const s of summary) console.log(`${s.name}: replicas=${s.replicas} generated=${s.generated} delivered=${s.delivered} len=${s.len}`);
console.log(`${summary.length} fixtures written to fixtures/`);
