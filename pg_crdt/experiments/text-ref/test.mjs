// Self-tests for ref.mjs. `node test.mjs` exits 0 on success, 1 on failure.
import assert from 'node:assert/strict';
import { Doc, OpRejected, mergeOps } from './ref.mjs';
import { mulberry32, ri, pick, shuffle, simulate, randLocalOp } from './sim.mjs';
import { byzSim, tryApply } from './byz.mjs';

let passed = 0;
function t(name, fn) {
  try { fn(); passed++; console.log('ok  ' + name); }
  catch (e) { console.error('FAIL ' + name + '\n' + (e.stack || e)); process.exitCode = 1; }
}
const cpLen = (s) => Array.from(s).length;

t('basic local edits', () => {
  const d = new Doc();
  d.localInsert('a', 0, 'Hello');
  d.localInsert('a', 5, ' World');
  d.localDelete('a', 5, 1);
  assert.equal(d.text(), 'HelloWorld');
  d.localInsert('a', 0, '\u{1F600}x');
  assert.equal(d.text(), '\u{1F600}xHelloWorld');
  assert.equal(d.length(), 12);
  d.localDelete('a', 0, 1); // deletes one code point, not one UTF-16 unit
  assert.equal(d.text(), 'xHelloWorld');
  assert.deepEqual(d.versionVector(), { a: 13 }); // 5 + 6 + 2 inserted chars
});

t('op wire format matches brief', () => {
  const d = new Doc();
  const o1 = d.localInsert('alice', 0, 'Hello');
  assert.deepEqual(o1, { v: {}, i: [['alice', 1, null, null, 'Hello']], d: [] });
  const o2 = d.localInsert('bob', 5, '!');
  assert.deepEqual(o2.i, [['bob', 1, ['alice', 5], null, '!']]);
  assert.deepEqual(o2.v, { alice: 5 });
  const o3 = d.localDelete('alice', 1, 3);
  assert.deepEqual(o3.d, [['alice', 2, 3]]);
  assert.deepEqual(o3.v, { alice: 5, bob: 1 });
});

t('non-interleaving: concurrent aaaa / bbbb at same spot', () => {
  for (const [n1, n2] of [['alice', 'bob'], ['bob', 'alice'], ['a', 'b']]) {
    const base = new Doc();
    const o0 = base.localInsert('base', 0, 'XY');
    const A = new Doc(), B = new Doc();
    A.apply(o0); B.apply(o0);
    // typed one char at a time, as a user would
    const opsA = [], opsB = [];
    for (let k = 0; k < 4; k++) opsA.push(A.localInsert(n1, 1 + k, 'a'));
    for (let k = 0; k < 4; k++) opsB.push(B.localInsert(n2, 1 + k, 'b'));
    for (const o of opsB) A.apply(o);
    for (const o of opsA.slice().reverse()) B.apply(o); // reversed delivery (buffered)
    assert.equal(A.text(), B.text());
    assert.match(A.text(), /^X(aaaabbbb|bbbbaaaa)Y$/);
    // single-run variant
    const C = new Doc(), D = new Doc();
    C.apply(o0); D.apply(o0);
    const oc = C.localInsert(n1, 1, 'aaaa'), od = D.localInsert(n2, 1, 'bbbb');
    C.apply(od); D.apply(oc);
    assert.equal(C.text(), D.text());
    assert.match(C.text(), /^X(aaaabbbb|bbbbaaaa)Y$/);
    // lower replica id (code point order) goes first
    assert.equal(C.text(), n1 < n2 ? 'XaaaabbbbY' : 'XbbbbaaaaY');
    assert.equal(A.text(), n1 < n2 ? 'XaaaabbbbY' : 'XbbbbaaaaY');
  }
});

