// Shared deterministic simulation helpers (seeded PRNG, random multi-replica editing).
import { Doc } from './ref.mjs';

export function mulberry32(seed) {
  let a = seed >>> 0;
  return function rnd() {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
export const ri = (rnd, lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1)); // inclusive
export const pick = (rnd, arr) => arr[Math.floor(rnd() * arr.length)];
export function shuffle(rnd, arr) {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(rnd() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

// Pool mixes ASCII, BMP, non-BMP (emoji, math), combining and ZWJ sequences, newline.
export const CHAR_POOL = ['a', 'b', 'c', 'd', 'e', 'x', 'y', 'z', ' ', '\n', '.', "'", '"', '\\', '$',
  'é', '日', '本', '\u{1F600}', '\u{1F44D}', '\u{1D54F}', '́', '‍', '\u{1F468}'];

export function randText(rnd, maxLen) {
  const n = ri(rnd, 1, maxLen);
  let s = '';
  for (let i = 0; i < n; i++) s += pick(rnd, CHAR_POOL);
  return s;
}

export function randLocalOp(rnd, doc, replica, opts = {}) {
  const maxRun = opts.maxRun ?? 8;
  const len = doc.length();
  if (len > 0 && rnd() < (opts.delProb ?? 0.3)) {
    const dl = ri(rnd, 1, Math.min(opts.maxDel ?? 5, len));
    return doc.localDelete(replica, ri(rnd, 0, len - dl), dl);
  }
  return doc.localInsert(replica, ri(rnd, 0, len), randText(rnd, maxRun));
}

// Random concurrent editing session. Returns { log, docs, expected, names }.
// log = ops in global generation order (a valid causal order).
export function simulate(seed, { names, nOps, syncProb = 0.2, dupProb = 0.15, maxRun = 8, delProb = 0.3 }) {
  const rnd = mulberry32(seed);
  const docs = names.map(() => new Doc());
  const log = [];
  const delivered = names.map(() => new Set());
  const deliver = (ri_, idx) => { docs[ri_].apply(log[idx]); delivered[ri_].add(idx); };
  const syncSome = (to) => {
    const missing = [];
    for (let k = 0; k < log.length; k++) if (!delivered[to].has(k)) missing.push(k);
    if (!missing.length) return;
    const take = shuffle(rnd, missing).slice(0, ri(rnd, 1, missing.length));
    for (const k of take) {
      deliver(to, k);
      if (rnd() < dupProb) docs[to].apply(log[k]); // duplicate delivery
    }
  };
  while (log.length < nOps) {
    if (rnd() < syncProb) { syncSome(ri(rnd, 0, names.length - 1)); continue; }
    const who = ri(rnd, 0, names.length - 1);
    const op = randLocalOp(rnd, docs[who], names[who], { maxRun, delProb });
    log.push(op);
    delivered[who].add(log.length - 1);
  }
  // final full delivery, each replica in its own random order, with duplicates
  for (let t = 0; t < names.length; t++) {
    const missing = [];
    for (let k = 0; k < log.length; k++) if (!delivered[t].has(k)) missing.push(k);
    for (const k of shuffle(rnd, missing)) {
      deliver(t, k);
      if (rnd() < dupProb) docs[t].apply(log[k]);
    }
  }
  return { log, docs, names, expected: docs[0].text() };
}
