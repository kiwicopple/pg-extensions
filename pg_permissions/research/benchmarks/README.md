# Benchmarks

This folder has the written summaries of the benchmarks of `pg_permissions`. The benchmarks compare four designs: A (tuple core), B (policy first), C (compiled model) and D (per-model tables). D is the extension. The [decision guide](../decision.md) explains why D won.

This page tells you four things. It says what each summary contains. It says how the generated reports are named. It says how to run the benchmark harness. It says where the budgets are.

## The summaries

Read the summaries in this order:

| File | Contents |
| --- | --- |
| [`COMPARISON.md`](./COMPARISON.md) | The first comparison of A, B and C on local Postgres 16.4. It covers the small, medium and large scales and the default, deep and wide shapes. It has latency tables, seed time and storage tables, checksums, the trade-offs between the designs and the budget misses. |
| [`VERSIONS.md`](./VERSIONS.md) | A, B and C on Postgres 16.15, 17.11 and 18.6 in Docker, before the optimizations of session 3. It shows what changes with the Postgres version. It also compares Docker runs with local runs (Calibration). |
| [`OPTIMIZATIONS.md`](./OPTIMIZATIONS.md) | The same Docker matrix after the optimizations of session 3. It checks the claims of the design documents. It has before and after tables, the changes in the ranking of the designs, and the budgets. |
| [`D.md`](./D.md) | Design D, the extension. It has the first measurement and the diagnosis of D. It also has the second and third optimization passes (opt2 and opt3), the phase 6 runs at small, medium and large scale, and the change of the large `parents_proj_select_count` budget. |
| [`cedar.md`](./cedar.md) | Design E, the extension's Cedar model (`cedar_*`), on the same data, compared with D's FGA and RBAC on the equivalent workloads, and the per-row check that only Cedar has. |

Each run is one run for each configuration. Treat differences under about 20% as noise.

## The generated reports

`bench/run.sh` writes one markdown report for each run. The reports are in [`../../bench/baselines/`](../../bench/baselines/). The harness generates them, so do not edit them. A report has the latency table (p50 and p95) and the plans. It also has the seed time and the table sizes after each phase, and the checksums of the documents that the sample users see.

The name of a report shows the run. The values are these. `<design>` is `a`, `b`, `c`, `d` or `e` (the Cedar model of the extension, `bench/run.sh --design e`). `<scale>` is `small` (10k documents), `medium` (100k) or `large` (1M). `<shape>` is `default`, `deep` or `wide`. `<NN>` is the Postgres major version (16, 17 or 18).

| Name | Run |
| --- | --- |
| `<design>-<scale>-<shape>.md` | A run on local Postgres 16.4, in a throwaway cluster on the host. Example: `a-large-default.md`. |
| `pg<NN>-docker-<design>-<scale>-<shape>.md` | A run in Docker on Postgres `<NN>`. Example: `pg18-docker-c-medium-wide.md`. |
| `<name>-<tag>.md` | A run with the tag that `--tag` sets. A tagged run and an untagged run of the same configuration are different series. |
| `a-large-default-session1.md` | The first run of A, before the shared data shape. It is history only. |

These tags exist:

- `opt`: the designs after the optimizations of session 3. The runs of D with this tag are the first measurement of D.
- `opt2` and `opt3`: design D after its second and third optimization pass.
- `opt3-before`: design D before the third pass, measured again.
- `opt3-covering`: design D with the covering index.
- `p6`: the runs of phase 6 at small, medium and large scale.
- `p6check`: the `--check` run of phase 6 at large scale.
- `p5`: design E, Cedar phase 5 ([`cedar.md`](./cedar.md)).

The JSON data of the runs is in [`../../bench/baselines/data/`](../../bench/baselines/data/). The [README of that folder](../../bench/baselines/data/README.md) describes the fields. The docs site makes its charts from these JSON files.

## Run the harness

Run the commands from the `pg_permissions/` directory. The first command runs the extension (design d) at small scale, with 10 s for each workload:

