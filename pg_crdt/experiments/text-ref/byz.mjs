// Byzantine-writer simulation: honest replicas mixed with ops from untrusted writers that lie about
// origins, seqs, v and delete targets. Used by test.mjs (convergence of decisions) and gen-fixtures.mjs.
import { Doc, OpRejected } from './ref.mjs';
import { mulberry32, ri, pick, shuffle, randLocalOp, randText } from './sim.mjs';

export function tryApply(doc, op) {
  try { return doc.apply(op, { validate: true }); } catch (e) { if (e instanceof OpRejected) return 'rejected'; throw e; }
}

function vObj(map) {
  const o = {};
  for (const [k, n] of map) if (n > 0) Object.defineProperty(o, k, { value: n, enumerable: true, writable: true, configurable: true });
  return o;
}

// One byzantine op generated against the state of `view` (an honest doc). `mal` holds the writers' counters.
// opts.modes limits the lies; opts.noRaise forbids claiming unseen items (those ops can never be applied).
export function makeByzOp(rnd, view, others, mal, opts = {}) {
  const items = view.items, len = items.length;
  const vv = new Map(Object.entries(view.versionVector()));
  let a = ri(rnd, -1, len - 1);
  let b = Math.min(len, a + 1 + pick(rnd, [0, 0, 0, 1, 1, 2, 3]));
  if (rnd() < 0.12) { a = ri(rnd, -1, len - 1); b = ri(rnd, 0, len); } // arbitrary pair, possibly reversed or equal
  const idOf = (it) => [it.r, it.s];
  const ol = a >= 0 ? idOf(items[a]) : null;
  const or = b < len ? idOf(items[b]) : null;

  let r, seq;
  if (mal.count.size && rnd() < (opts.continueProb ?? 0.3)) {
    r = pick(rnd, [...mal.count.keys()]); seq = mal.count.get(r) + 1;
  } else {
    r = pick(rnd, ['m', 'x', 'Zq', '~', 'alice-']) + (mal.fresh++); seq = 1;
  }

  const modes = opts.modes ?? ['honest', 'honest', 'lie-down', 'lie-down', 'random', 'random', 'raise', 'stale'];
  let mode = pick(rnd, modes);
  if (mode === 'raise' && opts.noRaise) mode = 'lie-down';
  let v = new Map(vv);
  if (mode === 'lie-down') {
    for (let i = Math.min(a, b) + 1; i < Math.max(a, b); i++) { const y = items[i]; v.set(y.r, Math.min(v.get(y.r) ?? 0, y.s - 1)); }
  } else if (mode === 'random') {
    for (const [k, n] of v) v.set(k, ri(rnd, 0, n));
  } else if (mode === 'raise') {
    const k = pick(rnd, [...vv.keys(), 'ghost']); v.set(k, (v.get(k) ?? 0) + ri(rnd, 1, 3));
  } else if (mode === 'stale') {
    const o = pick(rnd, others);
    v = new Map(Object.entries(o.versionVector()));
  }
  // usually keep the claims that make the op well formed, sometimes break them on purpose
  if (rnd() < 0.9) v.set(r, seq - 1); else if (rnd() < 0.5) v.set(r, ri(rnd, 0, seq + 1));
  if (rnd() < 0.85) for (const id of [ol, or]) if (id) v.set(id[0], Math.max(v.get(id[0]) ?? 0, id[1]));

  const i = [], d = [];
  if (rnd() > 0.15) {
    const t1 = randText(rnd, 3), n1 = Array.from(t1).length;
    i.push([r, seq, ol, or, t1]);
    let total = n1;
    if (rnd() < 0.25) { // second run of the same op, chained after the first
      const t2 = randText(rnd, 3);
      const or2 = rnd() < 0.5 ? or : (len && rnd() < 0.5 ? idOf(items[ri(rnd, 0, len - 1)]) : null);
      i.push([r, seq + n1, rnd() < 0.8 ? [r, seq + n1 - 1] : ol, or2, t2]);
      total += Array.from(t2).length;
    }
    mal.count.set(r, seq + total - 1);
  }
  if (!i.length || rnd() < 0.3) {
    for (let k = ri(rnd, 1, 2); k > 0; k--) {
      if (len && rnd() < 0.7) { const y = items[ri(rnd, 0, len - 1)]; d.push([y.r, y.s, ri(rnd, 1, 3)]); }
      else d.push([pick(rnd, ['alice', 'bob', 'ghost', r]), ri(rnd, 1, 12), ri(rnd, 1, 3)]);
    }
  }
  if (opts.noRaise && !i.length) v.delete(r); // a delete-only op that claims its own (nonexistent) ids would wait forever
  return { v: vObj(v), i, d };
}

