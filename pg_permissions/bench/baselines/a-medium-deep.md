# Benchmark: a-tuple-core (design a), medium scale, deep shape

- Date: 2026-10-28 23:51
- Postgres: 16.4 (Postgres.app)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.37 | 0.283 | 14124 | - | - |
| rbac_select_page | 0.53 | 0.64 | 0.544 | 7358 | - | - |
| rbac_select_count | 0.47 | 0.56 | 0.481 | 8322 | - | - |
| rbac_update_one | 0.80 | 0.94 | 0.755 | 5298 | - | - |
| write_assign_role | 0.16 | 0.27 | 0.173 | 23129 | - | - |
| share_list_objects | 0.69 | 0.85 | 0.713 | 5609 | - | - |
| share_select_page | 2.47 | 2.73 | 2.498 | 1601 | - | - |
| write_share | 0.15 | 0.25 | 0.161 | 24867 | - | - |
| parents_proj_select_page | 3.47 | 3.90 | 3.504 | 1141 | - | - |
| parents_proj_select_count | 3.59 | 4.09 | 3.642 | 1098 | - | - |
| parents_select_page | 99.56 | 108.30 | 100.300 | 39 | - | - |
| parents_select_count | 97.69 | 105.95 | 98.382 | 40 | - | - |
| write_nest_team | 0.15 | 0.25 | 0.159 | 25221 | - | - |
| nest_check | 0.87 | 0.94 | 0.882 | 4536 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.80 | 3.6 | 10020 |
| sharing | 0.60 | 9.5 | 27202 |
| parents_proj | 0.08 | 10.0 | 28705 |
| parents | 3.81 | 47.9 | 128706 |
| nesting | 0.04 | 47.9 | 128707 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 3.43 MB, 10000 rows | 9.33 MB, 27177 rows | 9.81 MB, 28677 rows | 47.70 MB, 128677 rows | 47.70 MB, 128678 rows |

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

Compared with other designs' latest runs at this scale and shape: none yet.

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.400..1.056 rows=50 loops=1)
  Buffers: shared hit=1526 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.378..0.378 rows=2 loops=1)
          Buffers: shared hit=49
          ->  ProjectSet (actual time=0.377..0.377 rows=2 loops=1)
                Buffers: shared hit=49
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.400..1.054 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1526 read=8
Planning:
  Buffers: shared hit=688
Planning Time: 1.877 ms
Execution Time: 1.062 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=1.506..2.354 rows=50 loops=1)
  Buffers: shared hit=2209 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.732..0.733 rows=2 loops=1)
          Buffers: shared hit=363
          ->  ProjectSet (actual time=0.732..0.732 rows=2 loops=1)
                Buffers: shared hit=363
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.740..0.752 rows=47 loops=1)
          Buffers: shared hit=363
          ->  ProjectSet (actual time=0.740..0.741 rows=47 loops=1)
                Buffers: shared hit=363
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.505..2.352 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2209 read=3
Planning:
  Buffers: shared hit=1366
Planning Time: 3.257 ms
Execution Time: 2.361 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=1.887..2.861 rows=50 loops=1)
  Buffers: shared hit=2637 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.965..0.977 rows=47 loops=1)
          Buffers: shared hit=577
          ->  ProjectSet (actual time=0.965..0.966 rows=47 loops=1)
                Buffers: shared hit=577
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.882..0.887 rows=20 loops=1)
          Buffers: shared hit=577
          ->  ProjectSet (actual time=0.882..0.882 rows=20 loops=1)
                Buffers: shared hit=577
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.887..2.858 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2637 read=3
Planning:
  Buffers: shared hit=1788
Planning Time: 3.511 ms
Execution Time: 2.868 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=45.000..45.003 rows=50 loops=1)
  Buffers: shared hit=49967
  InitPlan 1 (returns $0)
    ->  Result (actual time=41.100..42.054 rows=4045 loops=1)
          Buffers: shared hit=36689
          ->  ProjectSet (actual time=41.099..41.186 rows=4045 loops=1)
                Buffers: shared hit=36689
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=45.000..45.001 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=49967
        ->  Bitmap Heap Scan on documents (actual time=43.921..44.820 rows=4045 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1137
              Buffers: shared hit=49964
              ->  Bitmap Index Scan on documents_pkey (actual time=43.857..43.857 rows=4045 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=48827
Planning:
  Buffers: shared hit=37321
Planning Time: 45.875 ms
Execution Time: 45.013 ms
```

