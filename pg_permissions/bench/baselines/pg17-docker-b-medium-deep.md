# Benchmark: b-policy-first (design b), medium scale, deep shape

- Date: 2026-10-29 08:25
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.34 | 0.46 | 0.335 | 11949 | 1 | ok |
| rbac_select_page | 0.54 | 0.74 | 0.547 | 7313 | 2 | ok |
| rbac_select_count | 0.44 | 0.55 | 0.426 | 9380 | 2 | ok |
| rbac_update_one | 0.74 | 0.94 | 0.737 | 5429 | 3 | ok |
| write_assign_role | 0.15 | 0.21 | 0.147 | 27157 | 1 | ok |
| share_list_objects | 0.50 | 0.60 | 0.487 | 8219 | 1 | ok |
| share_select_page | 1.74 | 2.37 | 1.807 | 2214 | 3 | ok |
| write_share | 0.14 | 0.20 | 0.142 | 28087 | 1 | ok |
| parents_proj_select_page | 1.13 | 1.33 | 1.134 | 3526 | 4 | ok |
| parents_proj_select_count | 1.47 | 1.69 | 1.483 | 2697 | 4 | ok |
| parents_select_page | 11.30 | 13.30 | 11.633 | 343 | 25 | ok |
| parents_select_count | 10.23 | 12.44 | 10.533 | 379 | 23 | ok |
| write_nest_team | 133.65 | 188.48 | 132.879 | 30 | 1 | OVER |
| nest_check | 1.34 | 1.58 | 1.358 | 2946 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.53 | 2.9 | 10028 |
| sharing | 0.60 | 18.0 | 72466 |
| parents_proj | 0.08 | 18.5 | 74470 |
| parents | 11.16 | 92.2 | 374470 |
| nesting | 0.08 | 94.2 | 383480 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 10.38 MB, 45253 rows | 10.51 MB, 45753 rows | 59.59 MB, 245753 rows | 61.65 MB, 254762 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 1.48 MB, 6177 rows | 1.60 MB, 6677 rows | 26.13 MB, 106677 rows | 26.13 MB, 106678 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 2.54 MB, 10000 rows | 5.88 MB, 21000 rows | 6.13 MB, 22000 rows | 6.13 MB, 22000 rows | 6.13 MB, 22000 rows |
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
- vs design a (2026-10-29 08:22): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 08:20): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.575..1.408 rows=50 loops=1)
  Buffers: shared hit=1507 read=8
  InitPlan 1
    ->  Result (actual time=0.540..0.541 rows=2 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.539..0.540 rows=2 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.575..1.406 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1507 read=8
Planning:
  Buffers: shared hit=816
Planning Time: 2.113 ms
Execution Time: 1.416 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.876..1.882 rows=50 loops=1)
  Buffers: shared hit=1686 read=3
  InitPlan 1
    ->  Result (actual time=0.487..0.487 rows=2 loops=1)
          Buffers: shared hit=102
          ->  ProjectSet (actual time=0.486..0.486 rows=2 loops=1)
                Buffers: shared hit=102
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.338..0.354 rows=47 loops=1)
          Buffers: shared hit=102
          ->  ProjectSet (actual time=0.338..0.340 rows=47 loops=1)
                Buffers: shared hit=102
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.875..1.879 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=1686 read=3
Planning:
  Buffers: shared hit=1008
Planning Time: 2.715 ms
Execution Time: 1.892 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=1.182..2.252 rows=50 loops=1)
  Buffers: shared hit=1728 read=3
  InitPlan 1
    ->  Result (actual time=0.600..0.622 rows=47 loops=1)
          Buffers: shared hit=123
          ->  ProjectSet (actual time=0.600..0.602 rows=47 loops=1)
                Buffers: shared hit=123
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.518..0.524 rows=20 loops=1)
          Buffers: shared hit=123
          ->  ProjectSet (actual time=0.518..0.519 rows=20 loops=1)
                Buffers: shared hit=123
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.181..2.248 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=1728 read=3
Planning:
  Buffers: shared hit=1052
Planning Time: 3.045 ms
Execution Time: 2.261 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=8.863..8.867 rows=50 loops=1)
  Buffers: shared hit=6063
  InitPlan 1
    ->  Result (actual time=4.110..5.204 rows=4045 loops=1)
          Buffers: shared hit=3803
          ->  ProjectSet (actual time=4.110..4.239 rows=4045 loops=1)
                Buffers: shared hit=3803
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=8.862..8.863 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=6063
        ->  Bitmap Heap Scan on documents (actual time=6.579..8.595 rows=4045 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1133
              Buffers: shared hit=6060
              ->  Bitmap Index Scan on documents_pkey (actual time=6.509..6.509 rows=4045 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Buffers: shared hit=4927
Planning:
  Buffers: shared hit=4601
Planning Time: 7.938 ms
Execution Time: 8.875 ms
```

