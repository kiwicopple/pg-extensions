# Errors

Handle errors by their SQLSTATE code (`error.code` in node-postgres). Message text can change. The tables below cover errors raised by `pg_crdt` and errors Postgres can raise when you use it. Extension messages start with the function name and include a `HINT`.

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
| `22004` | `null_value_not_allowed` | `yseq_insert`, `yseq_delete`, `yseq_set` | `replica`, a position, a length or the text is null. |
| `22023` | `invalid_parameter_value` | `yseq_insert`, `yseq_delete`, `yseq_set` | A position or range outside the text, or a negative length; `replica` is not an entry key or is longer than 256 bytes; for `yseq_set`, a `base` with another document id, or with characters the state lacks. |
| `22023` | `invalid_parameter_value` | `yseq_apply` | `replica` is not a replica id; `ops` is not an op or an array of ops; a malformed op, insert run or delete; an op that breaks a causal rule or a limit (the message names it, `V0` to `V6`: no `v`, more than 128 runs, a key over 256 bytes). |
| `22023` | `invalid_parameter_value` | `yseq_merge` | An argument is not a well-formed state beyond the envelope, or the two states have different document ids. |
| `22023` | `invalid_parameter_value` | `yseq_ops_since` | `vv` is not an object of whole numbers from 0. |
| `22003` | `numeric_value_out_of_range` | `yseq_insert`, `yseq_set` | The entry key has used up its sequence numbers (2,147,483,647 characters). |
| `23514` | `check_violation` | The `crdt.yseq` domain, so any function that takes or returns one | A value is not a `crdt.yseq` envelope (wrong keys, `t` not `"yseq"`, `v` not 1, arrays of different lengths). |
| `42501` | `insufficient_privilege` | `yseq_apply` | `replica` is null (no identity), or an insert carries another writer's key. |
| `54000` | `program_limit_exceeded` | `yseq_apply` | The writer would have more than 32 entry keys in the state, or more waiting than its quota (256 runs plus deletes, or 64 kB). |
| `54000` | `program_limit_exceeded` | `yseq_ops_since`, `yseq_diff`, `yseq_merge` (Postgres) | `requested character too large for encoding`: the database is not UTF8 and the state has deleted characters. `yseq_` needs a UTF8 database. |
| `XX000` | `internal_error` | `yseq_ops_since`, `yseq_diff`, `yseq_merge` | A state has runs whose origins are missing. It means a bug, or a hand-made state: report it. |

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
| `22004` | `crdt.yseq_insert: replica must not be null` |
| `22023` | `crdt.yseq: range at position 20 of length 0 is outside the text (length 11)` |
| `22023` | `crdt.yseq_insert: 'a:' is not a replica key` |
| `22023` | `crdt.yseq_set: the base belongs to another document (id ... against ...)` |
| `22023` | `crdt.yseq_set: the base has characters the state lacks, so it is not a version of this document` |
| `22023` | `crdt.yseq_merge: the states belong to different documents (ids ... and ...)` |
| `22023` | `crdt.yseq_merge: argument a: not a well-formed crdt.yseq state` |
| `22023` | `crdt.yseq_apply: op rejected (V2: a run does not start at v[replica] + 1)` |
| `22023` | `crdt.yseq_apply: malformed insert run ["bob", 1, null, null, ""]` |
| `42501` | `crdt.yseq_apply: the writer has no replica id` |
| `42501` | `crdt.yseq_apply: replica 'frank' cannot insert characters of replica 'gina'` |
| `54000` | `crdt.yseq_apply: writer 'bob' has too much waiting (... runs and deletes, ... bytes)` |
| `23514` | `value for domain crdt.yseq violates check constraint "yseq_check"` (Postgres) |


## Errors from Postgres

| SQLSTATE | When | What to do |
| --- | --- | --- |
| `40001` | A merge under REPEATABLE READ or SERIALIZABLE, when the row changed and committed after your snapshot (`could not serialize access due to concurrent update`). | Run the whole transaction again. See [Update safely](../guides/safe-updates.md#isolation-levels-and-retries). |
| `22P02` | `crdt.current_replica_id()`, when `request.jwt.claims` is set to text that is not valid JSON. | Fix whatever sets the setting. |
| `40001` | A `yseq_` column update under REPEATABLE READ or SERIALIZABLE, when the row changed after your snapshot, as for any update. | Run the whole transaction again. |
| `42501` | An `update` of a column the role has no privilege on. | This is the intended result for a writer without access. See [Accept writes from untrusted clients](../guides/security.md). |

## Which errors mean what

For a symptom-first guide, see [Troubleshooting](../operations/troubleshooting.md).

- **`42501` from `pn_apply_delta`** means the caller sent an entry that is not its own, or has no identity. Reject the request and check the identity your server passed to the function.
- **`22023` from `pn_apply_delta`** means the delta is malformed. Check how the client constructs its keys and totals.
- **`23514`** means the value failed a domain check. Check the type, format version and required keys.
- **`40001`** can occur under stricter isolation levels. Retry the whole transaction; repeating the same merge does not count it twice.
- **`22003`** means a total reached the 64-bit limit. See [Limits](limits.md).
- **`42501` from `yseq_apply`** is its identity check: a forged insert, or no identity. Reject the request.
- **`22023` from `yseq_apply`** means the op is malformed or breaks a causal rule. Resync the client with `yseq_ops_since`.
- **`22023` from `yseq_merge` or `yseq_set` about another document** means a state or base from another row: check which row the value came from.
