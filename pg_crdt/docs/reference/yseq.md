# Collaborative text column functions

Every function of the collaborative text column type, `crdt.yseq`, in schema `crdt`. A `crdt.yseq` value is a whole document in one `jsonb` value: a column of your own table, written with `update ... set body = crdt.yseq_insert(body, ...)`, like a [PN-Counter](pn.md) column. See [Collaborative text](../types/collaborative-text.md) for the model, the op format, the limits and how it compares with the table-backed [`ydoc_`](ydoc.md), [Shared](shared.md) for naming and replica ids, and [Errors](errors.md) for every SQLSTATE. To build an application with them, follow [Collaborative text for a blog post](../guides/collaborative-text.md).

> **Experimental.** `yseq_` is part of the extension and tested like the rest of it, but every edit rewrites the whole value, so its cost grows with the document, and tombstones are never removed. Read [the limits](#limits) before you put large or heavily edited documents in a column.

Unless an entry says otherwise, a function:

- is `IMMUTABLE PARALLEL SAFE`, not `STRICT`, and not `security definer`;
- is `LANGUAGE plpgsql` with `search_path` pinned to `pg_catalog, pg_temp`, or `LANGUAGE sql` with a SQL-standard body;
- has `EXECUTE` granted to `public`. It reads and writes no table: it takes states and returns a value. Who may change a column is decided by the privileges on your table, as for any column;
- treats a null state as the empty document.

Positions and lengths count Unicode code points. A `replica` argument of a local edit is an [entry key](shared.md#replica-ids-and-entry-keys) of at most 256 bytes, which trusted code supplies. The extension needs a UTF8 database for `yseq_`: in another encoding, the functions that send deleted characters (`yseq_ops_since`, `yseq_diff`, `yseq_merge`) fail on a state that has any.

| Function | Returns | Purpose |
| --- | --- | --- |
| [`yseq_empty()`](#yseq_empty) | `crdt.yseq` | The empty document, without a document id. |
| [`yseq_new()`](#yseq_new) | `crdt.yseq` | An empty document with a random document id, for a column default. |
| [`yseq_value(state)`](#yseq_value) | `text` | The text. |
| [`yseq_length(state)`](#yseq_length) | `integer` | The length of the text, in code points. |
| [`yseq_version(state)`](#yseq_version) | `jsonb` | The version vector. |
| [`yseq_insert(state, pos, content, replica)`](#yseq_insert) | `crdt.yseq` | Local edit: insert text at a position. |
| [`yseq_delete(state, pos, len, replica)`](#yseq_delete) | `crdt.yseq` | Local edit: delete a range. |
| [`yseq_set(state, content, replica, base)`](#yseq_set) | `crdt.yseq` | Local edit: replace the whole text, two-way or three-way. |
| [`yseq_diff(old, new)`](#yseq_diff) | `jsonb` | The op that takes one state to a later one. |
| [`yseq_ops_since(state, vv)`](#yseq_ops_since) | `jsonb` | The ops a copy at version `vv` lacks. |
| [`yseq_merge(a, b)`](#yseq_merge) | `crdt.yseq` | Merge two states you trust. |
| [`yseq_merge_agg(state)`](#yseq_merge_agg) | `crdt.yseq` | Aggregate: merge every state in a group. |
| [`yseq_apply(state, ops, replica)`](#yseq_apply) | `crdt.yseq` | Apply ops from a writer you do not trust. |
| [`yseq_is_valid(state)`](#yseq_is_valid) | `boolean` | The full validator. |

The edit functions return the new state, not the op they made. When you need the op, to send it to other copies, take [`yseq_diff(old, new)`](#yseq_diff) in the same statement.

Functions whose names start with `_yseq_` are internal. They are granted to `public` because the functions above call them. Do not call them.

## The domain

`crdt.yseq` is a domain over `jsonb`. Its check reads only the envelope and what is cheap to check without reading the text: an object with the keys `t` (`"yseq"`), `v` (1), `r`, `c`, `n`, `s`, `m`, `p`, `x` and `q`, all but `t` and `v` arrays, matching array lengths, and an optional document id `o`. A value that fails it raises `23514`. The layout inside is internal and may change in a later version; read a document only through the functions on this page. [`yseq_merge`](#yseq_merge) checks the rest of what it needs at its boundary, and [`yseq_is_valid`](#yseq_is_valid) checks a state in full.

```sql
select crdt.yseq_empty();
-- {"c": [], "m": [], "n": [], "p": [], "q": [], "r": [], "s": [], "t": "yseq", "v": 1, "x": []}
select '{"t": "pn"}'::crdt.yseq;
-- ERROR:  value for domain crdt.yseq violates check constraint "yseq_check"
```

`crdt.yseq` belongs to the extension. `drop extension pg_crdt` fails with `2BP01` while a column uses it, and `drop extension pg_crdt cascade` drops those columns with their data. See [Uninstall](../install.md#uninstall).

## Functions

The examples on this page continue from each other. Run them in order, as the database owner, in a test database. They use this table:

```sql
create table notes (
  id int primary key,
  body crdt.yseq not null default crdt.yseq_new(),
  body_text text generated always as (crdt.yseq_value(body)) stored
);
insert into notes (id) values (1), (2);
```

### `yseq_empty`

```text
crdt.yseq_empty() returns crdt.yseq
```

The empty document, without a document id. Two empty states from `yseq_empty()` are the same value, so they can be merged with each other and with any state: prefer [`yseq_new`](#yseq_new) for a column default.

**Labels.** `IMMUTABLE PARALLEL SAFE`, `LANGUAGE sql`. **Privileges.** `EXECUTE` to `public`. **Errors.** None.

### `yseq_new`

```text
crdt.yseq_new() returns crdt.yseq
```

An empty document with a document id, a random UUID stored in the state (`o`). Use it as the column default: `body crdt.yseq not null default crdt.yseq_new()`. [`yseq_merge`](#yseq_merge) refuses to merge two states with different ids, and [`yseq_set`](#yseq_set) refuses a base with another id, so a state from one row cannot be merged or saved into another row by mistake. States without an id (from `yseq_empty()`) are not told apart.

**Labels.** `VOLATILE PARALLEL SAFE`, `LANGUAGE sql`. **Privileges.** `EXECUTE` to `public`. **Errors.** None.

```sql
select crdt.yseq_new() ->> 'o' is not null as has_id;
-- t
```

### `yseq_value`

```text
crdt.yseq_value(state crdt.yseq) returns text
```

The text: the visible characters in order. `''` for an empty document, null for null. The state stores the visible text as it is, in chunks, so this is a concatenation and does not read the history.

**Labels.** `IMMUTABLE PARALLEL SAFE STRICT`, `LANGUAGE sql`. Because it is `IMMUTABLE`, it can back a stored generated column, an expression index or a full-text index, as `body_text` above does. Postgres 18 virtual generated columns cannot call user-defined functions yet: use `stored`. **Privileges.** `EXECUTE` to `public`. **Errors.** None of its own.

### `yseq_length`

```text
crdt.yseq_length(state crdt.yseq) returns integer
```

The length of the text in code points. Null for null.

**Labels.** `IMMUTABLE PARALLEL SAFE STRICT`, `LANGUAGE sql`. **Privileges.** `EXECUTE` to `public`. **Errors.** None of its own.

### `yseq_version`

```text
crdt.yseq_version(state crdt.yseq) returns jsonb
```

The version vector `{key: count}`: for each entry key, the number of characters of that key the state has integrated, deleted ones included. Ops that wait for their dependencies are not counted. `{}` for an empty document, null for null. Pass it to another copy's [`yseq_ops_since`](#yseq_ops_since) to get what this copy lacks.

**Labels.** `IMMUTABLE PARALLEL SAFE STRICT`, `LANGUAGE sql`. **Privileges.** `EXECUTE` to `public`. **Errors.** None of its own.

### `yseq_insert`

```text
crdt.yseq_insert(
  state crdt.yseq,
  pos integer,
  content text,
  replica text
) returns crdt.yseq
```

Inserts `content` before position `pos` (0 to the length of the text) as the entry key `replica`, and returns the new state. Empty `content` returns the state unchanged. The new characters get the next sequence numbers of `replica`. For the op the edit made, use [`yseq_diff`](#yseq_diff).

**Privileges.** `EXECUTE` to `public`.

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22004` | `replica`, `pos` or `content` is null. |
| `22023` | `pos` is outside 0 to the length; `replica` is not an entry key, or is longer than 256 bytes. |
| `22003` | `replica` has used up its sequence numbers (2,147,483,647 characters). Use a new device key. |

```sql
update notes
set body = crdt.yseq_insert(body, 0, 'Hello', replica => 'alice')
where id = 1;
update notes
set body = crdt.yseq_insert(body, 5, ' world', replica => 'alice')
where id = 1;
select crdt.yseq_value(body),
       crdt.yseq_length(body),
       crdt.yseq_version(body)
from notes
where id = 1;
--  yseq_value  | yseq_length | yseq_version
-- -------------+-------------+---------------
--  Hello world |          11 | {"alice": 11}
select crdt.yseq_insert(body, 20, 'x', replica => 'alice')
from notes
where id = 1;
-- ERROR:  crdt.yseq: range at position 20 of length 0 is outside the text (length 11)
```

### `yseq_delete`

```text
crdt.yseq_delete(
  state crdt.yseq,
  pos integer,
  len integer,
  replica text
) returns crdt.yseq
```

Deletes `len` characters from position `pos` and returns the new state. `len` 0 returns the state unchanged. A local edit may delete anyone's characters. `replica` is checked, but not recorded: a delete does not say who deleted. The deleted characters stay as tombstones without their text.

**Privileges.** `EXECUTE` to `public`.

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22004` | `replica`, `pos` or `len` is null. |
| `22023` | The range is outside the text, or `len` is negative; `replica` is not an entry key. |

```sql
update notes
set body = crdt.yseq_delete(body, 0, 1, replica => 'bob')
where id = 1;
select crdt.yseq_value(body), crdt.yseq_version(body)
from notes
where id = 1;
--  yseq_value | yseq_version
-- ------------+---------------
--  ello world | {"alice": 11}
```

### `yseq_set`

```text
crdt.yseq_set(
  state crdt.yseq,
  content text,
  replica text,
  base crdt.yseq default null
) returns crdt.yseq
```

Replaces the text with `content`: it keeps the common prefix and suffix (in code points) and makes one delete and one insert in between, under `replica`. Setting the text it already has changes nothing.

- **Without `base`**, the diff is against the current text, so the result is exactly `content`. A form that was opened before another save reverts that save, in the range between its first and last change.
- **With `base`**, the state the form was opened with (the column value read together with the text it shows), the diff is against the text of `base`, and the result is merged into the current state. Saves of different places from the same base all survive. A form may save several times from one base: the characters `replica` added since the base count as part of it, so a second save does not insert the first one's text again.

The base is a whole state, not a small version token as in [`ydoc_set`](ydoc.md#ydoc_set), because the state does not keep the text of deleted characters: a form sends back the value it read. Two cases remain wrong and are misuse: a base from another document that has no document id, and a writer that deleted text in an earlier save and types it again in a later save from the same base (the earlier delete stays).

**Privileges.** `EXECUTE` to `public`.

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22004` | `content` or `replica` is null. |
| `22023` | `base` has another document id than `state`, or has characters that `state` lacks (it is not a version of this document); `replica` is not an entry key. |
| `22003` | `replica` has used up its sequence numbers. |

This example keeps the state before two saves as a base, with psql's `\gset`. Carol saves without a base, then dave saves from the older base: both changes stay.

```sql
update notes
set body = crdt.yseq_insert(body, 0, 'J', replica => 'alice:phone')
where id = 1;
select body as base from notes where id = 1 \gset
update notes
set body = crdt.yseq_set(body, 'Jello, world', replica => 'carol')
where id = 1;
update notes
set body = crdt.yseq_set(
  body,
  'Jello world!',
  replica => 'dave',
  base => :'base'
)
where id = 1;
select body_text from notes where id = 1;
--    body_text
-- ---------------
--  Jello, world!
select crdt.yseq_set(n1.body, 'x', replica => 'carol', base => n2.body)
from notes n1, notes n2
where n1.id = 1 and n2.id = 2;
-- ERROR:  crdt.yseq_set: the base belongs to another document (id ... against ...)
```

### `yseq_diff`

```text
crdt.yseq_diff(old crdt.yseq, new crdt.yseq) returns jsonb
```

The op that takes `old` to `new`, a later version of the same document: `{"v": ..., "i": [...], "d": [...]}` with the inserts `new` has beyond the version of `old`, only the deletes `old` lacks, and `v`, the smallest version vector that [`yseq_apply`](#yseq_apply) accepts for it. For a local edit, `yseq_diff(s, crdt.yseq_insert(s, ...))` is exactly the op the edit made, so this is how you get the op of an edit to send it on. A null `old` counts as empty.

To edit and return the op in one statement, lock the row first:

```sql
with old as (
  select body from notes where id = 1 for update
)
update notes n
set body = crdt.yseq_insert(old.body, 13, '?', replica => 'erin')
from old
where n.id = 1
returning crdt.yseq_diff(old.body, n.body) as op;
--                                          op
-- --------------------------------------------------------------------------------------
--  {"d": [], "i": [["erin", 1, ["dave", 1], null, "?"]], "v": {"dave": 1, "alice": 11}}
```

On Postgres 18, `returning crdt.yseq_diff(old.body, new.body)` does the same without the `with` clause.

**Privileges.** `EXECUTE` to `public`. **Errors.** `XX000`: a state is corrupt (runs whose origins are missing); it means a bug or a hand-made state.

### `yseq_ops_since`

```text
crdt.yseq_ops_since(state crdt.yseq, vv jsonb default '{}') returns jsonb
```

The ops that a copy at version `vv` lacks, as one op without `v`: `{"i": [...], "d": [...]}`. The inserts are the characters above `vv`, in a causal order, so the receiver can apply them without waiting; characters typed one after the other are joined into one run. The deletes are the whole delete set of the state, because deletes carry no clock. With the default `{}` (or null), it returns the whole document. Ops that wait in the state are not sent; [`yseq_merge`](#yseq_merge) carries them.

The state does not keep the text of deleted characters, so an insert of a character that is deleted since is sent as U+FFFD, one per code point. The delete set in the same result hides it. Peers that merge the result end with the same text.

Give the result to a client's own implementation of the algorithm, such as the [JavaScript client](client.md)'s engine. It has no `v`, so [`yseq_apply`](#yseq_apply) refuses it. Between servers, merge states with [`yseq_merge`](#yseq_merge).

**Privileges.** `EXECUTE` to `public`.

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22023` | `vv` is not an object of whole numbers from 0. |
| `XX000` | The state is corrupt (runs whose origins are missing). |

```sql
select crdt.yseq_ops_since(body, '{"alice": 11, "alice:phone": 1}')
from notes
where id = 1;
-- {"d": [["alice", 1, 1]], "i": [["carol", 1, ["alice", 5], ["alice", 6], ","], ["dave", 1, ["alice", 11], null, "!"], ["erin", 1, ["dave", 1], null, "?"]]}
```

### `yseq_merge`

```text
crdt.yseq_merge(a crdt.yseq, b crdt.yseq) returns crdt.yseq
```

Merges two states you trust: the characters, the deletes and the waiting ops of both. Commutative, associative and idempotent on the document, so states can be merged in any order and any number of times. `yseq_merge(x, null)` and `yseq_merge(null, x)` are `x`. When only one state has a document id, the result has it. The internal layout of the result can depend on the argument order; the text, the version and the ops it sends do not.

> **Warning:** do not merge states that clients send. A writer that builds its own state can claim any characters under any key, and choose origins that make two servers order the same text differently. Clients go through [`yseq_apply`](#yseq_apply).

The cost is proportional to both documents: it reads every run of `b` and rewrites the chunks of `a` that change.

**Privileges.** `EXECUTE` to `public`.

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22023` | An argument is not a well-formed state beyond the envelope (the message names it); the states have different document ids. |
| `23514` | An argument fails the domain's check. |

```sql
select crdt.yseq_value(crdt.yseq_merge(
  crdt.yseq_insert(null, 0, 'ab', replica => 'x'),
  crdt.yseq_insert(crdt.yseq_insert(null, 0, 'ab', replica => 'x'), 2, 'c', replica => 'y')
));
-- abc
select crdt.yseq_merge(n1.body, n2.body)
from notes n1, notes n2
where n1.id = 1 and n2.id = 2;
-- ERROR:  crdt.yseq_merge: the states belong to different documents (ids ... and ...)
```

### `yseq_merge_agg`

```text
crdt.yseq_merge_agg(state crdt.yseq) returns crdt.yseq
```

An aggregate: the [`yseq_merge`](#yseq_merge) of every state in the group, in any order. Nulls are skipped, and an empty group gives null. It has a combine function, so it can run in a parallel plan.

**Privileges.** `EXECUTE` to `public`. **Errors.** As `yseq_merge`.

```sql
select crdt.yseq_value(crdt.yseq_merge_agg(s))
from (values
  (crdt.yseq_insert(null, 0, 'a', replica => 'p')),
  (crdt.yseq_insert(null, 0, 'b', replica => 'q')),
  (null)
) v(s);
-- ab
```

### `yseq_apply`

```text
crdt.yseq_apply(
  state crdt.yseq,
  ops jsonb,
  replica text default crdt.current_replica_id()
) returns crdt.yseq
```

Applies ops from a writer you do not trust, whose identity is `replica`, and returns the new state. The writer's own `security definer` wrapper calls it in an `update` of your table, after checking your application's rule, while the writer has no `update` privilege on the column. `ops` is one [op](../types/collaborative-text.md#ops) or an array of ops. Null `ops` returns the state unchanged.

**Checks.** Each op is applied or refused as a whole:

1. `replica` is not null and is a replica id (non-empty, no `:`, at most 256 bytes).
2. Every op has the shape of an op and carries `v`, the writer's version vector before the op. Keys are at most 256 bytes, and an op carries at most 128 insert runs after joining runs that continue each other (4,096 before).
3. Every insert is under `replica` or `replica:<device>`. Deletes may name any character that `v` covers.
4. The causal rules V0 to V7 of the untrusted path: the origins and deletes are covered by `v`; each run starts right after `v`; `v` is causally closed; the left origin comes before the right one; the writer has not skipped a character it had seen between the origins. A run that repeats ids already present is skipped without comparing its text; an identical re-send changes nothing.
5. Quotas: at most 32 entry keys (devices) per writer in a state.

**Waiting ops.** When `v` names characters the state does not have yet (rule V7), the op waits in the state and the call returns the state with it. Every later `yseq_apply` and `yseq_merge` tries the waiting ops. One that is then refused is dropped silently: that later call succeeds, and the writer only sees that its text never appears. At most 256 insert runs plus deletes, and 64 kB of op JSON, may wait per writer.

**Default identity.** As for [`pn_apply_delta`](pn.md#pn_apply_delta): evaluated by the caller, and only as strong as whoever sets the settings it reads. Wrappers for writers with their own SQL access pass `replica => session_user::text`. The function is `IMMUTABLE`: given its arguments, including `replica`, the result is fixed.

**Privileges.** `EXECUTE` to `public`. Your wrapper needs `update` on the column.

**Errors**

| SQLSTATE | When |
| --- | --- |
| `42501` | `replica` is null (no identity); an insert carries another writer's key. |
| `22023` | `replica` is not a replica id; `ops` is not an op or an array of ops; an op, insert run or delete is malformed; an op breaks a rule or a limit (the message names it, `V0` to `V6`), when it arrives or when its `v` is covered in the same call. |
| `54000` | The writer would have more than 32 entry keys in the state, or more waiting than the quota. |

```sql
update notes
set body = crdt.yseq_apply(
  body,
  '{
    "v": {"alice": 11, "dave": 1, "erin": 1},
    "i": [["frank", 1, ["erin", 1], null, "!"]],
    "d": []
  }',
  replica => 'frank'
)
where id = 1;
select body_text from notes where id = 1;
--     body_text
-- -----------------
--  Jello, world!?!
select crdt.yseq_apply(
  body,
  '{"v": {}, "i": [["gina", 1, null, null, "?"]], "d": []}',
  replica => 'frank'
)
from notes
where id = 1;
-- ERROR:  crdt.yseq_apply: replica 'frank' cannot insert characters of replica 'gina'
select crdt.yseq_apply(
  body,
  '{"v": {}, "i": [["frank", 2, null, null, "?"]], "d": []}',
  replica => 'frank'
)
from notes
where id = 1;
-- ERROR:  crdt.yseq_apply: op rejected (V2: a run does not start at v[replica] + 1)
select crdt.yseq_apply(
  body,
  '{
    "v": {"erin": 1, "frank": 1},
    "i": [["frank", 2, ["frank", 1], null, "?"]],
    "d": []
  }',
  replica => 'frank'
)
from notes
where id = 1;
-- ERROR:  crdt.yseq_apply: op rejected (V3: v is not causally closed)
```

The last op's `v` claims erin's character but not the characters it depends on (`dave` 1, `alice` 11): a writer cannot have seen one without the others.

### `yseq_is_valid`

```text
crdt.yseq_is_valid(state jsonb) returns boolean
```

The full validator: the envelope as the domain checks it, every chunk (text length, run layout), every run, the version vector (each key's runs cover 1 to its count exactly), the origins, and the waiting ops. Null for null. It sorts every run, so it costs much more than the domain check. Use it in tests, or in a table `check` where states come from outside.

**Privileges.** `EXECUTE` to `public`. **Errors.** None: an invalid value gives `false`.

```sql
select crdt.yseq_is_valid(body) from notes where id = 1;
-- t
select crdt.yseq_is_valid('{"t": "pn"}');
-- f
```

## Limits

| Limit | Value | Past it |
| --- | --- | --- |
| An entry key | 256 bytes; the replica id without `:` | `22023` |
| Entry keys (devices) per writer in a state (`yseq_apply`) | 32 | `54000` |
| Insert runs in one op (`yseq_apply`) | 128 after joining runs that continue each other, 4,096 before | `22023` |
| Waiting ops per writer (`yseq_apply`) | 256 insert runs plus deletes, and 64 kB of op JSON | `54000` |
| Positions, lengths, and characters per entry key | `integer` (2,147,483,647) | `22003` or `22023` |
| Database encoding | UTF8 | Functions that send deleted characters fail. |

Cost and size are the real limits:

- **Every edit rewrites the whole value.** A one-character edit writes a new copy of the state, TOAST included. In the benchmarks the WAL of one keystroke was about 3.4 kB at 1 kB of text, 7.1 kB at 5 kB, 18.5 kB at 20 kB and 78.7 kB at 100 kB, and a state crosses the 2 kB TOAST threshold at under 1 kB of text.
- **TOAST churn at keystroke rate.** Every edit leaves a dead copy of the value, which only `VACUUM` reclaims; under default autovacuum a table of documents edited per keystroke settles at many times its live size, and at 100 kB documents autovacuum could not keep up. Use `compression lz4` on the column, and tune autovacuum for that table or use [`ydoc_`](ydoc.md) when documents are large and edited per keystroke.
- **No tombstone collection.** Deleted characters stay in the state as runs (without their text), so the state grows with the edit history, not only with the text.
- **No equivocation detection.** A run that repeats ids already present is skipped without comparing its text, so two writers that share one entry key lose text silently. Give each editor and device its own key, and merge only states from servers you trust.
- **Merge, apply and ops_since are O(document).** [`yseq_merge`](#yseq_merge), [`yseq_apply`](#yseq_apply) and [`yseq_ops_since`](#yseq_ops_since) read every run of the state on each call.
- **The base of a three-way save is a whole state.** A form sends back the whole value it read, not a small token.
- **Edits return the state, not the op.** Use [`yseq_diff`](#yseq_diff) for the op.

The measurements, with their setup, are in the [text benchmarks](../../research/benchmarks/text.md) and the [vacuum, bloat and WAL benchmarks](../../research/benchmarks/vacuum-wal.md). See [Limits](limits.md) for the limits of the extension as a whole.
