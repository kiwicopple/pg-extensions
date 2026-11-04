// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';
import { satteri } from '@astrojs/markdown-satteri';
import baseLinks from './markdown-base-links.mjs';
import { BASE, REPO, REF, SITE, extensionCss, sidebar } from './site.mjs';

// Defaults to GitHub Pages (https://kiwicopple.github.io/pg-extensions); set DOCS_SITE / DOCS_BASE to host elsewhere.
// All links in the synced pages are relative, so any base works.
export default defineConfig({
	site: SITE,
	base: BASE,
	markdown: { processor: satteri({ mdastPlugins: [baseLinks({ base: BASE })] }) },
	integrations: [
		starlight({
			title: 'pg-extensions research',
			description:
				'Design records, benchmark reports, reviews and build journals for the Postgres extensions in kiwicopple/pg-extensions.',
			social: [{ icon: 'github', label: 'GitHub', href: REPO }],
			editLink: { baseUrl: `${REPO}/edit/${REF}/research-site/` },
			customCss: ['./src/styles/custom.css', ...extensionCss()],
			plugins: [starlightLinksValidator({ errorOnRelativeLinks: false, errorOnInvalidHashes: true })],
			sidebar: sidebar(),
		}),
	],
});
