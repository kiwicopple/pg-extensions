// Before -> after comparison of the session 3 optimizations. "Before" is the untagged Docker series, "after" the
// same Postgres major version and Docker environment with tag `opt`. Everything here is computed from the run files.

import { findSeries, p50, tagLabel, times, workloadInfo } from './bench';
import type { Series } from './bench';
import type { Design } from './chart';

export const DESIGNS: Design[] = ['a', 'b', 'c'];
export const ENVIRONMENT = 'docker';
export const AFTER_TAG = 'opt';
/** The page's main version; the other versions appear in the "same on 16 and 17" table. */
export const MAIN_MAJOR = 18;
export const MAJORS = [16, 17, 18];
/** Engines whose p50 are within this factor of the best are ranked as tied. Same ~20% noise floor as the dashboard. */
export const TIE = 1.2;

export type Metric = 'p50' | 'seed_s' | 'size_mb';
export interface Case {
	id: string;
	/** workload name (p50) or seed phase (seed_s, size_mb) */
	key: string;
	metric: Metric;
	scale: string;
	shape: string;
	/** short name of the thing measured */
	title: string;
	/** ranking-table name of the workload class */
	cls: string;
}
export const UNIT: Record<Metric, string> = { p50: 'ms', seed_s: 's', size_mb: 'MB' };
const configName = (c: { scale: string; shape: string }) => `${c.scale} ${c.shape}`;
export const caseConfig = configName;

const wl = (key: string, scale: string, shape: string, cls?: string): Case => ({
	id: `${key}|${scale}|${shape}`,
	key,
	metric: 'p50',
	scale,
	shape,
	title: workloadInfo(key).title,
	cls: cls ?? workloadInfo(key).title,
});

/** The workloads the optimizations were aimed at. Wide shape for the sharing reads, large default for the rest. */
export const KEY_CASES: Case[] = [
	wl('share_select_page', 'medium', 'wide', 'Sharing page, wide teams'),
	wl('share_list_objects', 'medium', 'wide', 'Sharing id list, wide teams'),
	wl('parents_select_page', 'large', 'default', 'Parents, single-branch page'),
	wl('write_nest_team', 'large', 'default', 'Nesting write'),
	wl('nest_check', 'large', 'default', 'Check through a nested team'),
];

/** Control group: the RBAC workloads should not move. */
export const RBAC_CASES: Case[] = ['rbac_check', 'rbac_select_page', 'rbac_select_count', 'rbac_update_one', 'write_assign_role'].map((n) =>
	wl(n, 'large', 'default'),
);

const seed = (metric: 'seed_s' | 'size_mb', key: string, scale: string, shape: string, title: string, cls: string): Case => ({
	id: `${metric}|${key}|${scale}|${shape}`,
	key,
	metric,
	scale,
	shape,
	title,
	cls,
});
export const SEED_TIME_CASES: Case[] = [
	seed('seed_s', 'parents', 'large', 'default', 'Seed: per-document parent links', 'Seed time: parent links'),
	seed('seed_s', 'sharing', 'medium', 'wide', 'Seed: sharing', 'Seed time: wide sharing'),
];
export const STORAGE_CASES: Case[] = [
	seed('size_mb', 'parents', 'large', 'default', 'Storage after the parents seed', 'Storage: parent links'),
	seed('size_mb', 'sharing', 'medium', 'wide', 'Storage after the sharing seed', 'Storage: wide sharing'),
];

/** One row per workload class in the ranking table. */
export const RANK_CASES: Case[] = [
	wl('rbac_select_page', 'large', 'default', 'RBAC, first page'),
	wl('share_select_page', 'large', 'default', 'Sharing page, default teams'),
	KEY_CASES[0],
	KEY_CASES[1],
	wl('parents_proj_select_page', 'large', 'default', 'Parents, projection page'),
	KEY_CASES[2],
	KEY_CASES[3],
	KEY_CASES[4],
	STORAGE_CASES[0],
	SEED_TIME_CASES[0],
	SEED_TIME_CASES[1],
];

export interface Pair {
	before: Series | undefined;
	after: Series | undefined;
}
export const pairFor = (major: number): Pair => ({
	before: findSeries(ENVIRONMENT, major, undefined),
	after: findSeries(ENVIRONMENT, major, AFTER_TAG),
});

