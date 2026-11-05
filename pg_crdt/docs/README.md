# pg_crdt documentation

`pg_crdt` adds conflict-free replicated data types (CRDTs) to Postgres, for values that several writers change independently and merge later. The extension is SQL and PL/pgSQL, runs on Postgres 16, 17 and 18, and works with any client, driver or API layer. Version 0.0.1 has two types: the PN-Counter, a counter that goes up and down, and collaborative text, a plain-text document that several people edit at once.

New to the project? Read the [overview](overview.md), [install the extension](install.md) and follow the [quickstart](get-started/quickstart.md). The quickstart adds a counter column to a table, counts as two writers and merges a count that arrives from another place.

## Build your application

| Task | Read |
| --- | --- |
| Understand CRDTs, and decide whether you need one | [Overview](overview.md) |
| Install with a script, pg_tle or `create extension` | [Install](install.md) |
| Add a counter column and count | [Quickstart](get-started/quickstart.md) |
| Name your writers, use device ids, recover a lost device | [Replicas and identity](guides/replicas-and-identity.md) |
| Write from several clients without losing updates | [Update safely](guides/safe-updates.md) |
| Let clients send their own counts without forging each other's | [Accept writes from untrusted clients](guides/security.md) |
| Index the value, keep counters as deltas, read the benchmarks | [Storage and performance](guides/storage-and-performance.md) |
| Understand the state and its merge | [PN-Counter](types/pn-counter.md) |
| Let several people edit a text, from forms or live editors | [Collaborative text for a blog post](guides/collaborative-text.md) |
| Understand how text documents merge, and what they cannot do | [Collaborative text](types/collaborative-text.md) |
| Connect a live editor in JavaScript | [JavaScript client](reference/client.md) |
| Understand an error or a limit | [Errors](reference/errors.md), [Limits](reference/limits.md) |

## Reference

| Page | Contents |
| --- | --- |
| [Shared](reference/shared.md) | Schema and naming, privileges, replica ids, `current_replica_id`, the settings, the state envelope and versioning |
| [PN-Counter functions](reference/pn.md) | `pn_empty`, `pn_increment`, `pn_decrement`, `pn_value`, `pn_merge`, `pn_merge_agg`, `pn_is_valid`, `pn_apply_delta` |
| [Collaborative text functions](reference/ydoc.md) | `ydoc_create`, `ydoc_value`, `ydoc_length`, `ydoc_version`, `ydoc_base`, `ydoc_insert`, `ydoc_delete`, `ydoc_set`, `ydoc_apply`, `ydoc_merge`, `ydoc_ops_since`, `ydoc_compact`, `ydoc_rejected_purge`, `ydoc_drop`; the tables and their grants; limits |
| [JavaScript client](reference/client.md) | `pg-crdt-client` for collaborative text: `openYdoc`, edits at UTF-16 positions, change events, `sync`, transports, refused ops |
| [Errors](reference/errors.md) | Every SQLSTATE the extension raises, and the Postgres errors you can meet |
| [Limits](reference/limits.md) | Numeric limits, growth, and what is not built |

## Project

| Page | Contents |
| --- | --- |
| [Changelog](../CHANGELOG.md) | What each version contains |
| [Test suite](../test/README.md) | How to run the tests, and what each spec file checks |
| [Conventions](../STYLE.md) | How these pages are written |
| [Research](../research/README.md) | The architecture, prior art, benchmarks and the build journal. Planned types are described there |

## Example conventions

The examples are generic Postgres. Run the SQL in psql, or in any client. Where an application does the work, choose **JavaScript** or **SQL**: the site remembers your selection. JavaScript examples use plain [node-postgres](https://node-postgres.com) (`pg`) and assume a connected `client`, as set up in the [quickstart](get-started/quickstart.md#before-you-start). The SQL uses lowercase keywords, qualifies every extension name with `crdt.`, and shows results as comments.

Each task page states its prerequisites, and its examples run in order unless a block is introduced as a fragment, or ends with an `-- ERROR:` comment. Roles such as `app_writer` are examples: grant to your own.
