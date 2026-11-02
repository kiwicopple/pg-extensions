# Benchmark: pg_permissions--0.1.0 (design e), large scale, default shape

- Date: 2026-11-02 16:14
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.28 | 0.39 | 0.276 | 14482 | 1 | ok |
| rbac_select_page | 0.75 | 1.08 | 0.782 | 5114 | 3 | ok |
| rbac_select_count | 0.81 | 1.14 | 0.838 | 4775 | 3 | ok |
| rbac_update_one | 0.48 | 0.73 | 0.482 | 8303 | 3 | ok |
| write_assign_role | 0.25 | 0.38 | 0.259 | 15425 | 1 | ok |
| share_list_objects | 0.44 | 0.82 | 0.471 | 8494 | 2 | ok |
| share_select_page | 1.19 | 1.84 | 1.262 | 3170 | 6 | ok |
| write_share | 0.25 | 0.42 | 0.266 | 15018 | 1 | ok |
| parents_proj_select_page | 1.37 | 2.19 | 1.469 | 2722 | 4 | ok |
| parents_proj_select_count | 8.64 | 10.57 | 8.853 | 451 | 20 | ok |
| parents_select_page | 1.42 | 9.00 | 2.964 | 1349 | 32 | ok |
| parents_select_count | 8.85 | 17.38 | 10.357 | 386 | 70 | ok |
| write_nest_team | 1.17 | 1.70 | 1.216 | 3290 | 1 | OVER |
| nest_check | 0.40 | 0.63 | 0.406 | 9841 | 2 | ok |
| row_select_page | 225.47 | 312.52 | 230.796 | 17 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.96 | 7.5 | 31002 |
| sharing | 31.10 | 197.1 | 1109002 |
| parents_proj | 0.28 | 199.9 | 1114003 |
| parents | 32.56 | 445.0 | 2114003 |
| nesting | 0.02 | 445.0 | 2114004 |
| rowcheck | 0.02 | 445.0 | 2114006 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting | after rowcheck |
| --- | --- | --- | --- | --- | --- | --- |
| cedar_entities | 1.57 MB, 10400 rows | 147.07 MB, 1011901 rows | 147.21 MB, 1012901 rows | 147.21 MB, 1012901 rows | 147.21 MB, 1012901 rows | 147.21 MB, 1012901 rows |
| cedar_entity_parents | 5.05 MB, 20200 rows | 7.70 MB, 31697 rows | 7.70 MB, 31697 rows | 252.79 MB, 1031697 rows | 252.79 MB, 1031698 rows | 252.79 MB, 1031698 rows |
| cedar_policies | 0.23 MB, 200 rows | 20.38 MB, 22700 rows | 22.02 MB, 24700 rows | 22.02 MB, 24700 rows | 22.02 MB, 24700 rows | 22.02 MB, 24701 rows |
| cedar_policy_scopes | 0.20 MB, 200 rows | 21.56 MB, 42700 rows | 22.54 MB, 44700 rows | 22.54 MB, 44700 rows | 22.54 MB, 44700 rows | 22.54 MB, 44701 rows |
| cedar_templates | 0.06 MB, 2 rows | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows |
| fga_computed_closure | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| fga_conditions | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| fga_edges | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| fga_models | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| fga_paths | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| fga_reach | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| fga_relations | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| fga_rewrite_nodes | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| fga_tuples | 0.04 MB, 0 rows | 0.04 MB, 0 rows | 0.04 MB, 0 rows | 0.04 MB, 0 rows | 0.04 MB, 0 rows | 0.04 MB, 0 rows |
| fga_type_restrictions | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| fga_types | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| fga_walk_steps | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| rbac_assignments | 0.03 MB, 0 rows | 0.03 MB, 0 rows | 0.03 MB, 0 rows | 0.03 MB, 0 rows | 0.03 MB, 0 rows | 0.03 MB, 0 rows |
| rbac_role_closure | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| rbac_role_inherits | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| rbac_role_permissions | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| rbac_roles | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |

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
| rowcheck | 1 | 20007 | d2b4030ad636f968f35a8af5008ac9f6 |
| rowcheck | 2 | 20007 | abb87f25aaf62620d8b791efa17462b4 |
| rowcheck | 3 | 20012 | b4c68ea1387b14cdb659ac1be1bc314a |
| rowcheck | 5 | 21012 | 62038fc0969395160b3e96933ddac9e4 |
| rowcheck | 10 | 21012 | 447d15cf1ccb48b8a791f10de5616989 |
| rowcheck | 77 | 20022 | eb1cd8028cf96891dd907c58dd08b89f |
| rowcheck | 500 | 21007 | d357b76a845e832d77fdd55403df4e56 |
| rowcheck | 10000 | 21007 | 24fc32209c7c854bc0f098b1e1d6940d |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-30 16:28): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-30 16:31): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 16:34): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design d (2026-10-30 16:40): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.551..5.957 rows=50.00 loops=1)
  Buffers: shared hit=3733 read=13
  InitPlan 1
    ->  Result (actual time=2.411..2.412 rows=2.00 loops=1)
          Buffers: shared hit=1065
          ->  ProjectSet (actual time=2.410..2.411 rows=2.00 loops=1)
                Buffers: shared hit=1065
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.550..5.953 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3733 read=13
Planning:
  Buffers: shared hit=106
