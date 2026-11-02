# Postgres 16, 17 and 18 (Docker)

These are serial runs of 2026-10-29 of all three designs on Postgres 16.15, 17.11 and 18.6, each with pg_tle 1.5.3. They ran in Docker on the same Apple M4 laptop that produced the local Postgres 16.4 baselines in [`COMPARISON.md`](./COMPARISON.md). The setup is in [`../../docker/README.md`](../../docker/README.md). We ran one server at a time (`docker/run-matrix.sh bench`), with `cpus: 4` and `mem_limit: 6g`. The settings are the same as for the local throwaway cluster (`fsync=off`, `full_page_writes=off`, initdb defaults).

pgbench ran in a separate client container over the Unix socket, with 4 clients and 10 s for each workload. There are three groups of 9 runs (3 versions × 3 designs): large default, medium deep and medium wide. The wall-clock times were 32, 22 and 34 minutes.

These are the designs before the session 3 optimizations. [`OPTIMIZATIONS.md`](./OPTIMIZATIONS.md) has the same matrix with the optimized designs (the `*-opt` files). The full report of each run (plans, per-table storage, per-user checksums) is `pg<NN>-docker-<design>-<scale>-<shape>.md` in [`../../bench/baselines/`](../../bench/baselines/). Its numbers are in `data/<same name>.json`. [`COMPARISON.md`](./COMPARISON.md) has the engine comparison. This file is only about what changes with the Postgres version and with the environment.

**Summary.** Every run completed, and every design returns the same visible documents on every version. Postgres 17 is as fast as 16 on these workloads. Postgres 18 is typically 10-15% faster on the RBAC reads and 21-37% faster on `rbac_update_one`, for all three designs. The single-branch parents count of C is 22-28% faster on 17 and 18 than on 16. The counts of A and B are not faster.

No slowdown on 17 or 18 holds across configurations. The order of the designs on each workload is the same on every version. The exception is where designs were already within about 0.05 ms of each other. Docker and local numbers are not interchangeable. For the same Postgres major version they differ by up to 2x in either direction. The size of the difference is a function of the workload (see Calibration).

## Checksums

For each configuration, the per-policy checksums are identical across A, B and C, across 16, 17 and 18, and equal to the local 16.4 runs. There are 12 runs for each configuration, with one distinct value for each policy. A checksum is the md5 over the visible-document count and the md5 of the sorted ids of the 8 sample users (see [`data/README.md`](../../bench/baselines/data/README.md)).

| configuration | rbac | sharing | parents_proj | parents |
| --- | --- | --- | --- | --- |
| large default | `2e1dd348` | `58a66d1d` | `bffa5242` | `bffa5242` |
| medium deep | `d394663f` | `7cf80111` | `3261b092` | `3261b092` |
| medium wide | `d394663f` | `6f7c008d` | `f2867b7f` | `f2867b7f` |

## Large, default shape

The data has 1M documents, 10k users, 100 orgs and 500 teams (4-ary tree). Each user has 1 team, and each team has 5 shares. A sample user sees about 20k documents. The local equivalent is `<design>-large-default.md`.

p50 latency, ms:

