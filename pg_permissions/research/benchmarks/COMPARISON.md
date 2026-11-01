# Engine comparison: A (tuple core), B (policy first), C (compiled model)

These are serial runs of 2026-10-28/29, after the `_parent_keys` row-estimate fix of B and the tenant-parent change of C (commit `cc64196`). We ran one design at a time on an otherwise idle machine, 10 s for each workload, with 4 pgbench clients. The full report of each run (plans, per-table storage, per-user checksums) is `<design>-<scale>-<shape>.md` in [`../../bench/baselines/`](../../bench/baselines/). The file `a-large-default-session1.md` is the session-1 run of A (before the shared data shape, the rollbacks and the extra phases). We keep it for history only. Do not compare it directly.

Read the workloads in this way (see Benchmarks in [`../../test/README.md`](../../test/README.md)):

- `rbac_*` and `write_assign_role`: tenant RBAC through the preset API. The SQL is the same on every design.
- `share_*` and `write_share`: per-document sharing with nested teams, a two-branch policy (`org_id` arm or shared ids), native API.
- `parents_proj_*`: org → folder → document. Documents link to folders only through the app column `folder_id`. The policy is `id = any(<shared with me>) or folder_id = any(<folders I can view>)`.
- `parents_*` (no `proj`): a parent link for each document in the tables of the design. The policy has a single branch, and one call returns every visible document id.
- `write_nest_team`: nest a team of 1,000 members into a random team, rolled back. `nest_check`: one check for a user who reaches a document only through that nesting.
- All writes roll back, so the data never changes between designs.

## Checksum agreement

For every run below, the visible-document count of each user and the md5 of the sorted ids were identical across A, B and C. This holds for all four read policies (rbac, sharing, parents_proj, parents) and for all 8 sample users. Within each design, parents_proj and parents gave the same set for every user. Both equal sharing for users that are not folder viewers. The lists of counts are in the section of each group.

## Large, default shape

The data has 1M documents, 10k users, 100 orgs and 500 teams (4-ary tree, about 5 levels). Each user has 1 team, and each team has 5 shares. A sample user sees about 20k documents.

Latency, ms:

| workload | A p50 | B p50 | C p50 | A p95 | B p95 | C p95 |
| --- | --- | --- | --- | --- | --- | --- |
| `rbac_check` | 0.28 | 0.33 | 0.23 | 0.35 | 0.48 | 0.34 |
| `rbac_select_page` | 0.67 | 0.62 | 0.64 | 0.77 | 0.99 | 0.80 |
| `rbac_select_count` | 0.83 | 0.76 | 0.78 | 0.92 | 0.82 | 0.87 |
| `rbac_update_one` | 0.87 | 0.79 | 0.68 | 1.06 | 0.86 | 0.80 |
| `write_assign_role` | 0.17 | 0.14 | 0.20 | 0.28 | 0.24 | 0.34 |
| `share_list_objects` | 0.52 | 0.31 | 0.23 | 0.84 | 0.38 | 0.35 |
| `share_select_page` | 2.02 | 1.21 | 0.95 | 2.28 | 1.41 | 1.22 |
| `write_share` | 0.15 | 0.14 | 0.16 | 0.25 | 0.25 | 0.28 |
| `parents_proj_select_page` | 3.20 | 1.44 | 1.01 | 3.71 | 1.66 | 1.29 |
| `parents_proj_select_count` | 5.00 | 3.21 | 2.72 | 5.58 | 3.39 | 2.90 |
| `parents_select_page` | 509.43 | 197.22 | 9.57 | 560.66 | 251.96 | 10.34 |
| `parents_select_count` | 536.39 | 226.11 | 22.08 | 579.85 | 266.63 | 23.25 |
| `write_nest_team` | 0.15 | 285.44 | 333.48 | 0.24 | 325.98 | 384.19 |
| `nest_check` | 0.70 | 2.60 | 0.26 | 0.79 | 2.83 | 0.34 |

The next table shows the seed time (native-API load only) and the cumulative size of the `permissions` tables after each phase, after VACUUM FULL:

