// Benchmark data layer. Loads every run file at build time.
//
//   real data:  src/data/bench/*.json    (copied by `npm run sync` from pg_permissions/bench/baselines/data)
//   fixture:    src/data/fixture/*.json  (generated from the saved reports; used ONLY when there is no real data)
//
// Real data wins automatically: as soon as one file exists in src/data/bench the fixture is ignored.

import type { Design } from './chart';
import labels from '../data/workload-labels.json';

export interface WorkloadResult {
	name: string;
	p50_ms: number | null;
	p95_ms: number | null;
	tps?: number | null;
	budget_ms?: number | null;
}
export interface Seed {
	phase: string;
	seconds: number | null;
	size_mb: number | null;
	rows?: number | null;
}
export interface Run {
	run_id: string;
	date: string;
	environment: string;
	host?: string;
	pg_version: string;
	design: Design;
	scale: 'small' | 'medium' | 'large';
	shape: 'default' | 'deep' | 'wide';
	clients?: number;
	duration_s?: number;
	workloads: WorkloadResult[];
	seeds: Seed[];
	checksums?: Record<string, string>;
	/** fixture only: path of the saved report in pg_permissions */
	report?: string;
	/** file name the run was loaded from */
	file: string;
}

export const REPO = 'https://github.com/kiwicopple/pg-extensions';
export const REF = process.env.DOCS_REPO_REF ?? 'main';
export const BASELINES_URL = `${REPO}/tree/${REF}/pg_permissions/bench/baselines`;
export const DATA_URL = `${BASELINES_URL}/data`;

const real = import.meta.glob<Omit<Run, 'file'>>('/src/data/bench/*.json', { eager: true, import: 'default' });
const fixture = import.meta.glob<Omit<Run, 'file'>>('/src/data/fixture/*.json', { eager: true, import: 'default' });

export const usingFixture = Object.keys(real).length === 0;
const source = usingFixture ? fixture : real;

const DESIGNS = ['a', 'b', 'c'];
const SCALES = ['small', 'medium', 'large'];
const SHAPES = ['default', 'deep', 'wide'];

function valid(r: any, file: string): boolean {
	const ok =
		r &&
		DESIGNS.includes(r.design) &&
		SCALES.includes(r.scale) &&
		SHAPES.includes(r.shape) &&
		Array.isArray(r.workloads) &&
		typeof r.pg_version === 'string';
	if (!ok) console.warn(`[bench] ${file}: not a valid run (design/scale/shape/workloads/pg_version), skipped`);
	return !!ok;
}

export const runs: Run[] = Object.entries(source)
	.map(([path, r]) => ({ ...(r as any), file: path.split('/').pop()! }) as Run)
	.filter((r) => valid(r, r.file))
	.map((r) => ({ ...r, environment: r.environment ?? 'local', seeds: r.seeds ?? [] }));

/** A series is one (environment, Postgres major version) combination, e.g. "PG 17 (docker)". */
export interface Series {
	key: string;
	label: string;
	major: number;
	environment: string;
	runs: Run[];
	/** latest run per (design, scale, shape) */
	get(design: Design, scale: string, shape: string): Run | undefined;
	/** configurations present, ordered */
	configs: { scale: string; shape: string; label: string; designs: Design[] }[];
	versions: string[];
}

export const configLabel = (scale: string, shape: string) => `${scale} ${shape}`;

const CONFIG_ORDER = ['large-default', 'medium-default', 'small-default', 'medium-deep', 'medium-wide'];
const configRank = (s: string, h: string) => {
	const i = CONFIG_ORDER.indexOf(`${s}-${h}`);
	return i < 0 ? 99 : i;
};

function makeSeries(key: string, rs: Run[]): Series {
	const major = Math.floor(Number.parseFloat(rs[0].pg_version));
	const environment = rs[0].environment;
	const latest = new Map<string, Run>();
	for (const r of [...rs].sort((x, y) => (x.date < y.date ? -1 : 1))) {
		latest.set(`${r.design}|${r.scale}|${r.shape}`, r);
	}
	const cfg = new Map<string, Set<Design>>();
	for (const r of latest.values()) {
		const k = `${r.scale}|${r.shape}`;
		if (!cfg.has(k)) cfg.set(k, new Set());
		cfg.get(k)!.add(r.design);
	}
	const configs = [...cfg.entries()]
		.map(([k, d]) => {
			const [scale, shape] = k.split('|');
			return { scale, shape, label: configLabel(scale, shape), designs: [...d].sort() as Design[] };
		})
		.sort((a, b) => configRank(a.scale, a.shape) - configRank(b.scale, b.shape));
	return {
		key,
		label: `PG ${major} (${environment})`,
		major,
		environment,
		runs: rs,
		get: (d, s, h) => latest.get(`${d}|${s}|${h}`),
		configs,
		versions: [...new Set(rs.map((r) => r.pg_version))].sort(),
	};
}

