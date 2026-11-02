# Benchmark results as JSON

This folder has one JSON file for each benchmark run. The docs site reads this folder to make charts. [`../../report_to_json.sh`](../../report_to_json.sh) writes each file from a markdown report of `bench/run.sh`. `bench/run.sh` calls the script after every complete run (not after `--only` runs). The per-run markdown reports are in [`../`](../). The [index of the benchmark summaries](../../../research/benchmarks/README.md) explains how the reports are named.

The file groups are these:

- `pg16-local-*`: the 15 serial runs of 2026-10-28/29 in `bench/baselines/<design>-<scale>-<shape>.md`. We backfilled these files.
- `pg1[678]-docker-*`: the Docker runs of 2026-10-29 (`bench/baselines/pg<NN>-docker-<design>-<scale>-<shape>.md`, analyzed in [`VERSIONS.md`](../../../research/benchmarks/VERSIONS.md)). We made the JSON again from the copied report, to add `report`. The files keep the `date` and the `host` of the run.
- `*-opt`: the same 27 configurations with the session 3 optimized designs (`tag: "opt"`). Four of them are repeat runs that replaced disturbed originals ([`OPTIMIZATIONS.md`](../../../research/benchmarks/OPTIMIZATIONS.md), Repeatability).
- `pg18-docker-d-*-opt`: design D (the unoptimized prototype) in the same three configurations. They have the tag `opt`, so they are in the same primary series ([`D.md`](../../../research/benchmarks/D.md)).
- `pg18-docker-d-*-opt2`: design D after its second optimization pass (`tag: "opt2"`, a separate series; section "opt2" of [`D.md`](../../../research/benchmarks/D.md)).
- `pg18-docker-d-*-opt3`: design D after its third pass (`tag: "opt3"`; section "opt3" of [`D.md`](../../../research/benchmarks/D.md)).
- `pg18-docker-{a,b,c,d}-{small,medium,large}-default-p6`: the phase 6 runs (`tag: "p6"`; section "Phase 6" of [`D.md`](../../../research/benchmarks/D.md)). `pg18-docker-d-large-default-p6check` is the `--check` run.
- `pg18-docker-e-{small,medium,large}-default-p5`: design E, the Cedar model, at phase 5 (`tag: "p5"`; [`cedar.md`](../../../research/benchmarks/cedar.md)). `pg18-docker-e-{small,medium}-default-p9`: the same after the phase 9 security fixes (`tag: "p9"`; section "Phase 9" of `cedar.md`).

The name of a file is `<run_id>.json`. A later run with the same settings replaces the file.

```json
{
  "run_id": "pg17-docker-c-large-default",
  "date": "2026-10-29T10:00:00Z",
  "environment": "docker",
  "host": "Apple M4, 10 CPU, 24 GB; container cpus=4 mem=6g",
  "pg_version": "17.11",
  "design": "c",
  "scale": "large", "shape": "default", "clients": 4, "duration_s": 10,
  "workloads": [ {"name": "rbac_check", "p50_ms": 0.23, "p95_ms": 0.31, "tps": 12000, "budget_ms": 1} ],
  "seeds": [ {"phase": "rbac", "seconds": 4.1, "size_mb": 120.5} ],
  "checksums": {"rbac": "8d25a1e0", "sharing": "58a66d1d", "parents_proj": "bffa5242", "parents": "bffa5242"}
}
```

| Field | Meaning |
| --- | --- |
| `run_id` | `pg<major>-<environment>-<design>-<scale>-<shape>`, plus `-<tag>` if the run had `--tag` (for example `-smoke`; tagged runs are not reference data) |
| `tag` | Optional. Present only for tagged runs, equal to the run_id suffix (`opt`: the session 3 optimized designs, see [`OPTIMIZATIONS.md`](../../../research/benchmarks/OPTIMIZATIONS.md)). Untagged and tagged runs of the same configuration are different series. Do not treat a tagged run as a newer version of an untagged one |
| `date` | The time when the run started to measure, in UTC. Backfilled files use the minute-precision local time of the report, converted to UTC |
| `environment` | `local` (throwaway cluster from `test/lib/cluster.sh` on the host) or `docker` (`docker/compose.yaml`) |
| `host` | CPU model of the machine, CPU count and memory. For `docker`, also the CPU limit and the memory limit of the container |
| `pg_version` | `server_version` up to the first space (`16.4`, `17.11`) |
| `design` | `a`, `b`, `c` or `d` (`none` for the extension file) |
| `scale` | `small` (10k documents), `medium` (100k), `large` (1M) |
| `shape` | `default`, `deep` or `wide` (see `bench/run.sh --help`) |
| `clients`, `duration_s` | pgbench clients and seconds for each workload |
| `workloads[]` | In run order. `p50_ms` and `p95_ms` are latency percentiles from the per-transaction log of pgbench. `tps` is an integer. `budget_ms` is the p95 budget from [`bench/budgets.tsv`](../../budgets.tsv) at the time of the run (`null` if none). A workload that was skipped or failed has `null` for `p50_ms`, `p95_ms` and `tps` |
| `seeds[]` | In phase order (`rbac`, `sharing`, `parents_proj`, `parents`, `nesting`, and for design d also `conditions` and `blocklist`). `seconds` is the native-API seed load time. `size_mb` is the total size of the tables in schema `permissions` after the seed and `VACUUM FULL`, cumulative across phases. It is `null` if the seed failed |
| `report` | Optional. The path from `pg_permissions/` of the full markdown report of the run, when the report is committed in `bench/baselines/` (the docs site links it as the raw report). Absent for runs whose report is only in the git-ignored `bench/results/` |
| `checksums` | For each read policy, the first 8 hex digits of the md5 of the equivalence rows of the report for that policy (`user<TAB>visible<TAB>md5-of-sorted-ids`, one line for each sample user, by user). This is the same value that `bench/run.sh` prints as `checksum (<policy>)`. Identical data and correct designs give identical checksums across designs and versions. `parents_proj` and `parents` must always be equal. For design d, the policy `conditions` must equal `parents`. A policy whose phase did not run is absent |

Write numbers (`write_*`) are optimistic in both environments, because `fsync` is off.
