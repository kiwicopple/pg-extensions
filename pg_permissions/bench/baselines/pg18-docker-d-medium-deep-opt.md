# Benchmark: d-per-model (design d), medium scale, deep shape

- Date: 2026-10-29 17:35
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.22 | 0.36 | 0.231 | 17297 | 1 | ok |
| rbac_select_page | 0.41 | 0.70 | 0.442 | 9051 | 2 | ok |
| rbac_select_count | 0.32 | 0.53 | 0.331 | 12081 | 2 | ok |
| rbac_update_one | 0.28 | 0.45 | 0.293 | 13628 | 3 | ok |
| write_assign_role | 0.14 | 0.21 | 0.148 | 27013 | 1 | ok |
| share_list_objects | 0.78 | 1.02 | 0.798 | 5012 | 1 | OVER |
| share_select_page | 1.18 | 1.50 | 1.200 | 3334 | 3 | ok |
| write_share | 0.23 | 0.31 | 0.235 | 17049 | 1 | ok |
| parents_proj_select_page | 1.79 | 2.74 | 1.918 | 2085 | 4 | ok |
| parents_proj_select_count | 2.09 | 2.84 | 2.208 | 1811 | 4 | ok |
| parents_select_page | 1.23 | 2.40 | 1.459 | 2740 | 25 | ok |
| parents_select_count | 1.54 | 2.52 | 1.741 | 2297 | 23 | ok |
| write_nest_team | 0.23 | 0.31 | 0.235 | 17028 | 1 | ok |
| nest_check | 0.43 | 0.54 | 0.421 | 9493 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.46 | 3.0 | 10015 |
| sharing | 0.89 | 8.7 | 27240 |
| parents_proj | 0.05 | 9.0 | 28240 |
| parents | 3.18 | 35.9 | 128240 |
| nesting | 0.02 | 35.9 | 128241 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| fga_computed_closure | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows |
| fga_edges | 0.02 MB, 0 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows |
| fga_models | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows |
| fga_paths | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows |
| fga_relations | 0.02 MB, 0 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows |
| fga_rewrite_nodes | 0.02 MB, 0 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows |
| fga_tuples | 0.02 MB, 0 rows | 5.31 MB, 17177 rows | 5.63 MB, 18177 rows | 32.52 MB, 118177 rows | 32.52 MB, 118178 rows |
| fga_type_restrictions | 0.02 MB, 0 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows |
| fga_types | 0.02 MB, 0 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows |
| rbac_assignments | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows |
| rbac_role_closure | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |
| rbac_role_inherits | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows |
| rbac_role_permissions | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |

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
| sharing | 1 | 4045 | 191b9e3562eac23676f2ae85efb3a6ee |
| sharing | 2 | 4046 | 335c04f0b5bc3d03bcffc67aae3869ca |
| sharing | 3 | 4045 | 75d3d9ab19d3c59998a6f1c0aa0b6948 |
| sharing | 5 | 4047 | f93629e4f85e699b1035f55bdd839a18 |
| sharing | 10 | 4044 | d14583b707a0b173a9335693da0f83ce |
| sharing | 77 | 4044 | 1f5d5175497f9753469592e0dc00ef29 |
| sharing | 500 | 4040 | 2311723442185f44718d106cc6157e17 |
| sharing | 5000 | 4044 | 8d1cc59bb9cac19a9e3f641423c36bbc |
| parents_proj | 1 | 4045 | 191b9e3562eac23676f2ae85efb3a6ee |
| parents_proj | 2 | 4046 | 335c04f0b5bc3d03bcffc67aae3869ca |
| parents_proj | 3 | 4045 | 75d3d9ab19d3c59998a6f1c0aa0b6948 |
| parents_proj | 5 | 4247 | e901b7bd5efdcfbdba02c49ec5756579 |
| parents_proj | 10 | 4243 | 27e3570218fbbdeb167dd1a25cad3a86 |
| parents_proj | 77 | 4044 | 1f5d5175497f9753469592e0dc00ef29 |
| parents_proj | 500 | 4240 | 33efaf6a01975b460f502f30ed1dd363 |
| parents_proj | 5000 | 4244 | 9b47bb1a6b8c58829b3e82950e381c80 |
| parents | 1 | 4045 | 191b9e3562eac23676f2ae85efb3a6ee |
| parents | 2 | 4046 | 335c04f0b5bc3d03bcffc67aae3869ca |
| parents | 3 | 4045 | 75d3d9ab19d3c59998a6f1c0aa0b6948 |
| parents | 5 | 4247 | e901b7bd5efdcfbdba02c49ec5756579 |
| parents | 10 | 4243 | 27e3570218fbbdeb167dd1a25cad3a86 |
| parents | 77 | 4044 | 1f5d5175497f9753469592e0dc00ef29 |
| parents | 500 | 4240 | 33efaf6a01975b460f502f30ed1dd363 |
| parents | 5000 | 4244 | 9b47bb1a6b8c58829b3e82950e381c80 |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-29 12:26): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 12:29): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 12:31): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.793..1.743 rows=50.00 loops=1)
  Buffers: shared hit=1930 read=8
  InitPlan 1
    ->  Result (actual time=0.722..0.723 rows=2.00 loops=1)
          Buffers: shared hit=453
          ->  ProjectSet (actual time=0.721..0.721 rows=2.00 loops=1)
                Buffers: shared hit=453
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.792..1.739 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=1930 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.158 ms
Execution Time: 2.015 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=3.778..4.613 rows=50.00 loops=1)
  Buffers: shared hit=3028 read=3
  InitPlan 1
    ->  Result (actual time=3.452..3.465 rows=47.00 loops=1)
          Buffers: shared hit=1339
          ->  ProjectSet (actual time=3.450..3.453 rows=47.00 loops=1)
                Buffers: shared hit=1339
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.280..0.281 rows=2.00 loops=1)
          Buffers: shared hit=208
          ->  ProjectSet (actual time=0.279..0.280 rows=2.00 loops=1)
                Buffers: shared hit=208
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.777..4.609 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Index Searches: 1
        Buffers: shared hit=3028 read=3
