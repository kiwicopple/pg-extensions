# OrioleDB as a fix for CRDT write amplification

Researched 2026-11-04. Question: can OrioleDB reduce write amplification for `UPDATE t SET s = crdt.X_merge(s, $1)` on jsonb state columns (architecture.md section 4, sql-integration.md B3), and should pg_crdt depend on it?

Short answer: it removes dead tuples, VACUUM work and full-page writes, but it still writes and WAL-logs the whole new jsonb value on every merge. It is public beta, needs a patched Postgres (self-hosted) or a Supabase project created as OrioleDB, and has no PITR on Supabase. Recommendation is (b): storage-agnostic, document OrioleDB as an optional accelerator, and keep the delta-table design as the real fix.

Items marked **(unverified)** are from memory, from a single secondary source, or inferred.

## 1. Architecture relevant to this workload

| Topic | What OrioleDB does | Source |
|---|---|---|
| Table layout | Index-organised: the table is a B+-tree on the primary key (hidden `ctid` PK if none). Secondary indexes store their columns plus the PK, so they point at the PK, not a TID. | [architecture overview](https://github.com/orioledb/orioledb/blob/main/doc/architecture/overview.mdx) |
| MVCC | Undo log. The newest row version lives on the data page. Older versions live in undo chains. Update undo records hold tuple header and body. Page-level undo plus page merging reclaim space, so there is no dedicated VACUUM in most cases. 64-bit xids on OrioleDB tables (no wraparound). | [overview](https://github.com/orioledb/orioledb/blob/main/doc/architecture/overview.mdx), [README](https://github.com/orioledb/orioledb) |
| "No bloat" caveat | The docs say "in the majority of cases" and the intro adds an asterisk to "no VACUUM". It is not a guarantee. | [intro](https://github.com/orioledb/orioledb/blob/main/doc/intro.mdx) |
| Checkpoints | Copy-on-write, fuzzy. A consistent tree image exists on disk at every moment. | [overview](https://github.com/orioledb/orioledb/blob/main/doc/architecture/overview.mdx) |
| WAL | Row-level: logs primary-key tree and TOAST tree changes only. Secondary indexes are rebuilt from those at recovery. Orioledb's docs never mention full-page images. Because checkpoints are copy-on-write, torn pages are not a recovery problem, so FPW has no role **(inferred, not stated in docs)**. OrioleDB markets "very compact row-level WAL". | [recovery](https://github.com/orioledb/orioledb/blob/main/doc/architecture/recovery.mdx), [Neon comparison](https://www.orioledb.com/blog/orioledb-neon-differences) |
| Large values | Own TOAST: a separate B-tree keyed by (primary key, attribute number, chunk number/offset). A value is split into chunks, each a leaf tuple. Compression is zstd via `compress` options, not pglz/lz4. | [recovery](https://github.com/orioledb/orioledb/blob/main/doc/architecture/recovery.mdx), [toast.c](https://github.com/orioledb/orioledb/blob/main/src/tuple/toast.c), [getting started](https://github.com/orioledb/orioledb/blob/main/doc/usage/getting-started.mdx) |

### Does updating one big jsonb still write the whole value?

Yes. I read the source on `main` (2026-11-04).

- `tts_orioledb_update_toast_values` in [src/tuple/slot.c](https://github.com/orioledb/orioledb/blob/main/src/tuple/slot.c) compares old and new TOAST pointers with `o_toast_equal`. If the value is unchanged it skips it ("nothing to do"). This matches heap's "unchanged out-of-line value costs nothing" behaviour.
- If the value changed, it calls `generic_toast_update_optional_wal` in [src/tuple/toast.c](https://github.com/orioledb/orioledb/blob/main/src/tuple/toast.c). That loop walks every chunk of the new value, does an `o_btree_modify` insert-or-update on each, and writes one WAL insert/update record per chunk (`add_modify_wal_record`). It then deletes trailing chunks if the new value is shorter. There is no diff against the old chunks and no skipping of identical chunks.
- Old chunk versions go to undo, so undo volume also scales with value size.
- I found no partial or delta update of large values in the source or docs. jsonb has no in-place subdocument update in Postgres either (`jsonb_set` returns a whole new value), so a storage engine would need an API Postgres does not offer. **Chunk-level diffing is not implemented; absence is based on reading `toast.c` and `slot.c`, not on an explicit statement.**

So for a state column above the TOAST threshold, per-merge WAL is still roughly O(compressed state size) plus per-chunk record overhead. Small states (inline in the row) are logged as one row record, again whole.

## 2. What it reduces and what it does not

| Cost for our pattern | Heap today | OrioleDB | Verdict |
|---|---|---|---|
| Dead tuples / table bloat | Every merge leaves a dead heap tuple and dead TOAST chunks until VACUUM. | Old version moves to undo and is reclaimed when no snapshot needs it. Page merging. | Reduced. Vendor claims near-zero bloat in most cases. |
| VACUUM / autovacuum load | Scales with churn. | Mostly none. `VACUUM FULL` and `CLUSTER` unsupported. | Reduced. |
| Full-page writes after checkpoint | First touch of each page after a checkpoint writes an 8 kB image. Many small merges on many pages amplify this. | None documented (see above). | Likely reduced **(inferred)**. |
| HOT-update limits | Needs space on the same page and no indexed column change. Large rows and expression indexes on the state defeat it. | Not applicable. Updates are in place on the leaf page. Secondary index entries only change if indexed columns change **(inferred from design; the docs do not spell out the rule)**. | Concept disappears. |
| WAL bytes per merge | Whole new tuple, or whole new TOAST value, plus FPWs and index records. | Whole new value, chunked, plus per-chunk record headers. No FPW. | Partly reduced (FPW and index overhead), not O(delta). |
| Undo / old-version storage | Dead tuples in the heap. | Whole old value copied to undo until reclaimed. | Moved, not removed. |
| Whole-value re-serialisation in `crdt.X_merge` | O(state) CPU and allocation in PL/pgSQL, detoast, merge, re-toast. | Same. This is above the storage layer. | Not affected. |
| Logical replication / Realtime payload | New row image (with unchanged TOAST values omitted if unchanged, and full when changed). Capped at 1 MB for Realtime `postgres_changes`. | Same: logical decoding emits the new tuple. | Not affected. |
| Read amplification | Heap fetch plus detoast. | B-tree lookup plus TOAST-tree range read. | Neutral. |

The last two rows matter most. The merge function and the change stream are what grow with state size in the sql-integration.md analysis, and neither is a storage-engine concern.

## 3. Compatibility

### Patched Postgres and upstream status

- OrioleDB requires Postgres built from the [orioledb/postgres](https://github.com/orioledb/postgres) fork at the exact commit pinned in [.pgtags](https://github.com/orioledb/orioledb/blob/main/.pgtags). The build refuses other commits.
- The intro says all patches "have been submitted to the PostgreSQL community and are under review", and the goal is a pure extension ([intro](https://github.com/orioledb/orioledb/blob/main/doc/intro.mdx)). Ten patches (mostly tuplesort and rbtree refactors) are marked accepted for PG 16. Eight remaining TAM-interface patches are marked "under review" for PG 18 and link to [commitfest 48/4958](https://commitfest.postgresql.org/48/4958/), which is closed as a duplicate (Rejected status, 2024-07-23) of [48/4866](https://commitfest.postgresql.org/48/4866/). The table has not been refreshed since 2024.
- The March 2025 [OrioleDB blog](https://www.orioledb.com/blog) still says several core patches are needed, and a 2025 comparison post says "under review but not yet merged" ([Neon comparison](https://www.orioledb.com/blog/orioledb-neon-differences)).
- I could not confirm that the remaining patches have been merged into Postgres 18 or 19. **Treat OrioleDB as still requiring a patched core as of 2026-11-04 (unverified for PG 19 development).**
- The patched build keeps binary compatibility with the data directory. Heap tables keep working, and you can switch back after converting OrioleDB tables to heap ([intro](https://github.com/orioledb/orioledb/blob/main/doc/intro.mdx)).

### Versions

- `.pgtags` pins PG 16, 17 and 18. The README install text still mentions only 16 and 17, and OrioleDB's pgbench page references beta18 on PG 18.6, so PG 18 is supported.
- Latest release is v1.10.1 (2026-11-02). Releases moved from `betaN` to `vMAJOR.MINOR.PATCH` with that line. Previous: beta19 (2026-10-01), beta18 (2026-09-23). Only the newest release branch gets fixes ([release notes](https://github.com/orioledb/orioledb/releases)).
- Status in the README remains "public beta ... not recommended for production usage" ([README](https://github.com/orioledb/orioledb)).

### Feature support

| Feature | Status | Notes |
|---|---|---|
| Logical decoding / logical replication | Supported with caveats | Decoding works for OrioleDB tables. Fixes in v1.10.1: crash on TOASTed tables with short chunks, rewriting ALTERs resending all rows, mixed heap+oriole transactions lost after a crash. In-progress transaction streaming is disabled cluster-wide. See [limitation 14](https://github.com/orioledb/orioledb/blob/main/doc/usage/getting-started.mdx) and [v1.10.1 notes](https://github.com/orioledb/orioledb/releases). |
| Supabase Realtime | Not confirmed | An open issue reports Realtime broadcasts-from-triggers stopped showing in logical decoding between beta16 and beta18 images ([orioledb#1251](https://github.com/orioledb/orioledb/issues/1251)). Supabase's image only loads output plugins `pgoutput, test_decoding, wal2json` ([changelog](https://supabase.com/changelog/orioledb-public-beta)). No official statement that Realtime supports OrioleDB tables. |
| btree, expression, partial, unique indexes | Native | Native btree is the fast path. I did not find a doc line on expression indexes specifically **(unverified, but they are ordinary btree on computed keys; TOAST values in secondary indexes are handled per the recovery doc)**. |
| GIN / GiST / HNSW etc. | Experimental via "bridge index" | Adds a hidden bridge index to the table. Fixes in v1.10.1 for wrong rows and false unique violations with bridged indexes show it is still maturing. Supabase calls it experimental. |
| jsonb columns, TOAST | Supported | Own TOAST tree, described above. |
| pg_tle | **Unverified** | No OrioleDB issue or doc found. pg_tle stores extension SQL in a catalog table and is orthogonal to table storage, so I expect it to work. Needs a direct test. |
| DOMAIN types | **Unverified** | Old issue [#52](https://github.com/orioledb/orioledb/issues/52) (closed) was about a domain NOT NULL error. No known blocker. Needs a direct test. |
| PL/pgSQL, SQL functions | Unaffected | Run above the table AM. |
| Prepared transactions | Not supported | [limitation 3](https://github.com/orioledb/orioledb/blob/main/doc/usage/getting-started.mdx). |
| SERIALIZABLE | Not real SSI. Default takes a coarse table lock per touched relation. Our architecture.md already says to expect 40001 retries at RR/SERIALIZABLE, and this changes that behaviour. Set `orioledb.serializable` explicitly. |
| Row-level concurrency | Similar to heap for UPDATE, with differences when the primary key changes or a row is deleted and reinserted with the same key ([doc](https://github.com/orioledb/orioledb/blob/main/doc/architecture/row-level-concurrency.mdx)). The single-statement `UPDATE ... SET s = merge(s, $1)` under READ COMMITTED is the ordinary case, but re-test the lock-wait and re-evaluate behaviour (architecture.md section 4) on OrioleDB. |
| Other | Not supported: `CLUSTER`, `VACUUM FULL`, sample scans, bitmap scan except int4/int8/ctid PK, parallel scans other than seq and index. Collations limited to C/POSIX/ICU/builtin. `pg_rewind` copies whole tables. |

## 4. Availability

| Where | Status |
|---|---|
| Supabase hosted | **Public beta**, announced 2026-10-28 ([blog](https://supabase.com/blog/orioledb-public-beta)). Not GA, no SLA, "not ready for production yet". New projects only: Dashboard, Advanced Configuration, Postgres Type "Postgres with OrioleDB". Cannot be added to or removed from an existing project. Beta19 on Postgres 17.11 per the blog. The 2026-10-01 changelog says beta18, so the shipped version may have moved ([changelog](https://supabase.com/changelog/orioledb-public-beta)). Plan wording conflicts: the blog says "every Supabase plan", the changelog says Pro, Team and Enterprise "not only Free". Read replicas, resizing, upgrades and scheduled backups work. **No PITR and no restore of a backup to a new project.** |
| Supabase local dev | `supabase init --use-orioledb`, CLI v2.119.0 or later. |
| Supabase self-hosted | Not part of the self-hosted stack yet ([blog](https://supabase.com/blog/orioledb-public-beta)). |
| Supabase extension gaps | Image lacks `plv8`, `plls`, `plcoffee`, `timescaledb-apache`. A project is OrioleDB or Multigres, not both. |
| Other managed providers | I found none offering it. **Unverified**, a search turned up no provider announcements. |
| Self-hosted | Docker images `orioledb/orioledb:latest-pg17` (amd64, arm64) or build the patched Postgres plus the extension. `CREATE EXTENSION orioledb; CREATE TABLE ... USING orioledb`. Needs `shared_preload_libraries = 'orioledb'` and a restart. |

## 5. Benchmarks

All vendor-published. None cover large jsonb values or TOAST rewrite cost, which is our case.

| Source | Workload | Result |
|---|---|---|
| [Supabase beta post](https://supabase.com/blog/orioledb-public-beta) (2026-10) | DBArena, TPC-C-derived | Data 4x memory: about 1.8x tpm at 8XL (113,850 tpm), about 46% more per dollar at Small. In memory: about +13% (Large), +29% (8XL), heap ahead at Small. The post names frequently updated or deleted tables as the best fit. |
| [OrioleDB bloat post](https://www.orioledb.com/blog/no-more-vacuum-in-postgresql) (2023) | pgbench-style upsert, sparse index updates | 5x TPS, 2.3x less CPU, 22x less IOPS per transaction, no bloat. Old build, 100 connections on c5d.18xlarge. |
| [orioledb#1279](https://github.com/orioledb/orioledb/pull/1279) | read-write procedure | WAL per transaction 487 to 375 bytes after a fix. Also shows a roughly one-quarter throughput regression between beta4 and beta18 on that test, so numbers move between builds. |
| [OrioleDB pgbench recipe](https://www.orioledb.com/pgbench-benchmark) | pgbench, scale 1000 | Reproducible harness, CPU-bound. |

Rows in these tests are small (pgbench or TPC-C). They show OrioleDB wins on many small hot-row updates. They say nothing about rewriting a 100 kB to 1 MB value per update. We would need to run that ourselves.

## 6. Verdict

### Options

| Option | Assessment |
|---|---|
| (a) Depend on OrioleDB | No. Beta, patched core, no PITR on Supabase, Realtime unconfirmed, new-project-only, not self-hostable on stock Supabase. It would exclude nearly every current deployment. It also does not fix the dominant costs (merge CPU, payload size). |
| (b) Storage-agnostic, OrioleDB documented as optional accelerator | Yes. pg_crdt is PL/pgSQL on SQL tables, so it already works on any table AM. State a tested-on matrix once tests pass. |
| (c) Ignore it | Not quite. It is cheap to mention and to test, and it helps the whole-state design at moderate sizes. |

### Compared with the in-design fix (insert-only delta table + `merge_agg` + compaction)

OrioleDB attacks storage-layer symptoms (dead tuples, vacuum, FPW). The delta-table design removes the cause (rewriting O(state) per change) at every layer: WAL is O(delta), Realtime and logical replication carry the delta, merge CPU is O(delta) at write time, and there is nothing to vacuum except compaction deletes. OrioleDB cannot do any of that for a whole-value column.

Does OrioleDB change which design is better? Not the ranking. It narrows the gap for the whole-state column:

- Whole-state column on OrioleDB: bloat, vacuum and FPW costs mostly go away, but per-merge WAL, undo, CPU, and change-stream payload stay O(state). It is better than heap for small and medium states (inline, under about 2 kB, or a few kB) and counters. It does not lift the size ceiling.
- Delta table on heap: the insert-only pattern is already heap's best case (no dead tuples apart from compaction deletes, no HOT concerns, sequential inserts). It gains little from OrioleDB. Compaction (delete folded deltas, upsert snapshot) is the only update-heavy part, and it is a periodic batch.
- Delta table on OrioleDB: works, and the delete-heavy compaction step produces less bloat. Index-organised storage means the delta table's primary key choice matters. A monotonically increasing key (position cursor, matching the `doclog_` design) keeps inserts on the hot right-edge leaf, which OrioleDB has an [ordered-insertion optimisation](https://www.orioledb.com/blog) for (benchmark post, 2025-08). A random UUID key would lose that.
- Collaborative text (row per item or run, insert-mostly): heap is fine. Tombstoning items is a small update. OrioleDB helps only at the margins (secondary-index maintenance on the render path, **unverified**).

### Recommendation

1. Keep the delta-table plus `merge_agg` plus compaction as the scalable path. Do not delay it for OrioleDB.
2. Ship the whole-state column as the simple path. Document the heap size ceiling and say OrioleDB moves it somewhat for bloat/vacuum reasons only.
3. Do not add OrioleDB-specific code. Add an optional CI matrix job on the `orioledb/orioledb:latest-pg17` image running the existing property and concurrency tests, including pg_tle install, DOMAIN types, jsonb expression indexes, and the READ COMMITTED lock-wait test. This closes the three unverified items above.
4. Add a benchmark to the plan (architecture.md Benchmarks to run): the same whole-state merge loop at 1 kB, 10 kB, 100 kB, 1 MB states on heap vs OrioleDB, measuring `pg_current_wal_lsn` delta per merge, table size after N merges, and OrioleDB undo size. That is the missing evidence. Expect WAL per merge to track state size on both engines **(prediction, not measured)**.
5. Revisit when OrioleDB reaches GA on Supabase, PITR lands for OrioleDB projects, Realtime on OrioleDB is documented, and the core patches are upstream.

## Sources

- OrioleDB repo: <https://github.com/orioledb/orioledb> (README, [doc/architecture](https://github.com/orioledb/orioledb/tree/main/doc/architecture), [doc/usage](https://github.com/orioledb/orioledb/tree/main/doc/usage), [intro.mdx](https://github.com/orioledb/orioledb/blob/main/doc/intro.mdx), `src/tuple/toast.c`, `src/tuple/slot.c`, `.pgtags`, [releases](https://github.com/orioledb/orioledb/releases))
- Patched Postgres: <https://github.com/orioledb/postgres>
- Supabase: [public beta blog](https://supabase.com/blog/orioledb-public-beta), [changelog](https://supabase.com/changelog/orioledb-public-beta), [docs](https://supabase.com/docs/guides/database/orioledb)
- OrioleDB blog: <https://www.orioledb.com/blog>, [Neon comparison](https://www.orioledb.com/blog/orioledb-neon-differences), [bloat post](https://www.orioledb.com/blog/no-more-vacuum-in-postgresql)
- Issues and PRs: [#1251 Realtime](https://github.com/orioledb/orioledb/issues/1251), [#1279 WAL per txn](https://github.com/orioledb/orioledb/pull/1279), [#1379 logical decoding rewrites](https://github.com/orioledb/orioledb/pull/1379)
- Commitfest: <https://commitfest.postgresql.org/48/4958/>