| workload | A 16 | A 17 | A 18 | B 16 | B 17 | B 18 | C 16 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rbac_check` | 0.30 | 0.29 | 0.26 | 0.35 | 0.35 | 0.26 | 0.28 | 0.28 | 0.25 |
| `rbac_select_page` | 0.84 | 0.83 | 0.76 | 0.84 | 0.83 | 0.77 | 0.85 | 0.86 | 0.73 |
| `rbac_select_count` | 0.93 | 0.90 | 0.85 | 0.94 | 0.89 | 0.85 | 0.94 | 0.92 | 0.82 |
| `rbac_update_one` | 0.67 | 0.69 | 0.53 | 0.81 | 0.75 | 0.52 | 0.66 | 0.71 | 0.45 |
| `write_assign_role` | 0.17 | 0.16 | 0.16 | 0.17 | 0.15 | 0.14 | 0.22 | 0.20 | 0.18 |
| `share_list_objects` | 0.35 | 0.36 | 0.34 | 0.31 | 0.31 | 0.29 | 0.28 | 0.28 | 0.26 |
| `share_select_page` | 1.55 | 1.56 | 1.45 | 1.25 | 1.24 | 1.16 | 1.11 | 1.11 | 1.00 |
| `write_share` | 0.16 | 0.15 | 0.15 | 0.16 | 0.14 | 0.14 | 0.19 | 0.17 | 0.17 |
| `parents_proj_select_page` | 2.21 | 2.27 | 2.09 | 1.41 | 1.38 | 1.30 | 1.12 | 1.09 | 1.05 |
| `parents_proj_select_count` | 9.12 | 8.98 | 8.56 | 8.37 | 8.19 | 7.79 | 8.24 | 7.96 | 7.48 |
| `parents_select_page` | 242 | 246 | 240 | 95.36 | 94.70 | 102 | 10.69 | 10.48 | 9.26 |
| `parents_select_count` | 261 | 266 | 269 | 116 | 112 | 122 | 23.09 | 18.05 | 16.91 |
| `write_nest_team` | 0.16 | 0.15 | 0.15 | 107 | 112 | 107 | 299 | 303 | 300 |
| `nest_check` | 0.67 | 0.69 | 0.52 | 1.30 | 1.31 | 1.14 | 0.33 | 0.33 | 0.30 |

p95 latency, ms:

| workload | A 16 | A 17 | A 18 | B 16 | B 17 | B 18 | C 16 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rbac_check` | 0.41 | 0.38 | 0.35 | 0.47 | 0.43 | 0.34 | 0.38 | 0.44 | 0.32 |
| `rbac_select_page` | 1.41 | 1.03 | 1.04 | 1.04 | 1.03 | 0.94 | 1.05 | 1.08 | 0.96 |
| `rbac_select_count` | 1.43 | 1.08 | 1.15 | 1.24 | 1.03 | 1.06 | 1.14 | 1.10 | 1.02 |
| `rbac_update_one` | 0.93 | 0.89 | 0.75 | 1.11 | 0.97 | 0.64 | 0.81 | 0.94 | 0.57 |
| `write_assign_role` | 0.25 | 0.22 | 0.23 | 0.25 | 0.21 | 0.20 | 0.29 | 0.27 | 0.24 |
| `share_list_objects` | 0.48 | 0.46 | 0.45 | 0.41 | 0.41 | 0.36 | 0.37 | 0.36 | 0.35 |
| `share_select_page` | 1.99 | 1.90 | 1.78 | 1.55 | 1.50 | 1.42 | 1.37 | 1.46 | 1.41 |
| `write_share` | 0.23 | 0.21 | 0.22 | 0.23 | 0.20 | 0.20 | 0.28 | 0.24 | 0.23 |
| `parents_proj_select_page` | 2.79 | 3.42 | 2.67 | 1.83 | 1.64 | 1.54 | 1.45 | 1.36 | 1.54 |
| `parents_proj_select_count` | 10.29 | 12.06 | 10.25 | 9.97 | 9.15 | 8.46 | 9.50 | 8.94 | 8.50 |
| `parents_select_page` | 268 | 282 | 265 | 116 | 121 | 128 | 12.80 | 13.64 | 11.13 |
| `parents_select_count` | 295 | 305 | 296 | 136 | 131 | 140 | 27.03 | 21.09 | 24.90 |
| `write_nest_team` | 0.22 | 0.21 | 0.21 | 126 | 140 | 126 | 342 | 352 | 359 |
| `nest_check` | 0.82 | 0.97 | 0.62 | 1.49 | 1.65 | 1.37 | 0.41 | 0.41 | 0.44 |

Seed seconds / cumulative size of the `permissions` tables in MB:

| phase | A 16 | A 17 | A 18 | B 16 | B 17 | B 18 | C 16 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| rbac | 4.43 / 7 | 4.35 / 7 | 4.38 / 7 | 4.21 / 5.3 | 4.37 / 5.3 | 4.06 / 5.3 | 4.97 / 5.3 | 4.82 / 5.3 | 4.86 / 5.3 |
| sharing | 0.71 / 18.6 | 0.72 / 18.6 | 0.72 / 18.6 | 0.97 / 25.4 | 0.96 / 25.4 | 1.05 / 25.4 | 3.98 / 21.3 | 4 / 21.3 | 4.08 / 21.3 |
| parents_proj | 0.08 / 19.6 | 0.07 / 19.6 | 0.07 / 19.6 | 0.14 / 26.4 | 0.14 / 26.4 | 0.14 / 26.4 | 0.37 / 22.3 | 0.38 / 22.3 | 0.3 / 22.3 |
| parents | 27.22 / 397.6 | 27 / 397.6 | 27.29 / 397.6 | 119.79 / 762.8 | 118.39 / 762.8 | 121.15 / 762.8 | 16.71 / 182.4 | 16.13 / 182.4 | 17.13 / 182.4 |
| nesting | 0.06 / 397.6 | 0.06 / 397.6 | 0.07 / 397.6 | 0.05 / 763.9 | 0.05 / 763.9 | 0.05 / 763.9 | 0.11 / 183.2 | 0.11 / 183.2 | 0.06 / 183.2 |

## Medium, deep shape

The data has 100k documents, 5k users and 50 orgs. The teams are in chains 9 deep, and the users are in the leaf teams. The local equivalent is `<design>-medium-deep.md`.

p50 latency, ms:

