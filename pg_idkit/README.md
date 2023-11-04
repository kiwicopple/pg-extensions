# `pg_idkit`

Useful ID generators and utilities. A pure PL/pgSQL port of the popular [Rust version](https://github.com/VADOSWARE/pg_idkit).

The goal is to have no additional extension requirements (eg: no pgcrypto) to maintain portability.

- Source: https://github.com/kiwicopple/pg-extensions/tree/main/pg_idkit
- Docs: https://github.com/kiwicopple/pg-extensions/tree/main/pg_idkit
- DbDev: https://database.dev/kiwicopple/pg_idkit

## Usage

Function signatures follows a similar pattern to the built-in

- `gen_random_uuid_v6()` - generate a random UUID v6
- `gen_random_uuid_v7()` - generate a random UUID v7
- `gen_random_ksuid_second()` - generate a random KSUID with second-level precision
- `gen_random_ksuid_microsecond()` - generate a random KSUID with microsecond-level precision
- `timestamp_from_uuid_v7(uuidv7, timezone?)` - extract a timestamp from a UUIDv7. Optionally provide timezone (like 'America/New_York')

## Installation

```bash
dbdev install kiwicopple-pg_idkit --connection <CONNECTION_STRING>
```

or

```sql
select * from dbdev('kiwicopple-pg_idkit')
```

then:

```sql
create extension pg_idkit;
```

or to install in a separate schema (recommended):

```sql
create extension pg_idkit with schema extensions;
```

## Credits

- [`fabiolimace`](https://github.com/fabiolimace). Most of the work of this repo can be attributed to Fabio's gists on GitHub.