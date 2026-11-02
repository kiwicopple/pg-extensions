# Postgres 16, 17 and 18 with pg_tle (Docker)

This directory runs the test suite and the benchmark on three Postgres versions. Each version has [pg_tle](https://github.com/aws/pg_tle) preloaded. The spec `test/spec/d/03_tle_install.sql` then runs its `pgtle.install_extension` branch. The prototype copy, `test/spec/03_tle_install.sql`, does the same. The local throwaway cluster has no pg_tle, so it skips this branch.

| Service | Image | Postgres | Host port |
| --- | --- | --- | --- |
| `pg16` | `pg_permissions-pg:16` | 16.15 (`postgres:16.15-trixie`) | 127.0.0.1:54316 |
| `pg17` | `pg_permissions-pg:17` | 17.11 (`postgres:17.11-trixie`) | 127.0.0.1:54317 |
| `pg18` | `pg_permissions-pg:18` | 18.6 (`postgres:18.6-trixie`) | 127.0.0.1:54318 |

## Contents of the directory

- **[`Dockerfile`](./Dockerfile)** is one file for all versions. It has the build arguments `PG_TAG` and `PG_MAJOR`. It starts from the official `postgres` image. A build stage compiles pg_tle **v1.5.3** from the release tarball. The build stage uses `postgresql-server-dev-<major>`, `flex` and `libkrb5-dev`, with `with_llvm=no`, so there is no JIT bitcode. The final image gets only the installed files.

  Version 1.5.3 (2026-10-08) is the newest release. It supports Postgres 12 to 19. Version 1.5.2 added support for Postgres 18.
- **[`postgresql.conf`](./postgresql.conf)** is the whole server configuration for every version. Each container mounts it read-only. It mirrors the throwaway cluster from `test/lib/cluster.sh`: the `initdb` defaults, `fsync=off` and `full_page_writes=off`. It adds `shared_preload_libraries = 'pg_tle'` and listens on TCP too.
- **Limits:** each service has `cpus: 4`, `mem_limit: 6g` and `shm_size: 1g`. Parallel query needs more than the 64 MB `/dev/shm` of Docker. The Docker Desktop VM of the maintainer has 10 CPUs and about 9.7 GB. For this reason, run one server at a time.
- **Storage:** named volumes. `pgNN-data` holds the data directory. A tmpfs would count against `mem_limit` and would disappear on stop. Test and benchmark runs create and drop their own databases, so nothing carries over. `pgNN-run` holds the Unix socket. The client containers below share it.
- **Authentication:** `trust`. The ports bind to 127.0.0.1 only. Use this setup for local benchmarks only.
- Each container mounts the whole `pg_permissions/` directory at `/pg_permissions`.

## Start and stop the servers

Run these commands from the `pg_permissions/docker/` directory:

```bash
docker compose build                 # all three images (a few minutes the first time)
docker compose up -d --wait pg17     # one server
docker compose stop                  # stop all, keep containers
docker compose down                  # remove containers, keep volumes and images
docker compose down -v               # also delete the data volumes
psql -h localhost -p 54317 -U postgres   # from the host
```

## Run tests and benchmarks

The script [`run-matrix.sh`](./run-matrix.sh) loops over versions and designs. It runs strictly one server at a time. For each version, it stops the other servers, starts this server, runs each design, and stops the server. At the end, it runs `docker compose down`. The images and the volumes stay. Run these commands from the `pg_permissions/` directory:

```bash
docker/run-matrix.sh test                                     # 3 versions x the extension
docker/run-matrix.sh test --versions 18 --designs ext -- -v 03_tle
docker/run-matrix.sh test --designs ext,a,b,c                 # the extension and the prototypes
docker/run-matrix.sh bench -- --scale large                   # 3 large runs of the extension
docker/run-matrix.sh bench --versions 17 --designs ext,a,b -- --scale medium --shape wide
docker/run-matrix.sh bench --designs c -- --scale small --duration 2 --tag smoke
```

The options `--versions` and `--designs` filter and order the loop. The design `ext` is the extension file. It is the default, and `d` is another name for it. The designs `a`, `b` and `c` are the prototypes in `prototypes/`, which are kept as history. Everything after `--` goes to `test/run.sh` or `bench/run.sh`.

The option `--keep-running` keeps the last server up. Without it, the script runs `docker compose down`.

The script also saves the output to `bench/results/matrix-<test|bench>-<timestamp>.log`. At the end, it prints a summary. The summary has the exit status, the time, and the result line or the saved files.

Each run happens in a throwaway client container (`docker compose run`). The container uses the same image as the server, so `psql` and `pgbench` match the version of the server. It connects over the Unix socket of the server, like the local throwaway cluster. It has its own limit of 4 CPUs, so pgbench does not take CPU time from the server. By hand, the same run is:

```bash
docker compose -f docker/compose.yaml up -d --wait pg18
docker compose -f docker/compose.yaml run --rm --no-deps -T --entrypoint bash -u postgres \
    -e PGHOST=/var/run/postgresql -e PGUSER=postgres -e BENCH_ENVIRONMENT=docker \
    pg18 /pg_permissions/bench/run.sh --external --impl pg_permissions--0.1.0.sql --scale medium
```

You can also run the harness from the host: `PGHOST=localhost PGPORT=54318 PGUSER=postgres ./test/run.sh --external --impl ...`. Then the client is your local Postgres version, and each query crosses the network layer of Docker Desktop. This adds latency. Use it for tests, but not for benchmark numbers.

### Results

- Reports go to `bench/results/` as usual. The dates use the time zone of the host, because `run-matrix.sh` passes `TZ`.
- Complete benchmark runs also write `bench/baselines/data/pg<major>-docker-<design>-<scale>-<shape>[-<tag>].json`. The field `host` has the machine and the container limits that the script reads from the cgroup of the server. An example is `Apple M4, 10 CPU, 24 GB; container cpus=4 mem=6g`. See [`../bench/baselines/data/README.md`](../bench/baselines/data/README.md). A later run with the same settings replaces the file. Move tagged experiments, such as `-smoke`, out of this directory, because the docs site charts everything in it.
- The files `bench/results/equivalence-<scale>-<shape>-<design>.tsv` have no version in their name. A Docker run compares against the latest run of the other designs on any version, local runs included. The script generates the data in the same way on every version, so the checksums must match. A mismatch is a real problem.

### Duration of a full serial run

Measured on 2026-10-29: each workload runs for 10 s, and there are 14 workloads. About 2.5 minutes of each run is pgbench. The times include the start and stop of the containers.

| Benchmark | One version, A + B + C | 3 versions x 3 designs |
| --- | --- | --- |
| `--scale large` (default shape) | about 11 min (A 3.2, B 4.8, C 3.0) | 32 min |
| `--scale medium --shape deep` | about 7.5 min | 22 min |
| `--scale medium --shape wide` | about 11 min (C 5.5: its seed for wide shares takes 3 min) | 34 min |

These times are for the three prototypes. The extension was measured later. See [`../research/benchmarks/D.md`](../research/benchmarks/D.md). The results of these runs are in [`../research/benchmarks/VERSIONS.md`](../research/benchmarks/VERSIONS.md).