| workload | A 16 | A 17 | A 18 | B 16 | B 17 | B 18 | C 16 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rbac_check` | 0.29 | 0.29 | 0.25 | 0.35 | 0.34 | 0.26 | 0.28 | 0.28 | 0.25 |
| `rbac_select_page` | 0.54 | 0.53 | 0.47 | 0.56 | 0.54 | 0.50 | 0.57 | 0.56 | 0.48 |
| `rbac_select_count` | 0.46 | 0.45 | 0.39 | 0.45 | 0.44 | 0.39 | 0.47 | 0.46 | 0.37 |
| `rbac_update_one` | 0.68 | 0.63 | 0.45 | 0.79 | 0.74 | 0.51 | 0.68 | 0.63 | 0.43 |
| `write_assign_role` | 0.17 | 0.16 | 0.15 | 0.16 | 0.15 | 0.14 | 0.22 | 0.20 | 0.18 |
| `share_list_objects` | 0.42 | 0.43 | 0.42 | 0.48 | 0.50 | 0.48 | 0.29 | 0.29 | 0.28 |
| `share_select_page` | 1.52 | 1.57 | 1.42 | 1.65 | 1.74 | 1.68 | 0.89 | 0.82 | 0.77 |
| `write_share` | 0.17 | 0.15 | 0.15 | 0.15 | 0.14 | 0.14 | 0.19 | 0.17 | 0.17 |
| `parents_proj_select_page` | 2.13 | 2.16 | 2.01 | 1.15 | 1.13 | 1.05 | 0.80 | 0.75 | 0.71 |
| `parents_proj_select_count` | 2.46 | 2.48 | 2.25 | 1.49 | 1.47 | 1.31 | 1.11 | 1.11 | 0.97 |
| `parents_select_page` | 48.77 | 49.76 | 47.81 | 12.57 | 11.30 | 10.88 | 5.24 | 4.08 | 3.74 |
| `parents_select_count` | 48.26 | 48.38 | 46.16 | 11.14 | 10.23 | 9.89 | 4.22 | 3.31 | 3.04 |
| `write_nest_team` | 0.16 | 0.15 | 0.15 | 136 | 134 | 124 | 353 | 334 | 307 |
| `nest_check` | 0.49 | 0.66 | 0.63 | 1.31 | 1.34 | 1.18 | 0.32 | 0.32 | 0.30 |

p95 latency, ms:

| workload | A 16 | A 17 | A 18 | B 16 | B 17 | B 18 | C 16 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rbac_check` | 0.42 | 0.37 | 0.34 | 0.44 | 0.46 | 0.34 | 0.35 | 0.35 | 0.34 |
| `rbac_select_page` | 0.68 | 0.66 | 0.58 | 0.69 | 0.74 | 1.17 | 0.69 | 0.68 | 0.62 |
| `rbac_select_count` | 0.69 | 0.54 | 0.47 | 0.55 | 0.55 | 0.49 | 0.58 | 0.56 | 0.47 |
| `rbac_update_one` | 1.10 | 0.82 | 0.64 | 0.95 | 0.94 | 0.66 | 0.85 | 0.80 | 0.54 |
| `write_assign_role` | 0.25 | 0.23 | 0.24 | 0.22 | 0.21 | 0.21 | 0.29 | 0.26 | 0.25 |
| `share_list_objects` | 0.55 | 0.57 | 0.65 | 0.57 | 0.60 | 0.57 | 0.39 | 0.36 | 0.41 |
| `share_select_page` | 2.00 | 1.84 | 1.65 | 1.98 | 2.37 | 1.98 | 1.37 | 1.02 | 1.14 |
| `write_share` | 0.25 | 0.21 | 0.21 | 0.22 | 0.20 | 0.21 | 0.27 | 0.23 | 0.23 |
| `parents_proj_select_page` | 2.87 | 2.55 | 2.43 | 1.43 | 1.33 | 1.24 | 1.19 | 0.93 | 1.07 |
| `parents_proj_select_count` | 3.59 | 2.85 | 2.63 | 1.80 | 1.69 | 1.55 | 1.33 | 1.36 | 1.22 |
| `parents_select_page` | 60.56 | 57.43 | 64.58 | 14.64 | 13.30 | 12.55 | 5.99 | 4.57 | 4.37 |
| `parents_select_count` | 60.12 | 56.88 | 63.50 | 13.14 | 12.44 | 12.13 | 4.89 | 3.79 | 4.07 |
| `write_nest_team` | 0.22 | 0.27 | 0.21 | 198 | 188 | 188 | 460 | 445 | 487 |
| `nest_check` | 0.90 | 0.79 | 0.75 | 1.54 | 1.58 | 1.59 | 0.40 | 0.40 | 0.39 |

Seed seconds / cumulative size of the `permissions` tables in MB:

| phase | A 16 | A 17 | A 18 | B 16 | B 17 | B 18 | C 16 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| rbac | 0.65 / 3.6 | 0.65 / 3.6 | 0.6 / 3.6 | 0.54 / 2.9 | 0.53 / 2.9 | 0.49 / 2.9 | 0.83 / 2.9 | 0.82 / 2.9 | 0.83 / 2.9 |
| sharing | 0.37 / 9.5 | 0.35 / 9.5 | 0.39 / 9.5 | 0.68 / 18 | 0.6 / 18 | 0.6 / 18 | 2.18 / 15 | 2.19 / 15 | 2.13 / 15 |
| parents_proj | 0.04 / 10 | 0.04 / 10 | 0.04 / 10 | 0.08 / 18.5 | 0.08 / 18.5 | 0.08 / 18.5 | 0.19 / 15.5 | 0.18 / 15.5 | 0.16 / 15.5 |
| parents | 2.32 / 47.9 | 2.32 / 47.9 | 2.29 / 47.9 | 11.53 / 92.2 | 11.16 / 92.2 | 11.26 / 92.2 | 1.56 / 31.5 | 1.62 / 31.5 | 1.58 / 31.5 |
| nesting | 0.01 / 47.9 | 0.02 / 47.9 | 0.02 / 47.9 | 0.08 / 94.2 | 0.08 / 94.2 | 0.08 / 94.2 | 0.17 / 33.1 | 0.17 / 33.1 | 0.09 / 33.1 |