| phase | A seed s | B seed s | C seed s | A MB (rows) | B MB (rows) | C MB (rows) |
| --- | --- | --- | --- | --- | --- | --- |
| rbac | 4.88 | 4.56 | 4.95 | 7.0 (20020) | 5.3 (20028) | 5.3 (20053) |
| sharing | 1.18 | 1.71 | 4.08 | 18.6 (54022) | 25.4 (99977) | 21.3 (98346) |
| parents_proj | 0.14 | 0.22 | 0.39 | 19.6 (57025) | 26.4 (103981) | 22.3 (102365) |
| parents | 44.02 | 167.23 | 16.22 | 397.6 (1057026) | 762.8 (3103981) | 182.4 (1102365) |
| nesting | 0.06 | 0.11 | 0.14 | 397.6 (1057027) | 763.9 (3108987) | 183.2 (1107366) |

Checksums (visible documents per sample user):

- rbac: identical across A, B, C (1: 20000, 2: 20000, 3: 20000, 5: 20000, 10: 20000, 77: 20000, 500: 20000, 10000: 20000)
- sharing: identical across A, B, C (1: 20007, 2: 20007, 3: 20012, 5: 20012, 10: 20012, 77: 20022, 500: 20007, 10000: 20007)
- parents_proj: identical across A, B, C (1: 20007, 2: 20007, 3: 20012, 5: 21012, 10: 21012, 77: 20022, 500: 21007, 10000: 21007)
- parents: identical across A, B, C (1: 20007, 2: 20007, 3: 20012, 5: 21012, 10: 21012, 77: 20022, 500: 21007, 10000: 21007)

## Medium, default shape

The data has 100k documents, 5k users, 50 orgs and 200 teams. A sample user sees about 4k documents.

Latency, ms:

| workload | A p50 | B p50 | C p50 | A p95 | B p95 | C p95 |
| --- | --- | --- | --- | --- | --- | --- |
| `rbac_check` | 0.27 | 0.33 | 0.22 | 0.37 | 0.55 | 0.29 |
| `rbac_select_page` | 0.53 | 0.48 | 0.49 | 0.63 | 0.56 | 0.63 |
| `rbac_select_count` | 0.47 | 0.42 | 0.43 | 0.56 | 0.53 | 0.52 |
| `rbac_update_one` | 0.82 | 0.80 | 0.67 | 0.97 | 1.08 | 0.89 |
| `write_assign_role` | 0.17 | 0.15 | 0.21 | 0.29 | 0.26 | 0.39 |
| `share_list_objects` | 0.45 | 0.30 | 0.22 | 0.60 | 0.44 | 0.29 |
| `share_select_page` | 1.53 | 0.89 | 0.69 | 1.73 | 0.99 | 0.81 |
| `write_share` | 0.15 | 0.14 | 0.16 | 0.26 | 0.24 | 0.29 |
| `parents_proj_select_page` | 2.57 | 1.05 | 0.66 | 3.01 | 1.29 | 0.82 |
| `parents_proj_select_count` | 2.62 | 1.08 | 0.68 | 3.06 | 1.75 | 0.78 |
| `parents_select_page` | 99.57 | 28.78 | 4.61 | 109.11 | 31.79 | 5.21 |
| `parents_select_count` | 98.91 | 28.09 | 3.90 | 115.06 | 30.69 | 4.38 |
| `write_nest_team` | 0.15 | 219.77 | 272.03 | 0.25 | 240.84 | 306.48 |
| `nest_check` | 0.66 | 2.36 | 0.26 | 0.77 | 2.58 | 0.33 |

The next table shows the seed time (native-API load only) and the cumulative size of the `permissions` tables after each phase, after VACUUM FULL:

| phase | A seed s | B seed s | C seed s | A MB (rows) | B MB (rows) | C MB (rows) |
| --- | --- | --- | --- | --- | --- | --- |
| rbac | 0.80 | 0.66 | 0.86 | 3.6 (10020) | 2.9 (10028) | 2.9 (10053) |
| sharing | 0.61 | 0.89 | 2.13 | 9.5 (27222) | 12.2 (46727) | 10.4 (46241) |
| parents_proj | 0.09 | 0.14 | 0.21 | 10.0 (28725) | 12.7 (48731) | 11.0 (48260) |
| parents | 3.82 | 15.46 | 1.59 | 47.9 (128726) | 86.3 (348731) | 27.0 (148260) |
| nesting | 0.03 | 0.14 | 0.11 | 47.9 (128727) | 87.2 (352736) | 27.8 (152261) |

