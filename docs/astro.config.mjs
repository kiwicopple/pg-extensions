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
				'pg_permissions: authorization for Postgres with RBAC and OpenFGA-compatible relationships, usable in RLS policies.',
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
				// User docs
				{ label: 'Home', slug: 'index' },
				{ label: 'Using pg_permissions', slug: 'guide' },
				{ label: 'Install', slug: 'install' },
				{ label: 'RBAC', slug: 'rbac' },
				{ label: 'FGA', slug: 'fga' },
				{ label: 'Conditions', slug: 'conditions' },
				{ label: 'RLS', slug: 'rls' },
				{ label: 'Reference', slug: 'reference' },
				{ label: 'Errors and limits', slug: 'errors-and-limits' },
				{
					label: 'Contributing',
					items: [
						{ label: 'Test suite and bench harness', slug: 'contributing/test-suite' },
						{ label: 'Style guide', slug: 'contributing/style-guide' },
					],
				},
				// How it was designed, measured and chosen
				{
					label: 'Research',
					collapsed: true,
					items: [
						{ label: 'Overview', slug: 'research/overview' },
						{ label: 'Plan', slug: 'research/plan' },
						{ label: 'Goals', slug: 'research/goals' },
						{ label: 'Decision guide', slug: 'research/decision' },
						{
							label: 'Designs',
							collapsed: true,
							items: [
								{ label: 'A: tuple core', slug: 'research/designs/a-tuple-core' },
								{ label: 'B: policy first', slug: 'research/designs/b-policy-first' },
								{ label: 'C: compiled model', slug: 'research/designs/c-compiled-model' },
								{ label: 'D: per-model tables', slug: 'research/designs/d-per-model' },
								{ label: 'D: conditions (CEL)', slug: 'research/designs/d-conditions' },
							],
						},
						{
							label: 'Prototypes',
							collapsed: true,
							items: [
								{ label: 'Overview', slug: 'research/prototypes/overview' },
								{ label: 'A: tuple core usage', slug: 'research/prototypes/a-tuple-core' },
								{ label: 'B: policy first usage', slug: 'research/prototypes/b-policy-first' },
								{ label: 'C: compiled model usage', slug: 'research/prototypes/c-compiled-model' },
							],
						},
						{
							label: 'Benchmarks',
							collapsed: true,
							items: [
								{ label: 'Overview', slug: 'research/benchmarks/overview' },
								{ label: 'Dashboard', slug: 'research/benchmarks/dashboard' },
								{ label: 'Optimizations', slug: 'research/benchmarks/optimizations' },
								{ label: 'Postgres versions', slug: 'research/benchmarks/postgres-versions' },
								{ label: 'Engine comparison (report)', slug: 'research/benchmarks/comparison' },
								{ label: 'Postgres versions (report)', slug: 'research/benchmarks/versions-report' },
								{ label: 'Optimizations (report)', slug: 'research/benchmarks/optimizations-report' },
								{ label: 'Design D (report)', slug: 'research/benchmarks/design-d-report' },
							],
						},
						{ label: 'Upstream report: OpenFGA', slug: 'research/upstream/openfga-cycle-but-not' },
						{ label: 'Build journal', slug: 'research/journal' },
					],
				},
			],
		}),
	],
});
