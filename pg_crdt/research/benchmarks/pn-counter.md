# PN-Counter benchmarks (pg_crdt 0.0.1)

Session 2, 2026-11-04. Script: [`bench/pn-counter.sh`](../../bench/pn-counter.sh) (a throwaway cluster, as in the test runner, but with `full_page_writes=on`).

| Run | Postgres | Machine |
| --- | --- | --- |
| A | 16.4 (Postgres.app), native | Apple M4, 10 CPU, 24 GB, macOS 27.0.1 |
| B | 18.6 (Debian), Docker (`pg_permissions-pg:18`) | the same M4, Docker Desktop VM, 10 CPU |

Default settings otherwise (shared_buffers 128 MB, fsync off, which does not change WAL volume). These are single runs on a laptop: read the ratios, not the third digit.

## Workload

- **States.** `n` replicas in `p` (ids `user-000001` ...), a third of them in `n`, random counts up to 1,000,000. Stored in a table, so the functions read them as a real `update` would (TOASTed and compressed above about 2 kB). Stored sizes (`pg_column_size`): 10 replicas 496 B, 100: 1.3 kB, 1,000: 12 kB, 10,000: 120 kB, the last two compressed by TOAST (about 9 bytes per entry).
- **full**: merge two states with the same replicas and independent random counts (about half the entries change).
- **delta**: merge a one-entry delta that raises an existing replica's count, the shape of `update t set s = crdt.pn_merge(s, $1)`.
- **Latency**: `select count(f(a, b)) from pairs where n = ...`, 12 to 2,000 rows per size, best of 3, divided by rows. It includes reading the stored values (detoast), not the planning.

## Merge latency (microseconds per call)

Run A (Postgres 16). Run B (Postgres 18) agrees within about 15% everywhere; see the raw output below.

| Replicas | `pn_merge` full | `pn_merge` delta | concat-only (no domain) full / delta | PL/pgSQL full / delta | full join full / delta | naive overlay full / delta | `jsonb_set` loop full / delta |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 19.7 | 11.0 | 15.3 / 8.3 | 14.8 / 8.0 | 22.1 / 19.3 | 14.4 / 8.2 | 14.7 / 4.3 |
| 100 | 128 | 23 | 108 / 29 | 112 / 28 | 100 / 68 | 304 / 29 | 406 / 13 |
| 1,000 | 1,318 | 123 | 1,174 / 234 | 1,166 / 231 | 829 / 534 | 19,504 / 247 | 31,470 / 78 |
| 10,000 | 14,449 | 1,201 | 13,134 / 2,058 | 12,800 / 2,062 | 8,372 / 5,031 | (1,850,000) / 2,179 | (not run) / 705 |

The variants (all in `bench/pn-counter.sh`, only `pn_merge` ships):

- **`pn_merge`**: `LANGUAGE sql`, overlay: a's map with b's larger entries written over it. The maps are extracted once. No change: the map is reused; one change: `jsonb_set`; more: `||`. Result cast to the `crdt.pn` domain.
- **concat-only, no domain**: the same overlay, `||` for every change, on plain `jsonb` (no CHECK on the result). This was `pn_merge` one step earlier.
- **PL/pgSQL**: the concat-only overlay in PL/pgSQL, with the maps in variables.
- **full join**: `jsonb_each(a) full join jsonb_each(b)`, `greatest`, `jsonb_object_agg`.
- **naive overlay**: the first draft of `pn_merge`, with `a -> 'p' -> e.key` written inline. The 10,000 full value (1.85 s) is from an earlier run of the same function.
- **`jsonb_set` loop**: PL/pgSQL, one `jsonb_set` per entry of b. The pattern the architecture rules out.

Other functions, per call: `pn_value` 5.9 / 26 / 210 / 2,170 us; `pn_increment` 1.7 / 9.7 / 73 / 707 us; `pn_is_valid` (the full validator) 3.8 / 40 / 392 / 3,960 us, for 10 / 100 / 1,000 / 10,000 replicas.

### What the numbers say