## Medium, wide shape

The data has 100k documents, 5k users, 50 orgs and 800 teams. Each user is in 50 teams, and each team has 50 shares. A sample user sees about 10k visible documents. The local equivalent is `<design>-medium-wide.md`.

p50 latency, ms:

| workload | A 16 | A 17 | A 18 | B 16 | B 17 | B 18 | C 16 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rbac_check` | 0.29 | 0.29 | 0.26 | 0.35 | 0.35 | 0.29 | 0.28 | 0.28 | 0.24 |
| `rbac_select_page` | 0.54 | 0.54 | 0.50 | 0.57 | 0.55 | 0.57 | 0.57 | 0.57 | 0.48 |
| `rbac_select_count` | 0.46 | 0.45 | 0.41 | 0.46 | 0.44 | 0.42 | 0.48 | 0.47 | 0.38 |
| `rbac_update_one` | 0.67 | 0.67 | 0.53 | 0.81 | 0.79 | 0.57 | 0.67 | 0.67 | 0.46 |
| `write_assign_role` | 0.17 | 0.16 | 0.16 | 0.17 | 0.15 | 0.15 | 0.22 | 0.20 | 0.17 |
| `share_list_objects` | 24.52 | 26.10 | 29.08 | 8.96 | 9.02 | 11.37 | 4.08 | 4.23 | 4.25 |
| `share_select_page` | 98.57 | 104 | 125 | 33.60 | 33.76 | 36.89 | 9.40 | 9.59 | 10.25 |
| `write_share` | 0.16 | 0.15 | 0.16 | 0.16 | 0.14 | 0.15 | 0.19 | 0.17 | 0.18 |
| `parents_proj_select_page` | 100 | 107 | 123 | 36.23 | 36.70 | 40.74 | 9.61 | 9.75 | 11.07 |
| `parents_proj_select_count` | 99.52 | 106 | 112 | 36.33 | 34.56 | 38.53 | 10.15 | 8.04 | 8.97 |
| `parents_select_page` | 112 | 118 | 118 | 36.87 | 32.93 | 39.31 | 14.27 | 10.85 | 11.80 |
| `parents_select_count` | 113 | 115 | 121 | 35.48 | 31.34 | 41.19 | 12.77 | 9.32 | 9.40 |
| `write_nest_team` | 0.16 | 0.15 | 0.15 | 124 | 134 | 133 | 148 | 174 | 181 |
| `nest_check` | 1.33 | 1.35 | 1.34 | 1.34 | 1.41 | 1.22 | 0.34 | 0.34 | 0.31 |

p95 latency, ms:

| workload | A 16 | A 17 | A 18 | B 16 | B 17 | B 18 | C 16 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rbac_check` | 0.48 | 0.38 | 0.57 | 0.43 | 0.43 | 0.76 | 0.35 | 0.37 | 0.42 |
| `rbac_select_page` | 0.66 | 0.66 | 1.09 | 0.70 | 0.71 | 1.79 | 0.68 | 0.84 | 0.77 |
| `rbac_select_count` | 0.58 | 0.55 | 0.89 | 0.57 | 0.56 | 0.98 | 0.56 | 0.58 | 0.67 |
| `rbac_update_one` | 0.84 | 0.83 | 1.13 | 0.96 | 0.98 | 1.65 | 0.80 | 0.80 | 0.90 |
| `write_assign_role` | 0.25 | 0.23 | 0.35 | 0.25 | 0.23 | 0.34 | 0.29 | 0.26 | 0.28 |
| `share_list_objects` | 30.90 | 31.19 | 39.75 | 10.59 | 11.13 | 18.83 | 4.52 | 4.88 | 6.77 |
| `share_select_page` | 110 | 120 | 157 | 39.60 | 41.40 | 54.82 | 12.27 | 11.73 | 15.66 |
| `write_share` | 0.22 | 0.21 | 0.38 | 0.22 | 0.20 | 0.35 | 0.25 | 0.27 | 0.39 |
| `parents_proj_select_page` | 113 | 134 | 158 | 40.68 | 42.52 | 58.17 | 11.39 | 14.11 | 18.00 |
| `parents_proj_select_count` | 112 | 134 | 142 | 40.25 | 39.11 | 61.77 | 12.36 | 10.20 | 14.63 |
| `parents_select_page` | 129 | 154 | 146 | 42.43 | 38.08 | 51.51 | 16.85 | 12.77 | 18.39 |
| `parents_select_count` | 137 | 139 | 152 | 40.56 | 36.38 | 71.95 | 16.59 | 10.36 | 13.22 |
| `write_nest_team` | 0.23 | 0.21 | 0.29 | 149 | 178 | 193 | 191 | 219 | 231 |
| `nest_check` | 1.69 | 1.58 | 2.09 | 1.54 | 2.93 | 1.90 | 0.43 | 0.42 | 0.48 |

