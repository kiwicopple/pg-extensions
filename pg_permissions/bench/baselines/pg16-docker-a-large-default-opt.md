# Benchmark: a-tuple-core (design a), large scale, default shape

- Date: 2026-10-29 11:43
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.32 | 0.64 | 0.350 | 11432 | 1 | ok |
| rbac_select_page | 0.75 | 1.42 | 0.851 | 4697 | 3 | ok |
| rbac_select_count | 0.85 | 1.22 | 0.895 | 4469 | 3 | ok |
| rbac_update_one | 0.60 | 0.97 | 0.628 | 6369 | 3 | ok |
| write_assign_role | 0.17 | 0.32 | 0.196 | 20408 | 1 | ok |
| share_list_objects | 0.32 | 0.52 | 0.333 | 12004 | 2 | ok |
| share_select_page | 1.13 | 2.08 | 1.262 | 3170 | 6 | ok |
| write_share | 0.17 | 0.35 | 0.202 | 19800 | 1 | ok |
| parents_proj_select_page | 1.40 | 2.44 | 1.539 | 2599 | 4 | ok |
| parents_proj_select_count | 9.43 | 12.90 | 9.832 | 406 | 9 | OVER |
| parents_select_page | 45.98 | 59.92 | 47.033 | 85 | 32 | OVER |
| parents_select_count | 79.61 | 108.22 | 81.684 | 48 | 70 | OVER |
| write_nest_team | 0.16 | 0.24 | 0.173 | 23169 | 1 | ok |
| nest_check | 0.30 | 0.49 | 0.316 | 12664 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 8.18 | 7.0 | 20020 |
| sharing | 0.87 | 18.7 | 54022 |
| parents_proj | 0.09 | 19.6 | 57025 |
| parents | 29.47 | 404.3 | 1057026 |
| nesting | 0.03 | 404.3 | 1057027 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 6.76 MB, 20000 rows | 18.46 MB, 53997 rows | 19.44 MB, 56997 rows | 404.09 MB, 1056997 rows | 404.09 MB, 1056998 rows |

## Equivalence

Documents each sample user sees through RLS after each seed, and the md5 of their sorted ids. Every 5th user is also a folder viewer, so for users not divisible by 5 parents_proj and parents must equal sharing, and parents_proj must always equal parents.

| policy | user | visible | md5 |
| --- | --- | --- | --- |
| rbac | 1 | 20000 | 83dfc8a4117363cd29474848ec593462 |
| rbac | 2 | 20000 | e011f33abf8ec3609fe7413a636dafb7 |
| rbac | 3 | 20000 | 5466f182950003a321d8658d12e38760 |
| rbac | 5 | 20000 | 694e0998e6843b06e6d8c4f5b4d88795 |
| rbac | 10 | 20000 | 821fd2c6b79483746aab43841450b9c6 |
| rbac | 77 | 20000 | 43afbd5eee1be997db26e1ca9a889aa3 |
| rbac | 500 | 20000 | 0561304ca98a061cdf6a51a7d82459e6 |
| rbac | 10000 | 20000 | 0561304ca98a061cdf6a51a7d82459e6 |
| sharing | 1 | 20007 | d2b4030ad636f968f35a8af5008ac9f6 |
| sharing | 2 | 20007 | abb87f25aaf62620d8b791efa17462b4 |
| sharing | 3 | 20012 | b4c68ea1387b14cdb659ac1be1bc314a |
| sharing | 5 | 20012 | 033a5195f5d6c532f52c9cd816196a27 |
| sharing | 10 | 20012 | e01f45d54102a2059611bc18421a6fc3 |
| sharing | 77 | 20022 | eb1cd8028cf96891dd907c58dd08b89f |
| sharing | 500 | 20007 | abc7fbfa02e70e61e8a0b57bc01c375f |
| sharing | 10000 | 20007 | b91916b3d484d728f128f79576324a38 |
| parents_proj | 1 | 20007 | d2b4030ad636f968f35a8af5008ac9f6 |
| parents_proj | 2 | 20007 | abb87f25aaf62620d8b791efa17462b4 |
| parents_proj | 3 | 20012 | b4c68ea1387b14cdb659ac1be1bc314a |
| parents_proj | 5 | 21012 | 62038fc0969395160b3e96933ddac9e4 |
| parents_proj | 10 | 21012 | 447d15cf1ccb48b8a791f10de5616989 |
| parents_proj | 77 | 20022 | eb1cd8028cf96891dd907c58dd08b89f |
| parents_proj | 500 | 21007 | d357b76a845e832d77fdd55403df4e56 |
| parents_proj | 10000 | 21007 | 24fc32209c7c854bc0f098b1e1d6940d |
| parents | 1 | 20007 | d2b4030ad636f968f35a8af5008ac9f6 |
| parents | 2 | 20007 | abb87f25aaf62620d8b791efa17462b4 |
| parents | 3 | 20012 | b4c68ea1387b14cdb659ac1be1bc314a |
| parents | 5 | 21012 | 62038fc0969395160b3e96933ddac9e4 |
| parents | 10 | 21012 | 447d15cf1ccb48b8a791f10de5616989 |
| parents | 77 | 20022 | eb1cd8028cf96891dd907c58dd08b89f |
| parents | 500 | 21007 | d357b76a845e832d77fdd55403df4e56 |
| parents | 10000 | 21007 | 24fc32209c7c854bc0f098b1e1d6940d |

