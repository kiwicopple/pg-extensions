// Reference YjsMod sequence CRDT for pg_crdt collaborative text (ydoc_).
// Contract: ../../research/text.md plus the validation rules in ../../experiments/text-ref/README.md.
// Plain ESM, no dependencies, no Node-only APIs: it runs in Node and in browsers.
//
// This is both the JS reference that the extension is differential-tested against
// (experiments/text-ref/ref.mjs re-exports it) and the engine of the client library
// (./client.js). Moved here from experiments/text-ref/ref.mjs in session 8; the only
// change was replacing Buffer with portable code.
//
// Items are stored one per character (no RLE in memory; runs only exist on the
// wire). Correctness first. Positions are Unicode code points.
//
// Two write paths:
//   apply(op)                    trusted: no "v" needed, inserts buffered by origins, deletes held for unseen ids.
//   apply(op, {validate: true})  untrusted: the op carries "v" (sender's version vector before the op) and
//                                is checked by rules V1..V7 (see README). An op is accepted or rejected as a unit.

const MAX_SEQ = 2 ** 31 - 1;

// The code point at s[i], with a lone surrogate read as U+FFFD (what a UTF-8 encoder writes for it).
function cpAt(s, i) {
  const c = s.codePointAt(i);
  return c >= 0xd800 && c <= 0xdfff ? 0xfffd : c;
}

// Replica order = code point order = UTF-8 byte order (same as Postgres collate "C"). JS `<` compares
// UTF-16 code units, which differs for non-BMP characters against U+E000..U+FFFF.
export function cmpReplica(a, b) {
  if (a === b) return 0;
  let i = 0, j = 0;
  while (i < a.length && j < b.length) {
    const x = cpAt(a, i), y = cpAt(b, j);
    if (x !== y) return x < y ? -1 : 1;
    i += x > 0xffff ? 2 : 1;
    j += y > 0xffff ? 2 : 1;
  }
  return i < a.length ? 1 : j < b.length ? -1 : 0;
}

// Length of s in UTF-8 bytes (a lone surrogate counts as U+FFFD, 3 bytes).
export function utf8Length(s) {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const d = s.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) { n += 4; i++; } else n += 3;
    } else n += 3;
  }
  return n;
}

export class OpRejected extends Error {
  constructor(reason) {
    super(`op rejected: ${reason}`);
    this.reason = reason;
    this.code = '22023'; // invalid_parameter_value, as in pn_apply_delta
  }
}

// A replica key, as in the SQL extension (crdt._ydoc_is_key): an id without
// ':', or <id>:<device> with a non-empty device (which may contain ':'), at
// most 256 bytes. One writer identity can own several keys (a phone and a
// laptop). Ownership ("this writer may use this key") is not decided here; the
// reference has no writers. test/fixtures/replica-keys.json is run by both.
const MAX_KEY_BYTES = 256;
const REPLICA_KEY = /^[^:]+(?::[\s\S]+)?$/;
export function isReplicaKey(r) {
  return typeof r === 'string' && REPLICA_KEY.test(r) && utf8Length(r) <= MAX_KEY_BYTES;
}
function checkReplica(r) {
  if (!isReplicaKey(r)) throw new TypeError(`invalid replica key: ${JSON.stringify(r)}`);
}
function checkSeq(s) {
  if (!Number.isInteger(s) || s < 1 || s > MAX_SEQ) throw new TypeError(`invalid seq: ${s}`);
}
function checkId(id) {
  if (id === null) return;
  if (!Array.isArray(id) || id.length !== 2) throw new TypeError('invalid origin id');
  checkReplica(id[0]);
  checkSeq(id[1]);
}
// Shape check shared by both paths. Returns { ins, dels }; throws TypeError.
function checkOpShape(op) {
  if (op === null || typeof op !== 'object') throw new TypeError('op must be an object');
  const ins = op.i ?? [], dels = op.d ?? [];
  if (!Array.isArray(ins) || !Array.isArray(dels)) throw new TypeError('i and d must be arrays');
  for (const run of ins) {
    if (!Array.isArray(run) || run.length !== 5) throw new TypeError('bad insert run');
    const [r, s, ol, or, text] = run;
    checkReplica(r); checkSeq(s); checkId(ol); checkId(or);
    if (typeof text !== 'string' || text === '') throw new TypeError('bad insert text');
  }
  for (const dl of dels) {
    if (!Array.isArray(dl) || dl.length !== 3) throw new TypeError('bad delete');
    checkReplica(dl[0]); checkSeq(dl[1]);
    if (!Number.isInteger(dl[2]) || dl[2] < 1 || dl[2] > MAX_SEQ) throw new TypeError('bad delete len');
  }
  return { ins, dels };
}
// Own-property setter that is safe for replica ids like "__proto__".
function setProp(obj, k, v) { Object.defineProperty(obj, k, { value: v, enumerable: true, writable: true, configurable: true }); }

