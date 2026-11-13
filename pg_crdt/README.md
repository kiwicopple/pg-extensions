# pg_crdt

Counters and collaborative plain text in Postgres columns. Writers can change independent copies, then merge their updates without counting repeated deliveries twice.

The active extension provides `crdt.pn` counters and experimental `crdt.yseq` text columns. It is written in SQL and PL/pgSQL, supports Postgres 16, 17 and 18, and works with any driver or API layer. Your application owns the tables and permissions.

## Start here

1. [Install the extension](docs/install.md).
2. Try [your first counter](docs/get-started/quickstart.md) or [your first shared document](docs/get-started/text.md).
3. Follow the [documentation map](docs/README.md) for application integration, operations and reference.

## Know the limits

A counter cannot enforce a minimum or maximum while writers are disconnected. Its state grows with writer count.

Every text edit rewrites the whole CRDT value. WAL amplification, TOAST churn and retained deletion metadata make large or frequently edited documents expensive. Merge and sync scan the document, form saves carry the full base, and no packaged text-column client is provided. Read [Text-column limits and performance](docs/text/limits.md) before choosing this approach.

Table-backed documents (`ydoc_`) and their client remain [separate research](research/ydoc/README.md). We keep them separate to keep the active extension focused on column values. See the [decision and existing-installation guidance](research/scope.md). There is no automatic migration or upgrade script.

## Development

Run from this directory:

```sh
./test/run.sh
./test/docker.sh
npm run docs:install
npm run docs:build
npm run test:research
```

The research tests are separate from the active extension tests. See the [test guide](test/README.md) and [changelog](CHANGELOG.md).

Source: [kiwicopple/pg-extensions](https://github.com/kiwicopple/pg-extensions/tree/main/pg_crdt).
