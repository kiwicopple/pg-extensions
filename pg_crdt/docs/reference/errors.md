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

`pn_decrement` raises the same messages with its own name. The messages that name an entry show the map (`p` or `n`) and the key.

## Errors from Postgres

| SQLSTATE | When | What to do |
| --- | --- | --- |
| `40001` | A merge under REPEATABLE READ or SERIALIZABLE, when the row changed and committed after your snapshot (`could not serialize access due to concurrent update`). | Run the whole transaction again. See [Update safely](../guides/safe-updates.md#isolation-levels-and-retries). |
| `22P02` | `crdt.current_replica_id()`, when `request.jwt.claims` is set to text that is not valid JSON. | Fix whatever sets the setting. |
| `2BP01` | `drop extension pg_crdt`, while a column, default or index uses the type. | Copy your data out first. See [Uninstall](../install.md#uninstall). |
| `42501` | An `update` of a column the role has no privilege on. | This is the intended result for a writer without access. See [Accept writes from untrusted clients](../guides/security.md). |

## Which errors mean what

- **`42501` from `pn_apply_delta`** means the caller sent an entry that is not its own, or has no identity. Treat it as a rejected request. An honest client never causes it. A wrong identity setup does.
- **`22023` from `pn_apply_delta`** means the delta is malformed. An honest client does not cause it.
- **`23514`** means the value is not a counter at all: a wrong `t` or `v`, or a missing key.
- **`40001`** is expected under the stricter isolation levels and is safe to retry.
- **`22003`** means a total reached the 64-bit limit. See [Limits](limits.md).
