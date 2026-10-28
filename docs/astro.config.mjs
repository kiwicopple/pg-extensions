// @ts-check
import { defineConfig } from 'astro/config';
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
				'Design, decision guide and benchmarks for pg_permissions, a pure SQL authorization extension for Postgres.',
			logo: { src: './src/assets/logo.svg', alt: '' },
			favicon: '/favicon.svg',
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/kiwicopple/pg-extensions/tree/main/pg_permissions',
				},
			],
			editLink: { baseUrl: 'https://github.com/kiwicopple/pg-extensions/edit/main/docs/' },
			customCss: ['./src/styles/custom.css', './src/styles/viz.css'],
			plugins: [starlightLinksValidator({ errorOnRelativeLinks: false, errorOnInvalidHashes: true })],
			sidebar: [
				{
					label: 'Overview',
					items: [
						{ label: 'Home', slug: 'index' },
						{ label: 'README', slug: 'overview/readme' },
						{ label: 'Plan', slug: 'overview/plan' },
						{ label: 'Goals', slug: 'overview/goals' },
					],
				},
				{
					label: 'Decision',
					items: [{ label: 'Decision guide', slug: 'decision/guide' }],
				},
				{
					label: 'Benchmarks',
					items: [
						{ label: 'Dashboard', slug: 'benchmarks/dashboard' },
						{ label: 'Postgres versions', slug: 'benchmarks/postgres-versions' },
						{ label: 'Engine comparison (report)', slug: 'benchmarks/comparison' },
					],
				},
				{
					label: 'Designs',
					items: [
						{ label: 'A: tuple core', slug: 'designs/a-tuple-core' },
						{ label: 'B: policy first', slug: 'designs/b-policy-first' },
						{ label: 'C: compiled model', slug: 'designs/c-compiled-model' },
						{ label: 'Prototypes', slug: 'designs/prototypes' },
					],
				},
				{
					label: 'Testing',
					items: [{ label: 'Test suite and bench harness', slug: 'testing/test-suite' }],
				},
				{
					label: 'Journal',
					items: [{ label: 'Build journal', slug: 'journal/build-journal' }],
				},
			],
		}),
	],
});