Seed seconds / cumulative size of the `permissions` tables in MB:

| phase | A 16 | A 17 | A 18 | B 16 | B 17 | B 18 | C 16 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| rbac | 0.81 / 3.6 | 0.68 / 3.6 | 0.85 / 3.6 | 0.52 / 2.9 | 0.52 / 2.9 | 0.86 / 2.9 | 0.8 / 2.9 | 0.79 / 2.9 | 0.91 / 2.9 |
| sharing | 6.58 / 97.1 | 6.36 / 97.1 | 7.75 / 97.1 | 20.19 / 225.9 | 20.49 / 225.9 | 26.06 / 225.9 | 181.49 / 191.6 | 183.76 / 191.6 | 176.36 / 191.6 |
| parents_proj | 0.05 / 97.6 | 0.05 / 97.6 | 0.06 / 97.6 | 0.08 / 226.4 | 0.08 / 226.4 | 0.11 / 226.4 | 0.21 / 192.2 | 0.21 / 192.2 | 0.19 / 192.2 |
| parents | 2.6 / 135.4 | 2.45 / 135.4 | 2.71 / 135.4 | 11.41 / 300 | 11.1 / 300 | 13.98 / 300 | 1.61 / 208.2 | 1.53 / 208.2 | 1.95 / 208.2 |
| nesting | 0.03 / 135.4 | 0.04 / 135.4 | 0.04 / 135.4 | 0.05 / 301.1 | 0.06 / 301.1 | 0.06 / 301.1 | 0.07 / 209.1 | 0.08 / 209.1 | 0.1 / 209.1 |

## What changed between versions

This section lists only the measured differences that are bigger than 20%. A difference must be consistent across designs, or consistent for one design across all three configurations. A ratio is the p50 on the version divided by the p50 on 16, for the same design and configuration (below 1 means faster). The full ratio tables are at the end of this section.

1. **Postgres 18: `rbac_update_one` is 21-37% faster on every design.** The ratios are 0.63-0.79 in all 9 cells of design × configuration (large: A 0.67 → 0.53 ms, B 0.81 → 0.52, C 0.66 → 0.45). The preset SQL is the same on every design: an `update` of one document under the RBAC policy. So the cause is Postgres, not a design. On 17 the same workload is within 7% of 16.
2. **Postgres 18: the other RBAC reads are faster by up to 26%, typically 10-15%.** Most cells are below the threshold of 20%, except `rbac_check` of B. Almost every cell shows a gain. `rbac_check` 0.74-0.90 (B gains most: 0.74, 0.74, 0.83), `rbac_select_page` 0.84-1.00, `rbac_select_count` 0.79-0.91. The admin writes `write_assign_role` and `write_share` are about 10% faster on both 17 and 18 (0.77-1.00).
3. **Postgres 17 and 18: the single-branch parents queries of C are faster.** `parents_select_count` of C: 0.73-0.78 on 17 and 0.72-0.74 on 18 in all three configurations (large: 23.1 → 18.1 → 16.9 ms). `parents_select_page` of C: 0.76-0.78 on 17 and 0.71-0.83 on 18 at medium, but at large only 0.98 on 17 and 0.87 on 18. A is unchanged (0.96-1.08) and B is mixed (0.87-1.16). These queries return every visible document id from one call (`accessible()` of C). We did not investigate what in 17 makes this faster for C only.
4. **Otherwise, 17 is within ±7% of 16 on almost every workload.** There are two more exceptions, each in one configuration only. They are the single-branch parents of B (0.88-0.92) and `parents_proj_select_count` of C at medium wide (0.79). Seeds that take more than a second take the same time on every version (±5%).

   The exceptions are the medium wide sharing seeds of A and B on 18 (+18%, +29%). They ran in the disturbed window that the text notes below. The table sizes after each seed are identical on all three versions.

We saw these effects once, and we did not confirm them:

- **Medium wide on 18, A and B:** The sharing and `parents_proj` reads are 10-27% slower than 16. For example, B `share_list_objects` is 8.96 → 11.37 ms and A `share_select_page` is 98.6 → 124.5 ms. The pg18 wide runs (08:58-09:35) coincided with other activity on the host. Every run in that window has RBAC p95 values about 2x their p50. Four repeat runs (below) moved by up to 20% between runs, which is the size of this effect. Treat it as noise until someone repeats the runs on a quiet machine.
- **`write_nest_team` of C on medium wide:** 18-22% slower on 17 and 18 (148 → 175 → 181 ms), only in this configuration.
- **`nest_check` of A on medium deep:** The p50 is 29-35% higher on 17 and 18 (0.49 → 0.66 ms). But the p95 is lower (0.90 → 0.79, 0.75). At large, 18 is 22% faster. The results are not consistent, so we treat them as noise.

### Repeatability

