# Test suite

Run from `pg_crdt/`. The active suite tests counters and text columns. Table-backed document tests and the client are preserved separately in [research](../research/ydoc/README.md).

```sh
./test/run.sh
./test/run.sh yseq
./test/run.sh -v
./test/docker.sh
npm run test:research
```

The local runner starts a throwaway UTF8 Postgres cluster and runs each spec in a fresh database. Set `PGBIN` if Postgres is not on the path. The install spec skips pg_tle and control-file paths when they are unavailable locally; the Docker runner covers Postgres 16, 17 and 18 with those installation methods. Optional trace data belongs to research; the active differential fixtures are checked in.

## Active specifications

| Spec | Checks |
| --- | --- |
| `02_security` | Exact public API, only column internals, grants and function hygiene; no document tables, sequences or `ydoc_` functions installed |
| `03_install` | Non-superuser installs, schema guards, default privileges, both column types and drop dependencies through direct SQL, pg_tle and the control file; full text-column state and generated text survive dump/restore and accept later edits |
| `01_basics` | empty, increment, decrement, value, defaults, generic replica keys; a negative amount, malformed keys and invalid domain values rejected |
| `10_merge_laws` | commutative, associative, idempotent, identity (empty and null), equal to an independent per-key max: 1,000 random triples each |
| `11_convergence` | 60 trials of 2 to 12 replicas with random operations and shuffled, duplicated, stale delivery all converge to the sum of the operations |
| `12_round_trip` | text, json and column round-trips; canonical text output |
| `20_concurrency` | two dblink sessions: `update ... set s = pn_merge(s, $1)` loses nothing under READ COMMITTED; a client read-merge-write does (negative control) |
| `21_aggregate` | `pn_merge_agg` equals folding `pn_merge`, in any order and in a parallel plan |
| `30_apply_delta` | the write path for untrusted writers: identity from a JWT claim (configurable), an app server's `set local`, or `session_user`; forged and malformed deltas rejected, stale ones a no-op; `:` reserved in replica ids |
| `40_open_questions` | the domain questions: implicit casts, when the CHECK runs (counted), generated columns and expression indexes |
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
| `80_yseq_review2` | additional column regression tests: key and device caps, chained runs, the run cap, malformed waiting ops dropped, three-way save ops on a peer, pinned search_path, bases and merges across documents (22023), positions near 2^31 |
| `81_yseq_differential` | the 71 reference fixtures through `yseq_apply` (shuffled with duplicates, and causal), two validated halves merged, `yseq_ops_since` replayed, honest fixtures on the trusted path |

Property tests use seeded randomness. The column differential suite compares against fixtures from the reference engine in `experiments/text-ref/engine.mjs`.

## The JavaScript client

The former client is research only. `npm run test:research` runs the archived document tests and client tests separately from the active extension. See [the archive](../research/ydoc/README.md).

## Benchmark

Counter benchmarks use the active extension. The historical comparison harness uses the archived combined implementation so it can still compare column and table-backed storage. Reports in `research/benchmarks/` retain their original workloads and measurements.