t('replica order is code point order, not UTF-16 / locale order', () => {
  // U+FFFD (BMP) vs U+1F600 (non-BMP): code point order: FFFD < 1F600; UTF-16 order is the opposite.
  const lo = '�', hi = '\u{1F600}';
  const base = new Doc(); const o0 = base.localInsert('base', 0, '.');
  const A = new Doc(), B = new Doc(); A.apply(o0); B.apply(o0);
  const oa = A.localInsert(lo, 1, 'L'), ob = B.localInsert(hi, 1, 'H');
  A.apply(ob); B.apply(oa);
  assert.equal(A.text(), '.LH');
  assert.equal(B.text(), '.LH');
  // uppercase before lowercase in C order (localeCompare would say otherwise)
  const C = new Doc(), D = new Doc(); C.apply(o0); D.apply(o0);
  const oc = C.localInsert('b', 1, 'b'), od = D.localInsert('B', 1, 'B');
  C.apply(od); D.apply(oc);
  assert.equal(C.text(), '.Bb');
  assert.equal(D.text(), '.Bb');
});

t('delete before insert is held; idempotent', () => {
  const A = new Doc();
  const oi = A.localInsert('a', 0, 'abcdef');
  const od = A.localDelete('a', 1, 3);
  const B = new Doc();
  B.apply(od); B.apply(od);
  assert.equal(B.text(), '');
  B.apply(oi); B.apply(oi);
  assert.equal(B.text(), 'aef');
  assert.equal(B.text(), A.text());
  assert.equal(B.pendingCount(), 0);
});

t('missing origins are buffered', () => {
  const A = new Doc();
  const o1 = A.localInsert('a', 0, 'abc');
  const o2 = A.localInsert('b', 3, 'XY'); // after A's c
  const B = new Doc();
  B.apply(o2);
  assert.equal(B.text(), '');
  assert.equal(B.pendingCount(), 1);
  B.apply(o1);
  assert.equal(B.text(), 'abcXY');
  assert.equal(B.pendingCount(), 0);
});

t('malformed ops rejected, state untouched', () => {
  const d = new Doc();
  for (const bad of [{ i: [['a:b', 1, null, null, 'x']] }, { i: [['', 1, null, null, 'x']] },
    { i: [['a', 0, null, null, 'x']] }, { i: [['a', 1, null, null, '']] }, { i: [['a', 1, null]] },
    { d: [['a', 1, 0]] }, { d: [['a', 1]] }, { i: 'x' }, null]) {
    assert.throws(() => d.apply(bad), TypeError);
  }
  assert.equal(d.text(), '');
  assert.equal(d.pendingCount(), 0);
});

t('opsSince: sync from vv gives same text; missing inserts only', () => {
  const rnd = mulberry32(7);
  const { docs } = simulate(7, { names: ['a', 'b', 'c'], nOps: 60 });
  const src = docs[0];
  const full = src.opsSince({});
  const fresh = new Doc();
  fresh.apply(full);
  assert.equal(fresh.pendingCount(), 0, 'opsSince order is causal');
  assert.equal(fresh.text(), src.text());
  // partial: a peer with a prefix of each replica's seqs
  const vv = {};
  for (const [r, n] of Object.entries(src.versionVector())) vv[r] = ri(rnd, 0, n);
  const delta = src.opsSince(vv);
  const total = (op) => op.i.reduce((s, run) => s + cpLen(run[4]), 0);
  const want = Object.entries(src.versionVector()).reduce((s, [r, n]) => s + n - vv[r], 0);
  assert.equal(total(delta), want);
  for (const run of delta.i) assert.ok(run[1] > vv[run[0]]);
});

t('opsSince incremental sync converges', () => {
  const rnd = mulberry32(99);
  const A = new Doc(), B = new Doc();
  for (let round = 0; round < 200; round++) {
    const x = rnd() < 0.5 ? A : B, name = x === A ? 'a' : 'b';
    randLocalOp(rnd, x, name);
    if (rnd() < 0.2) { const [s, r] = rnd() < 0.5 ? [A, B] : [B, A]; r.apply(s.opsSince(r.versionVector())); }
  }
  A.apply(B.opsSince(A.versionVector())); B.apply(A.opsSince(B.versionVector()));
  assert.equal(A.text(), B.text());
  assert.deepEqual(A.versionVector(), B.versionVector());
});