Checksums (visible documents per sample user):

- rbac: identical across A, B, C (1: 4000, 2: 4000, 3: 4000, 5: 4000, 10: 4000, 77: 4000, 500: 4000, 5000: 4000)
- sharing: identical across A, B, C (1: 4007, 2: 4007, 3: 4012, 5: 4012, 10: 4010, 77: 4022, 500: 4020, 5000: 4006)
- parents_proj: identical across A, B, C (1: 4007, 2: 4007, 3: 4012, 5: 4212, 10: 4210, 77: 4022, 500: 4220, 5000: 4206)
- parents: identical across A, B, C (1: 4007, 2: 4007, 3: 4012, 5: 4212, 10: 4210, 77: 4022, 500: 4220, 5000: 4206)

## Small, default shape

The data has 10k documents, 1k users, 20 orgs and 50 teams. A sample user sees about 1k documents. These are the `--check` runs (first pass, before the new budgets).

Latency, ms:

| workload | A p50 | B p50 | C p50 | A p95 | B p95 | C p95 |
| --- | --- | --- | --- | --- | --- | --- |
| `rbac_check` | 0.27 | 0.32 | 0.22 | 0.43 | 0.39 | 0.29 |
| `rbac_select_page` | 0.44 | 0.39 | 0.40 | 0.61 | 0.47 | 0.49 |
| `rbac_select_count` | 0.39 | 0.34 | 0.36 | 0.47 | 0.42 | 0.43 |
| `rbac_update_one` | 0.79 | 0.79 | 0.65 | 1.03 | 0.87 | 0.77 |
| `write_assign_role` | 0.16 | 0.15 | 0.20 | 0.27 | 0.25 | 0.36 |
| `share_list_objects` | 0.38 | 0.28 | 0.22 | 0.47 | 0.36 | 0.32 |
| `share_select_page` | 1.15 | 0.69 | 0.53 | 1.29 | 0.82 | 0.68 |
| `write_share` | 0.15 | 0.14 | 0.16 | 0.25 | 0.24 | 0.28 |
| `parents_proj_select_page` | 2.16 | 0.79 | 0.48 | 3.02 | 1.04 | 0.57 |
| `parents_proj_select_count` | 2.06 | 0.73 | 0.43 | 2.44 | 0.89 | 0.51 |
| `parents_select_page` | 20.83 | 5.88 | 1.09 | 22.75 | 6.31 | 1.30 |
| `parents_select_count` | 20.53 | 5.80 | 1.01 | 22.44 | 6.25 | 1.19 |
| `write_nest_team` | 0.15 | 134.09 | 62.07 | 0.27 | 161.47 | 72.14 |
| `nest_check` | 0.33 | 1.16 | 0.24 | 0.45 | 1.29 | 0.30 |

The next table shows the seed time (native-API load only) and the cumulative size of the `permissions` tables after each phase, after VACUUM FULL:

| phase | A seed s | B seed s | C seed s | A MB (rows) | B MB (rows) | C MB (rows) |
| --- | --- | --- | --- | --- | --- | --- |
| rbac | 0.13 | 0.11 | 0.17 | 1.0 (2020) | 0.9 (2028) | 1.0 (2053) |
| sharing | 0.17 | 0.21 | 0.68 | 2.5 (6322) | 3.0 (10055) | 2.7 (10006) |
| parents_proj | 0.04 | 0.07 | 0.11 | 2.6 (6725) | 3.2 (10659) | 3.0 (10625) |
| parents | 0.37 | 1.49 | 0.18 | 6.4 (16726) | 10.5 (40659) | 4.6 (20625) |
| nesting | 0.05 | 0.07 | 0.06 | 6.4 (16727) | 11.2 (43663) | 5.1 (23626) |

Checksums (visible documents per sample user):

