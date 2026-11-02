# Benchmark: c-compiled-model (design c), large scale, default shape

- Date: 2026-10-29 07:50
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.28 | 0.38 | 0.273 | 14626 | 1 | ok |
| rbac_select_page | 0.85 | 1.05 | 0.863 | 4634 | 3 | ok |
| rbac_select_count | 0.94 | 1.14 | 0.942 | 4244 | 3 | ok |
| rbac_update_one | 0.66 | 0.81 | 0.648 | 6175 | 3 | ok |
| write_assign_role | 0.22 | 0.29 | 0.228 | 17512 | 1 | ok |
| share_list_objects | 0.28 | 0.37 | 0.267 | 14987 | 2 | ok |
| share_select_page | 1.11 | 1.37 | 1.130 | 3540 | 6 | ok |
| write_share | 0.19 | 0.28 | 0.202 | 19768 | 1 | ok |
| parents_proj_select_page | 1.12 | 1.45 | 1.139 | 3510 | 4 | ok |
| parents_proj_select_count | 8.24 | 9.50 | 8.275 | 483 | 9 | OVER |
| parents_select_page | 10.69 | 12.80 | 11.008 | 363 | 32 | ok |
| parents_select_count | 23.09 | 27.03 | 23.483 | 170 | 70 | ok |
| write_nest_team | 298.53 | 341.59 | 300.090 | 13 | 1 | OVER |
| nest_check | 0.33 | 0.41 | 0.307 | 13009 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.97 | 5.3 | 20053 |
| sharing | 3.98 | 21.3 | 98346 |
| parents_proj | 0.37 | 22.3 | 102365 |
| parents | 16.71 | 182.4 | 1102365 |
| nesting | 0.11 | 183.2 | 1107366 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| allowed_subjects | 0.05 MB, 6 rows | 0.05 MB, 12 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows |
| ancestors | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.26 MB, 1000 rows | 0.26 MB, 1000 rows | 0.26 MB, 1000 rows |
| memberships | 0.02 MB, 0 rows | 7.95 MB, 44280 rows | 7.95 MB, 44280 rows | 7.95 MB, 44280 rows | 8.82 MB, 49280 rows |
| models | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| parent_types | 0.01 MB, 0 rows | 0.01 MB, 0 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows |
| parents | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.23 MB, 1000 rows | 160.27 MB, 1001000 rows | 160.27 MB, 1001000 rows |
| relations | 0.08 MB, 14 rows | 0.08 MB, 17 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows |
| satisfies | 0.05 MB, 26 rows | 0.05 MB, 30 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows |
| tuples | 4.88 MB, 20000 rows | 13.02 MB, 53997 rows | 13.49 MB, 55997 rows | 13.49 MB, 55997 rows | 13.49 MB, 55998 rows |
| types | 0.08 MB, 3 rows | 0.08 MB, 5 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |

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
- vs design a (2026-10-29 07:43): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 07:47): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.739..3.585 rows=50 loops=1)
  Buffers: shared hit=2700 read=13
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.632..0.633 rows=2 loops=1)
          Buffers: shared hit=32
          ->  ProjectSet (actual time=0.631..0.631 rows=2 loops=1)
                Buffers: shared hit=32
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.739..3.582 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2700 read=13
Planning:
  Buffers: shared hit=1054
Planning Time: 2.131 ms
Execution Time: 3.592 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=1.484..4.854 rows=50 loops=1)
  Buffers: shared hit=2751 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.746..0.747 rows=2 loops=1)
          Buffers: shared hit=43
          ->  ProjectSet (actual time=0.745..0.746 rows=2 loops=1)
                Buffers: shared hit=43
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.645..0.646 rows=1 loops=1)
          Buffers: shared hit=38
  ->  Index Scan using documents_pkey on documents (actual time=1.483..4.850 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2751 read=12
Planning:
  Buffers: shared hit=1069
Planning Time: 2.311 ms
Execution Time: 4.871 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.218..6.485 rows=50 loops=1)
  Buffers: shared hit=3711 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=2.369..2.370 rows=1 loops=1)
          Buffers: shared hit=943
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.716..0.716 rows=1 loops=1)
          Buffers: shared hit=98
  ->  Index Scan using documents_pkey on documents (actual time=3.217..6.481 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3711 read=12
Planning:
  Buffers: shared hit=105
Planning Time: 0.220 ms
Execution Time: 6.507 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=12.979..13.147 rows=50 loops=1)
  Buffers: shared hit=1341 read=47
  InitPlan 1 (returns $0)
    ->  Result (actual time=10.560..10.560 rows=1 loops=1)
          Buffers: shared hit=1185
  ->  Index Scan using documents_pkey on documents (actual time=12.979..13.143 rows=50 loops=1)
        Index Cond: (id = ANY ($0))
        Buffers: shared hit=1341 read=47
Planning:
  Buffers: shared hit=100
Planning Time: 0.112 ms
Execution Time: 13.157 ms
```

