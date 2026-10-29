# Benchmark results as JSON

One file per benchmark run, for charting (the docs site reads this directory). Written by [`../../report_to_json.sh`](../../report_to_json.sh) from a `bench/run.sh` markdown report; `bench/run.sh` calls it after every complete run (not `--only` runs). The `pg16-local-*` files are the 15 serial runs of 2026-10-28/29 in `bench/baselines/<design>-<scale>-<shape>.md`, backfilled. The `pg1[678]-docker-*` files are the Docker runs of 2026-10-29 (`bench/baselines/pg<NN>-docker-<design>-<scale>-<shape>.md`, analysed in [`../VERSIONS.md`](../VERSIONS.md)); their JSON was regenerated from the copied report to add `report`, keeping the run's `date` and `host`. The `*-opt` files are the same 27 configurations with the session 3 optimized engines (`tag: "opt"`); four of them are repeat runs that replaced disturbed originals (OPTIMIZATIONS.md, Repeatability).

File name: `<run_id>.json`. A later run with the same settings replaces the file.

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
| `run_id` | `pg<major>-<environment>-<design>-<scale>-<shape>`, plus `-<tag>` if the run had `--tag` (e.g. `-smoke`; tagged runs aren't reference data) |
| `tag` | Optional. Present only for tagged runs, equal to the run_id suffix (`opt`: the session 3 optimized engines, see [`../OPTIMIZATIONS.md`](../OPTIMIZATIONS.md)). Untagged and tagged runs of the same configuration are different series; don't treat a tagged run as a newer version of an untagged one |
| `date` | When the run started measuring, UTC. Backfilled files use the report's minute-precision local time, converted to UTC |
| `environment` | `local` (throwaway cluster from `test/lib/cluster.sh` on the host) or `docker` (`docker/compose.yaml`) |
| `host` | Machine CPU, CPU count and memory; for `docker`, plus the container's CPU and memory limits |
| `pg_version` | `server_version` up to the first space (`16.4`, `17.11`) |
| `design` | `a`, `b` or `c` (`none` for the extension file) |
| `scale` | `small` (10k documents), `medium` (100k), `large` (1M) |
| `shape` | `default`, `deep` or `wide` (see `bench/run.sh --help`) |
| `clients`, `duration_s` | pgbench clients and seconds per workload |
| `workloads[]` | In run order. `p50_ms`, `p95_ms`: latency percentiles from pgbench's per-transaction log. `tps`: integer. `budget_ms`: the p95 budget from `bench/budgets.tsv` at the time of the run, `null` if none. A skipped or failed workload has `null` for `p50_ms`, `p95_ms` and `tps` |
| `seeds[]` | In phase order (`rbac`, `sharing`, `parents_proj`, `parents`, `nesting`). `seconds`: native-API seed load time. `size_mb`: total size of the tables in schema `permissions` after the seed and `VACUUM FULL`, cumulative across phases. `null` if the seed failed |
| `report` | Optional. Path from `pg_permissions/` of the run's full markdown report when it's committed in `bench/baselines/` (the docs site links it as the raw report). Absent for runs whose report is only in the git-ignored `bench/results/` |
| `checksums` | Per read policy, the first 8 hex digits of the md5 of the report's equivalence rows for that policy (`user<TAB>visible<TAB>md5-of-sorted-ids`, one line per sample user, by user). The same value `bench/run.sh` prints as `checksum (<policy>)`. Identical data and correct engines give identical checksums across designs and versions; `parents_proj` and `parents` must always be equal. Policies whose phase didn't run are absent |

Write numbers (`write_*`) are optimistic in both environments: `fsync` is off.
