# pg_crdt

CRDTs (conflict-free replicated data types) for Postgres, written in SQL and PL/pgSQL only. A CRDT is a value that several writers can change independently and merge later, in any order, any number of times, and still agree on the result.

Version 0.0.1 has two types:

- the **PN-Counter**: a counter that can go up and down, where every writer (replica) keeps its own running totals. Use it for likes, votes, stock levels or quotas that are updated from several devices, regions or offline clients;
- **collaborative text** (`ydoc_`): a plain-text document that several people edit at once, from forms or live editors, stored in the extension's tables and referenced from yours by a text id that your clients may choose. See [Collaborative text for a blog post](docs/guides/collaborative-text.md).

pg_crdt is plain Postgres. It works with any client, driver or API layer, needs no superuser and no C, and assumes no identity provider or platform roles. It runs on Postgres 16, 17 and 18.

- Source: https://github.com/kiwicopple/pg-extensions/tree/main/pg_crdt

## A counter in 30 seconds

```sql
create table posts (
  id bigint primary key,
  likes crdt.pn not null default crdt.pn_empty()
);
insert into posts (id) values (1);

-- each writer counts under its own replica id
update posts set likes = crdt.pn_increment(likes, 'alice') where id = 1;
update posts set likes = crdt.pn_increment(likes, 'bob', 2) where id = 1;
update posts set likes = crdt.pn_decrement(likes, 'alice') where id = 1;

select crdt.pn_value(likes) from posts where id = 1;   -- 2
select likes from posts where id = 1;
-- {"n": {"alice": 1}, "p": {"bob": 2, "alice": 1}, "t": "pn", "v": 1}
```

From an application, merge a state or delta that arrives from a client in one statement. The row lock makes this safe, and merging twice changes nothing:

```sql
update posts
set likes = crdt.pn_merge(likes, $1)
where id = $2;
```

Never read the state, merge it in the client and write the result back: another writer's update in between is lost. See [Update safely](docs/guides/safe-updates.md). Clients you do not trust get a wrapper around `pn_apply_delta`, not `update` access: see [Accept writes from untrusted clients](docs/guides/security.md).

## Install

pg_crdt is one SQL file, `pg_crdt--0.0.1.sql`. It creates the schema `crdt`. The database owner can install it:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f pg_crdt--0.0.1.sql
```

[Install](docs/install.md) also covers pg_tle (RDS, Aurora, Supabase), the extension directory with `create extension`, and the schema guard.

> **Warning: dropping the extension drops your data.** `crdt.pn` is a type that belongs to the extension. `drop extension pg_crdt cascade` **drops every column that uses it**, with its data. The text documents are in the extension's tables: `drop extension pg_crdt` **drops every document**. Read [Uninstall](docs/install.md#uninstall) first.

## Documentation

Start with the [documentation map](docs/README.md), or the [quickstart](docs/get-started/quickstart.md).

| Task | Guide |
| --- | --- |
| Decide whether you need a CRDT, and see which types exist and which are planned | [Overview](docs/overview.md) |
| Count in a few minutes | [Quickstart](docs/get-started/quickstart.md) |
| Name writers, use device suffixes, recover a lost device | [Replicas and identity](docs/guides/replicas-and-identity.md) |
| Write without losing updates | [Update safely](docs/guides/safe-updates.md) |
| Accept deltas from untrusted clients | [Security](docs/guides/security.md) |
| Index the value, keep counters as deltas, WAL and merge benchmarks | [Storage and performance](docs/guides/storage-and-performance.md) |
| The state, merge and the `crdt.pn` domain | [PN-Counter](docs/types/pn-counter.md) |
| Edit a blog post with several people: form saves, live ops, search, compaction | [Collaborative text for a blog post](docs/guides/collaborative-text.md) |
| How text documents merge, and what they cannot do | [Collaborative text](docs/types/collaborative-text.md) |
| Connect a live editor from JavaScript (`client/`) | [JavaScript client](docs/reference/client.md) |
| Look up a function, an error or a limit | [Shared](docs/reference/shared.md), [PN-Counter functions](docs/reference/pn.md), [Collaborative text functions](docs/reference/ydoc.md), [Errors](docs/reference/errors.md), [Limits](docs/reference/limits.md) |

The design and the decisions behind it are in [`research/architecture.md`](research/architecture.md) and, for text, [`research/text.md`](research/text.md). Benchmarks: [`research/benchmarks/pn-counter.md`](research/benchmarks/pn-counter.md), [`research/benchmarks/text.md`](research/benchmarks/text.md). What changed: the [changelog](CHANGELOG.md).

## Tests

```bash
./test/run.sh            # throwaway Postgres; pg_tle and the control-file install SKIP
./test/docker.sh         # Postgres 16, 17, 18 with pg_tle and the control file
npm run test:client      # the JavaScript client: unit, convergence and Postgres tests
make test.pg_crdt        # from the repository root
```

See [`test/README.md`](test/README.md).
