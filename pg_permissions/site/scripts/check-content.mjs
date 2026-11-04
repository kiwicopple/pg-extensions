#!/usr/bin/env node
// Validate published Markdown, old inbound anchors, and the canonical inventory.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { pages, sidebar } from '../navigation.mjs';
import { convertTabs } from './code-tabs.mjs';

const docs = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dist = path.join(docs, 'dist');
const migration = JSON.parse(fs.readFileSync(path.join(docs, 'content-migration.json'), 'utf8'));
const seenSources = new Set();
const seenRoutes = new Set();
const ids = (route) => new Set([...fs.readFileSync(path.join(dist, route, 'index.html'), 'utf8')
  .matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]));
let anchors = 0;
let links = 0;
let languageGroups = 0;

// A new client needs only an adjacent fence. Its label, code and position
// must survive the conversion, alongside the first and last alternatives.
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

checkLanguageTabs(''); // The homepage is hand-authored MDX.
for (const page of pages) {
  assert.ok(!seenSources.has(page.src), `Duplicate source: ${page.src}`);
  assert.ok(!seenRoutes.has(page.route), `Duplicate route: ${page.route}`);
  seenSources.add(page.src); seenRoutes.add(page.route);
  const file = path.join(dist, 'markdown', page.route + '.md');
  const source = fs.readFileSync(path.resolve(docs, '..', page.src), 'utf8');
  const exported = fs.readFileSync(file, 'utf8');
  // Keep the fence metadata too: exported examples need their language labels.
  const code = (text) => [...text.matchAll(/^([ \t]*)(`{3,}|~{3,})[^\n]*\n[\s\S]*?^\1\2[ \t]*$/gm)].map(([block]) => block);
  assert.deepEqual(code(exported), code(source), `Code changed in Markdown export: ${page.route}`);
  const sourceLabels = [...source.matchAll(/^\s*(?:`{3,}|~{3,})\S+[^\n]*\btab="([^"]+)"/gm)].map((match) => match[1]);
  checkLanguageTabs(page.route, sourceLabels);
  // Strip fences and code spans before interpreting Markdown links.
  const prose = exported.replace(/^```[^\n]*\n[\s\S]*?^```/gm, '');
  for (const match of prose.matchAll(/\[[^\]]+\]\(([^)\s]+)\)/g)) {
    const target = match[1];
    if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(target)) continue;
    const [pathname, anchor] = target.split('#');
    const resolved = pathname ? path.resolve(path.dirname(file), decodeURI(pathname)) : file;
    assert.ok(fs.existsSync(resolved), `${file}: missing ${target}`);
    if (anchor && resolved.endsWith('.md')) {
      const route = path.relative(path.join(dist, 'markdown'), resolved).replace(/\.md$/, '').split(path.sep).join('/');
      // The site renders the H1 from frontmatter without an ID; raw Markdown retains it.
      const firstTitle = fs.readFileSync(resolved, 'utf8').match(/^# (.+)$/m)?.[1];
      const titleSlug = firstTitle?.toLowerCase().replace(/[^\w -]/g, '').replace(/ /g, '-');
      assert.ok(ids(route).has(decodeURIComponent(anchor)) || anchor === titleSlug, `${file}: missing #${anchor} in ${route}`);
    }
    links++;
  }
}
for (const [route, headings] of Object.entries(migration.legacyAnchors)) {
  const existing = ids(route);
  for (const anchor of Object.keys(headings)) {
    assert.ok(existing.has(anchor), `Old inbound link no longer resolves: /${route ? route + "/" : ""}#${anchor}`);
    anchors++;
  }
}
function checkNavigation(items) {
  for (const item of items) {
    if (item.items) checkNavigation(item.items);
    else {
      if (item.link && /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(item.link)) continue;
      const route = item.slug ?? item.link.replace(/^\/|\/$/g, '');
      assert.ok(fs.existsSync(path.join(dist, route, 'index.html')) || route === 'index', `Missing sidebar route: ${route}`);
      assert.ok(!pages.find((p) => p.route === route)?.legacy, `Compatibility route in sidebar: ${route}`);
    }
  }
}
checkNavigation(sidebar);
const reference = ['shared', 'rbac', 'openfga', 'cedar'].map((name) =>
  fs.readFileSync(path.resolve(docs, `../docs/reference/${name}.md`), 'utf8')).join('\n');
const functions = [...reference.matchAll(/^### `([^`]+)`/gm)].map((m) => m[1]);
assert.equal(functions.length, 40, 'The SQL reference must cover all 40 public functions');
assert.equal(new Set(functions).size, 40, 'Each SQL function must have one canonical entry');
assert.ok(fs.existsSync(path.join(dist, 'llms.txt')), 'Missing agent index');
console.log(`check-content: ${pages.length} Markdown exports, ${languageGroups} language tab groups, ${links} links, ${anchors} legacy anchors, and 40 SQL functions verified`);