export const DEFAULT_RULES = Object.freeze({
  coverOrigins: true,  // V1: v covers both origins
  ownSeq: true,        // V2: v[r] == seq-1 for the first char of a run (advancing run by run)
  closed: true,        // V3: v is causally closed (dependencies of every covered item are covered)
  order: true,         // V4: originLeft is before originRight
  between: true,       // V5: no item strictly between the origins is covered by v
  deleteCovered: true, // V6: delete targets are covered by v
});                    // V7 (wait until the local doc covers v) is structural, not switchable.

const EMPTY_DEPS = new Map();

export class Doc {
  // opts.rules: override DEFAULT_RULES (test hook for the ablation experiment; production keeps all on).
  constructor(opts = {}) {
    this.rules = { ...DEFAULT_RULES, ...(opts.rules ?? {}) };
    this.items = [];          // document order, tombstones included
    this.byId = new Map();    // replica -> Item[] indexed by seq-1 (contiguous, no gaps)
    this.tomb = new Map();    // replica -> sorted disjoint [start, end) seq intervals (all deletes ever applied)
    this.pending = [];        // trusted path: buffered insert runs whose dependencies are missing
    this.pendingOps = [];     // validated path: ops waiting until the doc covers their v
    this.visible = 0;
    this.nextN = 0;           // integration counter (causal order)
    this.cache = null;        // {k, idx}: items[idx] is the k-th (0-based) visible item
    this.onDecision = null;   // optional (op, 'accepted'|'rejected', reason) => void, validated path
  }

  // ---- queries ------------------------------------------------------------
  text() {
    let out = '';
    for (const it of this.items) if (!it.del) out += it.ch;
    return out;
  }
  length() { return this.visible; }
  versionVector() {
    const vv = {};
    for (const [r, arr] of this.byId) if (arr.length) setProp(vv, r, arr.length);
    return vv;
  }
  pendingCount() { return this.pending.length + this.pendingOps.length; }

  // ---- item construction --------------------------------------------------------
  // dp = cumulative direct dependencies (replica -> max seq of an origin) of the replica's items 1..s.
  // Used by rule V3. Copy on write, shared between neighbours when unchanged.
  _newItem(r, s, ch, olItem, orItem) {
    const arr = this.byId.get(r);
    const prev = s > 1 ? arr[s - 2] : null;
    let dp = prev ? prev.dp : EMPTY_DEPS, copied = false;
    for (const o of [olItem, orItem]) {
      if (o && o.r !== r && (dp.get(o.r) ?? 0) < o.s) {
        if (!copied) { dp = new Map(dp); copied = true; }
        dp.set(o.r, o.s);
      }
    }
    const it = { r, s, ch, ol: olItem, or: orItem, del: false, n: this.nextN++, dp };
    arr.push(it);
    return it;
  }
  _arr(r) {
    let arr = this.byId.get(r);
    if (!arr) { arr = []; this.byId.set(r, arr); }
    return arr;
  }

