# Benchmark: a-tuple-core (design a), large scale, default shape

- Date: 2026-10-29 13:01
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.30 | 0.56 | 0.332 | 12053 | 1 | ok |
| rbac_select_page | 0.76 | 1.44 | 0.852 | 4695 | 3 | ok |
| rbac_select_count | 0.78 | 1.07 | 0.807 | 4954 | 3 | ok |
| rbac_update_one | 0.47 | 0.65 | 0.481 | 8319 | 3 | ok |
| write_assign_role | 0.15 | 0.23 | 0.163 | 24527 | 1 | ok |
| share_list_objects | 0.29 | 0.38 | 0.283 | 14121 | 2 | ok |
| share_select_page | 1.03 | 1.35 | 1.077 | 3714 | 6 | ok |
| write_share | 0.15 | 0.23 | 0.161 | 24916 | 1 | ok |
| parents_proj_select_page | 1.33 | 2.62 | 1.528 | 2617 | 4 | ok |
| parents_proj_select_count | 8.42 | 14.66 | 9.407 | 425 | 9 | OVER |
| parents_select_page | 45.65 | 66.27 | 47.693 | 83 | 32 | OVER |
| parents_select_count | 75.08 | 92.44 | 76.509 | 52 | 70 | OVER |
| write_nest_team | 0.15 | 0.27 | 0.170 | 23579 | 1 | ok |
| nest_check | 0.31 | 0.48 | 0.333 | 12026 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 5.14 | 7.0 | 20020 |
| sharing | 0.65 | 18.7 | 54022 |
| parents_proj | 0.08 | 19.6 | 57025 |
| parents | 31.02 | 404.3 | 1057026 |
| nesting | 0.05 | 404.3 | 1057027 |

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
- vs design b (2026-10-29 12:06): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 12:09): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.498..5.975 rows=50.00 loops=1)
  Buffers: shared hit=3376 read=13
  InitPlan 1
    ->  Result (actual time=2.289..2.292 rows=2.00 loops=1)
          Buffers: shared hit=708
          ->  ProjectSet (actual time=2.289..2.289 rows=2.00 loops=1)
                Buffers: shared hit=708
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.498..5.968 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3376 read=13
Planning:
  Buffers: shared hit=112
Planning Time: 0.211 ms
Execution Time: 6.244 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=3.092..7.163 rows=50.00 loops=1)
  Buffers: shared hit=3481 read=12
  InitPlan 1
    ->  Result (actual time=2.688..2.689 rows=2.00 loops=1)
          Buffers: shared hit=733
          ->  ProjectSet (actual time=2.687..2.688 rows=2.00 loops=1)
                Buffers: shared hit=733
                ->  Result (actual time=0.000..0.001 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.196..0.201 rows=7.00 loops=1)
          Buffers: shared hit=79
          ->  ProjectSet (actual time=0.195..0.197 rows=7.00 loops=1)
                Buffers: shared hit=79
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.091..7.158 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3481 read=12
Planning:
  Buffers: shared hit=115
Planning Time: 0.264 ms
Execution Time: 7.474 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.634..6.281 rows=50.00 loops=1)
  Buffers: shared hit=3714 read=12
  InitPlan 1
    ->  Result (actual time=2.239..2.242 rows=7.00 loops=1)
          Buffers: shared hit=848
          ->  ProjectSet (actual time=2.238..2.239 rows=7.00 loops=1)
                Buffers: shared hit=848
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.208..0.214 rows=20.00 loops=1)
          Buffers: shared hit=197
          ->  ProjectSet (actual time=0.208..0.209 rows=20.00 loops=1)
                Buffers: shared hit=197
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.633..6.278 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3714 read=12
Planning:
  Buffers: shared hit=114
Planning Time: 0.262 ms
Execution Time: 6.620 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=40.453..40.607 rows=50.00 loops=1)
  Buffers: shared hit=19101 read=1942 written=3
  InitPlan 1
    ->  Result (actual time=31.997..37.462 rows=20007.00 loops=1)
          Buffers: shared hit=19079 read=1881 written=3
          ->  ProjectSet (actual time=31.995..32.617 rows=20007.00 loops=1)
                Buffers: shared hit=19079 read=1881 written=3
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=40.452..40.603 rows=50.00 loops=1)
        Index Cond: (id = ANY ((InitPlan 1).col1))
        Index Searches: 11
        Buffers: shared hit=19101 read=1942 written=3
Planning:
  Buffers: shared hit=85 read=24 dirtied=1
Planning Time: 0.456 ms
Execution Time: 40.963 ms
```

