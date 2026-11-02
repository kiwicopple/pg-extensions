# Benchmark: pg_permissions--0.0.1 (design d), large scale, default shape

- Date: 2026-10-30 16:25
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.17 | 0.38 | 0.175 | 22868 | 1 | ok |
| rbac_select_page | 0.72 | 2.06 | 0.926 | 4319 | 3 | ok |
| rbac_select_count | 0.76 | 1.56 | 0.883 | 4532 | 3 | ok |
| rbac_update_one | 0.24 | 0.54 | 0.254 | 15737 | 3 | ok |
| write_assign_role | 0.12 | 0.27 | 0.125 | 32082 | 1 | ok |
| share_list_objects | 0.27 | 0.62 | 0.292 | 13720 | 2 | ok |
| share_select_page | 1.05 | 2.38 | 1.236 | 3236 | 6 | ok |
| write_share | 0.14 | 0.33 | 0.150 | 26600 | 1 | ok |
| parents_proj_select_page | 1.04 | 1.90 | 1.165 | 3434 | 4 | ok |
| parents_proj_select_count | 7.89 | 13.25 | 8.902 | 449 | 9 | OVER |
| parents_select_page | 1.05 | 6.99 | 2.213 | 1807 | 32 | ok |
| parents_select_count | 7.76 | 13.26 | 8.787 | 455 | 70 | ok |
| write_nest_team | 0.15 | 0.29 | 0.157 | 25539 | 1 | ok |
| nest_check | 0.38 | 0.66 | 0.392 | 10199 | 2 | ok |
| plain_list_objects | 0.33 | 1.94 | 0.615 | 6499 | - | - |
| cond_list_objects | 0.65 | 3.08 | 1.140 | 3507 | - | - |
| cond_select_page | 1.51 | 8.47 | 2.913 | 1373 | - | - |
| cond_nest_check | 0.56 | 1.24 | 0.640 | 6254 | - | - |
| plain_list_users | 0.33 | 1.57 | 0.660 | 6059 | - | - |
| cond_list_users | 0.52 | 2.36 | 1.021 | 3917 | - | - |
| block_list_objects | 0.42 | 2.31 | 0.770 | 5192 | - | - |
| block_or_mute_list_objects | 0.54 | 2.62 | 0.947 | 4224 | - | - |
| intersect_list_objects | 0.49 | 2.68 | 0.934 | 4281 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.39 | 5.4 | 20015 |
| sharing | 1.04 | 17.9 | 54086 |
| parents_proj | 0.05 | 18.6 | 56086 |
| parents | 15.35 | 323.7 | 1056086 |
| nesting | 0.02 | 323.7 | 1056087 |
| conditions | 1.37 | 329.5 | 1070203 |
| blocklist | 0.78 | 337.0 | 1090438 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting | after conditions | after blocklist |
| --- | --- | --- | --- | --- | --- | --- | --- |
| fga_computed_closure | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 3 rows | 0.08 MB, 11 rows |
| fga_conditions | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.06 MB, 1 rows | 0.06 MB, 2 rows |
| fga_edges | 0.02 MB, 0 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 24 rows | 0.08 MB, 45 rows |
| fga_models | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 2 rows | 0.08 MB, 3 rows |
| fga_paths | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 33 rows | 0.06 MB, 78 rows |
| fga_reach | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 33 rows | 0.06 MB, 75 rows |
| fga_relations | 0.02 MB, 0 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 12 rows | 0.06 MB, 24 rows |
| fga_rewrite_nodes | 0.02 MB, 0 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 21 rows | 0.06 MB, 47 rows |
| fga_tuples | 0.04 MB, 0 rows | 12.03 MB, 33997 rows | 12.77 MB, 35997 rows | 317.85 MB, 1035997 rows | 317.85 MB, 1035998 rows | 323.55 MB, 1049996 rows | 331.04 MB, 1069996 rows |
| fga_type_restrictions | 0.02 MB, 0 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 18 rows | 0.06 MB, 31 rows |
| fga_types | 0.02 MB, 0 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 9 rows | 0.06 MB, 14 rows |
| fga_walk_steps | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 36 rows | 0.07 MB, 97 rows |
| rbac_assignments | 4.90 MB, 20000 rows | 4.90 MB, 20000 rows | 4.90 MB, 20000 rows | 4.90 MB, 20000 rows | 4.90 MB, 20000 rows | 4.90 MB, 20000 rows | 4.90 MB, 20000 rows |
| rbac_role_closure | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |
| rbac_role_inherits | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows |
| rbac_role_permissions | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |

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
| conditions | 1 | 20007 | d2b4030ad636f968f35a8af5008ac9f6 |
| conditions | 2 | 20007 | abb87f25aaf62620d8b791efa17462b4 |
| conditions | 3 | 20012 | b4c68ea1387b14cdb659ac1be1bc314a |
| conditions | 5 | 21012 | 62038fc0969395160b3e96933ddac9e4 |
| conditions | 10 | 21012 | 447d15cf1ccb48b8a791f10de5616989 |
| conditions | 77 | 20022 | eb1cd8028cf96891dd907c58dd08b89f |
| conditions | 500 | 21007 | d357b76a845e832d77fdd55403df4e56 |
| conditions | 10000 | 21007 | 24fc32209c7c854bc0f098b1e1d6940d |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-30 10:48): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-30 10:52): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 10:55): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.764..4.177 rows=50.00 loops=1)
  Buffers: shared hit=3093 read=13
  InitPlan 1
    ->  Result (actual time=0.622..0.623 rows=2.00 loops=1)
          Buffers: shared hit=425
          ->  ProjectSet (actual time=0.621..0.621 rows=2.00 loops=1)
                Buffers: shared hit=425
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.763..4.172 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3093 read=13
Planning:
  Buffers: shared hit=142
