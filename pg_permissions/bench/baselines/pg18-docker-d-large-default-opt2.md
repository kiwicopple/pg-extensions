# Benchmark: d-per-model (design d), large scale, default shape

- Date: 2026-10-29 18:41
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.21 | 0.31 | 0.216 | 18536 | 1 | ok |
| rbac_select_page | 0.65 | 0.84 | 0.660 | 6056 | 3 | ok |
| rbac_select_count | 0.71 | 0.95 | 0.721 | 5550 | 3 | ok |
| rbac_update_one | 0.28 | 0.50 | 0.316 | 12661 | 3 | ok |
| write_assign_role | 0.14 | 0.22 | 0.146 | 27367 | 1 | ok |
| share_list_objects | 0.36 | 0.74 | 0.388 | 10307 | 2 | ok |
| share_select_page | 1.29 | 3.07 | 1.531 | 2613 | 6 | ok |
| write_share | 0.23 | 0.36 | 0.245 | 16339 | 1 | ok |
| parents_proj_select_page | 1.11 | 1.61 | 1.158 | 3454 | 4 | ok |
| parents_proj_select_count | 8.41 | 11.55 | 8.778 | 455 | 9 | OVER |
| parents_select_page | 1.16 | 7.58 | 2.415 | 1655 | 32 | ok |
| parents_select_count | 8.38 | 14.74 | 9.516 | 420 | 70 | ok |
| write_nest_team | 0.24 | 0.32 | 0.234 | 17110 | 1 | ok |
| nest_check | 0.40 | 0.54 | 0.384 | 10412 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.99 | 5.4 | 20015 |
| sharing | 2.05 | 16.2 | 54086 |
| parents_proj | 0.09 | 16.9 | 56086 |
| parents | 30.42 | 285.0 | 1056086 |
| nesting | 0.02 | 285.0 | 1056087 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| fga_computed_closure | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows |
| fga_edges | 0.02 MB, 0 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows |
| fga_models | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows |
| fga_paths | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows |
| fga_reach | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows |
| fga_relations | 0.02 MB, 0 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows |
| fga_rewrite_nodes | 0.02 MB, 0 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows |
| fga_tuples | 0.02 MB, 0 rows | 10.38 MB, 33997 rows | 11.05 MB, 35997 rows | 279.17 MB, 1035997 rows | 279.17 MB, 1035998 rows |
| fga_type_restrictions | 0.02 MB, 0 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows |
| fga_types | 0.02 MB, 0 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows |
| fga_walk_steps | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows |
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
Limit (actual time=0.795..4.180 rows=50.00 loops=1)
  Buffers: shared hit=3121 read=13
  InitPlan 1
    ->  Result (actual time=0.660..0.661 rows=2.00 loops=1)
          Buffers: shared hit=453
          ->  ProjectSet (actual time=0.659..0.659 rows=2.00 loops=1)
                Buffers: shared hit=453
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.794..4.175 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3121 read=13
Planning:
  Buffers: shared hit=112
Planning Time: 0.170 ms
Execution Time: 4.397 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=5.455..10.245 rows=50.00 loops=1)
  Buffers: shared hit=4127 read=12
  InitPlan 1
    ->  Result (actual time=4.134..4.138 rows=7.00 loops=1)
          Buffers: shared hit=1243
          ->  ProjectSet (actual time=4.132..4.133 rows=7.00 loops=1)
                Buffers: shared hit=1243
                ->  Result (actual time=0.000..0.001 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=1.143..1.145 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=1.141..1.142 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.001 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=5.454..10.237 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4127 read=12
Planning:
  Buffers: shared hit=117
Planning Time: 0.282 ms
Execution Time: 10.584 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.371..6.892 rows=50.00 loops=1)
  Buffers: shared hit=4135 read=12
  InitPlan 1
    ->  Result (actual time=2.815..2.818 rows=7.00 loops=1)
          Buffers: shared hit=1242
          ->  ProjectSet (actual time=2.813..2.815 rows=7.00 loops=1)
                Buffers: shared hit=1242
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.098..0.099 rows=0.00 loops=1)
          Buffers: shared hit=9
          ->  ProjectSet (actual time=0.098..0.098 rows=0.00 loops=1)
                Buffers: shared hit=9
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.315..0.315 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.314..0.314 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.370..6.887 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4135 read=12
Planning:
  Buffers: shared hit=120
Planning Time: 0.211 ms
Execution Time: 7.156 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=3.119..6.596 rows=50.00 loops=1)
  Buffers: shared hit=4067 read=41
  InitPlan 1
    ->  Result (actual time=2.690..2.693 rows=7.00 loops=1)
          Buffers: shared hit=1181 read=31
          ->  ProjectSet (actual time=2.689..2.690 rows=7.00 loops=1)
                Buffers: shared hit=1181 read=31
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.300..0.301 rows=2.00 loops=1)
          Buffers: shared hit=212 read=2
          ->  ProjectSet (actual time=0.300..0.300 rows=2.00 loops=1)
                Buffers: shared hit=212 read=2
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.118..6.592 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4067 read=41
Planning:
  Buffers: shared hit=135 read=10
Planning Time: 0.277 ms
Execution Time: 6.964 ms
```