To check the medium wide outliers, we repeated four runs right after the matrix: pg16 and pg18 × A and B. The checksums were identical. The p50 values moved by up to 20% between the two runs of the same configuration. Three examples: pg16 A `share_select_page` 98.6 → 113.9 ms, pg16 B `parents_select_count` 35.5 → 43.0, and pg18 B `parents_select_count` 41.2 → 33.7.

The original pg18 A medium wide run had a disturbance in its parents phase. In that run `parents_proj_select_page` had p50 159 ms and p95 512 ms. The repeat did not show this (123 and 158 ms). The published pg18 A medium wide numbers are from the repeat (09:25).

The other 26 published runs are the matrix runs. One run for each configuration resolves differences of about 20% on these heavy, wide-shape reads. It resolves differences of about 10% on the RBAC workloads and on the large and deep workloads.

### Budgets by version

We compare the results with [`bench/budgets.tsv`](../../bench/budgets.tsv). The large default results change between versions only on `parents_proj_select_count` (budget 9 ms), and only at the margin. B is over on 16 and 17 (p95 9.97, 9.15) and under on 18 (8.46). C is over on 16 (9.50) and under on 17 and 18 (8.94, 8.50).

A is over on all three (10.3-12.1). Every Docker run, on every version, is over this budget or within 10% of it. The local 16.4 runs passed it with room to spare (2.9-5.6 ms). This is the minor-release change that Calibration describes, not an effect of the major version. The other large budgets pass and fail in the same way on 16, 17 and 18.

At medium wide, the p95 values of B are close to many budgets (`share_*`, `parents_*`, `nest_check`). The pg16 run passes 4 that the pg18 run misses. But the repeat runs of both versions miss most of them, so this is noise around the budget, not an effect of the version.

### Ratio tables

Large, default shape:

| workload | A 17 | A 18 | B 17 | B 18 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rbac_check` | 0.97 | 0.87 | 1.00 | 0.74 | 1.00 | 0.89 |
| `rbac_select_page` | 0.99 | 0.90 | 0.99 | 0.92 | 1.01 | 0.86 |
| `rbac_select_count` | 0.97 | 0.91 | 0.95 | 0.90 | 0.98 | 0.87 |
| `rbac_update_one` | 1.03 | 0.79 | 0.93 | 0.64 | 1.08 | 0.68 |
| `write_assign_role` | 0.94 | 0.94 | 0.88 | 0.82 | 0.91 | 0.82 |
| `share_list_objects` | 1.03 | 0.97 | 1.00 | 0.94 | 1.00 | 0.93 |
| `share_select_page` | 1.01 | 0.94 | 0.99 | 0.93 | 1.00 | 0.90 |
| `write_share` | 0.94 | 0.94 | 0.88 | 0.88 | 0.89 | 0.89 |
| `parents_proj_select_page` | 1.03 | 0.95 | 0.98 | 0.92 | 0.97 | 0.94 |
| `parents_proj_select_count` | 0.98 | 0.94 | 0.98 | 0.93 | 0.97 | 0.91 |
| `parents_select_page` | 1.02 | 0.99 | 0.99 | 1.07 | 0.98 | 0.87 |
| `parents_select_count` | 1.02 | 1.03 | 0.97 | 1.05 | 0.78 | 0.73 |
| `write_nest_team` | 0.94 | 0.94 | 1.04 | 0.99 | 1.01 | 1.00 |
| `nest_check` | 1.03 | 0.78 | 1.01 | 0.88 | 1.00 | 0.91 |

Medium, deep shape:

| workload | A 17 | A 18 | B 17 | B 18 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rbac_check` | 1.00 | 0.86 | 0.97 | 0.74 | 1.00 | 0.89 |
| `rbac_select_page` | 0.98 | 0.87 | 0.96 | 0.89 | 0.98 | 0.84 |
| `rbac_select_count` | 0.98 | 0.85 | 0.98 | 0.87 | 0.98 | 0.79 |
| `rbac_update_one` | 0.93 | 0.66 | 0.94 | 0.65 | 0.93 | 0.63 |
| `write_assign_role` | 0.94 | 0.88 | 0.94 | 0.88 | 0.91 | 0.82 |
| `share_list_objects` | 1.02 | 1.00 | 1.04 | 1.00 | 1.00 | 0.97 |
| `share_select_page` | 1.03 | 0.93 | 1.05 | 1.02 | 0.92 | 0.87 |
| `write_share` | 0.88 | 0.88 | 0.93 | 0.93 | 0.89 | 0.89 |
| `parents_proj_select_page` | 1.01 | 0.94 | 0.98 | 0.91 | 0.94 | 0.89 |
| `parents_proj_select_count` | 1.01 | 0.91 | 0.99 | 0.88 | 1.00 | 0.87 |
| `parents_select_page` | 1.02 | 0.98 | 0.90 | 0.87 | 0.78 | 0.71 |
| `parents_select_count` | 1.00 | 0.96 | 0.92 | 0.89 | 0.78 | 0.72 |
| `write_nest_team` | 0.94 | 0.94 | 0.98 | 0.91 | 0.95 | 0.87 |
| `nest_check` | 1.35 | 1.29 | 1.02 | 0.90 | 1.00 | 0.94 |