export const allSeries: Series[] = (() => {
	const groups = new Map<string, Run[]>();
	for (const r of runs) {
		const major = Math.floor(Number.parseFloat(r.pg_version));
		const k = `${r.environment}-pg${major}`;
		if (!groups.has(k)) groups.set(k, []);
		groups.get(k)!.push(r);
	}
	return [...groups.entries()]
		.map(([k, rs]) => makeSeries(k, rs))
		.sort((a, b) => a.major - b.major || a.environment.localeCompare(b.environment));
})();

/** The series the dashboard shows: the one with the most runs (ties: lowest Postgres major). */
export const primary: Series | undefined = [...allSeries].sort(
	(a, b) => b.runs.length - a.runs.length || a.major - b.major,
)[0];

// ---- workloads ----

export interface WorkloadInfo {
	name: string;
	group: string;
	label: string;
	title: string;
	kind: 'read' | 'write';
	description: string;
}

const generated = import.meta.glob<Record<string, { description: string }>>('/src/data/workloads.generated.json', {
	eager: true,
	import: 'default',
});
const descriptions = Object.values(generated)[0] ?? {};

const L = labels as Record<string, { group: string; label: string; title: string; kind: 'read' | 'write' }>;
export const WORKLOAD_ORDER = Object.keys(L);

export function workloadInfo(name: string): WorkloadInfo {
	const l = L[name];
	return {
		name,
		group: l?.group ?? 'Other',
		label: l?.label ?? name,
		title: l?.title ?? name,
		kind: l?.kind ?? 'read',
		description: descriptions[name]?.description ?? '',
	};
}

export function workloadNames(rs: Run[]): string[] {
	const seen = new Set(rs.flatMap((r) => r.workloads.map((w) => w.name)));
	const known = WORKLOAD_ORDER.filter((n) => seen.has(n));
	return [...known, ...[...seen].filter((n) => !L[n]).sort()];
}

export const workload = (r: Run | undefined, name: string) => r?.workloads.find((w) => w.name === name);
export const p50 = (r: Run | undefined, name: string) => workload(r, name)?.p50_ms ?? undefined;
export const p95 = (r: Run | undefined, name: string) => workload(r, name)?.p95_ms ?? undefined;

export const PHASES = ['rbac', 'sharing', 'parents_proj', 'parents', 'nesting'];
export const PHASE_LABELS: Record<string, string> = {
	rbac: 'RBAC',
	sharing: 'Sharing',
	parents_proj: 'Parents (proj.)',
	parents: 'Parents (links)',
	nesting: 'Nesting',
};

export const raw = (r: Run) =>
	r.report ? `${REPO}/blob/${REF}/pg_permissions/${r.report}` : `${DATA_URL}/${r.file}`;

export function ratio(a: number | undefined, b: number | undefined): string {
	if (!a || !b) return '';
	const x = a / b;
	if (x >= 100) return `${Number(x.toPrecision(2)).toLocaleString('en-US')}x`;
	return x >= 10 ? `${Math.round(x)}x` : `${x.toFixed(1)}x`;
}

// ---- helpers shared by the dashboard sections ----

export const SCALE_DOCS: Record<string, string> = { small: '10k', medium: '100k', large: '1M' };

/** Site URL honouring Astro's `base`. */
export function url(path: string): string {
	const base = import.meta.env.BASE_URL.replace(/\/$/, '');
	return `${base}/${path.replace(/^\//, '')}`;
}

/** Anchor of a configuration's section in the synced COMPARISON report, when it has one. */
export function comparisonAnchor(scale: string, shape: string): string {
	const known = ['large-default', 'medium-default', 'small-default', 'medium-deep', 'medium-wide'];
	return known.includes(`${scale}-${shape}`) ? `#${scale}-${shape}-shape` : '';
}

export const comparisonLink = (scale?: string, shape?: string) =>
	url(`benchmarks/comparison/${scale && shape ? comparisonAnchor(scale, shape) : ''}`);

export type ByEngine = Partial<Record<Design, number>>;

/** p50 of one workload for each engine at one configuration. */
export function p50s(s: Series, scale: string, shape: string, name: string): ByEngine {
	const out: ByEngine = {};
	for (const d of ['a', 'b', 'c'] as Design[]) {
		const v = p50(s.get(d, scale, shape), name);
		if (v != null) out[d] = v;
	}
	return out;
}

export function extremes(v: ByEngine) {
	const e = Object.entries(v) as [Design, number][];
	if (!e.length) return undefined;
	e.sort((a, b) => a[1] - b[1]);
	return { min: { d: e[0][0], v: e[0][1] }, max: { d: e[e.length - 1][0], v: e[e.length - 1][1] } };
}

/** "3.2x" / "160x" */
export function times(x: number | undefined): string {
	if (x == null || !Number.isFinite(x)) return '';
	if (x >= 100) return `${Number(x.toPrecision(2)).toLocaleString('en-US')}x`;
	return x >= 10 ? `${Math.round(x)}x` : `${x.toFixed(1)}x`;
}
