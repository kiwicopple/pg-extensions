# Benchmark: d-per-model (design d), large scale, default shape

- Date: 2026-10-29 17:30
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.22 | 0.36 | 0.234 | 17128 | 1 | ok |
| rbac_select_page | 0.72 | 1.81 | 0.894 | 4475 | 3 | ok |
| rbac_select_count | 0.77 | 1.55 | 0.872 | 4587 | 3 | ok |
| rbac_update_one | 0.28 | 0.44 | 0.282 | 14162 | 3 | ok |
| write_assign_role | 0.14 | 0.22 | 0.144 | 27806 | 1 | ok |
| share_list_objects | 0.54 | 0.71 | 0.546 | 7328 | 2 | ok |
| share_select_page | 1.29 | 3.34 | 1.576 | 2537 | 6 | ok |
| write_share | 0.23 | 0.35 | 0.245 | 16357 | 1 | ok |
| parents_proj_select_page | 1.66 | 2.61 | 1.799 | 2222 | 4 | ok |
| parents_proj_select_count | 8.92 | 11.03 | 9.144 | 437 | 9 | OVER |
| parents_select_page | 1.40 | 9.45 | 3.078 | 1299 | 32 | ok |
| parents_select_count | 8.44 | 15.96 | 9.877 | 404 | 70 | ok |
| write_nest_team | 0.24 | 0.50 | 0.273 | 14661 | 1 | ok |
| nest_check | 0.41 | 0.64 | 0.425 | 9408 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.86 | 5.4 | 20015 |
| sharing | 1.84 | 16.1 | 54060 |
| parents_proj | 0.10 | 16.8 | 56060 |
| parents | 33.80 | 284.9 | 1056060 |
| nesting | 0.03 | 284.9 | 1056061 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| fga_computed_closure | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows |
| fga_edges | 0.02 MB, 0 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows |
| fga_models | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows |
| fga_paths | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows |
| fga_relations | 0.02 MB, 0 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows |
| fga_rewrite_nodes | 0.02 MB, 0 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows |
| fga_tuples | 0.02 MB, 0 rows | 10.38 MB, 33997 rows | 11.05 MB, 35997 rows | 279.17 MB, 1035997 rows | 279.17 MB, 1035998 rows |
| fga_type_restrictions | 0.02 MB, 0 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows |
| fga_types | 0.02 MB, 0 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows |
| rbac_assignments | 4.90 MB, 20000 rows | 4.90 MB, 20000 rows | 4.90 MB, 20000 rows | 4.90 MB, 20000 rows | 4.90 MB, 20000 rows |
| rbac_role_closure | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |
| rbac_role_inherits | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows |
| rbac_role_permissions | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |

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
- vs design b (2026-10-29 13:27): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 13:21): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.764..3.913 rows=50.00 loops=1)
  Buffers: shared hit=3093 read=13
  InitPlan 1
    ->  Result (actual time=0.582..0.583 rows=2.00 loops=1)
          Buffers: shared hit=425
          ->  ProjectSet (actual time=0.581..0.582 rows=2.00 loops=1)
                Buffers: shared hit=425
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.763..3.909 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3093 read=13
Planning:
  Buffers: shared hit=142
Planning Time: 0.187 ms
Execution Time: 4.110 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=3.316..6.585 rows=50.00 loops=1)
  Buffers: shared hit=4115 read=12
  InitPlan 1
    ->  Result (actual time=2.902..2.904 rows=7.00 loops=1)
          Buffers: shared hit=1237
          ->  ProjectSet (actual time=2.901..2.902 rows=7.00 loops=1)
                Buffers: shared hit=1237
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.272..0.273 rows=2.00 loops=1)
          Buffers: shared hit=208
          ->  ProjectSet (actual time=0.272..0.272 rows=2.00 loops=1)
                Buffers: shared hit=208
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.315..6.581 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4115 read=12
Planning:
  Buffers: shared hit=117
Planning Time: 0.167 ms
Execution Time: 6.822 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=4.252..8.177 rows=50.00 loops=1)
  Buffers: shared hit=4143 read=12
  InitPlan 1
    ->  Result (actual time=3.508..3.512 rows=7.00 loops=1)
          Buffers: shared hit=1210
          ->  ProjectSet (actual time=3.506..3.507 rows=7.00 loops=1)
                Buffers: shared hit=1210
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.243..0.244 rows=0.00 loops=1)
          Buffers: shared hit=55
          ->  ProjectSet (actual time=0.243..0.244 rows=0.00 loops=1)
                Buffers: shared hit=55
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.324..0.325 rows=2.00 loops=1)
          Buffers: shared hit=208
          ->  ProjectSet (actual time=0.323..0.323 rows=2.00 loops=1)
                Buffers: shared hit=208
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=4.251..8.170 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4143 read=12
Planning:
  Buffers: shared hit=150
Planning Time: 0.273 ms
Execution Time: 8.511 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=4.685..9.430 rows=50.00 loops=1)
  Buffers: shared hit=4084 read=40
  InitPlan 1
    ->  Result (actual time=4.180..4.183 rows=7.00 loops=1)
          Buffers: shared hit=1204 read=30
          ->  ProjectSet (actual time=4.178..4.179 rows=7.00 loops=1)
                Buffers: shared hit=1204 read=30
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.358..0.360 rows=2.00 loops=1)
          Buffers: shared hit=206 read=2
          ->  ProjectSet (actual time=0.357..0.358 rows=2.00 loops=1)
                Buffers: shared hit=206 read=2
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=4.684..9.424 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4084 read=40
Planning:
  Buffers: shared hit=107 read=8
Planning Time: 0.305 ms
Execution Time: 9.851 ms
```

