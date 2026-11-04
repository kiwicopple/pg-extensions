# pg_crdt: implementation runtime research

Date of research: 2026-11-04. Scope was narrowed mid-research by the user: `pg_crdt` will be written in PL/pgSQL (plus plain SQL) only.

Conventions: "verified" means I read the primary source (pg_tle docs or source on GitHub, PostgreSQL docs, a provider's own docs). "Unverified" means inferred, taken from a secondary source, or not checked against a running server. Nothing here was benchmarked; performance sections describe mechanisms and a measurement plan, not measured numbers.

## 0. Languages ruled out

PLV8, PL/Rust and WASM-based languages were ruled out by user decision, so they were not researched in depth. One fact worth recording: Supabase has deprecated plv8 on Postgres 17 and says it must be dropped before upgrading a project from 15 to 17 ([Supabase plv8 docs](https://supabase.com/docs/guides/database/extensions/plv8), [Supabase PG17 changelog](https://supabase.com/changelog/35851-forthcoming-postgres-17-release-notes)). That alone would make plv8 a poor base for a Supabase-compatible extension. Native/pgrx (as in the original [supabase/pg_crdt](https://github.com/supabase/pg_crdt), built on Automerge's Rust library) needs a native binary and so is outside the pg_tle goal; it stays useful only as a performance comparator.

## 1. pg_tle with PL/pgSQL

### 1.1 Current state

- Latest release is v1.5.3, published 2026-10-08 ([releases API](https://api.github.com/repos/aws/pg_tle/releases)). The README lists support for PostgreSQL 12 through 19 beta ([repo](https://github.com/aws/pg_tle)).
- pg_tle must be in `shared_preload_libraries`, so it needs a restart. RDS/Aurora do this via parameter group ([install docs](https://github.com/aws/pg_tle/blob/main/docs/01_install.md)).
- Documented example languages are SQL, PL/pgSQL, PL/v8 and PL/Perl ([docs dir](https://github.com/aws/pg_tle/tree/main/docs)). pg_tle does not enforce a language whitelist for ordinary functions. Its security docs say it "can work with untrusted languages" but recommend trusted ones ([security](https://github.com/aws/pg_tle/blob/main/docs/20_security.md)). Extension scripts are ordinary SQL run through `CREATE EXTENSION`, so whatever the installing role may do, it can do.
- All pg_tle extensions report `superuser = false` and `trusted = false` ([managing extensions](https://github.com/aws/pg_tle/blob/main/docs/03_managing_extensions.md)).
- Transaction control statements are not allowed inside an extension script (error text in [tleextension.c](https://github.com/aws/pg_tle/blob/main/src/tleextension.c)).
- Without a `schema` argument, objects go into the current schema. `install_extension` accepts `requires` and `schema` (since 1.5.0).

### 1.2 Custom base types: can the I/O functions be PL/pgSQL?

Yes. The enforcement code in [datatype.c](https://github.com/aws/pg_tle/blob/main/src/datatype.c) (`check_user_defined_func`) only rejects functions in C or `internal`. Everything else, including `plpgsql` and `sql`, is accepted. The rules, from the [datatype docs](https://github.com/aws/pg_tle/blob/main/docs/09_datatypes.md) and that source:

| Item | Rule |
|---|---|
| Procedure | `pgtle.create_shell_type(nsp, name)` then `pgtle.create_base_type(nsp, name, infunc, outfunc, internallength, alignment, storage)`. Role `pgtle_admin`. |
| Input function | Exactly one argument of type `text`, returns `bytea`, must be `STRICT` and (per docs) `IMMUTABLE`, must live in the same schema as the type. |
| Output function | Exactly one argument of type `bytea`, returns `text`, same rules. |
| Internal representation | Always `bytea`. The type is stored as a bytea-shaped varlena. An explicit cast to `bytea` is created automatically (binary coercible). There is no implicit cast. |
| Length | `-1` for variable length. For fixed lengths the cap is `PG_INT16_MAX - VARHDRSZ` ([constants.h](https://github.com/aws/pg_tle/blob/main/include/constants.h)). Irrelevant for CRDTs, which are variable length. |
| Storage | `plain`, `external`, `extended`, `main` for variable-length types. Use `extended` (TOAST with compression) or `external`. |
| Alignment | `char`, `int2`, `int4`, `double`. |
| Binary send/recv | Not provided. `TypeCreate` is called with `InvalidOid` for the send/receive procedures ([datatype.c](https://github.com/aws/pg_tle/blob/main/src/datatype.c)). Consequence, unverified at runtime: binary-format result columns and `COPY ... BINARY` for the custom type probably fail or fall back to text. Text I/O would then carry a hex or base64 encoding. |
| typmod, analyze | None (`InvalidOid` for typmodin/typmodout/analyze). No `foo(10)` style modifiers. |
| Array type | Created automatically. |
| Replace after creation | `CREATE OR REPLACE` or `ALTER` of an I/O function or operator function used by the type is blocked: "ALTER or REPLACE of pg_tle used datatype ... function ... is not allowed" ([tleextension.c](https://github.com/aws/pg_tle/blob/main/src/tleextension.c)). A bug in the I/O format cannot be patched through an update path; the type would have to be dropped and rebuilt. This is a strong argument for keeping the on-disk format trivial and versioned inside the payload. |

Per-value cost: every text-to-type and type-to-text conversion goes through a PL/pgSQL (or SQL) function call wrapped by a pg_tle C shim. Cheap for `convert_to`/`convert_from`, but it is a function call per row on input and output.

### 1.3 Operators, casts, aggregates, operator classes in a TLE

All of these are plain SQL statements in the extension script. pg_tle's ProcessUtility hook only intercepts extension, function-in-`pgtle`-schema and a few related statements, so ordinary DDL runs under normal PostgreSQL privilege rules. What I could and could not confirm:

| Feature | Possible in a TLE? | Notes |
|---|---|---|
| Functions taking/returning the custom type, written in PL/pgSQL | Yes | The docs' `test_citext` example does exactly this ([docs](https://github.com/aws/pg_tle/blob/main/docs/09_datatypes.md)). There is a `create_operator_func` helper (bytea-argument functions re-exposed on the type) aimed at PL/Rust, not needed for PL/pgSQL. |
| `CREATE OPERATOR` (for example `||` as merge) | Yes | Documented in the same example. Operators can name `COMMUTATOR`, `NEGATOR`, `HASHES`, `MERGES`. Note: operator functions of a pg_tle type are protected from `REPLACE`. |
| `CREATE CAST` | Yes in principle | PostgreSQL requires owning the source or target type; the extension installer owns the new type, so this should work. Unverified on a managed provider. Casts between the custom type and `jsonb` need a function (not binary coercible), so write them in SQL or PL/pgSQL. |
| `CREATE AGGREGATE` | Yes in principle | State types must be ordinary types. Aggregates with `internal` state (the fast path) need C, so use a `jsonb`/`bytea` state or the custom type. `COMBINEFUNC` plus `PARALLEL SAFE` is possible for parallel aggregation. Unverified on a managed provider. |
| Btree/hash operator class for equality/ordering | Documented, privilege-sensitive | The pg_tle docs say `CREATE OPERATOR CLASS` needs superuser, except on Amazon RDS where it is not required ([docs](https://github.com/aws/pg_tle/blob/main/docs/09_datatypes.md)). Whether Supabase's `postgres` role can run it is unverified. Without a default btree/hash opclass, the type cannot be used in `GROUP BY`, `DISTINCT`, `ORDER BY`, unique indexes or primary keys. With the docs' own example, `'SELECT'` and `'select'` were separate values until the opclass existed. |
| GIN opclass | Effectively no | Needs support functions written in C in practice; a PL/pgSQL GIN opclass is not a documented or sensible route. Index a derived `jsonb`/`bytea` expression instead. |
| TOAST/compression | Yes | `storage => 'extended'`. |

### 1.4 Upgrade path mechanics

Verified in [managing extensions](https://github.com/aws/pg_tle/blob/main/docs/03_managing_extensions.md) and [architecture](https://github.com/aws/pg_tle/blob/main/docs/30_architecture.md):

- pg_tle stores the extension as functions in schema `pgtle`: a control function and one "version function" per install version or update path. `CREATE EXTENSION` runs them.
- `pgtle.install_extension(name, version, description, ext, requires, schema)` registers the first version and its default version.
- `pgtle.install_extension_version_sql(name, version, ext)` registers a full install script for a new version (for fresh installs).
- `pgtle.install_update_path(name, fromvers, tovers, ext)` registers the upgrade script, enabling `ALTER EXTENSION ... UPDATE`.
- `pgtle.set_default_version(name, version)` moves the default.
- `pgtle.uninstall_extension(...)` and `uninstall_update_path(...)` remove artifacts. `DROP EXTENSION` is still needed to remove the live objects.
- There is no filesystem, so migration scripts live inside the database. Version bumps are cheap, but see 1.2: type I/O and operator functions cannot be redefined by an update path.

### 1.5 Availability of pg_tle and PL/pgSQL by provider

PL/pgSQL is built into core PostgreSQL and enabled by default; I did not look up each provider's page for it separately (unverified per provider, but I know of no managed Postgres that removes it).

| Provider | pg_tle | PL/pgSQL | Source |
|---|---|---|---|
| Supabase | Yes | Yes | [pg_tle docs page exists](https://supabase.com/docs/guides/database/extensions/pg_tle); [launch post](https://supabase.com/blog/pg-tle). I could not extract the page text; availability claim rests on the page existing plus the launch post. |
| AWS RDS for PostgreSQL | Yes (14.5 and later) | Yes | [pg_tle README](https://github.com/aws/pg_tle/blob/main/docs/01_install.md); [RDS extension versions](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-extensions.html) mentions pg_tle |
| AWS Aurora PostgreSQL | Yes (14.6 and later) | Yes | same README |
| Neon | No (not in official list) | Yes | [Neon extensions list](https://neon.com/docs/extensions/pg-extensions): no pg_tle entry |
| Google Cloud SQL | No (not in official list) | Yes | [Cloud SQL extensions](https://docs.cloud.google.com/sql/docs/postgres/extensions): no pg_tle entry |
| AlloyDB | No (not in official list) | Yes | [AlloyDB extensions](https://docs.cloud.google.com/alloydb/docs/reference/extensions): no pg_tle entry |
| Azure Database for PostgreSQL Flexible | No (not in official list) | Yes | [Azure extensions](https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions-versions): no pg_tle entry |
| Self-hosted | Yes (add to `shared_preload_libraries`, restart) | Yes | [pg_tle install](https://github.com/aws/pg_tle/blob/main/docs/01_install.md) |

"Not in official list" is a text search of those pages for "pg_tle" and "trusted language"; the pages did render other extensions (for example pgcrypto), so the absence is meaningful, but providers add extensions without notice. Re-check before publishing.

Practical consequence: pg_tle is only a distribution path on Supabase and AWS. On every other provider the same PL/pgSQL and SQL can be run as a plain SQL migration (or a schema script), since it contains no native code. The extension should therefore ship as a single SQL file that can be loaded either through `pgtle.install_extension` or directly.

### 1.6 database.dev

The Supabase launch post presents dbdev as the package registry for TLEs ([dbdev blog](https://supabase.com/blog/dbdev), [repo](https://github.com/supabase/dbdev)). One secondary summary says the in-database `supabase-dbdev` client is deprecated in favour of the CLI and registry ([DeepWiki](https://deepwiki.com/supabase/dbdev)). Unverified: exact package layout dbdev expects today. Check the dbdev repo's publishing docs before packaging.

## 2. PL/pgSQL performance for jsonb-heavy CRDTs

No benchmark was run. The following is mechanism-level reasoning from PostgreSQL's documented behaviour and planner source, with a measurement plan at the end.

### 2.1 Cost model

- `jsonb` is stored in a decomposed binary format that needs no reparsing, but any key or element lookup is a binary search within the object and any modification copies the whole value ([PG docs: JSON types](https://www.postgresql.org/docs/current/datatype-json.html)). Docs: "any update acquires a row-level lock on the whole row", and large documents increase contention.
- Each function call receives the argument detoasted (decompressed and de-chunked in full). A merge of two 1 MB states reads and decompresses 2 MB per call regardless of how little changed. This is general PostgreSQL behaviour for varlena arguments, not something I verified in jsonb source here.
- Result values are built from scratch: `jsonb_object_agg`, `jsonb_build_object`, `||` and `jsonb_set` all produce a new datum. `jsonb_each` produces a row per key whose value is a fresh jsonb copy. Merging two maps by `jsonb_each` then re-aggregating is therefore roughly O(n log n) in key count (keys are sorted when the object is built) with a large constant.
- Row updates write a new tuple. Changing a TOASTed value rewrites the changed TOAST datum entirely (PostgreSQL has no partial TOAST updates), so WAL volume per update scales with total document size, not delta size ([TOAST docs](https://www.postgresql.org/docs/current/storage-toast.html)). This matches what the original Supabase extension reported: "frequently updated CRDTs produce a lot of WAL and dead tuples" ([supabase/pg_crdt README](https://github.com/supabase/pg_crdt)). Their fix, expanded datums, needs C and is not available to us. Mitigation inside the TLE constraint: keep state small, keep per-replica data in separate rows where possible, and tune `fillfactor` for HOT updates.
- PL/pgSQL has no expanded-object support for jsonb, so variables holding jsonb are plain flat datums and assignments can copy.

### 2.2 Patterns

| Pattern | Notes |
|---|---|
| Per-key max merge as one SQL statement: `FULL JOIN` of `jsonb_each(a)` and `jsonb_each(b)`, `GREATEST` per key, `jsonb_object_agg` | One pass, one sort, one result build. Best general form for PN-counter and G-counter merge. |
| Loop in PL/pgSQL over `jsonb_each` with `jsonb_set` per key | O(n) copies of an O(n) object, so O(n^2). Avoid. |
| Custom aggregate with jsonb state to merge many rows | Each transition copies the whole state, so O(rows x state). A single query `SELECT jsonb_object_agg(k, max(v)) FROM table, jsonb_each(state) GROUP BY k` over many rows is cheaper because the engine does the grouping. Offer both, document which to use. |
| Normalised tables (one row per replica or per element) instead of one jsonb | Merge becomes `INSERT ... ON CONFLICT DO UPDATE SET n = GREATEST(...)`. No detoast/reserialise, small WAL per update, indexable, and RLS-friendly. Trades the "single value you can ship around" ergonomics for scale. |
| Scalar reads (`pn_value`) | `SELECT sum(...) FROM jsonb_each_text(...)` forces a scan of the whole map. Cache a total if reads dominate. |

### 2.3 PL/pgSQL versus SQL-language functions (inlining)

From the planner source (`inline_function` in [clauses.c](https://github.com/postgres/postgres/blob/master/src/backend/optimizer/util/clauses.c)), a scalar SQL-language function is inlined only if:

- language is SQL, not set-returning, no `SET` clause (any `proconfig` blocks it, so `SET search_path` kills inlining), not SECURITY DEFINER;
- the body is a single `SELECT` with no `FROM`, no aggregates, no window functions, no sub-selects (`hasSubLinks`);
- if declared `IMMUTABLE`, the body contains no volatile functions; if `STRICT`, the body must be strict in all arguments and use them all;
- arguments used more than once must not be expensive or volatile.

Set-returning SQL functions in `FROM` can also be inlined (`inline_function_in_from`, same file). PL/pgSQL functions are never inlined; each call pays interpreter entry, argument conversion and plan-cache lookups.

What this means for CRDTs: merge bodies use aggregates and `FROM jsonb_each`, so they cannot be inlined as scalar functions. Writing them in `LANGUAGE sql` rather than PL/pgSQL still avoids interpreter overhead and lets the executor plan the whole statement as one query, and is the natural form for set-based merges. Use PL/pgSQL only where control flow or validation raising errors is needed. Trivial wrappers such as `crdt.pn_empty()` (a constant `'{}'::jsonb`) and operator functions like `a || b` on jsonb can be inlined if written as `LANGUAGE sql IMMUTABLE` with no `SET` clause. Because a `SET search_path` clause blocks inlining, schema-qualify every reference inside function bodies (`pg_catalog.jsonb_each`, `crdt.pn_merge`) instead.

How much faster `sql` is than `plpgsql` for these shapes is unmeasured. My expectation is a small constant-factor gain dwarfed by jsonb detoast/rebuild cost for large states; this needs benchmarking before it drives design.

### 2.4 Volatility and parallel safety labels

Per [CREATE FUNCTION docs](https://www.postgresql.org/docs/current/sql-createfunction.html): default is `VOLATILE` and `PARALLEL UNSAFE`; `IMMUTABLE` allows constant folding and index/generated-column use; `PARALLEL SAFE` allows use in parallel workers.

| Function kind | Label |
|---|---|
| Constructors, mergers, value readers that depend only on arguments (`pn_empty`, `pn_increment`, `pn_merge`, `pn_value`, `set_values`, `register_value`) | `IMMUTABLE PARALLEL SAFE`, plus `STRICT` or explicit null handling |
| Anything reading `now()`, `clock_timestamp()` or random/uuid (LWW `register_set` that stamps its own time, OR-set tag generation) | Not `IMMUTABLE`. `now()` is `STABLE`; `clock_timestamp()`, `gen_random_uuid()` are `VOLATILE`. Better: take the clock/tag as an explicit argument and keep the core function immutable, with a thin volatile wrapper that supplies it. |
| Functions reading other tables | `STABLE` at best |

Mislabelling a function `IMMUTABLE` when it is not is the main correctness hazard (stale values in generated columns and index expressions). Merge must be deterministic, which also makes the immutable label honest: avoid dependence on `jsonb` key iteration order, locale or collation (use `COLLATE "C"` for tie-breaks between replica ids).

### 2.5 Representation comparison: base type vs domain vs jsonb vs bytea

| Option | For | Against |
|---|---|---|
| Plain `jsonb` | Works everywhere, no pg_tle needed for the type, native GIN, `->`/`@>`, PostgREST and Realtime return readable JSON, existing equality/hash/btree opclasses, binary I/O works. Matches the brief's own `state jsonb` example. | No type safety: nothing stops passing an OR-set state to `pn_merge`. Function overloads cannot distinguish CRDT families. Human-readable but larger than binary. |
| `DOMAIN ... AS jsonb CHECK (...)` (one per CRDT family) | No superuser needed, ordinary `CREATE DOMAIN`. Keeps jsonb storage, indexing, JSON I/O, binary I/O and opclasses (inherited from base type). Functions can be declared on the domain for self-documentation and a `CHECK` rejects wrongly shaped values. | Domain arguments are generally treated as the base type for function and operator resolution, so overloads on domains and domain-specific operators are fragile and need testing (unverified). The `CHECK` runs on every assignment and adds cost. Functions returning plain jsonb lose the domain unless cast back. Alter-domain constraint changes during upgrades are possible but validate all rows. |
| `bytea` | Compact, any format (versioned binary), cheap to ship to clients, no JSON overhead. | Opaque to SQL: every operation needs manual decode in PL/pgSQL (`get_byte`, `substring`) which is slow and clumsy. No GIN, no readable output, no type distinction. |
| pg_tle base type (bytea-backed) | Distinct type with its own operators (`||` as merge), casts, array type, can hide format. | Only works where pg_tle exists (Supabase, RDS, Aurora, self-hosted). No binary send/recv, no typmod. Opclass needs superuser outside RDS (so `GROUP BY`/`DISTINCT`/unique can fail). I/O and operator functions cannot be replaced by update paths. Internally still bytea, so PL/pgSQL must still decode bytes manually. It gives a nicer surface, not a faster engine. |

No option gives faster merging in PL/pgSQL: the work is in the jsonb or byte manipulation. The type decision is about API and distribution, not performance.

## 3. Collaborative text and documents in PL/pgSQL

Findings from the references named in the brief, checked only at the level needed here.

### 3.1 What is not realistic

Running Yjs, Automerge, Loro or Diamond Types logic inside PL/pgSQL is not realistic. Their update formats are compact binary encodings with their own integration and delete-set rules; re-implementing the integration algorithm (YATA, RGA variants, Eg-walker replay) in PL/pgSQL would be a from-scratch text CRDT, which the brief explicitly says not to do for the MVP. Producing `document_text()` from an opaque Yjs or Automerge blob inside the database is therefore unavailable with PL/pgSQL only.

### 3.2 Option A: store and relay opaque updates (realistic for the MVP)

Postgres stores the binary updates produced by clients or a server running the real library, and merges them by set union.

- Table sketch: `(doc_id, update_id, update bytea, created_at)`, append-only; dedupe on a content hash or the client's operation id. Merge is `UNION` of rows, so it is commutative, associative and idempotent by construction. Order of arrival does not matter because the real CRDT library on the client is order-insensitive.
- The database never interprets the bytes. Realtime/PostgREST/RLS work on row-level metadata. This is the pattern seen in the wild: Yjs docs persisted as bytea updates with periodic compaction ([Yjs forum](https://discuss.yjs.dev/t/how-to-store-ydoc-in-a-database/2495), [yhub](https://github.com/yjs/yhub), [PowerSync post](https://powersync.com/blog/postgres-and-yjs-crdt-collaborative-text-editing-using-powersync)).
- Compaction (squashing many updates into one snapshot) needs the library, so it must happen in a client or edge function that writes back a snapshot and deletes the exact rows it merged, in one transaction. Unbounded row growth is the main operational cost without it; another write-up runs compaction in serializable transactions and deletes only the rows it fetched ([k_yrs_go](https://github.com/kapv89/k_yrs_go)).
- Needs explicit concurrency design: the compaction transaction must not delete updates it did not read (delete by id set, not by "all rows for the doc").

This is honest "storage and sync coordination", not a SQL-native text CRDT. The SQL API (`document_apply`, `document_merge`) can exist as thin append/union functions; `document_text` cannot.

### 3.3 Option B: a simple sequence CRDT in tables (feasible, as a labelled experiment)

Fugue is the most plausible candidate for implementing from the paper: Weidner and Kleppmann present Fugue and FugueMax, with FugueMax satisfying "maximal non-interleaving" ([arXiv 2305.00583](https://arxiv.org/abs/2305.00583), reference code [mweidner037/fugue](https://github.com/mweidner037/fugue)). I did not read the algorithm in full; the following is a design sketch, flagged unverified until checked against the paper:

- One row per character (or later, per run): `(doc_id, replica, counter, parent_replica, parent_counter, side, value, deleted)`. The element id is globally unique.
- Merge is a row union keyed by id, with `deleted` combined by logical OR. Idempotent, commutative and associative per element; convergence follows from the tree position being fixed at insert time.
- Materialising text is a tree in-order traversal ordered by a deterministic sibling comparator (replica id, then counter). In SQL this is a recursive CTE with a path array, roughly O(n log n) per read.
- Costs: tens of bytes of heap and index per character, deletes are tombstones, heavy WAL for typing patterns, recursive CTE per read. Fine for small documents (notes, comments, titles); likely poor beyond tens of thousands of characters without run-length compression, which adds the complexity this MVP wants to avoid. Measure before promising a size limit.

### 3.4 Eg-walker

The paper and Diamond Types use an append-only event graph (operations with parent versions), which suits relational storage (rows with parent ids; merge is union). The hard part is the replay algorithm that rebuilds state over concurrent regions; I did not assess a PL/pgSQL port and it should not be attempted before the MVP. Recommended deliverable: a proposal document only, as in the brief.

## Implications for pg_crdt

**(a) Simple state-based CRDTs (PN-counter, OR-set, LWW register).** Use PL/pgSQL and plain SQL-language functions only. Represent state as `jsonb` in the first release, with a versioned envelope (`{"v":1,"t":"pn",...}`) so serialisation changes are explicit and a CHECK or domain can validate shape. Write merges as single set-based SQL statements (full join over `jsonb_each`, `GREATEST`, `jsonb_object_agg`), put them in `LANGUAGE sql` where the body is expressible, label pure functions `IMMUTABLE PARALLEL SAFE`, and pass clocks and tags as explicit arguments so the core stays immutable. Provide a set-based merge-all query for many rows instead of relying on a jsonb-state aggregate. Document that normalised tables are the scale path (small WAL, `ON CONFLICT` merges) and that jsonb per-row updates amplify WAL with document size.

**Custom-type route.** A pg_tle base type is possible with PL/pgSQL I/O functions, but gains only syntax (a distinct type and a `||` merge operator) and costs: availability limited to pg_tle providers, no binary I/O, no typmod, opclass privilege uncertainty outside RDS, and I/O and operator functions frozen against replacement. Recommendation: do not use a base type for the MVP. Use plain `jsonb`, optionally one `DOMAIN` per family for type safety if a quick test shows overload resolution behaves; add a `||` operator on those domains only after that test passes. Revisit a bytea-backed base type only if a compact binary format is justified by benchmarks, and keep the payload self-describing with a version byte because the type's functions cannot be patched later.

**Distribution.** Ship one SQL file usable both as `pgtle.install_extension` content and as a plain migration. pg_tle is available on Supabase and RDS/Aurora but not (per official lists) on Neon, Cloud SQL, AlloyDB or Azure Flexible, where the plain-SQL route still works. Use `install_update_path` for upgrades and avoid changes to any function a pg_tle type would pin.

**(b) Collaborative text and documents.** For the MVP, Option A: store and relay opaque updates from Yjs or Automerge, with SQL for append, union and metadata, and compaction done by a client or edge function inside a carefully scoped transaction. No `document_text()` in SQL. As phase 2 research, prototype Option B (Fugue-style rows plus a recursive CTE) for small documents only, benchmark it, and keep Eg-walker as a written proposal.

## Open questions

1. Can `CREATE OPERATOR CLASS` run on Supabase's `postgres` role? Matters only if a base type is revisited.
2. Do overload resolution and `||` on a domain over jsonb behave well enough for a typed API? Needs a small test on PG 15, 16, 17.
3. Real numbers: jsonb merge cost versus state size (1k, 10k, 100k replicas/elements), `sql` versus `plpgsql`, and WAL per update. The brief already asks for these benchmarks.
4. Binary-protocol behaviour of a pg_tle type without send/recv (for example through PostgREST, drivers using binary results). Unverified.
5. Exact dbdev packaging expectations today.
6. Fugue sizing: how many characters before the row-per-character design becomes unusable.
