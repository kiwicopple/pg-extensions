# Errors

Handle errors by their SQLSTATE code (`error.code` in node-postgres). Message text can change. The tables below cover errors raised by `pg_crdt` and errors Postgres can raise when you use it. Use the message to distinguish conditions that share a code.

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

## Errors from Postgres

| SQLSTATE | When | What to do |
| --- | --- | --- |
| `40001` | A merge under REPEATABLE READ or SERIALIZABLE, when the row changed and committed after your snapshot (`could not serialize access due to concurrent update`). | Run the whole transaction again. See [Update safely](application.md#updates-and-retries). |
| `22P02` | `crdt.current_replica_id()`, when `request.jwt.claims` is set to text that is not valid JSON. | Fix whatever sets the setting. |
| `42501` | An `update` of a column the role has no privilege on. | This is the intended result for a writer without access. See [Accept writes from untrusted clients](application.md#counters). |

For recovery by symptom, see [troubleshooting](operations.md#troubleshooting). Preserve unsent text before resyncing a rejected edit.
