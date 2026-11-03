# Benchmarks

This page has the current benchmark numbers for `pg_permissions`. It shows how long the policy functions take on a table of 10 thousand to 1 million documents. Each release gets its own section. The newest release is first.

The numbers are measurements of one setup. They are not guarantees. Measure your own policies and data before you decide on a query shape. [Performance and query plans](rls/performance.md) explains how to write policies that stay fast.

## What the benchmark measures

The harness runs pgbench against a table with row level security (RLS). Each workload is one SQL statement or one write, run by 4 clients for 10 seconds. A workload is one of these:

- A check of one permission, such as `rbac_check` or `nest_check`.
- A page of documents or a count of documents that a user can read. The RLS policy calls a list function.
- A write, such as `write_share` or `write_assign_role`.
- For Cedar only, `row_select_page`. Its policy checks every row instead of listing the accessible IDs.

The scales are small (10,000 documents and 1,000 users), medium (100,000 documents and 5,000 users) and large (1,000,000 documents and 10,000 users). All models read the same data, and each run checks that the same users see the same documents.

Read the tables with these rules:

- Each value is p50 / p95 latency in milliseconds.
- Each configuration ran once. Treat differences under about 20% as noise.
- The budget is a limit for the p95. It is 3 times the p95 of the fastest design on that workload, rounded up to a whole millisecond. [`bench/budgets.tsv`](../bench/budgets.tsv) has all budgets and their history.

## Release 0.1.0

Release 0.1.0 has three models: RBAC and OpenFGA (called design D in the benchmark files) and Cedar (design E).

### Environment

