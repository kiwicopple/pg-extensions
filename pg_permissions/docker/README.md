# Postgres 16, 17 and 18 with pg_tle (Docker)

Runs the test suite and the benchmark on three Postgres versions, each with [pg_tle](https://github.com/aws/pg_tle) preloaded, so `test/spec/03_tle_install.sql` exercises its `pgtle.install_extension` branch (the local throwaway cluster has no pg_tle and skips it).

| Service | Image | Postgres | Host port |
| --- | --- | --- | --- |
| `pg16` | `pg_permissions-pg:16` | 16.15 (`postgres:16.15-trixie`) | 127.0.0.1:54316 |
| `pg17` | `pg_permissions-pg:17` | 17.11 (`postgres:17.11-trixie`) | 127.0.0.1:54317 |
| `pg18` | `pg_permissions-pg:18` | 18.6 (`postgres:18.6-trixie`) | 127.0.0.1:54318 |

## What's in it

- **[`Dockerfile`](./Dockerfile)**, one for all versions (build args `PG_TAG`, `PG_MAJOR`): the official `postgres` image plus pg_tle **v1.5.3** built from the release tarball in a build stage (`postgresql-server-dev-<major>`, `flex`, `libkrb5-dev`; `with_llvm=no`, so no JIT bitcode). v1.5.3 (2026-10-08) is the newest release and supports Postgres 12 to 19; Postgres 18 is supported since v1.5.2. Only the installed files are copied into the final image.
- **[`postgresql.conf`](./postgresql.conf)**, the server's whole configuration for every version, mounted read-only. It mirrors the throwaway cluster from `test/lib/cluster.sh` (plain `initdb` defaults, `fsync=off`, `full_page_writes=off`), adds `shared_preload_libraries = 'pg_tle'` and listens on TCP as well.
- **Limits:** every service has `cpus: 4`, `mem_limit: 6g` and `shm_size: 1g` (parallel query needs more than Docker's 64 MB `/dev/shm`). The Docker Desktop VM here has 10 CPUs and about 9.7 GB, so one server at a time.
- **Storage:** named volumes, `pgNN-data` for the data directory (tmpfs would count against `mem_limit` and disappear on stop). Test and benchmark runs create and drop their own databases, so nothing carries over. `pgNN-run` holds the Unix socket, shared with the client containers below.
- **Auth:** `trust`, ports bound to 127.0.0.1 only. This is a local benchmarking setup.
- The whole `pg_permissions/` directory is mounted at `/pg_permissions` in each container.

## Up and down

From `pg_permissions/docker/`:

```bash
docker compose build                 # all three images (a few minutes the first time)
docker compose up -d --wait pg17     # one server
docker compose stop                  # stop all, keep containers
docker compose down                  # remove containers, keep volumes and images
docker compose down -v               # also delete the data volumes
psql -h localhost -p 54317 -U postgres   # from the host
```

## Running tests and benchmarks

[`run-matrix.sh`](./run-matrix.sh) loops over versions and designs, strictly one at a time: for each version it stops the other servers, starts this one, runs every design, and stops it. At the end it runs `docker compose down` (images and volumes stay). From `pg_permissions/`:

```bash
docker/run-matrix.sh test                                     # 3 versions x A, B, C
docker/run-matrix.sh test --versions 18 --designs c -- -v 03_tle
docker/run-matrix.sh bench -- --scale large                   # 9 large runs
docker/run-matrix.sh bench --versions 17 --designs a,b -- --scale medium --shape wide
docker/run-matrix.sh bench --designs c -- --scale small --duration 2 --tag smoke
```

`--versions` and `--designs` (`a`, `b`, `c`, or `ext` for the extension file) filter and order the loop; everything after `--` goes to `test/run.sh` or `bench/run.sh`. Output is also saved to `bench/results/matrix-<test|bench>-<timestamp>.log`, and a summary (exit status, time, result line or saved files) is printed at the end.

Each run happens in a throwaway client container (`docker compose run`) from the same image as the server, so `psql` and `pgbench` match the server version. It connects over the server's Unix socket, like the local throwaway cluster, and has its own 4-CPU limit, so pgbench doesn't take CPU from the server. By hand, the same thing is:

```bash
docker compose -f docker/compose.yaml up -d --wait pg18
docker compose -f docker/compose.yaml run --rm --no-deps -T --entrypoint bash -u postgres \
    -e PGHOST=/var/run/postgresql -e PGUSER=postgres -e BENCH_ENVIRONMENT=docker \
    pg18 /pg_permissions/bench/run.sh --external --impl prototypes/c-compiled-model.sql --scale medium
```

Running the harness from the host also works (`PGHOST=localhost PGPORT=54318 PGUSER=postgres ./test/run.sh --external --impl ...`), but then the client is your local Postgres version and every query crosses Docker Desktop's port forwarding, which adds latency. Fine for tests, not for benchmark numbers.

### Results

- Reports go to `bench/results/` as usual (dates in the host's time zone; run-matrix passes `TZ`).
- Complete benchmark runs also write `bench/baselines/data/pg<major>-docker-<design>-<scale>-<shape>[-<tag>].json`, with `host` set to the machine plus the container limits read from the server's cgroup (e.g. `Apple M4, 10 CPU, 24 GB; container cpus=4 mem=6g`). See [`../bench/baselines/data/README.md`](../bench/baselines/data/README.md). A later run with the same settings replaces the file. Move tagged experiments (e.g. `-smoke`) out of that directory: the docs site charts everything in it.
- The cross-design equivalence files (`bench/results/equivalence-<scale>-<shape>-<design>.tsv`) aren't keyed by version, so a Docker run compares against the latest run of the other designs on any version, local included. The data is generated the same way on every version, so checksums should match regardless; a mismatch is still a real finding.

### How long a full serial run takes

Measured on 2026-10-29 (10 s per workload, 14 workloads, so about 2.5 minutes of each run is pgbench), including container start and stop:

| Benchmark | One version, A + B + C | 3 versions x 3 engines |
| --- | --- | --- |
| `--scale large` (default shape) | about 11 min (A 3.2, B 4.8, C 3.0) | 32 min |
| `--scale medium --shape deep` | about 7.5 min | 22 min |
| `--scale medium --shape wide` | about 11 min (C 5.5: its wide sharing seed takes 3 min) | 34 min |

Results from these runs are in [`../bench/baselines/VERSIONS.md`](../bench/baselines/VERSIONS.md).
