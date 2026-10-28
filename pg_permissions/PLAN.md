# pg_permissions: Plan

> Status: draft for discussion. The extension itself isn't implemented yet; prototypes of Designs A and B are in [`prototypes/`](./prototypes/).
>
> This document holds the goals and requirements every design must meet. The candidate designs are in [`designs/`](./designs/). The requirements are turned into executable goals in [`GOALS.md`](./GOALS.md) and [`test/`](./test/).

## Goal

A single Postgres extension that can express several authorization models (RBAC, Zanzibar/FGA-style relationships, and later attribute rules), so each application picks the model that fits instead of installing a different extension per model.

Constraints, same as the rest of this repo:

- Pure SQL / PL/pgSQL, installable as a Trusted Language Extension (`superuser = false`), published on database.dev.
- Every check is usable inside RLS policies.
- Not tied to Supabase. It works with Supabase out of the box, but nothing references the `auth` schema.

## 1. Review of the existing ideas

There are four open RFC PRs in this repo, each proposing a separate extension:

| PR | Extension | Model | Core storage | How it finds the current user |
| --- | --- | --- | --- | --- |
| #7 | `pg_zanzibar` | ReBAC (Zanzibar) | `tuples(object, relation, subject[#relation])` + `relation_configs(implied_by[])` | `auth.uid()`, then `zanzibar.subject_id` setting |
| #8 | `pg_abac` | ABAC | `subject_attributes`, `policies`, `policy_rules(attr, op, value)` | `abac.subject_id` setting, then `current_user` |
| #9 | `pg_cel` | CEL expressions + RBAC/ABAC helpers | Mostly stateless; optional `policies(expression)` | JWT claims (`request.jwt.claims`) |
| #10 | `pg_cedar` | Cedar (permit/forbid) | `entities(attributes jsonb)`, `entity_parents`, `actions`, `policies` | `cedar.user_id` setting |

What they have in common:

