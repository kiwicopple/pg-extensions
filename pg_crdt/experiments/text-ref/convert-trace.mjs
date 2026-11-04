// Replays an editing trace through ref.mjs as one replica ("paper") and emits op files.
// Usage: node convert-trace.mjs [raw.json.gz] [outDir] [--verify-remote]
//   defaults: traces/raw/automerge-paper.json.gz  traces/
// The raw file is untrusted data: it is only gunzipped and JSON.parse'd.
// --verify-remote additionally applies the emitted ops to a fresh Doc through apply() (slow, O(n) per op).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve, basename } from 'node:path';
import assert from 'node:assert/strict';
import { Doc, mergeOps } from './ref.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const verifyRemote = process.argv.includes('--verify-remote');
const input = resolve(args[0] ?? join(here, 'traces/raw/automerge-paper.json.gz'));
const outDir = resolve(args[1] ?? join(here, 'traces'));
const name = basename(input).replace(/\.json(\.gz)?$/, '');
mkdirSync(outDir, { recursive: true });
const REPLICA = 'paper', BATCH = 100;

const raw = readFileSync(input);
const trace = JSON.parse((input.endsWith('.gz') ? gunzipSync(raw) : raw).toString('utf8'));
assert.equal(typeof trace.startContent, 'string');
assert.equal(typeof trace.endContent, 'string');
assert.ok(Array.isArray(trace.txns));

// Flatten patches: [pos, delCount, insStr]
const patches = [];
for (const txn of trace.txns) {
  for (const p of txn.patches) {
    assert.ok(Array.isArray(p) && p.length === 3 && Number.isInteger(p[0]) && Number.isInteger(p[1]) && typeof p[2] === 'string');
    patches.push(p);
  }
}
if (trace.startContent) patches.unshift([0, 0, trace.startContent]); // base content becomes a first patch

// Units check: positions are code points iff replay matches endContent under code point semantics; also
// report whether any non-BMP char exists (only then do UTF-16 units and code points differ).
const nonBmp = (s) => /[\u{10000}-\u{10FFFF}]/u.test(s);
const hasNonBmp = nonBmp(trace.endContent) || patches.some((p) => nonBmp(p[2]));

// Replay as a single replica; one op per patch.
const doc = new Doc();
const ops = [];
const t0 = process.hrtime.bigint();
for (const [pos, del, ins] of patches) {
  const parts = [];
  if (del > 0) parts.push(doc.localDelete(REPLICA, pos, del));
  if (ins.length > 0) parts.push(doc.localInsert(REPLICA, pos, ins));
  ops.push(parts.length === 1 ? parts[0] : mergeOps(parts));
}
const tReplay = Number(process.hrtime.bigint() - t0) / 1e6;
const text = doc.text();
assert.equal(text, trace.endContent, 'ref final text differs from endContent');

// Batched: merge consecutive ops, BATCH patches per op.
const batches = [];
for (let k = 0; k < ops.length; k += BATCH) batches.push(mergeOps(ops.slice(k, k + BATCH)));

const lines = (arr) => arr.map((o) => JSON.stringify(o)).join('\n') + '\n';
writeFileSync(join(outDir, `${name}.ops.jsonl`), lines(ops));
writeFileSync(join(outDir, `${name}.batch${BATCH}.jsonl`), lines(batches));
writeFileSync(join(outDir, `${name}.patches.jsonl`), lines(patches));

// Round trip checks: re-read each file and verify it replays to endContent.
// (a) positional form through localInsert/localDelete = the original replay but from the written file.
const tPatchStart = process.hrtime.bigint();
const dp = new Doc();
for (const line of readFileSync(join(outDir, `${name}.patches.jsonl`), 'utf8').split('\n')) {
  if (!line) continue;
  const [pos, del, ins] = JSON.parse(line);
  if (del > 0) dp.localDelete(REPLICA, pos, del);
  if (ins.length > 0) dp.localInsert(REPLICA, pos, ins);
}
const tPatches = Number(process.hrtime.bigint() - tPatchStart) / 1e6;
assert.equal(dp.text(), trace.endContent);

const stats = {
  trace: name, patches: patches.length, ops: ops.length, batches: batches.length,
  insertRuns: ops.reduce((s, o) => s + o.i.length, 0), deleteRanges: ops.reduce((s, o) => s + o.d.length, 0),
  finalLengthCodePoints: doc.length(), finalLengthUtf16: text.length, hasNonBmp,
  items_incl_tombstones: doc.items.length,
  jsReplayLocalMs: Math.round(tReplay), jsReplayFromPatchesFileMs: Math.round(tPatches),
};

if (verifyRemote) {
  for (const [label, list] of [['batch100', batches], ['ops', ops]]) {
    const t = process.hrtime.bigint();
    const d = new Doc();
    for (const o of list) d.apply(o);
    stats[`jsRemoteApply_${label}_Ms`] = Math.round(Number(process.hrtime.bigint() - t) / 1e6);
    assert.equal(d.text(), trace.endContent, `remote apply (${label}) mismatch`);
    assert.equal(d.pendingCount(), 0);
  }
}
console.log(JSON.stringify(stats, null, 2));