t('mergeOps coalesces and replays identically', () => {
  const rnd = mulberry32(5);
  const A = new Doc(); const ops = [];
  for (let k = 0; k < 100; k++) ops.push(randLocalOp(rnd, A, 'a', { maxRun: 3 }));
  const B = new Doc(); B.apply(mergeOps(ops));
  assert.equal(B.text(), A.text());
  assert.equal(B.pendingCount(), 0);
  // typing char by char coalesces to one run
  const C = new Doc(); const typed = [];
  for (const ch of 'hello') typed.push(C.localInsert('a', C.length(), ch));
  assert.deepEqual(mergeOps(typed).i, [['a', 1, null, null, 'hello']]);
});

t('convergence fuzz (random order, duplicates, 2-6 replicas, 300 seeds)', () => {
  const all = ['alice', 'bob', 'carol', 'dave', 'Eve', 'zed'];
  for (let seed = 1; seed <= 300; seed++) {
    const rnd = mulberry32(seed * 7919);
    const n = ri(rnd, 2, 6);
    const names = shuffle(rnd, all.slice()).slice(0, n);
    const { docs, log } = simulate(seed, { names, nOps: ri(rnd, 20, 150), syncProb: pick(rnd, [0.05, 0.2, 0.5]) });
    const text0 = docs[0].text();
    for (const d of docs) {
      assert.equal(d.text(), text0, `seed ${seed}`);
      assert.equal(d.pendingCount(), 0, `seed ${seed} pending`);
      assert.deepEqual(d.versionVector(), docs[0].versionVector());
    }
    // a brand new replica fed the whole log in random order with duplicates converges too
    const f = new Doc();
    const order = shuffle(rnd, log.concat(log.filter(() => rnd() < 0.3)));
    for (const o of order) f.apply(o);
    assert.equal(f.text(), text0, `seed ${seed} fresh`);
    // and via opsSince
    const g = new Doc(); g.apply(docs[0].opsSince({}));
    assert.equal(g.text(), text0, `seed ${seed} opsSince`);
    assert.equal(g.pendingCount(), 0);
  }
});

t('large concurrent sessions converge (heavy conflicts, 4 replicas x 600 ops)', () => {
  const { docs } = simulate(4242, { names: ['alice', 'bob', 'carol', 'dave'], nOps: 600, syncProb: 0.03, maxRun: 12 });
  for (const d of docs) assert.equal(d.text(), docs[0].text());
});

// ---------------------------------------------------------------------------------------------
// Validation rules (untrusted path): see README "Validation rules".
const V = { validate: true };
const rejects = (doc, op, re) => assert.throws(() => doc.apply(op, V), (e) => e instanceof OpRejected && e.code === '22023' && re.test(e.reason));

t('original repro: non-adjacent originRight is rejected, replicas converge', () => {
  const alice = new Doc(); const oa = alice.localInsert('alice', 0, 'abc');
  const bob = { v: {}, i: [['bob', 1, null, null, 'Y']], d: [] };
  const mal = { v: { alice: 3 }, i: [['mal', 1, null, ['alice', 2], 'X']], d: [] };
  // trusted path: the two delivery orders diverge (this is the hole)
  const t1 = new Doc(), t2 = new Doc();
  for (const o of [oa, bob, mal]) t1.apply(o);
  for (const o of [oa, mal, bob]) t2.apply(o);
  assert.notEqual(t1.text(), t2.text(), 'trusted path diverges on the repro');
  // validated path: X is rejected whatever the order
  for (const order of [[oa, bob, mal], [oa, mal, bob], [mal, oa, bob], [bob, mal, oa]]) {
    const d = new Doc();
    for (const o of order) tryApply(d, o);
    assert.equal(d.text(), 'abcY');
    assert.equal(d.pendingCount(), 0);
  }
  const d = new Doc(); d.apply(oa, V);
  rejects(d, mal, /V5/);
});

