# Benchmark: b-policy-first (design b), large scale, default shape

- Date: 2026-10-29 13:27
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.50 | 0.311 | 12859 | 1 | ok |
| rbac_select_page | 0.74 | 1.00 | 0.767 | 5217 | 3 | ok |
| rbac_select_count | 0.81 | 1.04 | 0.825 | 4845 | 3 | ok |
| rbac_update_one | 0.47 | 0.74 | 0.504 | 7931 | 3 | ok |
| write_assign_role | 0.14 | 0.23 | 0.155 | 25784 | 1 | ok |
| share_list_objects | 0.29 | 0.41 | 0.294 | 13623 | 2 | ok |
| share_select_page | 1.02 | 1.43 | 1.067 | 3747 | 6 | ok |
| write_share | 0.15 | 0.30 | 0.177 | 22609 | 1 | ok |
| parents_proj_select_page | 1.15 | 1.55 | 1.199 | 3334 | 4 | ok |
| parents_proj_select_count | 8.96 | 15.19 | 10.009 | 399 | 9 | OVER |
| parents_select_page | 20.05 | 50.84 | 25.063 | 159 | 32 | OVER |
| parents_select_count | 27.32 | 81.88 | 37.965 | 105 | 70 | OVER |
| write_nest_team | 0.70 | 1.90 | 0.917 | 4363 | 1 | OVER |
| nest_check | 0.32 | 0.55 | 0.329 | 12150 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.32 | 7.4 | 20028 |
| sharing | 0.89 | 19.6 | 55697 |
| parents_proj | 0.09 | 20.6 | 58701 |
| parents | 49.19 | 377.9 | 1059701 |
| nesting | 0.03 | 377.9 | 1059707 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 0.62 MB, 1664 rows | 0.62 MB, 1664 rows | 0.96 MB, 2664 rows | 0.96 MB, 2669 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 3.87 MB, 11497 rows | 4.20 MB, 12497 rows | 361.11 MB, 1012497 rows | 361.11 MB, 1012498 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 7.03 MB, 20000 rows | 14.84 MB, 42500 rows | 15.53 MB, 44500 rows | 15.53 MB, 44500 rows | 15.53 MB, 44500 rows |
| role_implies | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows |
| roles | 0.06 MB, 6 rows | 0.06 MB, 8 rows | 0.06 MB, 9 rows | 0.06 MB, 9 rows | 0.06 MB, 9 rows |

## Equivalence

Documents each sample user sees through RLS after each seed, and the md5 of their sorted ids. Every 5th user is also a folder viewer, so for users not divisible by 5 parents_proj and parents must equal sharing, and parents_proj must always equal parents.

