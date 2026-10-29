# Benchmark: b-policy-first (design b), large scale, default shape

- Date: 2026-10-29 08:09
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.26 | 0.34 | 0.254 | 15752 | 1 | ok |
| rbac_select_page | 0.77 | 0.94 | 0.773 | 5175 | 3 | ok |
| rbac_select_count | 0.85 | 1.06 | 0.863 | 4636 | 3 | ok |
| rbac_update_one | 0.52 | 0.64 | 0.502 | 7962 | 3 | ok |
| write_assign_role | 0.14 | 0.20 | 0.144 | 27789 | 1 | ok |
| share_list_objects | 0.29 | 0.36 | 0.276 | 14489 | 2 | ok |
| share_select_page | 1.16 | 1.42 | 1.179 | 3391 | 6 | ok |
| write_share | 0.14 | 0.20 | 0.146 | 27338 | 1 | ok |
| parents_proj_select_page | 1.30 | 1.54 | 1.314 | 3044 | 4 | ok |
| parents_proj_select_count | 7.79 | 8.46 | 7.785 | 513 | 9 | ok |
| parents_select_page | 102.18 | 127.71 | 102.984 | 38 | 32 | OVER |
| parents_select_count | 121.95 | 140.37 | 122.093 | 32 | 70 | OVER |
| write_nest_team | 106.63 | 126.08 | 106.724 | 37 | 1 | OVER |
| nest_check | 1.14 | 1.37 | 1.156 | 3461 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.06 | 5.3 | 20028 |
| sharing | 1.05 | 25.4 | 99977 |
| parents_proj | 0.14 | 26.4 | 103981 |
| parents | 121.15 | 762.8 | 3103981 |
| nesting | 0.05 | 763.9 | 3108987 |

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
- vs design a (2026-10-29 08:04): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 08:01): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.683..4.121 rows=50.00 loops=1)
  Buffers: shared hit=2698 read=13
  InitPlan 1
    ->  Result (actual time=0.553..0.554 rows=2.00 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.552..0.553 rows=2.00 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.682..4.117 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=2698 read=13
Planning:
  Buffers: shared hit=819
Planning Time: 2.410 ms
Execution Time: 4.128 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.933..4.144 rows=50.00 loops=1)
  Buffers: shared hit=2730 read=12
  InitPlan 1
    ->  Result (actual time=0.500..0.501 rows=2.00 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.499..0.500 rows=2.00 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.316..0.319 rows=7.00 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.316..0.316 rows=7.00 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.932..4.139 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=2730 read=12
Planning:
  Buffers: shared hit=868
Planning Time: 2.814 ms
Execution Time: 4.152 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=1.051..4.504 rows=50.00 loops=1)
  Buffers: shared hit=2778 read=12
  InitPlan 1
    ->  Result (actual time=0.515..0.518 rows=7.00 loops=1)
          Buffers: shared hit=54
          ->  ProjectSet (actual time=0.515..0.515 rows=7.00 loops=1)
                Buffers: shared hit=54
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.428..0.434 rows=20.00 loops=1)
          Buffers: shared hit=54
          ->  ProjectSet (actual time=0.427..0.428 rows=20.00 loops=1)
                Buffers: shared hit=54
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.051..4.500 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=2778 read=12
Planning:
  Buffers: shared hit=911
Planning Time: 3.234 ms
Execution Time: 4.512 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=25.351..25.495 rows=50.00 loops=1)
  Buffers: shared hit=19870 read=202
  InitPlan 1
    ->  Result (actual time=19.444..24.591 rows=20007.00 loops=1)
          Buffers: shared hit=19848 read=141
          ->  ProjectSet (actual time=19.443..20.047 rows=20007.00 loops=1)
                Buffers: shared hit=19848 read=141
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=25.351..25.492 rows=50.00 loops=1)
        Index Cond: (id = ANY ((InitPlan 1).col1))
        Index Searches: 11
        Buffers: shared hit=19870 read=202
Planning:
  Buffers: shared hit=17989 read=2800 dirtied=1 written=1
Planning Time: 32.692 ms
Execution Time: 25.506 ms
```