Planning:
  Buffers: shared hit=117
Planning Time: 0.173 ms
Execution Time: 4.813 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=4.281..5.224 rows=50.00 loops=1)
  Buffers: shared hit=3177 read=3
  InitPlan 1
    ->  Result (actual time=3.341..3.354 rows=47.00 loops=1)
          Buffers: shared hit=1336
          ->  ProjectSet (actual time=3.340..3.342 rows=47.00 loops=1)
                Buffers: shared hit=1336
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.616..0.616 rows=0.00 loops=1)
          Buffers: shared hit=153
          ->  ProjectSet (actual time=0.615..0.616 rows=0.00 loops=1)
                Buffers: shared hit=153
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.276..0.276 rows=2.00 loops=1)
          Buffers: shared hit=207
          ->  ProjectSet (actual time=0.275..0.275 rows=2.00 loops=1)
                Buffers: shared hit=207
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=4.280..5.220 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 1428
        Index Searches: 1
        Buffers: shared hit=3177 read=3
Planning:
  Buffers: shared hit=120
Planning Time: 0.170 ms
Execution Time: 5.429 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=3.825..4.798 rows=50.00 loops=1)
  Buffers: shared hit=3023 read=2
  InitPlan 1
    ->  Result (actual time=3.470..3.483 rows=47.00 loops=1)
          Buffers: shared hit=1333
          ->  ProjectSet (actual time=3.469..3.471 rows=47.00 loops=1)
                Buffers: shared hit=1333
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.305..0.310 rows=2.00 loops=1)
          Buffers: shared hit=208
          ->  ProjectSet (actual time=0.304..0.310 rows=2.00 loops=1)
                Buffers: shared hit=208
                ->  Result (actual time=0.000..0.005 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.825..4.790 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Index Searches: 1
        Buffers: shared hit=3023 read=2
Planning:
  Buffers: shared hit=117
Planning Time: 0.192 ms
Execution Time: 5.015 ms
```