- rbac: identical across A, B, C (1: 1000, 2: 1000, 3: 1000, 5: 1000, 10: 1000, 77: 1000, 500: 1000, 1000: 1000)
- sharing: identical across A, B, C (1: 1007, 2: 1005, 3: 1012, 5: 1011, 10: 1012, 77: 1015, 500: 1007, 1000: 1007)
- parents_proj: identical across A, B, C (1: 1007, 2: 1005, 3: 1012, 5: 1060, 10: 1062, 77: 1015, 500: 1057, 1000: 1057)
- parents: identical across A, B, C (1: 1007, 2: 1005, 3: 1012, 5: 1060, 10: 1062, 77: 1015, 500: 1057, 1000: 1057)

## Medium, deep shape

The data is the medium data, but the teams are in chains 9 deep. Every user is in a leaf team, so each user has 9 transitive teams.

Latency, ms:

| workload | A p50 | B p50 | C p50 | A p95 | B p95 | C p95 |
| --- | --- | --- | --- | --- | --- | --- |
| `rbac_check` | 0.27 | 0.32 | 0.23 | 0.37 | 0.40 | 0.30 |
| `rbac_select_page` | 0.53 | 0.47 | 0.49 | 0.64 | 0.56 | 0.57 |
| `rbac_select_count` | 0.47 | 0.42 | 0.43 | 0.56 | 0.66 | 0.54 |
| `rbac_update_one` | 0.80 | 0.80 | 0.68 | 0.94 | 0.91 | 0.79 |
| `write_assign_role` | 0.16 | 0.14 | 0.20 | 0.27 | 0.24 | 0.35 |
| `share_list_objects` | 0.69 | 0.60 | 0.24 | 0.85 | 0.68 | 0.30 |
| `share_select_page` | 2.47 | 2.04 | 0.77 | 2.73 | 2.18 | 0.91 |
| `write_share` | 0.15 | 0.14 | 0.16 | 0.25 | 0.23 | 0.29 |
| `parents_proj_select_page` | 3.47 | 1.37 | 0.75 | 3.90 | 1.51 | 1.03 |
| `parents_proj_select_count` | 3.59 | 1.36 | 0.72 | 4.09 | 1.45 | 1.07 |
| `parents_select_page` | 99.56 | 29.35 | 4.89 | 108.30 | 32.37 | 8.22 |
| `parents_select_count` | 97.69 | 28.24 | 4.22 | 105.95 | 31.05 | 7.44 |
| `write_nest_team` | 0.15 | 312.46 | 353.55 | 0.25 | 449.13 | 536.42 |
| `nest_check` | 0.87 | 2.54 | 0.27 | 0.94 | 2.77 | 0.35 |

The next table shows the seed time (native-API load only) and the cumulative size of the `permissions` tables after each phase, after VACUUM FULL:

| phase | A seed s | B seed s | C seed s | A MB (rows) | B MB (rows) | C MB (rows) |
| --- | --- | --- | --- | --- | --- | --- |
| rbac | 0.80 | 0.68 | 0.86 | 3.6 (10020) | 2.9 (10028) | 2.9 (10053) |
| sharing | 0.60 | 1.13 | 2.22 | 9.5 (27202) | 18.0 (72466) | 15.0 (71727) |
| parents_proj | 0.08 | 0.13 | 0.21 | 10.0 (28705) | 18.5 (74470) | 15.5 (73746) |
| parents | 3.81 | 15.33 | 1.64 | 47.9 (128706) | 92.2 (374470) | 31.5 (173746) |
| nesting | 0.04 | 0.17 | 0.24 | 47.9 (128707) | 94.2 (383480) | 33.1 (182747) |

Checksums (visible documents per sample user):

- rbac: identical across A, B, C (1: 4000, 2: 4000, 3: 4000, 5: 4000, 10: 4000, 77: 4000, 500: 4000, 5000: 4000)
- sharing: identical across A, B, C (1: 4045, 2: 4046, 3: 4045, 5: 4047, 10: 4044, 77: 4044, 500: 4040, 5000: 4044)
- parents_proj: identical across A, B, C (1: 4045, 2: 4046, 3: 4045, 5: 4247, 10: 4243, 77: 4044, 500: 4240, 5000: 4244)
- parents: identical across A, B, C (1: 4045, 2: 4046, 3: 4045, 5: 4247, 10: 4243, 77: 4044, 500: 4240, 5000: 4244)

