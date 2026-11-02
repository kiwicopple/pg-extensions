# Research

This section records the design decisions, experiments, and measurements behind `pg_permissions`. Start with [Current architecture](architecture.md) for the implementation in use. The earlier designs and completed plans remain here as historical evidence. The result of the research is the extension in [`../pg_permissions--0.0.1.sql`](../pg_permissions--0.0.1.sql). To use the extension, read the user docs in [`../docs/`](../docs/README.md).

## The problem

Four open RFC PRs in this repo each proposed a separate authorization extension: Zanzibar, ABAC, CEL and Cedar. Each one invented its own identity layer. Each one also invented its own way to say "subject is related to object". They all have the same RLS problem. A check that runs for each row in a policy is slow on a large table.

The project asked this question: can one Postgres extension express more than one authorization model? Then an app picks the model that fits. The app does not install a different extension for each model. [`plan.md`](./plan.md) has the full review of the RFCs and the requirements.

## The goals

The extension must meet these constraints:

- It is pure SQL and PL/pgSQL, and it installs as a Trusted Language Extension (`superuser = false`).
- Every check works inside RLS policies.
- It does not depend on Supabase. Nothing references the `auth` schema.

[`goals.md`](./goals.md) turns the requirements into 14 functional goals (G1 to G14). Each goal is a spec file, and a goal is met when its file passes. The page also lists the p95 budgets for each workload. The command `bench/run.sh --check` enforces the budgets.

## The four designs

Four SQL implementations were built and benchmarked.

| Design | Idea |
| --- | --- |
| A: tuple core | Zanzibar-style tuples in one generic table. A recursive walk decides at read time. |
| B: policy first | Cedar-style permit and forbid policies decide everything. The write precomputes closures of groups and roles. |
| C: compiled model | A JSON model compiles into lookup tables. Triggers materialize group memberships. |
| D: per-model tables | One set of tables for each model. `rbac_*` tables are first-class. `fga_*` tables follow OpenFGA, with CEL conditions. |

A, B and C put every model behind one generic API. D dropped that API. The prototype files of A, B and C are in [`../prototypes/`](../prototypes/), and they stay selectable with `--impl`. D is the extension file.

## How the designs were measured

Three kinds of measurement apply to the designs.

1. **The spec suite.** Each goal is a spec file in `test/spec/`. A, B and C pass the shared goals and their own specs. The counts are A 18 files and 199 assertions, B 18 and 189, C 21 and 229. The suite of the extension has 56 spec files and 3,638 assertions. It passes on PG 16, 17 and 18.
2. **The test suites of OpenFGA as oracles.** The author vendored the public tests of OpenFGA at a pinned commit and turned them into specs. D passes the consolidated suite (138 cases, 933 assertions with stored tuples and 746 with contextual tuples). It passes the ABAC suite for conditions (302 stored and 271 contextual assertions).

   It also passes 70 of the model validation cases of openfga/language. A skip list gives a reason for each case that does not run. The author never edited an upstream expectation.
3. **Benchmarks on PG 16, 17 and 18.** The benchmarks ran in Docker with pg_tle 1.5.3 and 4 pgbench clients, with one run for each configuration. Large scale is 1M documents, 10k users, 100 orgs and 500 teams. Medium scale is 100k documents, and small scale is 10k documents.

   Two stress shapes at medium scale have teams that nest 9 levels (deep) or 50 teams for each user (wide). A, B and C ran on 16.15, 17.11 and 18.6. D ran on 18.6 only. All designs return identical visible-document checksums for every read policy that the benchmark measured.

## Why D

The project chose the per-model implementation (D) on 2026-10-29 for these reasons:

- **One API forced different meanings.** The `rbac` preset was not fully identical across A, B and C. A forbid meant something different in each design.
- **The `rbac` preset is flat across designs.** Its p50 is under 1 ms, and it differs by about 0.1 ms between designs. The designs differ only on sharing shapes, and the optimizations there are specific to a model.
- **A public spec lets users and tools reuse what they know.** The project can also follow updates of the spec.
- **OpenFGA gives a test oracle and CEL conditions.** The public test suites of OpenFGA check D. The user chose OpenFGA, not SpiceDB, because of these suites and because of the conditions on tuples.
- **The models compose in RLS.** Permissive policies combine with OR, and restrictive policies combine with AND. An app that graduates adds the FGA model next to RBAC. It does not migrate off RBAC.

[`decision.md`](./decision.md) has the scorecard, the cases where each design wins and the decisions that the user made.

## Main results

