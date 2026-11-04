// Reference YjsMod sequence CRDT for pg_crdt text experiments.
// Contract: ../../research/text.md. Plain ESM, no dependencies.
//
// Items are stored one per character (no RLE in memory; runs only exist on the
// wire). Correctness first. Positions are Unicode code points.

const MAX_SEQ = 2 ** 31 - 1;

// Replica order = code point order = UTF-8 byte order (same as Postgres collate "C").
export function cmpReplica(a, b) {
  if (a === b) return 0;
  return Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));
}

function checkReplica(r) {
  if (typeof r !== 'string' || r === '' || r.includes(':')) {
    throw new TypeError(`invalid replica id: ${JSON.stringify(r)}`);
  }
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

export class Doc {
  constructor() {
    this.items = [];          // document order, tombstones included
    this.byId = new Map();    // replica -> Item[] indexed by seq-1 (contiguous, no gaps)
    this.tomb = new Map();    // replica -> sorted disjoint [start, end) seq intervals (all deletes ever seen)
    this.pending = [];        // buffered insert runs whose dependencies are missing
    this.visible = 0;
    this.nextN = 0;           // integration counter (causal order)
    this.cache = null;        // {k, idx}: items[idx] is the k-th (0-based) visible item
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
    for (const [r, arr] of this.byId) vv[r] = arr.length;
    return vv;
  }
  pendingCount() { return this.pending.length; }

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

  localInsert(replica, pos, text) {
    checkReplica(replica);
    const chars = Array.from(text);
    if (chars.length === 0) throw new RangeError('empty insert');
    if (!Number.isInteger(pos) || pos < 0 || pos > this.visible) throw new RangeError(`pos ${pos} out of range`);
    const L = pos === 0 ? -1 : this._visIdx(pos - 1);
    const olItem = L >= 0 ? this.items[L] : null;
    const orItem = this.items[L + 1] ?? null; // next item incl. tombstones
    let arr = this.byId.get(replica);
    if (!arr) { arr = []; this.byId.set(replica, arr); }
    const seq = arr.length + 1;
    const news = [];
    let prev = olItem;
    for (let k = 0; k < chars.length; k++) {
      const it = { r: replica, s: seq + k, ch: chars[k], ol: prev, or: orItem, del: false, n: this.nextN++ };
      news.push(it); arr.push(it); prev = it;
    }
    this.items.splice(L + 1, 0, ...news);
    this.visible += chars.length;
    this.cache = { k: pos + chars.length - 1, idx: L + chars.length };
    return { i: [[replica, seq, olItem ? [olItem.r, olItem.s] : null, orItem ? [orItem.r, orItem.s] : null, chars.join('')]], d: [] };
  }

  // `replica` is accepted for symmetry with localInsert; deletes may target anyone's characters.
  localDelete(replica, pos, len) {
    checkReplica(replica);
    if (!Number.isInteger(pos) || !Number.isInteger(len) || len < 1 || pos < 0 || pos + len > this.visible) {
      throw new RangeError(`delete ${pos}+${len} out of range`);
    }
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
    return { i: [], d };
  }

  // ---- remote ops -----------------------------------------------------------------
  // Accepts an op object or JSON string. Idempotent. Inserts whose dependencies
  // (origins, or the same replica's previous seq) are missing are buffered.
  // Deletes are recorded as tombstone intervals immediately, so a delete of an
  // unseen id takes effect when the insert arrives.
  apply(op) {
    if (typeof op === 'string') op = JSON.parse(op);
    if (op === null || typeof op !== 'object') throw new TypeError('op must be an object');
    const ins = op.i ?? [], dels = op.d ?? [];
    if (!Array.isArray(ins) || !Array.isArray(dels)) throw new TypeError('i and d must be arrays');
    // validate everything before changing state
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
      let arr = this.byId.get(run.r);
      const have = arr ? arr.length : 0;
      if (seq <= have) { run.off++; moved = true; continue; } // already integrated
      if (seq !== have + 1) break;                             // gap in this replica's seqs
      const ol = run.off === 0 ? run.ol : [run.r, seq - 1];
      const olItem = ol ? this._lookup(ol) : null;
      if (ol && !olItem) break;
      const orItem = run.or ? this._lookup(run.or) : null;
      if (run.or && !orItem) break;
      if (!arr) { arr = []; this.byId.set(run.r, arr); }
      const it = { r: run.r, s: seq, ch: run.chars[run.off], ol: olItem, or: orItem, del: false, n: this.nextN++ };
      arr.push(it);
      this._integrate(it);
      if (this._isTomb(it.r, it.s)) it.del = true; else this.visible++;
      run.off++; moved = true;
    }
    return moved;
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

  // ---- sync out -----------------------------------------------------------------------
  // Returns one op {i, d}: i = exactly the integrated inserts with seq > vv[replica]
  // (missing replica in vv means 0), as maximal runs, in integration (causal) order;
  // d = ALL deletes this doc knows (including ones for ids it has not seen), because
  // the doc cannot tell which deletes the client lacks. Deletes are idempotent.
  // Buffered (pending) inserts are not included.
  opsSince(vv = {}) {
    const runs = [];
    for (const [r, arr] of this.byId) {
      let s = (vv[r] ?? 0) + 1;
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

// Concatenate ops into one op, coalescing adjacent insert runs that are exactly
// what typing them would produce, and adjacent deletes. Order of runs preserved.
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
  return { i, d: dm };
}
