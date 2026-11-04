# Correctness review: OpenFGA lists, CEL conditions and Cedar links

An external tester reported nine discrepancies against an earlier 0.1.0 snapshot. We checked them against the November 3 security fixes on main (commit 119a0fa) and the project's pinned OpenFGA v1.22.1 server. Six needed code changes, two were already fixed, and one turned out to match upstream.

| Report | What we found | Resolution |
| --- | --- | --- |
| 1. Direct exclusion in ListObjects | OpenFGA accepts a JSON difference whose subtract operand is directly assignable. On the merged code, Check excluded a document while ListObjects, both current-subject list functions and a real RLS query returned it. | Evaluate that operand from its own type restrictions and tuples. The positive graph intentionally omits subtract edges. Stored models do not need recompiling. |
| 2. Refresh resurrects a deleted link | A refresh could read a link before another transaction finished deleting it, then insert it again. This reproduced with both a direct deletion and subject cleanup. Moving a link to a different template could also be undone. | Refresh locks surviving links before validating slots and rewriting policies. It skips a committed deletion or move; a conflicting older snapshot must retry. |
| 3. Link retains an old template | Already fixed in the November 3 review. Creating a link and replacing its template both write the template row. | Kept the tests for both orderings at three isolation levels, plus the incompatible-slot test. The cross-template move variant is covered by finding 2. |
| 4. Integer division rounds | At the signed and unsigned limits, a rounded numeric quotient could be off by one before truncation. | Use integer quotient directly. Tests cover both signs and unsigned values. |
| 5. UTC year out of range | A local date in year 9999 could become year 10000 UTC and compare as earlier than 2024. Crossing below year one also broke ordering. | Validate the UTC instant before formatting. Both conversion and typed inputs outside the supported range produce a condition error in the extension. |
| 6. Regex grants on a newline | A CEL string literal containing a newline did not match the anchored dot pattern on the reference server, but did match in Postgres. Upstream rejects a literal newline in request context before evaluation, so we also tested the expression independently of transport. | Translate the supported RE2 syntax explicitly, including dot and word boundaries. Reject unsupported constructs, including backreferences and lookaround. See [CEL support](../../docs/reference/cel.md) before migrating patterns. |
| 7. Large UTC offsets escape the evaluator | The server accepted +20:00. Postgres' time zone input rejected it before CEL could handle the result. | Apply the numeric offset to the local timestamp. Valid offsets through ±23:59 work; invalid conversions stay inside CEL's error handling. |
| 8. Unreachable conditional exclusion breaks ListObjects | Confirmed the reported SQL behavior **and the same behavior on the live server**. Check returns false for the unreachable object. Explicit ListObjects raises a missing-context error while walking its exclusion. | Preserved compatibility. Added regressions for Check, explicit ListObjects, and the current-subject helper, which can still list the unaffected objects. |
| 9. Invalid Cedar attributes depend on resource id | Already fixed: validation precedes an unconditional allow. The reference page still described the old behavior. | Corrected the documentation and added the exact cache-separator id case to the malformed-input tests. |

## How to reproduce the comparisons

Run the following from the extension directory:

- The [live reference probe](../../test/fga_abac/probe.sh) runs with the option `--correctness`. It starts the pinned OpenFGA image on a temporary loopback port, writes both model shapes, prints the responses and removes the container.
- The [list regression](../../test/spec/d/44_fga_difference_correctness.sql) exercises Check, lists and RLS against the same model, including direct users, wildcards, usersets, conditional and contextual tuples. The [CEL cases](../../test/spec/d/38_fga_cel.sql) write a model and a tuple, then check the permission with `fga_check`.
- The [two-connection tests](../../js/test/integration/security.test.ts) observe a database lock before releasing the competing transaction, then assert both the stored link and the final permission decision.

Against the merged code, the targeted regressions reproduced 19 failing SQL assertions and all three read-committed Cedar races. With the fixes, the full suite passed 170,045 SQL assertions on PostgreSQL 16.4, and all 93 JavaScript integration tests passed against PostgreSQL 17 and PostgREST.

One distinction matters for dates: for the upper-bound example, OpenFGA's explicit timestamp conversion reports overflow, while its typed parameter comparison returns false. The extension rejects the out-of-range typed value as well. Both prevent the incorrect allow; the error behavior differs.

These edits apply to fresh 0.1.0 installs and the 0.0.1 upgrade script. An already installed 0.1.0 database needs a patch migration. Existing links resurrected by a past race cannot be distinguished from intentional grants: reconcile affected links with the application's grant records. Before rolling out the regex change, test conditions that rely on Postgres-specific syntax.
