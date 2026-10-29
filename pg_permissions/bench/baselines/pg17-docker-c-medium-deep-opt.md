# Benchmark: c-compiled-model (design c), medium scale, deep shape

- Date: 2026-10-29 12:24
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.35 | 0.263 | 15224 | 1 | ok |
| rbac_select_page | 0.48 | 0.63 | 0.481 | 8318 | 2 | ok |
| rbac_select_count | 0.38 | 0.47 | 0.366 | 10924 | 2 | ok |
| rbac_update_one | 0.46 | 0.68 | 0.483 | 8279 | 3 | ok |
| write_assign_role | 0.20 | 0.28 | 0.206 | 19398 | 1 | ok |
| share_list_objects | 0.29 | 0.37 | 0.276 | 14505 | 1 | ok |
| share_select_page | 0.69 | 0.88 | 0.693 | 5774 | 3 | ok |
| write_share | 0.17 | 0.24 | 0.179 | 22322 | 1 | ok |
| parents_proj_select_page | 0.73 | 1.03 | 0.756 | 5293 | 4 | ok |
| parents_proj_select_count | 1.10 | 1.81 | 1.206 | 3316 | 4 | ok |
| parents_select_page | 2.92 | 4.43 | 3.120 | 1282 | 25 | ok |
| parents_select_count | 2.16 | 2.62 | 2.201 | 1817 | 23 | ok |
| write_nest_team | 68.57 | 105.10 | 70.280 | 56 | 1 | OVER |
| nest_check | 0.32 | 0.43 | 0.310 | 12904 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.76 | 2.9 | 10053 |
| sharing | 1.07 | 15.0 | 71727 |
| parents_proj | 0.18 | 15.5 | 73746 |
| parents | 2.25 | 31.5 | 173746 |
| nesting | 0.06 | 33.1 | 182747 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| allowed_subjects | 0.05 MB, 6 rows | 0.05 MB, 12 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows |
| ancestors | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.16 MB, 500 rows | 0.16 MB, 500 rows | 0.16 MB, 500 rows |
| memberships | 0.02 MB, 0 rows | 7.98 MB, 44481 rows | 7.98 MB, 44481 rows | 7.98 MB, 44481 rows | 9.56 MB, 53481 rows |
| models | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| parent_types | 0.01 MB, 0 rows | 0.01 MB, 0 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows |
| parents | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.16 MB, 500 rows | 16.16 MB, 100500 rows | 16.16 MB, 100500 rows |
| relations | 0.08 MB, 14 rows | 0.08 MB, 17 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows |
| satisfies | 0.05 MB, 26 rows | 0.05 MB, 30 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows |
| tuples | 2.48 MB, 10000 rows | 6.62 MB, 27177 rows | 6.86 MB, 28177 rows | 6.86 MB, 28177 rows | 6.86 MB, 28178 rows |
| types | 0.08 MB, 3 rows | 0.08 MB, 5 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |

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
- vs design a (2026-10-29 12:19): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 12:21): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=1.753..2.571 rows=50 loops=1)
  Buffers: shared hit=2472 read=8
  InitPlan 1
    ->  Result (actual time=1.715..1.716 rows=2 loops=1)
          Buffers: shared hit=995
          ->  ProjectSet (actual time=1.714..1.715 rows=2 loops=1)
                Buffers: shared hit=995
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.753..2.567 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Buffers: shared hit=2472 read=8
Planning:
  Buffers: shared hit=109
Planning Time: 0.147 ms
Execution Time: 2.771 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.912..4.082 rows=50 loops=1)
  Buffers: shared hit=2695 read=3
  InitPlan 1
    ->  Result (actual time=2.076..2.077 rows=2 loops=1)
          Buffers: shared hit=1087
          ->  ProjectSet (actual time=2.075..2.076 rows=2 loops=1)
                Buffers: shared hit=1087
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.791..0.791 rows=1 loops=1)
          Buffers: shared hit=126
  ->  Index Scan using documents_pkey on documents (actual time=2.912..4.078 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2695 read=3
Planning:
  Buffers: shared hit=114
Planning Time: 0.181 ms
Execution Time: 4.322 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.940..4.205 rows=50 loops=1)
  Buffers: shared hit=2739 read=3
  InitPlan 1
    ->  Result (actual time=2.169..2.169 rows=1 loops=1)
          Buffers: shared hit=1074
  InitPlan 2
    ->  Result (actual time=0.734..0.735 rows=1 loops=1)
          Buffers: shared hit=183
  ->  Index Scan using documents_pkey on documents (actual time=2.939..4.201 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2739 read=3
Planning:
  Buffers: shared hit=103
Planning Time: 0.167 ms
Execution Time: 4.217 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=9.291..9.295 rows=50 loops=1)
  Buffers: shared hit=3450
  InitPlan 1
    ->  Result (actual time=5.515..5.515 rows=1 loops=1)
          Buffers: shared hit=1189
  ->  Sort (actual time=9.289..9.291 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=3450
        ->  Bitmap Heap Scan on documents (actual time=7.264..9.050 rows=4045 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1134
              Buffers: shared hit=3447
              ->  Bitmap Index Scan on documents_pkey (actual time=7.184..7.184 rows=4045 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Buffers: shared hit=2313
Planning:
  Buffers: shared hit=100
Planning Time: 0.285 ms
Execution Time: 9.316 ms
```