Medium, wide shape:

| workload | A 17 | A 18 | B 17 | B 18 | C 17 | C 18 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rbac_check` | 1.00 | 0.90 | 1.00 | 0.83 | 1.00 | 0.86 |
| `rbac_select_page` | 1.00 | 0.93 | 0.96 | 1.00 | 1.00 | 0.84 |
| `rbac_select_count` | 0.98 | 0.89 | 0.96 | 0.91 | 0.98 | 0.79 |
| `rbac_update_one` | 1.00 | 0.79 | 0.98 | 0.70 | 1.00 | 0.69 |
| `write_assign_role` | 0.94 | 0.94 | 0.88 | 0.88 | 0.91 | 0.77 |
| `share_list_objects` | 1.06 | 1.19 | 1.01 | 1.27 | 1.04 | 1.04 |
| `share_select_page` | 1.05 | 1.26 | 1.00 | 1.10 | 1.02 | 1.09 |
| `write_share` | 0.94 | 1.00 | 0.88 | 0.94 | 0.89 | 0.95 |
| `parents_proj_select_page` | 1.06 | 1.22 | 1.01 | 1.12 | 1.01 | 1.15 |
| `parents_proj_select_count` | 1.06 | 1.12 | 0.95 | 1.06 | 0.79 | 0.88 |
| `parents_select_page` | 1.05 | 1.05 | 0.89 | 1.07 | 0.76 | 0.83 |
| `parents_select_count` | 1.02 | 1.08 | 0.88 | 1.16 | 0.73 | 0.74 |
| `write_nest_team` | 0.94 | 0.94 | 1.07 | 1.07 | 1.18 | 1.22 |
| `nest_check` | 1.02 | 1.01 | 1.05 | 0.91 | 1.00 | 0.91 |

## Calibration: Docker 16.15 against local 16.4

The first table shows the ratio of the Docker pg16 p50 (or p95) to the local Postgres.app 16.4 p50 (or p95). The design and the configuration are the same. There are 9 pairs for each workload (3 designs × 3 configurations). A value above 1 means that Docker is slower.

| workload | median p50 ratio | p50 range | median p95 ratio | p95 range | n |
| --- | ---: | ---: | ---: | ---: | ---: |
| `rbac_check` | 1.07 | 1.06-1.22 | 1.13 | 0.84-1.33 | 9 |
| `rbac_select_page` | 1.19 | 1.02-1.35 | 1.21 | 1.05-1.83 | 9 |
| `rbac_select_count` | 1.12 | 0.98-1.24 | 1.16 | 0.83-1.55 | 9 |
| `rbac_update_one` | 0.99 | 0.77-1.03 | 1.05 | 0.87-1.29 | 9 |
| `write_assign_role` | 1.10 | 1.00-1.21 | 0.89 | 0.83-1.04 | 9 |
| `share_list_objects` | 0.80 | 0.35-1.22 | 0.84 | 0.38-1.30 | 9 |
| `share_select_page` | 0.81 | 0.45-1.17 | 0.89 | 0.41-1.51 | 9 |
| `write_share` | 1.14 | 1.07-1.19 | 0.93 | 0.85-1.00 | 9 |
| `parents_proj_select_page` | 0.84 | 0.45-1.11 | 0.75 | 0.46-1.16 | 9 |
| `parents_proj_select_count` | 1.18 | 0.45-3.03 | 1.24 | 0.47-3.28 | 9 |
| `parents_select_page` | 0.48 | 0.42-1.12 | 0.51 | 0.45-1.24 | 9 |
| `parents_select_count` | 0.49 | 0.39-1.10 | 0.54 | 0.42-1.25 | 9 |
| `write_nest_team` | 1.00 | 0.38-1.07 | 0.88 | 0.39-1.10 | 9 |
| `nest_check` | 0.60 | 0.48-1.27 | 0.96 | 0.50-1.23 | 9 |

The second table shows the p50 ratio for each configuration and design:

| workload | large default A | large default B | large default C | medium deep A | medium deep B | medium deep C | medium wide A | medium wide B | medium wide C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rbac_check` | 1.07 | 1.06 | 1.22 | 1.07 | 1.09 | 1.22 | 1.07 | 1.06 | 1.22 |
| `rbac_select_page` | 1.25 | 1.35 | 1.33 | 1.02 | 1.19 | 1.16 | 1.02 | 1.21 | 1.16 |
| `rbac_select_count` | 1.12 | 1.24 | 1.21 | 0.98 | 1.07 | 1.09 | 0.98 | 1.12 | 1.14 |
| `rbac_update_one` | 0.77 | 1.03 | 0.97 | 0.85 | 0.99 | 1.00 | 0.82 | 1.01 | 1.03 |
| `write_assign_role` | 1.00 | 1.21 | 1.10 | 1.06 | 1.14 | 1.10 | 1.00 | 1.21 | 1.10 |
| `share_list_objects` | 0.67 | 1.00 | 1.22 | 0.61 | 0.80 | 1.21 | 0.38 | 0.35 | 1.09 |
| `share_select_page` | 0.77 | 1.03 | 1.17 | 0.62 | 0.81 | 1.16 | 0.45 | 0.48 | 0.88 |
| `write_share` | 1.07 | 1.14 | 1.19 | 1.13 | 1.07 | 1.19 | 1.07 | 1.14 | 1.19 |
| `parents_proj_select_page` | 0.69 | 0.98 | 1.11 | 0.61 | 0.84 | 1.07 | 0.45 | 0.49 | 0.86 |
| `parents_proj_select_count` | 1.82 | 2.61 | 3.03 | 0.69 | 1.10 | 1.54 | 0.45 | 0.53 | 1.18 |
| `parents_select_page` | 0.47 | 0.48 | 1.12 | 0.49 | 0.43 | 1.07 | 0.47 | 0.42 | 1.04 |
| `parents_select_count` | 0.49 | 0.51 | 1.05 | 0.49 | 0.39 | 1.00 | 0.48 | 0.41 | 1.10 |
| `write_nest_team` | 1.07 | 0.38 | 0.90 | 1.07 | 0.44 | 1.00 | 1.07 | 0.39 | 1.02 |
| `nest_check` | 0.96 | 0.50 | 1.27 | 0.56 | 0.52 | 1.19 | 0.60 | 0.48 | 1.21 |

