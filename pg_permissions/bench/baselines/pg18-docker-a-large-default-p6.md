# Benchmark: a-tuple-core (design a), large scale, default shape

- Date: 2026-10-30 16:28
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.48 | 0.267 | 14963 | 1 | ok |
| rbac_select_page | 0.74 | 1.96 | 0.921 | 4344 | 3 | ok |
| rbac_select_count | 0.79 | 1.41 | 0.861 | 4643 | 3 | ok |
| rbac_update_one | 0.52 | 1.09 | 0.574 | 6965 | 3 | ok |
| write_assign_role | 0.14 | 0.27 | 0.144 | 27746 | 1 | ok |
| share_list_objects | 0.28 | 0.67 | 0.324 | 12341 | 2 | ok |
| share_select_page | 1.06 | 1.90 | 1.159 | 3452 | 6 | ok |
| write_share | 0.14 | 0.24 | 0.133 | 30089 | 1 | ok |
| parents_proj_select_page | 1.36 | 3.11 | 1.635 | 2446 | 4 | ok |
| parents_proj_select_count | 8.70 | 16.10 | 10.014 | 399 | 9 | OVER |
| parents_select_page | 43.54 | 57.54 | 44.217 | 90 | 32 | OVER |
| parents_select_count | 69.89 | 80.93 | 70.127 | 57 | 70 | OVER |
| write_nest_team | 0.14 | 0.21 | 0.143 | 28041 | 1 | ok |
| nest_check | 0.29 | 0.41 | 0.289 | 13856 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.71 | 7.0 | 20020 |
| sharing | 1.06 | 18.7 | 54022 |
| parents_proj | 0.07 | 19.6 | 57025 |
| parents | 29.76 | 404.3 | 1057026 |
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
- vs design b (2026-10-30 10:52): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 10:55): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design d (2026-10-30 16:25): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=1.780..5.021 rows=50.00 loops=1)
  Buffers: shared hit=3376 read=13
  InitPlan 1
    ->  Result (actual time=1.655..1.656 rows=2.00 loops=1)
          Buffers: shared hit=708
          ->  ProjectSet (actual time=1.654..1.655 rows=2.00 loops=1)
                Buffers: shared hit=708
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.779..5.017 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3376 read=13
Planning:
  Buffers: shared hit=112
Planning Time: 0.152 ms
Execution Time: 5.208 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.175..6.181 rows=50.00 loops=1)
  Buffers: shared hit=3482 read=12
  InitPlan 1
    ->  Result (actual time=1.874..1.875 rows=2.00 loops=1)
          Buffers: shared hit=733
          ->  ProjectSet (actual time=1.873..1.874 rows=2.00 loops=1)
                Buffers: shared hit=733
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.164..0.167 rows=7.00 loops=1)
          Buffers: shared hit=79
          ->  ProjectSet (actual time=0.163..0.164 rows=7.00 loops=1)
                Buffers: shared hit=79
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.175..6.176 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3482 read=12
Planning:
  Buffers: shared hit=117
Planning Time: 0.224 ms
Execution Time: 6.526 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.513..6.794 rows=50.00 loops=1)
  Buffers: shared hit=3715 read=12
  InitPlan 1
    ->  Result (actual time=2.075..2.078 rows=7.00 loops=1)
          Buffers: shared hit=848
          ->  ProjectSet (actual time=2.074..2.075 rows=7.00 loops=1)
                Buffers: shared hit=848
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.287..0.294 rows=20.00 loops=1)
          Buffers: shared hit=197
          ->  ProjectSet (actual time=0.286..0.287 rows=20.00 loops=1)
                Buffers: shared hit=197
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.512..6.788 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3715 read=12
Planning:
  Buffers: shared hit=114
Planning Time: 0.176 ms
Execution Time: 7.026 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=39.887..40.030 rows=50.00 loops=1)
  Buffers: shared hit=19433 read=1609 written=2
  InitPlan 1
    ->  Result (actual time=31.725..37.053 rows=20007.00 loops=1)
          Buffers: shared hit=19400 read=1559 written=2
          ->  ProjectSet (actual time=31.723..32.346 rows=20007.00 loops=1)
                Buffers: shared hit=19400 read=1559 written=2
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=39.886..40.026 rows=50.00 loops=1)
        Index Cond: (id = ANY ((InitPlan 1).col1))
        Index Searches: 11
        Buffers: shared hit=19433 read=1609 written=2
Planning:
  Buffers: shared hit=86 read=23 dirtied=1
Planning Time: 0.240 ms
Execution Time: 40.258 ms
```