// Returns { ok, problems, stats, log, kinds, texts, statuses }.
export function byzSim(seed, o = {}) {
  const { honest = ['alice', 'bob', 'carol'], nOps = 60, byzFrac = 0.4, rules, honestSeesByz = true,
    syncProb = 0.25, dupProb = 0.15, nExtra = 2, byzOpts = {} } = o;
  const rnd = mulberry32(seed);
  const mk = () => new Doc({ rules });
  const docs = honest.map(mk);
  const extra = Array.from({ length: nExtra }, mk);
  const all = docs.concat(extra);
  const status = all.map(() => new Map());
  all.forEach((d, k) => { d.onDecision = (op, st) => status[k].set(op, st); });
  const log = [], kinds = [];
  const delivered = docs.map(() => new Set());
  const mal = { count: new Map(), fresh: 0 };

  const syncSome = (to) => {
    const missing = [];
    for (let k = 0; k < log.length; k++) if (!delivered[to].has(k) && (honestSeesByz || kinds[k] === 'honest')) missing.push(k);
    if (!missing.length) return;
    for (const k of shuffle(rnd, missing).slice(0, ri(rnd, 1, missing.length))) {
      tryApply(docs[to], log[k]); delivered[to].add(k);
      if (rnd() < dupProb) tryApply(docs[to], log[k]);
    }
  };
  while (log.length < nOps) {
    if (rnd() < syncProb) { syncSome(ri(rnd, 0, docs.length - 1)); continue; }
    if (rnd() < byzFrac) {
      const viewIdx = ri(rnd, 0, docs.length - 1);
      log.push(makeByzOp(rnd, docs[viewIdx], docs, mal, byzOpts)); kinds.push('byz');
    } else {
      const who = ri(rnd, 0, docs.length - 1);
      const op = randLocalOp(rnd, docs[who], honest[who], { maxRun: 5 });
      log.push(op); kinds.push('honest');
      delivered[who].add(log.length - 1); status[who].set(op, 'accepted');
    }
  }
  // final delivery: every checker gets everything, own random order, with duplicates
  all.forEach((d, t) => {
    const todo = [];
    for (let k = 0; k < log.length; k++) todo.push(k);
    for (const k of shuffle(rnd, todo)) {
      tryApply(d, log[k]);
      if (rnd() < dupProb) tryApply(d, log[k]);
    }
  });

  const problems = [];
  const texts = all.map((d) => d.text());
  if (new Set(texts).size !== 1) problems.push('texts differ: ' + JSON.stringify(texts));
  const vvs = all.map((d) => JSON.stringify(Object.entries(d.versionVector()).sort()));
  if (new Set(vvs).size !== 1) problems.push('version vectors differ');
  const statuses = log.map((op, k) => all.map((_, t) => status[t].get(op) ?? 'pending'));
  statuses.forEach((st, k) => { if (new Set(st).size !== 1) problems.push(`op ${k} (${kinds[k]}) decisions differ: ${st.join(',')}`); });
  const stats = { accepted: 0, rejected: 0, pending: 0, byzAccepted: 0, honestRejected: 0 };
  statuses.forEach((st, k) => {
    stats[st[0]]++;
    if (kinds[k] === 'byz' && st[0] === 'accepted') stats.byzAccepted++;
    if (kinds[k] === 'honest' && st[0] !== 'accepted') stats.honestRejected++;
  });
  if (stats.honestRejected && !(o.expectHonestLoss)) problems.push(`${stats.honestRejected} honest ops not accepted`);
  return { ok: problems.length === 0, problems, stats, log, kinds, texts, statuses, docs: all };
}
