# pg_permissions: build journal

Raw material for a blog post about how this extension was designed and built. It's a log of what we tried, in order, including the wrong turns, so the story can be told honestly later. Append to it as the project continues.

Built by Copple working with Claude Code (Claude Opus 5.5) in this repo. "We" below means the two of us; "the user" means Copple's direction, and "Claude" means the AI's work and suggestions.

---

## Session 1: 2026-10-28, from blank folder to tested prototypes

### 0. Starting point

- The repo is a handful of small Trusted Language Extensions (TLEs) for database.dev: `is_even`, `is_odd`, `countries`, `pg_idkit`. All pure SQL/PL/pgSQL, no compilation.
- Copple hadn't been in the repo for a long time. The first question was whether an uncommitted file should be pushed: `pg_idkit/pg_idkit--0.0.5.sql`, dated April 2024. Claude diffed it against 0.0.4. It was identical apart from a trailing newline, and the control file still said 0.0.4. It was an abandoned version bump, so it was deleted.
- There were four open RFC pull requests from January 2026, each proposing a **separate** authorization extension:
  - #7 `pg_zanzibar` (relationship tuples, Google Zanzibar style)
  - #8 `pg_abac` (attribute rules)
  - #9 `pg_cel` (CEL expressions)
  - #10 `pg_cedar` (Cedar permit/forbid policies)

### 1. The brief

Copple's goal, roughly in their words: one extension that can handle many permission models (FGA, Zanzibar, or something else), with a permission schema linked to an identity. On Supabase the identity would be the `auth` schema, but the extension should stay generic. Plan outline: review the existing ideas, pick two or three simple models as a proof of concept, design the core schema and identity link, avoid tight coupling to Supabase, and document everything.

### 2. Reviewing the four RFCs

Reading the four RFCs side by side turned up patterns none of them mentioned:

- **Each reinvented identity.** There were four different answers to "who is the current user?". The Zanzibar one hard-coded Supabase's `auth.uid()`, so it would fail on plain Postgres.
- **Each reinvented "subject is related to object".** Zanzibar tuples, Cedar's `entity_parents` and ABAC role assignments are all the same shape.
- **They differed mainly in how a decision is computed:** graph walk, attribute rules, expressions, or ordered permit/forbid.
- **They shared one RLS performance trap.** A per-row check function in a policy runs once per row. The Zanzibar RFC had the right instinct (return a list of IDs once and compare against it), crediting Gary Austin's custom-properties repo.

### 3. First plan: one design, then a challenge

Claude's first plan proposed a single design: a shared Zanzibar-style tuple table as the core, with other models layered on top.

Copple pushed back: **"How do you know that's the best design?"** They asked for two subagents with alternative designs, and for the plan to be split into generic requirements plus three implementation docs.

How that was done:

- `PLAN.md` became requirements only: goals, RFC review, models to support, identity and RLS requirements, a **shared reference scenario** every design must work through (org `acme`, Alice admin, Bob editing `readme`, team `eng` viewing it), and evaluation criteria.
- The original design moved to `designs/a-tuple-core.md`.
- Two subagents ran in parallel. Each was **deliberately not shown Design A**, so they couldn't anchor on it, and each got a different direction:
  - **B, policy-first:** Cedar-shaped policies decide everything; roles and groups are plain data. Told to tackle RLS performance head on.
  - **C, compiled model:** move work from read time to write time; declare a model once, then maintain lookup tables.
- B took about 5 minutes, C about 6.

While they ran, Claude brought Design A up to the same standard as the others: a full reference scenario and an honest weaknesses section. The weaknesses section turned out to matter. Writing the scenario out showed that "who can view readme?" would miss Alice (an org admin), because org-level access lived in the RLS policy rather than in the tuples.

### 4. Testing the designs, not just reading them

None of the three docs had been run. Claude started a throwaway Postgres 16 cluster in a temp directory and ran what each doc contained:

- **A:** the recursive CTE gave the right answer for all four users in the scenario. It also terminated on a deliberate cycle (team `eng` as a member of itself). The trick: Postgres allows only one recursive reference, so both kinds of step (follow a tuple, follow an implied relation) go in a single `cross join lateral` with a `union all` inside.
- **B:** the schema compiled (8 tables). Its evaluator existed only in prose.
- **C:** the schema, identity function and `can()` worked. Bob can update, Dave can view through team `eng` but not edit.
- **A small factual correction:** Design C claimed `check` couldn't be used as a function name because it's reserved. Testing showed `permissions.check(...)` works when schema-qualified; only a bare `check(...)` is a syntax error. C's note was corrected, and the trap was added to A's open questions.

### 5. What comparing three designs revealed

- **B and C independently chose to precompute group membership at write time.** That pointed straight at A's main weakness, recursion on every read. It also meant B and C shared the hardest part to build: keeping derived tables correct under concurrency (both needed a global advisory lock, and C had to reject `repeatable read` for membership writes).
- **A and C had nearly the same public API.** C is roughly "A plus a typed model and a materialized membership index".
- **The real decision was relationship-first (A/C) or policy-first (B).**
- Claude proposed a benchmark spike instead of more documents.

### 6. The Oso detour

Copple asked whether any of this resembled Oso. After a quick web check:

- B is closest overall. It has the same split between facts and policies; B's `via => 'org'` is Polar's `"edit" if "admin" on "parent"`; and B's `rls_expression()` is the same idea as Oso's `list_local`, which returns a SQL filter.
- C's JSON model is essentially an Oso resource block.
- A is closer to Zanzibar/OpenFGA.

Claude then proposed a fourth design inspired by Oso's local authorization: **"bring your own data"**, where the extension reads facts from the app's existing tables through mappings instead of storing its own copy.

**Copple rejected it: it would be slower and more confusing.** That was the right call, and it set the tone for what followed: the goal is a blessed path, not maximum generality.

### 7. Reframing: a blessed path with model presets

Copple restated the goal: provide a blessed path, but let users choose between authorization models, "whether it's Zanzibar or simply RBAC".

Claude's answer was that the three designs already covered the engine question. What none of them covered was **how a user chooses a model**. All three expressed RBAC as a special case of something bigger: a relation on an `org:acme` object, or a role grant plus a policy. Someone who only wants roles would still have to learn Zanzibar or policies.

So the missing piece was a layer, **model presets**:

- `rbac`: `create_role`, `assign_role`, `has_permission`, `scopes_with_permission`. No tuples, relations or policies in sight.
- `zanzibar`: the engine's full API.
- Both write to the same core data, so an app can **graduate** from RBAC to per-object sharing without migrating anything.
- The `rbac` API is **identical in every design**, which makes the engine swappable.

