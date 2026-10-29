# Benchmark: a-tuple-core (design a), large scale, default shape

- Date: 2026-10-29 07:53
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.29 | 0.38 | 0.277 | 14442 | 1 | ok |
| rbac_select_page | 0.83 | 1.03 | 0.835 | 4787 | 3 | ok |
| rbac_select_count | 0.90 | 1.08 | 0.895 | 4471 | 3 | ok |
| rbac_update_one | 0.69 | 0.89 | 0.678 | 5902 | 3 | ok |
| write_assign_role | 0.16 | 0.22 | 0.162 | 24634 | 1 | ok |
| share_list_objects | 0.36 | 0.46 | 0.345 | 11584 | 2 | ok |
| share_select_page | 1.56 | 1.90 | 1.594 | 2509 | 6 | ok |
| write_share | 0.15 | 0.21 | 0.147 | 27156 | 1 | ok |
| parents_proj_select_page | 2.27 | 3.42 | 2.423 | 1650 | 4 | ok |
| parents_proj_select_count | 8.98 | 12.06 | 9.296 | 430 | 9 | OVER |
| parents_select_page | 246.05 | 281.81 | 252.090 | 15 | 32 | OVER |
| parents_select_count | 265.57 | 304.98 | 271.563 | 14 | 70 | OVER |
| write_nest_team | 0.15 | 0.21 | 0.153 | 26079 | 1 | ok |
| nest_check | 0.69 | 0.97 | 0.714 | 5605 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.35 | 7.0 | 20020 |
| sharing | 0.72 | 18.6 | 54022 |
| parents_proj | 0.07 | 19.6 | 57025 |
| parents | 27.00 | 397.6 | 1057026 |
| nesting | 0.06 | 397.6 | 1057027 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 6.75 MB, 20000 rows | 18.42 MB, 53997 rows | 19.39 MB, 56997 rows | 397.43 MB, 1056997 rows | 397.43 MB, 1056998 rows |

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
- vs design b (2026-10-29 07:47): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 07:50): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.556..4.867 rows=50 loops=1)
  Buffers: shared hit=2734 read=13
  InitPlan 1
    ->  Result (actual time=0.414..0.415 rows=2 loops=1)
          Buffers: shared hit=66
          ->  ProjectSet (actual time=0.413..0.414 rows=2 loops=1)
                Buffers: shared hit=66
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.555..4.863 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2734 read=13
Planning:
  Buffers: shared hit=705
Planning Time: 1.556 ms
Execution Time: 4.876 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.836..3.865 rows=50 loops=1)
  Buffers: shared hit=2955 read=12
  InitPlan 1
    ->  Result (actual time=0.431..0.432 rows=2 loops=1)
          Buffers: shared hit=143
          ->  ProjectSet (actual time=0.430..0.431 rows=2 loops=1)
                Buffers: shared hit=143
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.303..0.306 rows=7 loops=1)
          Buffers: shared hit=143
          ->  ProjectSet (actual time=0.303..0.303 rows=7 loops=1)
                Buffers: shared hit=143
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.835..3.862 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2955 read=12
Planning:
  Buffers: shared hit=922
Planning Time: 2.374 ms
Execution Time: 3.882 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=1.062..4.446 rows=50 loops=1)
  Buffers: shared hit=3475 read=12
  InitPlan 1
    ->  Result (actual time=0.492..0.495 rows=7 loops=1)
          Buffers: shared hit=403
          ->  ProjectSet (actual time=0.492..0.492 rows=7 loops=1)
                Buffers: shared hit=403
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.446..0.456 rows=20 loops=1)
          Buffers: shared hit=403
          ->  ProjectSet (actual time=0.445..0.446 rows=20 loops=1)
                Buffers: shared hit=403
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.062..4.442 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3475 read=12
Planning:
  Buffers: shared hit=1434
Planning Time: 2.468 ms
Execution Time: 4.457 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=102.691..102.855 rows=50 loops=1)
  Buffers: shared hit=180263 read=165
  InitPlan 1
    ->  Result (actual time=96.720..101.908 rows=20007 loops=1)
          Buffers: shared hit=180232 read=113
          ->  ProjectSet (actual time=96.717..97.358 rows=20007 loops=1)
                Buffers: shared hit=180232 read=113
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=102.691..102.852 rows=50 loops=1)
        Index Cond: (id = ANY ((InitPlan 1).col1))
        Buffers: shared hit=180263 read=165
Planning:
  Buffers: shared hit=179511 read=1461 dirtied=1 written=1
Planning Time: 111.018 ms
Execution Time: 102.870 ms
```

