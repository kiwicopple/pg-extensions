# Benchmark: pg_permissions--0.0.1 (design d), large scale, default shape

- Date: 2026-10-30 16:40
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.21 | 0.31 | 0.204 | 19647 | 1 | ok |
| rbac_select_page | 0.65 | 0.89 | 0.676 | 5917 | 3 | ok |
| rbac_select_count | 0.72 | 0.99 | 0.737 | 5428 | 3 | ok |
| rbac_update_one | 0.26 | 0.35 | 0.246 | 16239 | 3 | ok |
| write_assign_role | 0.14 | 0.20 | 0.132 | 30314 | 1 | ok |
| share_list_objects | 0.29 | 0.40 | 0.275 | 14563 | 2 | ok |
| share_select_page | 0.95 | 1.35 | 1.001 | 3996 | 6 | ok |
| write_share | 0.15 | 0.21 | 0.148 | 27035 | 1 | ok |
| parents_proj_select_page | 1.03 | 1.41 | 1.065 | 3756 | 4 | ok |
| parents_proj_select_count | 7.49 | 8.24 | 7.572 | 528 | 20 | ok |
| parents_select_page | 1.05 | 6.96 | 2.180 | 1835 | 32 | ok |
| parents_select_count | 7.48 | 12.08 | 8.151 | 490 | 70 | ok |
| write_nest_team | 0.15 | 0.22 | 0.153 | 26214 | 1 | ok |
| nest_check | 0.41 | 0.51 | 0.419 | 9553 | 2 | ok |
| plain_list_objects | 0.32 | 1.78 | 0.567 | 7054 | - | - |
| cond_list_objects | 0.52 | 2.26 | 0.817 | 4895 | - | - |
| cond_select_page | 1.22 | 7.30 | 2.377 | 1682 | - | - |
| cond_nest_check | 0.55 | 0.70 | 0.544 | 7346 | - | - |
| plain_list_users | 0.30 | 1.46 | 0.524 | 7632 | - | - |
| cond_list_users | 0.45 | 1.87 | 0.729 | 5486 | - | - |
| block_list_objects | 0.39 | 1.93 | 0.645 | 6204 | - | - |
| block_or_mute_list_objects | 0.55 | 2.43 | 0.872 | 4586 | - | - |
| intersect_list_objects | 0.45 | 2.13 | 0.730 | 5475 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 3.84 | 5.4 | 20015 |
| sharing | 0.79 | 17.9 | 54086 |
| parents_proj | 0.04 | 18.6 | 56086 |
| parents | 15.56 | 323.7 | 1056086 |
| nesting | 0.01 | 323.7 | 1056087 |
| conditions | 1.06 | 329.5 | 1070203 |
| blocklist | 0.64 | 337.0 | 1090438 |

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
- vs design a (2026-10-30 16:28): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-30 16:31): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 16:34): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.883..4.484 rows=50.00 loops=1)
  Buffers: shared hit=3121 read=13
  InitPlan 1
    ->  Result (actual time=0.758..0.759 rows=2.00 loops=1)
          Buffers: shared hit=453
          ->  ProjectSet (actual time=0.757..0.758 rows=2.00 loops=1)
                Buffers: shared hit=453
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.882..4.480 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3121 read=13
Planning:
  Buffers: shared hit=112
Planning Time: 0.159 ms
Execution Time: 4.716 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=4.299..7.734 rows=50.00 loops=1)
  Buffers: shared hit=4205 read=12
  InitPlan 1
    ->  Result (actual time=3.847..3.850 rows=7.00 loops=1)
          Buffers: shared hit=1321
          ->  ProjectSet (actual time=3.845..3.847 rows=7.00 loops=1)
                Buffers: shared hit=1321
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.324..0.325 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.323..0.324 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=4.299..7.729 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4205 read=12
Planning:
  Buffers: shared hit=117
Planning Time: 0.257 ms
Execution Time: 8.029 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.167..6.088 rows=50.00 loops=1)
  Buffers: shared hit=4187 read=12
  InitPlan 1
    ->  Result (actual time=2.662..2.664 rows=7.00 loops=1)
          Buffers: shared hit=1294
          ->  ProjectSet (actual time=2.661..2.661 rows=7.00 loops=1)
                Buffers: shared hit=1294
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.099..0.099 rows=0.00 loops=1)
          Buffers: shared hit=9
          ->  ProjectSet (actual time=0.099..0.099 rows=0.00 loops=1)
                Buffers: shared hit=9
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.289..0.290 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.288..0.289 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.166..6.083 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4187 read=12
Planning:
  Buffers: shared hit=150
Planning Time: 0.287 ms
Execution Time: 6.323 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=2.970..5.959 rows=50.00 loops=1)
  Buffers: shared hit=4163 read=52
  InitPlan 1
    ->  Result (actual time=2.544..2.547 rows=7.00 loops=1)
          Buffers: shared hit=1277 read=42
          ->  ProjectSet (actual time=2.543..2.544 rows=7.00 loops=1)
                Buffers: shared hit=1277 read=42
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.306..0.307 rows=2.00 loops=1)
          Buffers: shared hit=212 read=2
          ->  ProjectSet (actual time=0.305..0.306 rows=2.00 loops=1)
                Buffers: shared hit=212 read=2
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.969..5.955 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4163 read=52
Planning:
  Buffers: shared hit=106 read=9
Planning Time: 0.193 ms
Execution Time: 6.192 ms
```

