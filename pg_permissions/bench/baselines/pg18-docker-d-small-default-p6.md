# Benchmark: pg_permissions--0.0.1 (design d), small scale, default shape

- Date: 2026-10-30 16:13
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 10000 documents, 1000 users, 20 orgs, 50 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.20 | 0.29 | 0.191 | 20924 | 1 | ok |
| rbac_select_page | 0.28 | 0.38 | 0.261 | 15315 | 2 | ok |
| rbac_select_count | 0.24 | 0.33 | 0.225 | 17742 | 2 | ok |
| rbac_update_one | 0.26 | 0.40 | 0.259 | 15469 | 4 | ok |
| write_assign_role | 0.14 | 0.23 | 0.139 | 28860 | 1 | ok |
| share_list_objects | 0.28 | 0.46 | 0.278 | 14382 | 2 | ok |
| share_select_page | 0.39 | 0.54 | 0.382 | 10460 | 5 | ok |
| write_share | 0.15 | 0.26 | 0.152 | 26362 | 1 | ok |
| parents_proj_select_page | 0.46 | 0.88 | 0.488 | 8202 | 2 | ok |
| parents_proj_select_count | 0.44 | 0.63 | 0.443 | 9034 | 2 | ok |
| parents_select_page | 0.41 | 0.63 | 0.411 | 9725 | 4 | ok |
| parents_select_count | 0.40 | 1.03 | 0.483 | 8287 | 4 | ok |
| write_nest_team | 0.13 | 0.35 | 0.151 | 26560 | 1 | ok |
| nest_check | 0.37 | 0.99 | 0.448 | 8927 | 1 | ok |
| plain_list_objects | 0.17 | 0.60 | 0.255 | 15664 | - | - |
| cond_list_objects | 0.43 | 1.20 | 0.529 | 7560 | - | - |
| cond_select_page | 0.61 | 1.68 | 0.768 | 5206 | - | - |
| cond_nest_check | 0.58 | 1.63 | 0.734 | 5449 | - | - |
| plain_list_users | 0.36 | 2.61 | 0.670 | 5966 | - | - |
| cond_list_users | 0.59 | 3.49 | 1.034 | 3867 | - | - |
| block_list_objects | 0.26 | 0.88 | 0.368 | 10865 | - | - |
| block_or_mute_list_objects | 0.63 | 1.58 | 0.769 | 5199 | - | - |
| intersect_list_objects | 0.35 | 1.01 | 0.445 | 8988 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.06 | 1.1 | 2015 |
| sharing | 0.37 | 3.2 | 6386 |
| parents_proj | 0.02 | 3.3 | 6586 |
| parents | 0.14 | 6.3 | 16586 |
| nesting | 0.02 | 6.3 | 16587 |
| conditions | 0.43 | 7.3 | 19003 |
| blocklist | 0.31 | 8.1 | 21238 |

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
| fga_tuples | 0.04 MB, 0 rows | 1.62 MB, 4297 rows | 1.70 MB, 4497 rows | 4.77 MB, 14497 rows | 4.77 MB, 14498 rows | 5.69 MB, 16796 rows | 6.43 MB, 18796 rows |
| fga_type_restrictions | 0.02 MB, 0 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 18 rows | 0.06 MB, 31 rows |
| fga_types | 0.02 MB, 0 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 9 rows | 0.06 MB, 14 rows |
| fga_walk_steps | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 36 rows | 0.07 MB, 97 rows |
| rbac_assignments | 0.59 MB, 2000 rows | 0.59 MB, 2000 rows | 0.59 MB, 2000 rows | 0.59 MB, 2000 rows | 0.59 MB, 2000 rows | 0.59 MB, 2000 rows | 0.59 MB, 2000 rows |
| rbac_role_closure | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |
| rbac_role_inherits | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows |
| rbac_role_permissions | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |

## Equivalence

Documents each sample user sees through RLS after each seed, and the md5 of their sorted ids. Every 5th user is also a folder viewer, so for users not divisible by 5 parents_proj and parents must equal sharing, and parents_proj must always equal parents.

