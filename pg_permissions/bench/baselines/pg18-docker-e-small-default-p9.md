# Benchmark: pg_permissions--0.1.0 (design e), small scale, default shape

- Date: 2026-11-02 18:41
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 10000 documents, 1000 users, 20 orgs, 50 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.30 | 0.52 | 0.307 | 13046 | 1 | ok |
| rbac_select_page | 0.37 | 0.69 | 0.398 | 10046 | 2 | ok |
| rbac_select_count | 0.32 | 0.61 | 0.344 | 11635 | 2 | ok |
| rbac_update_one | 0.52 | 0.84 | 0.521 | 7680 | 4 | ok |
| write_assign_role | 0.26 | 0.45 | 0.275 | 14566 | 1 | ok |
| share_list_objects | 0.35 | 0.50 | 0.339 | 11787 | 2 | ok |
| share_select_page | 0.56 | 0.90 | 0.586 | 6825 | 5 | ok |
| write_share | 0.26 | 0.62 | 0.313 | 12762 | 1 | ok |
| parents_proj_select_page | 0.67 | 1.15 | 0.752 | 5322 | 2 | ok |
| parents_proj_select_count | 0.66 | 1.06 | 0.697 | 5737 | 2 | ok |
| parents_select_page | 0.59 | 0.99 | 0.649 | 6165 | 4 | ok |
| parents_select_count | 0.57 | 0.83 | 0.595 | 6719 | 4 | ok |
| write_nest_team | 1.10 | 1.81 | 1.205 | 3318 | 1 | OVER |
| nest_check | 0.35 | 0.63 | 0.378 | 10583 | 1 | ok |
| row_select_page | 35.15 | 47.47 | 35.936 | 111 | 179 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.10 | 1.5 | 3204 |
| sharing | 1.15 | 7.8 | 22805 |
| parents_proj | 0.08 | 8.1 | 23407 |
| parents | 0.54 | 10.6 | 33408 |
| nesting | 0.02 | 10.6 | 33410 |
| rowcheck | 0.03 | 10.6 | 33413 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting | after rowcheck |
| --- | --- | --- | --- | --- | --- | --- |
| _cedar_secret | 0.06 MB, 1 rows | 0.06 MB, 1 rows | 0.06 MB, 1 rows | 0.06 MB, 1 rows | 0.06 MB, 1 rows | 0.06 MB, 1 rows |
| _cedar_write_gen | 0.06 MB, 1 rows | 0.06 MB, 2 rows | 0.06 MB, 3 rows | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows |
| cedar_entities | 0.22 MB, 1080 rows | 1.84 MB, 12131 rows | 1.87 MB, 12331 rows | 1.87 MB, 12331 rows | 1.87 MB, 12331 rows | 1.87 MB, 12331 rows |
| cedar_entity_parents | 0.59 MB, 2040 rows | 1.05 MB, 4087 rows | 1.05 MB, 4087 rows | 3.52 MB, 14087 rows | 3.52 MB, 14088 rows | 3.52 MB, 14088 rows |
| cedar_policies | 0.10 MB, 40 rows | 2.12 MB, 2290 rows | 2.30 MB, 2490 rows | 2.30 MB, 2490 rows | 2.30 MB, 2490 rows | 2.30 MB, 2491 rows |
| cedar_policy_scopes | 0.09 MB, 40 rows | 2.24 MB, 4290 rows | 2.35 MB, 4490 rows | 2.35 MB, 4490 rows | 2.35 MB, 4490 rows | 2.35 MB, 4491 rows |
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
| rowcheck | 1 | 1007 | f635214e68cb66caeeaaf31b9e47c0e5 |
| rowcheck | 2 | 1005 | a32ea7ae134e6eec5e63db894c97e9b8 |
| rowcheck | 3 | 1012 | d65d9f337cf0efef2fbbb2b5fa39a0c0 |
| rowcheck | 5 | 1060 | 557a27517d4d2b6eb8f4ecd87060ab57 |
| rowcheck | 10 | 1062 | c34e39f19fa172caadc858d61087fbc5 |
| rowcheck | 77 | 1015 | 9936bba1571d2af2f5fcd43ad643be5a |
| rowcheck | 500 | 1057 | 497acd0fa8a7231c284ada146bac9aa5 |
| rowcheck | 1000 | 1057 | 1c8390d0c8b5c0058632f723c73fbf89 |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-30 16:15): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-30 16:17): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 16:20): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design d (2026-10-30 16:13): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.962..3.120 rows=50.00 loops=1)
  Buffers: shared hit=1666 read=4
  InitPlan 1
    ->  Result (actual time=2.910..2.911 rows=2.00 loops=1)
          Buffers: shared hit=1076
          ->  ProjectSet (actual time=2.909..2.909 rows=2.00 loops=1)
                Buffers: shared hit=1076
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.961..3.117 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=1666 read=4
Planning:
  Buffers: shared hit=106
