# Benchmark: opt3-before-0bd650b (design d), medium scale, deep shape

- Date: 2026-10-30 11:35
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.22 | 0.30 | 0.212 | 18902 | 1 | ok |
| rbac_select_page | 0.40 | 0.55 | 0.390 | 10256 | 2 | ok |
| rbac_select_count | 0.31 | 0.44 | 0.308 | 12967 | 2 | ok |
| rbac_update_one | 0.28 | 0.38 | 0.281 | 14244 | 3 | ok |
| write_assign_role | 0.15 | 0.27 | 0.159 | 25091 | 1 | ok |
| share_list_objects | 0.32 | 0.50 | 0.318 | 12596 | 1 | ok |
| share_select_page | 0.69 | 1.17 | 0.737 | 5427 | 3 | ok |
| write_share | 0.26 | 0.39 | 0.262 | 15252 | 1 | ok |
| parents_proj_select_page | 0.77 | 1.30 | 0.832 | 4807 | 4 | ok |
| parents_proj_select_count | 1.04 | 1.54 | 1.094 | 3654 | 4 | ok |
| parents_select_page | 0.79 | 1.76 | 0.940 | 4255 | 25 | ok |
| parents_select_count | 0.98 | 1.45 | 1.046 | 3823 | 23 | ok |
| write_nest_team | 0.24 | 0.31 | 0.236 | 16949 | 1 | ok |
| nest_check | 0.45 | 0.72 | 0.463 | 8635 | 2 | ok |
| plain_list_objects | 0.33 | 0.51 | 0.337 | 11864 | - | - |
| cond_list_objects | 0.62 | 0.91 | 0.661 | 6055 | - | - |
| cond_select_page | 1.03 | 1.72 | 1.145 | 3492 | - | - |
| cond_nest_check | 0.59 | 0.74 | 0.586 | 6823 | - | - |
| plain_list_users | 0.91 | 2.24 | 1.040 | 3846 | - | - |
| cond_list_users | 1.35 | 3.96 | 1.539 | 2599 | - | - |
| block_list_objects | 0.38 | 0.57 | 0.391 | 10242 | - | - |
| block_or_mute_list_objects | 27.65 | 92.48 | 40.721 | 98 | - | - |
| intersect_list_objects | 4.86 | 24.95 | 9.127 | 438 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.44 | 3.0 | 10015 |
| sharing | 1.07 | 9.5 | 27266 |
| parents_proj | 0.04 | 9.9 | 28266 |
| parents | 3.41 | 40.4 | 128266 |
| nesting | 0.01 | 40.4 | 128267 |
| conditions | 0.65 | 43.3 | 135563 |
| blocklist | 0.63 | 47.0 | 145798 |

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
| fga_tuples | 0.03 MB, 0 rows | 6.02 MB, 17177 rows | 6.38 MB, 18177 rows | 36.96 MB, 118177 rows | 36.96 MB, 118178 rows | 39.77 MB, 125356 rows | 43.49 MB, 135356 rows |
| fga_type_restrictions | 0.02 MB, 0 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 18 rows | 0.06 MB, 31 rows |
| fga_types | 0.02 MB, 0 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 9 rows | 0.06 MB, 14 rows |
| fga_walk_steps | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 36 rows | 0.07 MB, 97 rows |
| rbac_assignments | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows |
| rbac_role_closure | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |
| rbac_role_inherits | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows |
| rbac_role_permissions | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |

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
| conditions | 1 | 4045 | 191b9e3562eac23676f2ae85efb3a6ee |
| conditions | 2 | 4046 | 335c04f0b5bc3d03bcffc67aae3869ca |
| conditions | 3 | 4045 | 75d3d9ab19d3c59998a6f1c0aa0b6948 |
| conditions | 5 | 4247 | e901b7bd5efdcfbdba02c49ec5756579 |
| conditions | 10 | 4243 | 27e3570218fbbdeb167dd1a25cad3a86 |
| conditions | 77 | 4044 | 1f5d5175497f9753469592e0dc00ef29 |
| conditions | 500 | 4240 | 33efaf6a01975b460f502f30ed1dd363 |
| conditions | 5000 | 4244 | 9b47bb1a6b8c58829b3e82950e381c80 |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-30 10:57): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-30 11:00): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 11:02): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.855..1.780 rows=50.00 loops=1)
  Buffers: shared hit=1930 read=8
  InitPlan 1
    ->  Result (actual time=0.788..0.789 rows=2.00 loops=1)
          Buffers: shared hit=453
          ->  ProjectSet (actual time=0.787..0.788 rows=2.00 loops=1)
                Buffers: shared hit=453
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.854..1.776 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=1930 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.132 ms
Execution Time: 1.969 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=3.023..3.988 rows=50.00 loops=1)
  Buffers: shared hit=3037 read=3
  InitPlan 1
    ->  Result (actual time=2.649..2.663 rows=47.00 loops=1)
          Buffers: shared hit=1344
          ->  ProjectSet (actual time=2.648..2.650 rows=47.00 loops=1)
                Buffers: shared hit=1344
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.320..0.321 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.319..0.320 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.022..3.985 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Index Searches: 1
        Buffers: shared hit=3037 read=3
Planning:
  Buffers: shared hit=115
Planning Time: 0.235 ms
Execution Time: 4.254 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.947..3.756 rows=50.00 loops=1)
  Buffers: shared hit=3046 read=3
  InitPlan 1
    ->  Result (actual time=2.535..2.549 rows=47.00 loops=1)
          Buffers: shared hit=1345
          ->  ProjectSet (actual time=2.535..2.537 rows=47.00 loops=1)
                Buffers: shared hit=1345
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.079..0.079 rows=0.00 loops=1)
          Buffers: shared hit=9
          ->  ProjectSet (actual time=0.079..0.079 rows=0.00 loops=1)
                Buffers: shared hit=9
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.284..0.285 rows=2.00 loops=1)
          Buffers: shared hit=213
          ->  ProjectSet (actual time=0.284..0.284 rows=2.00 loops=1)
                Buffers: shared hit=213
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.947..3.752 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 1428
        Index Searches: 1
        Buffers: shared hit=3046 read=3
Planning:
  Buffers: shared hit=120
Planning Time: 0.178 ms
Execution Time: 3.968 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=3.213..4.223 rows=50.00 loops=1)
  Buffers: shared hit=3036 read=2
  InitPlan 1
    ->  Result (actual time=2.817..2.831 rows=47.00 loops=1)
          Buffers: shared hit=1342
          ->  ProjectSet (actual time=2.816..2.818 rows=47.00 loops=1)
                Buffers: shared hit=1342
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.325..0.326 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.324..0.325 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.212..4.220 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Index Searches: 1
        Buffers: shared hit=3036 read=2
Planning:
  Buffers: shared hit=115
Planning Time: 0.215 ms
Execution Time: 4.639 ms
```

