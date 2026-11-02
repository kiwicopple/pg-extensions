# Design E: the Cedar model on the benchmark

Design E is the extension's Cedar model (`cedar_*`, [`research/designs/e-cedar.md`](../designs/e-cedar.md)), measured by Cedar phase 5. It runs the same harness on the same data as A to D: `bench/run.sh --design e` with the extension file. The seeds in [`bench/designs/e/`](../../bench/designs/e/) write the facts of `bench/seed_shape.sql` as Cedar entities and template links. This page compares E with D, the extension's RBAC (`rbac_*`) and FGA (`fga_*`) models, on the workloads that both have, and reports the per-row check, which only E has.

## The runs

| Design | Reports | Date | Server |
| --- | --- | --- | --- |
| E (Cedar) | [`pg18-docker-e-{small,medium,large}-default-p5.md`](../../bench/baselines/) | 2026-11-02 | Postgres 18.6, Docker (`docker/run-matrix.sh bench --versions 18 --designs e -- --scale <scale> --tag p5`) |
| D (RBAC and FGA) | [`pg18-docker-d-{small,medium,large}-default-p6.md`](../../bench/baselines/) | 2026-10-30 | the same image and container limits (4 CPUs, 6 GB) |

Each configuration ran once, serially, 10 s per workload with 4 clients. Treat differences under about 20% as noise. The runs of the two designs are three days apart; the image, the limits and the data are the same. Other containers on the host were idle.

**Equivalence.** At every scale, E's checksums equal those of A, B, C and D for every phase (`rbac`, `sharing`, `parents_proj` and `parents`): the same users see the same documents. The per-row phase (`rowcheck`) equals the parents phase within each run.

## How E expresses each scenario

| Phase | D | E |
| --- | --- | --- |
| rbac | roles assigned in an org; the select policy lists the orgs (`rbac_scopes_with_permission`), the update policy checks per row | each user is in `Role::"<org>/<role>"` (admin in editor in viewer); two templates, `org_read` and `org_edit`, linked once per org (`principal in Role, resource in Org`); the select policy lists the orgs (`cedar_list_resources_current(..., 'Org')`), the update policy checks the org per row |
| sharing | FGA tuples: users in teams, nested teams, team grants, direct editors | teams as entities with their parent team, users with their roles and teams; every document stored as an entity; one link per team grant (`share_read`, `principal in ?principal`) and per direct grant (`share_edit`, view and edit) |
| parents_proj | folder viewer tuples, two lists | `Folder` entities; one link per folder viewer (`folder_read`, `resource in ?resource`); a list of documents and a list of folders |
| parents | a parent tuple per document | every document put again with its folder as its parent; one list |
| nesting | one tuple nests the team | `Team::"nest-src"` put again with a parent team: a re-parent of one entity |
| rowcheck (E only) | none | one select policy that calls `cedar_is_authorized_current` on every row, with the row's org as a resource attribute (`principal in resource.readers`) |

## Latency (ms)

p50 / p95. Budgets are those of [`bench/budgets.tsv`](../../bench/budgets.tsv); E uses the same workload names, so the same rows apply.

### Small (10k documents, 1k users)

| Workload | D | E (Cedar) | Budget p95 |
| --- | --- | --- | --- |
| rbac_check | 0.20 / 0.29 | 0.29 / 0.50 | 1 |
| rbac_select_page | 0.28 / 0.38 | 0.36 / 0.68 | 2 |
| rbac_select_count | 0.24 / 0.33 | 0.32 / 0.51 | 2 |
| rbac_update_one | 0.26 / 0.40 | 0.48 / 0.79 | 4 |
| write_assign_role | 0.14 / 0.23 | 0.25 / 0.43 | 1 |
| share_list_objects | 0.28 / 0.46 | 0.36 / 0.57 | 2 |
| share_select_page | 0.39 / 0.54 | 0.56 / 0.91 | 5 |
| write_share | 0.15 / 0.26 | 0.25 / 0.53 | 1 |
| parents_proj_select_page | 0.46 / 0.88 | 0.68 / 1.06 | 2 |
| parents_proj_select_count | 0.44 / 0.63 | 0.65 / 0.94 | 2 |
| parents_select_page | 0.41 / 0.63 | 0.58 / 0.93 | 4 |
| parents_select_count | 0.40 / 1.03 | 0.57 / 0.97 | 4 |
| write_nest_team | 0.13 / 0.35 | 1.03 / **1.53** | 1 |
| nest_check | 0.37 / 0.99 | 0.34 / 0.58 | 1 |
| row_select_page | none | 39.91 / 59.57 | 179 |

### Medium (100k documents, 5k users)

| Workload | D | E (Cedar) | Budget p95 |
| --- | --- | --- | --- |
| rbac_check | 0.15 / 0.38 | 0.31 / 0.52 | 1 |
| rbac_select_page | 0.38 / 0.95 | 0.50 / 0.85 | 2 |
| rbac_select_count | 0.30 / 0.45 | 0.45 / 0.63 | 2 |
| rbac_update_one | 0.27 / 0.46 | 0.56 / 0.78 | 3 |
| write_assign_role | 0.13 / 0.23 | 0.25 / 0.34 | 1 |
| share_list_objects | 0.28 / 0.37 | 0.39 / 0.52 | 1 |
| share_select_page | 0.57 / 1.18 | 0.78 / 1.05 | 3 |
| write_share | 0.15 / 0.27 | 0.25 / 0.42 | 1 |
| parents_proj_select_page | 0.64 / 0.84 | 0.94 / 1.44 | 3 |
| parents_proj_select_count | 0.95 / 1.31 | 1.32 / 1.89 | 3 |
| parents_select_page | 0.61 / 1.43 | 0.86 / 1.94 | 16 |
| parents_select_count | 0.91 / 1.42 | 1.26 / 2.24 | 14 |
| write_nest_team | 0.15 / 0.26 | 1.16 / **1.72** | 1 |
| nest_check | 0.38 / 0.51 | 0.36 / 0.51 | 1 |
| row_select_page | none | 107.81 / 162.43 | 488 |

