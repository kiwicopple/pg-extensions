# Benchmark: a-tuple-core (design a), large scale, default shape

- Date: 2026-10-28 23:40
- Postgres: 16.4 (Postgres.app)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.28 | 0.35 | 0.285 | 14057 | 1 | ok |
| rbac_select_page | 0.67 | 0.77 | 0.678 | 5895 | 3 | ok |
| rbac_select_count | 0.83 | 0.92 | 0.839 | 4765 | 3 | ok |
| rbac_update_one | 0.87 | 1.06 | 0.834 | 4798 | 3 | ok |
| write_assign_role | 0.17 | 0.28 | 0.180 | 22214 | 1 | ok |
| share_list_objects | 0.52 | 0.84 | 0.553 | 7234 | 2 | ok |
| share_select_page | 2.02 | 2.28 | 2.007 | 1993 | 6 | ok |
| write_share | 0.15 | 0.25 | 0.161 | 24770 | 1 | ok |
| parents_proj_select_page | 3.20 | 3.71 | 3.223 | 1240 | - | - |
| parents_proj_select_count | 5.00 | 5.58 | 5.047 | 792 | - | - |
| parents_select_page | 509.43 | 560.66 | 523.920 | 7 | - | - |
| parents_select_count | 536.39 | 579.85 | 538.863 | 7 | - | - |
| write_nest_team | 0.15 | 0.24 | 0.157 | 25510 | - | - |
| nest_check | 0.70 | 0.79 | 0.712 | 5621 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.88 | 7.0 | 20020 |
| sharing | 1.18 | 18.6 | 54022 |
| parents_proj | 0.14 | 19.6 | 57025 |
| parents | 44.02 | 397.6 | 1057026 |
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

Compared with other designs' latest runs at this scale and shape: none yet.

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.468..2.615 rows=50 loops=1)
  Buffers: shared hit=2734 read=13
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.408..0.409 rows=2 loops=1)
          Buffers: shared hit=66
          ->  ProjectSet (actual time=0.408..0.408 rows=2 loops=1)
                Buffers: shared hit=66
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.468..2.613 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2734 read=13
Planning:
  Buffers: shared hit=705
Planning Time: 1.962 ms
Execution Time: 2.620 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.910..3.330 rows=50 loops=1)
  Buffers: shared hit=2955 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.445..0.446 rows=2 loops=1)
          Buffers: shared hit=143
          ->  ProjectSet (actual time=0.444..0.445 rows=2 loops=1)
                Buffers: shared hit=143
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.412..0.414 rows=7 loops=1)
          Buffers: shared hit=143
          ->  ProjectSet (actual time=0.411..0.412 rows=7 loops=1)
                Buffers: shared hit=143
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.910..3.327 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2955 read=12
Planning:
  Buffers: shared hit=922
Planning Time: 2.516 ms
Execution Time: 3.337 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=1.368..3.961 rows=50 loops=1)
  Buffers: shared hit=3475 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.649..0.652 rows=7 loops=1)
          Buffers: shared hit=403
          ->  ProjectSet (actual time=0.649..0.649 rows=7 loops=1)
                Buffers: shared hit=403
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.654..0.659 rows=20 loops=1)
          Buffers: shared hit=403
          ->  ProjectSet (actual time=0.653..0.654 rows=20 loops=1)
                Buffers: shared hit=403
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.368..3.959 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3475 read=12
Planning:
  Buffers: shared hit=1438
Planning Time: 2.941 ms
Execution Time: 3.968 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=208.492..208.620 rows=50 loops=1)
  Buffers: shared hit=180360 read=186
  InitPlan 1 (returns $0)
    ->  Result (actual time=202.976..207.777 rows=20007 loops=1)
          Buffers: shared hit=180207 read=136
          ->  ProjectSet (actual time=202.975..203.430 rows=20007 loops=1)
                Buffers: shared hit=180207 read=136
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=208.492..208.617 rows=50 loops=1)
        Index Cond: (id = ANY ($0))
        Buffers: shared hit=180360 read=186
Planning:
  Buffers: shared hit=179582 read=1391 dirtied=1
Planning Time: 212.603 ms
Execution Time: 208.630 ms
```

