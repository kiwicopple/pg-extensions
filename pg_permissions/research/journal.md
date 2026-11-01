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

### 8. An independent review of the upstream report, and a second model's correction

After the OpenFGA finding in section 6 was written up as an upstream report, another model reviewed it independently. It reproduced the inconsistency with the official release binary and corrected the framing.

- **The API disagreement is confirmed, but "false is right" is not.** Check and ListObjects say true, ListUsers says nobody, and that is a real disagreement. What the review took issue with was the earlier session-4 conclusion that false was the correct answer and OpenFGA was the one in error.
- **The cycle is positive recursion beneath an exclusion, not recursion through the negation.** `blocked(document:1)` contains `blocked(document:2)` which contains `blocked(document:1)`, and `viewer` only subtracts that set. Under least-fixpoint semantics the smallest set satisfying those equations contains nobody, so jon is not blocked and true is defensible.
- **The closest upstream test doesn't settle it.** `true_butnot_cycle_return_false` loops back through `viewer` itself (`viewer` subtracts `restricted`, which contains `viewer`), which is recursion through negation. Searching the YAML for a subtracted relation that references itself found no case.
- **A second inconsistency, from the same review.** Adding an unused `team#member` path to the model (the control from section 6) flips OpenFGA's Check on `viewer` to false while ListObjects still includes the document. So adding a path no tuple uses changes Check but not ListObjects, which is a stronger finding than the original one, because it doesn't depend on which answer is right.
- **Copple told us to follow the review.** Two changes followed:
  - The report now asks for agreement across the APIs and across resolver strategies, and leaves the true-or-false answer to the maintainers. (Commits `fca6873`, `526bdf6`.)
  - D switched to least-fixpoint semantics for a monotone relation beneath an exclusion, in Check, ListObjects and ListUsers, so the three agree in D, including on the control model. Recursion through negation keeps OpenFGA's cycle rule. `d/31_fga_cycles` now expects true. (Commit `c262cc6`.)
- **The earlier recommendation was too strong.** Section 6 said D "keeps the default resolver (false)" because it matched OpenFGA's own cycle cases, and the "Decisions" table recorded that as settled. It matched cases about a different shape. The decision row is now marked superseded.

### 9. Optimizing D: opt to opt2 (commits `c262cc6`, `98fd181`)

The three hotspots from section 5 were fixed, benchmarked the same way (PG18 Docker, same workloads, tagged `opt2`), and written up in `bench/baselines/D.md` next to the `opt` numbers.

