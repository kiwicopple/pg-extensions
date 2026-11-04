// Shared settings for astro.config.mjs and the scripts: deployment URL, repository, and the extensions
// that have research. Any top-level directory with a research/ directory is an extension on this site.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SITE_DIR = path.dirname(fileURLToPath(import.meta.url)); // research-site/
export const REPO_ROOT = path.resolve(SITE_DIR, '..');
export const SITE = process.env.DOCS_SITE ?? 'https://kiwicopple.github.io';
export const BASE = process.env.DOCS_BASE ?? '/pg-extensions';
export const REPO = process.env.DOCS_REPO_URL ?? 'https://github.com/kiwicopple/pg-extensions';
export const REF = process.env.DOCS_REPO_REF ?? 'main';

const isDir = (p) => fs.existsSync(p) && fs.statSync(p).isDirectory();
const posix = (p) => p.split(path.sep).join('/');

/**
 * Every <extension>/research/ directory, sorted by name. `nav` is research/navigation.json when the
 * extension has one: { title, userSite, pages: [{ src, route, label, historical }], sidebar }. Without it,
 * every Markdown file is a page and the sidebar is generated from the directory tree.
 */
export function extensions() {
	return fs
		.readdirSync(REPO_ROOT, { withFileTypes: true })
		.filter((e) => e.isDirectory() && !e.name.startsWith('.') && e.name !== 'node_modules')
		.filter((e) => path.join(REPO_ROOT, e.name) !== SITE_DIR && isDir(path.join(REPO_ROOT, e.name, 'research')))
		.map((e) => {
			const navFile = path.join(REPO_ROOT, e.name, 'research', 'navigation.json');
			const nav = fs.existsSync(navFile) ? JSON.parse(fs.readFileSync(navFile, 'utf8')) : null;
			return { name: e.name, title: nav?.title ?? e.name, nav, pages: nav ? nav.pages : autoPages(e.name) };
		})
		.sort((a, b) => a.name.localeCompare(b.name));
}

/** Pages of an extension without navigation.json: each Markdown file, README.md as its directory's index. */
function autoPages(ext) {
	const root = path.join(REPO_ROOT, ext, 'research');
	const walk = (d) =>
		fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
	return walk(root)
		.filter((f) => f.endsWith('.md'))
		.sort()
		.map((f) => {
			const src = posix(path.relative(root, f));
			const route = src.replace(/(^|\/)README\.md$/, '').replace(/\.md$/, '').toLowerCase().replace(/[^a-z0-9/_.-]+/g, '-');
			return { src, route, label: path.basename(src, '.md') };
		});
}

/** Full slug of a route of an extension; '' is the extension's index. */
export const slug = (ext, route) => (route ? `${ext}/${route}` : ext);

/** One sidebar group per extension: navigation.json's sidebar, or generated from the directory. */
export function sidebar() {
	const prefix = (ext, items) =>
		items.map((i) => (i.items ? { ...i, items: prefix(ext, i.items) } : { ...i, slug: slug(ext, i.slug) }));
	return extensions().map((e) =>
		e.nav?.sidebar ? { label: e.title, items: prefix(e.name, e.nav.sidebar) } : { label: e.title, items: [{ autogenerate: { directory: e.name } }] },
	);
}

/** Stylesheets of extension-specific site components (src/extensions/<ext>/styles/*.css). */
export function extensionCss() {
	const root = path.join(SITE_DIR, 'src', 'extensions');
	if (!isDir(root)) return [];
	return fs
		.readdirSync(root)
		.filter((ext) => isDir(path.join(root, ext, 'styles')))
		.flatMap((ext) =>
			fs.readdirSync(path.join(root, ext, 'styles')).filter((f) => f.endsWith('.css')).map((f) => `./src/extensions/${ext}/styles/${f}`),
		)
		.sort();
}
