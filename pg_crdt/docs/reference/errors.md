# Errors

Every error that `pg_crdt` raises, with its SQLSTATE, and the errors from Postgres that you can meet when you use it. Match on the SQLSTATE (`error.code` in node-postgres), not on the message text. Messages of the extension start with the name of the function and carry a `HINT`.

## SQLSTATE table

| SQLSTATE | Name | Raised by | When |
| --- | --- | --- | --- |
| `22004` | `null_value_not_allowed` | `pn_increment`, `pn_decrement` | `replica` or `amount` is null. |
| `22023` | `invalid_parameter_value` | `pn_increment`, `pn_decrement` | `amount` is negative; `replica` is not a valid entry key (`''`, `abc:`, `:x`). |
| `22023` | `invalid_parameter_value` | `pn_apply_delta` | `replica` is empty or contains `:`; a count in the delta is not a whole number from 0 to 9223372036854775807; a key in the delta is malformed. |
| `22023` | `invalid_parameter_value` | `pn_value` (Postgres) | An entry is not a number. Only a state that did not pass `pn_is_valid` can have one. |
| `22003` | `numeric_value_out_of_range` | `pn_increment`, `pn_decrement` (Postgres) | An entry would pass 9223372036854775807 (`bigint out of range`). |
| `22003` | `numeric_value_out_of_range` | `pn_value` (Postgres) | The value is outside the `bigint` range. |
| `23514` | `check_violation` | The `crdt.pn` domain, so any function that takes or returns one | A value is not a `crdt.pn` envelope: not an object, other keys than `t`, `v`, `p`, `n`, `t` not `"pn"`, `v` not 1, or `p` or `n` not an object. |
| `42501` | `insufficient_privilege` | `pn_apply_delta` | `replica` is null (no identity), or an entry of the delta belongs to another replica. |
| `42501` | `insufficient_privilege` | The install script | The schema `crdt` is owned by another non-superuser role, or another role has `CREATE` on it. |
| `22023` | `invalid_parameter_value` | `ydoc_create` | The id is null, empty, longer than 256 bytes or has a control character. |
| `23505` | `unique_violation` | `ydoc_create` | A document with this id exists. Creating is not idempotent: the existing document is never returned, so that nobody can take over a document by creating its predictable id. Two sessions that create one id at once get one success and one `23505`. See [Create a document with a client-chosen id](../guides/collaborative-text.md#create-a-document-with-a-client-chosen-id). |
| `22004` | `null_value_not_allowed` | `ydoc_insert`, `ydoc_delete`, `ydoc_set` | `replica`, a position, a length or the text is null. |
| `22023` | `invalid_parameter_value` | `ydoc_insert`, `ydoc_delete`, `ydoc_set` | A position or range outside the text; `replica` is not an entry key or is longer than 256 bytes; a `base` that is not a version of the document, or is older than its last compaction. |
| `22023` | `invalid_parameter_value` | `ydoc_apply`, `ydoc_merge` | A malformed op; for `ydoc_apply`, an op without `v`, or one that breaks a causal rule (the message names it, `V0` to `V6`); the same ids sent again with other text or origins. `ydoc_apply` also: `replica` is not a replica id. |
| `22023` | `invalid_parameter_value` | `ydoc_ops_since`, `ydoc_compact` | `vv` is not an object of whole numbers from 0; `horizon` outside 0 to the document's write counter. |
| `42501` | `insufficient_privilege` | `ydoc_apply` | `replica` is null (no identity), or an insert carries another writer's key. |
| `42501` | `insufficient_privilege` | Any `ydoc_` function (Postgres) | The caller has no privileges on the `crdt.ydoc_*` tables (`permission denied for table ydoc_docs`). This is the intended result for a client role: see [Collaborative text for a blog post](../guides/collaborative-text.md#set-up-the-roles-and-grants). |
| `54000` | `program_limit_exceeded` | `ydoc_apply` | A quota of the untrusted path: more than 256 runs in one op, more than 16 device keys per owner and document, origins too far apart to check (250,000 rows), or too many waiting ops for the writer (100 ops or 256 kB). |
| `54000` | `program_limit_exceeded` | Any `ydoc_` write | The order labels of a document ran out (`document ... has too many rows`). Not reachable at realistic sizes. |
| `P0002` | `no_data_found` | Every `ydoc_` function that writes, and `ydoc_ops_since` | The document does not exist. The readers `ydoc_value`, `ydoc_length` and `ydoc_base` return null instead, and `ydoc_version` returns `{}`. |
| `XX000` | `internal_error` | `ydoc_` internals | An invariant of a document's rows is broken (`no row labelled ...`, `... is not inside the run`). It means a bug, or a direct write to the tables: report it. |

Several rows share a SQLSTATE for different reasons. Tell them apart with the message.

## Messages

Text that is written by the extension, as Postgres reports it:

| SQLSTATE | Message |
| --- | --- |
| `22004` | `crdt.pn_increment: replica and amount must not be null` |
| `22023` | `crdt.pn_increment: 'abc:' is not a replica key` |
| `22023` | `crdt.pn_increment: amount must be zero or more, got -3` |
| `22023` | `crdt.pn_apply_delta: 'a:b' is not a replica id` |
| `22023` | `crdt.pn_apply_delta: the delta has an entry that is not an integer from 0 to 9223372036854775807` |
| `22023` | `crdt.pn_apply_delta: entry p.'alice:' is not a replica key` |
| `42501` | `crdt.pn_apply_delta: the writer has no replica id` |
| `42501` | `crdt.pn_apply_delta: replica 'alice' cannot write entry p.'bob' of another replica` |
| `42501` | `schema crdt is owned by role other, not by the installing role app_owner` |
| `42501` | `another role has CREATE on schema crdt` |
| `23514` | `value for domain crdt.pn violates check constraint "pn_check"` (Postgres) |
| `22023` | `crdt.ydoc_create: '' is not a document id` |
| `23505` | `crdt.ydoc_create: document 'welcome' already exists` |
| `22023` | `crdt.ydoc_insert: position 99 is outside the document (length 11)` |
| `22023` | `crdt.ydoc_set: base is not a version of document 'welcome'` |
| `22023` | `crdt.ydoc_set: base 3 of document 'welcome' is older than its last compaction` |
| `22023` | `crdt.ydoc_apply: V0: ops carry no version vector "v"` |
| `22023` | `crdt.ydoc_apply: V2: insert bob:3 does not follow "v" (expected seq 1)` |
| `22023` | `crdt.ydoc: insert bob:1 reuses ids with other content or origins` |
| `42501` | `crdt.ydoc_apply: the writer has no replica id` |
| `42501` | `crdt.ydoc_apply: replica 'dave' cannot insert characters of replica 'erin'` |
| `42501` | `permission denied for table ydoc_docs` (Postgres) |
| `54000` | `crdt.ydoc_apply: replica 'bob' has too many ops waiting in document 'welcome'` |
| `P0002` | `crdt.ydoc_insert: document 'nope' does not exist` |

`pn_decrement` raises the same messages with its own name. The messages that name an entry show the map (`p` or `n`) and the key. The `ydoc_` messages name the function, a document by its id in quotes, and a character as `key:seq`.

## Errors from Postgres

| SQLSTATE | When | What to do |
| --- | --- | --- |
| `40001` | A merge under REPEATABLE READ or SERIALIZABLE, when the row changed and committed after your snapshot (`could not serialize access due to concurrent update`). | Run the whole transaction again. See [Update safely](../guides/safe-updates.md#isolation-levels-and-retries). |
| `22P02` | `crdt.current_replica_id()`, when `request.jwt.claims` is set to text that is not valid JSON. | Fix whatever sets the setting. |
| `2BP01` | `drop extension pg_crdt`, while a column, default or index uses the type, or a foreign key references `crdt.ydoc_docs`. | Copy your data out first. See [Uninstall](../install.md#uninstall). |
| `23503` | `crdt.ydoc_drop`, while a row of your table references the document. | Delete your row first, in the same transaction. |
| `40001` | A `ydoc_` write under REPEATABLE READ or SERIALIZABLE that waited for another write to the same document. | Run the whole transaction again. |
| `42501` | An `update` of a column the role has no privilege on. | This is the intended result for a writer without access. See [Accept writes from untrusted clients](../guides/security.md). |

## Which errors mean what

- **`42501` from `pn_apply_delta`** means the caller sent an entry that is not its own, or has no identity. Treat it as a rejected request. An honest client never causes it. A wrong identity setup does.
- **`22023` from `pn_apply_delta`** means the delta is malformed. An honest client does not cause it.
- **`23514`** means the value is not a counter at all: a wrong `t` or `v`, or a missing key.
- **`40001`** is expected under the stricter isolation levels and is safe to retry.
- **`22003`** means a total reached the 64-bit limit. See [Limits](limits.md).
- **`42501` from a `ydoc_` function** is either the identity check of `ydoc_apply` (a forged insert, or no identity: reject the request) or Postgres refusing a role without table privileges (call through your wrapper).
- **`22023` from `ydoc_apply`** means the op is malformed or breaks a causal rule. An honest client running the same algorithm does not cause it; a client with a bug does. Resync it with `ydoc_ops_since`.
- **`22023` from `ydoc_set` with `base ... is older than its last compaction`** means the form is older than the compaction horizon. Reopen the document and apply the change again.
- **`23505` from `ydoc_create`** means the id is taken. If your client chose it, your wrapper decides what that means: the owner's retry gets the same document, anyone else is refused. Never answer it by handing out the existing document.
- **`54000` from `ydoc_apply`** is a quota. A writer with too many waiting ops is sending ops whose dependencies never arrive: send the missing ops first.
