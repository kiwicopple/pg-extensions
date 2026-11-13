# pg_crdt test suite

The tests are the spec. Each file in `spec/` is one goal, named in its header comment. The PN-Counter files (01 to 40) were written before the extension, for the PN-Counter slice (`research/architecture.md`, section 8). The collaborative-text files (`50_text_*` to `65_text_*`) came with `ydoc_` from `experiments/text-table`, and the `yseq_` files (`70_yseq_*` to `81_yseq_*`) with the column type from `experiments/text-column`, where they were written with the implementations.

The tests need only the Postgres binaries `initdb`, `pg_ctl` and `psql` (and `pg_dump`, for the control-file branch of `03_install`). The runner finds Postgres.app by itself; otherwise set `PGBIN`. `20_concurrency`, `56_text_review`, `62_text_concurrency`, `63_text_ids` and `76_yseq_concurrency` also need the `dblink` contrib extension (it is in Postgres.app and the Docker images); without it the text files pass with `SKIP` assertions for those parts.

Two text files read data from `experiments/text-ref/`:

- `60_text_fixtures` and `81_yseq_differential` load `experiments/text-ref/fixtures/fixtures.sql` (tracked; regenerate it with `node gen-fixtures.mjs && node fixtures-to-sql.mjs` in that directory after changing the reference).
- `61_text_trace` reads the automerge-paper trace from `experiments/text-ref/traces/*.jsonl`. Those files are generated and gitignored: run `experiments/text-ref/regen-traces.sh` once (it downloads the trace and converts it with the JS reference). Without them the file passes with one `SKIP` assertion and prints `# trace files missing`.

## Run the tests

From the `pg_crdt/` directory:

```bash
./test/run.sh                    # the extension: pg_crdt--0.0.1.sql
./test/run.sh merge              # only spec files whose name contains "merge"
./test/run.sh text               # only the ydoc_ collaborative-text files (50 to 65)
./test/run.sh yseq               # only the yseq_ column files (70 to 81)
./test/run.sh -v                 # print every assertion
./test/run.sh --impl other.sql   # another build of the file
./test/run.sh --external         # the server from PGHOST, PGPORT and PGUSER
./test/docker.sh                 # Postgres 16, 17 and 18, with pg_tle and the control file
./test/docker.sh 18 -- -v 03     # one version, runner arguments after --
```

From the root of the repository: `make test.pg_crdt` and `make test.pg_crdt.docker`.

By default the runner starts a throwaway Postgres in a temporary directory, listening on a Unix socket only, and deletes it at the end. It loads `lib/tap.sql` (minimal pgTAP-style assertions) and the extension file into a UTF8 template database, and runs each spec file in a fresh clone of it, one at a time. It creates the client roles of the PostgREST convention (`anon`, `authenticated`, `service_role`); only `02_security` uses them, to check grants where those roles exist. Specs that need writer roles create their own. When the Postgres installation has pg_tle, the cluster preloads it.

A file passes only when each planned assertion ran and passed, and no SQL error occurred.

`docker.sh` runs the same runner inside `pg_permissions-pg:<version>` containers (Postgres plus pg_tle, built by `pg_permissions/docker`; override with `PG_CRDT_IMAGE`). As root it first copies `pg_crdt.control` and the SQL file into the extension directory. That is the only way to run the pg_tle and control-file branches of `03_install`; elsewhere they pass with `SKIP` assertions.

## The spec files

