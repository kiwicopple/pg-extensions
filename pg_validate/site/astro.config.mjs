// @ts-check
import { defineConfig } from 'astro/config';
import { sidebar } from './navigation.mjs';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';

const repo = process.env.DOCS_REPO_URL ?? 'https://github.com/kiwicopple/pg-extensions';
const ref = process.env.DOCS_REPO_REF ?? 'main';

// Set DOCS_SITE / DOCS_BASE when deploying below a path. All links in the
// synced docs are relative, so any base works.
export default defineConfig({
	site: process.env.DOCS_SITE,
	base: process.env.DOCS_BASE,
	integrations: [
		starlight({
			title: 'pg_validate',
			description:
				'pg_validate: boolean validators for common string formats in Postgres, for CHECK constraints, with a registry of named formats.',
			logo: { src: './src/assets/logo.svg', alt: '' },
			favicon: '/favicon.svg',
			social: [{ icon: 'github', label: 'GitHub', href: `${repo}/tree/${ref}/pg_validate` }],
			editLink: { baseUrl: `${repo}/edit/${ref}/pg_validate/site/` },
			customCss: ['./src/styles/custom.css'],
			plugins: [starlightLinksValidator({ errorOnRelativeLinks: false, errorOnInvalidHashes: true })],
			sidebar,
		}),
	],
});