- **What changed:**
  - **Target-type pruning.** `fga_reach` holds reachability between (type, relation) pairs, and `fga_walk_steps` holds, per target relation, only the edges whose destination can reach the target (13 rows for the benchmark model). Both are compiled at model write.
  - **One recursive CTE walk** (A's `_reach` shape) in place of the PL/pgSQL loop over growing arrays. Levels are kept per row so the depth-25 rule stays exact; if an expandable node is first reached at level 25, a level-free walk finishes behind it.
  - **Set-based `but not` lists** for ListObjects and ListUsers when the base is a positive expression over monotone relations and the subtract is `r` or `r from ts`: base walk minus subtract walk. Other shapes keep the per-candidate path.
  - Small Check trims (no statement for a plain user's start frontier, inline object parsing).
- **Results (p50):**
  - `but not` ListObjects on the wide data, user 7 (6,701 ids): **2,079 ms to 4.16 ms**, 540x faster than the per-candidate path on the same build (2,234 ms). That is about the cost of the monotone list, because the subtract walk is one probe.
  - Wide `share_list_objects` **17.77 to 5.12 ms** (A 4.44, B 8.41, C 3.41).
  - Wide `parents_proj_select_page` **38.63 to 10.87 ms** (A 14.98, C 8.73). The folder arm costs nothing once it is pruned (in-server, ListObjects on `folder#viewer` 13.7 to 0.04 ms).
  - Deep `share_list_objects` 0.78 to 0.33 ms. Large default barely moved except `share_list_objects` (0.54 to 0.36) and the two-arm page (1.66 to 1.11). Check and writes didn't move.
- **Budget misses:** the four wide misses and the deep one are gone. The only one left is large `parents_proj_select_count` (11.55 ms against a 9 ms budget), which all four engines share (the heap-fetch floor from session 3).
- **Tests:** 37 of 37 spec files, 2,164 assertions, on PG 16, 17 and 18. The OpenFGA suite is still 933 of 933 stored and 746 of 746 contextual.
- **New specs, new mutants.** `d/32` and `d/33` are in-house specs for the new walk. Mutants of the depth check and of the level-25 finish passed the whole OpenFGA suite and were caught only by them, the same pattern as the cycle-flag mutant in section 7.
- **Remaining hotspots (from D.md):**
  - Wide ListObjects is 1.15x A and 1.5x C. The leaf join does a heap fetch per tuple (the user index has no `object_id`), a sort-based `group by` keeps each target's lowest level, and three PL/pgSQL result tuplestores sit on top.
  - Check is 1.3-1.4x A (`_fga_bidi` statement count). It matters for per-row RLS, not for list policies.
  - Writes are 1.5-1.7x A (`fga_write_tuple` builds JSON that `fga_write` re-parses and validates).
  - Non-monotone relations outside the set-based form (intersections, `but not (a or b)`, a base that depends on a non-monotone relation) still check every candidate top-down, about 2 s per wide ListObjects. Check on any `but not` relation is top-down too.
  - A userset cycle in the leveled walk is expanded once per level until 25, not once. Not in the benchmark data.
- **Not done:** the covering `fga_tuples` user index (+120 MB at large), the typed write path, memoization in `_fga_rec`.

### 10. Checking the upstream report before sending it

The report had never been run. Before Copple sends it, the repro script and every claim in the report were checked against a fresh `openfga/openfga:v1.22.1` container (pinned by digest, memory datastore).

- **The script ran cleanly the first time** at both `MINIMIZE_LATENCY` (the default) and `HIGHER_CONSISTENCY`, exiting 1 (inconsistency reproduced) both times, with identical output at the two levels:
  - Original model: Check `blocked` false, Check `viewer` true, ListObjects `["document:1","document:3"]`, ListUsers empty.
  - Control model: Check `viewer` false, ListObjects still `["document:1","document:3"]`, ListUsers empty.
  - Cycle broken: Check, ListObjects and ListUsers all agree jon has access.
  - Jon blocked on `document:2`: all agree jon has no access.
- **Every number in the report's Results table and cycle-breaking variants matched.** The report now says so ("reproduced by the attached script"). 1,000 consecutive Checks of `viewer` on `document:1` on the original model all returned true, as claimed; that is a separate loop, and the report says so.
- **The blog citation needed tightening.** The post (`weighted-graph-upcoming-changes`) does distinguish the two, but not quite as the report put it. Its broken pattern is a recursive relation that carries the exclusion itself (`define member: [user, group#member] but not blocked`), "This creates a circular dependency." Its recommended fix keeps the recursion a pure union and puts the exclusion on a separate relation ("Pure union recursion (allowed)", "Exclusion at leaf level only"). The report's model has the second shape, so the post doesn't call it broken, but it doesn't give the answer either, and it describes upcoming changes rather than v1.22.1. The report's sentence now says that.
- **All 17 GitHub permalinks at tag v1.22.1 return 200,** and the cited line numbers land on the named functions (checked in a read-only local clone at `44054f5`).
- **A mishap in the check itself:** the first 1,000-check loop printed 1,000 `false`. The store name `x` was too short for OpenFGA's validation, so every call returned an error, and a `// false` default in the jq filter turned the errors into answers. The repeat with a valid name gave 1,000 `true`. The script itself uses `curl -f` and exits 2 on API errors, so it can't be fooled that way.

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

### 7. Usage docs, written as tests

Copple asked for usage docs: how they'd actually use the extension under each engine, plus the API. Four light-implementers worked in parallel: a shared guide (install, identity, privileges, the `rbac` preset and RLS patterns) and one page per engine (mental model, quick start, how-tos, full API reference, performance notes and gotchas).

- **Every example with a result is also an assertion:** `90_usage_rbac` (86 assertions, passes on all three engines), `a/90` (141), `b/90` (229) and `c/90` (196). Each agent also checked by script that every public function in `pg_proc` appears in its API reference (A 24, B 38, C 31).
- **Writing docs as a newcomer found more than any review had.** The "identical" `rbac` preset isn't quite identical across engines:
  - `current_subject_id()` is uuid on C, so a Clerk-style `user_2abc` subject is "no subject";
  - cleanup functions differ;
  - B refuses role changes under `repeatable read`.

  There were also security-relevant RLS footguns: A's recommended two-arm policy ignores document-level forbids; B's null parent column hides rows; B's conditioned forbids aren't enforced until RLS is regenerated. All of these are now in DECISION.md as "first hardening work".
- One broken anchor (`#rls-tooling` vs Starlight's `#rls-tooling-admin` slug) was caught by the link validator. The site now has 22 pages and 1,911 internal links, all resolving.
- **Blog angle: "Write the docs to find the bugs."** Explaining the API to a newcomer, with every example executed, surfaced inconsistencies that 500+ assertions per engine hadn't.

---

## Session 4: 2026-10-29, dropping the generic API: per-model tables, OpenFGA as the oracle

The session started with a direction change rather than a task. Copple questioned the thing the first three sessions had taken as given: that there should be one generic API over several models. The A/B/C engines had been compared as candidates for that single API. This session replaced the question.

### 1. The proposal, and where Claude agreed and pushed back

- Copple's proposal: put a separate set of tables per model inside the `permissions` schema, each following an existing spec, usable at the same time, each optimized on its own, and easier to keep in step with upstream spec changes than a generic layer would be.
- Claude agreed, with caveats:
  - **CEL is an expression language, not a model.** In OpenFGA it shows up as conditions on tuples, so it doesn't get its own table set.
  - **Full Cedar is expensive in Postgres.** `when`/`unless` over arbitrary attributes doesn't compile to index lookups (already noted in C's design doc), so Cedar would be a documented subset, later.
  - **A small shared toolkit remains:** subject identity, the plan-time-evaluation guard, `collate "C"` on ids, and the install and pg_tle plumbing.
  - **The surface grows.** More tables and more functions to document and test.
- **Postgres RLS is the composition layer.** Permissive policies OR together and restrictive policies AND. That also gives the graduation path: an app starts on RBAC and adds an FGA policy next to it instead of migrating off.
- The reasons recorded in DECISION.md were evidence from earlier sessions: the usage-doc findings (session 3) came from forcing different semantics through one API (the `rbac` preset wasn't quite identical across engines, and forbid meant something different in each); the `rbac` preset was flat across engines (under 1 ms, within about 0.1 ms); and the engines only differed on sharing shapes, where the optimizations were model-specific anyway.

### 2. Choosing OpenFGA, and the ABAC question

- **OpenFGA, not SpiceDB or a generic "Zanzibar-style" model.** The two have different schema languages, so "follow a spec" means choosing one. OpenFGA was chosen specifically so that its public test suite could be the oracle, and because it has CEL conditions on tuples. Cedar was deferred, with design B as its starting point.
- Copple asked whether ABAC needs its own model. It doesn't: **ABAC is a category, not a spec** (XACML is the only formal standard, and nobody builds new systems on it). Row attributes are covered by RLS predicates, attributes on a relationship (expiry, IP range, amount) by OpenFGA conditions, and policy-language ABAC by Cedar later.
- **A gap was written down rather than hidden:** row attributes that exist only in RLS are invisible to the check functions (design A's doc had already seen `check_for` return true for a draft that RLS hides). The usage docs will have to say either "check functions are advisory and RLS is final" or "pass row attributes into the check".
- Recorded in commit `86ea456` (DECISION.md "Session 4 direction", PLAN.md "Current plan (session 4)"). The empty `pg_permissions--0.0.1.sql` stays empty until the spike is validated, and the A/B/C prototypes stay in the repo as measured history.

### 3. Research before building: what OpenFGA's test suite looks like

- `assets/tests/consolidated_1_1_tests.yaml` upstream: **138 cases**, each with a model in OpenFGA's DSL, tuples, and assertions for Check, ListObjects and ListUsers. The harness runs each case twice, the second time with every tuple sent as a contextual tuple.
- A rough first count was 78 core cases and 59 needing `and` or `but not`, so the plan was two stages. Conditions (CEL) live in a separate file of 33 cases, left for later.
- **Postgres never parses the DSL.** Each model is converted to JSON once, with `openfga/cli` v0.8.2 pinned by image digest, and the JSON is vendored with the YAML, the licence (Apache-2.0) and a SOURCE file. `vendor.sh` clones into an empty temp directory and executes nothing from the clone; `generate.py` (run with `python3 -I`) turns the cases into ordinary TAP spec files, so the existing runner and Docker matrix pick them up unchanged (commit `5e25454`).

### 4. Prototype D

Built in four commits (`5e25454`, `e75598f`, `a620868`, `10d0849`).

- **`rbac_*`:** first-class tables (roles, permissions, an `inherits` closure, scoped assignments) behind the same `rbac` API the earlier designs had, so the shared specs run unchanged.
- **`fga_*`:** OpenFGA's API (Check, ListObjects, ListUsers, Read, Write, WriteAuthorizationModel), schema 1.1 JSON models validated and compiled on write, and **OpenFGA's numeric error codes** in the `DETAIL` of the Postgres exception, so the machine-checkable part matches upstream. Monotone relations are answered by set-based walks (design A's bidirectional search generalized); relations with `and` or `but not` go through a recursive evaluator written after OpenFGA's `LocalChecker`.
- **Stage 1 first:** `e75598f` passed every stage-1 case (stored 79 cases / 498 assertions, contextual 67 / 369) and skipped 59 stage-2 cases.
- **Stage 2 needed no new engine code.** The recursive evaluator already followed `LocalChecker` for intersection and difference, so `10d0849` only deleted the skip list. Final result:

  | Run | Cases | Assertions | Passed |
  | --- | --- | --- | --- |
  | stored | 138 | 933 | 933 |
  | contextual | 116 | 746 | 746 |

  The other 22 cases are multi-stage, which upstream doesn't run with contextual tuples either. The plan said 23 multi-stage, because one case name appears twice upstream (`immediate_cycle_through_computed_userset`; the second is reported as `~2`).
- **Mutants, to prove the oracle can fail** (the habit from session 1): ignoring wildcards fails 13 assertions, no depth limit fails 2, ignoring the subtract of a difference fails 159, ignoring the cycle flag under a subtract fails 4, treating a cycle as true in an intersection fails 8. All caught.
- **One mutant survived the upstream suite** and was caught by D's own `d/31_fga_cycles`: using the fast set-based search for a monotone relation inside a subtract also loses the cycle flag, and upstream has no case with a cycle inside a monotone subtract. That is the first hint of what section 6 turned into.
- **Composition spec:** `d/40_rbac_fga_rls` puts RBAC and FGA policies on one table (permissive OR, a restrictive FGA ban AND, per-row checks for updates) and asserts the exact rows five users see.
- **A plan-time finding that came for free:** the FGA list functions return `setof text`. A set-returning function is never evaluated at plan time (its row estimate comes from `rows`), so the session 3 trap needs no dummy argument there. `d/41_no_plan_time_eval` pins it with the call-count probe from session 3. `scopes_with_permission` keeps its `text[]` form and dummy argument because the shared specs pin both.
- **Test status:** all 35 spec files (1,931 assertions each) pass locally and on PG 16, 17 and 18 with pg_tle 1.5.3 in the Docker matrix.

### 5. Benchmarking D (PG18 Docker, same workloads, tagged `opt`)

D got the same seeds, shapes and workloads as A, B and C, with one deliberate difference: **org roles stay in `rbac_*` and compose with the FGA policies through RLS**, instead of living inside the FGA graph. The sharing model is written once in OpenFGA terms (`team#member`, `folder#viewer`, `document#parent`, `document#viewer: [user, team#member] or editor or viewer from parent`). D is unoptimized; nothing was changed after measuring.

- **Checksums matched in every configuration, A = B = C = D**, per read policy (large default, medium deep, medium wide, plus small shapes on local PG16 before any timing).
- **p50 for the headline workloads (ms, large default unless noted):**

  | Workload | A | B | C | D |
  | --- | --- | --- | --- | --- |
  | `rbac_check` | 0.30 | 0.27 | 0.24 | 0.22 |
  | `rbac_update_one` | 0.47 | 0.47 | 0.36 | 0.28 |
  | `share_list_objects` | 0.29 | 0.29 | 0.25 | 0.54 |
  | `share_select_page` | 1.03 | 1.00 | 0.93 | 1.29 |
  | `write_nest_team` | 0.15 | 0.62 | 57.66 | 0.24 |
  | `nest_check` | 0.31 | 0.32 | 0.30 | 0.41 |
  | wide `share_list_objects` | 4.44 | 8.41 | 3.41 | 17.77 |
  | wide `share_select_page` | 14.44 | 17.82 | 8.20 | 26.20 |
  | wide `parents_proj_select_page` | 14.98 | 15.05 | 8.73 | 38.63 |

- **RBAC on its own tables is the fastest of the four:** `rbac_check` 0.21-0.22 ms against 0.24-0.30, `rbac_update_one` 0.27-0.28 ms, 20-30% under C.
- **Nesting a team is just a tuple write:** 0.23 ms, no locks, no derived rows (C: 58-75 ms).
- **Storage at large is 285 MB:** between C (182) and B/A (378/404). Seeds through the native Write API are in A's range (large parents 33.8 s; A 31.0, B 44.8, C 17.6).
- **FGA sharing reads are 1.3-2x A at large and 2-4x at wide.** Four budget misses at wide, one at medium deep (`share_list_objects`, p95 1.02 ms against 1 ms), and the large `parents_proj_select_count` miss that all four engines share (the heap-fetch floor from session 3).
- **The single-branch parents rows are not comparable.** D's 1.4 ms against A's 45.6 ms is because D never walks the org-role documents that A, B and C walk. With org roles mirrored into FGA (A's scenario literally), D's ListObjects takes 52 ms per call against A's 45.6 ms page. The honest statement is that D keeps org roles out of the graph by design, and the benefit is real for this app but isn't an engine-to-engine win.
- **Three hotspots, each with a throwaway variant measured on the benchmark's own database:**
  - **The walk ignores the target type.** A folder ListObjects for a wide user who views no folder took 13.7 ms and returned nothing, because the forward walk expands every team and document. Pruning the frontier to nodes that can reach the target: **13.7 -> 0.25 ms**. The two-arm parents policy pays this on every query.
  - **ListObjects is a PL/pgSQL loop over growing arrays.** Per reached node it costs 4x A's recursive CTE (17 ms against A's 3.9 ms on the same data and server). One recursive CTE over a pre-joined edge list: **17 -> 8.5 ms**.
  - **ListObjects on a `but not` relation checks every candidate top-down.** 2.08 s per call for a user with 6,700 candidates (20,106 calls to the recursive evaluator, about 310 microseconds per candidate), against 17 ms for the monotone relation, 120x. A set-based difference (list the base, subtract what the user reaches through the blocked relation) is expected to give about 35 ms. This isn't in the benchmark model, so it was measured separately.
- **Not a hotspot, despite being flagged in the design doc:** the empty contextual-tuple branches in the four-way `union all`. They run in microseconds, and a variant without them was within noise. They only add about 1 ms of planning to the first call of a session. **A risk written down before measuring turned out not to matter; another (ListObjects loop cost) turned out to be the main wide cost.**
- **Check has a fixed overhead:** about 200 microseconds per call, of which model resolution and validation is about 10% and the rest is statement count.
- The docs site gained engine D (its own colour, its design doc and D.md synced).

### 6. Running the reference implementation, and the answer it gave

This is the part of the session worth the most space. D passed all 138 of OpenFGA's cases, so the oracle had said everything it was going to say. The mutant checks showed which behaviours the suite pins and which it doesn't. One gap was a cycle inside a subtract, so we asked what OpenFGA itself does there.

- **The first attempt to run the `openfga/openfga` Docker image was blocked by the permission classifier.** Copple then authorized it explicitly, and it ran.
- **Model:** `blocked: [user, document#blocked]` and `viewer: [user] but not blocked`, with a blocked cycle between `document:1` and `document:2`. Intuition from OpenFGA's own cycle cases (`true_butnot_cycle_return_false`) says the difference should be false.
- **OpenFGA v1.22.1** (exactly the commit the suite is vendored from, memory datastore) says **Check `viewer` on `document:1` is true**, and ListObjects includes `document:1`, while **its own ListUsers returns no viewers.** OpenFGA disagrees with itself between Check and ListUsers.
- **The cause is the planner.** OpenFGA has a Thompson-sampling planner that chooses between resolvers. For a recursive userset like this it picks the recursive resolver, which never reports a cycle. Its cold-start priors (150 ms for recursive, 500 ms for the default resolver) make it pick recursive essentially every time until recursive runs slower than the default's prior. No flag selects the resolver. The results were deterministic across about 800 runs (the committed docs and spec comment say "600+"), over fresh containers, with default settings and with `enable-check-optimizations`.
- **A control confirmed the explanation.** In a model where the recursive resolver doesn't apply (`blocked` also accepts `team#member`, so a second path for `user` exists), OpenFGA answers false, which is what D computes.
- **D's engine is unchanged.** It follows the default resolver (false). The difference is documented in the design doc (deviation 12 and the "Cycles" section) and `d/31_fga_cycles` still pins D's answer, not OpenFGA's. Commit `f2a05ef` changed only those two files: it replaced "upstream leaves this to its planner" with the measured behaviour.
- **Matching OpenFGA would be possible but ugly:** detect the same condition as its `UsersetUseRecursiveResolver` and evaluate that subproblem by set-based least fixpoint, with ListObjects following and ListUsers changed to return the viewer. **Whether D should match the planner's answer, or the answer the spec's own cycle cases imply, is an open decision for Copple.**

### 7. Small mishaps (useful colour for the post)

- **The benchmark runs shared the machine with an unrelated Supabase Docker stack.** It was running throughout. D.md records that it was, and also that **whether it was running during A, B and C's runs isn't recorded.** The wide p95 values are the noisy ones: a 5 s rerun of one workload gave the same p50 (16.55 against 17.77 ms) but a different p95 (22.28 against 37.11 ms). Treat D's wide p95 misses as a maybe.
- **A count in the plan was off by one:** 23 multi-stage cases, actually 22, because upstream has a duplicate case name. Worth knowing before anyone quotes "138 cases" and does arithmetic on it.
- **The classifier block** on running a third-party image (section 6) is the permission system working as designed; running a third-party image needed an explicit yes.
- **The benchmark runs shared the machine with more than Supabase.** An unrelated `openfga/openfga:v1.22.1` container (not ours), a Supabase stack and a freereps stack were all running while D (and later opt2) was measured. Timing noise on the wide p95 values is the likely cost; the p50 comparisons are the ones to trust.
- **A mutant survived and wasn't a spec failure:** the one that lost the cycle flag in the set-based path passed all 933 upstream assertions. The in-house spec for it exists because we noticed.

### Decisions this session

| Decision | Why |
| --- | --- |
| Drop the single generic API; one table set per model | Different semantics forced through one API produced the session 3 usage-doc inconsistencies; each model can be optimized for itself |
| OpenFGA first, not SpiceDB or generic Zanzibar | A spec means one schema language; OpenFGA has a public test suite and CEL conditions |
| RLS as the composition layer | Permissive OR and restrictive AND already do what is needed; also the graduation path |
| No ABAC model | A category, not a spec; covered by RLS, OpenFGA conditions and Cedar later |
| Cedar deferred, B as its starting point | Full `when`/`unless` over arbitrary attributes doesn't compile to index lookups |
| Convert DSL to JSON once, pinned CLI image | Postgres never parses the DSL; the vendored tests run offline |
| FGA list functions return `setof text` | Never evaluated at plan time, so no dummy argument |
| ~~D keeps the default resolver on cycle-in-subtract~~ (superseded, see section 8) | Matched cases about a different shape (recursion through negation) |
| D uses least fixpoint for positive recursion beneath an exclusion | Check, ListObjects and ListUsers agree, including on the control model; recursion through negation keeps OpenFGA's cycle rule |
| Upstream report asks for agreement, not a particular answer | The cycle shape can be argued either way; the disagreement between APIs and resolver strategies is not arguable |
| Apply target pruning, CTE walk and set-based `but not` (opt2) | The three measured hotspots; wide reads 2.2-4x faster, `but not` ListObjects 540x |

### Still open (end of session 4)

- **What the maintainers say about the OpenFGA report.** Not yet sent. D no longer matches OpenFGA's default-resolver answer; it matches the recursive resolver's answer (true) on the original model, and agrees with itself on the control model where OpenFGA's Check says false. If upstream decides the other way, D changes again.
- **Which of the remaining proposed fixes to apply.** Done in opt2: target pruning, the recursive-CTE walk and set-based `but not`. Left: a covering `fga_tuples` index (-33% on large fan-outs, +120 MB), a cheaper Check (0.40 ms, 1.3-1.4x A), and a typed write path (0.23 ms, 1.5-1.7x A). Also the non-monotone shapes that still check every candidate (about 2 s per wide ListObjects) and the level-by-level cycle walk.
- **Stage 2 of the plan: OpenFGA conditions (CEL).** The largest single cost, because pg_tle means a parser and compiler in SQL or PL/pgSQL. The 33-case conditions file is the oracle.
- **A benchmark workload with a block list.** The `but not` ListObjects number (4.16 ms) still comes from a side script (`designs/d/but_not_list_objects.sql`), not from the pgbench workloads.
- **The only budget miss left:** large `parents_proj_select_count`, shared by all four engines.
- **The RLS-only attribute gap** and what the check functions promise (advisory, or take attributes).
- **Re-run the wide benchmarks with nothing else on the machine.** An unrelated openfga container, a Supabase stack and freereps stacks were running during D's runs, and whether anything was running during A, B and C's runs still isn't recorded.
- Open design choices in the design doc (section 11): `setof text` returns, the error encoding, model versioning, deny-on-missing-subject, whether `delete_subject` should span both models, and keeping two evaluators in agreement.

### Possible angles for the blog post (session 4 additions)

- **"The spec's own test suite caught nothing, because we passed all of it. The real divergence came from running the reference implementation."** 138 of 138 cases, 933 of 933 assertions, and OpenFGA still answers a cycle-in-subtract question differently from D. A passing oracle only tells you about the cases the oracle has.
- **"An adaptive planner makes the reference implementation's answer to an edge case depend on its cost priors."** A Thompson-sampling resolver choice means the answer to Check is decided by a prior of 150 ms against 500 ms, and OpenFGA's Check and ListUsers disagree with each other. "Follow the reference implementation" has no single answer here.
- **"Drop the generic API."** Three sessions of building one API over several engines, then evidence from the third session's docs work turned the direction around. The comparison of A, B and C didn't pick a winner; it picked a different question.
- **Following a spec so you can borrow its tests.** The reason for choosing OpenFGA over SpiceDB wasn't features; it was that its tests are public and run offline.
- **"The test suite is a measuring tool for what you haven't tested."** Mutants showed exactly which behaviours the 138 cases pin (and the one they don't).
- **A risk list written before benchmarking, and how it scored.** One flagged risk was noise, one was the main cost, and one important hotspot (`but not` in ListObjects, 120x) wasn't in the benchmark model at all.
- **Fast on its own tables.** RBAC as first-class tables was the fastest of four engines on `rbac_check` and updates, with no shared core to pay for.
- **"Honest comparisons need the same work."** D's 1.4 ms single-branch parents result looked like a win until it turned out D was doing less work by design; the mirrored version was 52 ms.
- **Not every blocker is a bug.** A permission classifier stopped a third-party image from running until a human said yes.
- **"A second model caught the overclaim."** Session 4's own recommendation was to keep false, and it was too strong. An independent review reproduced the finding, pointed out that the cycle is positive recursion beneath an exclusion (least fixpoint says nobody is blocked) and that the nearest upstream test is a different shape, and found a stronger second inconsistency. The fix was to ask upstream for agreement and leave the answer open.
- **A bug report is a claim too, so run it.** The report's script had never been run; running it matched every number, the blog quote needed a more careful reading, and the first check of "1,000 consecutive true" produced 1,000 false because of a mistake in the checker.
- **Mutants again: the in-house specs caught what the oracle can't.** The depth check and the level-25 finish passed all 933 upstream assertions and failed `d/32` and `d/33`.
- **What an optimization pass is worth.** One session's diagnosis, three fixes, and wide reads 2.2-4x faster; the 2-second `but not` call became 4 ms, while Check and writes didn't move at all.

### Numbers worth quoting (session 4)

- 138 upstream cases (22 multi-stage); 933 of 933 stored assertions, 746 of 746 contextual (116 cases); 35 spec files and 1,931 assertions on each of PG 16, 17 and 18 with pg_tle 1.5.3.
- 5 mutants against the upstream suite, 13, 2, 159, 4 and 8 failing assertions respectively; one more survived until the in-house cycle spec.
- Checksums identical across A, B, C and D in all three Docker configurations.
- `rbac_check` 0.22 ms (A 0.30, B 0.27, C 0.24); `rbac_update_one` 0.28 ms; nesting a team 0.24 ms against C's 57.66 ms; large storage 285 MB.
- FGA wide sharing: 17.77 ms `share_list_objects` against A's 4.44 and C's 3.41.
- Hotspots: 13.7 -> 0.25 ms (target pruning), 17 -> 8.5 ms (one recursive CTE), 2.08 s -> about 35 ms expected (set-based `but not`; 20,106 recursive-evaluator calls per ListObjects).
- Single-branch parents: 1.4 ms (D, not comparable) against 52 ms with org roles mirrored into FGA and A's 45.6 ms.
- OpenFGA v1.22.1: Check true, ListObjects includes the object, ListUsers empty, about 800 runs (600+ in the committed docs); planner priors 150 ms recursive against 500 ms default.
- Repro script: 4 scenarios at 2 consistency levels, identical output; 1,000 of 1,000 consecutive Checks true; 17 of 17 permalinks resolve at v1.22.1.
- Control model (unused `team#member` path): OpenFGA Check false, ListObjects still includes the document, ListUsers empty.
- opt2 (PG18 Docker): `but not` ListObjects 2,079 -> 4.16 ms (per-candidate path 2,234 ms on the same build); wide `share_list_objects` 17.77 -> 5.12 ms (A 4.44, C 3.41); wide `parents_proj_select_page` 38.63 -> 10.87 ms (A 14.98, C 8.73); deep `share_list_objects` 0.78 -> 0.33 ms; `folder#viewer` ListObjects 13.7 -> 0.04 ms in-server.
- Budget misses: five (four wide, one deep) plus the shared large one before; only the large `parents_proj_select_count` (11.55 > 9 ms) after.
- Tests after opt2: 37 of 37 spec files, 2,164 assertions on PG 16, 17 and 18; OpenFGA suite 933 of 933 and 746 of 746.

### End of session 4: decisions

The user made these calls after the opt2 benchmarks and the upstream report. They are recorded in `DECISION.md` ("Decisions at the end of session 4") and turned into an ordered work plan in `PLAN.md` ("Next work (session 5 onward)").

- **D is the engine and becomes the extension.** A, B and C stay as measured history. The schema is `permissions`, with `rbac_*` and `fga_*` prefixes (closes open question 10). One implicit OpenFGA store per database; the latest model by default, older model ids still evaluate.
- **Caps follow OpenFGA on the API functions:** ListObjects and ListUsers at most 1,000 results, Write at most 100 tuples per call, Read paginated with `page_size` and `continuation_token`. The RLS helper functions (`fga_list_objects_current`, `fga_list_object_ids_current`, any RLS-facing variant) stay uncapped, because a cap there would silently hide rows from a user.
- **Descriptive errors:** OpenFGA's numeric code stays in `DETAIL`; the message names the actual offending values and every error carries a `HINT` that says how to fix it (allowed user types, the nearest relation name, the call to make first). This covers `rbac_*` errors as well.
- **Cycle semantics stay as implemented:** least fixpoint for positive recursion beneath an exclusion, which differs from OpenFGA v1.22.1.
- **The pg_tle managed-host test is dropped** ("don't worry about the PG TLE"). The Docker install spec stays green; nothing more.
- **The user reached out to the OpenFGA team with the report** (`upstream/openfga-cycle-but-not-inconsistency.md`). No answer yet; if upstream decides the other way, D changes again.
- **Next:** the plan has six phases in order: promote D to the extension, the API decisions, hardening and usage docs (with openfga/language's semantic validation cases as a second oracle), conditions with a CEL parser and evaluator in PL/pgSQL (OpenFGA's 33 ABAC cases as the oracle), a second performance pass, and the loose ends (small and medium benchmarks, the large `parents_proj_select_count` budget).

## Session 5: 2026-10-29, D becomes the extension; caps, pagination and errors

Run as an orchestrator: the main conversation planned and reviewed, and subagents did the work (a cheaper model for phase 1 and the research, a stronger one for phase 2).

### 1. Phase 1: promote D (commit 246fe1f)

`prototypes/d-per-model.sql` moved (with `git mv`) to `pg_permissions--0.0.1.sql`, and the test, bench and Docker scripts now default to it, with A, B and C still selectable. The counts were the same before and after: 37 spec files and 2,164 assertions, locally and on PG 16, 17 and 18, with `03_tle_install` 9/9 (the pg_tle branch really ran, not skipped). A bench smoke on the small scale gave the same checksums as A, B and C. One small trap: the docs site charts every JSON in `bench/baselines/data/`, so the smoke result had to be deleted, or it would have appeared as a baseline.

### 2. Research before code: what OpenFGA does at its limits

A research agent read OpenFGA v1.22.1's source, not just the docs, before any spec was written. Findings that shaped the specs:
- ListObjects and ListUsers truncate at 1,000 **silently**, keeping whichever results were found first (nondeterministic, from concurrent resolution). The 3 s deadline also returns partial results with no signal; there is a `TODO set header to indicate "deadline exceeded"` in the source. So the specs assert the count and that every result is in the true set, never which members survive.
- Write: 100 tuples, counted over de-duplicated writes plus deletes; duplicates are checked first (2004), then the limit (2053 `exceeded_entity_limit`).
- Read: page size 50 by default, 1..100 when given (2000 otherwise); the token is base64url of `"<ulid>|"`. A token that fails the shape check is 2000, one that passes it but won't decode is 2007, and an unknown ulid is no error at all (it seeks past it).

### 3. Phase 2: caps, Read pagination, errors with HINTs (commit 8e0f614)

Orchestrator choices: fixed constant caps (OpenFGA makes them configurable; here they are not, per the "blessed path" direction), no list deadline (callers use `statement_timeout`, which errors rather than returning partial results: a documented deviation), and an opaque token in OpenFGA's shape.

- **Red, then green:** d/30 36/42 → 42/42, new d/34 (limits) 8/49 → 49/49, new d/35 (every raise site) 2/63 → 63/63. Suite: 39 files, 2,276 assertions on PG 16, 17 and 18; OpenFGA consolidated suite still 933/933 and 746/746.
- **Every raise site has a spec row:** 59 sites (7 in `rbac_*`, 49 `_fga_error`, 3 `_fga_unsupported`), plus a guard that scans `pg_proc.prosrc` for a raise without a hint. Mutants (each hint removed on a copy of the file) failed 2 assertions each.
- **The spec found a real bug on its first run:** a malformed user or object in a delete key gave 2017 instead of 2000, because `_fga_split_object()` returns one row of nulls rather than no rows, so a "no rows" check never fired.
- **The cap bit our own benchmark:** the bench seeds wrote 50,000 tuples per `fga_write`, which now raises 2053. They write in batches of 100, so seed times from before phase 2 are not comparable.
- **Paging needed a new column:** D had no ulid or id to page on, so `fga_tuples` gained a `seq` identity column (8 bytes plus an index entry per tuple; the storage and write baselines will move a little, not yet re-measured).
- **`fga_read` broke its API on purpose:** it now returns one row shaped like OpenFGA's ReadResponse (`tuples jsonb, continuation_token text`).
- **Hint text has constraints:** no `auth.` (the identity spec greps function bodies for it) and no `;` (the guard splits statements on it).
- **Caps are output-only:** the walk still computes the full set before the cap applies, which phase 5 could revisit.

### Numbers worth quoting (session 5)
- Phase 1: 37/2,164 before and after the move, on three PG versions.
- Phase 2: 59 raise sites, 63 error assertions, 49 limit assertions; suite 39 files, 2,276 assertions; OpenFGA 933/746 unchanged.

### 4. Phase 3: a second oracle for model validation, usage docs for D (commit 8b56eed)

- **The pin:** openfga/language `f558baa` (`pkg/go/v0.3.2`), the version both openfga v1.22.1 and openfga/cli v0.8.2 require. Of its 93 semantic validation cases, 66 run and 66 pass (33 passed before the new checks). 27 are skipped, each with a reason: 14 the server accepts, 8 conditions (phase 4), 2 modular models (schema 1.2), and 3 the language repo expects to pass but the server rejects.
- **The decisive move was asking the real server.** The vendor script writes every case's model to a pinned `openfga/openfga:v1.22.1` container and records its answer. The language validator turned out stricter than the server (14 duplicate-restriction cases the server accepts with 201). The language repo's own skipped cases contradict each other ("cycle 3–6 should fail" against "union does not require all children to have entry"). The server settles it: `x: [user] or y` with `y: [user] or x` is rejected as a cycle even though both relations have entrypoints. And the CLI transformer validates nothing (schema "0.9", duplicate types and modular models all convert).
- **D had been returning the wrong codes for model writes:** 2005 and 2057, which OpenFGA's WriteAuthorizationModel never returns (`write_authzmodel.go:84-86` maps every validation error to 2056). Our own specs were corrected to match the server.
- **New checks:** entrypoints (least fixpoint), no cycles of computed relations through any operator, reserved type names `self` and `this` (D had accepted them; the oracle caught it), name patterns 2047 and 2050. Mutants: each disabled check fails 1 to 11 oracle assertions. No model in the consolidated suite was newly rejected (still 933/746).
- **Usage docs for D:** `usage/fga.md` (54 spec assertions) and `usage/rls.md` (32), README rewritten, A/B/C pages labelled history. Every example is a spec.
- **Old findings closed:** 22 bullets, 13 not applicable to D, 6 fixed (each cites a spec), 3 carried: the nullable-column restrictive policy, changing a role's permissions without `drop_role`, and RLS-only row attributes.
- **Wrong turn:** the first manual server probe used a one-character store name (it needs 3 to 64), and the resulting validation error hid every model answer.
- **Numbers:** 43 spec files, 2,463 assertions on PG 16, 17 and 18.

### 5. Phase 4a: the ABAC oracle and the conditions design (commit 02571e8)

- **The oracle:** 33 cases and 331 assertions from `abac_tests.yaml` at the same pin (which is exactly tag v1.22.1). 9 use inline `$expression` conditions, which sit behind an experimental server flag, and are skipped. The generated specs stay out of the default run until the evaluator exists; with `--suite` they are all red (0A000).
- **The cases reach a small part of CEL:** six parameter types, `<`, `>`, `==`, `||`, `timestamp("…")` and `ip.in_cidr`. The rest of the standard library appears only in the docs. OpenFGA's docs list `bytes` as a parameter type, and the server rejects it.
- **32 probes against a live v1.22.1 server pinned what the cases don't:**
  - Tuple context beats request context on a shared key.
  - `||` absorbs an error from either side.
  - Check raises 2000 for an erroring edge that is not even on the user's path.
  - ListObjects and ListUsers raise on any edge they walk.
  - A stale stored context is ignored by Check but makes ListObjects fail; the APIs disagree.
- **Measured before choosing (micro-benchmark, tag `cond-eval-micro`):**
  - A jsonb AST walked by a PL/pgSQL interpreter costs 2–3 µs per evaluation.
  - An AST in rows or arrays is slower (3.5–4.5 µs), because PL/pgSQL copies arrays on every recursive call.
  - Compiling to a SQL expression and running it with `EXECUTE` costs 3.4 µs, so no gain.
  - A generated function per condition is 10–25x faster (0.1–0.6 µs), but rejected: runtime DDL turns a quoting bug into SQL injection as the extension owner, breaks `pg_dump` and `DROP EXTENSION`, and fires every event trigger (PostgREST schema reloads on Supabase) on each model write. It is kept as a possible phase-5 fallback.
- **Mishaps:**
  - macOS bash 3.2 dropped the braces inside `"$(f "{...}")"`, so the first probe run silently sent broken JSON.
  - Condition names need at least 2 characters on a tuple but only 1 in a model, so a probe condition named `c` failed every write.
  - Ruby read the value 1.8e309 as Infinity, which JSON can't carry, so a Psych-AST converter keeps numbers as written.
- **Open questions went to the user before any parser code was written.**

### 6. Phase 4b: conditions, with a CEL interpreter in PL/pgSQL (commit 8b70765)

- **The user's calls, before any code:**
  - RLS helpers deny on conditioned edges.
  - OpenFGA's top-down error rule, so Check fails even for an erroring edge off the user's path.
  - A stale stored context is ignored in every API.
  - An approximate cost counter.
- **Smaller calls (the orchestrator's):** inline `$expression` rejected; a conflicting rewrite under `on_duplicate: ignore` becomes 2017; `bytes`, `type()` and `dyn()` rejected at model write.
- **The result:**
  - The ABAC oracle went 302/302 stored and 271/271 contextual on the first run after integration (from 0).
  - In-house CEL specs went from 10/257 to all passing.
  - The fga_lang oracle went to 70/70, with 4 more condition cases running.
  - The consolidated suite is still 933/746.
  - Overall, 53 spec files and 3,337 assertions on PG 16, 17 and 18.
- **Mutants:** every one was caught.
  - Ignoring the condition fails 148 stored, 140 contextual and 87 in-house assertions.
  - Swapping context precedence fails 18, 18 and 24.
  - The "always conditional" fast-path flag mutant is invisible to the oracle; only a white-box spec catches it.
- **The cost limit is 100, as in OpenFGA.** With per-node costs chosen so that `exists` over strings passes at 19 elements and fails at 20, exactly where the live server trips.
- **A subtle catch:** "RLS helpers never take conditioned edges", read literally, would have let a user through a `but not` whose subtract errors. The fix is a mode in which an error counts as true inside a subtract, so the helper fails closed. A spec pins it.
- **Performance:**
  - The unconditioned fast path is unchanged within noise (two runs before, two after, large scale; `parents_select_page` p95 swings 10–20% between identical runs).
  - One `x < 100` evaluation costs about 9 µs end to end (2 µs in the interpreter).
  - ListObjects over 1,000 tuples: 2.0 ms unconditioned, 2.8 ms with a shared condition, 21.8 ms with 1,000 distinct contexts.
  - A false Check on a conditional relation goes from 68 µs to 160–180 µs because of the error walk.
- **PL/pgSQL traps hit along the way:**
  - `if x = case ... then ... end then` breaks (the IF scanner stops at the CASE's THEN).
  - `row(null, ...)` needs casts.
  - Assigning `collate "C"` text to a variable drops the collation.
  - Regex repetition counts cap at 255.
  - psql's `\set` turned the CLI's `<` into `u003c`.
- **Probe surprises:**
  - `getHours("+02:00")` means two hours east, the opposite of Postgres' POSIX reading.
  - A condition with no parameters and any non-empty context is an error.
- **API change:** `fga_check`, `fga_list_objects` and `fga_list_users` take `context jsonb` as their sixth parameter.
- **Left for phase 5:** inside the recursive CTE term, conditions are evaluated per row, not once per distinct context, because a recursive term can't aggregate.

### 7. Phase 5: performance pass 2 (commits 0bd650b, 482aab4, 01b9fc2, 8fe8fcf)

- **Method:**
  - PG 18 in Docker, each configuration run as a back-to-back pair: `opt3-before` (re-measured on HEAD, not opt2) then `opt3`.
  - Both builds are installed from frozen copies of the extension file.
  - Phase 2's `seq` column had already moved large storage from 285 to 323.5 MB.
  - Same-day A/B/C reruns came out 3–24% slower than their session 3 numbers: the machine drifts, so only paired runs are compared.
- **Check:** a partial index on userset tuples and skipping the meet test. `nest_check` 0.41→0.39 ms large, 0.47→0.40 wide; in-server 229→178 µs. The idea carried over from opt2, folding the user probe into the step, made it slower (229→390 µs) and was reverted.
- **Writes:** a typed path without the JSON round trip. `write_share` and `write_nest_team` 0.25→0.16 ms; the large parents seed 33.1→15.3 s.
- **Non-monotone ListObjects:** a set-based evaluator over the rewrite tree. Wide `but not (blocked or muted)` 5,246→7.6 ms, wide `editor and viewer` 621→6.1 ms.
- **Rejected with numbers:**
  - Dropping one tuplestore saves ≤0.3 ms.
  - `distinct` instead of the min-level `group by` is invisible through pgbench.
  - Cyclic userset data is 3.3x slower on a 2-cycle at every inner team, and no exact alternative was found.
- **Conditions:**
  - The flagged suspect (per-row evaluation in the recursive term) was real but small: 205→2 evaluations per wide ListObjects.
  - The big win was a quadratic correlated `IS NOT DISTINCT FROM` match in the leaves and steps: in-server ListObjects with one context per tuple 3,203→167 ms, ListUsers 29–37 s→0.6–1.0 s.
  - Through pgbench, wide conditioned ListObjects costs 10.6 ms against 5.0 for its plain twin.
- **Covering index (`include (object_id, condition_name)`): measured, left for the user.**
  - It costs +120 MB at large (323.7→444.1) and gives no gain through pgbench (4.90 vs 4.85 ms), -7% in-server.
  - It flips a plan that turns large `plain_list_users` from 0.35 to 12.95 ms.
  - Recommendation: don't adopt.
- **Mishaps:**
  - The first "before" batch was contaminated by editing the extension file mid-run: a wide intersection showed 8.6 ms against a true 630. Every run since uses a frozen copy.
  - A cold cache after a server restart looked like a 2x regression.
  - A noisy run an hour before its pair showed fake regressions, hence the paired runs.
- **Safety:**
  - Checksums are identical to A, B and C in every run.
  - All 15 mutants are caught; 4 survived at first, and specs were added to catch them.
  - 55 spec files and 3,604 assertions on PG 16, 17 and 18.
  - The oracles are unchanged: consolidated suite 933/746, ABAC 302/271, fga_lang 70/70.
  - Budgets are unchanged; the only miss is the large `parents_proj_select_count` (9.35 > 9 ms), which every engine shares.

### 8. API naming pass (commit c90853b)

- **The trigger:** reading the code, the user noticed the RBAC functions had no `rbac_` prefix while the tables and every `fga_*` function did. That contradicted the session-4 decision itself. The RBAC API predates the per-model direction: it was designed when `has_permission` was meant to be *the* check, and was never renamed. Options offered: prefix every model-specific function (chosen), one schema per model (`rbac.has_permission`: an extension owning several schemas is awkward, and generic schema names collide), or leave RBAC unprefixed as the "blessed path".
- **The user asked about cost before agreeing to named arguments.** Measured on a scratch cluster: EXPLAIN shows the identical expression for positional and named calls (Postgres resolves names at parse time), and 1M calls took 235–265 ms either way. Postgres can't *require* named calls, so the parameter names were made worth using instead.
- **The renames:**
  - All nine RBAC functions became `rbac_*`. Only `current_subject_id`, `current_subject_type` and `delete_subject` stay unprefixed, as genuinely cross-model.
  - All `p_` prefixes are gone, and the shared vocabulary is `object`, `relation`, `role`, `permission`, `scope`, `context`, `model_id`, `page_size`.
  - OpenFGA's `user` became `subject`, because `user` is a reserved word and `fga_check(user => …)` doesn't parse. RBAC keeps `user_id` (a bare id, matching its column).
  - The plan-time-guard parameter is now honestly named `plan_time_guard`.
- **Safety in the bodies:** every parameter is qualified with the function name, and `variable_conflict = error` is left on, so a missed clash raises rather than silently reading a column. In SQL-language bodies the column silently wins, so everything there is qualified too.
- **The guard spec `d/04_api_naming` (34 assertions; 6/34 on the old file).** It `PREPARE`s every public function with all-named `null` arguments built from the catalog, which proves every name parses without running anything. Bite checks: an un-renamed `has_role` fails 3 assertions, and a `"user"` parameter or a `p_` prefix fails 5.
- **Traps:**
  - Col_name keywords also fail as `name => value`, but type_func_name keywords parse (the opposite of the first guess).
  - `proargtypes` is 0-based while `proargnames` is 1-based, which misindexed every argument in the first draft.
  - PL/pgSQL rejects an IN and an OUT parameter with the same name (SQL functions allow it), so `fga_read` uses `inout continuation_token`.
- **Prototypes stay frozen:** the shared RBAC specs still test A, B and C under the old names, and the extension carries renamed copies in `test/spec/d/`. Prototype counts are unchanged (A 426, B 504, C 511 assertions).
- **Mechanics:** about 360 doc and spec calls were converted to named style by a small parser aware of quotes, dollar-quoting and comments.
- **Numbers:** 56 files and 3,638 assertions on PG 16, 17 and 18. The oracles are unchanged, and D's bench equivalence TSV is byte-identical to before the rename.

### 9. Phase 6: loose ends (commit 68b65d5)

- **What was run.** Small, medium and large default shape, D (the extension at `f5a25a7`, after the rename) and A, B, C, on PG 18.6 in Docker, one run at a time, tag `p6`; then one more large D run with `--check` after the budget change (`p6check`). The bench scripts needed no change after the rename (the d seed and workloads were already moved in the naming pass). No SQL changed, so the test matrix wasn't rerun. Reports: `bench/baselines/pg18-docker-{d,a,b,c}-{small,medium,large}-default-p6.md`.
- **Small and medium, the numbers worth quoting** (`D.md`, Phase 6):
  - D misses no budget at small or medium. At medium and large it is within 1.1x of the best engine on every read except Check; at small it is 1.0-1.4x (0.03-0.07 ms).
  - The single-branch policy opens up with scale: D's `parents_select_count` p50 is 0.40 / 0.91 / 7.76 ms at small / medium / large; A's is 2.52 / 6.26 / 69.89, B's 1.11 / 3.67 / 21.21, C's 0.63 / 2.03 / 11.45.
  - Check is the one place D trails: `nest_check` 0.37-0.38 ms at every scale against 0.25-0.34.
  - Writes: D 0.13-0.15 ms at every scale. C's nest write is 32 / 45 / 54 ms.
  - Storage through nesting: D 6.3 / 40.6 / 323.7 MB, A 6.5 / 48.6 / 404.3, B 6.5 / 46.4 / 377.9, C 5.1 / 27.8 / 183.2.
  - Checksums identical across all four designs at all three scales.
- **Mishap: the first small batch was thrown away.** The machine was busy (host load average 15-21, a second unrelated Supabase stack, `supabase_*_agar`, started up during the C run and the medium D run that followed). Every engine had p95s 2-5x its p50: A, B and C missed 11, 6 and 11 budgets at small, D one. I killed my driver script, removed the one contaminated JSON, polled `docker stats` for about 11 minutes until the other stacks were idle, and reran everything. My own stack was stopped with `compose down`; the others were not touched. The lesson for the post: a budget table is only as good as the quietest hour you can find, so record `docker ps` and load next to every run, and rerun when they disagree with the numbers.
- **The budget.** The large `parents_proj_select_count` budget (9 ms) was set on a 16.4 laptop that skipped the heap fetch for all-visible pages; every patch release since reads all 10,900 pages. Over the 27 large reports on PG 16-18 that existed, p50 was 7.48-9.43 ms for every engine and p95 8.21-16.10 ms, and it missed 22 times. One more D run showed how noisy the tail is: the same file gave p95 9.35 (opt3), 13.25 (`p6`) and 8.24 ms (`p6check`) with p50 within 0.4 ms. Chosen 20 ms for every engine: above every p95 measured, 2.1x the worst p50, and stricter than the 25 ms the 3x-fastest-p95 rule gives. `--check` at large passes for D. Pinning the budget to the p50 floor would have failed on host noise, which is the whole reason p95 budgets are loose.
- **DECISION.md.** "What hasn't been measured" is split into closed (small and medium, conditions and non-monotone costs, nesting and deletes for D, the budget) and still open (hosted pg_tle, durability, concurrency mixes, D on PG 16 and 17, confidence intervals, the huge-visibility user, role churn). Open questions 1, 4, 5, 6 and 8 are closed with the measurement that settles them. New question 11 is the covering index, awaiting the user: +120 MB at large, no pgbench gain, don't add.
- **Angle for the post:** the benchmark that matters most for an extension that composes models is the one where the data model decides the cost (the single-branch policy: 0.4 ms at small, 7.8 ms at large for D against 70 ms for A), and the one that matters least is the one a Postgres patch release changed under every engine at once.

## Session 6: 2026-11-01, release docs in Simplified Technical English

### 1. The covering index is closed

- The user agreed with the recommendation: no `include (object_id, condition_name)` index. DECISION question 11 is closed with the numbers (+120 MB at large, no pgbench gain, a plan flip that takes large `plain_list_users` from 0.35 to 12.95 ms).

### 2. The docs split: user docs and research

- **The ask:** clean up the docs for a release. Everything about how the extension was built goes in a "research" section; the rest is plain user-facing docs; every doc follows ASD-STE100 Simplified Technical English.
- **The layout.** `docs/` is the user half: install, RBAC, FGA, conditions, RLS, a full function reference (26 public functions) and errors and limits (42 errors, each with its fix). `research/` is the history: an overview that tells the whole story, plan, goals, decision, the four designs, the three prototype guides, the benchmark summaries, the upstream OpenFGA report and this journal (moved from `JOURNAL.md`). The SQL prototypes stay in `prototypes/` because the test and bench scripts load them by path.
- **Scope questions asked first.** The journal keeps its own voice (it is blog material, and an STE rewrite would flatten it); generated bench reports keep the harness format; the A/B/C prototype guides (about 3,600 lines) were rewritten in full, not summarized, at the user's choice. The Starlight site was rebuilt to match: user pages first, Research collapsed at the end.
- **STYLE.md** holds the rules as they apply here: sentence limits (20 words for instructions, 25 descriptive), no `-ing` verb forms, the active voice, a replacement table (`allow` → `let`, `ensure` → `make sure`, `via` → `through`), and the list of technical names that STE lets through (Postgres objects, SQL, authorization terms like tuple and relation). Without an STE dictionary, "approved word" can only be approximated; the table of common swaps and a lint script did most of the work.
- **How it ran.** One mechanical pass first (git moves, a link fixer, the site sidebar: 136 links broke in the move, all fixed), then eight agents in parallel on disjoint file sets, then one integration pass. Each agent wrote its own STE lint script; three of them collided in the same `/tmp` directory and overwrote each other's helpers, a small lesson in giving parallel agents their own scratch space.

### 3. What rewriting in STE found

- **Running the examples is the real test of user docs.** Every SQL example in the user pages (about 250 statements in install, RBAC and RLS, 67 blocks in FGA, conditions, reference and errors) was run in order on a throwaway cluster. Mismatches found and fixed: `rbac_drop_role` names every heir in its error, a second install fails on a function before a relation, the typo checks in `fga_check_current` raise only when a subject is set (anonymous requests return false), an RLS example read its model with `\set model \`cat model.json\`` that no reader could run, and `fga_list_objects` for Erin returns one more document than the old text claimed.
- **A more exact rule for conditions in RLS.** The session-5 summary said "RLS helpers deny on conditioned edges". The SQL is more precise: a conditioned tuple counts when its condition is true from its stored context alone, and is denied when it needs a request parameter. The docs now say that.
- **Stale facts surfaced by the rewrite:** the site home page still said 37 spec files and "attribute rules later"; a prototype guide miscounted policies; a design doc said "three axes" over a four-column table and had items numbered 8, 9, 10, 13, 11, 12.
- **An honest correction of the orchestrator's brief:** the brief said D was benchmarked on PG 16/17/18. It was benchmarked on 18.6 only (the test suite runs on all three). The agent followed the sources, not the brief.
- **Terminology:** "engine" and "design" were used interchangeably for A–D; the research docs now say "design" (217 lines changed), keeping "engine" in code identifiers and fixed titles. "Gotchas" is not STE; it became "Warnings and limits" everywhere.
- **Paragraph limits are blunt.** 150 research paragraphs ran past six sentences. They were split by script and spot-read; the splits fall on sentence boundaries but sometimes separate a claim from its reason.

### 4. Release fixes in the extension

- **Install through database.dev or directly.** The docs now offer both. The dbdev in-database client (`dbdev.install(...)`) is deprecated; the current flow is the CLI: `dbdev add -o ./migrations -v 0.0.1 package -n kiwicopple@pg_permissions`, then run the generated migration, which calls `pgtle.install_extension` and `create extension "kiwicopple@pg_permissions" version '0.0.1'`. The old README's `with schema extensions` is harmless but misleading: measured on PG 17 with pg_tle, `pg_extension` records the `extensions` schema while all 93 functions land in `permissions`, because the script qualifies everything. The docs say to leave it out.
- **Null arguments in RBAC writes.** `rbac_create_role(role => null)` raised a bare 23502 with no hint, and `permissions => null` or `inherits => null` silently made a role with nothing. All three now raise `22004` with a HINT; `'{}'` stays valid for a role that only inherits. `rbac_unassign_role` got the same checks. The read functions keep returning false on null.
- **A CEL hint said "pg_permissions' CEL has no bytes …" and then "pg_permissions' CEL leaves out bytes …".** Four hints now say it once, ending with `(see docs/conditions.md)`; the old tail pointed to a design doc path that users never had.
- **Numbers:** 56 spec files and 3,646 assertions (+8) on PG 16, 17 and 18; site build with 3,677 internal links all resolving; 510 relative links in the repo, none broken.

### Angle for the post

- STE as a forcing function: rewriting docs into a controlled language meant re-reading every claim, and running every example found more drift than the rewrite itself. The docs that had been "done" since session 5 still disagreed with the extension in six places.

## Session 7 (2026-11-01): planning the `permissions` JS library

- **The ask:** an npm package `permissions` (the user owns the name and permissions.dev) that talks to the extension, built like supabase-js: standalone sub-libraries composed by one `createClient`, with the API as close to Supabase's as possible.
- **Research, in two parallel agents.** One mapped the extension surface: 26 public functions, only 9 granted to PUBLIC (the current-subject checks), identity from the JWT `sub` or `permissions.subject_id`, stable DETAIL codes. The other read supabase-js as it is now: an Nx and pnpm monorepo, tsdown dual builds, `{ data, error }`, `PostgrestError { message, details, hint, code }`, `auth.admin.*`, one fixed version, and some admitted inconsistencies (constructor shapes, `fetch` versus `customFetch`).
- **The shape that fell out.** The extension has no HTTP server, so a "standalone library" here means a client plus a transport. The user chose: SQL for everything server side, PostgREST only for client-side checks. That maps cleanly onto the grants: the PostgREST client has no `admin` namespace at all, so no service key ever goes over HTTP.
- **Naming constraint.** The user owns `permissions`, not an `@permissions` scope, so the "collection of libraries" became subpath exports (`permissions/rbac`, `permissions/fga`, `permissions/sql`, `permissions/postgrest`) in one package, with Vitest instead of Jest and no Nx.
- The plan is in `pg_permissions/js/PLAN.md`.

### Angle for the post

- The grant list decided the client architecture. Nine PUBLIC functions is exactly the browser API; everything else is the server API. The library did not need its own permission model, only to respect the one the database already enforces.

### Implementation, same session

- **Six phases, five implementer agents, one reviewer.** Scaffold and transports first (one agent, because everything else depended on the `Transport` interface and the probe results). Then RBAC and FGA in parallel on disjoint files and disjoint tables of one shared test database: each suite reset only its own model's state. Then the umbrella, then docs and an independent review in parallel.
- **Probing before building paid off.** The first agent ran every return shape through a real PostgREST and a real `pg` driver and wrote `test/NOTES.md`: void is a 204 with no body over HTTP and `''` over pg, `bigint` arrives as a string, `fga_read`'s OUT/INOUT record is one object, not an array, `plan_time_guard` stays hidden. The later agents built against facts, not guesses.
- **Parallel agents diverge on taste.** RBAC and FGA both had to hide `admin` on PostgREST clients; one used constructor overloads and a second client type, the other a conditional type on the transport kind. Phase 5 unified them on the conditional type and added a third kind, `'subject'`, for `as()`: those calls run as the end user, so they get no `admin` either.
- **The review found a real leak.** Two transports over one `pg.Client` each had their own serial queue, so `alice` and `bob` subject transactions interleaved on the wire (`begin, begin, set alice, set bob, query`) and both calls answered `bob`. The queue is now per connection (a `WeakMap`), a failed rollback poisons the connection, and Node errno codes like `EPIPE` no longer pass as SQLSTATEs.
- **Numbers:** 133 unit tests, 45 integration tests (Postgres 17 + PostgREST 16.5 in Docker), ESM index 2.5 kB gzip, CDN bundle 5.5 kB gzip. Nothing published; `0.2.0` waits for the user.

### Angle for the post

- A client library for an authorization extension is mostly a translation layer, and its hard bugs are the same as the extension's: who is the subject right now. The leak lived in connection handling, not in any permission logic.
