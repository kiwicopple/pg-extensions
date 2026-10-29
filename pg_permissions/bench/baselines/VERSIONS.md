# Postgres 16, 17 and 18 (Docker)

Serial runs on 2026-10-29 of all three engines on Postgres 16.15, 17.11 and 18.6, each with pg_tle 1.5.3, in Docker on the same Apple M4 laptop that produced the local Postgres 16.4 baselines in [`COMPARISON.md`](./COMPARISON.md). Setup: [`../../docker/README.md`](../../docker/README.md). One server at a time (`docker/run-matrix.sh bench`), `cpus: 4`, `mem_limit: 6g`, the same settings as the local throwaway cluster (`fsync=off`, `full_page_writes=off`, initdb defaults), pgbench in a separate client container over the Unix socket, 4 clients, 10 s per workload. Three groups of 9 runs (3 versions × 3 engines): large default, medium deep and medium wide. Wall clock: 32, 22 and 34 minutes.

These are the engines before the session 3 optimizations; the same matrix with the optimized engines is in [`OPTIMIZATIONS.md`](./OPTIMIZATIONS.md) (`*-opt` files). Each run's full report (plans, per-table storage, per-user checksums) is `pg<NN>-docker-<design>-<scale>-<shape>.md` in this directory, and its numbers are in `data/<same name>.json`. The engine comparison itself is in [`COMPARISON.md`](./COMPARISON.md); this file is only about what changes with the Postgres version and with the environment.

**Summary.** Every run completed and every engine returns the same visible documents on every version. Postgres 17 performs like 16 on these workloads. Postgres 18 is typically 10-15% faster on the RBAC reads and 21-37% faster on `rbac_update_one`, for all three engines. C's single-branch parents count is 22-28% faster on 17 and 18 than on 16; A's and B's aren't. No slowdown on 17 or 18 holds up across configurations. The engine ordering on each workload is the same on every version, except where engines were already within about 0.05 ms of each other. Docker and local numbers are not interchangeable: for the same Postgres major they differ by up to 2x in either direction depending on the workload (see Calibration).

## Checksums

For each configuration, the per-policy checksums (md5 over the 8 sample users' visible-document count and md5 of sorted ids, see `data/README.md`) are identical across A, B and C, across 16, 17 and 18, and equal to the local 16.4 runs: 12 runs per configuration, one distinct value per policy.

| configuration | rbac | sharing | parents_proj | parents |
| --- | --- | --- | --- | --- |
| large default | `2e1dd348` | `58a66d1d` | `bffa5242` | `bffa5242` |
| medium deep | `d394663f` | `7cf80111` | `3261b092` | `3261b092` |
| medium wide | `d394663f` | `6f7c008d` | `f2867b7f` | `f2867b7f` |

## Large, default shape

1M documents, 10k users, 100 orgs, 500 teams (4-ary tree), 1 team per user, 5 shares per team. A sample user sees about 20k documents. Local equivalent: `<design>-large-default.md`.

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

100k documents, 5k users, 50 orgs; teams in chains 9 deep, users in the leaf teams. Local equivalent: `<design>-medium-deep.md`.

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

100k documents, 5k users, 50 orgs, 800 teams; each user in 50 teams, 50 shares per team, about 10k visible documents per sample user. Local equivalent: `<design>-medium-wide.md`.

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

Only measured differences that are bigger than 20% and either consistent across engines or consistent for one engine across all three configurations. Ratios are p50 on the version divided by p50 on 16, same engine, same configuration (below 1 means faster). The full ratio tables are at the end of this section.

1. **Postgres 18: `rbac_update_one` is 21-37% faster on every engine.** Ratios 0.63-0.79 in all 9 engine × configuration cells (large: A 0.67 → 0.53 ms, B 0.81 → 0.52, C 0.66 → 0.45). It's the same preset SQL on every engine (an `update` of one document under the RBAC policy), so this is Postgres, not an engine. On 17 the same workload is within 7% of 16.
2. **Postgres 18: the other RBAC reads are faster by up to 26%, typically 10-15%**, below the threshold except for B's `rbac_check` but in almost every cell: `rbac_check` 0.74-0.90 (B gains most: 0.74, 0.74, 0.83), `rbac_select_page` 0.84-1.00, `rbac_select_count` 0.79-0.91. The admin writes `write_assign_role` and `write_share` are about 10% faster on both 17 and 18 (0.77-1.00).
3. **Postgres 17 and 18: C's single-branch parents queries are faster.** C's `parents_select_count`: 0.73-0.78 on 17 and 0.72-0.74 on 18 in all three configurations (large: 23.1 → 18.1 → 16.9 ms). C's `parents_select_page`: 0.76-0.78 on 17 and 0.71-0.83 on 18 at medium, but at large only 0.98 on 17 and 0.87 on 18. A is unchanged (0.96-1.08) and B mixed (0.87-1.16). These queries return every visible document id from one engine call (C's `accessible()`); what in 17 makes that faster for C only was not investigated.
4. **Otherwise, 17 is within ±7% of 16 on almost every workload** (the exceptions besides the above: B's single-branch parents 0.88-0.92 and C's medium wide `parents_proj_select_count` 0.79, each in one configuration only). Seeds that take more than a second take the same time on every version (±5%), except A's and B's medium wide sharing seeds on 18 (+18%, +29%), which ran in the disturbed window noted below. Table sizes after each seed are identical on all three versions.

