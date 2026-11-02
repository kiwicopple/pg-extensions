#!/usr/bin/env node
// Validate the published Markdown exports, the sidebar, and the reference's
// coverage: every built-in validator has one reference entry with a
// "Guarantees" and a "Does not guarantee" section (STYLE.md).
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { pages, sidebar } from '../navigation.mjs';

const site = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = path.resolve(site, '..');
const dist = path.join(site, 'dist');

// 1. Exports keep the source code fences and their links resolve.
let links = 0;
const seen = new Set();
for (const page of pages) {
  assert.ok(!seen.has(page.route), `Duplicate route: ${page.route}`);
  seen.add(page.route);
  const file = path.join(dist, 'markdown', page.route + '.md');
  const code = (text) => [...text.matchAll(/^```[^\n]*\n([\s\S]*?)^```/gm)].map((m) => m[1]);
  const exported = fs.readFileSync(file, 'utf8');
  assert.deepEqual(code(exported), code(fs.readFileSync(path.join(root, page.src), 'utf8')), `Code changed in Markdown export: ${page.route}`);
  const prose = exported.replace(/^```[^\n]*\n[\s\S]*?^```/gm, '');
  for (const match of prose.matchAll(/\[[^\]]+\]\(([^)\s]+)\)/g)) {
    const target = match[1];
    if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(target) || target.startsWith('#')) continue;
    const resolved = path.resolve(path.dirname(file), decodeURI(target.split('#')[0]));
    assert.ok(fs.existsSync(resolved), `${file}: missing ${target}`);
    links++;
  }
}

// 2. Every sidebar entry was built.
function checkNavigation(items) {
  for (const item of items) {
    if (item.items) checkNavigation(item.items);
    else assert.ok(fs.existsSync(path.join(dist, item.slug, 'index.html')), `Missing sidebar route: ${item.slug}`);
  }
}
checkNavigation(sidebar);
assert.ok(fs.existsSync(path.join(dist, 'llms.txt')), 'Missing agent index');

// 3. Reference coverage, against the list of built-ins in the extension file.
const sql = fs.readFileSync(path.join(root, 'pg_validate--0.0.1.sql'), 'utf8');
const builtins = sql.match(/select '\{([a-z0-9_,]+)\}'::text\[\]/)[1].split(',');
const reference = ['identifiers', 'internet', 'dates', 'international', 'developer', 'financial']
  .map((n) => fs.readFileSync(path.join(root, 'docs', 'reference', `${n}.md`), 'utf8'))
  .join('\n');
const sections = new Map();
for (const part of reference.split(/^### /m).slice(1)) {
  const name = part.match(/^`([a-z0-9_]+)`/)?.[1];
  if (name) sections.set(name, (sections.get(name) ?? '') + part);
}
for (const name of builtins) {
  const body = sections.get(name);
  assert.ok(body, `No reference entry for validator ${name}`);
  assert.ok(/\*\*Guarantees( and limits)?:\*\*/.test(body), `No "Guarantees" section for ${name}`);
  assert.ok(/\*\*Does not guarantee:\*\*|\*\*Guarantees and limits:\*\*/.test(body), `No "Does not guarantee" section for ${name}`);
}
console.log(`check-content: ${pages.length} Markdown exports, ${links} links, ${builtins.length} validators with guarantees`);