1. **SQL vs PL/pgSQL: no difference.** The same statement costs the same in both languages, at every size (the PL/pgSQL column vs concat-only). The work is building jsonb, not calling the function. Stay with `LANGUAGE sql`.
2. **The first draft was quadratic.** `a -> 'p' -> e.key` inside the sub-select over b's entries detoasts a and copies its map *per entry of b*: 19.5 ms at 1,000 replicas and 1.85 s at 10,000 for a full merge. Taking the maps out once (an `offset 0` sub-select) fixed it. The delta case hid the bug, because the delta has one entry. The property tests passed either way: this is a performance law that needs a benchmark.
3. **`||` re-sorts the whole map; `jsonb_set` on an existing key does not.** Writing one changed entry with `jsonb_set` made the delta merge 1.7 to 2 times faster at 1,000 and 10,000 replicas (234 to 123 us, 2,058 to 1,201 us). It costs about 3 us more at 10 replicas (two lateral sub-selects that count the changes).
4. **The `jsonb_set` loop is fastest for a one-entry delta and catastrophic for a full merge** (31 ms vs 1.3 ms at 1,000 replicas, quadratic). `pn_merge` takes `jsonb_set` for exactly one change and `||` otherwise, which gets most of the loop's speed for deltas without its worst case.
5. **The full join wins full merges from 100 replicas up** (8.4 ms vs 14.4 ms at 10,000) and loses deltas by 4 times. Deltas are the common write, so `pn_merge` stays an overlay. A full-state merge of two 10,000-replica states takes about 14 ms.
6. **The domain CHECK is cheap because it checks only the envelope.** `pn_merge` vs concat-only differs by the `jsonb_set` path and the CHECK together; the CHECK alone, measured on a 10,000-replica value, is about 10 us (`@>` and `jsonb - text[]` read the nested maps as opaque blobs). Checking every entry (`pn_is_valid`) costs 3.96 ms at 10,000 replicas, more than a delta merge, and would run on every merge result. So the domain checks the envelope, and `pn_apply_delta` runs the full validator on untrusted deltas. Two cheaper-looking alternatives were slower at 10,000 replicas: `jsonb_typeof(value -> 'p')` and the same for `n` copy both maps (about 0.65 ms), and jsonpath `keyvalue()` re-encodes them (about 0.4 ms).

## WAL per write: state column vs delta table

500 writes, each its own transaction, after a `CHECKPOINT`, `full_page_writes=on`, measured with `pg_current_wal_insert_lsn()` before and after. Each write raises one replica's entry.

- **state column**: one row, `update bench.counters set s = crdt.pn_merge(s, $delta) where id = 1`.
- **delta table**: `insert into bench.deltas (counter, d) values (1, $delta)`, with a bigserial primary key and an index on `counter`. Read with `pn_merge_agg`.

| Replicas | State stored | State column: WAL per write | Delta table: WAL per write | State column: us per write | Delta table: us per write |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 480 B | **128 B** | 334 B | 168 | 26 |
| 100 | 965 B | 398 B | 349 B | 197 | 27 |
| 1,000 | 8.9 kB | 9,941 B | **349 B** | 691 | 29 |
| 10,000 | 84 kB | 92,037 B | **349 B** | 6,633 | 31 |

Run A. Run B (Postgres 18): the same state-column numbers within 0.2%; delta inserts 385 to 394 B.

"us per write" is client time through psql, one statement per round trip, fsync off: compare the shapes, not the absolute values.

**Headline.** The crossover is at about 100 replicas, or about 1 kB of state. Below it, the state column writes *less* WAL than a delta insert: the row stays inline, the update is HOT, and Postgres logs only the bytes that changed between the old and the new tuple (prefix and suffix compression of heap update records), 128 B for a 480 B state. Above about 2 kB, the state is TOASTed, and every write rewrites and logs the whole compressed value: 9.9 kB per write at 1,000 replicas, 92 kB at 10,000, which is 28 and 264 times a delta insert. The delta table's WAL does not depend on the number of replicas.

The read side of the delta table: `pn_value(pn_merge_agg(d))` over 500 one-entry delta rows took 17.9 ms (run A) and 14.8 ms (run B), about 30 us per row. A counter kept as deltas needs compaction (merge the rows into a snapshot row, delete them) to keep reads bounded. That is not built yet.