A second, RBAC-only scenario went into the plan, and each design got a "blessed path" section. Then Claude implemented the preset on all three:

- **A:** for real, tested end to end, including RLS under a non-superuser role and graduation.
- **B:** on a minimal stand-in evaluator.
- **C:** on a hand-compiled catalog, since `apply_model()` existed only in prose.

All three gave the same answers.

**A prediction that turned out wrong:** Claude had predicted B would be the most awkward fit for the preset. It fitted cleanly. B's role implication is exactly "inherits", and each role becomes two generated policies.

**First real bug found:** `col = any ((select f()))`, the pattern used in Design A and in the original Zanzibar RFC, **doesn't work**. Even with double parentheses, Postgres parses it as a subquery comparison and fails with `operator does not exist: text = text[]`. It needs a cast to be treated as an array.

Another catch: Design C's name rule (`^[a-z][a-z0-9_]{0,62}$`) rejected permission names like `documents.read`. It was relaxed to allow dots, which is safe because C only stores names as data.

### 8. Building the test suite

Copple: build a nice test suite so we can set goals against it and do performance testing; test-driven development; bring everything into the repo.

Constraints found:

- pgTAP and `pg_prove` weren't installed. Postgres.app had `pgbench`.
- The repo's style is zero dependencies.

Decisions:

- **A small assertion library** (`test/lib/tap.sql`) that uses pgTAP's function names (`plan`, `ok`, `is`, `set_eq`, `throws_ok`, `lives_ok`, `finish`), so the tests could move to pgTAP later.
- **Tests are a contract, not tied to one engine.** They call only the public API from PLAN.md. Security is checked through the catalog (`has_table_privilege` on every table in the schema) rather than by naming tables. Fixture IDs are untyped UUID literals, so `text` and `uuid` implementations both work.
- **A runner that defaults to the real extension file.** That file is empty, so on day one every goal is red: proper TDD. `--impl` points it at a prototype.
- **Isolation:** a throwaway cluster that listens only on a Unix socket (no TCP port, so it can't clash with a running server), a template database with the implementation installed, and one cloned database per spec file.
- **Supabase's client roles** (`anon`, `authenticated`, `service_role`) are created, so RLS is tested the way Supabase clients hit it.
- The Zanzibar-level tests use Design A's function names and are marked **provisional**, since that API isn't settled.

Writing the contract forced several decisions the plan had left vague:

- **The JWT wins over the session setting.** Design A had it the other way round; B and C put the JWT first. JWT-first is safer, because nothing else in a session can override who a request is for.
- **Explicit-subject functions are admin-only.** If any client could call `check_for(other_user, ...)`, any user could probe anyone's access. Design A's API was split into client-facing `check`/`list_objects` (current subject only) and admin-only `check_for`/`list_objects_for`/`list_subjects`.
- **Unknown permission names return false rather than raising,** so a policy that names a dropped permission denies instead of breaking every query.

Results:

| Implementation | Result |
| --- | --- |
| Extension (empty file) | 0/9 files. 19 of 112 assertions "pass" vacuously (e.g. "Dave sees nothing"). |
| Prototype A | 9/9 files, 112/112 on the first run |
| Prototype B stand-in | 6/9: every identity, security, RBAC and RLS file passes; the three Zanzibar-level files fail because B's API differs |

**Passing on the first run was suspicious,** so the suite was tested against 8 deliberately broken copies of Prototype A (mutation testing):

| Mutant | Caught by |
| --- | --- |
| `has_permission` always true | identity, RBAC, RLS, graduation |
| Session setting beats JWT | identity |
| All functions executable by clients | security |
| Role inheritance removed | RBAC, RLS, graduation |
| Tenant scope ignored | RBAC, RLS, graduation |
| Expiry ignored | groups |
| Group expansion removed | Zanzibar reference, groups |
| `drop_role` ignores heirs | management |

All 8 were caught.

### 9. Benchmarks, and the bug that wasn't where we looked

The harness (`bench/run.sh`) seeds tenant-scoped RBAC through the preset API (any engine can load it), then per-document sharing with teams nested about 5 levels deep. It runs pgbench workloads as `authenticated` under RLS and works out p50/p95 from pgbench's per-transaction logs.

The first large run (1M documents, 10k users, 100 orgs, 500 teams) had two oddities:

1. `rbac_select_count` took 0.72 ms to count what should be about 20,000 rows per user. **Suspicion:** maybe the workload silently matched nothing. A sanity check went into the harness (it prints how many documents sample users see). Answer: 20,000 each. The speed was real, because after `vacuum analyze` Postgres counts from the `org_id` index without touching the table.
2. `share_select_page` was 7× slower than `rbac_select_page` (p50 10.0 ms vs 1.33 ms), with the same query plan and the same 2,619 rows filtered.

**First theory, wrong:** cache. The plan showed 2,381 pages read and 1,756 dirty pages written, and Postgres' default `shared_buffers` is only 128 MB. A rerun with 512 MB changed nothing (9.83 ms).

**Real cause:** the policy filter was `id = ANY (($1)::uuid[])`. The function returns `text[]` and the policy casts it to `uuid[]`. Because `$1` is a parameter (from the InitPlan) rather than a constant, Postgres re-applies the cast on every row it filters. The RBAC-only policy had the same problem, but its array held 2 org IDs instead of about 10 document IDs.

Four ways of writing the policy, measured on the 1M-row data set:

| Policy pattern | Page of 50 | Count all visible |
| --- | --- | --- |
| `any ((select f())::uuid[])` (what we had) | 3.64 ms | 2.51 ms |
| `any ((select f()::uuid[])::uuid[])` | 0.76 ms | 2.29 ms |
| `any (array(select unnest(f())::uuid))` | **0.73 ms** | **2.22 ms** |
| `in (select unnest(f())::uuid)` (hashed subquery) | 0.83 ms | **88.76 ms** |

- The third form is now the rule (PLAN.md §4), applied to every policy in the tests, seeds and docs.
- The hashed-subquery form, which Design B's doc had recommended for large ID sets, stops Postgres using the `org_id` index and made counts 40× slower. B's doc was corrected with the measurement.

After the fix, at 1M documents:

| Workload | p50 before | p50 after | p95 after |
| --- | --- | --- | --- |
| `rbac_select_page` | 1.33 ms | 0.71 ms | 0.85 ms |
| `share_select_page` | 10.01 ms | 1.90 ms | 2.31 ms |

Every workload's p95 ended up under 2.5 ms. **The biggest performance factor so far was how the RLS policy was written, not the choice of engine.** Design A's read-time recursion, the thing B and C were designed to avoid, cost under a millisecond at this scale.

Budgets (`bench/budgets.tsv`) were set at about 2–3× A's p95: tight enough to catch a 5× regression like this one, loose enough for machine noise. `bench/run.sh --check` enforces them.

### 10. Small mishaps (useful colour for the post)

- **zsh `echo` ate a command.** Test scripts were built with `echo '\c dbname'`, and zsh's `echo` treats `\c` as "stop output". The database switch never happened, and one test ran in the wrong (throwaway) database. It was caught when another script failed with "schema already exists".
- **zsh doesn't split words in `$var`.** `P="psql -h ..."; $P` tried to run a file named after the whole string. A first check of the budget logic also "failed" for this reason; it was rerun in bash, which the scripts actually use.
- **`pipefail` plus `grep` killed the runner.** A `grep` that finds nothing exits 1, which stopped the script after the first failing test file. The fix was `|| true` on the display pipelines.
- **A safety check blocked `rm -rf "$(cat file)"`.** Claude Code refuses to delete a path it can't see before running the command. The fix was to print the path first, then delete the literal path. It was also the right call once when the wrong temp directory name was typed.
- **Testing the test library itself:** an `any((select ...))` mismatch and a role that survived between runs (roles are cluster-wide) both showed up as test-script bugs, not implementation bugs. Not every red result is a real failure.

### Decisions so far, and why

| Decision | Why |
| --- | --- |
| One extension, multiple models through presets | Users get a blessed path (`rbac`) and can graduate to `zanzibar` without migrating |
| `rbac` preset API identical across engines | Keeps the engine swappable; proven by running the same tests on A and B |
| No dependency on Supabase's `auth` schema | Works on plain Postgres; on Supabase the JWT `sub` is all that's needed |
| JWT `sub` beats the session setting | Nothing else in a session can override the subject of a request |
| Explicit-subject functions admin-only | Otherwise any user could query anyone's access |
| Unknown permissions return false | A stale policy denies instead of breaking queries |
| RLS fast path `= any (array(select unnest(f())::uuid))` | Measured fastest; avoids a per-row cast and keeps index use |
| No "bring your own data" design | Slower and more confusing; rejected by Copple |
| Own TAP library with pgTAP names | Zero dependencies, easy to move to pgTAP later |
| Tests default to the real (empty) extension | TDD: start red |

### Still open (end of session 1)

- Pick the engine: build Design C's prototype and benchmark A against C, especially nesting a 1,000-member team.
- Find where A's read-time walk stops being cheap (deeper or wider group graphs).
- Decide whether forbid and attribute conditions are needed in year one; if yes, start from B.
- Parent inheritance (v0.0.2), installing through pg_tle/dbdev as a non-superuser, medium-scale budgets.

### Possible angles for the blog post

- **"How do you know that's the best design?"** Making an AI argue with itself: independent subagents that never see the first design, then a comparison table.
- **Measure, don't predict.** Several confident claims didn't survive contact with Postgres: `check` "can't" be a function name, B "would be awkward", the slowdown "was the cache", hashed subqueries "are faster for big sets".
- **The 5× bug was one cast in an RLS policy,** not the engine everyone was designing around.
- **Tests as a contract across engines:** the same 112 assertions against two different engines.
- **Mutation-testing an AI-written test suite:** it passed first time, so we broke the code on purpose to prove the tests could fail.
- **Saying no to generality:** rejecting "bring your own data" in favour of a blessed path.

### Numbers worth quoting

- 4 earlier RFCs, 3 candidate designs, 2 independent subagents.
- 9 spec files, 112 assertions; 8 of 8 mutants caught.
- 1M documents, 10k users, 100 orgs, 500 teams about 5 levels deep; RBAC seed in about 5 s, sharing seed in about 2 s.
- Sharing page p50: 10.0 ms → 1.9 ms after changing one line of policy SQL.
- Hashed-subquery trap: 2.2 ms → 88.8 ms for a count.

---

## Session 2: 2026-10-28 to 29, three full engines, measured side by side

### 0. Setup and decisions

- The session started with a check that Copple's new global CLAUDE.md had loaded. It puts the main conversation in **orchestrator mode**: an expensive model plans and reviews, and cheaper subagents explore and implement. Routing: `explorer` (Haiku) for search, `light-implementer` (Sonnet) for routine work, `heavy-implementer` (Opus) for hard work. Two of the three agent definitions were missing at first and showed up after Copple added them, which made a useful sanity check.
- Copple's answers to the up-front questions:
  - Keep the extension file empty: build prototypes only and choose later.
  - In scope: a full Prototype C, a full Prototype B, stress benchmarks, and new goals (parents, public access, forbid, conditions, pg_tle install).
  - **Per-design zanzibar-level spec files** rather than one shared API: each engine is tested in its native API, with the same scenarios and assertions.
  - Commit per milestone and never push.

### 1. M0: infrastructure (light-implementer, ~2 min)

- `test/spec/{a,b,c}/` holds the per-design spec files and `bench/designs/{a,b,c}/` the per-design sharing benchmarks. The runner infers the design from the prototype's filename (`a-tuple-core.sql` gives `a`).
- New goal scenarios G10–G14 were written into PLAN.md §10 **before** any engine work started, with exact assertion checklists, so three agents working in parallel would write comparable tests.

### 2. M1: three engines in parallel (one heavy-implementer each)

Each agent owned only its prototype, its spec directory, its bench directory and its design doc, so nothing collided. Large benchmarks were held back, because three agents running tests on one laptop make timings meaningless.

**Design A** (about 17 minutes): 13/13 files, 147/147 assertions.
- Parents are OpenFGA-style tuple-to-userset (`from_parent`). Public access is a `user:*` wildcard start node. Forbid is "but not" (`unless => '{blocked}'`) and prunes the walk. Conditions needed no engine change: `expires_at` plus RLS over the app's `status` column.
- **The SQL function re-planning trap.** The bigger recursive query, written as a `language sql` function, made every check slower: `rbac_check` p50 went from 0.32 to 0.58 ms. Postgres 16 re-plans SQL function bodies on every call. Moving it to PL/pgSQL, which caches the plan, brought it back to 0.34 ms.
- **A mutant survived first time.** Swapping `union` for `union all`, which removes cycle protection, still passed. A non-grantee's walk never reaches the cycle, so the checklist's cycle assertion proved nothing. The fix was cycle traversals under a 5 s `statement_timeout` before the assertion. In the end all 7 mutants were caught, and the fix was passed on to the B and C agents mid-flight.
- **Honest cost:** a single-branch parents policy is O(visible documents): 7 µs per document, 18 ms vs 2.2 ms for the two-branch policy at small scale. That's extrapolated to about 150 ms at 20k visible documents, but **not yet measured**. Parent tuples cost about 450 bytes per row, about 430 MB at 1M documents (extrapolated).

**Design B** (about 24 minutes): 13/13 files, 147/147 assertions. The stand-in is gone.
- What was built:
  - **Facts:** an `ancestors` closure maintained by triggers under one global advisory lock. Cycles and depth over 10 are rejected on write (`23514`), and `repeatable read` is refused for closure writes.
  - **Policies:** permit/forbid. `via` requires a role on a parent. Conditions are a jsonb AST, split on write into a per-query half and a per-row half; the per-row half compiles to SQL for RLS.
- **The stand-in's RBAC slowness was the implementation, not the design.** `principal = me OR principal IN (ancestors)` stopped Postgres using the primary key on `role_grants`, so it scanned about 334 grants per role. Going straight from subject to primary key took single-client `update_one` from 2.5 to 0.56 ms and `rbac_check` from 0.41 to 0.20 ms. **This is the third OR/cast-shaped RLS trap**, after the per-row cast and the hashed subquery.
- **Another RLS trap:** `(select allows_all()) OR id = any(...)` blocks the BitmapOr over indexes and forces a seq scan. B now emits that arm only when an allow-all policy exists.
- **Cross-engine agreement check:** fresh A and B databases gave an identical checksum over all 1,000 users' RLS results. Random fuzzing found 0 disagreements in 2,400 cases between `can_for` and the RLS projections.
- **Parents are cheap in B:** the single-branch `folder_id` policy projects onto about 20 folder IDs instead of thousands of document IDs (0.43 ms ad hoc vs A's 7.3 ms). This is the biggest structural difference found so far.
- **Honest weaknesses:**
  - The table's RLS is generated once (`apply_rls`) and must be regenerated when policies change shape.
  - **`can()` outside RLS needs the row passed in, and forbids that depend on missing attributes fail open.**
  - The closure lock is global.
  - Each generated policy runs 5–7 function calls per query.

**Design C** (about 30 minutes): 14/14 files, 178/178 assertions, including a C-only `32_memberships` file for drift, `verify()`/`rebuild()` and isolation rules.
- What was built:
  - `apply_model()` compiles a JSON model (relations, implies, permissions, `parent`, `but_not`) into a flat `satisfies` table. It keeps stable IDs and version rows, and the dry run executes in a rolled-back subtransaction, so its plan is exact.
  - Statement-level triggers with transition tables keep `memberships` up to date under a global advisory lock.
  - Parent cycles are rejected on write.
- **A real concurrency test:** two sessions raced on nesting writes. With the lock, `verify()` was clean afterwards. With the lock removed from a copy, `verify()` caught the missing membership. That's the drift risk the design doc predicted, now demonstrated.
- **Where the brief was wrong:** the brief said C's preset would take `uuid`. It can't: the shared tests and the RBAC bench seed pass `text`, and text→uuid is an explicit-only cast. The preset keeps PLAN §6's text signatures with uuid underneath, plus `uuid` overloads for policies.
- **RLS fast path, refined:** for a function that already returns `uuid[]`, `id = any ((select f())::uuid[])` is fastest, because the cast is a no-op. That's about 0.15 ms faster than the `array(select unnest(...))` rule. **The §4 rule is about avoiding a real per-row cast, not a magic incantation.**
- **The write-side price, measured:** nesting a 1,000-member team takes about 14 ms with 1 client. With 4 clients it's about 61 ms each, and throughput stays flat at 65–70 tps, because the global lock serializes them.
- Code size: C is about 1,860 lines, A about 620.

### 3. M2: fixes, install test and a fair benchmark harness (three agents in parallel)

**G14 install test** (light-implementer): all three prototypes install as a non-superuser database owner, with no C or `internal` functions. Function counts: A 27, B 55, C 63. pg_tle isn't in Postgres.app 16.4, so the pg_tle branch of the spec is written but **has never run**. It's an honest skip, and someone with pg_tle has to run it.

**Correctness fixes** (heavy-implementer). Each new test was confirmed red before its fix.
- **B failed open.** Called outside RLS without the row's folder or attribute, `can()` skipped forbids that depended on them and granted access. Now it raises `22023` and names the missing key. The agent rejected "treat the missing input as deny", because it turns a caller bug into silent denials and makes `who_can` return nobody.
- **A worse B bug, found while fixing that one:** every jsonb key was read as a parent. `{"user": author}` made the author's teams and orgs into anchors for the row, so `can_for` said yes where RLS said no. It's fixed for principal-type keys. The real fix is declared parent types, which would change B's calling convention.
- **Still open in B:** the list function (`ids_for`) can include a document that a forbid blocks through its folder column or a condition. RLS stays exact. This is documented, not fixed. **Policy-first's flexibility makes "the same answer everywhere" hard to guarantee.**
- **C's `who_can` left out public grants.** A public grant now comes back as one null row, mirroring A's `('user','*')` row, rather than enumerating every user.
- Suites after the fixes: A 14/14 files (156 assertions), B 15/15 (172), C 16/16 (195).

**Benchmark harness** (heavy-implementer, about 40 minutes):
- **Equivalent data by construction.** One integer data shape (`bench/seed_shape.sql`) feeds every engine's seed, so the seeds can't drift apart.
- **Cross-engine checksums.** For each read policy, the md5 of the sorted visible IDs for sample users must match across A, B and C. In all three shapes (default, deep with 10-level nesting, wide with 50 teams per user) **all three engines returned identical results**.
- **Fairness fixes the agent made on its own:**
  - Write workloads now roll back, so committed rows don't pollute later checksums.
  - `VACUUM FULL` replaces `VACUUM`, and empty tables are skipped.
  - **The vacuum detail matters:** analyzing B's closure tables while empty, then bulk-loading, made its wide sharing seed take 225 s instead of 3 s. The planner believed the tables were empty and picked quadratic plans. C showed the same effect (77 s vs 26 s). That's a real risk for apps that bulk-load in one transaction.
- **B's `can()` went from 1.3 to 17–22 ms after re-analyze.** The `_parent_keys()` function scan was estimated at 1,000 rows (actual 1), so the planner hash-joined a seq scan over 92k ancestor rows. **The fourth planner trap of the project.**
- First small-scale numbers (p50 ms, noisy machine):

  | Workload | A | B | C |
  | --- | --- | --- | --- |
  | `parents_select_page` | 20.9 | 0.79 | 1.18 |
  | `write_nest_team` | 0.14 | 129 | 55 |
  | `nest_check` (read after nesting) | 0.32 | 1.53 | 0.25 |

  This is the read/write trade-off the designs predicted, now in numbers: **A writes in 0.14 ms and pays at read time; B and C pay 400–900× more on the nesting write.**
- **Fairness question raised:** B's parents policy projects onto `folder_id` (about 20 folder IDs) while A and C enumerated every visible document. Is the comparison about engines or about policy shape? (Answer in the next step: benchmark both shapes on every engine.)

**Two follow-up engine fixes** (light-implementer):
- **B's planner trap:** `rows 1` on `_parent_keys` changed the plan from a seq scan plus hash join over 92k closure rows to an index-only scan. `can()` p50 after nesting (wide shape) went from **17.1 to 0.79 ms**: one line, 21×.
- C now officially supports naming the preset `tenant` type as a parent, so folder access can reach preset roles, the graduation path. Redefining `tenant` or `app` is still refused. The benchmark had been relying on a loophole.

**Separating engine cost from policy shape.** Every engine was benchmarked with both parents policies:
- **projection:** `id = any(docs) or folder_id = any(folders)`, with no per-document parent links;
- **single branch:** one call, with one parent link per document stored in the engine.

All four workloads gave identical checksums across A, B and C in every shape. Small scale, p50 ms (default shape):

| Workload | A | B | C |
| --- | --- | --- | --- |
| projection page | 2.1 | 0.79 | 0.48 |
| single-branch page | 20.4 | 6.0 | 1.20 |

- **The policy shape mattered more than the engine:** projection is about 10× faster for A, 7× for B and 2.5× for C. A's 20 ms "parents problem" was mostly the policy shape. With the same policy, A is 2.1 ms vs C's 0.48.
- In the wide shape (50 teams per user) the sharing arm dominates: A 58 ms, B 36 ms, C 3.3 ms. **This is where materialization (C) pays off, and the first place an engine choice clearly wins on reads.**
- B's single-branch form costs 1 parent row plus 2 closure rows per document (3M rows at 1M documents).

### 4. The serial benchmark runs

Run strictly one at a time on an idle laptop, 10 s per workload: large default, medium default, medium deep and medium wide, for each engine. About 33 minutes of runs, plus one restart.

- **Another benchmark bug, caught by a budget.** The harness's `VACUUM FULL` left the visibility map empty, so index-only scans read every heap page. A's `rbac_select_count` came out at 6.2 ms instead of about 0.8 ms and went over its budget. The fix was a plain `VACUUM` after the `FULL`. Everything was rerun from scratch. **The budgets from session 1 earned their keep: a regression guard caught a harness bug, not an engine bug.**
- **Cross-engine checksums matched in every run,** for all four read policies and all 8 sample users. Three engines with different storage and evaluation strategies gave the same answers for 1M documents.
- **RBAC (the blessed path) is a tie.** All three engines were within about 0.2 ms of each other at every scale. Single-row writes were 0.14–0.20 ms everywhere. **For apps that stay on the `rbac` preset, the engine choice is invisible**, as predicted in session 1, and now measured.
- Large default (1M documents), p50 ms:

  | Workload | A | B | C |
  | --- | --- | --- | --- |
  | `share_select_page` | 2.02 | 1.21 | 0.95 |
  | `parents_proj_select_page` | 3.20 | 1.44 | 1.01 |
  | `parents_select_page` (single branch) | **509** | 197 | 9.6 |
  | `write_nest_team` (4 clients) | **0.15** | 285 | 333 |
  | `nest_check` | 0.70 | 2.60 | 0.26 |

- **Single-branch parents scale linearly with visible documents in A and B** (A: 20.8 → 99.6 → 509 ms from small to medium to large). Session 1's extrapolation of about 150 ms was **3× too optimistic**. The projection policy barely grows: C went from 0.48 to 1.01 ms. **Projection should be the blessed RLS pattern for hierarchies, whatever the engine.**
- **Wide shape (50 teams per user, medium):** `share_select_page` A 221 ms, B 70 ms, C 10.7 ms. This is the case materialization was designed for, and it wins by 20×.
- **The write price of materialization:** nesting a 1,000-member team with 4 clients took 285 ms in B and 333 ms in C, against 0.15 ms in A, a factor of about 2,000. C's design doc quoted 14 ms, but that was single-client; the global lock serializes the clients.
- **Storage for per-document parent links at 1M documents:** A +378 MB (44 s seed), B +736 MB (167 s, 3 rows per document), C +160 MB (16 s). The projection policy needs none of this.
- **Budgets for everything,** with the rule "3× the fastest engine's p95". `--check` at small scale: A fails 4 (parents), B fails 4 (single-branch parents, nesting write, nest check), C fails 1 (nesting write). Nothing was loosened to fit an engine.

### 5. M3: the decision guide

- `DECISION.md` (light-implementer) is a scorecard against PLAN §7 in which **every cell cites a number, a test or a design-doc section**. It has "Choose A/B/C if…" sections, three hybrids marked untested, open questions for Copple, and a list of what hasn't been measured. **It deliberately picks no winner.** Copple wants to make that call.
- One agent refreshed PLAN §8, the README and prototypes/README. A second fixed stale numbers in the design docs, including A's own "about 150 ms extrapolated", now replaced by the measured 509 ms.

### How the orchestration worked (meta, for the post)

- **Main conversation (Opus):** planning, briefs, reviewing reports, commits and this journal. It never read a prototype or ran a test. The only files it read were the plan, goals and journal (to brief), and the finished DECISION.md (to review).
- **13 subagent runs:**
  - 6 heavy-implementer: A, B and C in parallel, the correctness fixes, and the benchmark harness, which was resumed twice for parents variants and serial runs;
  - 5 light-implementer: infrastructure, install test, planner/tenant fixes, decision guide, doc fixes.
  - The explorer agent wasn't needed, because the journal and plan already held the context.
- **What made the parallelism safe:** strict file ownership per agent; "don't commit, the orchestrator commits"; and "no large benchmarks while others run tests". The shared test runner was held back from edits while three agents were using it.
- **Briefs that carried exact assertion checklists** produced comparable tests from agents that never saw each other's work. Findings were relayed mid-flight (A's cycle-test weakness was sent to B and C while they worked).
- **Agents found real bugs outside their brief:** B's jsonb-key-as-parent bug, B's missing row estimate, C's reliance on a loophole, and the harness's own vacuum and visibility-map problems. They reported them instead of hiding them because the briefs said "report, don't paper over".

### Decisions this session

| Decision | Why |
| --- | --- |
| Per-design zanzibar-level spec files | Copple's call. Each engine is tested in its native API, with checklists kept identical by the brief |
| Extension file stays empty | Copple will choose the engine later |
| Benchmark both policy shapes on every engine | Separates engine cost from policy shape; that turned out to be the biggest effect |
| Budgets = 3× the fastest engine's p95 | A multi-engine version of session 1's rule; nothing loosened to fit an engine |
| B raises when a forbid's inputs are missing | Fail closed, with a clear error, rather than silent denials |
| C reports public grants as a null row in `who_can` | Mirrors A's `('user','*')` without enumerating users |

### Still open (end of session 2)

- **Choose the engine** (DECISION.md's open questions): forbid on groups and engine-evaluated conditions in year one? uuid-only? a global write lock? `repeatable read` refusal?
- B's list function isn't net of conditioned or folder-based forbids.
- Run the pg_tle branch of `03_tle_install` somewhere pg_tle exists.
- Not yet measured: single-client nesting writes at large, mixed read/write concurrency, fsync on, PG 15/17, a user who can see most of 1M documents.
- The untested hybrid: A's API with C's materialized memberships.

### Possible angles for the blog post (session 2 additions)

- **"The policy shape mattered more than the engine."** For the same parents feature, a single-branch policy took 509 ms in A and a two-arm projection 3.2 ms (160×). The engines differed by 2–3× under the same policy.
- **"Measure, don't extrapolate."** 150 ms was predicted and 509 ms measured.
- **"A tie on the blessed path."** RBAC was within 0.2 ms across three very different engines. Most apps would never feel the choice.
- **"Materialization is a trade, not a win."** C is 20× faster on wide reads; A is 2,000× faster on nesting a big team.
- **"Planner traps, a catalogue":** a per-row cast, a hashed subquery, an OR killing the primary key, a function estimated at 1,000 rows, SQL functions re-planned on every call, and an empty visibility map after VACUUM FULL. None of them was about the authorization model.
- **"Orchestrating 13 agents without collisions":** file ownership, a single committer, serial benchmarks, and relaying findings mid-flight.
- **"Fail closed":** a fix for one fail-open bug uncovered a worse one in the same function.

### Numbers worth quoting (session 2)

- 3 engines: 618 / 1,557 / 1,871 lines; 27 / 56 / 63 functions. 46 spec-file runs in total, 532 assertions, all green.
- 15 mutants across the new features, all caught; plus a real two-session race showing C's drift without its lock.
- Identical visible-document checksums for A, B and C in every run (1M documents, 4 policies, 8 sample users).
- RBAC: all engines within 0.2 ms. Sharing page at 1M documents: 2.02 / 1.21 / 0.95 ms.
- Wide groups (medium): 221 / 70 / 10.7 ms. Nesting a 1,000-member team: 0.15 / 285 / 333 ms.
- Single-branch parents at 1M documents: 509 / 197 / 9.6 ms; projection 3.2 / 1.4 / 1.0 ms.
- One-line fixes: B `rows 1` 17.1 → 0.79 ms; B's stand-in OR rewrite 2.5 → 0.56 ms; A's SQL → PL/pgSQL 0.58 → 0.34 ms.

---

## Session 3: 2026-10-29, Postgres 16–18 with pg_tle, and a docs site

Copple asked for three things: a Docker Compose setup with PG 16, 17 and 18, each with pg_tle; benchmarks across all of them, with optimizations where the results suggest them; and a browsable docs site (Astro + Starlight, with charts), because reading markdown files had become tiresome. Two agents ran in parallel: a heavy-implementer on the Docker matrix and a light-implementer on the docs site.

### 1. Docker matrix (heavy-implementer, about 17 minutes)

- pg_tle **v1.5.3** (released 2026-10-08, PG 12–19) is built from source in a build stage onto pinned official images: `postgres:16.15`, `17.11` and `18.6`. Each container gets the same 4 CPUs and 6 GB, plus the harness's own settings (`fsync=off` and so on).
- `docker/run-matrix.sh` runs strictly one server at a time. The client runs in a separate container from the same image, so psql and pgbench match the server version.
- **All 9 version × engine suites pass:** A 156, B 172, C 204 assertions each, on 16, 17 and 18. There were no version-specific failures.
- **The pg_tle branch of the install test ran for the first time, and it had a bug.** psql doesn't interpolate `:"var"` inside backticks, so `pgtle.install_extension` received an empty body and "succeeded", and the next calls then failed. **Code that has never run is broken until proven otherwise.** The fix also made the assertion stricter: it now requires functions that belong to the extension, checked through `pg_depend`.
- **A portability bug in the harness:** Debian's `mawk` parsed `a[x > 0 ? ...]` inside `printf` as output redirection, so every workload failed in the containers. BSD awk on macOS had hidden it.
- Benchmark results now also go to JSON (`bench/baselines/data/`) for the charts. The 15 local PG16 reports were backfilled.

### 2. Docs site (light-implementer, about 19 minutes)

- `docs/` at the repo root: Astro 7.4 + Starlight 0.42. `make docs` builds it and `make docs.dev` serves it.
- **No hand-copied duplicates:** `scripts/sync.mjs` copies the 11 pg_permissions markdown files in before every build, adds frontmatter and rewrites links. The markdown in the repo stays the source of truth; the site is just a way to read it.
- **Charts are hand-built SVG, rendered at build time,** following the `dataviz` skill: one color per engine everywhere (A blue, B orange, C aqua), log scales where values span orders of magnitude, a table view and ARIA labels on every chart, and light/dark themes. Observable Plot was rejected because it needs a DOM shim at build time. The takeaway sentence under each chart is **computed from the data at build time**, so it can't go stale when the numbers change.
- The benchmark JSON is the contract between the two agents. The docs agent built against a fixture generated from the saved reports; when the Docker agent's real data appeared mid-task, it took over automatically.
- A link checker was added on top of Starlight's validator, because the plugin skips relative links: 820 internal links, all resolve.

### 3. Postgres 16 vs 17 vs 18 (27 serial runs, about 90 minutes)

- All 27 runs completed. **Checksums were identical across engines and versions:** 12 runs per configuration, one value per policy.
- **PG18 makes single-row updates under RLS 21–37% faster on every engine** (`rbac_update_one`, large: A 0.67→0.53 ms, B 0.81→0.52, C 0.66→0.45). Other RBAC reads are 10–15% faster on 18. PG17 is within ±7% of 16 almost everywhere.
- PG17/18 make C's single-branch parents count about 25% faster (large: 23.1 → 18.1 → 16.9 ms). A doesn't move.
- **Calibrating Docker against the laptop turned up a Postgres minor-release difference.** The median ratio was 1.04, but `parents_proj_select_count` was 2–3× slower in Docker. With the same plan, 16.4 touched 1,180 buffers and 16.15 touched 11,996: the newer minor releases stopped skipping heap fetches for all-visible pages in a bitmap `count(*)`, and 17 and 18 behave like 16.15. **Our local number for that workload was optimistic because of a Postgres patch release, not our code.**
- A's and B's heavy PL/pgSQL paths ran about 2× faster in Docker (Linux) than on macOS, with identical plans. The cause wasn't isolated, and JIT was ruled out.
- **Noise is real:** repeats varied ±20% on heavy wide reads and about ±10% elsewhere. One run (pg18/A medium wide) had a disturbance spike and was rerun; both sets are recorded.

### 4. Optimization pass (three heavy-implementers in parallel, one per engine)

The rules: keep each engine's character, keep every test green, keep cross-engine checksums equal, and don't touch workloads or seeds. Because the three agents shared one laptop, they measured **interleaved before/after** runs (old and new code alternating in the same cluster) rather than absolute numbers. A serial rerun confirms the results afterwards.

**C** (about 1 h):
- **Delta inserts instead of recomputing on every membership write.** New rows = (the subject's existing members) × (the object's usersets and everything above them). Deletes still recompute.
- The set-level walk runs once per distinct set instead of once per principal.
- `accessible()` uses a single `distinct on` sort for dedup and forbid veto.
- Results:

  | Workload | Before | After |
  | --- | --- | --- |
  | `write_nest_team`, large, 4 clients | 367 ms | 58 ms (6×) |
  | `write_nest_team`, large, 1 client | 90 ms | 15.5 ms |
  | Wide bulk seed | 185 s | 24.6 s (7.5×) |
  | Wide bulk seed with a new `grant_many()` | | 7.5 s (not used by the benchmark) |
  | Single-branch parents page | 9.4 ms | 5.0 ms |

- **Safety net:** a new spec runs 400 random grants and revokes with `verify()` after every step. `verify()` keeps its own **independent** per-principal walk, so the optimized path is always checked against a naive one. 4 of 4 mutants of the delta logic were caught, one of them only by the new random test.
- The global lock stayed. Per-team locks wouldn't help, because concurrent nests write the same unique keys anyway. The two-session race was rerun in both orders and stayed clean.

**A** (about 75 minutes): A still derives nothing, and every target got 10× faster or better.
- **The biggest find of the session: Postgres was running A's whole walk twice per query.** For `unnest(f(const args))` over a STABLE function, the planner evaluates the function at plan time to estimate rows, then runs it again at execution. Planning time equalled execution time. **Marking the list functions VOLATILE** halved the wide page (207 → 110 ms) on its own. The other engines' RLS functions are STABLE too, so the finding was relayed to B mid-flight and given to C as a follow-up.
- `array_agg(distinct)` was a 25 ms collation sort per 6.6k IDs, and it was unnecessary because the walk already returns each node once.
- The walk expands only nodes that can have an outgoing edge (a new partial index, 6.8 MB). The exclusion CTE is forced `materialized`: without that, a statistics change mid-run turned it into per-node probes, and a walk went from 5 to 85 ms.
- `check_for` became a bidirectional search with forced generic plans.
- Results (interleaved, 1 client, p50):

  | Workload | Before | After |
  | --- | --- | --- |
  | Medium wide `share_select_page` | 207 ms | 18 ms (11×) |
  | Medium wide `share_list_objects` | 59 ms | 5 ms |
  | Large single-branch parents page | 505 ms | 35 ms (14×) |
  | `nest_check` | 0.60 ms | 0.24 ms |

- **Honest gap:** two mutants of the new check survived the suite. One was a real hole: dropping exclusions in the backward direction. The agent couldn't add a spec (outside its files), so a follow-up agent was briefed to add `a/56_exclusion_paths` and prove it catches that mutant. **The mutation habit from session 1 keeps paying off: optimized code needs new tests, not just old ones passing.**

**Follow-up** (light-implementer):
- **C had the double execution too,** in `scopes_with_permission`: its planning buffers exactly equalled the InitPlan's buffers at execution. After the VOLATILE change, C's RBAC reads were 20–30% faster.
- C's `accessible()` stays STABLE, because the recommended `(select accessible(..))::uuid[]` form doesn't trigger the plan-time run, and VOLATILE would stop the bare form from being an index condition. **The trap depends on the exact SQL shape in the policy, not just on the function's volatility.**
- `a/56_exclusion_paths` (31 assertions): each assertion requires `check_for`, `list_objects_for` and `list_subjects` to agree. **It catches the mutant that survived** (7 assertions fail). A is now at 15/15 files and 187 assertions.

**B** (about 97 minutes), with the same policy model, closure approach and lock:
- **Collation was the biggest cost.** The database's default collation (en_SG) made the distinct sort 19 of 29 ms in a wide `ids()` call. `collate "C"` on the ID, type and role columns took the wide list from 25 to 6.8 ms on its own. **Another trap with nothing to do with authorization.** (A's `array_agg(distinct)` cost was the same problem in disguise.)
- Exact primary-key probes instead of scans, and PL/pgSQL wrappers (PG16 re-plans non-inlinable SQL functions on every call; A found the same in session 2).
- **Closure rows only for entities that have children,** as C already did. Leaves are reached in one hop through a `closure` view. This took `write_nest_team` from **307 ms to 0.6 ms** with 4 clients and halved the storage (large per-document parents: 763 → 378 MB, seed 252 → 51 s).
- **The plan-time double execution, done more carefully than A.** B kept `ids()` STABLE and made its last argument default to a VOLATILE `_unfolded_null()`, so the planner can't fold the call. The reasoning: **a VOLATILE function under read committed takes a fresh snapshot for each query it runs, so grants could be read at a later instant than the rows they filter.** A and C were then switched to B's technique, so all three keep single-snapshot semantics.
- Results (interleaved):

  | Workload | Before | After |
  | --- | --- | --- |
  | `write_nest_team`, large, 4 clients | 307 ms | 0.6 ms |
  | `nest_check` | 3.3 ms | 0.37 ms |
  | Wide `share_select_page` | 70 ms | 15 ms |
  | Large single-branch parents page | 190 ms | 13 ms |

- **Proof of equivalence:** two differential fuzzers compared old and new engines: 168k random closure writes (outcomes, errors, the full closure with depths) and 119k read results across 120 random worlds. **0 differences.**
- **A latent bug B kept as-is:** removing a shortcut edge can push a shortest path past depth 10, and the rebuild then silently drops that pair. The fix (reject such deletes, or lift the cap) is a semantic decision left to Copple.
- **The ranking changed.** Before optimization, B was worst on writes (285 ms); now it's the fastest of the materializing engines on writes (0.6 ms), close to A. The comparison in DECISION.md is now out of date, until the serial confirmation run.

**Making the plan-time trap impossible to reintroduce** (light-implementers):
- All three engines now keep STABLE (statement snapshot) and use B's volatile-default dummy argument. Planning dropped from about 12 ms and 3,564 buffers to 0.2 ms and catalog lookups only. `collate "C"` gave A another 9% on wide pages, mostly in B-tree probes rather than sorts.
- **A deterministic test for the trap:** `pg_stat_get_xact_function_calls()` counts function calls made during planning. The new specs run `EXPLAIN` (no ANALYZE), assert the permission functions were called zero times, then run the query and assert they were called. One gotcha: the counter also includes unflushed counts from earlier transactions, so the specs assert on differences.
- **The test found another gap immediately:** B's generated RLS for conditioned policies passed every `ids()` argument as a constant, so it folded too. Each new spec was proven by a mutant that removes the dummy default.
- Suites: A 18 files and 199 assertions, B 18 and 189, C 21 and 229. All green.

### 5. Serial confirmation of the optimizations (27 runs, tagged `opt`)

- **Every checksum matched the pre-optimization runs,** per configuration and policy, across all three versions. The optimizations changed speed, not answers.
- PG18 Docker, p50, before → after:

  | Engine | Workload | Before → after |
  | --- | --- | --- |
  | A | wide `share_select_page` | 125 → 14.4 ms |
  | A | large single-branch parents | 240 → 45.6 ms |
  | B | `write_nest_team` | 107 → 0.62 ms (172×) |
  | B | `nest_check` | 1.14 → 0.32 ms |
  | B | large parents | 102 → 13.7 ms |
  | B | storage | 763 → 378 MB |
  | C | `write_nest_team` | 300 → 58 ms |
  | C | wide seed | 176 → 25 s |
  | C | parents | 9.3 → 4.9 ms |

- **The "after" values matched the claims within 1.3×, but some speedup factors were smaller than claimed** (A's parents: 5.3× measured vs 14× claimed). EXPLAIN showed why: Docker (Linux) already ran the old PL/pgSQL paths about 2× faster than macOS, so the "before" values were lower. **A speedup measured on one machine doesn't transfer, but the absolute "after" number did.**
- **The new ranking:**
  - RBAC and default/deep sharing: all three within 15%.
  - `nest_check`: a three-way tie (0.30–0.32 ms).
  - Wide sharing: C < A < B.
  - Nesting write: A 0.15 < B 0.62 ≪ C 58 ms.
  - Storage at large: C 182 < B 378 < A 404 MB.
- **The engines converged.** Before the pass, the gaps were 10–2,000×. After it, most are under 3×, except C's nesting write and A's single-branch parents. **Much of the "engine difference" in session 2 was really unoptimized code.**
- Not every number moved: A's `rbac_check` got 10–20% slower (0.26 → 0.30 ms). Large `parents_proj_select_count` sits on the minor-release heap-fetch floor (about 8 ms), so no engine can meet its 9 ms budget (set on 16.4) on current minor releases.
- Housekeeping: four disturbed runs were replaced by repeats, using a written rule (5 or more workloads with p95 > 2× p50). Desktop apps kept the load average at 3–5 even with no agents running.

### 6. Docs and decision refresh

- **The docs site needed one data-model change:** series are now keyed by environment + major version + tag, so optimized runs no longer hide pre-optimization runs. The primary series is chosen explicitly (PG18 Docker, optimized), not by run count.
- New `/benchmarks/optimizations/` page: dumbbell charts on a log axis (hollow dot = before, filled = after) in the engine colors, a before/after ranking table and a speedup table across PG 16/17/18. The takeaways are computed from the data. `VERSIONS.md` and `OPTIMIZATIONS.md` are synced in. The build checks 1,125 internal links across 18 pages.
- **One hand-written takeaway was false:** "nest_check stays close to flat" isn't true for B on local PG16 (1.2 → 2.6 ms). It was fixed. **Computed takeaways stayed honest and the hand-written one went stale.**
- `DECISION.md` and PLAN.md were refreshed to the optimized PG18 numbers. PLAN §4 gained four rules learned this session: STABLE plus a volatile-default dummy argument, `collate "C"` on text IDs, PL/pgSQL for hot functions, and `rows` estimates on set-returning helpers.
- New open questions for Copple:
  - B's depth cap can silently drop a path after a delete.
  - The dummy argument means `scopes_with_permission` signatures differ slightly across engines (the one-argument call is still identical).

### Still open (end of session 3)

- **Choose the engine.** After optimization the engines are much closer:
  - RBAC, default/deep sharing and `nest_check` are within 15%.
  - C still leads on wide reads (1.8× A) and single-branch parents.
  - A and B lead on nesting writes (0.15 / 0.62 ms vs 58).
  - A is the smallest (871 lines) and derives nothing.
- B's depth-cap-on-delete behaviour, and its list function not being net of conditioned forbids.
- The large `parents_proj_select_count` budget (9 ms) can't be met on current minor releases. Re-baseline it, or accept it.
- Not yet measured: small and medium default in Docker after optimization, mixed read/write concurrency, fsync on, single-client writes in Docker.

### Possible angles for the blog post (session 3 additions)

- **"Most of the engine difference was unoptimized code."** Gaps of 10–2,000× shrank to under 3× for most workloads after one optimization pass, without changing any engine's design.
- **"Postgres ran our permission check twice per query."** Plan-time folding of STABLE functions; the VOLATILE fix that weakens snapshot semantics; and the dummy-argument trick that avoids both. Plus a deterministic test using `pg_stat_get_xact_function_calls`.
- **"Your collation is a performance setting."** `collate "C"` on text IDs was B's biggest single win.
- **"Speedups don't transfer between machines; absolute numbers do."** macOS vs Linux Docker made the same plan 2× different.
- **"A patch release changed our benchmark."** 16.4 vs 16.15 changed a bitmap `count(*)` by 10× in buffers.
- **"Code that has never run is broken."** The pg_tle install branch, written in session 2, failed the first time it ran.
- **"Agents relaying findings to each other":** A's plan-time discovery was sent to B and C mid-flight, and B's snapshot objection then improved A's and C's fixes.

### Numbers worth quoting (session 3)

- 3 Postgres versions (16.15, 17.11, 18.6) × 3 engines; 54 Docker benchmark runs plus repeats; pg_tle 1.5.3.
- Checksums identical across 69 runs, engines, versions and before/after optimization.
- PG18 makes RLS single-row updates 21–37% faster on every engine.
- After optimization (PG18): B's nesting write 107 → 0.62 ms; A's wide sharing page 125 → 14 ms; C's wide seed 176 → 25 s; B's storage 763 → 378 MB.
- Plan-time fold: planning went from 12 ms and 3,564 buffers to 0.2 ms.
- Collation: B's wide list went from 25 to 6.8 ms on that change alone.
- Suites: A 199, B 189, C 229 assertions; all green on 16, 17 and 18.
