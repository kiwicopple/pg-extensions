// pg_permissions data for the benchmark chart pages (src/content/docs/pg_permissions/**/*.mdx).
// Called by scripts/sync.mjs. Everything written here is generated and gitignored.
//   1. Bench data -> data/bench/*.json               (copied from pg_permissions/bench/baselines/data)
//   2. Workloads  -> data/workloads.generated.json   (description = first sentence of each workload SQL file header)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT_DATA = path.join(path.dirname(fileURLToPath(import.meta.url)), 'data');
const posix = (p) => p.split(path.sep).join('/');

function syncData(SRC_ROOT, warn) {
	const from = path.join(SRC_ROOT, 'bench', 'baselines', 'data');
	const to = path.join(OUT_DATA, 'bench');
	fs.rmSync(to, { recursive: true, force: true });
	if (!fs.existsSync(from)) {
		console.log('sync: pg_permissions: no bench/baselines/data yet, the charts will use data/fixture');
		return;
	}
	fs.mkdirSync(to, { recursive: true });
	let n = 0;
	for (const f of fs.readdirSync(from)) {
		if (!f.endsWith('.json')) continue;
		try {
			JSON.parse(fs.readFileSync(path.join(from, f), 'utf8'));
		} catch (e) {
			warn(`pg_permissions: bench data ${f} is not valid JSON, skipped (${e.message})`);
			continue;
		}
		fs.copyFileSync(path.join(from, f), path.join(to, f));
		n++;
	}
	console.log(`sync: pg_permissions: ${n} bench data file(s) -> data/bench${n ? '' : ' (empty: using fixture)'}`);
}

function syncWorkloads(SRC_ROOT) {
	// design d's directory last, for the workloads only it has (conditions, blocklist); the shared names keep c's text
	const dirs = [path.join(SRC_ROOT, 'bench', 'workloads'), path.join(SRC_ROOT, 'bench', 'designs', 'c', 'workloads'),
		path.join(SRC_ROOT, 'bench', 'designs', 'd', 'workloads')];
	const out = {};
	for (const dir of dirs) {
		if (!fs.existsSync(dir)) continue;
		for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.sql'))) {
			const name = f.replace(/\.sql$/, '');
			if (out[name]) continue;
			const header = [];
			for (const line of fs.readFileSync(path.join(dir, f), 'utf8').split('\n')) {
				const m = line.match(/^--\s?(.*)$/);
				if (!m) break;
				header.push(m[1].trim());
			}
			const joined = header.join(' ').replace(/\s+/g, ' ');
			const sentence = joined.match(/^(.*?[.!?])(\s|$)/)?.[1] ?? joined;
			out[name] = { description: sentence, source: posix(path.relative(SRC_ROOT, path.join(dir, f))) };
		}
	}
	fs.mkdirSync(OUT_DATA, { recursive: true });
	fs.writeFileSync(path.join(OUT_DATA, 'workloads.generated.json'), JSON.stringify(out, null, 2) + '\n');
	console.log(`sync: pg_permissions: ${Object.keys(out).length} workload descriptions -> data/workloads.generated.json`);
}

/** @param {{ extDir: string, warn: (m: string) => void }} ctx  extDir is pg_permissions/ */
export default function sync({ extDir, warn }) {
	syncData(extDir, warn);
	syncWorkloads(extDir);
}