Seen once, not confirmed:

- **Medium wide on 18, A and B:** sharing and `parents_proj` reads 10-27% slower than 16 (e.g. B `share_list_objects` 8.96 → 11.37 ms, A `share_select_page` 98.6 → 124.5 ms). The pg18 wide runs (08:58-09:35) coincided with other activity on the host: every run in that window has RBAC p95s about 2x their p50. Four repeat runs (below) moved by up to 20% between runs, the size of this effect. Treat as noise until repeated on a quiet machine.
- **C's `write_nest_team` on medium wide:** 18-22% slower on 17 and 18 (148 → 175 → 181 ms), only in this configuration.
- **A's `nest_check` on medium deep:** p50 29-35% higher on 17 and 18 (0.49 → 0.66 ms), but p95 is lower (0.90 → 0.79, 0.75), and at large 18 is 22% faster. Inconsistent, so noise.

### Repeatability

To check the medium wide outliers, four runs were repeated right after the matrix: pg16 and pg18 × A and B. Checksums were identical. p50s moved by up to 20% between the two runs of the same configuration (pg16 A `share_select_page` 98.6 → 113.9 ms, pg16 B `parents_select_count` 35.5 → 43.0, pg18 B `parents_select_count` 41.2 → 33.7). The original pg18 A medium wide run had a disturbance in its parents phase (`parents_proj_select_page` p50 159 ms, p95 512 ms) that the repeat didn't show (123 and 158 ms); the published pg18 A medium wide numbers are from the repeat (09:25). The other 26 published runs are the matrix runs. One run per configuration resolves differences of about 20% on these heavy, wide-shape reads and about 10% on the RBAC and large/deep workloads.

### Budgets by version

Against `bench/budgets.tsv`, the large default results only change between versions on `parents_proj_select_count` (9 ms budget), and only at the margin: B is over on 16 and 17 (p95 9.97, 9.15) and under on 18 (8.46); C is over on 16 (9.50) and under on 17 and 18 (8.94, 8.50); A is over on all three (10.3-12.1). Every Docker run, on every version, is over this budget or within 10% of it, while the local 16.4 runs passed it with room to spare (2.9-5.6 ms): that's the minor-release change described under Calibration, not a major-version effect. The other large budgets pass and fail the same way on 16, 17 and 18. At medium wide, B's p95s sit close to several budgets (`share_*`, `parents_*`, `nest_check`): the pg16 run passes 4 that the pg18 run misses, but the repeat runs of both versions miss most of them, so that's noise around the budget, not a version effect.

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

