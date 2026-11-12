# pg_crdt documentation site

The Astro + Starlight site publishes the guides and reference for `pg_crdt`. Canonical prose lives in the parent directory, `pg_crdt/` (`../docs`, `../CHANGELOG.md`, `../STYLE.md`, `../test/README.md`). Edit those files, not the generated site pages. The site is adapted from `pg_validate/site`, with the language tabs of `pg_permissions/site`.

Research records (`../research`: the architecture, prior art, benchmarks, the build journal) are not on this site. They are published on the monorepo research site, built from `research-site/` at the repo root. See `research-site/README.md`. Links from the guides to `research/` files become absolute URLs on that site (`research-links.mjs` reads `../research/navigation.json`).

```bash
# from pg_crdt/ (the scripts are in package.json there):
npm run docs:install            # npm ci in site/
npm run docs:dev                # local development server (syncs first)
npm run docs:build              # sync, build into site/dist, and validate
npm run docs:preview            # serve the built site
# or from the repo root: make docs.pg_crdt, make docs.pg_crdt.dev
# or from pg_crdt/site/: npm run sync, npm run build
```

## The production URL

The production URL is `https://crdt.postgres.tools`, set in one constant, `DEFAULT_SITE`, in `astro.config.mjs`. It sets canonical URLs and the sitemap. If the domain changes, change it there, and change `userSite` in `../research/navigation.json` to the same value so that research pages link to the right place. A build can override it without a code change: set `DOCS_SITE` (and `DOCS_BASE` below a path).

## Page inventory and navigation

`navigation.mjs` is the source of truth for source paths, routes, labels and sidebar groups. Both `astro.config.mjs` and `scripts/sync.mjs` import it. Add new pages there and put their Markdown under `pg_crdt/docs/`. Research pages are listed in `../research/navigation.json` instead, which the research site reads.

## Code tabs

pg_crdt has no client library, so a task that an application does is shown twice: `tab="JavaScript"` (plain node-postgres) and `tab="SQL"`. In the source, two adjacent fenced blocks (only blank lines between them) with a `tab="..."` meta are one group. GitHub and the Markdown exports show every block in source order. On the site, `scripts/code-tabs.mjs` turns each group into `<Tabs syncKey="lang">`, so the reader's choice carries across pages, and the page is written as `.mdx` instead of `.md`. The converter requires at least two blocks per group, a plain language label, JavaScript first and SQL last.

## Generated files

| Path | Source | Tracked? |
| --- | --- | --- |
| Generated `.md` and `.mdx` under `src/content/docs/` | Canonical Markdown listed in `navigation.mjs`. Pages with language tabs generate MDX. | No |
| `src/content/docs/index.mdx` | Hand-written home page | Yes |
| `public/markdown/**/*.md`, `public/llms.txt` | Plain Markdown exports and an agent index | No |

Every generated page has a marker and an edit link to its canonical source. The sync step removes stale generated pages. Git ignores generated Markdown and MDX under `src/content/docs/`. The home page is the hand-authored exception.

## Sync and deployment

Vercel builds the site from source with the Root Directory `pg_crdt` and the settings in `../vercel.json`. The built site and the generated pages are never committed.

Sync rewrites relative links between pages to site routes; links to code and other files point to GitHub. Set `DOCS_REPO_URL` and `DOCS_REPO_REF` for source and edit links (defaults: `kiwicopple/pg-extensions`, `main`), `DOCS_SITE` for the deployment origin, `DOCS_BASE` when hosting below a path, and `DOCS_RESEARCH_URL` for the origin of the research site.

## Validation

`npm run build` checks rendered links and fragments (`scripts/check-links.mjs`), and `scripts/check-content.mjs` checks that:

- the Markdown exports keep their code, with the tab labels, and their links resolve;
- every rendered tab group has at least two tabs, JavaScript first, and matches the source;
- every sidebar route exists;
- every public function in `../pg_crdt--0.0.1.sql` has one reference entry (a `### \`name\`` heading in `docs/reference/shared.md`, `pn.md`, `yseq.md` or `ydoc.md`), and every SQLSTATE the file raises is in `docs/reference/errors.md`.

The SQL examples are not run by the build. Run the quickstart and the guides against a throwaway cluster after you change them: `pg_crdt/test/lib/cluster.sh` starts one.
