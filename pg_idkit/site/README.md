# pg_idkit documentation site

This Astro + Starlight site follows `pg_validate/site`. Edit canonical Markdown in `../docs/` and `../STYLE.md`; edit page paths and sidebar groups in `navigation.mjs`. The landing page is maintained in `src/content/docs/index.mdx`.

From `pg_idkit/`:

```bash
npm run docs:install
npm run docs:dev
npm run docs:build
npm run docs:preview
```

The sync step generates site pages, plain Markdown exports and `public/llms.txt`. Generated output is ignored by Git. The build checks internal links and fragments, sidebar routes, unchanged SQL code in exports, and reference coverage for all five functions in 0.0.4. It does not execute SQL examples.

`DOCS_REPO_URL` and `DOCS_REPO_REF` customize source links; defaults are `kiwicopple/pg-extensions` and `main`. The production origin defaults to `https://id.postgres.tools` for canonical URLs, sitemaps and the Markdown index. `DOCS_SITE` overrides that origin and `DOCS_BASE` supports a subpath. For Vercel, choose `pg_idkit` as the root directory; `../vercel.json` supplies the build settings. Building locally does not publish the site.
