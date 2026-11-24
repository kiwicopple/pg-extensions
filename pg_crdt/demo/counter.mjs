// This deliberately small browser model mirrors the PN-counter merge rule.
// In live mode, Postgres is authoritative for every sync.
export const REPLICAS = ['demo:alice', 'demo:bob'];
export const MAX_TOTAL = 10_000;
export const empty = () => ({ t: 'pn', v: 1, p: {}, n: {} });

export function merge(a, b) {
  const result = empty();
  for (const map of ['p', 'n']) {
    for (const key of new Set([...Object.keys(a[map]), ...Object.keys(b[map])])) {
      result[map][key] = Math.max(a[map][key] ?? 0, b[map][key] ?? 0);
    }
  }
  return result;
}

export function value(state) {
  return Object.values(state.p).reduce((sum, n) => sum + n, 0)
    - Object.values(state.n).reduce((sum, n) => sum + n, 0);
}

export function deltaFromCopies(copies) {
  const delta = empty();
  for (const key of REPLICAS) {
    delta.p[key] = copies[key].p[key] ?? 0;
    delta.n[key] = copies[key].n[key] ?? 0;
  }
  return delta;
}

export function validDelta(delta) {
  if (!delta || typeof delta !== 'object' || Array.isArray(delta)
    || Object.keys(delta).sort().join() !== 'n,p,t,v'
    || delta.t !== 'pn' || delta.v !== 1) return false;
  return ['p', 'n'].every((map) => {
    const entries = delta[map];
    return entries && typeof entries === 'object' && !Array.isArray(entries)
      && Object.keys(entries).every((key) => REPLICAS.includes(key)
        && Number.isSafeInteger(entries[key]) && entries[key] >= 0 && entries[key] <= MAX_TOTAL);
  });
}
