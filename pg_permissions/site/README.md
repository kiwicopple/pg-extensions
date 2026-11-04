# pg_permissions documentation site

The Astro + Starlight site publishes application guides and API reference for `pg_permissions`. Canonical prose lives in the parent directory, `pg_permissions/` (`../docs` and so on). Edit those files, not the generated site pages.

Research records (`../research`: design records, benchmark reports, reviews, the build journal) are not on this site. They are published on the monorepo research site, built from `research-site/` at the repo root and deployed to GitHub Pages. See `research-site/README.md`.

```bash
# from pg_permissions/ (the scripts are in package.json there):
npm run docs:install            # npm ci in site/
npm run docs:dev                # local development server (syncs first)
npm run docs:build              # sync, build into site/dist, and validate
npm run docs:preview            # serve the built site
npm run docs:check:quickstart   # execute the quickstart in a temporary Postgres
# or from the repo root: make docs, make docs.dev
# or from pg_permissions/site/: npm run sync, npm run build, npm run check:quickstart
```

The site uses Astro 7, Starlight 0.42, and `starlight-links-validator`. Use the Node version required by the installed Astro release.

## Page inventory and navigation

`navigation.mjs` is the source of truth for source paths, routes, labels, and sidebar groups. Both `astro.config.mjs` and `scripts/sync.mjs` import it. Add new pages there and put their Markdown under `pg_permissions/docs/`. Research pages are listed in `../research/navigation.json` instead, which the research site reads.

Task guides cover setup and examples. Model guides share a structure while preserving each model's own concepts. The reference is organized by model, with current-subject helpers beside the other functions. Historical designs stay on the research site, separate from current application guidance.

Introduce the extension as an authorization store and check engine. The quickstart and application guides show direct checks first; RLS has its own optional sidebar group. Keep Cedar policies (authorization rules) distinct from Postgres RLS policies (table enforcement).

`content-migration.json` records where the original sections moved and the old inbound anchors. Compatibility pages retain old paths and headings, link to the current pages, and use `pagefind: false` so they do not compete with current guides in search. Keep these pages when adding or moving material; the extension's condition error hint still names `docs/conditions.md`.

## Blog

Blog posts live in `../blog/*.md` as a separate Astro content collection. They use the same header, theme and search as the docs, with a reading layout at `/blog/<filename>/`. The index at `/blog/`, RSS feed at `/blog/rss.xml`, and homepage's latest-post link update automatically.

Start a post with this frontmatter:

```yaml
---
title: A descriptive title
description: A short summary for the index, search and social previews.
date: 2026-11-02
author: Paul Copplestone
draft: true
---
```

Set `draft: false` when the post should appear in the built site. Drafts are excluded from article routes, the index, homepage, feed and Markdown exports. Dates are displayed in UTC so a publication day cannot shift with the build server's timezone. Published posts are sorted newest first.

Use site-relative Markdown links such as `/models/cedar/overview/`. `markdown-base-links.mjs` adds `DOCS_BASE` through Astro's Sätteri Markdown processor. Each post also has a portable Markdown version at `/blog/<filename>.md`, with absolute links and unchanged code blocks. Blog source files are never touched by the docs sync script.

`SitePageTitle.astro` supplies blog headings and metadata; other pages keep Starlight's standard title. The reading layout is in `styles/blog.css`. `DOCS_SITE` defaults to `https://permissions.dev` for canonical URLs, RSS and sitemap output; override it for another host.

## Generated files

| Path | Source | Tracked? |
| --- | --- | --- |
| `src/content/docs/**/*.md` | Canonical Markdown listed in `navigation.mjs` | No |
| Guide directories under `src/content/docs/` (`models`, `integrations`, `reference`, `rls`, `get-started`) | Generated `.md` or `.mdx` when a page uses tabs | No |
| `src/content/docs/index.mdx` | Hand-written site components | Yes |
| `public/markdown/**/*.md`, `public/llms.txt` | Plain Markdown exports and an agent index | No |

Every generated site page has a marker and an edit link to its canonical source. The sync step removes stale generated pages. New directories with generated MDX need an entry in `.gitignore`; keep hand-authored MDX outside those directories.

Adjacent fenced blocks with `tab="SQL"` and `tab="JavaScript"` become synchronized Starlight tabs. GitHub and plain Markdown exports retain both blocks. Do not hand-copy a second language version into another guide.

## Sync and deployment

Vercel builds the site from source with the Root Directory `pg_permissions` and the settings in `../vercel.json`. The built site and the generated pages are never committed. `npm run docs:publish` (from `pg_permissions/`) deploys by hand; the Git integration deploys on push to `main`.

Sync runs before development and build. It adds page metadata, rewrites relative links and exports plain Markdown. Links to code and other non-page files point to GitHub. Links to `../research` pages point to the research site: `research-links.mjs` maps each source to its route through `../research/navigation.json`, and `DOCS_RESEARCH_URL` (default `https://kiwicopple.github.io/pg-extensions`) sets the research site root. Blog links to the old `/research/<route>/` paths are rewritten the same way at build time. Missing targets produce a warning; resolve warnings before publishing.

Set `DOCS_REPO_URL` and `DOCS_REPO_REF` for source and edit links. The defaults are `kiwicopple/pg-extensions` and the `main` branch. Set `DOCS_SITE` to the deployment origin and `DOCS_BASE` when hosting below a path, for example `/pg-extensions`. Markdown and index links honor the same base.

The plain Markdown exports preserve the source code fences without tab markup. `llms.txt` lists canonical pages and their descriptions; compatibility pages are exported for old links but omitted from that index. The homepage links to the index. Historical records retain their status notes.

## Validation

`npm run build` checks rendered links and fragments, Markdown export links and code preservation, old inbound anchors, sidebar routes, and coverage of all 40 public SQL functions.

`npm run check:quickstart` runs the SQL fences directly from the quickstart in an isolated Postgres cluster. It verifies direct permission checks before any application table exists, then checks the optional RLS example and transaction-local identity. It needs Postgres binaries (`PGBIN` can select them). The existing usage specs cover the longer walkthroughs:

```bash
cd .. && ./test/run.sh usage
```

When moving a section, check its prerequisite data and the order of model or policy changes. Update the matching usage-spec comments. Keep intentional error examples separate from scripts that stop on errors.

## Link checking

`starlight-links-validator` checks absolute links and anchors. Synced pages use relative links, which that plugin skips, so `npm run build` finishes with `scripts/check-links.mjs`, which resolves every internal href and `#anchor` in `dist/` and fails the build on a broken one.
