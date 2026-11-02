# Documentation conventions

Write for a developer building an application. Use plain English, precise technical terms, and enough context to make each example usable. Prefer natural sentences over rigid word limits or prescribed vocabulary.

The build journal in `research/journal.md` is a raw historical record. Do not edit it during documentation cleanup. Generated benchmark reports keep the harness format.

## Organize by the reader's task

- Start a task page with its outcome and prerequisites. Say which database role runs each kind of operation.
- Keep a complete scenario together. If it continues another page, link to that page and name the data or variables it needs.
- Distinguish runnable examples, fragments, and statements that intentionally raise errors.
- Give each concept one canonical explanation. Keep short reminders beside examples where a mistake could change access or performance.
- Keep current behavior in the guides and reference. Label historical designs and superseded decisions in Research.
- Put future models in the architecture discussion until they are implemented. A future model gets its own guide and reference without changing the shared identity or RLS sections.

## Write plainly

Use active voice when the actor matters. Keep paragraphs focused, and vary sentence length when it makes the explanation easier to read. Avoid announcing that a topic is important; explain what it does and when the reader needs it.

Use one term consistently for each concept. Distinguish an application permission role from a Postgres database role, a subject from a connection role, and an OpenFGA authorization model from the broader choice of permission model.

Use tables for signatures, options, error codes, and comparisons. Use numbered steps for a sequence. Put a warning immediately before the operation it applies to, with the specific consequence.

Do not turn historical measurements into performance guarantees. Keep the environment, workload, limitations, and source with the result. Do not rewrite quoted errors, identifiers, or values for style.

## Code examples

1. SQL examples must run on the current extension unless marked as fragments or expected errors.
2. Use named arguments, lowercase SQL keywords, and one clause per line.
3. Put multi-argument calls on multiple lines, with one argument per line and a two-space indent. Put the closing parenthesis on its own line.
4. Aim for code lines of 72 characters or fewer. Long identifiers, URLs, output, and psql commands can exceed that limit when breaking them would be misleading.
5. Break long arrays, JSON, and nested calls into readable blocks. Indent JSON by two spaces.
6. In a policy, put `on`, `for`, `to`, `using`, and `with check` on separate lines. Indent the expression.
7. Show expected results when they establish behavior. Keep exact result and error text unchanged.
8. Break long shell commands with a trailing `\` and put flag groups on separate lines.
9. In JavaScript, construct complex values in named constants before passing them to a method.
10. Show equivalent SQL and JavaScript in adjacent fences, separated only by blank lines. Use `tab="SQL"` and `tab="JavaScript"`, in that order. GitHub shows both; the site renders synchronized language tabs.
11. Keep database policy definitions in SQL. A client permission check does not replace RLS enforcement.
12. Use transaction-local subject settings in application examples. State the setup when a standalone diagnostic uses session state.

## Reference entries

Document the signature, defaults, return type, privileges, subject behavior, errors, and JavaScript equivalent. State whether a result is capped and whether a function accepts request context. Link to a task guide for setup; do not require readers to execute the reference from top to bottom.

## Source and publication

Edit the canonical Markdown under `pg_permissions/`. The site generates its pages and plain Markdown exports from those files. `docs/navigation.mjs` controls the source paths, routes, and sidebar.

Keep existing routes and section anchors usable when moving content. Compatibility pages link to the new location and stay out of search results. See `docs/README.md` for build checks, export conventions, and the content migration map.
