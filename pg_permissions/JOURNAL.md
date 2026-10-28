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