```sh
bench/run.sh
bench/run.sh --scale large
bench/run.sh --impl prototypes/a-tuple-core.sql                       # a prototype, for comparison
bench/run.sh --impl prototypes/a-tuple-core.sql --shape wide --scale medium
bench/run.sh --only parents,write_nest_team                           # run some workloads again
bench/run.sh --check                                                  # exit 1 if a p95 is over budget
```

The options are these:

| Option | Meaning |
| --- | --- |
| `--scale small\|medium\|large` | 10k, 100k or 1M documents. The default is `small`. |
| `--shape default\|deep\|wide` | The team graph. The default is `default`. In `deep`, the teams are in chains 9 deep and the users are in the leaf teams. In `wide`, there are 4 times the teams, each user is in 50 teams, and each team has 50 documents. |
| `--duration SECONDS` | The time for each workload. The default is 10. |
| `--clients N` | The number of pgbench clients. The default is 4. |
| `--only NAME[,NAME...]` | Run only the workloads whose name contains one of these words. The harness does not seed the phases after the last selected workload. |
| `--impl FILE` | The implementation to install. The default is `pg_permissions--0.0.1.sql`. |
| `--design a\|b\|c\|d\|none` | The design. The default is the letter before the first dash of the `--impl` file name (`d` for the extension file, `none` for any other file). |
| `--external` | Use the server from `PGHOST`, `PGPORT` and `PGUSER`. |
| `--tag NAME` | Add a tag to the `run_id` of the JSON file. |
| `--check` | Exit 1 if a p95 is over its budget or a workload fails. A workload without a budget never fails. |

The harness seeds and measures in seven phases: `rbac`, `sharing`, `parents_proj`, `parents`, `nesting`, `conditions` and `blocklist`. Only design d has the phases `conditions` and `blocklist`. All designs read the same data from the shape tables (`bench/seed_shape.sql`), so the data is identical. Each seed is followed by `VACUUM FULL ANALYZE` of the non-empty tables.

A complete run prints the report as a markdown table. It saves the report in `bench/results/` (git-ignored). It also writes the JSON file in `bench/baselines/data/`. To keep a report in the repository, copy it to `bench/baselines/`.

To run on Postgres 16, 17 and 18 in Docker, use `docker/run-matrix.sh`. It runs one server at a time. Pass the options of `bench/run.sh` after `--`. The [Docker README](../../docker/README.md) has more detail.

```sh
docker/run-matrix.sh bench -- --scale large
docker/run-matrix.sh bench --versions 18 --designs d -- --scale medium --shape wide --tag opt --check
```

## The budgets

The p95 budgets are in [`../../bench/budgets.tsv`](../../bench/budgets.tsv). The file has one line for each scale and workload. The stress shapes have their own keys, `medium-deep` and `medium-wide`. The header of the file gives the rule and the reason for each change.

The rule is: 3 times the p95 of the fastest design on the workload, rounded up to a whole ms, with at least 1 ms. `--check` compares the p95 of each workload with its budget. Phase 6 changed the large `parents_proj_select_count` budget from 9 to 20 ms for every design. [`D.md`](./D.md) explains the change.

## The dashboards on the docs site

The docs site has three pages with charts of these results. Each page draws its charts at build time from the JSON files. Each chart has a table view.

- [Benchmarks dashboard](../../../research-site/src/content/docs/pg_permissions/benchmarks/dashboard.mdx) (route `research/benchmarks/dashboard`): latency, scaling, shapes, read against write, parents, and seed time and storage.
- [Optimizations](../../../research-site/src/content/docs/pg_permissions/benchmarks/optimizations.mdx) (route `research/benchmarks/optimizations`): the runs before and after the optimizations of session 3, for each design.
- [Postgres versions](../../../research-site/src/content/docs/pg_permissions/benchmarks/postgres-versions.mdx) (route `research/benchmarks/postgres-versions`): Postgres 16, 17 and 18 side by side.