| File | Goal |
| --- | --- |
| `01_basics` | empty, increment, decrement, value, defaults, generic replica keys; a negative amount, malformed keys and invalid domain values rejected |
| `02_security` | grants (only for the client roles that exist), languages, volatility and parallel labels, pinned search_path, no SECURITY DEFINER; for `ydoc_`: no table or sequence privileges for any role but the owner, execute on the API and its internals for public, every PL/pgSQL function pins search_path, no dynamic SQL; for `yseq_`: execute on the API and its internals for public, usage on `crdt.yseq`, every function IMMUTABLE PARALLEL SAFE but `yseq_new` (VOLATILE), `yseq_apply` and every PL/pgSQL function pin search_path, no `EXECUTE` |
| `03_install` | non-superuser install as a script, through pg_tle and from the control file; the schema guard; the installer's default privileges stripped; drop extension restrict and cascade (a `crdt.pn` column, a `crdt.yseq` column with a generated column on `yseq_value`: `2BP01`, then cascade drops both and keeps the table, a foreign key to `crdt.ydoc_docs`); a `crdt.yseq` column smoke test; the plain install into a `SQL_ASCII` database, and that it drops the `ydoc_` tables; the `ydoc_` tables and sequences marked for pg_dump, and a dump and restore that keeps documents and sequences |
| `10_merge_laws` | commutative, associative, idempotent, identity (empty and null), equal to an independent per-key max: 1,000 random triples each |
| `11_convergence` | 60 trials of 2 to 12 replicas with random operations and shuffled, duplicated, stale delivery all converge to the sum of the operations |
| `12_round_trip` | text, json and column round-trips; canonical text output |
| `20_concurrency` | two dblink sessions: `update ... set s = pn_merge(s, $1)` loses nothing under READ COMMITTED; a client read-merge-write does (negative control) |
| `21_aggregate` | `pn_merge_agg` equals folding `pn_merge`, in any order and in a parallel plan |
| `30_apply_delta` | the write path for untrusted writers: identity from a JWT claim (configurable), an app server's `set local`, or `session_user`; forged and malformed deltas rejected, stale ones a no-op; `:` reserved in replica ids |
| `40_open_questions` | the domain questions: implicit casts, when the CHECK runs (counted), generated columns and expression indexes |
| `50_text_basics` | `ydoc_`: local insert, delete, value, length, version; the ops each edit returns; non-BMP positions; errors (22004, 22023, P0002); device keys; drop |
| `51_text_set` | `ydoc_set`: prefix and suffix diff; unicode; 300 random multibyte sets; three-way set with a base (concurrent paragraphs, delete and append, same-spot inserts); without a base a stale save reverts (pinned); base validation |
| `52_text_convergence` | 30 trials: two servers editing with local ops by several replicas, exchanging `ydoc_ops_since` split, shuffled and duplicated: same text and version |
| `53_text_apply` | `ydoc_apply`: own ids, device keys, deletes of others; idempotent; identity from `crdt.current_replica_id()`; 42501 forged or no identity; 22023 for malformed ops; buffering; `ydoc_ops_since` order and run joining |
| `54_text_wrapper` | the deployment model: no privileges for clients (42501), an app SECURITY DEFINER wrapper with its own check, `session_user` identity, reads through an app function |
| `55_text_validate` | the causal rules V0 to V7 of the untrusted path, waiting ops, the waiting quota (54000), atomicity, equivocation |
| `56_text_review` | regressions for the adversarial review (`experiments/text-table/NOTES.md`, "Review fixes") |
| `57_text_relabel_small` | 1,500 random edits with shrunk tuning constants against a model: block labels never collide |
| `58_text_order_keys` | order labels: bounds, adversarial patterns that force relabels, 4,000 random edits against a model with every invariant |
| `59_text_compact` | `ydoc_compact`: same text, version and `ydoc_ops_since` text, fewer rows; three-way set at the horizon; older bases refused |
| `60_text_fixtures` | the 71 reference fixtures (57 honest, 14 malicious) on the untrusted and the trusted path, in shuffled, duplicated and causal orders |
| `61_text_trace` | automerge-paper: local edits produce exactly the reference's ops; its ops through `ydoc_apply` and `ydoc_merge` give the same text (SKIP without the generated trace) |
| `62_text_concurrency` | dblink: a waiting writer integrates against the lock holder's version; four sessions on one document lose nothing and do not deadlock |
| `63_text_ids` | `ydoc_create`: generated UUID ids, client-chosen ids (uuid, `post:123`, unicode), 23505 for an id that exists (and for two dblink sessions creating one id at once: one succeeds), 22023 for empty, null, over-long and control-character ids, `Post` and `post` distinct, unknown documents (every write, `ydoc_ops_since` and `ydoc_version` raise P0002), a base token from another document |
| `64_text_keys` | replica keys: the cases of `test/fixtures/replica-keys.json` (also run by the JS reference, `experiments/text-ref/test.mjs`) through `ydoc_insert`, `ydoc_merge` and `ydoc_apply`: `<id>:<device>` accepted, empty id or device and over 256 bytes refused (22023) |
| `65_text_rejected_purge` | `ydoc_rejected_purge`: one writer or all, counts returned, other documents, waiting ops and text untouched, P0002, 22004, 42501 without table privileges |
| `70_yseq_basics` | `yseq_`: empty, value, length, version, insert, delete, set (minimal diff), set with base, null handling, errors (22004, 22023), the domain envelope |
| `71_yseq_model` | 40 random sessions of 150 edits from 3 replicas against a plain text model; `yseq_is_valid` on the way; `yseq_diff` of every checked edit reproduces it; 3,000 editor keystrokes ending in many chunks |
| `72_yseq_unicode` | code point positions, non-BMP, combining marks, ZWJ sequences; set() across shared UTF-8 lead and trail bytes; unicode replica ids; U+FFFD for deleted text in ops |
| `73_yseq_merge_laws` | 300 random triples with shared history: commutative, associative, idempotent, empty and null identities, valid results, `yseq_merge_agg` equals the fold |
| `74_yseq_convergence` | 40 trials of 2 to 5 replicas editing and syncing (merge and partial apply); the whole log shuffled with duplicates, one op per call or all at once, all equal; nothing pending |
| `75_yseq_sync` | non-interleaving of concurrent typing at one spot, `yseq_ops_since` with version vectors, the delete set, `yseq_diff`, causal order, three-way set |
| `76_yseq_concurrency` | dblink: three-way set with a lock wait, stale set without base (pinned), 600 concurrent `yseq_insert`, `yseq_set` and `yseq_merge` transactions lose nothing; negative control |
| `77_yseq_apply` | `yseq_apply`: owner rule, null and malformed caller ids, deletes of others, arrays of ops, idempotence; each causal rule V0 to V7; the waiting quota (54000); default identity |
| `78_yseq_generated` | stored generated column, GIN full-text index and expression index used by the planner, `like`, REINDEX and updates under `search_path = pg_catalog, pg_temp` |
| `79_yseq_review` | regressions from the adversarial review: linear cost of 8,000 deletes and 8,000 inserts in one apply, a second save from one base, malformed states (23514, 22023), numbers written as 1.0, seq 2147483647 |
| `80_yseq_review2` | the sibling `ydoc_` review's findings checked on `yseq_`: key and device caps, chained runs, the run cap, malformed waiting ops dropped, three-way save ops on a peer, pinned search_path, bases and merges across documents (22023), positions near 2^31 |
| `81_yseq_differential` | the 71 reference fixtures through `yseq_apply` (shuffled with duplicates, and causal), two validated halves merged, `yseq_ops_since` replayed, honest fixtures on the trusted path |

