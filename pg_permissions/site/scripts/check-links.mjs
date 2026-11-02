#!/usr/bin/env node
// Post-build link check over dist/*.html. starlight-links-validator skips relative links (which is what
// the synced docs use so they work under any base path), so this checks every internal href, including
// #hash targets, by resolving it against the built files. Exits 1 on any broken link.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DIST = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist');
const BASE = (process.env.DOCS_BASE ?? '').replace(/\/$/, '');

const walk = (d) =>
	fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
const htmlFiles = walk(DIST).filter((f) => f.endsWith('.html'));
const idCache = new Map();
const ids = (file) => {
	if (!idCache.has(file)) {
		const html = fs.readFileSync(file, 'utf8');
		idCache.set(file, new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1])));
	}
	return idCache.get(file);
};

const errors = [];
let checked = 0;
for (const file of htmlFiles) {
	const rel = path.relative(DIST, file).split(path.sep).join('/');
	const pageUrl = '/' + (rel.endsWith('index.html') ? rel.slice(0, -'index.html'.length) : rel);
	const html = fs.readFileSync(file, 'utf8');
	for (const m of html.matchAll(/<a\s[^>]*?href="([^"]*)"/g)) {
		let href = m[1].replace(/&amp;/g, '&');
		if (/^([a-z][a-z0-9+.-]*:|\/\/)/i.test(href)) continue; // external, mailto, etc.
		const [pathPart, hash] = href.split('#');
		let target = pathPart.split('?')[0];
		const samePage = target === '';
		if (samePage) target = pageUrl;
		else if (!target.startsWith('/')) target = new URL(target, 'http://x' + BASE + pageUrl).pathname;
		if (BASE && !samePage) {
			if (!target.startsWith(BASE + '/') && target !== BASE) { errors.push(`${rel}: ${href} is outside base ${BASE}`); continue; }
			target = target.slice(BASE.length) || '/';
		}
		target = decodeURI(target);
		if (target.startsWith('/pagefind/')) continue;
		let f = path.join(DIST, target);
		if (target.endsWith('/')) f = path.join(f, 'index.html');
		else if (!path.extname(f)) f = path.join(f, 'index.html');
		checked++;
		if (!fs.existsSync(f)) { errors.push(`${rel}: ${href} -> missing ${path.relative(DIST, f)}`); continue; }
		if (hash && f.endsWith('.html') && !ids(f).has(decodeURIComponent(hash))) errors.push(`${rel}: ${href} -> no #${hash} in ${path.relative(DIST, f)}`);
	}
}
if (errors.length) {
	console.error(`check-links: ${errors.length} broken link(s) of ${checked} checked:`);
	for (const e of errors.slice(0, 50)) console.error('  ' + e);
	process.exit(1);
}
console.log(`check-links: ${checked} internal links in ${htmlFiles.length} pages, all resolve`);
