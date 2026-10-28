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

1. Copies README, PLAN, GOALS, DECISION, JOURNAL, `designs/*`, `prototypes/README`, `test/README` and `bench/baselines/COMPARISON.md` to site routes (the table at the top of the script), adding Starlight frontmatter (`title` from the H1, `description` from the first paragraph, `editUrl`, sidebar label). The H1 is dropped because Starlight renders the title.
2. Rewrites relative links. Links between synced docs become relative site URLs (so the site works under any base path). Directories that have a site home (`prototypes/`, `test/`) go there; other files and directories link to GitHub (`DOCS_REPO_URL`, `DOCS_REPO_REF`, default `kiwicopple/pg-extensions` at `main`). A link to something that does not exist is shown as plain code with a warning. Fenced and inline code is never touched.
3. Copies run files, removing stale ones.
4. Extracts workload descriptions.

Set `DOCS_REPO_REF=<branch>` if the files are not on `main` yet, and `DOCS_SITE` / `DOCS_BASE` when deploying under a path (for example `DOCS_BASE=/pg-extensions`).

## Benchmark data

Pages read every run file with `import.meta.glob` (`src/lib/bench.ts`). Shape of a run file: see `src/lib/bench.ts` (`Run`): `run_id, date, environment, host, pg_version, design, scale, shape, clients, duration_s, workloads[], seeds[], checksums{}`.

- **Real data wins.** If `src/data/bench/` has any file, only real data is used. Otherwise the fixture in `src/data/fixture/` is used and the pages say so.
- A **series** is one Postgres major version on one environment (for example "PG 16 (local)"). The dashboard shows the series with the most runs, the latest run per engine, scale and shape. The Postgres versions page shows all series and says which versions exist.
- Takeaways under each chart are computed from the data at build time, so they stay true when numbers change.
- A malformed file is skipped with a warning, not a build failure.

## Charts

Build-time SVG from Astro components in `src/components/viz` (no client-side chart library). The only client JS is a small script for the tooltip and the scale/shape tabs; without it every value is still in the SVG labels, the `Table view` under each chart and, for tabs, all panels are shown. Colors follow the dataviz skill: one fixed color per engine (A blue, B orange, C aqua, categorical slots 1 to 3, validated for color-blind separation in light and dark), thin marks, a legend plus direct labels, light/dark via Starlight's theme attribute (`src/styles/viz.css`).

## Link checking

`starlight-links-validator` checks absolute links and anchors. Synced pages use relative links, which that plugin skips, so `npm run build` finishes with `scripts/check-links.mjs`, which resolves every internal href and `#anchor` in `dist/` and fails the build on a broken one.
