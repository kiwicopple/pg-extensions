# pg_validate documentation site

The Astro + Starlight site publishes the guides and reference for `pg_validate`. Canonical prose lives in the parent directory, `pg_validate/` (`../docs`, `../STYLE.md`, `../test/README.md`). Edit those files, not the generated site pages. The site is adapted from `pg_permissions/site`, without its benchmark charts.

```bash
# from pg_validate/ (the scripts are in package.json there):
npm run docs:install            # npm ci in site/
npm run docs:dev                # local development server (syncs first)
npm run docs:build              # sync, build into site/dist, and validate
npm run docs:preview            # serve the built site
# or from pg_validate/site/: npm run sync, npm run build
```

## Page inventory and navigation

`navigation.mjs` is the source of truth for source paths, routes, labels and sidebar groups. Both `astro.config.mjs` and `scripts/sync.mjs` import it. Add new pages there and put their Markdown under `pg_validate/docs/`.

## Generated files

| Path | Source | Tracked? |
| --- | --- | --- |
| `src/content/docs/**/*.md` and the guide directories | Canonical Markdown listed in `navigation.mjs` | No |
| `src/content/docs/index.mdx` | Hand-written home page | Yes |
| `public/markdown/**/*.md`, `public/llms.txt` | Plain Markdown exports and an agent index | No |

Every generated page has a marker and an edit link to its canonical source. The sync step removes stale generated pages. A new directory of generated pages needs an entry in `.gitignore`.

## Sync and deployment

Vercel builds the site from source with the Root Directory `pg_validate` and the settings in `../vercel.json`. The built site and the generated pages are never committed.

Sync rewrites relative links between pages to site routes; links to code and other files point to GitHub. Set `DOCS_REPO_URL` and `DOCS_REPO_REF` for source and edit links (defaults: `kiwicopple/pg-extensions`, `main`), `DOCS_SITE` for the deployment origin and `DOCS_BASE` when hosting below a path.

## Validation

`npm run build` checks rendered links and fragments (`scripts/check-links.mjs`), and that the Markdown exports keep their code, every sidebar route exists, and every built-in validator has a reference entry with "Guarantees" and "Does not guarantee" sections (`scripts/check-content.mjs`). The SQL examples are checked by the test suite (`test/spec/90_usage_quickstart.sql`, `91_usage_registry.sql`).