What the tables show:

- **Cheap preset operations are 0-35% slower in Docker** (`rbac_*`, `write_assign_role`, `write_share`: median 0.99-1.19). This is a fixed overhead of 0.01-0.2 ms for each transaction.
- **The design paths of C are about the same** (0.86-1.27), except `parents_proj_select_count`.
- **The expensive PL/pgSQL paths of A and B are about 2x faster in Docker.** These are the single-branch parents (0.39-0.51), `write_nest_team` of B (0.38-0.44), `nest_check` of B (0.48-0.52), and the sharing and projection reads of the wide shape (0.35-0.62). The plans are identical. For `parents_select_page` of A at large, EXPLAIN ANALYZE shows the same nodes and almost the same buffers (180,360 local, 179,861 Docker). But the execution takes 209 ms against 98 ms, and the planning takes 213 ms against 125 ms.
- **The cause of the 2x difference is not JIT.** The packages of Docker include LLVM JIT, and Postgres.app 16 does not. But when we turned JIT off in Docker, nothing changed in a material way. `parents_select_page` of A was 260 against 286 ms, and `parents_proj_select_count` was 9.65 against 9.85 ms. The other differences are the OS (macOS against Linux in the Docker VM) and the build (Postgres.app against Debian PGDG packages). We did not isolate which one is responsible.
- **`parents_proj_select_count` at large is 1.8-3.0x slower in Docker, on every design. The cause is a Postgres minor release, not Docker.** Both environments use the same plan: a bitmap heap scan over about 10,900 heap pages of `documents` that are all visible. On 16.4 the scan reads 1,180 buffers (6.0 ms).

  On 16.15 it reads 11,996 buffers (17.0 ms). Postgres 16.4 skips the heap fetch for all-visible pages when the query needs no columns (`count(*)`), and 16.15 does not. This matches the removal of the skip-fetch optimization of the bitmap heap scan in later minor releases.
- **Any current Postgres release pays this cost.** Postgres 17.11 and 18.6 show the same timing (7.5-9 ms on every design). So the local 16.4 number for this workload is optimistic. At medium the scan is 10x smaller. C still shows 1.5x at medium deep, and for A and B the 2x speedup of Docker hides the effect.

**Advice for readers:** Compare versions within Docker, or compare designs within one environment. Do not compare a Docker number with a local number for the same workload without the ratio above. The order of the designs is the same in both environments. The exception is where the 2x PL/pgSQL effect narrows the gap between C and A or B. For example, `nest_check` of B at large takes 2.6 ms local and 1.3 ms in Docker, against 0.33 ms for C.

## Caveats

- **One run for each configuration**, 10 s for each workload. See Repeatability for the noise.
- **The host was not idle.** Desktop apps kept the load average around 6 on 10 cores. Other Docker containers (an idle Supabase stack) ran in the same VM. The 4-CPU limit and the separate client container isolate the run from the CPUs, but not from the memory bandwidth or the caches.
- **The minor versions differ.** The local baselines are 16.4, and Docker is 16.15, 17.11 and 18.6. Calibration shows one minor-release effect. There can be others.
- **Docker is not production either.** It is Linux in a VM on a laptop, with `fsync=off` and `full_page_writes=off`, and every write rolled back. The write numbers are optimistic in both environments.
- **The budgets** come from the local 16.4 runs. We did not derive them again from Docker.
- The pg_tle install path (`test/spec/03_tle_install.sql`) passes on all three versions for A, B and C. The command was `docker/run-matrix.sh test`. The results at the time of that run were A 14/14 files, B 15/15 and C 17/17 on each version. The current suites are A 18/18, B 18/18 and C 21/21, and [OPTIMIZATIONS.md](./OPTIMIZATIONS.md) records that they pass on all three versions. The benchmark installs the designs with plain `psql -f`, not through pg_tle.