## Medium, wide shape

The data is the medium data, with 800 teams in a 4-ary tree. Each user is in 50 teams, and each team has 50 shares. A sample user sees about 10k documents.

Latency, ms:

| workload | A p50 | B p50 | C p50 | A p95 | B p95 | C p95 |
| --- | --- | --- | --- | --- | --- | --- |
| `rbac_check` | 0.27 | 0.33 | 0.23 | 0.36 | 0.51 | 0.31 |
| `rbac_select_page` | 0.53 | 0.47 | 0.49 | 0.63 | 0.56 | 0.58 |
| `rbac_select_count` | 0.47 | 0.41 | 0.42 | 0.57 | 0.49 | 0.50 |
| `rbac_update_one` | 0.82 | 0.80 | 0.65 | 0.97 | 0.87 | 0.76 |
| `write_assign_role` | 0.17 | 0.14 | 0.20 | 0.29 | 0.24 | 0.34 |
| `share_list_objects` | 63.77 | 25.65 | 3.76 | 73.23 | 28.17 | 4.06 |
| `share_select_page` | 221.40 | 70.19 | 10.72 | 268.80 | 75.74 | 13.73 |
| `write_share` | 0.15 | 0.14 | 0.16 | 0.26 | 0.23 | 0.29 |
| `parents_proj_select_page` | 221.55 | 73.24 | 11.15 | 246.37 | 79.81 | 16.98 |
| `parents_proj_select_count` | 221.32 | 67.96 | 8.60 | 238.33 | 73.22 | 10.14 |
| `parents_select_page` | 237.76 | 88.44 | 13.74 | 253.06 | 95.22 | 15.27 |
| `parents_select_count` | 234.14 | 86.21 | 11.63 | 251.90 | 92.25 | 13.32 |
| `write_nest_team` | 0.15 | 320.82 | 144.63 | 0.26 | 344.09 | 174.19 |
| `nest_check` | 2.23 | 2.80 | 0.28 | 2.48 | 3.08 | 0.35 |

The next table shows the seed time (native-API load only) and the cumulative size of the `permissions` tables after each phase, after VACUUM FULL:

| phase | A seed s | B seed s | C seed s | A MB (rows) | B MB (rows) | C MB (rows) |
| --- | --- | --- | --- | --- | --- | --- |
| rbac | 0.80 | 0.67 | 0.87 | 3.6 (10020) | 2.9 (10028) | 2.9 (10053) |
| sharing | 10.39 | 35.45 | 182.95 | 97.1 (311822) | 225.9 (971953) | 191.6 (969122) |
| parents_proj | 0.09 | 0.14 | 0.23 | 97.6 (313325) | 226.4 (973957) | 192.2 (971141) |
| parents | 4.04 | 15.81 | 1.65 | 135.4 (413326) | 300.0 (1273957) | 208.2 (1071141) |
| nesting | 0.05 | 0.12 | 0.09 | 135.4 (413327) | 301.1 (1278963) | 209.1 (1076142) |

Checksums (visible documents per sample user):

- rbac: identical across A, B, C (1: 4000, 2: 4000, 3: 4000, 5: 4000, 10: 4000, 77: 4000, 500: 4000, 5000: 4000)
- sharing: identical across A, B, C (1: 10386, 2: 10386, 3: 10386, 5: 10386, 10: 10434, 77: 10434, 500: 9906, 5000: 10434)
- parents_proj: identical across A, B, C (1: 10386, 2: 10386, 3: 10386, 5: 10568, 10: 10614, 77: 10434, 500: 10101, 5000: 10629)
- parents: identical across A, B, C (1: 10386, 2: 10386, 3: 10386, 5: 10568, 10: 10614, 77: 10434, 500: 10101, 5000: 10629)

## What the numbers say

This section gives only what these runs measured. We did one run for each configuration, so differences under about 20% are within the noise.

