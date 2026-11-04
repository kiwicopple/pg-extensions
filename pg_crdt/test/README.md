# pg_crdt test suite

The tests are the spec. Each file in `spec/` is one goal, named in its header comment. They were written before the extension, for the PN-Counter slice (`research/architecture.md`, section 8).

The tests need only the Postgres binaries `initdb`, `pg_ctl` and `psql`. The runner finds Postgres.app by itself; otherwise set `PGBIN`. `20_concurrency` also needs the `dblink` contrib extension (it is in Postgres.app and the Docker images).

## Run the tests

From the `pg_crdt/` directory:

```bash
./test/run.sh                    # the extension: pg_crdt--0.0.1.sql
./test/run.sh merge              # only spec files whose name contains "merge"
./test/run.sh -v                 # print every assertion
./test/run.sh --impl other.sql   # another build of the file
./test/run.sh --external         # the server from PGHOST, PGPORT and PGUSER
./test/docker.sh                 # Postgres 16, 17 and 18, with pg_tle and the control file
./test/docker.sh 18 -- -v 03     # one version, runner arguments after --
```

From the root of the repository: `make test.pg_crdt` and `make test.pg_crdt.docker`.

By default the runner starts a throwaway Postgres in a temporary directory, listening on a Unix socket only, and deletes it at the end. It loads `lib/tap.sql` (minimal pgTAP-style assertions) and the extension file into a template database, and runs each spec file in a fresh clone of it, one at a time. It creates the client roles of the PostgREST convention (`anon`, `authenticated`, `service_role`); only `02_security` uses them, to check grants where those roles exist. Specs that need writer roles create their own. When the Postgres installation has pg_tle, the cluster preloads it.

A file passes only when each planned assertion ran and passed, and no SQL error occurred.

`docker.sh` runs the same runner inside `pg_permissions-pg:<version>` containers (Postgres plus pg_tle, built by `pg_permissions/docker`; override with `PG_CRDT_IMAGE`). As root it first copies `pg_crdt.control` and the SQL file into the extension directory. That is the only way to run the pg_tle and control-file branches of `03_install`; elsewhere they pass with `SKIP` assertions.

## The spec files

| File | Goal |
| --- | --- |
| `01_basics` | empty, increment, decrement, value, defaults, generic replica keys; a negative amount, malformed keys and invalid domain values rejected |
| `02_security` | grants (only for the client roles that exist), languages, volatility and parallel labels, pinned search_path, no SECURITY DEFINER |
| `03_install` | non-superuser install as a script, through pg_tle and from the control file; the schema guard; drop extension restrict and cascade |
| `10_merge_laws` | commutative, associative, idempotent, identity (empty and null), equal to an independent per-key max: 1,000 random triples each |
| `11_convergence` | 60 trials of 2 to 12 replicas with random operations and shuffled, duplicated, stale delivery all converge to the sum of the operations |
| `12_round_trip` | text, json and column round-trips; canonical text output |
| `20_concurrency` | two dblink sessions: `update ... set s = pn_merge(s, $1)` loses nothing under READ COMMITTED; a client read-merge-write does (negative control) |
| `21_aggregate` | `pn_merge_agg` equals folding `pn_merge`, in any order and in a parallel plan |
| `30_apply_delta` | the write path for untrusted writers: identity from a JWT claim (configurable), an app server's `set local`, or `session_user`; forged and malformed deltas rejected, stale ones a no-op; `:` reserved in replica ids |
| `40_open_questions` | the domain questions: implicit casts, when the CHECK runs (counted), generated columns and expression indexes |

The property tests use `setseed`, so a run is reproducible on one Postgres version. The generator (`fixtures/gen.sql`) draws replica ids from a small pool so random states overlap.

## Benchmark

`bench/pn-counter.sh` measures merge latency against the number of replicas, the merge variants, and WAL per write for a state column and for an insert-only delta table. Results: `research/benchmarks/pn-counter.md`.
