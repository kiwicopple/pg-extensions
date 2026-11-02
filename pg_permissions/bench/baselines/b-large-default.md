# Benchmark: b-policy-first (design b), large scale, default shape

- Date: 2026-10-28 23:46
- Postgres: 16.4 (Postgres.app)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.33 | 0.48 | 0.345 | 11592 | 1 | ok |
| rbac_select_page | 0.62 | 0.99 | 0.673 | 5940 | 3 | ok |
| rbac_select_count | 0.76 | 0.82 | 0.769 | 5203 | 3 | ok |
| rbac_update_one | 0.79 | 0.86 | 0.735 | 5444 | 3 | ok |
| write_assign_role | 0.14 | 0.24 | 0.156 | 25628 | 1 | ok |
| share_list_objects | 0.31 | 0.38 | 0.317 | 12613 | 2 | ok |
| share_select_page | 1.21 | 1.41 | 1.227 | 3260 | 6 | ok |
| write_share | 0.14 | 0.25 | 0.156 | 25669 | 1 | ok |
| parents_proj_select_page | 1.44 | 1.66 | 1.455 | 2749 | - | - |
| parents_proj_select_count | 3.21 | 3.39 | 3.216 | 1243 | - | - |
| parents_select_page | 197.22 | 251.96 | 204.321 | 19 | - | - |
| parents_select_count | 226.11 | 266.63 | 228.353 | 17 | - | - |
| write_nest_team | 285.44 | 325.98 | 283.430 | 14 | - | - |
| nest_check | 2.60 | 2.83 | 2.623 | 1524 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.56 | 5.3 | 20028 |
| sharing | 1.71 | 25.4 | 99977 |
| parents_proj | 0.22 | 26.4 | 103981 |
| parents | 167.23 | 762.8 | 3103981 |
| nesting | 0.11 | 763.9 | 3108987 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 10.55 MB, 45944 rows | 10.80 MB, 46944 rows | 502.12 MB, 2046944 rows | 503.26 MB, 2051949 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 2.72 MB, 11497 rows | 2.95 MB, 12497 rows | 248.05 MB, 1012497 rows | 248.05 MB, 1012498 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 5.00 MB, 20000 rows | 11.83 MB, 42500 rows | 12.33 MB, 44500 rows | 12.33 MB, 44500 rows | 12.33 MB, 44500 rows |
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
- vs design a (2026-10-28 23:40): parents_proj: same; rbac: same; parents: same; sharing: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.515..2.756 rows=50 loops=1)
  Buffers: shared hit=2698 read=13
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.456..0.457 rows=2 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.456..0.456 rows=2 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.514..2.754 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2698 read=13
Planning:
  Buffers: shared hit=815
Planning Time: 2.344 ms
Execution Time: 2.761 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.810..3.370 rows=50 loops=1)
  Buffers: shared hit=2729 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.448..0.449 rows=2 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.448..0.448 rows=2 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.304..0.306 rows=7 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.303..0.304 rows=7 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.810..3.368 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2729 read=12
Planning:
  Buffers: shared hit=863
Planning Time: 2.929 ms
Execution Time: 3.378 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=0.955..3.554 rows=50 loops=1)
  Buffers: shared hit=2777 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.486..0.488 rows=7 loops=1)
          Buffers: shared hit=54
          ->  ProjectSet (actual time=0.486..0.486 rows=7 loops=1)
                Buffers: shared hit=54
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.396..0.401 rows=20 loops=1)
          Buffers: shared hit=54
          ->  ProjectSet (actual time=0.395..0.396 rows=20 loops=1)
                Buffers: shared hit=54
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.955..3.552 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2777 read=12
Planning:
  Buffers: shared hit=906 dirtied=1
Planning Time: 3.310 ms
Execution Time: 3.561 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=79.727..79.863 rows=50 loops=1)
  Buffers: shared hit=15662 read=4550 written=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=74.334..79.056 rows=20007 loops=1)
          Buffers: shared hit=15511 read=4498 written=3
          ->  ProjectSet (actual time=74.334..74.763 rows=20007 loops=1)
                Buffers: shared hit=15511 read=4498 written=3
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=79.727..79.860 rows=50 loops=1)
        Index Cond: (id = ANY ($0))
        Buffers: shared hit=15662 read=4550 written=3
Planning:
  Buffers: shared hit=17260 read=3542 dirtied=1
Planning Time: 82.314 ms
Execution Time: 79.871 ms
```

