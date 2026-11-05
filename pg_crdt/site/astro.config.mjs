// @ts-check
import { defineConfig } from 'astro/config';
import { sidebar } from './navigation.mjs';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';

const repo = process.env.DOCS_REPO_URL ?? 'https://github.com/kiwicopple/pg-extensions';
const ref = process.env.DOCS_REPO_REF ?? 'main';

// The production URL is not decided. Change this one constant (and "userSite" in
// ../research/navigation.json) when it is, or set DOCS_SITE at build time.
const DEFAULT_SITE = 'https://pg-crdt.vercel.app';

// Set DOCS_SITE / DOCS_BASE when deploying below a path. All links in the
// synced docs are relative, so any base works.
export default defineConfig({
	site: process.env.DOCS_SITE ?? DEFAULT_SITE,
	base: process.env.DOCS_BASE,
	integrations: [
		starlight({
			title: 'pg_crdt',
			description:
				'pg_crdt: CRDTs (conflict-free replicated data types) for Postgres, in SQL and PL/pgSQL. A PN-Counter that several writers can change independently and merge later.',
			logo: { src: './src/assets/logo.svg', alt: '' },
			favicon: '/favicon.svg',
			social: [{ icon: 'github', label: 'GitHub', href: `${repo}/tree/${ref}/pg_crdt` }],
			editLink: { baseUrl: `${repo}/edit/${ref}/pg_crdt/site/` },
			customCss: ['./src/styles/custom.css'],
			plugins: [starlightLinksValidator({ errorOnRelativeLinks: false, errorOnInvalidHashes: true })],
			sidebar,
		}),
	],
});
