#!/usr/bin/env node
// Dev fixture: turn the saved per-run reports (pg_permissions/bench/baselines/<design>-<scale>-<shape>.md)
// into JSON files in the shape the benchmark data contract uses. Output: data/fixture/*.json (next to this file).
// The site only reads the fixture when data/bench has no files. Re-run with `npm run fixture` (in research-site/)
// if the baselines change; the output is committed so the site builds without it.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url)); // research-site/src/extensions/pg_permissions
const BASE = path.resolve(HERE, '..', '..', '..', '..', 'pg_permissions', 'bench', 'baselines');
const OUT = path.join(HERE, 'data', 'fixture');

const rows = (md, heading) => {
	const i = md.indexOf(heading);
	if (i < 0) return [];
	const lines = md.slice(i).split('\n').slice(1);
	const out = [];
	let started = false;
	for (const l of lines) {
		if (l.startsWith('|')) {
			started = true;
			out.push(l.split('|').slice(1, -1).map((c) => c.trim()));
		} else if (started) break;
	}
	return out.slice(1); // the heading line is already dropped; drop the separator
};

fs.mkdirSync(OUT, { recursive: true });
for (const f of fs.readdirSync(OUT)) if (f.endsWith('.json')) fs.rmSync(path.join(OUT, f));

let n = 0;
for (const f of fs.readdirSync(BASE).sort()) {
	const m = f.match(/^([abc])-(small|medium|large)-(default|deep|wide)\.md$/);
	if (!m) continue;
	const [, design, scale, shape] = m;
	const md = fs.readFileSync(path.join(BASE, f), 'utf8');
	const date = md.match(/- Date: (\d{4}-\d\d-\d\d) (\d\d:\d\d)/);
	const pg = md.match(/- Postgres: ([\d.]+)/)?.[1];
	const pgb = md.match(/pgbench: (\d+)s per workload, (\d+) clients/);
	const num = (v) => (v === '-' ? null : Number(v));

	const workloads = rows(md, '| workload | p50 ms').map((r) => ({
		name: r[0], p50_ms: num(r[1]), p95_ms: num(r[2]), tps: num(r[4]), budget_ms: num(r[5]),
	}));
	const seeds = rows(md, '| phase | seed s').map((r) => ({
		phase: r[0], seconds: num(r[1]), size_mb: num(r[2]), rows: num(r[3]),
	}));
	const eq = rows(md, '| policy | user | visible | md5');
	const checksums = {};
	for (const policy of new Set(eq.map((r) => r[0]))) {
		const parts = eq.filter((r) => r[0] === policy).map((r) => `${r[1]}:${r[2]}:${r[3]}`).join('\n');
		checksums[policy] = crypto.createHash('md5').update(parts).digest('hex');
	}
	const run = {
		run_id: `local-pg16-${design}-${scale}-${shape}`,
		date: `${date[1]}T${date[2]}:00Z`,
		environment: 'local',
		host: 'Apple Silicon laptop, Postgres.app (fixture from bench/baselines reports)',
		pg_version: pg,
		design, scale, shape,
		clients: Number(pgb[2]),
		duration_s: Number(pgb[1]),
		workloads, seeds, checksums,
		report: `bench/baselines/${f}`,
	};
	fs.writeFileSync(path.join(OUT, `${run.run_id}.json`), JSON.stringify(run, null, 1) + '\n');
	n++;
}
console.log(`fixture: wrote ${n} run file(s) to data/fixture`);