Planning Time: 0.155 ms
Execution Time: 5.981 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.840..6.641 rows=50.00 loops=1)
  Buffers: shared hit=3850 read=37
  InitPlan 1
    ->  Result (actual time=2.559..2.562 rows=7.00 loops=1)
          Buffers: shared hit=1078 read=25
          ->  ProjectSet (actual time=2.558..2.559 rows=7.00 loops=1)
                Buffers: shared hit=1078 read=25
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.147..0.148 rows=2.00 loops=1)
          Buffers: shared hit=102
          ->  ProjectSet (actual time=0.147..0.147 rows=2.00 loops=1)
                Buffers: shared hit=102
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.839..6.636 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3850 read=37
Planning:
  Buffers: shared hit=136
Planning Time: 0.236 ms
Execution Time: 6.665 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.628..8.258 rows=50.00 loops=1)
  Buffers: shared hit=4000 read=12
  InitPlan 1
    ->  Result (actual time=3.116..3.119 rows=7.00 loops=1)
          Buffers: shared hit=1133
          ->  ProjectSet (actual time=3.114..3.116 rows=7.00 loops=1)
                Buffers: shared hit=1133
                ->  Result (actual time=0.000..0.001 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.189..0.189 rows=0.00 loops=1)
          Buffers: shared hit=95
          ->  ProjectSet (actual time=0.189..0.189 rows=0.00 loops=1)
                Buffers: shared hit=95
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.127..0.129 rows=2.00 loops=1)
          Buffers: shared hit=102
          ->  ProjectSet (actual time=0.127..0.127 rows=2.00 loops=1)
                Buffers: shared hit=102
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.628..8.252 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=4000 read=12
Planning:
  Buffers: shared hit=109
Planning Time: 0.172 ms
Execution Time: 8.292 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=3.462..7.399 rows=50.00 loops=1)
  Buffers: shared hit=3843 read=89
  InitPlan 1
    ->  Result (actual time=3.054..3.057 rows=7.00 loops=1)
          Buffers: shared hit=1059 read=81
          ->  ProjectSet (actual time=3.053..3.054 rows=7.00 loops=1)
                Buffers: shared hit=1059 read=81
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.305..0.306 rows=2.00 loops=1)
          Buffers: shared hit=110
          ->  ProjectSet (actual time=0.305..0.305 rows=2.00 loops=1)
                Buffers: shared hit=110
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.461..7.394 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3843 read=89
Planning:
  Buffers: shared hit=93 read=13 dirtied=1
Planning Time: 0.251 ms
Execution Time: 7.421 ms
```

### row_select_page (per-row policy, user 1)

```
Limit (actual time=16.385..223.720 rows=50.00 loops=1)
  Buffers: shared hit=25705 read=2589 written=24
  ->  Index Scan using documents_pkey on documents (actual time=16.384..223.713 rows=50.00 loops=1)
        Filter: permissions.cedar_is_authorized_current('Action::"read"'::text, (('Document::"'::text || (id)::text) || '"'::text), jsonb_build_object('readers', jsonb_build_object('__entity', jsonb_build_object('type', 'Role', 'id', ((org_id)::text || '/viewer'::text)))), permissions._unfolded_null())
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=25705 read=2589 written=24
Planning:
  Buffers: shared hit=117 read=21
Planning Time: 0.912 ms
Execution Time: 224.285 ms
```

