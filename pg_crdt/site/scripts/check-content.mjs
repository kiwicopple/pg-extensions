// Validate the published Markdown exports (code and links), the language tab groups, the sidebar, and
// the reference's coverage: every public function of the extension file has one reference entry, and
// every SQLSTATE the extension raises is in the errors table.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { pages, sidebar } from '../navigation.mjs';
import { convertTabs } from './code-tabs.mjs';

const site = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = path.resolve(site, '..');
const dist = path.join(site, 'dist');
let languageGroups = 0;

// A new client needs only an adjacent fence. Its label, code and position must survive the conversion.
const sample = [['ts', 'JavaScript'], ['cs', 'C#'], ['sql', 'SQL']];
const fixture = sample.map(([lang, label]) =>
  [`~~~${lang} tab="${label}"`, `example in ${label}`, '~~~'].join('\n')).join('\n\n');
const converted = convertTabs(fixture, 'three-language fixture');
assert.equal(converted.groups, 1);
assert.deepEqual([...converted.body.matchAll(/<TabItem label="([^"]+)">\s*~~~(\S+)\n([^\n]+)\n~~~/g)]
  .map(([, label, lang, code]) => [label, lang, code]), sample.map(([lang, label]) => [label, lang, `example in ${label}`]));

function checkLanguageTabs(route, sourceLabels) {
  const html = fs.readFileSync(path.join(dist, route, 'index.html'), 'utf8');
  const labels = [];
  for (const [, content] of html.matchAll(/<starlight-tabs\b[^>]*\bdata-sync-key="lang"[^>]*>([\s\S]*?)<\/starlight-tabs>/g)) {
    const tabs = [...content.matchAll(/<a\b([^>]*\brole="tab"[^>]*)>([^<]+)<\/a>/g)];
    assert.ok(tabs.length >= 2, `Missing tab alternatives: ${route}`);
    if (tabs.some(([, , label]) => label === 'JavaScript')) {
      assert.equal(tabs[0][2], 'JavaScript', `JavaScript must be the first tab: ${route}`);
    }
    assert.match(tabs[0][1], /\baria-selected="true"/, `First tab must be selected by default: ${route}`);
    labels.push(...tabs.map(([, , label]) => label));
    languageGroups++;
  }
  if (sourceLabels) assert.deepEqual(labels, sourceLabels, `Rendered tabs differ from the Markdown: ${route}`);
}

// 1. Exports keep the source code fences (with their tab labels) and their links resolve.
checkLanguageTabs(''); // The homepage is hand-authored MDX.
let links = 0;
const seen = new Set();
for (const page of pages) {
  assert.ok(!seen.has(page.route), `Duplicate route: ${page.route}`);
  seen.add(page.route);
  const file = path.join(dist, 'markdown', page.route + '.md');
  const source = fs.readFileSync(path.join(root, page.src), 'utf8');
  const exported = fs.readFileSync(file, 'utf8');
  const code = (text) => [...text.matchAll(/^([ \t]*)(`{3,}|~{3,})[^\n]*\n[\s\S]*?^\1\2[ \t]*$/gm)].map(([block]) => block);
  assert.deepEqual(code(exported), code(source), `Code changed in Markdown export: ${page.route}`);
  const sourceLabels = [...source.matchAll(/^\s*(?:`{3,}|~{3,})\S+[^\n]*\btab="([^"]+)"/gm)].map((match) => match[1]);
  checkLanguageTabs(page.route, sourceLabels);
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

// 3. Reference coverage, against the public functions in the extension file.
const sql = fs.readFileSync(path.join(root, 'pg_crdt--0.0.1.sql'), 'utf8');
const functions = [...new Set([...sql.matchAll(/^create (?:function|aggregate) crdt\.([a-z][a-z0-9_]*)\(/gm)].map((m) => m[1]))];
assert.ok(functions.length >= 9, 'Found too few functions in the extension file');
const reference = ['shared', 'pn']
  .map((n) => fs.readFileSync(path.join(root, 'docs', 'reference', `${n}.md`), 'utf8'))
  .join('\n');
const entries = [...reference.matchAll(/^### `([a-z0-9_]+)`/gm)].map((m) => m[1]);
assert.equal(new Set(entries).size, entries.length, 'Each function must have one reference entry');
for (const name of functions) assert.ok(entries.includes(name), `No reference entry for function ${name}`);
for (const name of entries) assert.ok(functions.includes(name), `Reference entry for a function that does not exist: ${name}`);

// 4. Every SQLSTATE the extension raises is in the errors table (plus the two Postgres raises: the domain CHECK, overflow).
const errors = fs.readFileSync(path.join(root, 'docs', 'reference', 'errors.md'), 'utf8');
const codes = new Set([...sql.matchAll(/errcode = '([0-9A-Z]{5})'/g)].map((m) => m[1]).concat(['23514', '22003']));
for (const code of codes) assert.ok(errors.includes(`\`${code}\``), `SQLSTATE ${code} is missing from docs/reference/errors.md`);

console.log(`check-content: ${pages.length} Markdown exports, ${languageGroups} language tab groups, ${links} links, ${functions.length} functions and ${codes.size} SQLSTATEs documented`);