| policy | user | visible | md5 |
| --- | --- | --- | --- |
| rbac | 1 | 1000 | 32d4f239c366fea35a5ef36b8c39951e |
| rbac | 2 | 1000 | 4e1830b17a8269e704b55b945b618cd4 |
| rbac | 3 | 1000 | 78c4d0b810ba5f8a462642451ca609b0 |
| rbac | 5 | 1000 | 600d6ac1d050e16012c44cc9caf4b9e3 |
| rbac | 10 | 1000 | 67b08ee90ded8099328c7ac98376a317 |
| rbac | 77 | 1000 | 4e1830b17a8269e704b55b945b618cd4 |
| rbac | 500 | 1000 | b6a5aa102e8824a66f6644f1429b9d78 |
| rbac | 1000 | 1000 | b6a5aa102e8824a66f6644f1429b9d78 |
| sharing | 1 | 1007 | f635214e68cb66caeeaaf31b9e47c0e5 |
| sharing | 2 | 1005 | a32ea7ae134e6eec5e63db894c97e9b8 |
| sharing | 3 | 1012 | d65d9f337cf0efef2fbbb2b5fa39a0c0 |
| sharing | 5 | 1011 | 9ea5cdb71a200276b84ae1d60daf8b70 |
| sharing | 10 | 1012 | b98e1ed845af9b686122a67c92a52194 |
| sharing | 77 | 1015 | 9936bba1571d2af2f5fcd43ad643be5a |
| sharing | 500 | 1007 | a0147f5aa1e0d2179a774c6ae09277a0 |
| sharing | 1000 | 1007 | c837ee69e297b4776b984dc062bb28ee |
| parents_proj | 1 | 1007 | f635214e68cb66caeeaaf31b9e47c0e5 |
| parents_proj | 2 | 1005 | a32ea7ae134e6eec5e63db894c97e9b8 |
| parents_proj | 3 | 1012 | d65d9f337cf0efef2fbbb2b5fa39a0c0 |
| parents_proj | 5 | 1060 | 557a27517d4d2b6eb8f4ecd87060ab57 |
| parents_proj | 10 | 1062 | c34e39f19fa172caadc858d61087fbc5 |
| parents_proj | 77 | 1015 | 9936bba1571d2af2f5fcd43ad643be5a |
| parents_proj | 500 | 1057 | 497acd0fa8a7231c284ada146bac9aa5 |
| parents_proj | 1000 | 1057 | 1c8390d0c8b5c0058632f723c73fbf89 |
| parents | 1 | 1007 | f635214e68cb66caeeaaf31b9e47c0e5 |
| parents | 2 | 1005 | a32ea7ae134e6eec5e63db894c97e9b8 |
| parents | 3 | 1012 | d65d9f337cf0efef2fbbb2b5fa39a0c0 |
| parents | 5 | 1060 | 557a27517d4d2b6eb8f4ecd87060ab57 |
| parents | 10 | 1062 | c34e39f19fa172caadc858d61087fbc5 |
| parents | 77 | 1015 | 9936bba1571d2af2f5fcd43ad643be5a |
| parents | 500 | 1057 | 497acd0fa8a7231c284ada146bac9aa5 |
| parents | 1000 | 1057 | 1c8390d0c8b5c0058632f723c73fbf89 |
| conditions | 1 | 1007 | f635214e68cb66caeeaaf31b9e47c0e5 |
| conditions | 2 | 1005 | a32ea7ae134e6eec5e63db894c97e9b8 |
| conditions | 3 | 1012 | d65d9f337cf0efef2fbbb2b5fa39a0c0 |
| conditions | 5 | 1060 | 557a27517d4d2b6eb8f4ecd87060ab57 |
| conditions | 10 | 1062 | c34e39f19fa172caadc858d61087fbc5 |
| conditions | 77 | 1015 | 9936bba1571d2af2f5fcd43ad643be5a |
| conditions | 500 | 1057 | 497acd0fa8a7231c284ada146bac9aa5 |
| conditions | 1000 | 1057 | 1c8390d0c8b5c0058632f723c73fbf89 |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-30 15:35): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-30 15:37): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 15:57): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.767..0.919 rows=50.00 loops=1)
  Buffers: shared hit=1040 read=4
  InitPlan 1
    ->  Result (actual time=0.729..0.730 rows=2.00 loops=1)
          Buffers: shared hit=450
          ->  ProjectSet (actual time=0.728..0.729 rows=2.00 loops=1)
                Buffers: shared hit=450
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.767..0.916 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=1040 read=4
Planning:
  Buffers: shared hit=112
Planning Time: 0.153 ms
Execution Time: 1.116 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=4.009..4.240 rows=50.00 loops=1)
  Buffers: shared hit=2115 read=2
  InitPlan 1
    ->  Result (actual time=3.597..3.599 rows=7.00 loops=1)
          Buffers: shared hit=1311
          ->  ProjectSet (actual time=3.596..3.597 rows=7.00 loops=1)
                Buffers: shared hit=1311
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.361..0.362 rows=2.00 loops=1)
          Buffers: shared hit=211
          ->  ProjectSet (actual time=0.361..0.361 rows=2.00 loops=1)
                Buffers: shared hit=211
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=4.008..4.237 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=2115 read=2
Planning:
  Buffers: shared hit=117
Planning Time: 0.244 ms
Execution Time: 4.495 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.944..3.166 rows=50.00 loops=1)
  Buffers: shared hit=2095 read=2
  InitPlan 1
    ->  Result (actual time=2.517..2.520 rows=7.00 loops=1)
          Buffers: shared hit=1283
          ->  ProjectSet (actual time=2.516..2.517 rows=7.00 loops=1)
                Buffers: shared hit=1283
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.099..0.099 rows=0.00 loops=1)
          Buffers: shared hit=8
          ->  ProjectSet (actual time=0.098..0.099 rows=0.00 loops=1)
                Buffers: shared hit=8
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.286..0.287 rows=2.00 loops=1)
          Buffers: shared hit=211
          ->  ProjectSet (actual time=0.285..0.286 rows=2.00 loops=1)
                Buffers: shared hit=211
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.943..3.163 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=2095 read=2
Planning:
  Buffers: shared hit=150
Planning Time: 0.235 ms
Execution Time: 3.387 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=3.366..3.611 rows=50.00 loops=1)
  Buffers: shared hit=2117
  InitPlan 1
    ->  Result (actual time=2.943..2.946 rows=7.00 loops=1)
          Buffers: shared hit=1311
          ->  ProjectSet (actual time=2.941..2.943 rows=7.00 loops=1)
                Buffers: shared hit=1311
                ->  Result (actual time=0.000..0.001 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.376..0.377 rows=2.00 loops=1)
          Buffers: shared hit=211
          ->  ProjectSet (actual time=0.376..0.376 rows=2.00 loops=1)
                Buffers: shared hit=211
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.366..3.606 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=2117
Planning:
  Buffers: shared hit=115
Planning Time: 0.224 ms
Execution Time: 3.955 ms
```