t('validated path: each rule rejects its violation', () => {
  const d = new Doc();
  d.apply(new Doc().localInsert('alice', 0, 'abc'), V); // a1 a2 a3
  d.apply({ v: { alice: 3 }, i: [['bob', 1, ['alice', 3], null, 'Z']], d: [] }, V); // fine
  rejects(d, { i: [], d: [] }, /malformed/);                                              // no v
  rejects(d, { v: { 'a:b': 1 }, i: [], d: [] }, /malformed/);                              // bad id in v
  rejects(d, { v: { alice: 0 }, i: [], d: [] }, /malformed/);                              // zero in v
  rejects(d, { v: { alice: 3 }, i: [['m1', 1, ['alice', 3], ['carol', 1], 'x']], d: [] }, /V1/); // or not covered
  rejects(d, { v: { alice: 3 }, i: [['m2', 2, null, null, 'x']], d: [] }, /V2/);          // seq forged
  rejects(d, { v: { alice: 3, m3: 1 }, i: [['m3', 1, null, null, 'x']], d: [] }, /V2/);   // seq reuse
  rejects(d, { v: { alice: 3 }, i: [['m4', 1, ['alice', 3], ['alice', 1], 'x']], d: [] }, /V4/); // reversed origins
  rejects(d, { v: { alice: 3 }, i: [['m5', 1, ['alice', 2], ['alice', 2], 'x']], d: [] }, /V4/); // ol == or
  rejects(d, { v: { alice: 3 }, i: [['m6', 1, ['alice', 1], ['alice', 3], 'x']], d: [] }, /V5/); // skips alice2
  rejects(d, { v: { alice: 3 }, i: [], d: [['alice', 3, 2]] }, /V6/);                      // delete past v
  rejects(d, { v: { alice: 3 }, i: [], d: [['ghost', 1, 1]] }, /V6/);                      // delete unseen id
  // V3: v claims bob:1 without alice:3 which bob1 depends on
  rejects(d, { v: { alice: 2, bob: 1 }, i: [['m7', 1, null, null, 'x']], d: [] }, /V3/);
  assert.equal(d.text(), 'abcZ');
  // rejection is atomic: second run bad -> first run not applied
  rejects(d, { v: { alice: 3, bob: 1 }, i: [['m8', 1, ['bob', 1], null, 'ok'], ['m8', 3, ['alice', 1], ['alice', 3], 'bad']], d: [] }, /V5/);
  assert.equal(d.text(), 'abcZ');
  assert.deepEqual(d.versionVector(), { alice: 3, bob: 1 });
  // chained runs in one op are fine (v advances run by run), delete may target the op's own inserts
  d.apply({ v: { alice: 3, bob: 1 }, i: [['m9', 1, ['bob', 1], null, 'AB'], ['m9', 3, ['m9', 2], null, 'C']], d: [['m9', 2, 1]] }, V);
  assert.equal(d.text(), 'abcZAC');
});

t('validated path: ops wait until the doc covers v; duplicates are no-ops', () => {
  const A = new Doc(); const o1 = A.localInsert('a', 0, 'xyz'); const o2 = A.localInsert('b', 3, '!');
  const o3 = A.localDelete('a', 0, 1);
  const B = new Doc(); const dec = [];
  B.onDecision = (op, st) => dec.push(st);
  assert.equal(B.apply(o3, V), 'pending');
  assert.equal(B.apply(o2, V), 'pending');
  assert.equal(B.apply(o2, V), 'pending');
  assert.equal(B.text(), '');
  assert.equal(B.apply(o1, V), 'accepted');
  assert.equal(B.text(), 'yz!');
  assert.equal(B.pendingCount(), 0);
  assert.equal(B.apply(o1, V), 'accepted'); assert.equal(B.apply(o2, V), 'accepted');
  assert.equal(B.text(), 'yz!');
});

