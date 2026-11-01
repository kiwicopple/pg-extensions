# pg_permissions docs site

An [Astro](https://astro.build) + [Starlight](https://starlight.astro.build) site for the `pg_permissions` design docs, decision guide and benchmark results. The markdown stays in `../pg_permissions`; the site never holds a hand-copied duplicate.

```bash
make docs        # from the repo root: install if needed, build to docs/dist
make docs.dev    # dev server with hot reload (http://localhost:4321)
# or, inside docs/:
npm install
npm run dev      # sync, then dev server
npm run build    # sync, build, then check every internal link
npm run sync     # only copy docs and data
```

Node 20+ (developed on Node 23, npm 10). Stack: Astro 7, Starlight 0.42, `starlight-links-validator`; charts are hand-built SVG in Astro components (no chart library).

## What is generated and what is hand-written

| Path | Source | In git? |
| --- | --- | --- |
| `src/content/docs/**/*.md` | Copied from `../pg_permissions` by `scripts/sync.mjs` | No (gitignored). Never edit. |
| `src/data/bench/*.json` | Copied from `../pg_permissions/bench/baselines/data/*.json` | No (gitignored) |
| `src/data/workloads.generated.json` | First sentence of each workload SQL header | No (gitignored) |
| `src/content/docs/**/*.mdx`, `src/components`, `src/lib`, `src/styles` | Hand-written | Yes |
| `src/data/fixture/*.json` | Dev fixture, generated once from `bench/baselines/*.md` by `npm run fixture` | Yes |
| `src/data/workload-labels.json` | Human labels and groups for workload names | Yes |

Rule: synced pages are `.md`, hand-written pages are `.mdx`, and `src/content/docs/**/*.md` is gitignored. So "generated" is a file-type convention, and every generated page also carries a `GENERATED ... Do not edit` comment and an Edit-page link to its real source.

## Sync (`scripts/sync.mjs`)

Runs before `dev` and `build` (npm `predev` and `prebuild`). It:

1. Copies the user docs (`docs/*.md`), `test/README.md`, `STYLE.md` and everything under `research/` (plan, goals, decision guide, designs, prototype usage pages, benchmark reports, the OpenFGA report, the journal) to site routes (the `PAGES` table at the top of the script), adding Starlight frontmatter (`title` from the H1, `description` from the first paragraph, `editUrl`, sidebar label). The H1 is dropped because Starlight renders the title.
   A page whose source file is missing is skipped with a warning, and links to it render as plain code until it exists. The sidebar in `astro.config.mjs` lists pages by slug, so a route added to `PAGES` also needs a sidebar entry, and the other way round.
2. Rewrites relative links. Links between synced docs become relative site URLs (so the site works under any base path). Directories that have a site home (`docs/`, `test/`, `research/`, `research/prototypes/`, `research/benchmarks/`; the `DIR_ROUTES` table) go there; other files and directories link to GitHub (`DOCS_REPO_URL`, `DOCS_REPO_REF`, default `kiwicopple/pg-extensions` at `main`). A link to something that does not exist is shown as plain code with a warning. Fenced and inline code is never touched.
3. Copies run files, removing stale ones.
4. Extracts workload descriptions.

Set `DOCS_REPO_REF=<branch>` if the files are not on `main` yet, and `DOCS_SITE` / `DOCS_BASE` when deploying under a path (for example `DOCS_BASE=/pg-extensions`).

## Benchmark data

Pages read every run file with `import.meta.glob` (`src/lib/bench.ts`). Shape of a run file: see `src/lib/bench.ts` (`Run`): `run_id, date, environment, host, pg_version, design, scale, shape, clients, duration_s, workloads[], seeds[], checksums{}`.

- **Real data wins.** If `src/data/bench/` has any file, only real data is used. Otherwise the fixture in `src/data/fixture/` is used and the pages say so.
- **Tags.** A run's `tag` (JSON field, else the run_id suffix after the fifth dash) names a variant of the engines, e.g. `opt` for the session 3 optimized engines. Tagged and untagged runs of one configuration are different series; a tagged run never replaces an untagged one.
- A **series** is one Postgres major version on one environment with one tag (for example "PG 18 (docker, optimized)" or "PG 16 (local)"). `allSeries` in `src/lib/bench.ts` groups by environment, major and tag.
- **Primary series** (dashboard, home page): set by `PRIMARY_PREFERENCE` in `src/lib/bench.ts`. It is Docker PG 18 `opt` if that exists, else the newest Docker series, else the newest local series. It is never chosen by run count. Charts that need scales Docker lacks (scaling from 10k to 1M) use `scalingSeries()` (today local PG 16) and say so in their subtitle; no chart mixes environments or tags.
- The **Postgres versions** page compares only series with the same environment and tag: optimized Docker first, then pre-optimization Docker.
- The **Optimizations** page (`src/lib/optimizations.ts`, `src/components/opt`) pairs the untagged and `opt` Docker series per Postgres version (main version 18): dumbbell charts (hollow dot before, filled dot after, log axis), a ranking table (engines within 20% of the best are tied) and takeaways computed from the numbers.
- Takeaways under each chart are computed from the data at build time, so they stay true when numbers change.
- A malformed file is skipped with a warning, not a build failure.

## Charts

Build-time SVG from Astro components in `src/components/viz` (no client-side chart library). The only client JS is a small script for the tooltip and the scale/shape tabs; without it every value is still in the SVG labels, the `Table view` under each chart and, for tabs, all panels are shown. Colors follow the dataviz skill: one fixed color per engine (A blue, B orange, C aqua, categorical slots 1 to 3, validated for color-blind separation in light and dark), thin marks, a legend plus direct labels, light/dark via Starlight's theme attribute (`src/styles/viz.css`).

## Link checking

`starlight-links-validator` checks absolute links and anchors. Synced pages use relative links, which that plugin skips, so `npm run build` finishes with `scripts/check-links.mjs`, which resolves every internal href and `#anchor` in `dist/` and fails the build on a broken one.