- **The optimization pass changed the trade-offs of A, B and C.** The nest of a team in B went from 107 to 0.62 ms. The storage of B at large went from 763 to 378 MB. The nest in C went from 300 to 57.7 ms. A fix of plan-time evaluation cut the plan time of the wide sharing policy of A from 11.7-12.8 ms to 0.22 ms.
- **The RLS policy shape matters as much as the design.** At large, the single-branch parents policy costs 45.6 ms for A, 13.7 ms for B and 4.94 ms for C (page p50). The two-arm projection costs 1.33, 1.15 and 1.05 ms.
- **D is close to the best design on reads.** At medium and large, D is within 1.1 times the best of A, B and C. At small, it is within 1.0 to 1.4 times. D trails most on Check (0.37-0.38 ms against 0.25-0.34 ms).
- **D misses no budget at small or medium scale.** The large `--check` passes for D. Phase 6 changed one large budget from 9 to 20 ms for every design, because of a floor of heap reads.
- **A nest in D is one row.** `write_nest_team` is 0.13-0.15 ms at every scale. D has no lock, no closure and no materialized membership.
- **The single-branch policy of D costs the same as the projection.** The page p50 at large is 1.05 against 1.04 ms. D composes RBAC and FGA, and does not walk org roles.
- **Storage.** The parent links of D cost +305 MB at 1M documents (323.7 MB at large after the parents seed). A costs +385 MB, and B costs +357 MB.
- **A `but not` ListObjects was the worst hotspot.** It took 2.1 s for each call at first. The second performance pass cut it to 4.2 ms.
- **The covering index was not adopted.** It added 120 MB at large (323.7 to 444.1 MB). It gave no gain through pgbench (4.90 against 4.85 ms). It also flipped a plan, so that large `plain_list_users` went from 0.35 to 12.95 ms. The user decided on 2026-11-01 not to add it.

The full numbers are in the [benchmark pages](./benchmarks/README.md).

## What is not measured

[`decision.md`](./decision.md), "What is not measured", has the full list. The main open items are:

- an install through database.dev or on a hosted platform (pg_tle is tested only in Docker)
- real hardware and durability (one laptop, `fsync=off`, every write rolls back)
- reads under concurrent writes, and mixed read and write load
- D on PG 16 and 17
- repeat runs and confidence intervals (every number is from one run of 10 s)
- a user who sees most of 1M documents
- runtime role churn (`rbac_create_role` in a loop)

## The upstream OpenFGA report

The OpenFGA test suites showed a problem in OpenFGA v1.22.1. Check, ListObjects and ListUsers disagree for a relation like `[user] but not blocked`, when `blocked` is a userset that refers to itself in a cycle. In one shape, Check flips from `true` to `false` when the model gets an extra path that no tuple uses.

The author does not claim which answer is correct. The report says that the APIs do not agree with each other. The user reported it to the OpenFGA team. D uses the least fixpoint for positive recursion below an exclusion. If upstream decides differently, D changes again. See [`upstream/openfga-cycle-but-not-inconsistency.md`](./upstream/openfga-cycle-but-not-inconsistency.md).

## Index of research pages

| Page | What it has |
| --- | --- |
| [`plan.md`](./plan.md) | The requirements, the plan of session 4, and the six phases of work that made D the extension. |
| [`goals.md`](./goals.md) | The functional goals G1 to G14 as spec files, and the performance budgets. |
| [`decision.md`](./decision.md) | The decision guide: scorecard, decisions, open questions, what is not measured. |
| [`designs/a-tuple-core.md`](./designs/a-tuple-core.md) | Design A: shared tuple core. |
| [`designs/b-policy-first.md`](./designs/b-policy-first.md) | Design B: policy first. |
| [`designs/c-compiled-model.md`](./designs/c-compiled-model.md) | Design C: compiled model. |
| [`designs/d-per-model.md`](./designs/d-per-model.md) | Design D: per-model tables. This is the design record of the extension. |
| [`designs/d-conditions.md`](./designs/d-conditions.md) | Design D: OpenFGA conditions (CEL) in PL/pgSQL. |
| [`prototypes/README.md`](./prototypes/README.md) | The prototypes A, B and C as measured history. |
| [`prototypes/a-tuple-core.md`](./prototypes/a-tuple-core.md) | The usage guide of prototype A. |
| [`prototypes/b-policy-first.md`](./prototypes/b-policy-first.md) | The usage guide of prototype B. |
| [`prototypes/c-compiled-model.md`](./prototypes/c-compiled-model.md) | The usage guide of prototype C. |
| [`benchmarks/README.md`](./benchmarks/README.md) | The overview of the benchmark pages. |
| [`benchmarks/COMPARISON.md`](./benchmarks/COMPARISON.md) | A, B and C before the optimization (local Postgres 16.4). |
| [`benchmarks/OPTIMIZATIONS.md`](./benchmarks/OPTIMIZATIONS.md) | A, B and C after the session 3 optimizations (PG 16 to 18 in Docker). |
| [`benchmarks/VERSIONS.md`](./benchmarks/VERSIONS.md) | A, B and C on Postgres 16, 17 and 18 in Docker. |
| [`benchmarks/D.md`](./benchmarks/D.md) | Design D benchmarked, with the passes opt, opt2, opt3 and phase 6. |
| [`upstream/openfga-cycle-but-not-inconsistency.md`](./upstream/openfga-cycle-but-not-inconsistency.md) | The report to OpenFGA about the `but not` cycle problem. The script [`upstream/openfga-cycle-but-not-repro.sh`](./upstream/openfga-cycle-but-not-repro.sh) reproduces it. |
| [`journal.md`](./journal.md) | The raw build record. It keeps its original style and is not in simplified English. |

The per-run benchmark reports are in [`../bench/baselines/`](../bench/baselines/). The benchmark harness writes them, and they keep the format of the harness.