Planning Time: 0.152 ms
Execution Time: 3.136 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.649..2.883 rows=50.00 loops=1)
  Buffers: shared hit=1854 read=2
  InitPlan 1
    ->  Result (actual time=2.461..2.463 rows=7.00 loops=1)
          Buffers: shared hit=1167
          ->  ProjectSet (actual time=2.460..2.460 rows=7.00 loops=1)
                Buffers: shared hit=1167
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.131..0.131 rows=2.00 loops=1)
          Buffers: shared hit=95
          ->  ProjectSet (actual time=0.130..0.130 rows=2.00 loops=1)
                Buffers: shared hit=95
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.648..2.880 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=1854 read=2
Planning:
  Buffers: shared hit=108
Planning Time: 0.182 ms
Execution Time: 2.905 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.995..4.255 rows=50.00 loops=1)
  Buffers: shared hit=1914 read=2
  InitPlan 1
    ->  Result (actual time=3.693..3.696 rows=7.00 loops=1)
          Buffers: shared hit=1139
          ->  ProjectSet (actual time=3.692..3.693 rows=7.00 loops=1)
                Buffers: shared hit=1139
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.148..0.148 rows=0.00 loops=1)
          Buffers: shared hit=88
          ->  ProjectSet (actual time=0.147..0.148 rows=0.00 loops=1)
                Buffers: shared hit=88
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.112..0.112 rows=2.00 loops=1)
          Buffers: shared hit=95
          ->  ProjectSet (actual time=0.111..0.111 rows=2.00 loops=1)
                Buffers: shared hit=95
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.994..4.251 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=1914 read=2
Planning:
  Buffers: shared hit=139
Planning Time: 0.299 ms
Execution Time: 4.286 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=2.969..3.209 rows=50.00 loops=1)
  Buffers: shared hit=1871
  InitPlan 1
    ->  Result (actual time=2.782..2.784 rows=7.00 loops=1)
          Buffers: shared hit=1176
          ->  ProjectSet (actual time=2.781..2.782 rows=7.00 loops=1)
                Buffers: shared hit=1176
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.145..0.146 rows=2.00 loops=1)
          Buffers: shared hit=101
          ->  ProjectSet (actual time=0.144..0.145 rows=2.00 loops=1)
                Buffers: shared hit=101
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.969..3.206 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=1871
Planning:
  Buffers: shared hit=106
Planning Time: 0.215 ms
Execution Time: 3.231 ms
```

### row_select_page (per-row policy, user 1)

```
Limit (actual time=7.040..41.897 rows=50.00 loops=1)
  Buffers: shared hit=7101 read=4
  ->  Index Scan using documents_pkey on documents (actual time=7.039..41.892 rows=50.00 loops=1)
        Filter: permissions.cedar_is_authorized_current('Action::"read"'::text, (('Document::"'::text || (id)::text) || '"'::text), jsonb_build_object('readers', jsonb_build_object('__entity', jsonb_build_object('type', 'Role', 'id', ((org_id)::text || '/viewer'::text)))), permissions._unfolded_null())
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=7101 read=4
Planning:
  Buffers: shared hit=140
Planning Time: 0.286 ms
Execution Time: 42.134 ms
```