## Not measured yet

- The `crdt.pn` domain vs plain `jsonb` columns for storage (identical by construction: a domain stores its base type).
- `lz4` TOAST compression vs the default `pglz` for large states, and `fillfactor` for HOT updates.
- Concurrent writers on one row (lock waits), and OrioleDB.

## Raw output, run A (Postgres 16.4)

```
 replicas | state_bytes | pn_merge full | pn_merge delta | concat-only, no domain full | concat-only, no domain delta | plpgsql full | plpgsql delta | full join full | full join delta | naive full | naive delta | jsonb_set loop full | jsonb_set loop delta | pn_value | pn_is_valid | pn_increment
----------+-------------+---------------+----------------+-----------------------------+------------------------------+--------------+---------------+----------------+-----------------+------------+-------------+---------------------+----------------------+----------+-------------+--------------
       10 |         496 |          19.7 |           11.0 |                        15.3 |                          8.3 |         14.8 |           8.0 |           22.1 |            19.3 |       14.4 |         8.2 |                14.7 |                  4.3 |      5.9 |         3.8 |          1.7
      100 |        1270 |         127.8 |           23.2 |                       108.1 |                         28.5 |        112.2 |          27.5 |          100.1 |            67.5 |      304.4 |        28.9 |               405.7 |                 12.7 |     25.6 |        40.1 |          9.7
     1000 |       12129 |        1318.1 |          122.8 |                      1173.8 |                        233.9 |       1166.0 |         231.2 |          828.7 |           533.6 |    19503.6 |       247.0 |             31469.9 |                 77.6 |    209.8 |       392.1 |         72.9
    10000 |      120222 |       14449.0 |         1201.3 |                     13134.1 |                       2057.6 |      12799.7 |        2062.4 |         8372.3 |          5030.5 |            |      2179.1 |                     |                705.3 |   2169.8 |      3960.3 |        706.8
```

## Raw output, run B (Postgres 18.6, Docker)

```
 replicas | state_bytes | pn_merge full | pn_merge delta | concat-only, no domain full | concat-only, no domain delta | plpgsql full | plpgsql delta | full join full | full join delta | naive full | naive delta | jsonb_set loop full | jsonb_set loop delta | pn_value | pn_is_valid | pn_increment
----------+-------------+---------------+----------------+-----------------------------+------------------------------+--------------+---------------+----------------+-----------------+------------+-------------+---------------------+----------------------+----------+-------------+--------------
       10 |         496 |          17.7 |           10.3 |                        14.7 |                          8.1 |         14.4 |           7.8 |           19.3 |            16.8 |       13.5 |         7.7 |                13.8 |                  4.3 |      5.7 |         3.6 |          1.8
      100 |        1270 |         109.2 |           21.1 |                       101.0 |                         23.5 |        100.1 |          22.7 |           90.5 |            63.2 |      261.9 |        24.5 |               371.7 |                 11.7 |     22.6 |        36.0 |          8.6
     1000 |       12129 |        1217.1 |          136.8 |                      1144.7 |                        193.1 |       1145.6 |         185.9 |          944.4 |           616.4 |    18576.5 |       184.0 |             28885.2 |                 75.3 |    183.0 |       350.0 |         70.8
    10000 |      120222 |       12820.6 |         1582.3 |                     12605.5 |                       2108.9 |      12119.3 |        1953.1 |         9008.1 |          5784.8 |            |      2275.2 |                     |                971.8 |   1695.4 |      4191.6 |        640.8

               shape                | replicas | WAL bytes per write | us per write (client)
------------------------------------+----------+---------------------+-----------------------
 state column (update ... pn_merge) |       10 |                 128 |                    96
 state column (update ... pn_merge) |      100 |                 398 |                   131
 state column (update ... pn_merge) |     1000 |                9958 |                   593
 state column (update ... pn_merge) |    10000 |               92071 |                  7225
 delta table (insert)               |       10 |                 385 |                    42
 delta table (insert)               |      100 |                 392 |                    43
 delta table (insert)               |     1000 |                 392 |                    46
 delta table (insert)               |    10000 |                 394 |                    42
```