export function value(s: Series | undefined, d: Design, c: Case): number | undefined {
	const run = s?.get(d, c.scale, c.shape);
	if (!run) return undefined;
	if (c.metric === 'p50') return p50(run, c.key);
	const x = run.seeds.find((q) => q.phase === c.key);
	return (c.metric === 'seed_s' ? x?.seconds : x?.size_mb) ?? undefined;
}

export interface Item {
	design: Design;
	before: number;
	after: number;
}
export function items(pair: Pair, c: Case): Item[] {
	return DESIGNS.flatMap((design) => {
		const before = value(pair.before, design, c);
		const after = value(pair.after, design, c);
		return before != null && after != null ? [{ design, before, after }] : [];
	});
}

export type Direction = 'faster' | 'slower' | 'same';
/** before / after, lower is better; "same" within the TIE factor. */
export function change(before: number, after: number) {
	const r = before / after;
	const dir: Direction = r >= TIE ? 'faster' : r <= 1 / TIE ? 'slower' : 'same';
	const text = dir === 'faster' ? `${times(r)} faster` : dir === 'slower' ? `${times(1 / r)} slower` : 'within 20%';
	return { r, dir, text };
}

/** Engines grouped best first; a group holds the engines within TIE of the group's best value. */
export function rankGroups(v: Partial<Record<Design, number>>): Design[][] {
	const e = (Object.entries(v) as [Design, number][]).filter(([, x]) => x != null).sort((a, b) => a[1] - b[1] || a[0].localeCompare(b[0]));
	const groups: { head: number; ds: Design[] }[] = [];
	for (const [d, x] of e) {
		const g = groups[groups.length - 1];
		if (g && x <= g.head * TIE) g.ds.push(d);
		else groups.push({ head: x, ds: [d] });
	}
	return groups.map((g) => g.ds.sort());
}
export const rankKey = (g: Design[][]) => g.map((x) => x.join('')).join('<');

export function rankingRows() {
	const pair = pairFor(MAIN_MAJOR);
	return RANK_CASES.map((c) => {
		const before: Partial<Record<Design, number>> = {};
		const after: Partial<Record<Design, number>> = {};
		for (const d of DESIGNS) {
			const b = value(pair.before, d, c);
			const a = value(pair.after, d, c);
			if (b != null) before[d] = b;
			if (a != null) after[d] = a;
		}
		const gb = rankGroups(before);
		const ga = rankGroups(after);
		return { c, before, after, gb, ga, changed: rankKey(gb) !== rankKey(ga) };
	});
}

/** Every (case, engine) change on the main version, for the computed takeaways. */
export function allChanges(cases: Case[]) {
	const pair = pairFor(MAIN_MAJOR);
	return cases.flatMap((c) => items(pair, c).map((i) => ({ c, ...i, ...change(i.before, i.after) })));
}

export const afterLabel = tagLabel(AFTER_TAG);

/** Rows for the Dumbbell chart. */
export function dumbbellRows(pair: Pair, cases: Case[]) {
	return cases
		.map((c) => ({
			title: c.cls,
			sub: c.metric === 'p50' ? c.key : `${c.metric === 'seed_s' ? 'seed seconds' : 'size after phase'}: ${c.key}`,
			ctx: configName(c),
			items: items(pair, c),
		}))
		.filter((r) => r.items.length);
}

export const engineLetter = (d: Design) => d.toUpperCase();
/** "B nesting a team: 107 to 0.62 ms (172x faster)" */
export function describeChange(x: { c: Case; design: Design; before: number; after: number; text: string }, fmt: (v: number) => string) {
	return `${engineLetter(x.design)} ${x.c.cls.toLowerCase()}: ${fmt(x.before)} to ${fmt(x.after)} ${UNIT[x.c.metric]} (${x.text})`;
}

/** What the two series are, for chart subtitles. */
export const beforeAfterText = (pair: Pair) =>
	pair.before && pair.after
		? `Before: ${pair.before.label.replace(')', ', untagged)')}; after: ${pair.after.label} (Postgres ${pair.after.versions.join(', ')})`
		: '';
