# `pg_permissions`

A flexible authorization extension for Postgres: one schema that supports multiple permission models (RBAC, Zanzibar/FGA-style relationships, and later attribute rules), usable inside RLS policies. (Work in progress.)

- Source: https://github.com/kiwicopple/pg-extensions/tree/main/pg_permissions
- DbDev: https://database.dev/kiwicopple/pg_permissions (not yet published)

## Status

The extension file, [`pg_permissions--0.0.1.sql`](./pg_permissions--0.0.1.sql), is intentionally empty. The engine hasn't been chosen. Three candidate engines are built as prototypes in [`prototypes/`](./prototypes/), pass the same test suite (A 14/14 spec files, B 15/15, C 17/17) and have been benchmarked on identical data. They all expose the same simple `rbac` preset. [`DECISION.md`](./DECISION.md) lays out the trade-offs so one can be picked.

## Where to look

| File or directory | What it is |
| --- | --- |
| [`PLAN.md`](./PLAN.md) | Goals, requirements, the `rbac` preset API, evaluation criteria, and a summary comparison of the three designs |
| [`GOALS.md`](./GOALS.md) | Each goal as an executable spec, with pass counts per prototype and the performance budgets |
| [`DECISION.md`](./DECISION.md) | Decision guide: scorecard, when each engine wins, hybrids, open questions, what wasn't measured |
| [`bench/baselines/COMPARISON.md`](./bench/baselines/COMPARISON.md) | The measured numbers for all three engines (the source of truth for DECISION.md) |
| [`designs/`](./designs/) | One design doc per engine: [A tuple core](./designs/a-tuple-core.md), [B policy first](./designs/b-policy-first.md), [C compiled model](./designs/c-compiled-model.md) |
| [`prototypes/`](./prototypes/) | The three working implementations, as single SQL files |
| [`test/`](./test/) | The spec suite and runner; see [`test/README.md`](./test/README.md) |
| [`bench/`](./bench/) | The benchmark harness, budgets and saved baselines |
| [`JOURNAL.md`](./JOURNAL.md) | How the design and prototypes were built, including the dead ends |

## Development

The extension is built test-first. [GOALS.md](./GOALS.md) lists what it must do; each goal is a spec file in [`test/spec/`](./test/spec/). Everything runs on a throwaway Postgres started from your local binaries (Postgres.app is detected, or set `PGBIN`). Run from `pg_permissions/`:

```bash
# Tests (add -v to print every assertion)
./test/run.sh                                       # the extension (currently all red: the file is empty)
./test/run.sh --impl prototypes/a-tuple-core.sql    # Design A
./test/run.sh --impl prototypes/b-policy-first.sql  # Design B
./test/run.sh --impl prototypes/c-compiled-model.sql  # Design C

# Benchmarks (small is about 2.5 minutes; --scale medium|large, --shape deep|wide, --check for budgets)
./bench/run.sh --impl prototypes/a-tuple-core.sql --scale large
./bench/run.sh --impl prototypes/b-policy-first.sql --scale large
./bench/run.sh --impl prototypes/c-compiled-model.sql --scale large
```

From the repo root: `make test.pg_permissions` (and `IMPL=prototypes/a-tuple-core.sql make test.pg_permissions`). See [test/README.md](./test/README.md) for the test and benchmark details.

## Installation

Not available yet. Once published:

```bash
dbdev install kiwicopple-pg_permissions --connection <CONNECTION_STRING>
```

then:

```sql
create extension pg_permissions with schema extensions;
```