Compared with other designs' latest runs at this scale and shape:
- vs design b (2026-10-29 08:09): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 08:12): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=1.878..5.928 rows=50 loops=1)
  Buffers: shared hit=3395 read=13
  InitPlan 1 (returns $0)
    ->  Result (actual time=1.716..1.717 rows=2 loops=1)
          Buffers: shared hit=727
          ->  ProjectSet (actual time=1.715..1.716 rows=2 loops=1)
                Buffers: shared hit=727
                ->  Result (actual time=0.000..0.001 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.878..5.924 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3395 read=13
Planning:
  Buffers: shared hit=109
Planning Time: 0.143 ms
Execution Time: 6.274 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.059..5.786 rows=50 loops=1)
  Buffers: shared hit=3473 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=1.786..1.787 rows=2 loops=1)
          Buffers: shared hit=724
          ->  ProjectSet (actual time=1.785..1.786 rows=2 loops=1)
                Buffers: shared hit=724
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.163..0.166 rows=7 loops=1)
          Buffers: shared hit=79
          ->  ProjectSet (actual time=0.163..0.163 rows=7 loops=1)
                Buffers: shared hit=79
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.059..5.781 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3473 read=12
Planning:
  Buffers: shared hit=144
Planning Time: 0.234 ms
Execution Time: 6.003 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.226..5.885 rows=50 loops=1)
  Buffers: shared hit=3734 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=1.866..1.869 rows=7 loops=1)
          Buffers: shared hit=867
          ->  ProjectSet (actual time=1.865..1.866 rows=7 loops=1)
                Buffers: shared hit=867
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.244..0.250 rows=20 loops=1)
          Buffers: shared hit=197
          ->  ProjectSet (actual time=0.243..0.244 rows=20 loops=1)
                Buffers: shared hit=197
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.225..5.880 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3734 read=12
Planning:
  Buffers: shared hit=111
Planning Time: 0.182 ms
Execution Time: 6.124 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=40.881..41.083 rows=50 loops=1)
  Buffers: shared hit=19604 read=1578 written=1
  InitPlan 1 (returns $0)
    ->  Result (actual time=32.153..37.559 rows=20007 loops=1)
          Buffers: shared hit=19451 read=1528 written=1
          ->  ProjectSet (actual time=32.150..32.815 rows=20007 loops=1)
                Buffers: shared hit=19451 read=1528 written=1
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=40.880..41.079 rows=50 loops=1)
        Index Cond: (id = ANY ($0))
        Buffers: shared hit=19604 read=1578 written=1
Planning:
  Buffers: shared hit=87 read=19 dirtied=1
Planning Time: 0.349 ms
Execution Time: 41.640 ms
```