**RBAC: the designs are equal.** At every scale and shape the `rbac_*` workloads are within about 0.1–0.2 ms across designs. The large p95 values are 0.34–0.48 ms for check, 0.77–0.99 ms for page, 0.82–0.92 ms for count and 0.80–1.06 ms for update. All three meet every RBAC budget of session 1. Single-row writes (`write_assign_role`, `write_share`) take 0.14–0.20 ms p50 everywhere.

**Sharing reads: C is faster than B, and B is faster than A, at every scale.** `share_select_page` p50 at small/medium/large: A 1.15/1.53/2.02, B 0.69/0.89/1.21, C 0.53/0.69/0.95 ms. All meet the budgets of session 1 in the default shape.

**The policy shape matters more than the design.** With the two-arm projection, parents cost about what sharing costs: large `parents_proj_select_page` p50 A 3.20, B 1.44, C 1.01 ms. The cost grows slowly (small to large: A 2.2 → 3.2, B 0.8 → 1.4, C 0.5 → 1.0 ms). With the single-branch policy the design materializes every visible document id (about 20k at large), and the cost follows that number:

| `parents_select_page` p50, ms | small (~1k ids) | medium (~4k) | large (~21k) | single ÷ projection at large |
| --- | --- | --- | --- | --- |
| A | 20.8 | 99.6 | 509 | ~160× |
| B | 5.9 | 28.8 | 197 | ~140× |
| C | 1.09 | 4.6 | 9.6 | ~9× |

C holds up an order of magnitude better than A and B on the single branch, with its materialized `accessible()`. A walks, and B joins a closure. Even so, at large the projection is 9× cheaper for C too. The extrapolation of session 1 for A at large (about 150 ms) was low: it measured 509 ms.

**Nesting is the trade-off between read and write, as designed.** The next table shows `write_nest_team` (4 clients):

| p50, ms | small | medium | large | medium deep | medium wide |
| --- | --- | --- | --- | --- | --- |
| A | 0.15 | 0.15 | 0.15 | 0.15 | 0.15 |
| B | 134 | 220 | 285 | 312 | 321 |
| C | 62 | 272 | 333 | 354 | 145 |

A writes one tuple. B and C write closure or membership rows under a global lock, so concurrent nests queue (12–70 tps). The read side (`nest_check`) is flat for C (0.24–0.28 ms everywhere). For A it grows with what the walk reaches (0.33 small, 0.70 large, 0.87 deep, 2.23 wide). B takes 1.2–2.8 ms. After the `_parent_keys` fix it no longer shows the 17 ms plan, but it is still the slowest check here.

**Stress shapes.** *Deep* (medium): the reads of C do not change (`share_select_page` 0.77 ms against 0.69 for default). A and B are 1.6–2.3× slower (A 1.53 → 2.47, B 0.89 → 2.04 ms). This is the cost of nine walk levels or nine closure rows for each user.

*Wide* (medium, about 10k visible documents and 50 direct teams for each user) separates the designs most. `share_select_page` p50 is A 221, B 70, C 10.7 ms. The parents workloads follow the same order (A ~220–238, B ~68–88, C ~9–14 ms). Here the share arm dominates, so the projection does not help A or B. C pays at write time: its wide sharing seed took 183 s, against 35 s for B and 10 s for A.

**Storage and seed cost.**

- Sharing data at large: A 18.6 MB, B 25.4 MB, C 21.3 MB.
- Per-document parent links at large: A 44 s / +378 MB (1M tuples). B 167 s / +736 MB (1M parents rows + 2M closure rows). C 16 s / +160 MB (1M parents rows). The projection shape needs none of it.
- Wide (medium) after sharing: A 97 MB / 0.31M rows, B 226 MB / 0.97M rows, C 192 MB / 0.97M rows.

## Budgets

[`bench/budgets.tsv`](../../bench/budgets.tsv) now also has budgets for the parents and nesting workloads at small and large, and for every workload at `medium`, `medium-deep` and `medium-wide`. The rule is 3× the p95 of the fastest design on that workload. The result is rounded up to a whole ms, and it is at least 1 ms (session 1 used A, then the only design). The budgets of session 1 did not change, and we did not loosen any budget to fit a design. The list shows the misses against these runs (measured p95 > budget, ms):