| policy | user | visible | md5 |
| --- | --- | --- | --- |
| rbac | 1 | 20000 | 83dfc8a4117363cd29474848ec593462 |
| rbac | 2 | 20000 | e011f33abf8ec3609fe7413a636dafb7 |
| rbac | 3 | 20000 | 5466f182950003a321d8658d12e38760 |
| rbac | 5 | 20000 | 694e0998e6843b06e6d8c4f5b4d88795 |
| rbac | 10 | 20000 | 821fd2c6b79483746aab43841450b9c6 |
| rbac | 77 | 20000 | 43afbd5eee1be997db26e1ca9a889aa3 |
| rbac | 500 | 20000 | 0561304ca98a061cdf6a51a7d82459e6 |
| rbac | 10000 | 20000 | 0561304ca98a061cdf6a51a7d82459e6 |
| sharing | 1 | 20007 | d2b4030ad636f968f35a8af5008ac9f6 |
| sharing | 2 | 20007 | abb87f25aaf62620d8b791efa17462b4 |
| sharing | 3 | 20012 | b4c68ea1387b14cdb659ac1be1bc314a |
| sharing | 5 | 20012 | 033a5195f5d6c532f52c9cd816196a27 |
| sharing | 10 | 20012 | e01f45d54102a2059611bc18421a6fc3 |
| sharing | 77 | 20022 | eb1cd8028cf96891dd907c58dd08b89f |
| sharing | 500 | 20007 | abc7fbfa02e70e61e8a0b57bc01c375f |
| sharing | 10000 | 20007 | b91916b3d484d728f128f79576324a38 |
| parents_proj | 1 | 20007 | d2b4030ad636f968f35a8af5008ac9f6 |
| parents_proj | 2 | 20007 | abb87f25aaf62620d8b791efa17462b4 |
| parents_proj | 3 | 20012 | b4c68ea1387b14cdb659ac1be1bc314a |
| parents_proj | 5 | 21012 | 62038fc0969395160b3e96933ddac9e4 |
| parents_proj | 10 | 21012 | 447d15cf1ccb48b8a791f10de5616989 |
| parents_proj | 77 | 20022 | eb1cd8028cf96891dd907c58dd08b89f |
| parents_proj | 500 | 21007 | d357b76a845e832d77fdd55403df4e56 |
| parents_proj | 10000 | 21007 | 24fc32209c7c854bc0f098b1e1d6940d |
| parents | 1 | 20007 | d2b4030ad636f968f35a8af5008ac9f6 |
| parents | 2 | 20007 | abb87f25aaf62620d8b791efa17462b4 |
| parents | 3 | 20012 | b4c68ea1387b14cdb659ac1be1bc314a |
| parents | 5 | 21012 | 62038fc0969395160b3e96933ddac9e4 |
| parents | 10 | 21012 | 447d15cf1ccb48b8a791f10de5616989 |
| parents | 77 | 20022 | eb1cd8028cf96891dd907c58dd08b89f |
| parents | 500 | 21007 | d357b76a845e832d77fdd55403df4e56 |
| parents | 10000 | 21007 | 24fc32209c7c854bc0f098b1e1d6940d |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-29 13:24): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 13:21): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=3.035..6.672 rows=50 loops=1)
  Buffers: shared hit=3539 read=13
  InitPlan 1
    ->  Result (actual time=2.929..2.930 rows=2 loops=1)
          Buffers: shared hit=871
          ->  ProjectSet (actual time=2.928..2.928 rows=2 loops=1)
                Buffers: shared hit=871
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.034..6.668 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3539 read=13
Planning:
  Buffers: shared hit=109
Planning Time: 0.141 ms
Execution Time: 6.878 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=3.490..6.823 rows=50 loops=1)
  Buffers: shared hit=3546 read=12
  InitPlan 1
    ->  Result (actual time=3.190..3.191 rows=2 loops=1)
          Buffers: shared hit=852
          ->  ProjectSet (actual time=3.189..3.190 rows=2 loops=1)
                Buffers: shared hit=852
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.187..0.190 rows=7 loops=1)
          Buffers: shared hit=24
          ->  ProjectSet (actual time=0.187..0.187 rows=7 loops=1)
                Buffers: shared hit=24
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.490..6.818 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3546 read=12
Planning:
  Buffers: shared hit=142
Planning Time: 0.256 ms
Execution Time: 7.061 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=4.153..7.689 rows=50 loops=1)
  Buffers: shared hit=3571 read=12
  InitPlan 1
    ->  Result (actual time=3.856..3.858 rows=7 loops=1)
          Buffers: shared hit=864
          ->  ProjectSet (actual time=3.855..3.856 rows=7 loops=1)
                Buffers: shared hit=864
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.178..0.184 rows=20 loops=1)
          Buffers: shared hit=37
          ->  ProjectSet (actual time=0.178..0.179 rows=20 loops=1)
                Buffers: shared hit=37
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=4.153..7.685 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3571 read=12
Planning:
  Buffers: shared hit=139
Planning Time: 0.185 ms
Execution Time: 7.900 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=88.105..89.577 rows=50 loops=1)
  Buffers: shared hit=1335 read=44
  InitPlan 1
    ->  Result (actual time=69.737..80.443 rows=20007 loops=1)
          Buffers: shared hit=1296
          ->  ProjectSet (actual time=69.733..71.359 rows=20007 loops=1)
                Buffers: shared hit=1296
                ->  Result (actual time=0.001..0.001 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=88.101..89.562 rows=50 loops=1)
        Index Cond: (id = ANY ((InitPlan 1).col1))
        Buffers: shared hit=1335 read=44
Planning:
  Buffers: shared hit=106
Planning Time: 0.860 ms
Execution Time: 91.046 ms
```

