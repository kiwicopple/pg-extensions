// Research records (../research) are published on the monorepo research site (research-site/ at the repo
// root), not on this site. Links to them become absolute URLs there. ../research/navigation.json maps each
// research source file to its route, so this site and the research site agree on the URLs.
import nav from '../research/navigation.json' with { type: 'json' };

/** Root of the research site; override with DOCS_RESEARCH_URL (the research site's origin plus base). */
export const RESEARCH_SITE = (process.env.DOCS_RESEARCH_URL ?? 'https://kiwicopple.github.io/pg-extensions').replace(/\/+$/, '');
/** Root of the pg_permissions section of the research site. */
export const RESEARCH_URL = `${RESEARCH_SITE}/pg_permissions`;

const bySrc = new Map(nav.pages.map((p) => [`research/${p.src}`, p.route]));
const routes = new Set(nav.pages.map((p) => p.route));
const addSlugs = (items) => items.forEach((i) => (i.items ? addSlugs(i.items) : routes.add(i.slug)));
addSlugs(nav.sidebar); // hand-written pages of the research site (charts) are only in the sidebar

/** Absolute research site URL of a route ('' is the pg_permissions index) plus an optional ?query/#anchor tail. */
export function researchUrl(route, tail = '') {
	return `${RESEARCH_URL}/${route ? route + '/' : ''}${tail}`;
}

/** A source path relative to pg_permissions/ (a research page, or a directory with a README page), or null. */
export function researchSourceUrl(rel, tail = '') {
	const key = rel.replace(/\/$/, '');
	const route = bySrc.get(key) ?? bySrc.get(`${key}/README.md`);
	return route === undefined ? null : researchUrl(route, tail);
}

/** A site path from when research was on this site (/research/<route>/), or null. */
export function researchSitePath(url) {
	const m = url.match(/^\/research(?:\/([^?#]*?))?\/?([?#].*)?$/);
	if (!m) return null;
	const route = m[1] === 'overview' ? '' : m[1] ?? '';
	return routes.has(route) ? researchUrl(route, m[2] ?? '') : null;
}
