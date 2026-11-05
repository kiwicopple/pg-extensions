# Collaborative text functions

Every function of collaborative text, in schema `crdt`. A document lives in the extension's tables and is named by a `text` id, which the client may choose: see [Collaborative text](../types/collaborative-text.md) for the model, the op format and what it cannot do, [Shared](shared.md) for naming and replica ids, and [Errors](errors.md) for every SQLSTATE. To build an application with them, follow [Collaborative text for a blog post](../guides/collaborative-text.md).

Unless an entry says otherwise, a function:

- is `VOLATILE`, not `STRICT`, and not `security definer`;
- pins `search_path` to `pg_catalog, pg_temp`;
- has `EXECUTE` granted to `public`, and runs with the caller's privileges on the [tables](#tables), which nobody but their owner has at install. Without them, a call fails with `42501` (`permission denied for table ydoc_docs`);
- raises `P0002` for a document that does not exist (the readers [`ydoc_value`](#ydoc_value), [`ydoc_length`](#ydoc_length) and [`ydoc_base`](#ydoc_base) return null instead);
- looks the document up by its id and locks its row in one step when it writes, so writes to one document run one at a time (see [Concurrency](../types/collaborative-text.md#concurrency)).

Positions and lengths count Unicode code points. A `replica` argument of a local edit is an [entry key](shared.md#replica-ids-and-entry-keys) of at most 256 bytes, which trusted code supplies.

| Function | Returns | Purpose |
| --- | --- | --- |
| [`ydoc_create(id)`](#ydoc_create) | `text` | A new, empty document, with the id you give or a random UUID. |
| [`ydoc_value(doc)`](#ydoc_value) | `text` | The text. |
| [`ydoc_length(doc)`](#ydoc_length) | `integer` | The length of the text, in code points. |
| [`ydoc_version(doc)`](#ydoc_version) | `jsonb` | The version vector. |
| [`ydoc_base(doc)`](#ydoc_base) | `jsonb` | The version a form starts from, for `ydoc_set`. |
| [`ydoc_insert(doc, pos, chars, replica)`](#ydoc_insert) | `jsonb` | Local edit: insert text at a position. |
| [`ydoc_delete(doc, pos, len, replica)`](#ydoc_delete) | `jsonb` | Local edit: delete a range. |
| [`ydoc_set(doc, new_text, replica, base)`](#ydoc_set) | `jsonb` | Local edit: replace the whole text, two-way or three-way. |
| [`ydoc_apply(doc, ops, replica)`](#ydoc_apply) | `text` | Apply ops from a writer you do not trust. |
| [`ydoc_merge(doc, ops)`](#ydoc_merge) | `void` | Apply ops from a peer you trust. |
| [`ydoc_ops_since(doc, vv)`](#ydoc_ops_since) | `jsonb` | The ops a copy at version `vv` lacks. |
| [`ydoc_compact(doc, horizon)`](#ydoc_compact) | `integer` | Maintenance: merge rows that continue one run. |
| [`ydoc_rejected_purge(doc, writer)`](#ydoc_rejected_purge) | `integer` | Maintenance: delete the rejection log of a document. |
| [`ydoc_drop(doc)`](#ydoc_drop) | `void` | Delete a document and its rows. |

Functions whose names start with `_ydoc_` are internal. They are granted to `public` because the functions above call them with the caller's privileges. Do not call them.

## Tables

The extension creates these tables in `crdt`. They are its members: `drop extension pg_crdt` drops them with every document. With `create extension`, they and their sequences are marked for `pg_dump` (`pg_extension_config_dump`), so a dump includes the documents.

| Table | Holds |
| --- | --- |
| `ydoc_docs` | One row per document: `uid` (the public id, `text`), `id` (an internal `bigint`, which the other tables use), visible length, write counter, compaction horizon. Reference `ydoc_docs (uid)` from your tables. |
| `ydoc_replicas` | The entry keys of each document, as small integers. |
| `ydoc_items` | One row per run of characters: ids, origins, text, tombstone, order label. |
| `ydoc_blocks` | A positional index over the rows. |
| `ydoc_pending`, `ydoc_pending_deletes` | Inserts and deletes whose dependencies have not arrived (the trusted path). |
| `ydoc_deps` | Per writer, the characters its inserts depend on (the untrusted path). |
| `ydoc_pending_ops` | Untrusted ops that wait for characters named in their `v`. |
| `ydoc_rejected` | Waiting ops that were refused when they were decided, by a later call: `writer`, `op`, `reason`, `at`. The last 100 per writer and document are kept. You may read its rows; [`ydoc_rejected_purge`](#ydoc_rejected_purge) deletes them. |

Sequences: `ydoc_ins` (integration order) and the identity sequences of `ydoc_docs`, `ydoc_pending_ops` and `ydoc_rejected`.

Grant all of them to the role that owns your wrapper functions, and to no client role:

```sql
create role app_owner nologin;
grant select, insert, update, delete
  on crdt.ydoc_docs, crdt.ydoc_replicas, crdt.ydoc_items,
     crdt.ydoc_blocks, crdt.ydoc_pending,
     crdt.ydoc_pending_deletes, crdt.ydoc_deps,
     crdt.ydoc_pending_ops, crdt.ydoc_rejected
  to app_owner;
grant references on crdt.ydoc_docs to app_owner;  -- for foreign keys to ydoc_docs (uid)
grant usage on all sequences in schema crdt to app_owner;
```

## Functions

The examples on this page continue from each other. Run them in order, as the database owner, in a test database. They use the document ids `welcome` and `other`.

### `ydoc_create`

```text
crdt.ydoc_create(id text default gen_random_uuid()::text) returns text
```

Creates an empty document and returns its id: `id`, or a random UUID in text form when you pass none. The argument is named `id`, so `ydoc_create(id => 'post:123')` works.

An id is non-empty, at most 256 bytes, with no control characters (the C0 controls, DEL and the C1 controls), and is compared byte for byte: `Post` and `post` are two documents. Anything that fits is allowed, so a UUID, a UUIDv7 or ULID, a Yjs room name or an application key all work. When the client chooses the id, it should be random, so that nobody can guess it.

Creating is not idempotent. An id that exists raises `23505`, and the function never returns, resets or replaces the existing document. That is deliberate: if it returned the existing document, anyone could take over a document by creating its predictable id first. If you chose the id, check in your application that you own the document (record the owner when you create it, in your own table), and handle `23505` in your wrapper: see [Create a document with a client-chosen id](../guides/collaborative-text.md#create-a-document-with-a-client-chosen-id). Two sessions that create the same id at once get one success and one `23505`.

An id names a document and grants nothing: knowing or creating it gives no right to read or edit it, and that a document exists is never proof that the caller owns it. Access is decided by the table privileges and your wrappers.

The default is evaluated in the caller's context, so it names `pg_catalog.gen_random_uuid()`; a function of that name earlier in the caller's `search_path` is not used.

**Privileges.** `EXECUTE` to `public`, and the [table grants](#tables).

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22023` | `id` is null, empty, longer than 256 bytes or has a control character. |
| `23505` | A document with this id exists. The message says so and the hint explains why creating is not idempotent. |

```sql
select crdt.ydoc_create('welcome');
-- welcome
select crdt.ydoc_create('welcome');
-- ERROR:  crdt.ydoc_create: document 'welcome' already exists
-- HINT:  Documents are not created idempotently. If you chose this id, check in your app that you own the document.
select crdt.ydoc_create('');
-- ERROR:  crdt.ydoc_create: '' is not a document id
-- HINT:  A document id is non-empty text of at most 256 bytes without control characters. Omit it for a random UUID.
select crdt.ydoc_create('other');
-- other
select length(crdt.ydoc_create());
-- 36
```

### `ydoc_value`

```text
crdt.ydoc_value(doc text) returns text
```

The text of the document: its visible characters in order. `''` for an empty document, null for a document that does not exist or a null `doc`.

**Labels.** `STABLE PARALLEL SAFE`, `LANGUAGE sql` with a SQL-standard body (no pinned `search_path`). Because it reads tables, it cannot be used in a generated column or an index expression: keep a text column for search (see [Search the posts](../guides/collaborative-text.md#search-the-posts)). Its cost grows with the document: it reads every row.

**Privileges.** `EXECUTE` to `public`, and `select` on the [tables](#tables). **Errors.** None of its own.

### `ydoc_length`

```text
crdt.ydoc_length(doc text) returns integer
```

The length of the text in code points, from a counter on the document's row (it does not read the text). Null for a document that does not exist.

**Labels.** `STABLE PARALLEL SAFE`, `LANGUAGE sql` with a SQL-standard body. **Privileges.** `select` on the [tables](#tables). **Errors.** None of its own.

### `ydoc_version`

```text
crdt.ydoc_version(doc text) returns jsonb
```

The version vector `{key: highest seq}` of the characters the document has integrated, one index probe per entry key. `{}` for an empty document. Pass it to another copy's [`ydoc_ops_since`](#ydoc_ops_since) to get what this copy lacks.

**Labels.** `STABLE PARALLEL SAFE`. **Privileges.** `select` on the [tables](#tables). **Errors.** `P0002`: the document does not exist. (A missing document is an error, not `{}`: a peer that takes `{}` for "nothing yet" would ask for the whole history of a mistyped id.)

### `ydoc_base`

```text
crdt.ydoc_base(doc text) returns jsonb
```

The version a form starts from: `{"d": the document's id, "g": write counter, "v": version vector}`. Read it in the same statement as the text and pass it back to [`ydoc_set`](#ydoc_set). `g` counts the write calls to the document, and is the value that [`ydoc_compact`](#ydoc_compact)'s horizon is compared with. Null for a document that does not exist.

**Labels.** `STABLE PARALLEL SAFE`, `LANGUAGE sql` with a SQL-standard body. **Privileges.** `select` on the [tables](#tables). **Errors.** None of its own.

```sql
select crdt.ydoc_value('welcome'), crdt.ydoc_base('welcome');
--  ydoc_value |             ydoc_base
-- ------------+-----------------------------------
--             | {"d": "welcome", "g": 0, "v": {}}
```

### `ydoc_insert`

```text
crdt.ydoc_insert(
  doc text,
  pos integer,
  chars text,
  replica text
) returns jsonb
```

Inserts `chars` before the character at `pos` (0 is the start, `ydoc_length(doc)` the end), under the entry key `replica`, and returns the op it made: `{"v": version before the edit, "i": [insert], "d": []}`. Send that op to other copies (`ydoc_merge`, or `ydoc_apply` on a server that does not trust this one). Text typed directly after the same key's last character extends its row.

An empty `chars` changes nothing and returns an op with no inserts. The key must be the only writer that uses it: two writers numbering characters under one key make ops that other copies refuse.

**Privileges.** `EXECUTE` to `public`, and the [table grants](#tables).

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22004` | `pos`, `chars` or `replica` is null. |
| `22023` | `pos` is outside `0` to `ydoc_length(doc)`; `replica` is not an entry key (`''`, `a:`), or is longer than 256 bytes. |
| `P0002` | The document does not exist. |

```sql
select crdt.ydoc_insert('welcome', 0, 'Hello', replica => 'alice');
-- {"d": [], "i": [["alice", 1, null, null, "Hello"]], "v": {}}
select crdt.ydoc_insert('welcome', 5, ' world', replica => 'alice:phone');
-- {"d": [], "i": [["alice:phone", 1, ["alice", 5], null, " world"]], "v": {"alice": 5}}
select crdt.ydoc_insert('welcome', 99, 'x', replica => 'alice');
-- ERROR:  crdt.ydoc_insert: position 99 is outside the document (length 11)
```

### `ydoc_delete`

```text
crdt.ydoc_delete(
  doc text,
  pos integer,
  len integer,
  replica text
) returns jsonb
```

Deletes `len` characters from `pos` and returns the op: `{"v": ..., "i": [], "d": [deletes]}`, one delete per run of ids. The characters stay as tombstones. A delete does not record who deleted: `replica` is checked like `ydoc_insert`'s and is otherwise unused. `len` 0 changes nothing.

**Privileges.** `EXECUTE` to `public`, and the [table grants](#tables).

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22004` | `pos`, `len` or `replica` is null. |
| `22023` | The range is outside the text, or `len` is negative; `replica` is not an entry key. |
| `P0002` | The document does not exist. |

```sql
select crdt.ydoc_delete('welcome', 0, 6, replica => 'bob');
-- {"d": [["alice", 1, 5], ["alice:phone", 1, 1]], "i": [], "v": {"alice": 5, "alice:phone": 6}}
select crdt.ydoc_value('welcome');
-- world
```

### `ydoc_set`

```text
crdt.ydoc_set(
  doc text,
  new_text text,
  replica text,
  base jsonb default null
) returns jsonb
```

Replaces the text with `new_text`: it keeps the common prefix and suffix and makes one delete and one insert in between. Returns the op, like the other local edits. Setting the text it already has changes nothing.

- **Without `base`**, the diff is against the current text. A form that was opened before another save reverts that save, in the range between its first and last change.
- **With `base`**, the value of [`ydoc_base`](#ydoc_base) read together with the text the form shows, the diff is against the text at `base`, and the insert is placed relative to that version. Saves of different places from the same base all survive. A form may save several times from one base: the text at the base includes the edits made since under the same `replica`, so the second save does not insert the first one's text again.

**Privileges.** `EXECUTE` to `public`, and the [table grants](#tables).

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22004` | `new_text` or `replica` is null. |
| `22023` | `base` is not a version of this document (another document's base, or a malformed value); `base` is older than the document's last compaction horizon (re-read the text and base, or save without a base); `replica` is not an entry key. |
| `P0002` | The document does not exist. |

```sql
select crdt.ydoc_set('welcome', 'Hello, world', replica => 'carol');
-- {"d": [], "i": [["carol", 1, null, ["alice", 1], "Hello, "]], "v": {"alice": 5, "alice:phone": 6}}
select crdt.ydoc_set(
  'welcome',
  'x',
  replica => 'carol',
  base => '{"d": "other", "g": 0, "v": {}}'
);
-- ERROR:  crdt.ydoc_set: base is not a version of document 'welcome'
```

### `ydoc_apply`

```text
crdt.ydoc_apply(
  doc text,
  ops jsonb,
  replica text default crdt.current_replica_id()
) returns text
```

Applies ops from a writer you do not trust, whose identity is `replica`. The writer's own `security definer` wrapper calls it after checking your application's rule. Returns `'accepted'` when the op was applied, `'pending'` when it waits, and null for null `ops`.

**Checks.** The op is applied or refused as a whole:

1. `replica` is not null and is a replica id (non-empty, no `:`, at most 256 bytes).
2. The op has the shape of an [op](../types/collaborative-text.md#ops) and carries `v`, the writer's version vector before the op.
3. Every insert is under `replica` or `replica:<device>`. Deletes may name any character.
4. The causal rules V0 to V7 of the untrusted path: the origins and deletes are covered by `v`; each run starts right after `v`; `v` is causally closed; the left origin comes before the right one; the writer has not skipped a character it had seen between the origins. A run that reuses ids with other text or origins is refused (equivocation); an identical re-send is accepted and changes nothing.
5. Quotas: at most 256 runs per op (after joining runs that continue each other), 16 device keys per owner and document, and 250,000 rows read for the checks of one op.

**Waiting ops.** When `v` names characters this document does not have yet (rule V7), the op is stored and the call returns `'pending'`. Every later write to the document tries the waiting ops. One that is then refused is recorded in `crdt.ydoc_rejected` instead of failing that later write. At most 100 waiting ops and 256 kB per writer and document.

**Default identity.** As for [`pn_apply_delta`](pn.md#pn_apply_delta): evaluated by the caller, and only as strong as whoever sets the settings it reads. Wrappers for writers with their own SQL access pass `replica => session_user::text`.

**Privileges.** `EXECUTE` to `public`, and the [table grants](#tables).

**Errors**

| SQLSTATE | When |
| --- | --- |
| `42501` | `replica` is null (no identity); an insert carries another writer's key. |
| `22023` | `replica` is not a replica id; the op is malformed or has no `v`; it breaks a rule (the message names it, `V0` to `V6`); it reuses ids with other content or origins. |
| `54000` | A quota: too many runs in one op, too many device keys, origins too far apart, too many waiting ops for this writer. |
| `P0002` | The document does not exist. |

```sql
select crdt.ydoc_apply(
  'welcome',
  '{
    "v": {"alice": 5, "alice:phone": 6, "carol": 7},
    "i": [["dave", 1, ["alice:phone", 6], null, "!"]],
    "d": []
  }',
  replica => 'dave'
);
-- accepted
select crdt.ydoc_apply(
  'welcome',
  '{"v": {}, "i": [["erin", 1, null, null, "?"]], "d": []}',
  replica => 'dave'
);
-- ERROR:  crdt.ydoc_apply: replica 'dave' cannot insert characters of replica 'erin'
```

### `ydoc_merge`

```text
crdt.ydoc_merge(doc text, ops jsonb) returns void
```

Applies ops from a peer you trust: another server's [`ydoc_ops_since`](#ydoc_ops_since), a sync job, a replay of ops you stored. It checks only the shape of the op and ignores `v`. Inserts whose origins have not arrived, and deletes of characters not seen yet, are kept and applied when they arrive. Ops may come in any order and any number of times. Ids that are already present must carry the same text and origins. A null `ops` changes nothing.

> **Warning:** do not pass ops from clients to `ydoc_merge`. A writer that chooses its own origins can make two servers order the same text differently, and they never converge. Clients go through `ydoc_apply`.

**Privileges.** `EXECUTE` to `public`, and the [table grants](#tables).

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22023` | The op is malformed; an insert reuses ids with other text or origins. |
| `P0002` | The document does not exist. |

### `ydoc_ops_since`

```text
crdt.ydoc_ops_since(doc text, vv jsonb default '{}') returns jsonb
```

The ops that a copy at version `vv` lacks, as one op without `v`: `{"i": [...], "d": [...]}`. The inserts are the characters above `vv`, in the order this document integrated them, which is causal, so the receiver can apply them without waiting; consecutive rows of one run are joined. The deletes are every delete this document knows, because deletes carry no clock (applying one twice is harmless). With the default `{}` (or null), it returns the whole document.

Give the result to [`ydoc_merge`](#ydoc_merge) on a server, or to a client's own implementation. It has no `v`, so `ydoc_apply` refuses it.

**Labels.** `STABLE`. **Privileges.** `select` on the [tables](#tables).

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22023` | `vv` is not an object of whole numbers from 0. |
| `P0002` | The document does not exist. |

```sql
select crdt.ydoc_ops_since('welcome', crdt.ydoc_version('welcome'));
-- {"d": [["alice", 1, 5], ["alice:phone", 1, 1]], "i": []}
select crdt.ydoc_ops_since('welcome', '{"alice": 5, "alice:phone": 6}');
-- {"d": [["alice", 1, 5], ["alice:phone", 1, 1]], "i": [["carol", 1, null, ["alice", 1], "Hello, "], ["dave", 1, ["alice:phone", 6], null, "!"]]}
```

### `ydoc_compact`

```text
crdt.ydoc_compact(doc text, horizon bigint default null) returns integer
```

Maintenance. Merges adjacent rows that continue one run (consecutive ids of one key, typed one after the other) and have the same visibility: both visible, both deleted by the same write, or both deleted at or before `horizon`, a value of the document's write counter (`g` in [`ydoc_base`](#ydoc_base)). The default is the current write counter. Returns the number of rows removed. The text, the version and the text of `ydoc_ops_since` do not change.

The horizon is stored on the document, and [`ydoc_set`](#ydoc_set) refuses a base older than it. Choose the oldest base you want to accept, for example the write counter at the previous run of your job. It reads every row of the document while it holds the document's lock. See [Compact on a schedule](../guides/collaborative-text.md#compact-on-a-schedule).

**Privileges.** `EXECUTE` to `public`, and the [table grants](#tables).

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22023` | `horizon` is negative or above the document's write counter. |
| `P0002` | The document does not exist. |

```sql
select crdt.ydoc_compact('welcome');
-- 0
```

### `ydoc_rejected_purge`

```text
crdt.ydoc_rejected_purge(doc text, writer text default null) returns integer
```

Maintenance. Deletes the rows of the document in [`ydoc_rejected`](#tables), the log of waiting ops that were refused when they were decided. With `writer`, only that writer's rows; with the default null, every writer's. Returns the number of rows deleted. The log already keeps only the last 100 per writer and document, so you need this only to empty it after you have read it, for example from the job that tells writers their ops were refused. Other documents, the waiting ops and the text are not touched. It takes the document's lock, like a write.

**Privileges.** `EXECUTE` to `public`, and the [table grants](#tables).

**Errors**

| SQLSTATE | When |
| --- | --- |
| `22004` | `doc` is null. |
| `P0002` | The document does not exist. |

```sql
select crdt.ydoc_rejected_purge('welcome', 'mallory');
-- 3
select crdt.ydoc_rejected_purge('welcome');
-- 1
```

### `ydoc_drop`

```text
crdt.ydoc_drop(doc text) returns void
```

Deletes the document and every row that belongs to it, including its waiting ops and rejections. If a row of your table references the document with a foreign key, delete that row first.

**Privileges.** `EXECUTE` to `public`, and the [table grants](#tables). **Errors.** `P0002`: the document does not exist; `23503` (from Postgres): a row of yours still references it.

```sql
select crdt.ydoc_drop('welcome');
select crdt.ydoc_value('welcome') is null as gone;
-- t
```

## Limits

| Limit | Value | Past it |
| --- | --- | --- |
| A document id | 256 bytes; no control characters | `22023` |
| An entry key | 256 bytes; the replica id without `:` | `22023` |
| Device keys per owner and document (`ydoc_apply`) | 16 | `54000` |
| Runs in one op (`ydoc_apply`, after joining runs that continue each other) | 256 | `54000` |
| Rows read to check one op (`ydoc_apply`) | 250,000 | `54000` |
| Waiting ops per writer and document (`ydoc_apply`) | 100 ops and 256 kB | `54000` |
| Rejected ops kept per writer and document | 100 | The oldest are deleted. |
| Characters in one row | 256 when typed; up to about 512 after `ydoc_compact` | A new row. |
| Positions, lengths, and characters per entry key | `integer` (2,147,483,647) | `22003` from Postgres, or `22023` |

See [Limits](limits.md) for the limits of the extension as a whole.