1. **Each one reinvents identity.** There are four different ways to answer "who is the current user?", and one of them (#7) hard-codes `auth.uid()`, which fails on non-Supabase databases.
2. **Each one reinvents "subject is related to object".** Zanzibar tuples, Cedar `entity_parents`, ABAC role assignments and group membership are all the same shape: `(object_type, object_id) --relation--> (subject_type, subject_id)`.
3. **They differ mainly in how a decision is computed:** graph walk (Zanzibar), attribute rules (ABAC), expressions (CEL), or ordered permit/forbid (Cedar).
4. **They share the same RLS performance problem.** #7 makes the important point: a per-row `check()` in a policy runs once per row. A "list the IDs I can access" function wrapped in `(select ...)` runs once per query. This has to be a first-class part of the API.

Takeaway: whichever design we choose should have **one identity layer**, **one way to model "subject is related to object"**, and a **first-class RLS fast path**. The designs in `designs/` disagree on how to get there.

## 2. Proof-of-concept scope

The first version must support these models in one extension. Implementing two genuinely different models proves the "one extension, many models" goal. The examples below describe behaviour, not storage; each design decides how to store them.

### Model 1: RBAC (global or per-tenant)

- Roles are scoped to a tenant/org, or app-wide.
- Roles form a hierarchy: `owner` > `admin` > `member`. Permissions such as `edit_documents` are granted to one or more roles.
- Example: Alice is an admin of Acme, so she can edit every Acme document.

### Model 2: ReBAC / Zanzibar-lite (fine-grained)

- Per-object relationships: Bob is an editor of the `readme` document.
- Implied relations on the same object: `editor` implies `viewer`.
- Groups: every member of team `eng` is a viewer of `readme`.
- Nested groups, with recursion capped at a maximum depth (default 10).

### Model 3 (stretch): attribute conditions

- Access that depends on attributes of the subject, resource or request (for example "only published documents", or a grant that expires).
- No CEL parser in v0.0.1.

### Explicitly out of scope for v0.0.1

- A CEL parser, Cedar `forbid` policies and priority ordering (but the design must show where they would fit).
- Parent inheritance ("viewers of a folder can view its documents"). The first item for v0.0.2, so the design must show how it would be added.
- Zookies / replica consistency, audit logging, caching.

## 3. Identity requirements

- The extension must not store users or reference the `auth` schema.
- It must resolve the current subject without configuration on Supabase (PostgREST sets `request.jwt.claims`; its `sub` claim is what `auth.uid()` returns) and with an explicit session setting on plain Postgres.
- Contract, fixed by `test/spec/01_identity.sql`: `permissions.current_subject_id()` returns the JWT `sub` if present, otherwise the `permissions.subject_id` setting, otherwise null. `permissions.current_subject_type()` defaults to `'user'`. The JWT wins, so nothing else in a session can override the subject of a request that carries one.
- Explicit-subject variants must exist for tests and server-side jobs, and must be **admin-only**. If clients could call them, any user could ask what any other user can access.
- Apps need a documented way to clean up permissions when a user is deleted from their identity table.

## 4. RLS requirements

- All checks are STABLE and safe to call from RLS policies.
- There must be a fast path for SELECT on large tables that doesn't call a function once per row (for example a "list accessible IDs" function wrapped in `(select ...)`), plus a simple per-row check for single-row writes.
- Clients must not be able to write permission data directly.
- **The RLS fast path is `col = any (array(select unnest(f())::uuid))`.** Two other ways of writing it look right but aren't, both measured on Postgres 16 with 1M rows:
  - `col = any ((select f()))` is parsed as a subquery comparison and fails with `operator does not exist`, even with the double parentheses. The original Zanzibar RFC (#7) has this bug.
  - `col = any ((select f())::uuid[])` works, but Postgres re-applies the `::uuid[]` cast to the parameter on every row it filters. A page of 50 documents took 3.64 ms instead of 0.73 ms.
  - `col in (select unnest(f())::uuid)` (a hashed subquery) stops Postgres using the column's index: counting a user's visible documents took 88.8 ms instead of 2.2 ms.

## 5. Reference scenario

Every design must show this scenario end to end (schema, setup SQL, RLS policies), so the designs can be compared side by side:

- Org `acme`. Alice is an `admin`, Carol is a `member`. Admins can edit all of the org's documents; members can view them.
- A `documents` table with `id uuid` and `org_id uuid` columns.
- Document `readme`: Bob (not in the org) is an `editor`. Team `eng` (members: Carol and Dave) are `viewer`s.
- `editor` implies `viewer`.
- Queries to answer: Can Bob update `readme`? Which documents can Dave select? Who can view `readme`?

## 6. Blessed path and model presets

The extension should offer a **blessed path**: a developer picks a model preset and only learns the concepts that preset needs. Presets are a layer of functions on top of whichever engine we choose. The engine is never visible to a developer who stays on the RBAC preset.

### Presets

| Preset | For | Concepts the developer learns |
| --- | --- | --- |
| `rbac` | Most apps: app-wide roles, optionally scoped to a tenant/org | Roles, permissions, scopes |
| `zanzibar` | Per-object sharing, groups, nested teams | Object types, relations, groups (the engine's full API) |

Later presets (attribute conditions, Cedar-style policies) follow the same pattern.

Rules for every design:

- **Both presets write to the same core data.** An app that starts on `rbac` and later needs per-document sharing adds the `zanzibar` functions without migrating anything. Its RLS policies gain an extra `or` branch.
- **The `rbac` preset API is identical in every design.** Only the implementation underneath differs. That keeps the engine swappable, and backwards compatibility with earlier drafts isn't a concern.
- **Plain names.** A developer on the `rbac` preset never sees tuples, relations, policies, `via`, or a model file.

### The `rbac` preset API

User and scope IDs are shown as `text`. A design with typed IDs (Design C) uses `uuid`.

```sql
-- Define roles. A role grants permissions and can inherit other roles' permissions.
permissions.create_role(role text, permissions text[], inherits text[] default '{}')
permissions.drop_role(role text)

-- Assign roles. scope = null means app-wide; otherwise a tenant/org ID.
permissions.assign_role(user_id text, role text, scope text default null)
permissions.unassign_role(user_id text, role text, scope text default null)

-- Checks for the current user (STABLE, safe in RLS)
permissions.has_permission(permission text, scope text default null) returns boolean
permissions.has_role(role text, scope text default null) returns boolean
permissions.scopes_with_permission(permission text) returns text[]   -- RLS fast path for tenant scoping

-- Admin and debugging (not callable by clients)
permissions.user_permissions(user_id text, scope text default null) returns text[]
permissions.users_with_role(role text, scope text default null) returns setof text
```

Behaviour the tests pin down (`test/spec/1x_*.sql`):

- `create_role`, `drop_role`, `assign_role` and `unassign_role` are admin-only.
- `has_role` is true for a role held directly or through inheritance (an editor "has" viewer).
- Unknown permission or role names return false rather than raising, so an RLS policy that names a dropped permission denies instead of breaking every query.
- `drop_role` fails while another role inherits it, and removes the role's assignments.
- Role names and permission names can't overlap.

**App-wide and scoped roles are kept separate.** `has_permission(p)` checks only app-wide roles, and `has_permission(p, scope)` checks only that scope. An app that wants "app-wide admins can do anything in any tenant" writes both checks in its policy. This keeps the rule explicit: there's no hidden inheritance between scopes.

### RBAC scenario

Every design must also show this scenario, written **only** with the preset API above, and then show what happens underneath:

1. **App-wide roles.** Roles: `viewer` (`documents.read`), `editor` (`documents.edit`, inherits `viewer`), `admin` (`documents.delete`, `users.manage`, inherits `editor`). Alice is `admin`, Bob is `editor`, Carol is `viewer`.
2. **RLS on `documents`:** SELECT needs `documents.read`, UPDATE needs `documents.edit`, DELETE needs `documents.delete`.
3. **Tenant-scoped variant.** Same roles, but assigned per org: Alice is `admin` of `acme`, Bob is `editor` of `acme` and `viewer` of `globex`. RLS uses `documents.org_id`.
4. **Graduation.** Later, the app shares one `acme` document with Dave (not in any org) as an editor, using the `zanzibar` preset. Show what changes in the data and in the RLS policies, and confirm the RBAC data is untouched.
5. **Queries:** Can Carol edit documents? What permissions does Bob have in `globex`? Who are the admins of `acme`?

## 7. Evaluation criteria

| Criterion | Question |
| --- | --- |
| Model flexibility | How naturally does it express RBAC, ReBAC, attributes, and later CEL/Cedar? |
| RLS performance | Cost of a SELECT over 1M rows, and of a single-row check. Read vs write cost. |
| Simplicity | How much SQL does an app developer write for the reference scenario? How much code is in the extension? |
| Blessed path | How cleanly does the `rbac` preset (§6) map onto the engine? Can an app graduate to `zanzibar` without migrating data? |
| Correctness and safety | Default deny, cycle handling, no dynamic SQL injection, clients can't escalate. |
| Identity decoupling | Meets §3 without special cases. |
| TLE fit | Pure SQL/PL/pgSQL, no superuser, works through dbdev. |
| Evolvability | Cost of adding parent inheritance, conditions, CEL, Cedar later. |

## 8. Candidate designs

| Design | Approach |
| --- | --- |
| [A: Shared tuple core](./designs/a-tuple-core.md) | Zanzibar-style tuples in one generic table with `text` IDs. Decisions computed at read time by a recursive CTE. |
| [B: Policy-first](./designs/b-policy-first.md) | Cedar-style `policies` table decides everything. Roles, groups and parents are plain data. Group and role closures are precomputed on write. |
| [C: Compiled model](./designs/c-compiled-model.md) | A JSON model is compiled into lookup tables. Group membership is materialized by triggers. Typed, `uuid`-only IDs. |

### Comparison

Each design's own "weaknesses" section has the details. This table summarizes them against §7.

| Criterion | A: Tuple core | B: Policy-first | C: Compiled model |
| --- | --- | --- | --- |
| Model flexibility | RBAC and ReBAC natural. Forbid and conditions need a policy layer that isn't designed yet. | Widest: RBAC, ReBAC, conditions and forbid are all policy shapes. Policies are limited to shapes that can become SQL filters. | RBAC and ReBAC natural, with OpenFGA-like types. Forbid as an exclusion list. Resource conditions are left to RLS. |
| Read cost | Recursive walk per check. Grows with group nesting. | Flat joins, no recursion. | Flat joins, no recursion. |
| Write cost | 1 row per grant. Nothing to maintain. | 1 row per grant. Group nesting writes closure rows under a global lock. | 1 row per object grant. Group nesting writes membership rows under a global lock. `repeatable read` rejected for those writes. |
| Org-wide access (reference scenario) | Two-arm RLS policy until parent inheritance. `list_subjects` misses org-derived viewers. | First-class (`via => 'org'`). `who_can` returns everyone. RLS must mirror each `via`. | Two-arm RLS policy until parent inheritance. `who_can` must be unioned by hand. |
| Simplicity for app developers | One concept (tuples). Smallest extension. | Two concepts (facts and policies). | One model file plus grants. The extension's write path is the most complex of the three. |
| Blessed path (`rbac` preset, §6) | Thin wrappers (about 50 lines). Roles defined twice (`app` and `tenant`). RBAC checks still use the recursive walk, though it's tiny. **Tested end to end**, including RLS and graduation. | Maps one to one: inheritance is `role_implies`, permissions are actions. Generated policies need a `managed_by` marker. Graduating introduces policies. Tested with a minimal stand-in evaluator. | RBAC is its cheapest path: one lookup, no triggers. Each `create_role` is a new model version. UUID only. Name rule had to allow dots. Tested with a hand-compiled catalog. |
| Validation | Weak: relation names only. | Roles declared per type. | Strongest: typed subjects, unknown names raise. |
| IDs | `text`, array cast to `uuid[]` in RLS. | `text`, cast to `uuid[]` in RLS. | `uuid` only, no casts. Other key types need a mapping table. |
| Drift risk | None: nothing is derived. | Closure tables can drift (triggers). | `memberships` can drift (`verify`/`rebuild` provided). |
| Familiarity | SpiceDB / OpenFGA. | Cedar. | OpenFGA. |

### What the three designs tell us

- **B and C independently chose to precompute group membership at write time.** This points at A's main weakness: recursion on every read. It also means B and C share the hardest part to build (closure maintenance, concurrency, drift).
- **The `rbac` preset works the same on all three engines.** The identical preset API (§6) ran on each design and gave the same answers to the RBAC scenario. For developers who stay on RBAC, which is most apps, the engine choice is invisible. The choice only matters for performance and for apps that graduate to per-object sharing.
- **A and C have almost the same `zanzibar`-level API** (`grant`/`revoke`, check, list accessible IDs, list subjects). C is close to "A with a typed model and a materialized membership index". We could ship A's engine first, then add C's precomputation behind the same functions if benchmarks show the read-time walk is too slow. B's `zanzibar`-level API is different (policies plus role grants), so that part is a choice to make up front.
- **All three handle org-wide access through the app's `org_id` column in RLS.** None of them copies 1M documents into the permission tables. B makes this first-class; A and C get there with parent inheritance in v0.0.2.
- **The real decision is relationship-first (A/C) or policy-first (B).** Relationship-first is simpler and familiar to FGA users. Policy-first has a better home for forbid, conditions, CEL and Cedar, but costs a second concept and a coupling between policies and RLS.

### How to decide

Because the `rbac` preset API is the same for every engine, the blessed path can be built and documented now, before the engine is chosen.

The test suite and benchmark harness now exist (`test/run.sh`, `bench/run.sh`, goals in [`GOALS.md`](./GOALS.md)). First results, from Prototype A at 1M documents, 10k users and teams nested about 5 levels deep:

- **Design A's read-time walk is fast enough at this scale.** Every workload has p95 under 2.5 ms, including the two-branch sharing policy. The recursion B and C avoid costs well under a millisecond here. Full report: [`bench/baselines/a-tuple-core-large.md`](./bench/baselines/a-tuple-core-large.md).
- **The biggest performance factor so far was how the RLS policy is written, not the engine** (§4: a per-row cast made pages 5× slower).

Remaining steps:

1. Build Design C's prototype (materialized memberships) and run the same benchmark, plus a write workload that nests a 1,000-member team, which is where A and C should differ most.
2. Try deeper or wider group graphs (more teams per user, deeper nesting) to find where A's walk stops being cheap.
3. Decide whether forbid and attribute conditions are needed in the first year. If yes, B's policy model should be the starting point. If no, use A/C.

## 9. Open questions (all designs)

1. **Schema name**: `permissions`, or something less likely to clash with app schemas? Also confirm how pg_tle / dbdev handles a fixed schema versus `with schema extensions`.
2. **Who may grant?** Should the extension ship a convention for who can grant what, or leave it to the app?
3. **Public access** (`user:*` in OpenFGA terms): in v0.0.1 or later?