### Large (1M documents, 10k users)

| Workload | D | E (Cedar) | Budget p95 |
| --- | --- | --- | --- |
| rbac_check | 0.17 / 0.38 | 0.28 / 0.39 | 1 |
| rbac_select_page | 0.72 / 2.06 | 0.75 / 1.08 | 3 |
| rbac_select_count | 0.76 / 1.56 | 0.81 / 1.14 | 3 |
| rbac_update_one | 0.24 / 0.54 | 0.48 / 0.73 | 3 |
| write_assign_role | 0.12 / 0.27 | 0.25 / 0.38 | 1 |
| share_list_objects | 0.27 / 0.62 | 0.44 / 0.82 | 2 |
| share_select_page | 1.05 / 2.38 | 1.19 / 1.84 | 6 |
| write_share | 0.14 / 0.33 | 0.25 / 0.42 | 1 |
| parents_proj_select_page | 1.04 / 1.90 | 1.37 / 2.19 | 4 |
| parents_proj_select_count | 7.89 / 13.25 | 8.64 / 10.57 | 20 |
| parents_select_page | 1.05 / 6.99 | 1.42 / 9.00 | 32 |
| parents_select_count | 7.76 / 13.26 | 8.85 / 17.38 | 70 |
| write_nest_team | 0.15 / 0.29 | 1.17 / **1.70** | 1 |
| nest_check | 0.38 / 0.66 | 0.40 / 0.63 | 2 |
| row_select_page | none | 225.47 / 312.52 | 938 |

## What the numbers say

- **Reads through lists are close to D.** The pages and lists that go through `cedar_list_resources_current` (an InitPlan, once per statement) are within about 0.1 to 0.4 ms of D at p50. The two counts at large scale, which read about 20,000 visible rows, are 0.8 to 1.1 ms slower at p50. Every one is inside its budget at every scale. Cedar pays a fixed cost per list: the principal's walk, the candidate policies from the scope index, and then the uids or the walk of `in X`. The documents scale does not change it, because candidates come from the policies, not from the table.
- **Single checks cost about the same as D's.** `rbac_check` and `nest_check` are 0.3 to 0.4 ms at p50 in both designs. `rbac_update_one` costs about 0.2 to 0.3 ms more than D's: the row's check is answered from the statement's cached part (a link without conditions names the org, and no forbid applies), but the first call computes that part, and the update also runs the select policy's org list.
- **Writes cost about 0.1 ms more.** `cedar_put_entities` validates entity JSON, upserts the entity and its parents, and fires the statement-level triggers that end the per-statement caches; `cedar_link_template` compiles the link's scope. Both stay at 0.25 ms p50.
- **The per-row path is the expensive one.** `row_select_page` reads documents in id order and checks each one until 50 are visible: about 500 checks at small scale, 2,600 at large (a user sees 2% of the documents there). Every row is in the scope of `org_readers` (`resource is Document` with a condition), so every row parses the statement's cached part and evaluates the condition; rows in a linked folder also walk to the folder. That is about 80 µs a row on Docker (60 µs on the laptop, PG 16.4). A list view should use `cedar_list_resources_current` when its policies are on stored entities, and keep the per-row helper for policies on row attributes, writes and single rows. A policy that cannot name a row in its scope costs about 4 µs a row: the row is denied from the cached part without a query (e-cedar.md section 15.2).
- **Storage.** E stores every document as an entity, because the list returns stored entities only (plan-cedar.md, decision 3), and at the parents phase every document's parent. At large scale the permission tables are 445 MB against D's 324 MB, and the sharing seed takes 31 s against 1 s (1M entities put in calls of 10,000). D's FGA stores only the tuples.

| Seed, large | D: s, MB | E: s, MB |
| --- | --- | --- |
| rbac | 4.4, 5.4 | 5.0, 7.5 |
| sharing | 1.0, 17.9 | 31.1, 197.1 |
| parents | 15.4, 323.7 | 32.6, 445.0 |

## Budgets

E reuses the budget rows of the workloads it shares with A to D; they follow the rule of `bench/budgets.tsv` (3x the fastest reference p95), and none was loosened. The new rows are for `row_select_page`, which no other engine has: 3x E's own p95, as the only reference (179, 488 and 938 ms).

**Miss: `write_nest_team`, at every scale (p95 1.5 to 1.8 ms against 1 ms).** The workload nests the same team in a random team in every transaction, which in Cedar is a re-parent of one entity, `Team::"nest-src"`. Each transaction upserts that entity's row and replaces its parent rows, so the 4 clients wait for each other's row locks until the rollback. With one client the same write takes 0.31 ms p50 and 0.41 ms p95 (local, small); with four, throughput barely rises (3,036 to 3,392 tps) while p95 grows. D writes a new tuple each time and never waits. The cost of one write is in budget; the contention comes from the workload writing one row from every client. The budget stays at 1 ms.

Two misses of the first runs were fixed before these runs (e-cedar.md section 15.3): the org list at medium and large scale (a hashed subplan over every stored entity), and the document list at large scale on Postgres 18 (JIT compiling a generic plan on every call, 10 ms). The intermediate reports were not kept.

## For later phases

- The docs site reads `bench/baselines/data/` and accepts designs `a` to `d` only (`site/src/lib/bench.ts`, `DESIGNS`), so it skips the three E files with a warning until phase 8 adds `e`.
- Check the other `_current` helpers on a server with JIT (section 15.3 of the design doc).
