// Small helpers for the build-time SVG charts. No runtime dependencies.

export type Design = 'a' | 'b' | 'c' | 'd';

/** One fixed colour per engine, everywhere. The CSS variables live in styles/viz.css (light and dark). */
export const ENGINES: { id: Design; letter: string; name: string; css: string }[] = [
	{ id: 'a', letter: 'A', name: 'Tuple core', css: 'var(--eng-a)' },
	{ id: 'b', letter: 'B', name: 'Policy first', css: 'var(--eng-b)' },
	{ id: 'c', letter: 'C', name: 'Compiled model', css: 'var(--eng-c)' },
	{ id: 'd', letter: 'D', name: 'Per-model tables', css: 'var(--eng-d)' },
];
/** Every engine, in legend order. Charts show the ones that have data. */
export const DESIGN_IDS: Design[] = ENGINES.map((e) => e.id);
export const engine = (d: string) => ENGINES.find((e) => e.id === d) ?? ENGINES[0];

export type Scale = ((v: number) => number) & { domain: [number, number]; kind: 'log' | 'lin' };

export function scaleLinear(d0: number, d1: number, r0: number, r1: number): Scale {
	const f = ((v: number) => r0 + ((v - d0) / (d1 - d0)) * (r1 - r0)) as Scale;
	f.domain = [d0, d1];
	f.kind = 'lin';
	return f;
}

export function scaleLog(d0: number, d1: number, r0: number, r1: number): Scale {
	const l0 = Math.log10(d0);
	const l1 = Math.log10(d1);
	const f = ((v: number) => r0 + ((Math.log10(Math.max(v, d0)) - l0) / (l1 - l0)) * (r1 - r0)) as Scale;
	f.domain = [d0, d1];
	f.kind = 'log';
	return f;
}

/** Decade bounds around the data, with a little headroom below the smallest value. */
export function logDomain(values: number[], floorHeadroom = 1.2): [number, number] {
	const v = values.filter((x) => x > 0 && Number.isFinite(x));
	if (!v.length) return [0.1, 10];
	const lo = 10 ** Math.floor(Math.log10(Math.min(...v) / floorHeadroom));
	let hi = 10 ** Math.ceil(Math.log10(Math.max(...v)));
	if (hi <= lo) hi = lo * 10;
	return [lo, hi];
}

export function logTicks([lo, hi]: [number, number]): number[] {
	const out: number[] = [];
	for (let e = Math.round(Math.log10(lo)); 10 ** e <= hi * 1.0001; e++) out.push(10 ** e);
	return out;
}

/** Ticks at 1, 2 and 5 times each power of ten: for log axes that span two decades or fewer. */
export function logTicksFine([lo, hi]: [number, number]): number[] {
	const out: number[] = [];
	for (let e = Math.round(Math.log10(lo)); 10 ** e <= hi * 1.0001; e++) {
		for (const m of [1, 2, 5]) {
			const v = Number((m * 10 ** e).toPrecision(12));
			if (v >= lo * 0.9999 && v <= hi * 1.0001) out.push(v);
		}
	}
	return out;
}

/** Decades for wide log axes, 1-2-5 steps for narrow ones. */
export function logAxisTicks(d: [number, number]): number[] {
	return Math.log10(d[1] / d[0]) <= 2.01 ? logTicksFine(d) : logTicks(d);
}

/** "Nice" linear ticks from 0 to just past max. */
export function linDomain(max: number, n = 4): { domain: [number, number]; ticks: number[] } {
	if (!(max > 0)) return { domain: [0, 1], ticks: [0, 1] };
	const raw = max / n;
	const mag = 10 ** Math.floor(Math.log10(raw));
	const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) ?? raw;
	const top = Math.ceil(max / step) * step;
	const ticks: number[] = [];
	for (let t = 0; t <= top + step / 1000; t += step) ticks.push(Number(t.toPrecision(12)));
	return { domain: [0, top], ticks };
}

const group3 = (s: string) => s.replace(/\B(?=(\d{3})+(?!\d))/g, ',');

/** Value as shown in tooltips and tables, e.g. 0.28, 2.02, 12.4, 509, 1,234. */
export function fmt(v: number | null | undefined, digits?: number): string {
	if (v == null || !Number.isFinite(v)) return 'n/a';
	if (digits != null) return group3(v.toFixed(digits));
	const a = Math.abs(v);
	if (a >= 1000) return group3(v.toFixed(0));
	if (a >= 100) return v.toFixed(0);
	if (a >= 10) return v.toFixed(1);
	return v.toFixed(2);
}

/** Compact label for the tip of a bar (at most 4 characters): 0.15, 9.6, 221, 1.2k. */
export function fmtShort(v: number): string {
	if (!Number.isFinite(v)) return '';
	const a = Math.abs(v);
	if (a >= 10000) return `${Math.round(v / 1000)}k`;
	if (a >= 1000) return `${(v / 1000).toFixed(1)}k`;
	if (a >= 100) return v.toFixed(0);
	if (a >= 10) return v.toFixed(0);
	if (a >= 1) return v.toFixed(1);
	return v.toFixed(2);
}

/** Axis tick label. */
export function fmtTick(v: number): string {
	if (v >= 1000) return `${v / 1000}k`;
	if (v >= 1) return String(Number(v.toPrecision(3)));
	return String(Number(v.toPrecision(2)));
}

export interface TipRow {
	/** CSS colour of the series key */
	c?: string;
	/** series label (secondary ink) */
	k: string;
	/** value (strong) */
	v: string;
	/** extra detail (muted) */
	x?: string;
}
export interface Tip {
	t: string;
	s?: string;
	r: TipRow[];
}
export const tip = (t: Tip) => JSON.stringify(t);

/** Greedy label de-collision: keep labels whose y is at least `gap` from every kept label. */
export function spreadLabels<T extends { y: number }>(items: T[], gap = 12): T[] {
	const kept: T[] = [];
	for (const it of [...items].sort((a, b) => a.y - b.y)) {
		if (kept.every((k) => Math.abs(k.y - it.y) >= gap)) kept.push(it);
	}
	return kept;
}