- Postgres 18.6 in Docker, with pg_tle 1.5.3. The container has 4 CPUs and 6 GB of memory.
- 4 pgbench clients, 10 seconds for each workload, one run for each configuration, default data shape, one run at a time.
- RBAC and OpenFGA: reports `pg18-docker-d-{small,medium,large}-default-p6.md`, run on 2026-10-30 with the 0.0.1 file after the API rename (commit `f5a25a7`).
- Cedar: reports `pg18-docker-e-{small,medium}-default-p9.md` and `pg18-docker-e-large-default-p5.md`, run on 2026-11-02. The large scale was not run again after the p5 run. The p9 runs at small and medium scale were within the noise of p5, except for `row_select_page`. See [Cedar benchmark](../research/benchmarks/cedar.md#phase-9).
- All reports are in [`bench/baselines/`](../bench/baselines/).

These reports were made before the security and performance pass of 2026-11-03. The pass made some paths faster. [Changes after these runs](#changes-after-these-runs) lists the measured gain. No Docker run exists for the final 0.1.0 file yet.

### Latency at each scale

Source for all three tables: the reports named above. The budget column is the budget in [`bench/budgets.tsv`](../bench/budgets.tsv) today. The report of the large D run still shows the old 9 ms budget for `parents_proj_select_count`; the budget is now 20 ms for every design. See [the budget change](../research/benchmarks/D.md#the-large-parents_proj_select_count-budget-from-9-to-20-ms).

#### Small (10,000 documents)

| Workload | RBAC and OpenFGA | Cedar | Budget p95 | Met |
| --- | --- | --- | --- | --- |
| `rbac_check` | 0.20 / 0.29 | 0.30 / 0.52 | 1 | yes |
| `rbac_select_page` | 0.28 / 0.38 | 0.37 / 0.69 | 2 | yes |
| `rbac_select_count` | 0.24 / 0.33 | 0.32 / 0.61 | 2 | yes |
| `rbac_update_one` | 0.26 / 0.40 | 0.52 / 0.84 | 4 | yes |
| `write_assign_role` | 0.14 / 0.23 | 0.26 / 0.45 | 1 | yes |
| `share_list_objects` | 0.28 / 0.46 | 0.35 / 0.50 | 2 | yes |
| `share_select_page` | 0.39 / 0.54 | 0.56 / 0.90 | 5 | yes |
| `write_share` | 0.15 / 0.26 | 0.26 / 0.62 | 1 | yes |
| `parents_proj_select_page` | 0.46 / 0.88 | 0.67 / 1.15 | 2 | yes |
| `parents_proj_select_count` | 0.44 / 0.63 | 0.66 / 1.06 | 2 | yes |
| `parents_select_page` | 0.41 / 0.63 | 0.59 / 0.99 | 4 | yes |
| `parents_select_count` | 0.40 / 1.03 | 0.57 / 0.83 | 4 | yes |
| `write_nest_team` | 0.13 / 0.35 | 1.10 / 1.81 | 1 | Cedar: no |
| `nest_check` | 0.37 / 0.99 | 0.35 / 0.63 | 1 | yes |
| `row_select_page` | not available | 35.15 / 47.47 | 179 | yes |

#### Medium (100,000 documents)

| Workload | RBAC and OpenFGA | Cedar | Budget p95 | Met |
| --- | --- | --- | --- | --- |
| `rbac_check` | 0.15 / 0.38 | 0.31 / 0.47 | 1 | yes |
| `rbac_select_page` | 0.38 / 0.95 | 0.49 / 0.70 | 2 | yes |
| `rbac_select_count` | 0.30 / 0.45 | 0.40 / 0.61 | 2 | yes |
| `rbac_update_one` | 0.27 / 0.46 | 0.58 / 1.08 | 3 | yes |
| `write_assign_role` | 0.13 / 0.23 | 0.26 / 0.42 | 1 | yes |
| `share_list_objects` | 0.28 / 0.37 | 0.39 / 0.62 | 1 | yes |
| `share_select_page` | 0.57 / 1.18 | 0.79 / 1.30 | 3 | yes |
| `write_share` | 0.15 / 0.27 | 0.26 / 0.47 | 1 | yes |
| `parents_proj_select_page` | 0.64 / 0.84 | 0.93 / 1.61 | 3 | yes |
| `parents_proj_select_count` | 0.95 / 1.31 | 1.27 / 2.23 | 3 | yes |
| `parents_select_page` | 0.61 / 1.43 | 0.84 / 1.88 | 16 | yes |
| `parents_select_count` | 0.91 / 1.42 | 1.19 / 2.41 | 14 | yes |
| `write_nest_team` | 0.15 / 0.26 | 1.17 / 1.76 | 1 | Cedar: no |
| `nest_check` | 0.38 / 0.51 | 0.37 / 0.52 | 1 | yes |
| `row_select_page` | not available | 97.49 / 138.88 | 488 | yes |

#### Large (1,000,000 documents)

| Workload | RBAC and OpenFGA | Cedar | Budget p95 | Met |
| --- | --- | --- | --- | --- |
| `rbac_check` | 0.17 / 0.38 | 0.28 / 0.39 | 1 | yes |
| `rbac_select_page` | 0.72 / 2.06 | 0.75 / 1.08 | 3 | yes |
| `rbac_select_count` | 0.76 / 1.56 | 0.81 / 1.14 | 3 | yes |
| `rbac_update_one` | 0.24 / 0.54 | 0.48 / 0.73 | 3 | yes |
| `write_assign_role` | 0.12 / 0.27 | 0.25 / 0.38 | 1 | yes |
| `share_list_objects` | 0.27 / 0.62 | 0.44 / 0.82 | 2 | yes |
| `share_select_page` | 1.05 / 2.38 | 1.19 / 1.84 | 6 | yes |
| `write_share` | 0.14 / 0.33 | 0.25 / 0.42 | 1 | yes |
| `parents_proj_select_page` | 1.04 / 1.90 | 1.37 / 2.19 | 4 | yes |
| `parents_proj_select_count` | 7.89 / 13.25 | 8.64 / 10.57 | 20 | yes |
| `parents_select_page` | 1.05 / 6.99 | 1.42 / 9.00 | 32 | yes |
| `parents_select_count` | 7.76 / 13.26 | 8.85 / 17.38 | 70 | yes |
| `write_nest_team` | 0.15 / 0.29 | 1.17 / 1.70 | 1 | Cedar: no |
| `nest_check` | 0.38 / 0.66 | 0.40 / 0.63 | 2 | yes |
| `row_select_page` | not available | 225.47 / 312.52 | 938 | yes |

What the tables show:

- Pages and lists through a list function have a p50 under 1.5 ms at every scale, except the two counts at large scale. They read about 20,000 visible rows, and that costs 7.8 to 8.9 ms at p50 in both designs. This is a floor of the plan, not of the extension: every design in the benchmark, including the discarded prototypes, measured the same cost.
- Cedar is about 0.1 to 0.4 ms slower than RBAC and OpenFGA for most reads and writes (`write_nest_team` is the exception, below). It pays a fixed cost for each list, and the documents scale does not change it.
- Single checks cost about 0.3 to 0.4 ms in both designs.
- `write_nest_team` misses its 1 ms budget in Cedar at every scale (p95 1.70 to 1.81 ms). The workload changes the parent of one entity from all 4 clients, so the clients wait for each other's row locks. One write alone takes about 0.3 ms (local Postgres 16.4, one client). RBAC and OpenFGA have no miss at any scale. The budget stays at 1 ms.
- `row_select_page` is the expensive path. Its policy checks every row, until 50 rows are visible. That is about 500 checks at small scale and 2,600 at large scale. Use `cedar_list_resources_current` for reads when the policies are on stored entities. Keep the per-row check for policies on row attributes, writes and single rows.

### Conditions and non-monotone relations (OpenFGA)

OpenFGA workloads that have no Cedar counterpart. Source: `pg18-docker-d-{small,medium,large}-default-p6.md`. These workloads have no budget.

| Workload | Small | Medium | Large |
| --- | --- | --- | --- |
| `plain_list_objects` | 0.17 / 0.60 | 0.29 / 0.52 | 0.33 / 1.94 |
| `cond_list_objects` | 0.43 / 1.20 | 0.46 / 0.87 | 0.65 / 3.08 |
| `cond_select_page` | 0.61 / 1.68 | 0.85 / 2.19 | 1.51 / 8.47 |
| `cond_nest_check` | 0.58 / 1.63 | 0.57 / 1.29 | 0.56 / 1.24 |
| `plain_list_users` | 0.36 / 2.61 | 0.31 / 1.74 | 0.33 / 1.57 |
| `cond_list_users` | 0.59 / 3.49 | 0.46 / 2.13 | 0.52 / 2.36 |
| `block_list_objects` | 0.26 / 0.88 | 0.37 / 0.88 | 0.42 / 2.31 |
| `block_or_mute_list_objects` | 0.63 / 1.58 | 0.59 / 1.08 | 0.54 / 2.62 |
| `intersect_list_objects` | 0.35 / 1.01 | 0.41 / 1.10 | 0.49 / 2.68 |

### Seed time and storage

Seed time is the time to load the data through the native write functions, in seconds. Storage is the size of all tables in the `permissions` schema, including indexes, in MB after the phase. Both are at large scale. Sources: `pg18-docker-d-large-default-p6.md` and `pg18-docker-e-large-default-p5.md`.

| Phase | RBAC and OpenFGA: seconds, MB | Cedar: seconds, MB |
| --- | --- | --- |
| `rbac` | 4.39, 5.4 | 4.96, 7.5 |
| `sharing` | 1.04, 17.9 | 31.10, 197.1 |
| `parents` | 15.35, 323.7 | 32.56, 445.0 |

Cedar stores every document as an entity, because its list function returns stored entities only. OpenFGA stores only the tuples.

### Changes after these runs

On 2026-11-03 a performance pass and a security pass changed the shared helpers and the Cedar per-row path. These numbers come from local Postgres 16.4 (4 clients, p50 and p95 in ms), not from the Docker runs above. Source: [Cedar benchmark, performance pass](../research/benchmarks/cedar.md#performance-pass).

| Measurement (Postgres 16.4, local) | Before | After |
| --- | --- | --- |
| Cedar `row_select_page`, small (p50 / p95) | 35.5 / 45.7 | 27.5 / 39.4 |
| Cedar `row_select_page`, medium (p50 / p95) | 89.4 / 122.7 | 70.3 / 96.8 |
| `rbac_has_permission`, in server for each transaction | 21.8 µs | 12.1 µs |
| `fga_list_objects`, in server for each transaction | 125 µs | 90 µs |
| Cedar statement-level check with a conditional policy | 272 µs | 218 µs |

On Postgres 18 in Docker, the small `row_select_page` went from 34 to 25 ms in the server. The pgbench runs of the RBAC and OpenFGA models at small scale (p50, before and after) were: `share_select_page` 0.47 and 0.39 ms, `parents_proj_select_count` 0.50 and 0.40 ms, `parents_select_page` 0.46 and 0.38 ms, `block_list_objects` 0.39 and 0.34 ms.

The security hardening costs about 0.1 to 0.2 µs for each call, which is inside the noise. After the pass, `bench/run.sh --check` at small scale met 14 of 14 budgets for RBAC and OpenFGA. Cedar met every budget except the p95 of `write_nest_team`, as above.

### Reproduce

Run the commands from the `pg_permissions/` directory. The harness needs Postgres with pgbench, or Docker. The default `--impl` file is the current extension file, and the default design is the one that matches the file.

```sh
# RBAC and OpenFGA (design d), local Postgres, in a throwaway cluster
bench/run.sh --scale small --check
bench/run.sh --scale large --check

# Cedar (design e)
bench/run.sh --design e --scale small --check

# The Docker runs of this page: Postgres 18, one server at a time
docker/run-matrix.sh bench --versions 18 --designs d -- --scale large --tag p6 --check
docker/run-matrix.sh bench --versions 18 --designs e -- --scale large --tag p5
```

`--check` exits with code 1 if a p95 is over its budget. [Benchmark overview](../research/benchmarks/README.md) describes the options, the data shapes, the report names and the budgets. [Tests and benchmark harness](../test/README.md) describes the harness.

## History

These pages keep the full measurements, the methodology and the earlier designs. The numbers in them are not current unless a section above says so.

- [Benchmark overview](../research/benchmarks/README.md): how the reports are named, the harness options and the budgets.
- [Design D benchmarked](../research/benchmarks/D.md): the first measurement of RBAC and OpenFGA, the optimization passes, and the phase 6 runs on this page.
- [Design E: the Cedar model](../research/benchmarks/cedar.md): the Cedar runs, the comparison with D, and the performance pass.
- [Version measurements](../research/benchmarks/VERSIONS.md) and [optimization report](../research/benchmarks/OPTIMIZATIONS.md): the earlier prototypes on Postgres 16, 17 and 18.
- [Earlier engine comparison](../research/benchmarks/COMPARISON.md): the first comparison of the prototypes A, B and C, which were not shipped.