t('honest fuzz through the validated path: nothing rejected, converges (300 seeds)', () => {
  const all = ['alice', 'bob', 'carol', 'dave', 'Eve', 'zed'];
  let ops = 0;
  for (let seed = 1; seed <= 300; seed++) {
    const rnd = mulberry32(seed * 104729);
    const n = ri(rnd, 2, 6);
    const names = shuffle(rnd, all.slice()).slice(0, n);
    const { docs, log, rejected } = simulate(seed, { names, nOps: ri(rnd, 20, 150), syncProb: pick(rnd, [0.05, 0.2, 0.5]), validate: true });
    assert.equal(rejected, 0, `seed ${seed}: honest op rejected`);
    ops += log.length;
    for (const d of docs) {
      assert.equal(d.text(), docs[0].text(), `seed ${seed}`);
      assert.equal(d.pendingCount(), 0, `seed ${seed} pending`);
    }
    // same ops through the trusted path give the same text
    const f = new Doc(); for (const o of shuffle(rnd, log.slice())) f.apply(o);
    assert.equal(f.text(), docs[0].text());
  }
  console.log(`     (${ops} honest ops, 0 rejected)`);
});

t('merged ops (mergeOps) from one replica pass validation', () => {
  const rnd = mulberry32(11);
  const A = new Doc(); const ops = [];
  for (let k = 0; k < 100; k++) ops.push(randLocalOp(rnd, A, 'a', { maxRun: 3 }));
  const B = new Doc(); B.apply(mergeOps(ops), V);
  assert.equal(B.text(), A.text());
  const C = new Doc();
  for (let k = 0; k < 100; k += 10) C.apply(mergeOps(ops.slice(k, k + 10)), V);
  assert.equal(C.text(), A.text());
});

const BYZ_SEEDS = 600;
t(`byzantine fuzz: identical decisions and converged text on every replica (${BYZ_SEEDS} seeds)`, () => {
  const tot = { accepted: 0, rejected: 0, pending: 0, byzAccepted: 0 };
  for (let seed = 1; seed <= BYZ_SEEDS; seed++) {
    const r = byzSim(seed, { nOps: 40 + (seed % 60) });
    assert.ok(r.ok, `seed ${seed}: ${r.problems.slice(0, 3).join(' | ')}`);
    for (const k in tot) tot[k] += r.stats[k];
  }
  assert.ok(tot.rejected > 1000 && tot.byzAccepted > 500, 'fuzz must exercise both outcomes');
  console.log(`     (ops: ${tot.accepted} accepted, ${tot.rejected} rejected, ${tot.pending} never applicable; byzantine accepted: ${tot.byzAccepted})`);
});

t('byzantine fuzz is sharp: disabling V1, V2, V3, V4 or V5 makes replicas diverge', () => {
  for (const rule of ['coverOrigins', 'ownSeq', 'closed', 'order', 'between']) {
    let bad = 0;
    for (let seed = 1; seed <= 1500 && !bad; seed++) {
      if (!byzSim(seed, { nOps: 40 + (seed % 60), rules: { [rule]: false } }).ok) bad++;
    }
    assert.ok(bad, `rule ${rule} was never needed by the fuzz`);
  }
});

t('KNOWN HOLE (not covered by V1-V6): equivocation, two ops with the same id and different content', () => {
  const o1 = { v: {}, i: [['mal', 1, null, null, 'X']], d: [] };
  const o2 = { v: {}, i: [['mal', 1, null, null, 'Z']], d: [] };
  const A = new Doc(), B = new Doc();
  tryApply(A, o1); tryApply(A, o2); tryApply(B, o2); tryApply(B, o1);
  assert.notEqual(A.text(), B.text()); // first arrival wins; needs an ownership/sequencing argument outside the CRDT
});

console.log(`${passed} tests passed` + (process.exitCode ? ' (with failures)' : ''));
