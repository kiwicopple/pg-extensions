# Benchmark: opt3-before-0bd650b (design d), large scale, default shape

- Date: 2026-10-30 11:44
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.22 | 0.31 | 0.219 | 18239 | 1 | ok |
| rbac_select_page | 0.67 | 0.97 | 0.713 | 5608 | 3 | ok |
| rbac_select_count | 0.71 | 0.92 | 0.721 | 5544 | 3 | ok |
| rbac_update_one | 0.27 | 0.36 | 0.269 | 14869 | 3 | ok |
| write_assign_role | 0.14 | 0.20 | 0.141 | 28313 | 1 | ok |
| share_list_objects | 0.31 | 0.41 | 0.294 | 13608 | 2 | ok |
| share_select_page | 0.95 | 1.26 | 0.975 | 4101 | 6 | ok |
| write_share | 0.25 | 0.33 | 0.257 | 15585 | 1 | ok |
| parents_proj_select_page | 1.02 | 1.43 | 1.065 | 3757 | 4 | ok |
| parents_proj_select_count | 7.66 | 9.32 | 7.845 | 509 | 9 | OVER |
| parents_select_page | 1.07 | 7.12 | 2.258 | 1771 | 32 | ok |
| parents_select_count | 7.61 | 12.64 | 8.438 | 474 | 70 | ok |
| write_nest_team | 0.26 | 0.32 | 0.248 | 16145 | 1 | ok |
| nest_check | 0.41 | 0.53 | 0.401 | 9965 | 2 | ok |
| plain_list_objects | 0.33 | 1.90 | 0.604 | 6624 | - | - |
| cond_list_objects | 0.54 | 2.18 | 0.810 | 4939 | - | - |
| cond_select_page | 1.25 | 7.37 | 2.422 | 1651 | - | - |
| cond_nest_check | 0.58 | 0.86 | 0.597 | 6704 | - | - |
| plain_list_users | 0.30 | 1.48 | 0.553 | 7230 | - | - |
| cond_list_users | 0.43 | 1.96 | 0.771 | 5186 | - | - |
| block_list_objects | 0.38 | 1.94 | 0.648 | 6171 | - | - |
| block_or_mute_list_objects | 16.52 | 350.64 | 72.727 | 55 | - | - |
| intersect_list_objects | 2.93 | 103.39 | 23.659 | 169 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.27 | 5.4 | 20015 |
| sharing | 1.58 | 17.7 | 54086 |
| parents_proj | 0.08 | 18.4 | 56086 |
| parents | 33.05 | 323.5 | 1056086 |
| nesting | 0.02 | 323.5 | 1056087 |
| conditions | 1.04 | 329.0 | 1070203 |
| blocklist | 1.06 | 336.5 | 1090438 |

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
| fga_tuples | 0.03 MB, 0 rows | 11.77 MB, 33997 rows | 12.51 MB, 35997 rows | 317.59 MB, 1035997 rows | 317.59 MB, 1035998 rows | 323.06 MB, 1049996 rows | 330.55 MB, 1069996 rows |
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
Limit (actual time=0.774..4.141 rows=50.00 loops=1)
  Buffers: shared hit=3121 read=13
  InitPlan 1
    ->  Result (actual time=0.638..0.640 rows=2.00 loops=1)
          Buffers: shared hit=453
          ->  ProjectSet (actual time=0.638..0.638 rows=2.00 loops=1)
                Buffers: shared hit=453
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.774..4.137 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3121 read=13
Planning:
  Buffers: shared hit=112
Planning Time: 0.145 ms
Execution Time: 4.336 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=3.414..6.946 rows=50.00 loops=1)
  Buffers: shared hit=4139 read=12
  InitPlan 1
    ->  Result (actual time=3.005..3.008 rows=7.00 loops=1)
          Buffers: shared hit=1255
          ->  ProjectSet (actual time=3.004..3.005 rows=7.00 loops=1)
                Buffers: shared hit=1255
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.295..0.296 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.295..0.295 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.413..6.941 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4139 read=12
Planning:
  Buffers: shared hit=147
Planning Time: 0.221 ms
Execution Time: 7.182 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.874..6.264 rows=50.00 loops=1)
  Buffers: shared hit=4176 read=12
  InitPlan 1
    ->  Result (actual time=2.384..2.387 rows=7.00 loops=1)
          Buffers: shared hit=1283
          ->  ProjectSet (actual time=2.384..2.384 rows=7.00 loops=1)
                Buffers: shared hit=1283
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.092..0.092 rows=0.00 loops=1)
          Buffers: shared hit=9
          ->  ProjectSet (actual time=0.092..0.092 rows=0.00 loops=1)
                Buffers: shared hit=9
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.285..0.286 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.284..0.285 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.874..6.259 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4176 read=12
Planning:
  Buffers: shared hit=118
Planning Time: 0.172 ms
Execution Time: 6.478 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=3.136..6.283 rows=50.00 loops=1)
  Buffers: shared hit=4120 read=56
  InitPlan 1
    ->  Result (actual time=2.680..2.683 rows=7.00 loops=1)
          Buffers: shared hit=1241 read=39
          ->  ProjectSet (actual time=2.679..2.680 rows=7.00 loops=1)
                Buffers: shared hit=1241 read=39
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.345..0.346 rows=2.00 loops=1)
          Buffers: shared hit=205 read=9
          ->  ProjectSet (actual time=0.345..0.345 rows=2.00 loops=1)
                Buffers: shared hit=205 read=9
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.135..6.280 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4120 read=56
Planning:
  Buffers: shared hit=102 read=13 dirtied=1
Planning Time: 0.230 ms
Execution Time: 6.612 ms
```