Planning Time: 0.181 ms
Execution Time: 4.413 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=3.333..6.952 rows=50.00 loops=1)
  Buffers: shared hit=4177 read=12
  InitPlan 1
    ->  Result (actual time=2.827..2.830 rows=7.00 loops=1)
          Buffers: shared hit=1293
          ->  ProjectSet (actual time=2.825..2.827 rows=7.00 loops=1)
                Buffers: shared hit=1293
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.359..0.360 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.358..0.359 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.333..6.947 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4177 read=12
Planning:
  Buffers: shared hit=147
Planning Time: 0.230 ms
Execution Time: 7.158 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.187..6.451 rows=50.00 loops=1)
  Buffers: shared hit=4186 read=12
  InitPlan 1
    ->  Result (actual time=2.649..2.652 rows=7.00 loops=1)
          Buffers: shared hit=1293
          ->  ProjectSet (actual time=2.648..2.649 rows=7.00 loops=1)
                Buffers: shared hit=1293
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.105..0.105 rows=0.00 loops=1)
          Buffers: shared hit=9
          ->  ProjectSet (actual time=0.105..0.105 rows=0.00 loops=1)
                Buffers: shared hit=9
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.308..0.308 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.307..0.308 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.186..6.446 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4186 read=12
Planning:
  Buffers: shared hit=150
Planning Time: 0.221 ms
Execution Time: 6.665 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=2.971..6.174 rows=50.00 loops=1)
  Buffers: shared hit=4163 read=52
  InitPlan 1
    ->  Result (actual time=2.574..2.577 rows=7.00 loops=1)
          Buffers: shared hit=1277 read=42
          ->  ProjectSet (actual time=2.574..2.574 rows=7.00 loops=1)
                Buffers: shared hit=1277 read=42
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.295..0.296 rows=2.00 loops=1)
          Buffers: shared hit=212 read=2
          ->  ProjectSet (actual time=0.294..0.295 rows=2.00 loops=1)
                Buffers: shared hit=212 read=2
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.970..6.170 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4163 read=52
Planning:
  Buffers: shared hit=105 read=10
Planning Time: 0.260 ms
Execution Time: 6.390 ms
```

