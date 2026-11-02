# Benchmark: pg_permissions--0.1.0 (design e), medium scale, default shape

- Date: 2026-11-02 18:45
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.31 | 0.47 | 0.300 | 13355 | 1 | ok |
| rbac_select_page | 0.49 | 0.70 | 0.490 | 8158 | 2 | ok |
| rbac_select_count | 0.40 | 0.61 | 0.407 | 9826 | 2 | ok |
| rbac_update_one | 0.58 | 1.08 | 0.621 | 6443 | 3 | ok |
| write_assign_role | 0.26 | 0.42 | 0.268 | 14907 | 1 | ok |
| share_list_objects | 0.39 | 0.62 | 0.394 | 10164 | 1 | ok |
| share_select_page | 0.79 | 1.30 | 0.842 | 4753 | 3 | ok |
| write_share | 0.26 | 0.47 | 0.283 | 14140 | 1 | ok |
| parents_proj_select_page | 0.93 | 1.61 | 1.006 | 3974 | 3 | ok |
| parents_proj_select_count | 1.27 | 2.23 | 1.399 | 2860 | 3 | ok |
| parents_select_page | 0.84 | 1.88 | 1.040 | 3847 | 16 | ok |
| parents_select_count | 1.19 | 2.41 | 1.454 | 2750 | 14 | ok |
| write_nest_team | 1.17 | 1.76 | 1.268 | 3154 | 1 | OVER |
| nest_check | 0.37 | 0.52 | 0.394 | 10151 | 1 | ok |
| row_select_page | 97.49 | 138.88 | 100.168 | 39 | 488 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.80 | 4.2 | 15504 |
| sharing | 8.19 | 40.8 | 154905 |
| parents_proj | 0.15 | 42.2 | 157407 |
| parents | 3.90 | 66.7 | 257408 |
| nesting | 0.02 | 66.7 | 257410 |
| rowcheck | 0.02 | 66.7 | 257413 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting | after rowcheck |
| --- | --- | --- | --- | --- | --- | --- |
| _cedar_secret | 0.06 MB, 1 rows | 0.06 MB, 1 rows | 0.06 MB, 1 rows | 0.06 MB, 1 rows | 0.06 MB, 1 rows | 0.06 MB, 1 rows |
| _cedar_write_gen | 0.06 MB, 1 rows | 0.06 MB, 2 rows | 0.06 MB, 3 rows | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows |
| cedar_entities | 0.81 MB, 5200 rows | 15.53 MB, 106401 rows | 15.60 MB, 106901 rows | 15.60 MB, 106901 rows | 15.60 MB, 106901 rows | 15.60 MB, 106901 rows |
| cedar_entity_parents | 2.57 MB, 10100 rows | 3.99 MB, 16297 rows | 3.99 MB, 16297 rows | 28.52 MB, 116297 rows | 28.52 MB, 116298 rows | 28.52 MB, 116298 rows |
| cedar_policies | 0.15 MB, 100 rows | 10.03 MB, 11100 rows | 10.85 MB, 12100 rows | 10.85 MB, 12100 rows | 10.85 MB, 12100 rows | 10.85 MB, 12101 rows |
| cedar_policy_scopes | 0.13 MB, 100 rows | 10.71 MB, 21100 rows | 11.18 MB, 22100 rows | 11.18 MB, 22100 rows | 11.18 MB, 22100 rows | 11.18 MB, 22101 rows |
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
| rbac | 1 | 4000 | abe7a5a8440045bf3a6b4d35af791d8b |
| rbac | 2 | 4000 | 15806ec009213b1b8680a43dd9dae415 |
| rbac | 3 | 4000 | a171b9d4a238ebe30a12f7d43e4792a6 |
| rbac | 5 | 4000 | 3c906bb80bfb8cf875bcced92319d78e |
| rbac | 10 | 4000 | 83682d14d44928065e8fcd51a0fa3904 |
| rbac | 77 | 4000 | 266488027a22126548692c1fbb5615be |
| rbac | 500 | 4000 | ac5436d43b03d0b83e3ab7c5eecb0aa0 |
| rbac | 5000 | 4000 | ac5436d43b03d0b83e3ab7c5eecb0aa0 |
| sharing | 1 | 4007 | a72affb8dac9720afe47ed798856f486 |
| sharing | 2 | 4007 | a2907603023a122749a3257a6b76c92e |
| sharing | 3 | 4012 | dd7a7ecbdd714a8dc57fa5f0f8e69c8c |
| sharing | 5 | 4012 | 62910a5297358a981fbcb3abcd8b27ca |
| sharing | 10 | 4010 | 3f86ef71af4f0df87ebea0da7274fff6 |
| sharing | 77 | 4022 | 992b5588b0acef0e5f01285d911f79da |
| sharing | 500 | 4020 | 425a5d25d85612f6054e6591a821fafb |
| sharing | 5000 | 4006 | ba82507ecb8f9717f9ecb4b21da14ade |
| parents_proj | 1 | 4007 | a72affb8dac9720afe47ed798856f486 |
| parents_proj | 2 | 4007 | a2907603023a122749a3257a6b76c92e |
| parents_proj | 3 | 4012 | dd7a7ecbdd714a8dc57fa5f0f8e69c8c |
| parents_proj | 5 | 4212 | a570b2a32be579248c09197f56dca5bb |
| parents_proj | 10 | 4210 | 08d4ebfb3b09329146de3fdac7fc86f1 |
| parents_proj | 77 | 4022 | 992b5588b0acef0e5f01285d911f79da |
| parents_proj | 500 | 4220 | 5fee4f97891d7a79d09e06a8208212c2 |
| parents_proj | 5000 | 4206 | a4e9098b3f0f4616a3bb53336e12c394 |
| parents | 1 | 4007 | a72affb8dac9720afe47ed798856f486 |
| parents | 2 | 4007 | a2907603023a122749a3257a6b76c92e |
| parents | 3 | 4012 | dd7a7ecbdd714a8dc57fa5f0f8e69c8c |
| parents | 5 | 4212 | a570b2a32be579248c09197f56dca5bb |
| parents | 10 | 4210 | 08d4ebfb3b09329146de3fdac7fc86f1 |
| parents | 77 | 4022 | 992b5588b0acef0e5f01285d911f79da |
| parents | 500 | 4220 | 5fee4f97891d7a79d09e06a8208212c2 |
| parents | 5000 | 4206 | a4e9098b3f0f4616a3bb53336e12c394 |
| rowcheck | 1 | 4007 | a72affb8dac9720afe47ed798856f486 |
| rowcheck | 2 | 4007 | a2907603023a122749a3257a6b76c92e |
| rowcheck | 3 | 4012 | dd7a7ecbdd714a8dc57fa5f0f8e69c8c |
| rowcheck | 5 | 4212 | a570b2a32be579248c09197f56dca5bb |
| rowcheck | 10 | 4210 | 08d4ebfb3b09329146de3fdac7fc86f1 |
| rowcheck | 77 | 4022 | 992b5588b0acef0e5f01285d911f79da |
| rowcheck | 500 | 4220 | 5fee4f97891d7a79d09e06a8208212c2 |
| rowcheck | 5000 | 4206 | a4e9098b3f0f4616a3bb53336e12c394 |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-30 16:03): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-30 16:06): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 16:08): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design d (2026-10-30 16:01): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.541..3.320 rows=50.00 loops=1)
  Buffers: shared hit=2576 read=8
  InitPlan 1
    ->  Result (actual time=2.485..2.485 rows=2.00 loops=1)
          Buffers: shared hit=1099
          ->  ProjectSet (actual time=2.484..2.484 rows=2.00 loops=1)
                Buffers: shared hit=1099
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.540..3.317 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2576 read=8
Planning:
  Buffers: shared hit=106
