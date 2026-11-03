---
title: "pg_permissions: Authorization for Postgres"
description: An authorization store and check engine for Postgres, with RBAC, OpenFGA and Cedar. Call it from your application, with optional Row Level Security integration.
date: 2026-11-02
author: Paul Copplestone
draft: false
---

I've been working on `pg_permissions`, an authorization store and check engine for Postgres. It supports role-based access control (RBAC), OpenFGA-compatible relationships, and Cedar policies. You can store permissions, manage them through SQL or JavaScript, and check access from your backend.

If you're already using Postgres, this gives you an alternative to running a separate authorization service. You can also use the functions in Row Level Security policies if you want the database to enforce access on tables. RLS is optional.

The entire extension is written in SQL and PL/pgSQL. It runs on Postgres 16, 17 and 18, and you can [install it from a single SQL file](/install/) without superuser rights. There's no C module to compile or separate authorization service to run.

If you want to try it, the [quickstart](/get-started/quickstart/) walks through assigning a role and checking a user's permissions. I'll cover the design below, including some of the things we learned while building it. The [source](https://github.com/kiwicopple/pg-extensions/tree/main/pg_permissions) includes the prototypes, tests and benchmark harness.

## Why build this?

I think authorization should sit close to your data. Most permission checks depend on information you already store: who owns a document, which organization it belongs to, or whether someone is a member of a team.

If that data is in Postgres, it makes sense to evaluate the permissions there too. You avoid round trips to another service, and you can update permissions in the same transaction as your application data.

This is particularly useful when you're fetching a list. “Can Alice read this document?” is a simple check. Fetching the next 50 documents Alice can read, sorted by their last update, involves filtering, sorting and pagination. Postgres can do all of that together with the permission check.

Of course, running authorization in SQL adds work to your database. A dedicated engine might evaluate a rule faster than PL/pgSQL. I think avoiding the network calls and data movement makes this a worthwhile tradeoff for many Postgres applications. The thing to measure is the time it takes to return the data the user can access.

There's also a usability benefit. I wanted developers to have established authorization models and useful functions to call, without building a permission system from scratch. You can use the results in your backend, or connect them to [Row Level Security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html) when you want enforcement on table queries.

## Choosing an authorization model

The extension has three models. You can use whichever fits your application, or combine them.

### Roles and permissions

RBAC is a good starting point if your application has roles like “admin”, “editor” and “viewer”. Give the editor role a `documents.edit` permission, then assign that role to a user.

Assignments can apply to the whole application or a single tenant. Alice can be an editor in Acme and a viewer in Globex. Roles can also inherit permissions from other roles.

### Relationships with OpenFGA

For something like document sharing, you usually need more detail. A user might have access because someone shared a document with them, because they're in a team, or because they have access to the folder containing the document.

The OpenFGA model handles these relationships. Teams can contain other teams, and documents can inherit access from folders. The `fga_*` functions also support CEL conditions, so you can do things like create a share which expires.

### Policies with Cedar

Cedar lets you write `permit` and `forbid` policies using attributes of the user and resource. For example, here's a policy which lets a document's owner edit it:

```text title="Cedar policy"
permit (
  principal,
  action == Action::"edit",
  resource is Document
)
when { resource.owner == principal };
```

The `owner` attribute is an entity reference. Your backend can construct it from the document's `owner_id` and pass it into the check. I like this part: the ownership data stays in your existing column. The extension doesn't need to look it up in your application tables or maintain a second copy. Other information, like team membership and folder ancestry, lives in stored Cedar entities.

Cedar's admin check can also use trusted request context, such as an MFA result. The current-subject functions don't accept request context from clients. There's a complete example in the [Cedar walkthrough](/models/cedar/overview/). These are Cedar authorization policies; you don't need to create Postgres RLS policies to use them.

### Combining models

You might use RBAC for organization roles and OpenFGA for individual document shares. Each model has its own tables and API, with a shared subject identity.

Your backend can combine their results: allow access through either a role or a share, for example, while still rejecting a suspended user. If you choose RLS, permissive policies combine with OR and restrictive policies combine with AND to enforce that combination on a table.

A Cedar `forbid` only overrides Cedar permits. If you want a deny to apply across models, enforce it in the backend's combined decision or in a restrictive RLS policy. The [combined-model example](/rls/combine-models/) shows the RLS approach.

## Checking permissions from your application

Once you've stored your roles and assignments, you can check them from your backend. For example, with a configured JavaScript server client and Alice's role from the quickstart:

```ts
const { data: canRead, error } = await permissions
  .as({ id: 'alice' })
  .rbac.hasPermission({
    permission: 'documents.read',
    scope: 'acme',
  })

if (error) throw error
if (!canRead) throw new Error('Forbidden')

// Continue with the authorized operation.
```

In a request handler, the subject comes from your authentication system. Your backend checks the result before returning data or performing the operation. No table policy is involved. OpenFGA and Cedar have their own check and list functions for the same pattern. The [application guide](/integrations/checks/) covers the setup and how to handle the results.

## Optional: enforcing access with RLS

If you want Postgres to filter table queries, you can call the same functions from an RLS policy. Suppose you have a documents table with UUID IDs, and an OpenFGA `document#viewer` relation. This policy returns the documents the current user can read:

```sql
create policy documents_read
  on public.documents
  for select
  to authenticated
  using (
    id = any (
      array(
        select permissions.fga_list_object_ids_current(
          type => 'document',
          relation => 'viewer'
        )::uuid
      )
    )
  );
```

This assumes you've already set up the table, model, database role and request identity. The [complete guide](/rls/policies/) covers that setup and the policies for writes.

Your application can now issue a normal `select`. The helper finds the IDs the current subject can access, and Postgres uses them to filter the rows. Computing the IDs once gives the planner a chance to use an index, instead of running a permission check for every candidate row.

### A small change with a large performance improvement

The `::uuid` cast in that example is in a specific place for a reason.

In an early prototype, we returned a text array and cast it outside the subquery. Postgres repeated the conversion for every filtered row. Moving it inside the subquery meant it only had to do the conversion once.

On a dataset with one million documents, that change reduced the sharing-page query from **10.01 ms to 1.90 ms at p50**. We'd been comparing different authorization engines, and one of the biggest improvements came from moving a type cast.

We also tried a hashed `IN` subquery. That looked reasonable, but a count query lost its index access and became much slower. The query plans and results are in the [first benchmark session](/research/journal/#9-benchmarks-and-the-bug-that-wasnt-where-we-looked). These were prototype measurements on local Postgres 16.4.

Returning IDs isn't always the best approach. A Cedar policy which considers every document can still do a lot of work to produce that list. Row checks are useful for writes and for policies which need the row's current attributes. The [performance guide](/rls/performance/) covers when to use each.

## Performance

The current benchmark harness runs as an application database role with RLS enabled. It also checks the results using visible-document checksums. Returning fewer rows would be a fairly unhelpful optimization.

Here are the OpenFGA and Cedar models running the same access scenarios with **100,000 documents and 5,000 users**. Numbers are p50 / p95 latency in milliseconds:

| Workload | OpenFGA model | Cedar model |
| --- | ---: | ---: |
| Fetch a page of 50 shared documents | 0.57 / 1.18 | 0.79 / 1.30 |
| Check access through a nested team | 0.38 / 0.51 | 0.37 / 0.52 |
| Count documents with inherited access | 0.91 / 1.42 | 1.19 / 2.41 |
| Change a team's parent | 0.15 / 0.26 | 1.17 / 1.76 |

These runs used Postgres 18.6 in Docker on an Apple M4, with four container CPUs, 6 GB of memory, four clients and ten seconds per workload. The OpenFGA run is from October 30; Cedar is from November 2, after the cache fixes described below and before the later `search_path` fix and performance pass. You can find the [reports, workloads and methodology here](/research/benchmarks/cedar-report/).

Cedar missed our 1 ms p95 budget for changing a team's parent. All four clients were updating the same entity and waiting on its row lock. OpenFGA writes a tuple for this operation, so the two models end up doing different database work for the same permission change.

We did a performance pass after those runs. The Cedar per-row check, where the policy checks every candidate row, got about 21% faster on local Postgres 16.4: a page of 50 visible rows went from 35.5 to 27.5 ms at p50 on the small dataset and from 89.4 to 70.3 ms on the medium one. Postgres 18 in Docker went from 34 to 25 ms. Cedar still costs about 40 µs per row there, so a list is still the better choice for reads. On Postgres 16, `rbac_has_permission` went from 21.8 to 12.1 µs per call, and an OpenFGA `list_objects` from 125 to 90 µs.

Most of that came from one thing. A SQL function which has a `SET search_path`, or an `exists` subquery, can't be inlined, and before Postgres 18 it's planned again on every call. `current_subject_id` alone took 9.3 µs of a 28 µs `rbac_has_permission`. Rewriting five small helpers in PL/pgSQL, which caches the plan, fixed most of it. Postgres 18 caches those plans, so the gain there is smaller.

We also had a wrong turn. Folding four passes over the cached filter into one made it 2.3 times slower (92 to 215 µs per row), because Postgres flattened the subquery and ran `jsonb_build_object` about ten times per row. `offset 0` stopped the flattening and the final version took 84 µs.

Some caveats: these are short runs with `fsync=off` and writes which roll back. They don't measure durable commit latency or mixed read/write traffic, and we haven't established confidence intervals. These are also comparisons between the models inside this extension. We haven't benchmarked it against an external authorization service; that needs a representative application and network setup. I'd like to see how it performs on more workloads and hosted databases.

## Building it with Claude Code

I built this with Claude Code. We kept a [journal](/research/journal/) of the designs, experiments and review findings, including the approaches we dropped. A few parts of the process were particularly useful.

### Comparing designs

Claude's first proposal put everything into a shared relationship graph. Roles would be an API over tuples, and more complicated permission models would use the same underlying data. It seemed like a reasonable way to let an application start with roles and add object sharing later.

I asked for two alternative designs before committing to it. One evaluated permit/forbid policies and precomputed group membership. The other compiled a model into lookup tables, moving more work to writes. We implemented all three and tested them against the same application scenarios.

The differences became clearer once we ran them. Basic role checks performed similarly, while object sharing, inherited access and membership updates needed different optimizations in each model.

Even the meaning of a deny differed. One design applied it to the subject's own tuple, another handled group principals, and the third limited propagation by type. A common function name made these differences harder to see.

We ended up giving each model its own tables and API, with RLS as one way to combine them. You can still add object sharing to an application which uses roles; it just lives alongside RBAC. The [decision record](/research/decision/#session-4-direction-per-model-tables) has the full comparison.

### Using existing languages and tests

One reason I wanted established authorization models is that developers already have documentation and examples to work from. The same is true for LLMs. They can use an existing body of work when writing OpenFGA models or Cedar policies, instead of learning a custom language we invented for this extension.

It also gives us a useful way to test the implementation. We adapted pinned upstream test suites into database tests. Cedar's corpus has 5,701 tests and 45,494 requests, and the full JSON-policy run passes it. Other runs cover text parsing, request entities, hierarchy traversal and generated template links.

The [compatibility page](/models/cedar/compatibility/) lists what each mode covers. There are some differences to account for, including substituting U+0000 because Postgres can't store it. Cedar schema validation and partial evaluation aren't implemented, and the corpus is pinned to a specific version.

Error handling was an interesting part of this. Cedar skips policies which fail during evaluation and reports the errors. If a `forbid` fails, a separate permit can still allow the request.

We keep that behavior in the admin API, where you can inspect the decision and diagnostics. The current-subject functions return false when a relevant forbid fails to evaluate, whether you call them from application code or RLS. I don't want a boolean check to grant access because a deny rule failed. The [design record](/research/designs/e-cedar/) explains the difference.

### Reviewing the cache

The Cedar row helper caches work which can be reused across a statement, including the principal's groups, the action and candidate policies. The first version used a transaction-local Postgres setting for this.

The security argument was that a client which could forge the cache could already forge its subject identity. A separate review agent tested this and found that it could grant access to a subject which didn't even exist, bypassing forbid policies.

Forging an identity still leaves you with whatever permissions that identity has. Forging the cache let the caller supply the information used to grant access. The original argument had missed that distinction.

The cache now uses a keyed SHA-256 construction to authenticate entries, with a secret in an owner-only table. We also moved the counter used to invalidate cached work after writes out of a client-writable setting. This added roughly three microseconds per row in the small-payload measurements. The [review and fixes](/research/designs/e-cedar/#17-phase-9-the-security-review) include the construction and measurements.

This was a useful reminder for me about building with agents. The upstream tests helped check the language semantics, but finding this bug required someone to try a query which broke the implementation's security assumptions.

### A second review: search_path

A later security pass found a worse problem, and it was in the version we had released. The functions that set a search path used `set search_path = ''`, which looks like the safe choice. It isn't, for `security definer` functions. If `pg_temp` isn't in the `search_path`, Postgres searches it first for type and table names. Any role with the default `TEMP` privilege, which includes `anon` and `authenticated` on Supabase, could create a temporary domain called `text` with a `CHECK` constraint that calls its own function. That function then ran as the extension owner, because most of them are `security definer` (39 of the 42 that set a search path in 0.1.0). On an install owned by a superuser, we reproduced `alter role mallory superuser` from an ordinary role.

The fix is `set search_path = pg_catalog, pg_temp` on every function. The 0.0.1 release has the flaw, and the 0.0.1 to 0.1.0 upgrade script alters its functions, so please upgrade. It costs about 0.1 to 0.2 µs per call, which is inside the noise.

The same pass found four smaller issues. The "did you mean" hint for an unknown relation was quadratic in its input, and any client could reach it through `fga_check_current`: 20,000 characters took 3 to 6 seconds. A client's `standard_conforming_strings = off` stopped one function from compiling. The install accepted an existing `permissions` schema that another role owned or could write to, and now raises `42501`. And our own docs taught `search_path = ''` for user-written definer functions.

There's a regression test for all of this, `06_security_invariants.sql`. It builds its list of functions from the catalogs, so a new function is covered without anyone remembering to add it, and its 49 assertions include grants, pinned settings, no dynamic SQL and injection payloads. Thirteen of them fail on the code from before the fix.

Some limits are documented rather than fixed. A client with direct SQL access can set its own subject with `set_config` (PostgREST clients can't). A JWT with no `sub` falls back to the `permissions.subject_id` setting. Functions you add to the schema later get `PUBLIC` execute by default. And if you install with `create extension`, `pg_dump` doesn't include the extension's tables, so a restore loses your roles, tuples and policies. It fails closed, but you'd need a physical backup or a `copy` export.

## Get started

Version 0.1.0 is available as a SQL file, with an upgrade path from 0.0.1. If you installed 0.0.1, upgrade: it has the `search_path` privilege-escalation flaw described above. The `permissions` JavaScript client has separate namespaces for each model. The [quickstart](/get-started/quickstart/) walks through assigning a role and checking access for two users, with an optional RLS example afterward.

There are guides for [roles](/models/rbac/overview/), [object sharing](/models/openfga/overview/) and [Cedar policies](/models/cedar/overview/), along with the [source and tests](https://github.com/kiwicopple/pg-extensions/tree/main/pg_permissions).

If you have a permission rule which is awkward to express in your application, I'd be interested to see how it works with this. And if you find a surprising result or a slow query, please [open an issue](https://github.com/kiwicopple/pg-extensions/issues). A small model, the expected result, and an `EXPLAIN` plan would be helpful.
