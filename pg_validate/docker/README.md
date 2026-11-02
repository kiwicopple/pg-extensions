# Postgres 16, 17 and 18 with pg_tle (Docker)

This directory runs the test suite on three Postgres versions. Each version has [pg_tle](https://github.com/aws/pg_tle) preloaded, so `test/spec/03_tle_install.sql` runs its `pgtle.install_extension` branch, and `run-matrix.sh` copies `pg_validate.control` into each server so that `test/spec/04_control_install.sql` runs `create extension pg_validate`, `pg_dump` and a restore. The local throwaway cluster has neither, so those branches pass with `SKIP` there.

| Service | Image | Postgres | Host port |
| --- | --- | --- | --- |
| `pg16` | `pg_validate-pg:16` | 16.15 (`postgres:16.15-trixie`) | 127.0.0.1:54336 |
| `pg17` | `pg_validate-pg:17` | 17.11 (`postgres:17.11-trixie`) | 127.0.0.1:54337 |
| `pg18` | `pg_validate-pg:18` | 18.6 (`postgres:18.6-trixie`) | 127.0.0.1:54338 |

The setup is the one in `pg_permissions/docker/`, with its own image names, ports and volumes so the two can coexist.

## Contents of the directory

- **[`Dockerfile`](./Dockerfile)** is one file for all versions, with the build arguments `PG_TAG` and `PG_MAJOR`. It starts from the official `postgres` image and compiles pg_tle **v1.5.3** from the release tarball in a build stage.
- **[`postgresql.conf`](./postgresql.conf)** is the whole server configuration: the `initdb` defaults, `fsync=off`, `full_page_writes=off`, `timezone = 'UTC'` and `shared_preload_libraries = 'pg_tle'`.
- **[`compose.yaml`](./compose.yaml)** defines the three services. Each mounts the whole `pg_validate/` directory at `/pg_validate` and keeps its data and Unix socket in named volumes.
- **[`run-matrix.sh`](./run-matrix.sh)** runs the suite against each version in turn.
- **Authentication:** `trust`, with ports bound to 127.0.0.1. Use this setup for local testing only.

## Start and stop the servers

Run these commands from the `pg_validate/docker/` directory:

```bash
docker compose build                 # all three images (a few minutes the first time)
docker compose up -d --wait pg17     # one server
docker compose down                  # remove containers, keep volumes and images
docker compose down -v               # also delete the data volumes
psql -h localhost -p 54337 -U postgres   # from the host
```

## Run the tests

From the `pg_validate/` directory:

```bash
docker/run-matrix.sh                                  # 3 versions
docker/run-matrix.sh --versions 18 -- -v 03_tle       # one version, one spec, verbose
docker/run-matrix.sh --keep-running                   # leave the last server up
```

For each version, the script stops the other servers, starts this one, copies the control file in, and runs `test/run.sh --external` in a throwaway client container from the same image (so `psql` and `pg_dump` match the server) over the server's Unix socket. It prints a summary per version and exits with 1 if any run failed. Everything after `--` goes to `test/run.sh`.
