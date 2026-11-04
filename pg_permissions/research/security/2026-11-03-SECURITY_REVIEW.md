# Security review — 2026-11-03

Reviewed the extension and JavaScript client at `d061c62`, including the earlier security work in `873cd09`. The fixes and regressions from this review are on `codex/permissions-security-review`. The [build journal](../journal.md) session 12 summarizes it.

## Findings and fixes

### High: default privileges exposed admin functions and permission data

A database owner can configure default grants globally or for one schema. Installation revoked `PUBLIC` access but left grants to named roles intact. With default function execution and table access granted to `authenticated`, that role could call `cedar_put_policy`, install a permit-all policy, and read `_cedar_secret`. Global sequence grants also survived a fresh install.

New objects now discard grants to every non-owner role before the script exposes the intended client functions. The upgrade applies this to new Cedar objects and shared helpers while preserving explicit grants on existing RBAC and OpenFGA functions. The installer's defaults for unrelated objects are unchanged. Direct-install examples now use one transaction, so partially installed functions are not exposed between statements.

Regression: [`07_security_default_privileges.sql`](../../test/spec/d/07_security_default_privileges.sql) exercises global and schema-local grants, fresh installs, upgrades, private sequences and the cache secret, intended public functions, and preservation of an existing backend grant. Five assertions failed before the fix. PostgreSQL documents the underlying behavior in [ALTER DEFAULT PRIVILEGES](https://www.postgresql.org/docs/current/sql-alterdefaultprivileges.html).

### High: a concurrent template link could retain a revoked permit

One transaction could replace a permit template with a forbid while another copied the old template into a new link. Both committed successfully, leaving the new template forbidding access while its link still permitted it. A replacement that changed slots could similarly miss an in-flight link.

Linking now performs a no-op update on the template before copying it. Replacement takes its write lock before validating slots or reading links. At `READ COMMITTED`, the operations serialize on that template and the replacement sees previously committed links. At stronger isolation levels, the row write makes a stale snapshot fail with `40001`. A shared lock alone still allowed the stale permit under repeatable-read isolation. PostgreSQL's foreign-key key-share lock also does not block a non-key update; see [row-level locks](https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-ROWS).

Regressions: [`security.test.ts`](../../js/test/integration/security.test.ts) uses two database connections and observes actual lock waits. It tests both operation orders at all three isolation levels, retries after serialization failures, and incompatible slot changes. Restoring the original functions made the three initial read-committed tests fail. Two more tests reproduced the stale allow at stronger isolation levels with a lock-only fix. Links to the same template now serialize with one another as well as with replacements.

### Medium: malformed resource attributes could pass Cedar's fast path

`{"owner":{"__entity":{"type":"Admin"}}}` has no entity id. The fast validator treated its SQL `NULL` validation result as success, allowing `resource.owner is Admin` to pass. Separately, an unconditional permit returned before validating resource attributes at all.

The fast validator now requires a definite `true`, and attribute validation happens before an unconditional allow. Explicitly empty ids remain valid, as Cedar requires. This protects validation of supplied attributes; it does not make caller-supplied attributes trustworthy.

Regressions: [`58_cedar_security_inputs.sql`](../../test/spec/d/58_cedar_security_inputs.sql) tests malformed entity references, null values, fractions, out-of-range integers, wrong top-level shapes, valid attributes and forbids. A direct PostgREST test reproduces the missing-id case without the JavaScript client. The failing SQL cases and HTTP case were verified against the original implementation.

### Medium: concurrent hierarchy writes could commit a cycle

This was already documented as a limitation. Separate writes of `A in B` and `B in A` could each validate against a snapshot that omitted the other write, then both commit. Authorization walks terminated, but the stored graph violated the promised acyclic hierarchy and expanded membership in both directions.

Entity batches containing parent links now update one private coordination row before modifying the graph. At `READ COMMITTED`, the later writer validates the committed graph. At `REPEATABLE READ` or `SERIALIZABLE`, a conflicting older snapshot fails with `40001`. Batches with no parent links avoid this guard. This deliberately changes the earlier design's preference for no shared write lock.

Three integration regressions cover the isolation levels. Applications should keep hierarchy-write transactions short and [retry the whole transaction](https://www.postgresql.org/docs/current/mvcc-serialization-failure-handling.html) on serialization failures. The tradeoff is contention between concurrent parent-link writes, including writes to unrelated hierarchies.

## JavaScript hardening

- Subject transports capture the id, type and role at creation. Mutating a reused request object cannot change an outstanding or later check's identity.
- Subject transports refuse admin function calls before sending SQL, even when the underlying connection has admin rights. This is an API safeguard; database grants remain the security boundary.
- RBAC checks accept only the boolean `true` as an allow, matching the OpenFGA and Cedar clients. Unexpected responses such as the string `"false"` cannot become truthy authorization decisions.
- Integration-test cleanup preserves the Cedar signing secret. Previously it truncated the secret table, so later tests exercised the uncached fallback rather than the normal authenticated cache.

Unit regressions fail against the previous client implementation. The existing transport tests still cover parameterized SQL, identifier allow-lists, connection queues, transaction-local identity, rollback failures and disposal of unusable connections.

## Scope and remaining boundaries

The review covered installation and upgrade privileges, owner-executed functions and search paths, SQL injection surfaces, identity resolution, RBAC scoping and inheritance, OpenFGA conditional grants and subtraction, Cedar parsing and evaluation, cache authentication and invalidation, concurrent mutations, and the SQL/PostgREST client boundary. Existing security tests and upstream conformance suites supplement the new cases.

The following remain application responsibilities or documented limitations:

- A database role that can run arbitrary SQL can set its own subject and JWT settings. Identity must come from a trusted backend or a gateway that verifies the token. The extension is not an authentication system.
- A browser can supply arbitrary `resource_attrs` to a check. A backend must use trusted attributes and enforce its own decision; RLS policies must derive attributes from trusted row data.
- Cedar's admin API follows Cedar's policy-error semantics, including skipping an erroring forbid. Inspect diagnostics when enforcing its result. Current-subject functions fail closed on relevant forbid errors.
- A check and a later operation are separate unless the application joins them with appropriate transaction and locking behavior. Repeatable-read transactions can intentionally retain an older authorization snapshot.
- Concurrent creation can still give a static policy and a template the same id. This is documented in the compatibility guide. Allocate distinct ids across those APIs; this review did not merge their storage namespaces.
- Request-only Cedar overlays can contain cycles, as documented. Those overlays are accepted only by the privileged admin API.
- Logical backups of pg_tle installs still require an explicit permission-data backup strategy. No extension tables are registered for `pg_extension_config_dump`.

This was a source review with exploit reproduction and regression testing, not a formal proof, cryptographic audit, or independent penetration test. It does not certify an application's authentication gateway or deployment configuration.

## Validation

The review adds 22 SQL assertions, 11 JavaScript unit cases and 13 integration cases. The cache-replay assertions cover defense against a future regression; the privilege, malformed-input, concurrency and client cases were also checked against implementations that exhibited the bugs.

| Check | Result |
| --- | --- |
| Full SQL suite on PostgreSQL 16.4, including the Cedar and OpenFGA oracles (`./test/run.sh -j 4`) | 266 files, 170,009 assertions passed |
| Upgrade matrix on PostgreSQL 16.15, 17.11 and 18.6 (`./docker/run-matrix.sh test -- --upgrade-from 0.0.1 --no-cedar-oracle`) | 76 files, 4,598 assertions passed on each version; includes fresh/upgrade catalog comparisons and pg_tle installation checks |
| JavaScript unit suite | 8 files, 205 tests passed |
| JavaScript integration suite, PostgreSQL 17 and PostgREST 16.5 | 6 files, 88 tests passed |
| `npm run check` | Type checks, client build, package exports, docs build, internal links and content checks passed |
| `git diff --check` | Passed |

All database tests ran on disposable local clusters or dedicated test containers. No application database was changed. The write benchmark failed its budget check, as detailed below.

## Performance tradeoff

The hierarchy guard serializes parent-link writes across the store. On local PostgreSQL 16.4, with 10,000 documents, four clients and five seconds per run, the existing `write_nest_team` workload measured:

| Revision | p50 | p95 | Transactions/second |
| --- | --- | --- | --- |
| Before this review (`d061c62`) | 0.67 ms | 4.08 ms | 2,998 |
| With the fixes | 0.66 ms | 5.37 ms | 3,022 |

Both runs exceeded the existing 1 ms p95 budget, so the benchmark check failed before and after the changes. These are short local runs, not a production capacity estimate. This workload already contends on one entity; applications writing unrelated hierarchies concurrently may see a larger cost from the new shared guard. Measure that workload before rollout and keep mutation transactions short. A separate row-check smoke run measured 44.94 ms p95 against its 179 ms budget; it ran alongside other tests and is not a controlled before/after comparison. Authorization-result checksums matched the other models in all runs.

## Applying the changes

The changes update the development 0.1.0 install script, its 0.0.1 upgrade path, and the JavaScript source. They have not been deployed or published. Existing 0.1.0 databases do not change when these files change: prepare a versioned patch migration before rolling this out to those databases. Do not rerun the fresh-install script against an existing installation. Audit existing grants explicitly; an upgrade cannot distinguish an intentional old grant from one inherited during an earlier install.