  // ---- tombstone interval bookkeeping ---------------------------------------
  _isTomb(r, s) {
    const iv = this.tomb.get(r);
    if (!iv) return false;
    let lo = 0, hi = iv.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (s < iv[mid][0]) hi = mid - 1;
      else if (s >= iv[mid][1]) lo = mid + 1;
      else return true;
    }
    return false;
  }
  _addTomb(r, s, len) {
    let iv = this.tomb.get(r);
    if (!iv) { iv = []; this.tomb.set(r, iv); }
    let start = s, end = s + len;
    // first interval with iv[i][1] >= start
    let lo = 0, hi = iv.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (iv[mid][1] < start) lo = mid + 1; else hi = mid; }
    let j = lo;
    while (j < iv.length && iv[j][0] <= end) {
      start = Math.min(start, iv[j][0]);
      end = Math.max(end, iv[j][1]);
      j++;
    }
    iv.splice(lo, j - lo, [start, end]);
  }
  _markDeleted(it) {
    if (!it.del) { it.del = true; this.visible--; this.cache = null; }
  }

  // ---- local edits ------------------------------------------------------------
  _visIdx(k) {
    const items = this.items;
    let c = this.cache;
    if (!c) {
      // scan from the nearer end
      if (k < this.visible / 2) {
        let i = -1, n = -1;
        while (n < k) { i++; if (!items[i].del) n++; }
        return (this.cache = { k, idx: i }).idx;
      }
      let i = items.length, n = this.visible;
      while (n > k) { i--; if (!items[i].del) n--; }
      return (this.cache = { k, idx: i }).idx;
    }
    let { k: k0, idx: i } = c;
    while (k0 < k) { i++; if (!items[i].del) k0++; }
    while (k0 > k) { i--; if (!items[i].del) k0--; }
    c.k = k; c.idx = i;
    return i;
  }

  // Returned ops are {v, i, d}. v is the version vector before the op (only replicas with seq > 0).
  // Origins are adjacent in the full sequence including tombstones: originLeft is the visible char at
  // pos-1, originRight is the item right after it (a tombstone if there is one).
  localInsert(replica, pos, text) {
    checkReplica(replica);
    const chars = Array.from(text);
    if (chars.length === 0) throw new RangeError('empty insert');
    if (!Number.isInteger(pos) || pos < 0 || pos > this.visible) throw new RangeError(`pos ${pos} out of range`);
    const v = this.versionVector();
    const L = pos === 0 ? -1 : this._visIdx(pos - 1);
    const olItem = L >= 0 ? this.items[L] : null;
    const orItem = this.items[L + 1] ?? null; // next item incl. tombstones
    const arr = this._arr(replica);
    const seq = arr.length + 1;
    const news = [];
    let prev = olItem;
    for (let k = 0; k < chars.length; k++) {
      const it = this._newItem(replica, seq + k, chars[k], prev, orItem);
      news.push(it); prev = it;
    }
    this.items.splice(L + 1, 0, ...news);
    this.visible += chars.length;
    this.cache = { k: pos + chars.length - 1, idx: L + chars.length };
    return { v, i: [[replica, seq, olItem ? [olItem.r, olItem.s] : null, orItem ? [orItem.r, orItem.s] : null, chars.join('')]], d: [] };
  }

  // `replica` is accepted for symmetry with localInsert; deletes may target anyone's characters.
  localDelete(replica, pos, len) {
    checkReplica(replica);
    if (!Number.isInteger(pos) || !Number.isInteger(len) || len < 1 || pos < 0 || pos + len > this.visible) {
      throw new RangeError(`delete ${pos}+${len} out of range`);
    }
    const v = this.versionVector();
    const items = this.items;
    let i = this._visIdx(pos);
    const d = [];
    let left = len;
    for (;; i++) {
      const it = items[i];
      if (it.del) continue;
      it.del = true; this.visible--;
      this._addTomb(it.r, it.s, 1);
      const last = d[d.length - 1];
      if (last && last[0] === it.r && last[1] + last[2] === it.s) last[2]++;
      else d.push([it.r, it.s, 1]);
      if (--left === 0) break;
    }
    // restore cache at next visible item (which is now the pos-th visible one)
    let j = i + 1;
    while (j < items.length && items[j].del) j++;
    this.cache = j < items.length ? { k: pos, idx: j } : null;
    return { v, i: [], d };
  }

  // ---- remote ops -----------------------------------------------------------------
  // apply(op)                   trusted path (see header). Accepts an op object or JSON string. Idempotent.
  // apply(op, {validate:true})  untrusted path. Returns 'accepted' | 'pending'. Throws OpRejected (code 22023)
  //                             if the op is rejected during this call. Ops that wait and are decided in a later
  //                             call are reported through doc.onDecision.
  apply(op, opts = {}) {
    if (typeof op === 'string') op = JSON.parse(op);
    if (opts.validate) return this._applyValidated(op);
    const { ins, dels } = checkOpShape(op); // validate everything before changing state
    for (const dl of dels) {
      const [r, s, len] = dl;
      this._addTomb(r, s, len);
      const arr = this.byId.get(r);
      if (arr) {
        const end = Math.min(s + len, arr.length + 1);
        for (let q = s; q < end; q++) this._markDeleted(arr[q - 1]);
      }
    }
    for (const [r, s, ol, or, text] of ins) {
      this.pending.push({ r, s, ol, or, chars: Array.from(text), off: 0 });
    }
    this._drain();
  }

  _drain() {
    let progress = true;
    while (progress && this.pending.length) {
      progress = false;
      const rest = [];
      for (const run of this.pending) {
        if (this._advance(run)) progress = true;
        if (run.off < run.chars.length) rest.push(run);
      }
      this.pending = rest;
    }
  }

  // Integrate as many chars of `run` as dependencies allow. Returns true if any progress.
  _advance(run) {
    let moved = false;
    while (run.off < run.chars.length) {
      const seq = run.s + run.off;
      const have = this.byId.get(run.r)?.length ?? 0;
      if (seq <= have) { run.off++; moved = true; continue; } // already integrated
      if (seq !== have + 1) break;                             // gap in this replica's seqs
      const ol = run.off === 0 ? run.ol : [run.r, seq - 1];
      const olItem = ol ? this._lookup(ol) : null;
      if (ol && !olItem) break;
      const orItem = run.or ? this._lookup(run.or) : null;
      if (run.or && !orItem) break;
      this._integrateChar(run.r, seq, run.chars[run.off], olItem, orItem);
      run.off++; moved = true;
    }
    return moved;
  }

  _integrateChar(r, seq, ch, olItem, orItem) {
    this._arr(r);
    const it = this._newItem(r, seq, ch, olItem, orItem);
    this._integrate(it);
    if (this._isTomb(it.r, it.s)) it.del = true; else this.visible++;
    return it;
  }

  _lookup([r, s]) {
    const arr = this.byId.get(r);
    return arr && s <= arr.length ? arr[s - 1] : null;
  }

  // integrateYjsMod (josephg/reference-crdts crdts.ts), see README.
  _integrate(item) {
    const items = this.items;
    const len = items.length;
    const left = item.ol ? items.indexOf(item.ol) : -1;
    const right = item.or ? items.indexOf(item.or) : len;
    let dest = left + 1;
    let scanning = false;
    for (let i = left + 1; ; i++) {
      if (!scanning) dest = i;
      if (i === len || i === right) break;
      const o = items[i];
      const oleft = o.ol ? items.lastIndexOf(o.ol, i) : -1;
      const oright = o.or ? items.indexOf(o.or, i) : len;
      if (oleft < left) break;
      else if (oleft === left) {
        if (oright < right) { scanning = true; continue; }
        else if (oright === right) {
          if (cmpReplica(item.r, o.r) < 0) break;
          scanning = false; continue;
        } else { scanning = false; continue; }
      } else continue;
    }
    items.splice(dest, 0, item);
    this.cache = null;
  }

  // ---- validated (untrusted) path -------------------------------------------------------
  _decide(P, status, reason) { if (this.onDecision) this.onDecision(P.op, status, reason); }

  _applyValidated(op) {
    let P;
    try {
      const { ins, dels } = checkOpShape(op);
      if (op.v === null || typeof op.v !== 'object' || Array.isArray(op.v)) throw new TypeError('missing or bad v');
      const v = new Map();
      for (const [r, n] of Object.entries(op.v)) {
        checkReplica(r); checkSeq(n);
        v.set(r, n);
      }
      P = { op, ins, dels, v };
    } catch (e) {
      if (!(e instanceof TypeError)) throw e;
      const rej = new OpRejected('malformed: ' + e.message);
      this._decide({ op }, 'rejected', rej.reason);
      throw rej;
    }
    // Static rules (depend on the op alone, so every replica decides the same way, immediately).
    const reason = this._staticCheck(P);
    if (reason) { this._decide(P, 'rejected', reason); throw new OpRejected(reason); }
    this.pendingOps.push(P);
    const outcome = this._drainOps(P);
    if (outcome.status === 'rejected') throw new OpRejected(outcome.reason);
    return outcome.status;
  }

  // V1, V2, V6 on the claimed v advanced run by run.
  _staticCheck(P) {
    const vadv = new Map(P.v);
    for (const [r, s, ol, or, text] of P.ins) {
      if (this.rules.coverOrigins) {
        for (const id of [ol, or]) if (id && (vadv.get(id[0]) ?? 0) < id[1]) return 'V1: origin not covered by v';
      }
      if (this.rules.ownSeq && (vadv.get(r) ?? 0) !== s - 1) return 'V2: v[replica] != seq-1';
      vadv.set(r, Math.max(vadv.get(r) ?? 0, s + Array.from(text).length - 1));
    }
    if (this.rules.deleteCovered) {
      for (const [r, s, len] of P.dels) if ((vadv.get(r) ?? 0) < s + len - 1) return 'V6: delete target not covered by v';
    }
    P.vadv = vadv;
    return null;
  }

  _covers(v) {
    for (const [r, n] of v) if ((this.byId.get(r)?.length ?? 0) < n) return false;
    return true;
  }

  // Try every waiting op until no more progress. Returns the outcome of `target`.
  _drainOps(target) {
    let outcome = { status: 'pending' };
    let progress = true;
    while (progress) {
      progress = false;
      for (const P of this.pendingOps.slice()) {
        if (!this._covers(P.v)) continue;           // V7: wait
        const res = this._tryOp(P);
        this.pendingOps.splice(this.pendingOps.indexOf(P), 1);
        this._decide(P, res.status, res.reason);
        if (P === target) outcome = res;
        progress = true;
      }
    }
    return outcome;
  }

  // The doc covers P.v. Apply atomically or reject (rolling back anything integrated).
  _tryOp(P) {
    // V3: v is the version vector of some causally closed state
    if (this.rules.closed) {
      for (const [r, n] of P.v) {
        const it = this.byId.get(r)[n - 1];
        for (const [q, t] of it.dp) if ((P.v.get(q) ?? 0) < t) return { status: 'rejected', reason: 'V3: v is not causally closed' };
      }
    }
    const savedN = this.nextN, inserted = [], vadv = new Map(P.v);
    const rollback = (reason) => {
      if (inserted.length) {
        const gone = new Set(inserted);
        this.items = this.items.filter((it) => !gone.has(it));
        for (const it of inserted) { this.byId.get(it.r).pop(); if (!it.del) this.visible--; }
        this.nextN = savedN; this.cache = null;
      }
      return { status: 'rejected', reason };
    };
    for (const [r, s, ol, or, text] of P.ins) {
      const chars = Array.from(text);
      const have = this.byId.get(r)?.length ?? 0;
      if (s + chars.length - 1 <= have) { vadv.set(r, s + chars.length - 1); continue; } // duplicate of an integrated run
      if (s <= have) return rollback('overlaps an integrated run with different extent'); // only equivocation does this
      const olItem = ol ? this._lookup(ol) : null;
      const orItem = or ? this._lookup(or) : null;
      if ((ol && !olItem) || (or && !orItem)) return rollback('origin missing'); // unreachable when V1 holds
      const li = olItem ? this.items.indexOf(olItem) : -1;
      const ri = orItem ? this.items.indexOf(orItem) : this.items.length;
      if (this.rules.order && li >= ri) return rollback('V4: originLeft is not before originRight');
      if (this.rules.between) {
        for (let i = li + 1; i < ri; i++) {
          const y = this.items[i];
          if (y.s <= (vadv.get(y.r) ?? 0)) return rollback('V5: an item covered by v lies between the origins');
        }
      }
      let prev = olItem;
      for (let k = 0; k < chars.length; k++) {
        prev = this._integrateChar(r, s + k, chars[k], prev, orItem);
        // note: char k>0 has originLeft = previous char of the run, per the wire format
        inserted.push(prev);
      }
      vadv.set(r, s + chars.length - 1);
    }
    for (const [r, s, len] of P.dels) {
      this._addTomb(r, s, len);
      const arr = this.byId.get(r);
      const end = Math.min(s + len, (arr?.length ?? 0) + 1);
      for (let q = s; q < end; q++) this._markDeleted(arr[q - 1]);
    }
    return { status: 'accepted' };
  }

  // ---- sync out -----------------------------------------------------------------------
  // Returns one op {i, d} (no "v": a catch-up op is a trusted-path artifact, it cannot satisfy the
  // validation rules). i = exactly the integrated inserts with seq > vv[replica] (missing replica in vv
  // means 0), as maximal runs, in integration (causal) order; d = ALL deletes this doc knows, because the
  // doc cannot tell which deletes the client lacks. Deletes are idempotent. Buffered inserts are excluded.
  opsSince(vv = {}) {
    const runs = [];
    for (const [r, arr] of this.byId) {
      let s = (Object.hasOwn(vv, r) ? vv[r] : 0) + 1;
      while (s <= arr.length) {
        const first = arr[s - 1];
        let e = s;
        while (e < arr.length) {
          const nx = arr[e];
          if (nx.ol === arr[e - 1] && nx.or === first.or) e++; else break;
        }
        let text = '';
        for (let q = s; q <= e; q++) text += arr[q - 1].ch;
        runs.push({ n: first.n, run: [r, s, idOf(first.ol), idOf(first.or), text] });
        s = e + 1;
      }
    }
    runs.sort((a, b) => a.n - b.n);
    const d = [];
    for (const [r, iv] of this.tomb) for (const [a, b] of iv) d.push([r, a, b - a]);
    return { i: runs.map((x) => x.run), d };
  }
}