The property tests use `setseed`, so a run is reproducible on one Postgres version. The generator (`fixtures/gen.sql`) draws replica ids from a small pool so random states overlap. The text files share `lib/text-helpers.sql`: `pg_temp.did(uid)` resolves a public document id to the internal bigint (for specs that read the tables), `pg_temp.ydoc_check(doc)` checks the structural invariants of a document (lengths, block counters, labels unique and in bounds, ids contiguous) and `pg_temp.merge_all(doc, ops)`.

## The JavaScript client

The [JavaScript client](../docs/reference/client.md) in `client/` has its own tests, in `client/test/`. They use Node's built-in test runner and need no npm packages.

```bash
npm test --prefix client      # unit tests and the convergence fuzz, no database (about 2 s)
./client/test/pg.sh           # integration test on a throwaway Postgres with the extension
./client/test/pg.sh --external  # the same on the server from PGHOST, PGPORT and PGUSER
npm run test:client           # both
```

| File | Goal |
| --- | --- |
| `utf16.test.js` | UTF-16 to code point positions and back (emoji, ZWJ sequences, combining marks, lone surrogates); text Postgres cannot store refused |
| `client.test.js` | the ops the client sends (code point positions, batching, runs joined), change events in UTF-16 ranges, retries after a lost request or a lost response (identical re-send), the 128-run batch cap, refusals (`42501` stops the client, reported once), serialized syncs, reopening a key; the engine's code point order and UTF-8 length against `Buffer` |
| `convergence.test.js` | 1,000 seeds: 2 to 5 clients, random edits and overlapping syncs over an in-memory server that validates like `ydoc_apply` (the reference's untrusted path), with random delays and lost requests and responses; every client converges to the server's text and version, and its change events reproduce its text at every step |
| `pg.test.js` | against Postgres, through the example transport `docs/examples/node-postgres-transport.mjs` (with a psql stand-in for node-postgres): two clients agree with `ydoc_value`, `ydoc_length` and `ydoc_version`; a lost response; a forged key (`42501`); 8 seeds of three clients with concurrent syncs, `ydoc_set` saves and `ydoc_compact`, with no waiting or refused ops left. Skipped unless `pg.sh` runs it |

`pg.sh` uses `test/lib/cluster.sh`, like `run.sh`. Docker images without Node can still be tested: start the container with a published port and run `pg.sh --external` against it.

## Benchmark

`bench/pn-counter.sh` measures merge latency against the number of replicas, the merge variants, and WAL per write for a state column and for an insert-only delta table. Results: `research/benchmarks/pn-counter.md`. `bench/text-compare.sh` compares `ydoc_` with the experimental jsonb-column shape (`experiments/text-column`): `research/benchmarks/text.md`. `experiments/text-table/bench.sh` has the `ydoc_` design measurements (`experiments/text-table/NOTES.md`).
