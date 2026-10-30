# `pg_permissions`

A flexible authorization extension for Postgres: one schema that supports multiple permission models (RBAC, Zanzibar/FGA-style relationships, and later attribute rules), usable inside RLS policies. (Work in progress.)

- Source: https://github.com/kiwicopple/pg-extensions/tree/main/pg_permissions
- DbDev: https://database.dev/kiwicopple/pg_permissions (not yet published)

## Status

The extension file, [`pg_permissions--0.0.1.sql`](./pg_permissions--0.0.1.sql), is design D, chosen at the end of session 4: `rbac_*` tables for roles and scoped assignments, and `fga_*` tables that follow OpenFGA (JSON authorization models, tuples, Check, ListObjects, ListUsers, Read, Write, OpenFGA's error codes and default limits), one implicit store per database, all in schema `permissions`. It has OpenFGA's conditions too (CEL, compiled at model write and evaluated in PL/pgSQL: [`usage/conditions.md`](./usage/conditions.md)). It passes the whole suite (56 spec files, 3,638 assertions) on Postgres 16, 17 and 18 (Docker, with pg_tle), including OpenFGA's own consolidated test suite (933 stored and 746 contextual assertions), its ABAC (conditions) suite (302 stored and 271 contextual assertions, 9 cases with inline `$expression` conditions skipped) and openfga/language's model validation cases (70 run, 23 skipped with a reason). Every model-specific function carries its model's prefix (`rbac_has_permission`, `fga_check`); the three without one (`current_subject_id`, `current_subject_type`, `delete_subject`) are shared by both models, and every argument can be passed by name: `permissions.fga_check(subject => 'user:anne', relation => 'viewer', object => 'document:1')` (`subject` is OpenFGA's `user` field; `user` is reserved in SQL). How to use it: [`usage/`](./usage/README.md). The A, B and C designs stay in [`prototypes/`](./prototypes/) as measured history, selectable with `--impl`. [`DECISION.md`](./DECISION.md) records why D was chosen; [`PLAN.md`](./PLAN.md), "Next work (session 5 onward)", is the ordered work plan. D's numbers are in [`bench/baselines/D.md`](./bench/baselines/D.md); the comparison with A, B and C is in [`bench/baselines/OPTIMIZATIONS.md`](./bench/baselines/OPTIMIZATIONS.md) and [`bench/baselines/VERSIONS.md`](./bench/baselines/VERSIONS.md).

## Where to look

| File or directory | What it is |
| --- | --- |
| [`PLAN.md`](./PLAN.md) | Goals, requirements, the work plan from session 5 on, and (as history) the evaluation criteria and the comparison of the three designs |
| [`GOALS.md`](./GOALS.md) | Each goal as an executable spec, with pass counts per prototype and the performance budgets |
| [`DECISION.md`](./DECISION.md) | Why D is the engine: scorecard, when each engine wins, hybrids, the decisions at the end of session 4, open questions, what wasn't measured |
| [`bench/baselines/D.md`](./bench/baselines/D.md) | The extension's numbers (D, opt2) next to A, B and C |
| [`bench/baselines/OPTIMIZATIONS.md`](./bench/baselines/OPTIMIZATIONS.md) | A, B and C after the session 3 optimizations, before and after, on PG 16-18 |
| [`bench/baselines/VERSIONS.md`](./bench/baselines/VERSIONS.md) | The pre-optimization engines on PG 16, 17 and 18 in Docker, and the Docker versus local calibration |
| [`bench/baselines/COMPARISON.md`](./bench/baselines/COMPARISON.md) | The pre-optimization comparison of the three engines (local PG 16.4, all scales and shapes) |
| [`designs/`](./designs/) | One design doc per engine: [D per-model tables](./designs/d-per-model.md) (the extension), then [A tuple core](./designs/a-tuple-core.md), [B policy first](./designs/b-policy-first.md), [C compiled model](./designs/c-compiled-model.md) as history |
| [`pg_permissions--0.0.1.sql`](./pg_permissions--0.0.1.sql) | The extension (design D), a single SQL file |
| [`prototypes/`](./prototypes/) | The A, B and C implementations, as single SQL files (history) |
| [`test/`](./test/) | The spec suite and runner; see [`test/README.md`](./test/README.md) |
| [`bench/`](./bench/) | The benchmark harness, budgets and saved baselines |
| [`JOURNAL.md`](./JOURNAL.md) | How the design, the prototypes and the extension were built, including the dead ends |

## Development

The extension is built test-first. [GOALS.md](./GOALS.md) lists what it must do; each goal is a spec file in [`test/spec/`](./test/spec/). Everything runs on a throwaway Postgres started from your local binaries (Postgres.app is detected, or set `PGBIN`). Run from `pg_permissions/`:

```bash
# Tests (add -v to print every assertion)
./test/run.sh                                       # the extension (design D)
./test/run.sh --impl prototypes/a-tuple-core.sql    # Design A
./test/run.sh --impl prototypes/b-policy-first.sql  # Design B
./test/run.sh --impl prototypes/c-compiled-model.sql  # Design C

# Benchmarks (small is about 2.5 minutes; --scale medium|large, --shape deep|wide, --check for budgets)
./bench/run.sh --scale large                                      # the extension (design D)
./bench/run.sh --impl prototypes/a-tuple-core.sql --scale large
./bench/run.sh --impl prototypes/b-policy-first.sql --scale large
./bench/run.sh --impl prototypes/c-compiled-model.sql --scale large
```

From the repo root: `make test.pg_permissions` (and `IMPL=prototypes/a-tuple-core.sql make test.pg_permissions` for a prototype). See [test/README.md](./test/README.md) for the test and benchmark details.

## Installation

Not available yet. Once published:

```bash
dbdev install kiwicopple-pg_permissions --connection <CONNECTION_STRING>
```

then:

```sql
create extension pg_permissions with schema extensions;
```
