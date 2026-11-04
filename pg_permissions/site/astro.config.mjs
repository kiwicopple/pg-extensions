// @ts-check
import { defineConfig } from 'astro/config';
import { sidebar } from './navigation.mjs';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';
import { satteri } from '@astrojs/markdown-satteri';
import baseLinks from './markdown-base-links.mjs';

// Set DOCS_SITE / DOCS_BASE when deploying (e.g. GitHub Pages under /pg-extensions).
// All links in the synced docs are relative, so any base works.
export default defineConfig({
	site: process.env.DOCS_SITE ?? 'https://permissions.dev',
	base: process.env.DOCS_BASE,
	markdown: { processor: satteri({ mdastPlugins: [baseLinks({ base: process.env.DOCS_BASE })] }) },
	integrations: [
		starlight({
			title: 'pg_permissions',
			description:
				'pg_permissions: an authorization store and check engine for Postgres with RBAC, OpenFGA and Cedar, plus optional RLS enforcement.',
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
			customCss: ['./src/styles/custom.css'],
			components: {
				PageTitle: './src/components/SitePageTitle.astro',
				SocialIcons: './src/components/SiteLinks.astro',
			},
			plugins: [starlightLinksValidator({ errorOnRelativeLinks: false, errorOnInvalidHashes: true })],
			sidebar,
		}),
	],
});
