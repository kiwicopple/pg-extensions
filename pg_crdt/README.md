# pg_crdt

Counters and shared plain text in Postgres columns. Devices can change separate copies, then combine them without applying the same recorded update twice. This is called a CRDT: a conflict-free replicated data type.

The extension is SQL and PL/pgSQL, works with any Postgres driver, and supports Postgres 16, 17 and 18. It provides `crdt.pn` counters and experimental `crdt.yseq` text. Your app handles sign-in, permissions and sending updates.

## Start here

Read the [five-page guide](docs/overview.md), from what a CRDT is to connecting your app. Allow about 10–20 minutes, including examples.

[Install](docs/install.md) · [Try a counter](docs/get-started/quickstart.md) · [Try shared text](docs/get-started/text.md) · [Reference](docs/README.md#reference)

Counters cannot enforce a shared minimum or maximum while devices are offline. Text edits rewrite the whole state and retain deletion history; see [storage limits](docs/reference/storage.md) before choosing it. There is no packaged browser client.

## Development

Run from this directory:

```sh
./test/run.sh
./test/docker.sh
npm run docs:install
npm run docs:build
npm run test:research
```

See [tests](test/README.md) and the [changelog](CHANGELOG.md). Research tests are separate from the active extension tests.
