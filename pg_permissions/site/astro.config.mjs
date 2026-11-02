// @ts-check
import { defineConfig } from 'astro/config';
import { sidebar } from './navigation.mjs';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';

// Set DOCS_SITE / DOCS_BASE when deploying (e.g. GitHub Pages under /pg-extensions).
// All links in the synced docs are relative, so any base works.
export default defineConfig({
	site: process.env.DOCS_SITE,
	base: process.env.DOCS_BASE,
	integrations: [
		starlight({
			title: 'pg_permissions',
			description:
				'pg_permissions: authorization for Postgres with RBAC, OpenFGA-compatible relationships and Cedar policies, usable in RLS policies.',
			logo: { src: './src/assets/logo.svg', alt: '' },
			favicon: '/favicon.svg',
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: `${process.env.DOCS_REPO_URL ?? 'https://github.com/kiwicopple/pg-extensions'}/tree/${process.env.DOCS_REPO_REF ?? 'main'}/pg_permissions`,
				},
			],
			editLink: { baseUrl: `${process.env.DOCS_REPO_URL ?? 'https://github.com/kiwicopple/pg-extensions'}/edit/${process.env.DOCS_REPO_REF ?? 'main'}/pg_permissions/site/` },
			customCss: ['./src/styles/custom.css', './src/styles/viz.css'],
			plugins: [starlightLinksValidator({ errorOnRelativeLinks: false, errorOnInvalidHashes: true })],
			sidebar,
		}),
	],
});
