# Benchmark: c-compiled-model (design c), small scale, default shape

- Date: 2026-10-29 00:25
- Postgres: 16.4 (Postgres.app)
- Data: 10000 documents, 1000 users, 20 orgs, 50 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.22 | 0.29 | 0.230 | 17380 | 1 | ok |
| rbac_select_page | 0.40 | 0.49 | 0.415 | 9644 | 2 | ok |
| rbac_select_count | 0.36 | 0.43 | 0.369 | 10838 | 2 | ok |
| rbac_update_one | 0.65 | 0.77 | 0.636 | 6288 | 4 | ok |
| write_assign_role | 0.20 | 0.36 | 0.220 | 18159 | 1 | ok |
| share_list_objects | 0.22 | 0.32 | 0.232 | 17235 | 2 | ok |
| share_select_page | 0.53 | 0.68 | 0.554 | 7218 | 5 | ok |
| write_share | 0.16 | 0.28 | 0.175 | 22823 | 1 | ok |
| parents_proj_select_page | 0.48 | 0.57 | 0.492 | 8128 | - | - |
| parents_proj_select_count | 0.43 | 0.51 | 0.438 | 9130 | - | - |
| parents_select_page | 1.09 | 1.30 | 1.121 | 3568 | - | - |
| parents_select_count | 1.01 | 1.19 | 1.025 | 3902 | - | - |
| write_nest_team | 62.07 | 72.14 | 61.591 | 64 | - | - |
| nest_check | 0.24 | 0.30 | 0.244 | 16368 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.17 | 1.0 | 2053 |
| sharing | 0.68 | 2.7 | 10006 |
| parents_proj | 0.11 | 3.0 | 10625 |
| parents | 0.18 | 4.6 | 20625 |
| nesting | 0.06 | 5.1 | 23626 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| allowed_subjects | 0.05 MB, 6 rows | 0.05 MB, 12 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows |
| ancestors | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.11 MB, 200 rows | 0.11 MB, 200 rows | 0.11 MB, 200 rows |
| memberships | 0.02 MB, 0 rows | 0.71 MB, 3640 rows | 0.71 MB, 3640 rows | 0.71 MB, 3640 rows | 1.25 MB, 6640 rows |
| models | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| parent_types | 0.01 MB, 0 rows | 0.01 MB, 0 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows |
| parents | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.09 MB, 200 rows | 1.70 MB, 10200 rows | 1.70 MB, 10200 rows |
| relations | 0.08 MB, 14 rows | 0.08 MB, 17 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows |
| satisfies | 0.05 MB, 26 rows | 0.05 MB, 30 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows |
| tuples | 0.59 MB, 2000 rows | 1.62 MB, 6297 rows | 1.66 MB, 6497 rows | 1.66 MB, 6497 rows | 1.66 MB, 6498 rows |
| types | 0.08 MB, 3 rows | 0.08 MB, 5 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |

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

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-29 00:20): parents_proj: same; rbac: same; parents: same; sharing: same
- vs design b (2026-10-29 00:23): parents_proj: same; rbac: same; parents: same; sharing: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.507..0.660 rows=50 loops=1)
  Buffers: shared hit=621 read=4
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.486..0.487 rows=2 loops=1)
          Buffers: shared hit=31
          ->  ProjectSet (actual time=0.485..0.486 rows=2 loops=1)
                Buffers: shared hit=31
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.507..0.658 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 548
        Buffers: shared hit=621 read=4
Planning:
  Buffers: shared hit=1059
Planning Time: 2.753 ms
Execution Time: 0.666 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.913..1.085 rows=50 loops=1)
  Buffers: shared hit=648 read=2
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.488..0.489 rows=2 loops=1)
          Buffers: shared hit=29
          ->  ProjectSet (actual time=0.488..0.488 rows=2 loops=1)
                Buffers: shared hit=29
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.406..0.406 rows=1 loops=1)
          Buffers: shared hit=28
  ->  Index Scan using documents_pkey on documents (actual time=0.912..1.083 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 548
        Buffers: shared hit=648 read=2
Planning:
  Buffers: shared hit=1053
Planning Time: 2.747 ms
Execution Time: 1.091 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.335..3.527 rows=50 loops=1)
  Buffers: shared hit=1567 read=2
  InitPlan 1 (returns $0)
    ->  Result (actual time=2.684..2.684 rows=1 loops=1)
          Buffers: shared hit=907
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.632..0.632 rows=1 loops=1)
          Buffers: shared hit=69
  ->  Index Scan using documents_pkey on documents (actual time=3.334..3.524 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 548
        Buffers: shared hit=1567 read=2
Planning:
  Buffers: shared hit=135
Planning Time: 0.256 ms
Execution Time: 3.537 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=3.712..3.715 rows=50 loops=1)
  Buffers: shared hit=3131
  InitPlan 1 (returns $0)
    ->  Result (actual time=3.112..3.112 rows=1 loops=1)
          Buffers: shared hit=997
  ->  Sort (actual time=3.712..3.713 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=3131
        ->  Bitmap Heap Scan on documents (actual time=3.501..3.651 rows=1007 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=114
              Buffers: shared hit=3128
              ->  Bitmap Index Scan on documents_pkey (actual time=3.494..3.494 rows=1007 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=3014
Planning:
  Buffers: shared hit=102
Planning Time: 0.216 ms
Execution Time: 3.728 ms
```

