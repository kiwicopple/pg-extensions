# Benchmark: c-compiled-model (design c), large scale, default shape

- Date: 2026-10-29 13:21
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.43 | 0.275 | 14563 | 1 | ok |
| rbac_select_page | 0.75 | 1.44 | 0.845 | 4733 | 3 | ok |
| rbac_select_count | 0.86 | 1.38 | 0.925 | 4322 | 3 | ok |
| rbac_update_one | 0.51 | 0.68 | 0.496 | 8064 | 3 | ok |
| write_assign_role | 0.22 | 0.35 | 0.241 | 16577 | 1 | ok |
| share_list_objects | 0.27 | 0.39 | 0.267 | 14953 | 2 | ok |
| share_select_page | 1.01 | 1.48 | 1.070 | 3739 | 6 | ok |
| write_share | 0.19 | 0.36 | 0.218 | 18368 | 1 | ok |
| parents_proj_select_page | 1.09 | 1.67 | 1.168 | 3423 | 4 | ok |
| parents_proj_select_count | 8.06 | 10.38 | 8.271 | 483 | 9 | OVER |
| parents_select_page | 5.26 | 7.52 | 5.723 | 698 | 32 | ok |
| parents_select_count | 18.59 | 21.75 | 18.822 | 212 | 70 | ok |
| write_nest_team | 54.98 | 64.33 | 55.463 | 72 | 1 | OVER |
| nest_check | 0.32 | 0.46 | 0.318 | 12574 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 5.15 | 5.3 | 20053 |
| sharing | 1.91 | 21.3 | 98346 |
| parents_proj | 0.36 | 22.3 | 102365 |
| parents | 19.08 | 182.4 | 1102365 |
| nesting | 0.03 | 183.2 | 1107366 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| allowed_subjects | 0.05 MB, 6 rows | 0.05 MB, 12 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows |
| ancestors | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.26 MB, 1000 rows | 0.26 MB, 1000 rows | 0.26 MB, 1000 rows |
| memberships | 0.02 MB, 0 rows | 7.95 MB, 44280 rows | 7.95 MB, 44280 rows | 7.95 MB, 44280 rows | 8.82 MB, 49280 rows |
| models | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| parent_types | 0.01 MB, 0 rows | 0.01 MB, 0 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows |
| parents | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.23 MB, 1000 rows | 160.27 MB, 1001000 rows | 160.27 MB, 1001000 rows |
| relations | 0.08 MB, 14 rows | 0.08 MB, 17 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows |
| satisfies | 0.05 MB, 26 rows | 0.05 MB, 30 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows |
| tuples | 4.88 MB, 20000 rows | 13.02 MB, 53997 rows | 13.49 MB, 55997 rows | 13.49 MB, 55997 rows | 13.49 MB, 55998 rows |
| types | 0.08 MB, 3 rows | 0.08 MB, 5 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |

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
- vs design a (2026-10-29 13:08): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 13:11): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.412..7.835 rows=50 loops=1)
  Buffers: shared hit=3663 read=13
  InitPlan 1 (returns $0)
    ->  Result (actual time=2.236..2.238 rows=2 loops=1)
          Buffers: shared hit=995
          ->  ProjectSet (actual time=2.235..2.236 rows=2 loops=1)
                Buffers: shared hit=995
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.412..7.830 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3663 read=13
Planning:
  Buffers: shared hit=109
Planning Time: 0.194 ms
Execution Time: 8.200 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.624..6.545 rows=50 loops=1)
  Buffers: shared hit=3719 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=1.963..1.964 rows=2 loops=1)
          Buffers: shared hit=1005
          ->  ProjectSet (actual time=1.962..1.963 rows=2 loops=1)
                Buffers: shared hit=1005
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.549..0.549 rows=1 loops=1)
          Buffers: shared hit=44
  ->  Index Scan using documents_pkey on documents (actual time=2.623..6.540 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3719 read=12
Planning:
  Buffers: shared hit=114
Planning Time: 0.205 ms
Execution Time: 6.815 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.971..7.752 rows=50 loops=1)
  Buffers: shared hit=3741 read=12
  InitPlan 1 (returns $0)
    ->  Result (actual time=3.116..3.116 rows=1 loops=1)
          Buffers: shared hit=967
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.719..0.720 rows=1 loops=1)
          Buffers: shared hit=104
  ->  Index Scan using documents_pkey on documents (actual time=3.970..7.747 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=3741 read=12
Planning:
  Buffers: shared hit=133
Planning Time: 0.343 ms
Execution Time: 7.763 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=6.891..7.156 rows=50 loops=1)
  Buffers: shared hit=1378 read=48
  InitPlan 1 (returns $0)
    ->  Result (actual time=6.632..6.632 rows=1 loops=1)
          Buffers: shared hit=1223
  ->  Index Scan using documents_pkey on documents (actual time=6.890..7.151 rows=50 loops=1)
        Index Cond: (id = ANY ($0))
        Buffers: shared hit=1378 read=48
Planning:
  Buffers: shared hit=100
Planning Time: 0.135 ms
Execution Time: 7.168 ms
```

