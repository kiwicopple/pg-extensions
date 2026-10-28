# `pg_permissions`

A flexible authorization extension for Postgres: one schema that supports multiple permission models (RBAC, Zanzibar/FGA-style relationships, and later attribute rules), usable inside RLS policies. (Work in progress.)

- Source: https://github.com/kiwicopple/pg-extensions/tree/main/pg_permissions
- DbDev: https://database.dev/kiwicopple/pg_permissions (not yet published)

## Plan

See [PLAN.md](./PLAN.md) for the goals, requirements and a comparison of three candidate designs in [`designs/`](./designs/): a shared tuple core, policy-first, and a compiled model.

## Development

The extension is built test-first. [GOALS.md](./GOALS.md) lists what it must do; each goal is a spec file in [`test/spec/`](./test/spec/).

```bash
./test/run.sh                                     # run the suite against the extension
./test/run.sh --impl prototypes/a-tuple-core.sql  # or against a prototype
./bench/run.sh --impl prototypes/a-tuple-core.sql --scale large --check
```

See [test/README.md](./test/README.md) for details.

[JOURNAL.md](./JOURNAL.md) logs how the design and prototypes were built, including the dead ends.

## Installation

```bash
dbdev install kiwicopple-pg_permissions --connection <CONNECTION_STRING>
```

then:

```sql
create extension pg_permissions with schema extensions;
```