- small-default A: 4 miss: parents_proj_select_page 3.02>2; parents_proj_select_count 2.44>2; parents_select_page 22.75>4; parents_select_count 22.44>4
- small-default B: 4 miss: parents_select_page 6.31>4; parents_select_count 6.25>4; write_nest_team 161.47>1; nest_check 1.29>1
- small-default C: 1 miss: write_nest_team 72.14>1
- large-default A: 2 miss: parents_select_page 560.66>32; parents_select_count 579.85>70
- large-default B: 4 miss: parents_select_page 251.96>32; parents_select_count 266.63>70; write_nest_team 325.98>1; nest_check 2.83>2
- large-default C: 1 miss: write_nest_team 384.19>1
- medium-default A: 4 miss: parents_proj_select_page 3.01>3; parents_proj_select_count 3.06>3; parents_select_page 109.11>16; parents_select_count 115.06>14
- medium-default B: 4 miss: parents_select_page 31.79>16; parents_select_count 30.69>14; write_nest_team 240.84>1; nest_check 2.58>1
- medium-default C: 1 miss: write_nest_team 306.48>1
- medium-deep A: 3 miss: parents_proj_select_count 4.09>4; parents_select_page 108.3>25; parents_select_count 105.95>23
- medium-deep B: 4 miss: parents_select_page 32.37>25; parents_select_count 31.05>23; write_nest_team 449.13>1; nest_check 2.77>2
- medium-deep C: 1 miss: write_nest_team 536.42>1
- medium-wide A: 7 miss: share_list_objects 73.23>13; share_select_page 268.8>42; parents_proj_select_page 246.37>51; parents_proj_select_count 238.33>31; parents_select_page 253.06>46; parents_select_count 251.9>40; nest_check 2.48>2
- medium-wide B: 8 miss: share_list_objects 28.17>13; share_select_page 75.74>42; parents_proj_select_page 79.81>51; parents_proj_select_count 73.22>31; parents_select_page 95.22>46; parents_select_count 92.25>40; write_nest_team 344.09>1; nest_check 3.08>2
- medium-wide C: 1 miss: write_nest_team 174.19>1

Read the misses through the trade-offs above. B and C miss `write_nest_team` everywhere because the budget comes from the one-tuple write of A. A and B miss the single-branch parents budgets because the budget comes from C. In the wide shape A and B miss every sharing and parents read budget. B misses `nest_check` by a small margin at every scale.

We ran `./bench/run.sh --impl prototypes/<x>.sql --check` at small scale with these budgets (2026-10-29, second pass). **A fails** 4 checks: both `parents_proj_*` at about 2.7–2.9 ms against 2, and both single-branch `parents_*` at about 23–26 ms against 4. **B fails** 4 checks: the single-branch `parents_*` at 6.4–6.5 ms against 4, `write_nest_team` at 179 ms against 1, and `nest_check` at 1.29 ms against 1. **C fails** 1 check: `write_nest_team` at 72 ms against 1. All three pass every budget of session 1. The checksums matched across designs in these runs too.

The new `medium` `share_list_objects` budget (1 ms) is tighter than the small budget (2 ms). The reason is that the small budget is a session-1 budget derived from A. We left it as it is.

## Caveats

- One laptop (Apple Silicon, Postgres 16.4 from Postgres.app), one run for each configuration, 10 s for each workload, 4 clients. There are no repeat runs, so there are no confidence intervals.
- The throwaway cluster has `fsync=off` and `full_page_writes=off`. The write latencies are optimistic for all designs in the same way.
- Every write workload rolls back, so the benchmark does not measure the cost of a commit.
- The `write_nest_team` latencies include the queue on the global lock of B and C with 4 clients. We did not measure the cost of a nest with a single client.
- Each phase starts after VACUUM FULL plus VACUUM of the non-empty tables. So the tables are compact, with fresh statistics and a full visibility map. The benchmark does not measure bloat from churn.
- The checksums cover 8 sample users in each run, not every user.
- The designs are prototypes, not tuned implementations. The single-branch form of B needs per-document parents rows. The design document of B does not recommend this use ([`../designs/b-policy-first.md`](../designs/b-policy-first.md)). It recommends the projection.