Planning Time: 0.148 ms
Execution Time: 3.338 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.816..3.949 rows=50.00 loops=1)
  Buffers: shared hit=2762 read=4
  InitPlan 1
    ->  Result (actual time=2.610..2.613 rows=7.00 loops=1)
          Buffers: shared hit=1178
          ->  ProjectSet (actual time=2.609..2.610 rows=7.00 loops=1)
                Buffers: shared hit=1178
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.122..0.123 rows=2.00 loops=1)
          Buffers: shared hit=101
          ->  ProjectSet (actual time=0.122..0.122 rows=2.00 loops=1)
                Buffers: shared hit=101
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.816..3.945 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2762 read=4
Planning:
  Buffers: shared hit=108
Planning Time: 0.178 ms
Execution Time: 3.972 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.145..3.963 rows=50.00 loops=1)
  Buffers: shared hit=2855 read=4
  InitPlan 1
    ->  Result (actual time=2.844..2.847 rows=7.00 loops=1)
          Buffers: shared hit=1177
          ->  ProjectSet (actual time=2.843..2.844 rows=7.00 loops=1)
                Buffers: shared hit=1177
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.135..0.136 rows=0.00 loops=1)
          Buffers: shared hit=94
          ->  ProjectSet (actual time=0.135..0.136 rows=0.00 loops=1)
                Buffers: shared hit=94
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.106..0.107 rows=2.00 loops=1)
          Buffers: shared hit=101
          ->  ProjectSet (actual time=0.105..0.106 rows=2.00 loops=1)
                Buffers: shared hit=101
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.145..3.959 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2855 read=4
Planning:
  Buffers: shared hit=109
Planning Time: 0.172 ms
Execution Time: 3.995 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=2.844..3.994 rows=50.00 loops=1)
  Buffers: shared hit=2765 read=3
  InitPlan 1
    ->  Result (actual time=2.594..2.597 rows=7.00 loops=1)
          Buffers: shared hit=1178
          ->  ProjectSet (actual time=2.593..2.593 rows=7.00 loops=1)
                Buffers: shared hit=1178
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.182..0.183 rows=2.00 loops=1)
          Buffers: shared hit=103
          ->  ProjectSet (actual time=0.181..0.182 rows=2.00 loops=1)
                Buffers: shared hit=103
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.843..3.990 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2765 read=3
Planning:
  Buffers: shared hit=106
Planning Time: 0.166 ms
Execution Time: 4.018 ms
```

### row_select_page (per-row policy, user 1)

```
Limit (actual time=7.553..106.044 rows=50.00 loops=1)
  Buffers: shared hit=15026 read=8
  ->  Index Scan using documents_pkey on documents (actual time=7.552..106.037 rows=50.00 loops=1)
        Filter: permissions.cedar_is_authorized_current('Action::"read"'::text, (('Document::"'::text || (id)::text) || '"'::text), jsonb_build_object('readers', jsonb_build_object('__entity', jsonb_build_object('type', 'Role', 'id', ((org_id)::text || '/viewer'::text)))), permissions._unfolded_null())
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=15026 read=8
Planning:
  Buffers: shared hit=135
Planning Time: 0.396 ms
Execution Time: 106.539 ms
```

