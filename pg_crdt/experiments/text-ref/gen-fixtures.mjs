// Deterministic fixture generator. Usage: node gen-fixtures.mjs   (writes fixtures/*.json, then run fixtures-to-sql.mjs)
// Files are overwritten in place; stale fixtures from an older generator version are not removed.
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import assert from 'node:assert/strict';
import { Doc, OpRejected } from './ref.mjs';
import { byzSim } from './byz.mjs';
import { mulberry32, ri, pick, shuffle, simulate } from './sim.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, 'fixtures');
mkdirSync(outDir, { recursive: true });

// Random topological order of the ops. An op is ready when the doc covers its v, i.e. every op that
// created an id (r, 1..v[r]) is placed (the untrusted path waits for exactly that). Ops in `skip`
// (rejected ones) create no ids, so nothing can depend on them.
function causalOrder(rnd, log, skip) {
  const creator = new Map(); // replica -> array seq-1 -> op index
  log.forEach((op, k) => {
    if (skip.has(k)) return;
    for (const [r, s, , , text] of op.i) {
      let a = creator.get(r); if (!a) creator.set(r, (a = []));
      const n = Array.from(text).length;
      for (let q = 0; q < n; q++) a[s - 1 + q] = k;
    }
  });
  const deps = log.map((op, k) => {
    const ds = new Set();
    for (const [r, n] of Object.entries(op.v)) {
      for (let q = 1; q <= n; q++) {
        const c = creator.get(r)?.[q - 1];
        if (c === undefined && skip.has(k)) continue; // statically rejected ops never wait (V1/V2/V6 fire on arrival)
        assert.ok(c !== undefined, `op ${k} claims an id nobody created: ${r}:${q}`);
        ds.add(c);
      }
    }
    ds.delete(k);
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

// Replay `list` through the validated path in a fresh doc. Returns { doc, rejectedPositions, decided }.
function replayValidated(list, { allowPending = false } = {}) {
  const doc = new Doc();
  const rejectedPositions = [];
  const decided = new Map();
  doc.onDecision = (op, st, reason) => decided.set(op, [st, reason]);
  list.forEach((op, p) => {
    let res;
    try { res = doc.apply(op, { validate: true }); } catch (e) { if (e instanceof OpRejected) res = 'rejected'; else throw e; }
    if (res === 'rejected') rejectedPositions.push(p);
    if (res === 'pending' && !allowPending) { /* may be decided later (delivery order is arbitrary) */ }
  });
  return { doc, rejectedPositions, decided };
}

const reasonCounts = new Map();
// `rejectedLog`: Set of log indexes that must be rejected (empty for honest fixtures).
function write(name, log, expected, rnd, mode, rejectedLog = new Set()) {
  const order = deliveryOrder(rnd, log, mode);
  const ops = order.map((k) => log[k]);
  const rejected = order.flatMap((k, p) => (rejectedLog.has(k) ? [p] : []));
  const corder = causalOrder(rnd, log, rejectedLog);
  const causal = corder.map((k) => log[k]);
  const rejectedCausal = corder.flatMap((k, p) => (rejectedLog.has(k) ? [p] : []));
  // self-checks, validated path: arbitrary order reproduces expected text and the rejected set; causal
  // order never waits
  const a = replayValidated(ops);
  assert.equal(a.doc.text(), expected, `${name}: text`); assert.equal(a.doc.pendingCount(), 0, `${name}: stuck ops`);
  assert.deepEqual(ops.flatMap((op, p) => (a.decided.get(op)[0] === 'rejected' ? [p] : [])), rejected, `${name}: rejected set`);
  for (const [op, [st, why]] of a.decided) if (st === 'rejected') reasonCounts.set(why.split(':')[0], (reasonCounts.get(why.split(':')[0]) ?? 0) + 1);
  const b = new Doc(); const decidedB = [];
  b.onDecision = (op, st) => decidedB.push(st);
  causal.forEach((op, p) => {
    let res;
    try { res = b.apply(op, { validate: true }); } catch (e) { if (e instanceof OpRejected) res = 'rejected'; else throw e; }
    assert.notEqual(res, 'pending', `${name}: causal order needed buffering at ${p}`);
    assert.equal(res === 'rejected', rejectedCausal.includes(p), `${name}: causal rejected set at ${p}`);
  });
  assert.equal(b.text(), expected); assert.equal(b.pendingCount(), 0);
  // trusted path (ignores v) reproduces the text for honest fixtures
  if (!rejectedLog.size) { const c = new Doc(); for (const o of ops) c.apply(o); assert.equal(c.text(), expected); }
  const fmt = (arr) => '[\n' + arr.map((o) => '  ' + JSON.stringify(o)).join(',\n') + '\n]';
  const json = `{\n"ops": ${fmt(ops)},\n"ops_causal": ${fmt(causal)},\n"rejected": ${JSON.stringify(rejected)},\n"rejected_causal": ${JSON.stringify(rejectedCausal)},\n"expected": ${JSON.stringify(expected)}\n}\n`;
  JSON.parse(json);
  writeFileSync(join(outDir, name + '.json'), json);
  return { name, replicas: Object.keys(a.doc.versionVector()).length, generated: log.length, delivered: ops.length, rejected: rejected.length, len: Array.from(expected).length };
}

const NAMES = ['alice', 'bob', 'carol', 'dave', 'Eve', 'zed'];
const summary = [];
// 50 general fuzz fixtures
for (let n = 1; n <= 50; n++) {
  const rnd = mulberry32(1000 + n);
  const nr = ri(rnd, 2, 5);
  const names = shuffle(rnd, NAMES.slice()).slice(0, nr);
  const { log, expected } = simulate(5000 + n, {
    validate: true, names, nOps: ri(rnd, 15, 160), syncProb: pick(rnd, [0.05, 0.15, 0.4]),
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
// Malicious fixtures. Honest replicas never see the untrusted ops; untrusted ops come from fresh replica ids
// (seq 1) that lie about origins, v and delete targets. Each must be accepted or rejected on every replica,
// whatever the delivery order. `rejected` lists positions in `ops` (duplicates included) that must be rejected.
for (let n = 1; n <= 12; n++) {
  const rnd = mulberry32(3000 + n);
  const r = byzSim(9000 + n, {
    honest: ['alice', 'bob', 'carol', 'dave'].slice(0, 2 + (n % 3)), nOps: 30 + 6 * n, byzFrac: 0.35 + 0.03 * n,
    honestSeesByz: false, nExtra: 2, byzOpts: { noRaise: true, continueProb: 0 },
  });
  assert.ok(r.ok, r.problems.join('; '));
  assert.equal(r.stats.pending, 0);
  const rejectedLog = new Set(r.statuses.flatMap((st, k) => (st[0] === 'rejected' ? [k] : [])));
  summary.push(write(`malicious-${String(n).padStart(3, '0')}`, r.log, r.texts[0], rnd, n % 2 ? 'shuffled' : 'near-causal', rejectedLog));
}
// the reviewer's repro: alice "abc", bob honest "Y", mal skips "a" with originRight = alice:2
{
  const rnd = mulberry32(3100);
  const A = new Doc(); const oa = A.localInsert('alice', 0, 'abc');
  const ob = { v: {}, i: [['bob', 1, null, null, 'Y']], d: [] };
  const om = { v: { alice: 3 }, i: [['mal', 1, null, ['alice', 2], 'X']], d: [] };
  summary.push(write('malicious-repro-001', [oa, ob, om], 'abcY', rnd, 'shuffled', new Set([2])));
}
// one violation per rule on top of an honest base (alice "abc", bob "Z" after alice:3)
{
  const rnd = mulberry32(3200);
  const A = new Doc(); const oa = A.localInsert('alice', 0, 'abc');
  const ob = { v: { alice: 3 }, i: [['bob', 1, ['alice', 3], null, 'Z']], d: [] };
  const bad = [
    { v: { alice: 3 }, i: [['m02', 1, ['alice', 3], ['carol', 1], 'x']], d: [] },                          // V1
    { v: { alice: 3 }, i: [['m03', 2, null, null, 'x']], d: [] },                                          // V2 forged seq
    { v: { alice: 3, m04: 1 }, i: [['m04', 1, null, null, 'x']], d: [] },                                  // V2 reused seq
    { v: { alice: 2, bob: 1 }, i: [['m05', 1, null, null, 'x']], d: [] },                                  // V3 not closed
    { v: { alice: 3 }, i: [['m06', 1, ['alice', 3], ['alice', 1], 'x']], d: [] },                          // V4 reversed
    { v: { alice: 3 }, i: [['m07', 1, ['alice', 2], ['alice', 2], 'x']], d: [] },                          // V4 equal
    { v: { alice: 3 }, i: [['m08', 1, ['alice', 1], ['alice', 3], 'x']], d: [] },                          // V5 skips alice:2
    { v: { alice: 3 }, i: [], d: [['alice', 3, 2]] },                                                      // V6 past v
    { v: { alice: 3 }, i: [], d: [['ghost', 1, 1]] },                                                      // V6 unseen id
    { v: { alice: 3, bob: 1 }, i: [['m09', 1, ['bob', 1], null, 'ok'], ['m09', 3, ['alice', 1], ['alice', 3], 'bad']], d: [] }, // V5, atomic
    { v: { alice: 3 }, i: [['m10', 1, ['alice', 1], ['alice', 2], '-']], d: [] },                          // fine: adjacent
    { v: { alice: 2 }, i: [['m11', 1, ['alice', 1], ['alice', 2], '+']], d: [] },                          // fine: honest stale view
  ];
  const log = [oa, ob, ...bad];
  const rejectedLog = new Set([1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((k) => k + 1));
  const doc = new Doc(); for (const o of log) { try { doc.apply(o, { validate: true }); } catch (e) { if (!(e instanceof OpRejected)) throw e; } }
  summary.push(write('malicious-rules-001', log, doc.text(), rnd, 'shuffled', rejectedLog));
}
for (const s of summary) console.log(`${s.name}: replicas=${s.replicas} generated=${s.generated} delivered=${s.delivered} rejected=${s.rejected} len=${s.len}`);
console.log('rejection reasons across fixtures:', Object.fromEntries([...reasonCounts].sort()));
console.log(`${summary.length} fixtures written to fixtures/`);