## Calibration: Docker 16.15 vs local 16.4

Ratio of the Docker pg16 p50 (or p95) to the local Postgres.app 16.4 p50 (or p95), same engine and configuration; 9 pairs per workload (3 engines × 3 configurations). Above 1 means Docker is slower.

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

Per configuration and engine (p50 ratio):

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

What it shows:

- **Cheap preset operations are 0-35% slower in Docker** (`rbac_*`, `write_assign_role`, `write_share`: median 0.99-1.19). That's a fixed overhead of 0.01-0.2 ms per transaction.
- **C's engine paths are about the same** (0.86-1.27), apart from `parents_proj_select_count`.
- **A's and B's expensive PL/pgSQL paths are about 2x faster in Docker**: single-branch parents (0.39-0.51), B's `write_nest_team` (0.38-0.44) and `nest_check` (0.48-0.52), and the wide-shape sharing and projection reads (0.35-0.62). The plans are identical. For A's `parents_select_page` at large, EXPLAIN ANALYZE shows the same nodes and almost the same buffers (180,360 local, 179,861 Docker), but 209 ms vs 98 ms execution and 213 ms vs 125 ms planning. JIT is ruled out: Docker's packages include LLVM JIT and Postgres.app 16 doesn't, but turning it off in Docker changed nothing material (A `parents_select_page` 260 vs 286 ms, `parents_proj_select_count` 9.65 vs 9.85 ms). The remaining differences are the OS (macOS vs Linux in the Docker VM) and the build (Postgres.app vs Debian PGDG packages). Which one is responsible wasn't isolated.
- **`parents_proj_select_count` at large is 1.8-3.0x slower in Docker, on every engine, because of a Postgres minor release rather than Docker.** Same plan in both: a bitmap heap scan over about 10,900 heap pages of `documents` that are all visible. On 16.4 the scan reads 1,180 buffers (6.0 ms), and on 16.15 it reads 11,996 (17.0 ms). 16.4 skips the heap fetch for all-visible pages when the query needs no columns (`count(*)`), and 16.15 doesn't. That matches the removal of the bitmap heap scan's skip-fetch optimization in later minor releases. 17.11 and 18.6 show the same timing (7.5-9 ms on every engine). Any current Postgres release pays this cost, so the local 16.4 number for this workload is optimistic. At medium the scan is 10x smaller: C still shows 1.5x at medium deep, and for A and B the 2x Docker speedup hides it.

**For readers:** compare versions within Docker, or engines within one environment. Don't compare a Docker number with a local one for the same workload without the ratio above. The engine ranking is the same in both environments, except where the 2x PL/pgSQL effect narrows the gap between C and A or B (for example B `nest_check` at large: 2.6 ms local, 1.3 ms Docker, against C's 0.33).

## Caveats

- **One run per configuration**, 10 s per workload. See Repeatability for the noise.
- **The host was not idle**: desktop apps kept the load average around 6 on 10 cores, and other Docker containers (an idle Supabase stack) were running in the same VM. The server's 4-CPU limit and the separate client container isolate the run from the CPUs, not from the memory bandwidth or caches.
- **Minor versions differ**: the local baselines are 16.4 and Docker is 16.15, 17.11, 18.6. Calibration shows one minor-release effect; there may be others.
- **Docker isn't production either**: Linux in a VM on a laptop, `fsync=off`, `full_page_writes=off`, every write rolled back. Write numbers are optimistic in both environments.
- **Budgets** were set from the local 16.4 runs; they have not been re-derived from Docker.
- The pg_tle install path (`test/spec/03_tle_install.sql`) passes on all three versions for A, B and C (`docker/run-matrix.sh test`: A 14/14 files, B 15/15, C 17/17 on each version). The benchmark installs the engines with plain `psql -f`, not through pg_tle.