function idOf(it) { return it ? [it.r, it.s] : null; }

// Concatenate ops of ONE replica that were generated back to back (no foreign op applied in between)
// into one op, coalescing adjacent insert runs that are exactly what typing them would produce, and
// adjacent deletes. The merged op's v is the first op's v, so it satisfies V2 run by run.
export function mergeOps(ops) {
  const i = [];
  const d = [];
  for (const op of ops) {
    for (const run of op.i) {
      const last = i[i.length - 1];
      if (last && last[0] === run[0] && Array.from(last[4]).length + last[1] === run[1]
          && run[2] && run[2][0] === run[0] && run[2][1] === run[1] - 1
          && JSON.stringify(last[3]) === JSON.stringify(run[3])) {
        last[4] += run[4];
      } else i.push([run[0], run[1], run[2], run[3], run[4]]);
    }
    for (const dl of op.d) d.push([dl[0], dl[1], dl[2]]);
  }
  d.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] - b[1]));
  const dm = [];
  for (const dl of d) {
    const last = dm[dm.length - 1];
    if (last && last[0] === dl[0] && last[1] + last[2] >= dl[1]) last[2] = Math.max(last[2], dl[1] + dl[2] - last[1]);
    else dm.push(dl);
  }
  const out = { i, d: dm };
  return ops[0] && ops[0].v ? { v: ops[0].v, ...out } : out;
}
