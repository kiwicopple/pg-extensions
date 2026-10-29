# Benchmark: a-tuple-core (design a), large scale, default shape

- Date: 2026-10-29 13:24
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.34 | 0.90 | 0.460 | 8687 | 1 | ok |
| rbac_select_page | 0.77 | 1.59 | 0.902 | 4432 | 3 | ok |
| rbac_select_count | 0.83 | 1.08 | 0.845 | 4734 | 3 | ok |
| rbac_update_one | 0.57 | 0.82 | 0.587 | 6811 | 3 | ok |
| write_assign_role | 0.16 | 0.27 | 0.178 | 22508 | 1 | ok |
| share_list_objects | 0.34 | 0.84 | 0.460 | 8689 | 2 | ok |
| share_select_page | 1.14 | 2.24 | 1.297 | 3083 | 6 | ok |
| write_share | 0.15 | 0.23 | 0.152 | 26369 | 1 | ok |
| parents_proj_select_page | 1.36 | 2.13 | 1.469 | 2722 | 4 | ok |
| parents_proj_select_count | 8.69 | 10.93 | 8.846 | 452 | 9 | OVER |
| parents_select_page | 46.95 | 66.15 | 50.219 | 79 | 32 | OVER |
| parents_select_count | 68.19 | 113.47 | 77.405 | 51 | 70 | OVER |
| write_nest_team | 0.15 | 0.22 | 0.157 | 25527 | 1 | ok |
| nest_check | 0.31 | 0.49 | 0.320 | 12485 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.62 | 7.0 | 20020 |
| sharing | 1.10 | 18.7 | 54022 |
| parents_proj | 0.08 | 19.6 | 57025 |
| parents | 25.37 | 404.3 | 1057026 |
| nesting | 0.03 | 404.3 | 1057027 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 6.76 MB, 20000 rows | 18.46 MB, 53997 rows | 19.44 MB, 56997 rows | 404.09 MB, 1056997 rows | 404.09 MB, 1056998 rows |

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
- vs design b (2026-10-29 13:11): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 13:21): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.358..6.854 rows=50 loops=1)
  Buffers: shared hit=3381 read=13
  InitPlan 1
    ->  Result (actual time=2.218..2.219 rows=2 loops=1)
          Buffers: shared hit=713
          ->  ProjectSet (actual time=2.217..2.218 rows=2 loops=1)
                Buffers: shared hit=713
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.357..6.849 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3381 read=13
Planning:
  Buffers: shared hit=109
Planning Time: 0.171 ms
Execution Time: 7.123 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.146..6.618 rows=50 loops=1)
  Buffers: shared hit=3486 read=12
  InitPlan 1
    ->  Result (actual time=1.859..1.861 rows=2 loops=1)
          Buffers: shared hit=738
          ->  ProjectSet (actual time=1.858..1.859 rows=2 loops=1)
                Buffers: shared hit=738
                ->  Result (actual time=0.000..0.001 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.168..0.171 rows=7 loops=1)
          Buffers: shared hit=79
          ->  ProjectSet (actual time=0.168..0.168 rows=7 loops=1)
                Buffers: shared hit=79
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.145..6.611 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3486 read=12
Planning:
  Buffers: shared hit=114
Planning Time: 0.240 ms
Execution Time: 6.911 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.041..5.717 rows=50 loops=1)
  Buffers: shared hit=3719 read=12
  InitPlan 1
    ->  Result (actual time=1.678..1.680 rows=7 loops=1)
          Buffers: shared hit=853
          ->  ProjectSet (actual time=1.677..1.677 rows=7 loops=1)
                Buffers: shared hit=853
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.250..0.256 rows=20 loops=1)
          Buffers: shared hit=197
          ->  ProjectSet (actual time=0.249..0.250 rows=20 loops=1)
                Buffers: shared hit=197
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.040..5.712 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3719 read=12
Planning:
  Buffers: shared hit=109
Planning Time: 0.160 ms
Execution Time: 5.938 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=41.457..41.602 rows=50 loops=1)
  Buffers: shared hit=19410 read=1635
  InitPlan 1
    ->  Result (actual time=32.972..38.488 rows=20007 loops=1)
          Buffers: shared hit=19377 read=1585
          ->  ProjectSet (actual time=32.969..33.603 rows=20007 loops=1)
                Buffers: shared hit=19377 read=1585
                ->  Result (actual time=0.000..0.001 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=41.456..41.598 rows=50 loops=1)
        Index Cond: (id = ANY ((InitPlan 1).col1))
        Buffers: shared hit=19410 read=1635
Planning:
  Buffers: shared hit=87 read=19 dirtied=1
Planning Time: 0.275 ms
Execution Time: 41.872 ms
```

