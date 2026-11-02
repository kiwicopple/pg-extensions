# Benchmark: c-compiled-model (design c), medium scale, deep shape

- Date: 2026-10-28 23:57
- Postgres: 16.4 (Postgres.app)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.23 | 0.30 | 0.236 | 16975 | - | - |
| rbac_select_page | 0.49 | 0.57 | 0.497 | 8042 | - | - |
| rbac_select_count | 0.43 | 0.54 | 0.451 | 8861 | - | - |
| rbac_update_one | 0.68 | 0.79 | 0.664 | 6026 | - | - |
| write_assign_role | 0.20 | 0.35 | 0.222 | 18033 | - | - |
| share_list_objects | 0.24 | 0.30 | 0.246 | 16280 | - | - |
| share_select_page | 0.77 | 0.91 | 0.785 | 5098 | - | - |
| write_share | 0.16 | 0.29 | 0.179 | 22349 | - | - |
| parents_proj_select_page | 0.75 | 1.03 | 0.785 | 5093 | - | - |
| parents_proj_select_count | 0.72 | 1.07 | 0.767 | 5216 | - | - |
| parents_select_page | 4.89 | 8.22 | 5.404 | 740 | - | - |
| parents_select_count | 4.22 | 7.44 | 4.707 | 849 | - | - |
| write_nest_team | 353.55 | 536.42 | 369.979 | 10 | - | - |
| nest_check | 0.27 | 0.35 | 0.284 | 14073 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.86 | 2.9 | 10053 |
| sharing | 2.22 | 15.0 | 71727 |
| parents_proj | 0.21 | 15.5 | 73746 |
| parents | 1.64 | 31.5 | 173746 |
| nesting | 0.24 | 33.1 | 182747 |

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
- vs design a (2026-10-28 23:51): parents_proj: same; rbac: same; parents: same; sharing: same
- vs design b (2026-10-28 23:54): parents_proj: same; rbac: same; parents: same; sharing: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.612..1.279 rows=50 loops=1)
  Buffers: shared hit=1509 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.585..0.586 rows=2 loops=1)
          Buffers: shared hit=32
          ->  ProjectSet (actual time=0.585..0.585 rows=2 loops=1)
                Buffers: shared hit=32
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.611..1.277 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1509 read=8
Planning:
  Buffers: shared hit=1054
Planning Time: 2.821 ms
Execution Time: 1.286 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=1.148..2.093 rows=50 loops=1)
  Buffers: shared hit=1639 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.654..0.655 rows=2 loops=1)
          Buffers: shared hit=82
          ->  ProjectSet (actual time=0.653..0.654 rows=2 loops=1)
                Buffers: shared hit=82
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.474..0.474 rows=1 loops=1)
          Buffers: shared hit=77
  ->  Index Scan using documents_pkey on documents (actual time=1.148..2.090 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=1639 read=3
Planning:
  Buffers: shared hit=1106
Planning Time: 3.971 ms
Execution Time: 2.102 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.082..4.014 rows=50 loops=1)
  Buffers: shared hit=2593 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=2.524..2.524 rows=1 loops=1)
          Buffers: shared hit=979
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.539..0.539 rows=1 loops=1)
          Buffers: shared hit=134
  ->  Index Scan using documents_pkey on documents (actual time=3.082..4.012 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2593 read=3
Planning:
  Buffers: shared hit=105
Planning Time: 0.211 ms
Execution Time: 4.024 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=7.394..7.397 rows=50 loops=1)
  Buffers: shared hit=14388
  InitPlan 1 (returns $0)
    ->  Result (actual time=4.160..4.161 rows=1 loops=1)
          Buffers: shared hit=1111
  ->  Sort (actual time=7.393..7.394 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=14388
        ->  Bitmap Heap Scan on documents (actual time=6.284..7.225 rows=4045 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1136
              Buffers: shared hit=14385
              ->  Bitmap Index Scan on documents_pkey (actual time=6.222..6.222 rows=4045 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=13249
Planning:
  Buffers: shared hit=102
Planning Time: 0.206 ms
Execution Time: 7.410 ms
```

