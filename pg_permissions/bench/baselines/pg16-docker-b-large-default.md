# Benchmark: b-policy-first (design b), large scale, default shape

- Date: 2026-10-29 07:47
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.35 | 0.47 | 0.345 | 11597 | 1 | ok |
| rbac_select_page | 0.84 | 1.04 | 0.846 | 4728 | 3 | ok |
| rbac_select_count | 0.94 | 1.24 | 0.959 | 4170 | 3 | ok |
| rbac_update_one | 0.81 | 1.11 | 0.798 | 5012 | 3 | ok |
| write_assign_role | 0.17 | 0.25 | 0.175 | 22870 | 1 | ok |
| share_list_objects | 0.31 | 0.41 | 0.294 | 13619 | 2 | ok |
| share_select_page | 1.25 | 1.55 | 1.274 | 3138 | 6 | ok |
| write_share | 0.16 | 0.23 | 0.165 | 24257 | 1 | ok |
| parents_proj_select_page | 1.41 | 1.83 | 1.459 | 2742 | 4 | ok |
| parents_proj_select_count | 8.37 | 9.97 | 8.524 | 469 | 9 | OVER |
| parents_select_page | 95.36 | 116.04 | 96.103 | 41 | 32 | OVER |
| parents_select_count | 115.91 | 136.06 | 115.929 | 34 | 70 | OVER |
| write_nest_team | 107.31 | 126.46 | 108.462 | 36 | 1 | OVER |
| nest_check | 1.30 | 1.49 | 1.302 | 3071 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.21 | 5.3 | 20028 |
| sharing | 0.97 | 25.4 | 99977 |
| parents_proj | 0.14 | 26.4 | 103981 |
| parents | 119.79 | 762.8 | 3103981 |
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
- vs design a (2026-10-29 07:43): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-28 23:49): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.640..3.702 rows=50 loops=1)
  Buffers: shared hit=2698 read=13
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.533..0.534 rows=2 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.532..0.533 rows=2 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.639..3.698 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2698 read=13
Planning:
  Buffers: shared hit=815
Planning Time: 2.123 ms
Execution Time: 3.709 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.839..4.053 rows=50 loops=1)
  Buffers: shared hit=2730 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.470..0.471 rows=2 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.469..0.470 rows=2 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.280..0.282 rows=7 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.279..0.280 rows=7 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.838..4.050 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2730 read=12
Planning:
  Buffers: shared hit=861
Planning Time: 2.813 ms
Execution Time: 4.063 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=0.852..4.030 rows=50 loops=1)
  Buffers: shared hit=2778 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.459..0.462 rows=7 loops=1)
          Buffers: shared hit=54
          ->  ProjectSet (actual time=0.459..0.459 rows=7 loops=1)
                Buffers: shared hit=54
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.295..0.301 rows=20 loops=1)
          Buffers: shared hit=54
          ->  ProjectSet (actual time=0.294..0.295 rows=20 loops=1)
                Buffers: shared hit=54
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.852..4.026 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2778 read=12
Planning:
  Buffers: shared hit=908
Planning Time: 2.581 ms
Execution Time: 4.037 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=30.576..30.736 rows=50 loops=1)
  Buffers: shared hit=15922 read=4288 written=1
  InitPlan 1 (returns $0)
    ->  Result (actual time=24.376..29.664 rows=20007 loops=1)
          Buffers: shared hit=15769 read=4238 written=1
          ->  ProjectSet (actual time=24.374..25.010 rows=20007 loops=1)
                Buffers: shared hit=15769 read=4238 written=1
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=30.575..30.732 rows=50 loops=1)
        Index Cond: (id = ANY ($0))
        Buffers: shared hit=15922 read=4288 written=1
Planning:
  Buffers: shared hit=17599 read=3201 dirtied=1 written=1
Planning Time: 30.591 ms
Execution Time: 30.748 ms
```

