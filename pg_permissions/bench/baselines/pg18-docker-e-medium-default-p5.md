# Benchmark: pg_permissions--0.1.0 (design e), medium scale, default shape

- Date: 2026-11-02 16:02
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.31 | 0.52 | 0.313 | 12780 | 1 | ok |
| rbac_select_page | 0.50 | 0.85 | 0.523 | 7644 | 2 | ok |
| rbac_select_count | 0.45 | 0.63 | 0.445 | 8983 | 2 | ok |
| rbac_update_one | 0.56 | 0.78 | 0.555 | 7210 | 3 | ok |
| write_assign_role | 0.25 | 0.34 | 0.246 | 16239 | 1 | ok |
| share_list_objects | 0.39 | 0.52 | 0.377 | 10607 | 1 | ok |
| share_select_page | 0.78 | 1.05 | 0.801 | 4995 | 3 | ok |
| write_share | 0.25 | 0.42 | 0.265 | 15098 | 1 | ok |
| parents_proj_select_page | 0.94 | 1.44 | 0.984 | 4063 | 3 | ok |
| parents_proj_select_count | 1.32 | 1.89 | 1.382 | 2893 | 3 | ok |
| parents_select_page | 0.86 | 1.94 | 1.080 | 3705 | 16 | ok |
| parents_select_count | 1.26 | 2.24 | 1.446 | 2767 | 14 | ok |
| write_nest_team | 1.16 | 1.72 | 1.226 | 3262 | 1 | OVER |
| nest_check | 0.36 | 0.51 | 0.354 | 11287 | 1 | ok |
| row_select_page | 107.81 | 162.43 | 110.442 | 36 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.86 | 4.1 | 15502 |
| sharing | 6.21 | 40.7 | 154902 |
| parents_proj | 0.17 | 42.0 | 157403 |
| parents | 3.38 | 66.6 | 257403 |
| nesting | 0.02 | 66.6 | 257404 |
| rowcheck | 0.02 | 66.6 | 257406 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting | after rowcheck |
| --- | --- | --- | --- | --- | --- | --- |
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
Limit (actual time=2.722..3.588 rows=50.00 loops=1)
  Buffers: shared hit=2536 read=8
  InitPlan 1
    ->  Result (actual time=2.643..2.644 rows=2.00 loops=1)
          Buffers: shared hit=1059
          ->  ProjectSet (actual time=2.642..2.643 rows=2.00 loops=1)
                Buffers: shared hit=1059
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.722..3.584 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2536 read=8
Planning:
  Buffers: shared hit=106
Planning Time: 0.175 ms
Execution Time: 3.613 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.642..3.646 rows=50.00 loops=1)
  Buffers: shared hit=2723 read=4
  InitPlan 1
    ->  Result (actual time=2.449..2.452 rows=7.00 loops=1)
          Buffers: shared hit=1140
          ->  ProjectSet (actual time=2.448..2.449 rows=7.00 loops=1)
                Buffers: shared hit=1140
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.142..0.143 rows=2.00 loops=1)
          Buffers: shared hit=101
          ->  ProjectSet (actual time=0.141..0.142 rows=2.00 loops=1)
                Buffers: shared hit=101
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.642..3.642 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2723 read=4
Planning:
  Buffers: shared hit=108
Planning Time: 0.187 ms
Execution Time: 3.669 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.830..3.577 rows=50.00 loops=1)
  Buffers: shared hit=2815 read=4
  InitPlan 1
    ->  Result (actual time=2.530..2.533 rows=7.00 loops=1)
          Buffers: shared hit=1138
          ->  ProjectSet (actual time=2.530..2.530 rows=7.00 loops=1)
                Buffers: shared hit=1138
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.117..0.117 rows=0.00 loops=1)
          Buffers: shared hit=94
          ->  ProjectSet (actual time=0.117..0.117 rows=0.00 loops=1)
                Buffers: shared hit=94
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.098..0.099 rows=2.00 loops=1)
          Buffers: shared hit=101
          ->  ProjectSet (actual time=0.098..0.098 rows=2.00 loops=1)
                Buffers: shared hit=101
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.829..3.573 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2815 read=4
Planning:
  Buffers: shared hit=109
Planning Time: 0.207 ms
Execution Time: 3.612 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=2.774..3.827 rows=50.00 loops=1)
  Buffers: shared hit=2723 read=3
  InitPlan 1
    ->  Result (actual time=2.531..2.534 rows=7.00 loops=1)
          Buffers: shared hit=1137
          ->  ProjectSet (actual time=2.530..2.531 rows=7.00 loops=1)
                Buffers: shared hit=1137
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.186..0.187 rows=2.00 loops=1)
          Buffers: shared hit=103
          ->  ProjectSet (actual time=0.186..0.186 rows=2.00 loops=1)
                Buffers: shared hit=103
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.774..3.823 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2723 read=3
Planning:
  Buffers: shared hit=106
Planning Time: 0.158 ms
Execution Time: 3.870 ms
```

### row_select_page (per-row policy, user 1)

```
Limit (actual time=7.100..99.825 rows=50.00 loops=1)
  Buffers: shared hit=13414 read=8
  ->  Index Scan using documents_pkey on documents (actual time=7.100..99.819 rows=50.00 loops=1)
        Filter: permissions.cedar_is_authorized_current('Action::"read"'::text, (('Document::"'::text || (id)::text) || '"'::text), jsonb_build_object('readers', jsonb_build_object('__entity', jsonb_build_object('type', 'Role', 'id', ((org_id)::text || '/viewer'::text)))), permissions._unfolded_null())
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=13414 read=8
Planning:
  Buffers: shared hit=133
Planning Time: 0.270 ms
Execution Time: 100.212 ms
```

