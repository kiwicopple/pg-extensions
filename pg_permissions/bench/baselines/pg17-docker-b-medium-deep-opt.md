# Benchmark: b-policy-first (design b), medium scale, deep shape

- Date: 2026-10-29 12:21
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.38 | 0.268 | 14936 | 1 | ok |
| rbac_select_page | 0.45 | 0.58 | 0.441 | 9061 | 2 | ok |
| rbac_select_count | 0.36 | 0.46 | 0.342 | 11688 | 2 | ok |
| rbac_update_one | 0.45 | 0.59 | 0.436 | 9173 | 3 | ok |
| write_assign_role | 0.15 | 0.22 | 0.154 | 25996 | 1 | ok |
| share_list_objects | 0.30 | 0.38 | 0.286 | 14008 | 1 | ok |
| share_select_page | 0.71 | 0.91 | 0.739 | 5414 | 3 | ok |
| write_share | 0.14 | 0.21 | 0.144 | 27856 | 1 | ok |
| parents_proj_select_page | 0.82 | 1.03 | 0.832 | 4806 | 4 | ok |
| parents_proj_select_count | 1.21 | 1.50 | 1.225 | 3264 | 4 | ok |
| parents_select_page | 4.63 | 5.70 | 4.889 | 818 | 25 | ok |
| parents_select_count | 3.74 | 4.70 | 3.877 | 1031 | 23 | ok |
| write_nest_team | 0.61 | 0.71 | 0.636 | 6291 | 1 | ok |
| nest_check | 0.33 | 0.42 | 0.316 | 12660 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.52 | 3.9 | 10028 |
| sharing | 0.42 | 10.1 | 27985 |
| parents_proj | 0.05 | 10.6 | 29489 |
| parents | 3.78 | 46.5 | 129989 |
| nesting | 0.02 | 46.5 | 129999 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 0.34 MB, 772 rows | 0.34 MB, 772 rows | 0.50 MB, 1272 rows | 0.50 MB, 1281 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 2.11 MB, 6177 rows | 2.27 MB, 6677 rows | 37.95 MB, 106677 rows | 37.95 MB, 106678 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 3.56 MB, 10000 rows | 7.38 MB, 21000 rows | 7.73 MB, 22000 rows | 7.73 MB, 22000 rows | 7.73 MB, 22000 rows |
| role_implies | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows |
| roles | 0.06 MB, 6 rows | 0.06 MB, 8 rows | 0.06 MB, 9 rows | 0.06 MB, 9 rows | 0.06 MB, 9 rows |

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
- vs design c (2026-10-29 12:16): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.806..3.762 rows=50 loops=1)
  Buffers: shared hit=2348 read=8
  InitPlan 1
    ->  Result (actual time=2.753..2.754 rows=2 loops=1)
          Buffers: shared hit=871
          ->  ProjectSet (actual time=2.753..2.753 rows=2 loops=1)
                Buffers: shared hit=871
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.805..3.758 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Buffers: shared hit=2348 read=8
Planning:
  Buffers: shared hit=109
Planning Time: 0.182 ms
Execution Time: 4.000 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.955..3.842 rows=50 loops=1)
  Buffers: shared hit=2438 read=3
  InitPlan 1
    ->  Result (actual time=2.683..2.684 rows=2 loops=1)
          Buffers: shared hit=905
          ->  ProjectSet (actual time=2.682..2.682 rows=2 loops=1)
                Buffers: shared hit=905
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.226..0.239 rows=47 loops=1)
          Buffers: shared hit=56
          ->  ProjectSet (actual time=0.225..0.227 rows=47 loops=1)
                Buffers: shared hit=56
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.955..3.839 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2438 read=3
Planning:
  Buffers: shared hit=114
Planning Time: 0.174 ms
Execution Time: 4.050 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.322..4.357 rows=50 loops=1)
  Buffers: shared hit=2472 read=3
  InitPlan 1
    ->  Result (actual time=3.074..3.088 rows=47 loops=1)
          Buffers: shared hit=926
          ->  ProjectSet (actual time=3.073..3.075 rows=47 loops=1)
                Buffers: shared hit=926
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.192..0.198 rows=20 loops=1)
          Buffers: shared hit=69
          ->  ProjectSet (actual time=0.191..0.192 rows=20 loops=1)
                Buffers: shared hit=69
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.321..4.353 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2472 read=3
Planning:
  Buffers: shared hit=111
Planning Time: 0.159 ms
Execution Time: 4.564 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=9.613..9.617 rows=50 loops=1)
  Buffers: shared hit=3330
  InitPlan 1
    ->  Result (actual time=4.880..6.069 rows=4045 loops=1)
          Buffers: shared hit=1069
          ->  ProjectSet (actual time=4.879..5.048 rows=4045 loops=1)
                Buffers: shared hit=1069
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=9.612..9.613 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=3330
        ->  Bitmap Heap Scan on documents (actual time=7.891..9.395 rows=4045 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1134
              Buffers: shared hit=3327
              ->  Bitmap Index Scan on documents_pkey (actual time=7.813..7.813 rows=4045 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Buffers: shared hit=2193
Planning:
  Buffers: shared hit=108
Planning Time: 0.171 ms
Execution Time: 9.877 ms
```

