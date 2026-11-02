# Benchmark: b-policy-first (design b), large scale, default shape

- Date: 2026-10-30 16:31
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.35 | 0.254 | 15748 | 1 | ok |
| rbac_select_page | 0.71 | 0.92 | 0.728 | 5496 | 3 | ok |
| rbac_select_count | 0.78 | 1.02 | 0.787 | 5082 | 3 | ok |
| rbac_update_one | 0.40 | 0.57 | 0.426 | 9394 | 3 | ok |
| write_assign_role | 0.14 | 0.21 | 0.133 | 30016 | 1 | ok |
| share_list_objects | 0.28 | 0.39 | 0.265 | 15089 | 2 | ok |
| share_select_page | 1.00 | 1.27 | 1.014 | 3943 | 6 | ok |
| write_share | 0.14 | 0.20 | 0.130 | 30801 | 1 | ok |
| parents_proj_select_page | 1.15 | 1.56 | 1.185 | 3374 | 4 | ok |
| parents_proj_select_count | 7.74 | 8.49 | 7.753 | 515 | 9 | ok |
| parents_select_page | 13.46 | 16.38 | 13.858 | 288 | 32 | ok |
| parents_select_count | 21.21 | 26.61 | 22.005 | 181 | 70 | ok |
| write_nest_team | 0.61 | 0.70 | 0.622 | 6431 | 1 | ok |
| nest_check | 0.32 | 0.41 | 0.295 | 13565 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 3.82 | 7.4 | 20028 |
| sharing | 0.82 | 19.6 | 55697 |
| parents_proj | 0.10 | 20.6 | 58701 |
| parents | 43.26 | 377.9 | 1059701 |
| nesting | 0.02 | 377.9 | 1059707 |

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
- vs design a (2026-10-30 16:28): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 10:55): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design d (2026-10-30 16:25): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.535..5.703 rows=50.00 loops=1)
  Buffers: shared hit=3543 read=13
  InitPlan 1
    ->  Result (actual time=2.419..2.420 rows=2.00 loops=1)
          Buffers: shared hit=875
          ->  ProjectSet (actual time=2.418..2.419 rows=2.00 loops=1)
                Buffers: shared hit=875
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.535..5.699 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3543 read=13
Planning:
  Buffers: shared hit=112
Planning Time: 0.140 ms
Execution Time: 5.899 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=3.736..7.330 rows=50.00 loops=1)
  Buffers: shared hit=3549 read=12
  InitPlan 1
    ->  Result (actual time=3.465..3.466 rows=2.00 loops=1)
          Buffers: shared hit=856
          ->  ProjectSet (actual time=3.464..3.465 rows=2.00 loops=1)
                Buffers: shared hit=856
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.172..0.174 rows=7.00 loops=1)
          Buffers: shared hit=24
          ->  ProjectSet (actual time=0.171..0.172 rows=7.00 loops=1)
                Buffers: shared hit=24
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.736..7.325 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3549 read=12
Planning:
  Buffers: shared hit=147
Planning Time: 0.234 ms
Execution Time: 7.540 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.987..7.525 rows=50.00 loops=1)
  Buffers: shared hit=3574 read=12
  InitPlan 1
    ->  Result (actual time=3.705..3.707 rows=7.00 loops=1)
          Buffers: shared hit=868
          ->  ProjectSet (actual time=3.704..3.704 rows=7.00 loops=1)
                Buffers: shared hit=868
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.163..0.169 rows=20.00 loops=1)
          Buffers: shared hit=37
          ->  ProjectSet (actual time=0.162..0.163 rows=20.00 loops=1)
                Buffers: shared hit=37
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.986..7.520 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3574 read=12
Planning:
  Buffers: shared hit=144
Planning Time: 0.251 ms
Execution Time: 7.744 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=18.545..18.765 rows=50.00 loops=1)
  Buffers: shared hit=1342 read=41
  InitPlan 1
    ->  Result (actual time=10.126..15.548 rows=20007.00 loops=1)
          Buffers: shared hit=1300
          ->  ProjectSet (actual time=10.125..10.780 rows=20007.00 loops=1)
                Buffers: shared hit=1300
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=18.544..18.762 rows=50.00 loops=1)
        Index Cond: (id = ANY ((InitPlan 1).col1))
        Index Searches: 11
        Buffers: shared hit=1342 read=41
Planning:
  Buffers: shared hit=109
Planning Time: 0.165 ms
Execution Time: 18.979 ms
```

