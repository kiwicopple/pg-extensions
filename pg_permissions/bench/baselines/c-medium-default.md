# Benchmark: c-compiled-model (design c), medium scale, default shape

- Date: 2026-10-29 00:18
- Postgres: 16.4 (Postgres.app)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.22 | 0.29 | 0.232 | 17232 | - | - |
| rbac_select_page | 0.49 | 0.63 | 0.518 | 7717 | - | - |
| rbac_select_count | 0.43 | 0.52 | 0.441 | 9060 | - | - |
| rbac_update_one | 0.67 | 0.89 | 0.670 | 5972 | - | - |
| write_assign_role | 0.21 | 0.39 | 0.231 | 17317 | - | - |
| share_list_objects | 0.22 | 0.29 | 0.227 | 17633 | - | - |
| share_select_page | 0.69 | 0.81 | 0.700 | 5713 | - | - |
| write_share | 0.16 | 0.29 | 0.177 | 22639 | - | - |
| parents_proj_select_page | 0.66 | 0.82 | 0.673 | 5947 | - | - |
| parents_proj_select_count | 0.68 | 0.78 | 0.695 | 5754 | - | - |
| parents_select_page | 4.61 | 5.21 | 4.639 | 862 | - | - |
| parents_select_count | 3.90 | 4.38 | 3.930 | 1017 | - | - |
| write_nest_team | 272.03 | 306.48 | 272.714 | 14 | - | - |
| nest_check | 0.26 | 0.33 | 0.270 | 14838 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.86 | 2.9 | 10053 |
| sharing | 2.13 | 10.4 | 46241 |
| parents_proj | 0.21 | 11.0 | 48260 |
| parents | 1.59 | 27.0 | 148260 |
| nesting | 0.11 | 27.8 | 152261 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| allowed_subjects | 0.05 MB, 6 rows | 0.05 MB, 12 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows |
| ancestors | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.16 MB, 500 rows | 0.16 MB, 500 rows | 0.16 MB, 500 rows |
| memberships | 0.02 MB, 0 rows | 3.45 MB, 18975 rows | 3.45 MB, 18975 rows | 3.45 MB, 18975 rows | 4.17 MB, 22975 rows |
| models | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| parent_types | 0.01 MB, 0 rows | 0.01 MB, 0 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows |
| parents | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.16 MB, 500 rows | 16.16 MB, 100500 rows | 16.16 MB, 100500 rows |
| relations | 0.08 MB, 14 rows | 0.08 MB, 17 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows |
| satisfies | 0.05 MB, 26 rows | 0.05 MB, 30 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows |
| tuples | 2.48 MB, 10000 rows | 6.63 MB, 27197 rows | 6.87 MB, 28197 rows | 6.87 MB, 28197 rows | 6.87 MB, 28198 rows |
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

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-29 00:12): parents_proj: same; rbac: same; parents: same; sharing: same
- vs design b (2026-10-29 00:15): parents_proj: same; rbac: same; parents: same; sharing: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.500..1.193 rows=50 loops=1)
  Buffers: shared hit=1509 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.477..0.478 rows=2 loops=1)
          Buffers: shared hit=32
          ->  ProjectSet (actual time=0.477..0.477 rows=2 loops=1)
                Buffers: shared hit=32
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.500..1.191 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1509 read=8
Planning:
  Buffers: shared hit=1054
Planning Time: 2.740 ms
Execution Time: 1.198 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.944..1.698 rows=50 loops=1)
  Buffers: shared hit=1559 read=4
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.507..0.508 rows=2 loops=1)
          Buffers: shared hit=42
          ->  ProjectSet (actual time=0.507..0.507 rows=2 loops=1)
                Buffers: shared hit=42
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.416..0.416 rows=1 loops=1)
          Buffers: shared hit=37
  ->  Index Scan using documents_pkey on documents (actual time=0.943..1.696 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1559 read=4
Planning:
  Buffers: shared hit=1070
Planning Time: 2.781 ms
Execution Time: 1.704 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.149..3.976 rows=50 loops=1)
  Buffers: shared hit=2517 read=4
  InitPlan 1 (returns $0)
    ->  Result (actual time=2.569..2.569 rows=1 loops=1)
          Buffers: shared hit=943
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.554..0.555 rows=1 loops=1)
          Buffers: shared hit=94
  ->  Index Scan using documents_pkey on documents (actual time=3.149..3.974 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 1429
        Buffers: shared hit=2517 read=4
Planning:
  Buffers: shared hit=105
Planning Time: 0.218 ms
Execution Time: 3.986 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=7.299..7.302 rows=50 loops=1)
  Buffers: shared hit=14233
  InitPlan 1 (returns $0)
    ->  Result (actual time=4.046..4.046 rows=1 loops=1)
          Buffers: shared hit=1075
  ->  Sort (actual time=7.298..7.299 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=14233
        ->  Bitmap Heap Scan on documents (actual time=6.157..7.125 rows=4007 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1131
              Buffers: shared hit=14230
              ->  Bitmap Index Scan on documents_pkey (actual time=6.096..6.096 rows=4007 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=13099
Planning:
  Buffers: shared hit=102
Planning Time: 0.224 ms
Execution Time: 7.314 ms
```

