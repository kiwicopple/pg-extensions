# Collaborative text

Collaborative text is a plain-text document that several writers edit at the same time, online or offline, and that converges to the same text wherever the edits are merged. The algorithm is a sequence CRDT with the YjsMod ordering rule, as in Yjs and in Seph Gentle's reference CRDTs. The extension stores it in two ways, with the same algorithm and the same op format:

- **A column type, `crdt.yseq`** (functions `yseq_`), **experimental**. The whole document is one `jsonb` value in a column of your table, like a [PN-Counter](pn-counter.md). This is the simpler one to use, and the one to start with for documents of a few kilobytes.
- **Documents in tables** (functions `ydoc_`). A document lives in tables of the extension, one row per run of characters, and your table holds its id. An edit writes a few rows instead of rewriting the document.

```sql
create table posts (
  id bigint primary key,
  body crdt.yseq not null default crdt.yseq_new(),
  body_text text generated always as (crdt.yseq_value(body)) stored
);

create table pages (
  id bigint primary key,
  body_doc text not null references crdt.ydoc_docs (uid)
);
```

The design and the measurements behind the two shapes are in the research record: [`research/text.md`](../../research/text.md), the [text benchmarks](../../research/benchmarks/text.md) and the [vacuum, bloat and WAL benchmarks](../../research/benchmarks/vacuum-wal.md). For a complete application with either shape, follow [Collaborative text for a blog post](../guides/collaborative-text.md).

## Choose a shape

| | `yseq_` column (experimental) | `ydoc_` tables |
| --- | --- | --- |
| Where the document is | In your row, a `crdt.yseq` value | In the extension's tables; your row holds a `text` id |
| Cost of one edit | Rewrites the whole value: grows with the document | Writes a few rows: about the same at any size |
| Size of a 5 kB post, in the benchmarks | about 6 kB | about 24 kB across the tables |
| Generated column, index, full-text search | `yseq_value` is `IMMUTABLE`: yes, directly | `ydoc_value` reads tables: keep a text column yourself |
| Row-level security, triggers, change feeds on your table | See every edit | See nothing of the edits |
| Who may write | Your table's privileges, as for any column | Grants on the extension's tables, given to your wrappers |
| Base of a three-way save from a form | The whole value the form read | A small version token (`ydoc_base`) |
| Deleted characters | Kept as runs without their text, forever | Kept with their text; `ydoc_compact` merges rows |
| Untrusted writers | `yseq_apply`: about 8 times the time of `ydoc_apply` per call on the automerge-paper trace, in the benchmarks | `ydoc_apply` |
| `drop extension` | Blocked (`2BP01`) while a column uses `crdt.yseq`; `cascade` drops the columns | Drops every document, unless a foreign key points at them |
| [JavaScript client](../reference/client.md) | Not yet: your transport calls `yseq_apply` and `yseq_ops_since` itself | Yes |

Use the column for documents of a few kilobytes that are saved from forms or edited at a modest rate, where having the text in your row, indexable and visible to your policies and triggers, matters most. Use `ydoc_` for large documents, documents edited per keystroke by many people, and documents written by many untrusted writers: its cost per edit does not grow with the document. The limits of the column are in [The column type](#the-column-type-yseq_) below, with the numbers.

## The column type: `yseq_`

> **Experimental.** `yseq_` is part of the extension and tested like the rest of it, but its cost grows with the document and it never forgets deleted characters. Read the [limits](#limits-of-the-column) before you choose it for large or heavily edited documents.

A `crdt.yseq` value is the whole document: the visible text, the ids and origins of every character, the deleted characters (without their text) and the version vector. You write it like any column, in one statement, so the row lock makes concurrent writes safe, as for a [PN-Counter](pn-counter.md):

```sql
create table notes (
  id bigint primary key,
  body crdt.yseq not null default crdt.yseq_new()
);
insert into notes (id) values (1);

update notes
set body = crdt.yseq_insert(body, 0, 'Hello world', replica => 'alice')
where id = 1;
update notes
set body = crdt.yseq_insert(body, 5, ',', replica => 'bob')
where id = 1;

select crdt.yseq_value(body) from notes where id = 1;
-- Hello, world
```

`yseq_new()` gives the document an id, so that a state from another row cannot be merged into it or used as its base by mistake. The edit functions return the new state, not the op they made: when you need the op, to send it to other copies, take `crdt.yseq_diff(old, new)` in the same statement (see [`yseq_diff`](../reference/yseq.md#yseq_diff)).

**Merging two copies** of a document, from two servers or from an offline client you trust, is `yseq_merge`. Here two states stand for the copies on two servers:

```sql
select crdt.yseq_value(crdt.yseq_merge(
  crdt.yseq_insert(body, 12, '!', replica => 'carol'),
  crdt.yseq_insert(body, 0, '> ', replica => 'dave')
))
from notes
where id = 1;
-- > Hello, world!
```

**Saving a whole text from a form** uses `yseq_set` with the value the form read as its base: `update notes set body = crdt.yseq_set(body, $1, $2, base => $3)`. The new text is diffed against the base, so concurrent saves that changed different places both survive. See [`yseq_set`](../reference/yseq.md#yseq_set).

**Untrusted writers** send ops, which their `security definer` wrapper passes to `yseq_apply` in an `update` of your table. It applies the same rules as `ydoc_apply` (see [Trusted and untrusted writers](#trusted-and-untrusted-writers)). The writers themselves get no `update` privilege on the column. A copy that is behind asks for `yseq_ops_since(body, its_version)`.

**The text is in your row.** `yseq_value` is `IMMUTABLE`, so a stored generated column, an expression index and a full-text index can use it, and row-level security, triggers and logical decoding on your table see every edit. Back it up and restore it with your table.

### Limits of the column

These are measured in the [text benchmarks](../../research/benchmarks/text.md) and the [vacuum, bloat and WAL benchmarks](../../research/benchmarks/vacuum-wal.md), single runs on a laptop that show how the cost grows, not what you will get:

- **Every edit rewrites the whole value.** A one-character edit writes a new copy of the state. The WAL of one keystroke was about 3.4 kB at 1 kB of text, 7.1 kB at 5 kB, 18.5 kB at 20 kB and 78.7 kB at 100 kB, and the state crosses the 2 kB TOAST threshold at under 1 kB of text.
- **TOAST churn at keystroke rate.** Each edit leaves a dead copy of the value until `VACUUM` reclaims it. Under default autovacuum a table of documents edited per keystroke settles at many times its live size, VACUUM makes the space reusable without returning it, and at 100 kB documents and 200 keystrokes a second autovacuum did not keep up. This is how Postgres treats any large value that is rewritten often: from 5 kB up, a plain `text` column with the same edits bloated and logged within 1.1 to 1.6 times as much. Put `compression lz4` on the column, and tune autovacuum for the table, or use `ydoc_`, when documents are large and edited per keystroke.
- **No tombstone collection.** Deleted characters stay in the state as runs, without their text, so the state grows with the edit history and not only with the text.
- **No equivocation detection.** A run that repeats ids already present is skipped without comparing its text. Two writers that share one entry key lose text silently: give each editor and device its own key, and merge only states from servers you trust.
- **Merge, apply and ops_since are O(document).** `yseq_merge`, `yseq_apply` and `yseq_ops_since` read every run of the state on every call.
- **A three-way save sends the whole state.** The base of `yseq_set` is the value the form read, not a small token, because the state does not keep the text of deleted characters.
- **Edits return the state, not the op.** Use `yseq_diff(old, new)` for the op.
- **UTF8 databases only.** In another encoding, the functions that send deleted characters fail on a state that has any.

Every function and its errors: [Collaborative text column functions](../reference/yseq.md).

### Benchmarks of `yseq_`

Edits to a `yseq_` column are cheap while the document is small or saved at save rate, and they get expensive as the document grows or is edited per keystroke. Every edit rewrites the whole value, so WAL per keystroke grew with the document in the benchmarks, from 3,376 bytes at 1 kB of text to 78,733 bytes at 100 kB, and every old value stays as dead TOAST until `VACUUM` reclaims it. Under default autovacuum, a table of documents edited per keystroke settled at about 100 times its live data (103 to 109 times at 5 and 20 kB), and at 100 kB documents and 200 keystrokes a second autovacuum did not keep up: 2,016 MB after 3 minutes, for about 7 MB of live data. At save rate, one save of a 5 kB post took 0.45 to 3.15 ms and about 13 to 14 kB of WAL; bloat at save rate was not measured, and the formula in the vacuum benchmarks predicts proportionally less.

Size on disk, 1,001 posts of about 5 kB after `vacuum full` ([text benchmarks](../../research/benchmarks/text.md), storage):

| Column | kB per post | Total against plain text (pglz) |
| --- | ---: | ---: |
| plain `text`, pglz (default) | 4.2 | 1.00 |
| plain `text`, `compression lz4` | 5.6 | 1.32 |
| `yseq_`, pglz | 5.7 | 1.34 |
| `yseq_`, `compression lz4` | 6.3 | 1.48 |

With a GIN index on `to_tsvector('english', crdt.yseq_value(body))`, a `yseq_` post took 9.7 kB, against 7.6 kB for plain text with the same index (1.27 times).

Latency of one keystroke: a one-character insert at a random position in the first half, one per transaction, 1,000 transactions, mean in ms with the client round trip included (text benchmarks, size sweep). The GIN column recomputes `to_tsvector` for the whole text on every update.

| Text size | plain `text` (lz4) | `yseq_` | `yseq_` with GIN |
| ---: | ---: | ---: | ---: |
| 1 kB | 0.03 | 0.21 | 0.35 |
| 5 kB | 0.06 | 0.29 | 0.78 |
| 20 kB | 0.15 | 0.39 | 2.34 |
| 50 kB | 0.33 | 0.53 | 5.35 |
| 100 kB | 0.62 | 0.89 | 10.3 |

WAL per keystroke in bytes for the same kind of edit, on 100 documents per size with a 40-edit history ([vacuum benchmarks](../../research/benchmarks/vacuum-wal.md)). 'Cold' starts right after a checkpoint and 'warm' does not. The last row comes from the text benchmarks, an earlier run on an older version of the code and different documents. It measured more WAL for the same edit, and both runs show the WAL growing with the document.

| WAL bytes per keystroke | 1 kB | 5 kB | 20 kB | 100 kB |
| --- | ---: | ---: | ---: | ---: |
| plain `text` (lz4), cold | 541 | 5,292 | 16,504 | 76,648 |
| `yseq_` (lz4), cold | 3,376 | 7,118 | 18,459 | 78,733 |
| `yseq_` (lz4), warm | 3,706 | 7,449 | 18,419 | 75,978 |
| `yseq_` in the text benchmarks | 11,123 | 19,168 | 36,664 | 122,390 |

From 5 kB up, 96 to 100% of the `yseq_` WAL is the new TOAST chunks, that is, the whole compressed value, and 0 to 4% is full-page images. From 5 kB up, `yseq_` was within 1.1 to 1.6 times a plain `text` column with the same edits in bloat and WAL (2.2 times in one autovacuum run), because this is how Postgres treats any large value that is rewritten often. The difference is at the bottom of the range: the `yseq_` state is already a 2.4 kB TOASTed value at 1 kB of text, where plain text stays inline and HOT pruning cleans up (95 MB against 2.29 MB after 20,000 keystrokes on 100 documents).

Bloat of 100 documents in MB, with the number of times the live data in parentheses. 'Autovacuum off' is after 20,000 keystrokes and before `VACUUM`. 'Default autovacuum' is the size at the end of 3 minutes at 200 keystrokes a second, spread over the 100 documents. After `VACUUM`, 97 to 98% of the TOAST file was reusable and none of it was returned; only `VACUUM FULL` returns it.

| Text size | `yseq_`, autovacuum off | plain `text`, autovacuum off | `yseq_`, default autovacuum | plain `text`, default autovacuum |
| ---: | ---: | ---: | ---: | ---: |
| 1 kB | 95.5 (158x) | 2.29 (17x) | 88 (107x) | 1.25 (8x) |
| 5 kB | 168 (163x) | 106 (238x) | 140 (103x) | 65 (140x) |
| 20 kB | 372 (182x) | 312 (222x) | 267 (109x) | 192 (130x) |
| 100 kB | 1,420 (198x) | 1,344 (207x) | 2,016 (264x) | 1,784 (272x) |

Under random-position keystrokes the `yseq_` table did not settle, because each edit splits a run and the value keeps growing: 100 documents of 5 kB went from 0.7 MB to 140 MB at 3 minutes and 336 MB at 10 minutes, against 65 to 80 MB for plain text. Typing at the end of the document fragments less, and the same 5 kB run settled at 95 to 122 MB. At 100 kB and 200 keystrokes a second, plain text reached 3,885 MB (574 times live) in 10 minutes and was still rising, so a table like that needs its autovacuum tuned.

Form saves and concurrent writers, by document size (text benchmarks). WAL is per save. '8 sessions' means 8 clients, each inserting one character per transaction, either into one post or each into its own post; tps is as `pgbench` reports it. No edit was lost, and no transaction failed under `read committed`.

| Case | 5 kB post | 100 kB post |
| --- | ---: | ---: |
| three-way save (`yseq_set` with a base) | 3.15 ms, 13,975 B | 11.8 ms, 118,152 B |
| two-way save (no base) | 0.45 ms, 13,363 B | 1.60 ms, 112,896 B |
| plain `text` (lz4) save | 0.13 ms, 6,455 B | 0.25 ms, 75,119 B |
| 8 sessions, one post | 2,035 tps, mean 3.88 ms | 951 tps, mean 8.35 ms |
| 8 sessions, own posts | 10,871 tps, mean 0.72 ms | 3,127 tps, mean 2.50 ms |

On the automerge-paper trace through `yseq_apply`, a call with 100 patches took 6.16 ms and 126,486 bytes of WAL, and a call with one op (the document growing from 0 to about 2.5 kB) took 0.73 ms and 4,500 bytes. A one-character insert into a heavily edited 100 kB post (12,397 runs, a 219,749-byte value) took 2.23 ms and 280,347 bytes of WAL. Rendering a post with `yseq_value` took 0.06 ms at 5 kB and 0.27 ms at 100 kB. In the experiment notes ([`experiments/text-column/NOTES.md`](../../experiments/text-column/NOTES.md)), `yseq_merge` of two 100 kB states took 53 ms with 100 edits on each side and 97 ms with 1,000.

Setup and caveats: Postgres 16.4 (Postgres.app) on an Apple M4 laptop, with `shared_buffers=512MB`, `full_page_writes=on` and `wal_compression=off`. The latency, WAL and bloat runs used `fsync=off`; the autovacuum runs used `fsync=on` and default autovacuum settings. Every figure is a single run. Noise is about 5%, so treat ratios of 1.3 or less as ties, and read autovacuum sizes to about 20%. The generated text is pseudo-words that compress poorly (lz4 stores 5 kB of it in 4.2 kB), so real prose would reach TOAST at a somewhat larger size. Not measured: Postgres 17 and 18, tuned autovacuum, `fillfactor`, long-running transactions that hold back `VACUUM`, replicas and logical decoding, bloat at save rate, and the effect of bloat on read latency. Full results: [text benchmarks](../../research/benchmarks/text.md) and [vacuum, bloat and WAL benchmarks](../../research/benchmarks/vacuum-wal.md).

## The table-backed documents: `ydoc_`

A `ydoc_` document lives in tables of the extension, one row per run of characters, and your table holds its id, a text.

### The document

`crdt.ydoc_create()` creates a new, empty document and returns its id, a random UUID as text. Every other function takes that id. The id is `text`, like a [replica id](../guides/replicas-and-identity.md#replica-ids-and-entry-keys), so a client can also choose it: `crdt.ydoc_create('post:123')`. The extension accepts a UUID, a UUIDv7 or ULID, a Yjs room name or an application key. An id is non-empty, at most 256 bytes, with no control characters (`22023` otherwise), and ids are compared byte for byte: `Post` and `post` are two documents.

Creating is not idempotent. An id that exists raises `23505` (`unique_violation`) and never returns the existing document, so nobody can take a document over by creating its predictable id first. If the client chose the id, your application has to check that the document is its own: see [Create a document with a client-chosen id](../guides/collaborative-text.md#create-a-document-with-a-client-chosen-id).

An id names a document and grants nothing. Knowing it, or creating it, gives no right to read or edit the document, and that a document exists is never proof of who owns it. Access follows from the [privileges on the tables](#privileges-and-the-wrapper-pattern) and from your wrappers. When the client picks the id, it should be random (a UUID, UUIDv7 or ULID), so that nobody can guess it.

**Local edits** change a document by position, under an entry key that you supply: `ydoc_insert(doc, pos, chars, replica)`, `ydoc_delete(doc, pos, len, replica)`, and `ydoc_set(doc, new_text, replica)`, which replaces the whole text with one delete and one insert (the common prefix and suffix are kept). Each returns the op it made.

**Merging** brings in ops from another copy of the document. Here two documents stand for the copies on two servers (on two real servers both copies would have the same id). Each is edited, then each takes the ops it lacks from the other:

```sql
select crdt.ydoc_create('note-a');  -- server A's copy
select crdt.ydoc_create('note-b');  -- server B's copy

select crdt.ydoc_insert('note-a', 0, 'Hello world', replica => 'alice');
select crdt.ydoc_merge('note-b', crdt.ydoc_ops_since('note-a'));

select crdt.ydoc_insert('note-a', 5, ',', replica => 'alice');
select crdt.ydoc_insert('note-b', 11, '!', replica => 'bob');

select crdt.ydoc_merge('note-b', crdt.ydoc_ops_since('note-a', crdt.ydoc_version('note-b')));
select crdt.ydoc_merge('note-a', crdt.ydoc_ops_since('note-b', crdt.ydoc_version('note-a')));

select crdt.ydoc_value('note-a') as server_a, crdt.ydoc_value('note-b') as server_b;
--    server_a    |   server_b
-- ---------------+---------------
--  Hello, world! | Hello, world!
```

`ydoc_ops_since(doc, vv)` returns what a copy at version `vv` lacks: the inserts above `vv`, in an order that the receiver can apply directly, and every delete.

**Saving a whole text from a form** uses `ydoc_set` with a base. Read `crdt.ydoc_base(doc)` in the same statement as the text, and pass it back with the new text. The new text is then diffed against the text at the base, so concurrent saves that changed different places both survive. Without a base, the diff is against the current text, and a save from a form opened before another save reverts that save, between the first and last character it changed. See [Save from a form](../guides/collaborative-text.md#save-from-a-form).

### Privileges and the wrapper pattern

The tables belong to the extension. At install, no role but their owner has privileges on them, and the `ydoc_` functions are not `security definer`: they run with the caller's privileges. So a call by any other role fails with `42501` until you grant the tables. Grant them to the role that owns your own `security definer` wrapper functions, which check your application's rule (may this user edit this post?) before they call `ydoc_apply` or `ydoc_set`. A view over `ydoc_value` does not work for readers, because the function reads the tables with the caller's privileges. Row-level security on the extension's tables is possible but not recommended: the policies are yours to maintain, and run for every row of every scan. See [Set up the roles and grants](../guides/collaborative-text.md#set-up-the-roles-and-grants).

### Concurrency

Every write locks the document's row in `crdt.ydoc_docs` first. Writes to one document run one at a time, each against the result of the one before, and writes to different documents do not wait for each other. A write never locks two documents, so writes cannot deadlock on them. Under `repeatable read` or `serializable`, a write that waited for the lock fails with `40001`; retry the transaction.

### Storage

A row holds a run of characters typed one after the other by one writer, up to 256 characters. Edits in the middle of a run split it, and deletes leave tombstone rows, so a document that is edited for a long time has more rows than it needs. `crdt.ydoc_compact(doc, horizon)` merges them again without changing the text or what peers receive. Run it on a schedule: see [Compact on a schedule](../guides/collaborative-text.md#compact-on-a-schedule).

In the benchmarks, a 5 kB blog post took about 24 kB across the tables, and the automerge-paper editing trace (about 260,000 edits, 104,852 characters) went from 149 to 26 bytes per character of text after one compaction. One-character edits took about 0.3 to 0.4 ms from 1 kB to 100 kB documents, and their WAL stayed under 2 kB. See [`research/benchmarks/text.md`](../../research/benchmarks/text.md) for the setup and every number.

### What it cannot do

- **Rich text, cursors, presence, undo.** The document is plain text, in both shapes. Formatting, selections and undo are your editor's.
- **Speak the Yjs wire format.** The ops are pg_crdt's own (see [Ops](#ops)). A client needs an implementation of the same algorithm. The [JavaScript client](../reference/client.md) has one: its engine is the reference implementation that the extension is tested against.
- **Forget deleted text.** Tombstones keep their characters, because a copy that has not seen an insert yet must receive it with its text. Compaction merges tombstone rows; it does not remove them.
- **Be indexed directly.** `ydoc_value` reads tables, so it is `STABLE`, and generated columns and expression indexes need `IMMUTABLE` functions. Keep a text column for search, refreshed on save: see [Search the posts](../guides/collaborative-text.md#search-the-posts). (The `yseq_` column can be indexed directly.)
- **Live in one row.** Your table holds an id. Row-level security, triggers and change feeds on your table do not see edits to the document. (The `yseq_` column lives in your row.)
- **Survive `drop extension`.** The tables belong to the extension: dropping it drops every document. See [Uninstall](../install.md#uninstall).

Every function, its errors and its limits: [Collaborative text functions](../reference/ydoc.md).

### Benchmarks of `ydoc_`

The cost of a `ydoc_` edit does not grow with the document, and it leaves no TOAST bloat. In the benchmarks an edit took 0.30 to 0.37 ms from 1 kB to 100 kB of text, and under default autovacuum the tables settled at 1.9 to 2.6 times their live data. The prices are disk space and checkpoints. A 5 kB post took 23.9 kB across the tables (5.64 times a plain `text` column, 3.8 times `yseq_`). The WAL records are a flat 0.8 to 1.3 kB per keystroke, but right after a checkpoint 40 to 84% of the WAL is full-page images, and checkpoints every 30 seconds instead of every 5 minutes nearly doubled it.

Size on disk, 1,001 posts of about 5 kB after `vacuum full`, with the nine `crdt.ydoc_*` tables ([text benchmarks](../../research/benchmarks/text.md), storage): 23.38 MB in total, 23.9 kB per post, which is 5.64 times plain `text` with pglz (4.15 MB) and about 230 bytes per run including indexes and side tables. A 5 kB post has 100 item rows (13,567 bytes of heap) and a 100 kB post 1,983 rows (272,153 bytes). `ydoc_compact` on all 1,001 documents took 0.5 s and removed 17% of the rows and about 6% of the bytes, because random-position edits leave runs that cannot merge. A heavily edited 100 kB post (the automerge-paper trace as replayed, 13,822 item rows) took about 1.92 MB (an estimate that includes free space of other documents), against 219,749 bytes for a `yseq_` value; how many rows a document has depends on how its edits arrived, and replaying one patch per call left 83,253 rows.

Growth under keystrokes, 100 documents, 20,000 keystrokes (80% inserts, 20% deletes, random position), all `crdt.ydoc_*` tables, in MB ([vacuum benchmarks](../../research/benchmarks/vacuum-wal.md)). 'Default autovacuum' is the size at the end of 3 minutes at 200 keystrokes a second. Most of the growth is live data (about 2 new item rows per keystroke, 0.3 to 0.5 kB with indexes), not dead rows, and 100% of the updates on the internal tables were HOT.

| Text size | Loaded | After 20,000 keystrokes, autovacuum off | Live | After / live | Reusable after `VACUUM` | Default autovacuum, 3 min |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 kB | 4.27 | 10.1 | 3.54 | 2.9 | 2.24 | 13.1 |
| 5 kB | 5.27 | 12.3 | 4.42 | 2.8 | 3.02 | 16.6 |
| 20 kB | 8.41 | 16.2 | 6.37 | 2.5 | 4.39 | 20.5 |
| 100 kB | 23.5 | 33.3 | 16.4 | 2.0 | 8.09 | 36.5 |

Keystroke latency and WAL, one-character insert at a random position, 1,000 transactions per size. Latency is the mean in ms with the client round trip included, and the WAL in the second column comes from the text benchmarks. The last two columns come from the vacuum benchmarks, on documents with a 40-edit history, and show the full-page images in parentheses as a share of the WAL ('cold' starts right after a checkpoint, 'warm' does not). The two runs differ because they used different code versions and documents, and each cold run touches different pages.

| Text size | Latency, ms | WAL bytes, text benchmarks | WAL bytes, cold (FPI share) | WAL bytes, warm (FPI share) |
| ---: | ---: | ---: | ---: | ---: |
| 1 kB | 0.30 | 861 | 1,952 (40%) | 993 (1%) |
| 5 kB | 0.32 | 1,084 | 2,390 (47%) | 1,117 (2%) |
| 20 kB | 0.34 | 1,287 | 3,461 (63%) | 1,412 (12%) |
| 100 kB | 0.37 | 1,712 | 8,341 (84%) | 2,656 (49%) |

At a steady 100 keystrokes a second over 100 documents for 90 seconds, `ydoc_` wrote 2,427 bytes per keystroke at 5 kB with checkpoints every 30 s (54% full-page images) and 1,382 with no checkpoint in the run (19%), and 5,945 (79%) and 3,154 (59%) at 100 kB. `wal_compression` cut its total WAL by 26 to 33% in the runs after `VACUUM`, where the same pages were compared; the cold runs ranged from 24% more to 58% less. For comparison, `yseq_` wrote 0.76 MB/s at 5 kB and 7.4 to 7.6 MB/s at 100 kB in the same run, and `ydoc_` 0.13 to 0.23 MB/s and 0.30 to 0.57 MB/s.

Form saves and concurrent writers, by document size (text benchmarks). WAL is per save. '8 sessions' means 8 clients, each inserting one character per transaction, either into one post or each into its own post; tps is as `pgbench` reports it. No edit was lost, and no transaction failed under `read committed`.

| Case | 5 kB post | 100 kB post |
| --- | ---: | ---: |
| three-way save (`ydoc_set` with `ydoc_base`) | 1.16 ms, 4,626 B | 3.35 ms, 7,547 B |
| two-way save (no base) | 0.83 ms, 4,627 B | 2.31 ms, 9,296 B |
| plain `text` (lz4) save | 0.13 ms, 6,455 B | 0.25 ms, 75,119 B |
| 8 sessions, one post | 2,395 tps, mean 2.91 ms | 2,056 tps, mean 3.24 ms |
| 8 sessions, own posts | 10,995 tps, mean 0.71 ms | 7,928 tps, mean 0.98 ms |

Writers to one post queue on its row in `crdt.ydoc_docs`, so same-post throughput was flat from 4 to 8 sessions; at 5 kB it was the same as `yseq_` within noise, and its p95 under contention was 1.6 to 2 times higher (9.71 against 5.96 ms at 8 sessions). Under `repeatable read` (5 kB, 8 sessions on one post), both shapes failed about 85% of the transactions with serialization failures (2,090 of 2,400 for `ydoc_`), and the application has to retry. On the automerge-paper trace through `ydoc_apply`, a call with 100 patches took 0.75 ms and 3,797 bytes of WAL, and a call with one op took 0.38 ms and 614 bytes. A one-character insert into the heavily edited 100 kB post took 0.40 ms and 4,541 bytes of WAL, and 0.40 ms and 4,521 bytes after `ydoc_compact`.

Reads: `ydoc_value` took 0.09 ms at 5 kB and 0.43 ms at 100 kB (plain `text`: 0.03 and 0.26 ms), and listing 50 posts with `left(crdt.ydoc_value(body_doc), 200)` took 1.04 ms (plain: 0.17 ms). Search needs a text column that you refresh yourself. Refreshing it on every keystroke took 1.17 ms and 26,390 bytes of WAL at 5 kB and 11.6 ms and 216,216 bytes at 100 kB, against 0.32 and 0.36 ms for the edit alone, so refresh it on save, and accept that it lags the document.

Setup and caveats: Postgres 16.4 (Postgres.app) on an Apple M4 laptop, with `shared_buffers=512MB`, `full_page_writes=on` and `wal_compression=off` unless a row says otherwise. The latency, WAL and bloat runs used `fsync=off`; the autovacuum runs used `fsync=on` and default autovacuum settings. Every figure is a single run. Noise is about 5%, so treat ratios of 1.3 or less as ties. The generated text is pseudo-words. Not measured: Postgres 17 and 18 (Postgres 18 turns on data checksums, which adds full-page images), tuned autovacuum, `fillfactor` on the documents table, long-running transactions that hold back `VACUUM`, replicas and logical decoding, `ydoc_compact` under sustained edits, and the effect of bloat on read latency. Full results: [text benchmarks](../../research/benchmarks/text.md) and [vacuum, bloat and WAL benchmarks](../../research/benchmarks/vacuum-wal.md).

## How text merges

This part holds for both shapes.

Each character has an id, `[key, seq]`: the [entry key](../guides/replicas-and-identity.md#replica-ids-and-entry-keys) of the writer that typed it, and that key's sequence number, counted from 1. Each insert also records its *origins*: the ids of the characters to its left and right when it was typed. The order of the document follows from the origins and the ids alone, so every copy that has the same characters puts them in the same order, whatever order they arrived in. Deleted characters stay as tombstones, because a later insert may name them as its origin.

Positions and lengths count Unicode code points, as `length()` and `substr()` do in Postgres, not bytes or UTF-16 units. An emoji outside the Basic Multilingual Plane is one position. A JavaScript client counts it as two (`'😀'.length` is 2), so convert positions with `Array.from(text)` or a code-point iterator. The [JavaScript client](../reference/client.md) takes UTF-16 positions and converts them.

The version of a document, `crdt.yseq_version(state)` or `crdt.ydoc_version(doc)`, is its version vector: for each entry key, the highest sequence number the document has.

**Concurrent inserts at one place do not interleave.** When two writers type at the same position at the same time, one run of text ends up before the other, the same on every copy. Characters are never mixed. Continuing the `ydoc_` example above:

```sql
select crdt.ydoc_insert('note-a', 0, 'abc ', replica => 'alice');
select crdt.ydoc_insert('note-b', 0, 'xyz ', replica => 'bob');

select crdt.ydoc_merge('note-b', crdt.ydoc_ops_since('note-a', crdt.ydoc_version('note-b')));
select crdt.ydoc_merge('note-a', crdt.ydoc_ops_since('note-b', crdt.ydoc_version('note-a')));

select crdt.ydoc_value('note-a') as server_a, crdt.ydoc_value('note-b') as server_b;
--        server_a        |       server_b
-- -----------------------+-----------------------
--  abc xyz Hello, world! | abc xyz Hello, world!
```

**Deletes** name characters by id, not by position. A character that one writer deletes while another types next to it is deleted on every copy, and the new text stays. Deleting a character twice, from two copies, deletes it once.

### Ops

Every edit can be described by an op, a `jsonb` value. `ydoc_` local edits return the op they made, `yseq_diff(old, new)` gives the op of a `yseq_` edit, `ydoc_ops_since` and `yseq_ops_since` return ops for a peer, and `ydoc_merge`, `ydoc_apply` and `yseq_apply` take them:

```json
{
  "v": {"alice": 11},
  "i": [["bob", 1, ["alice", 11], null, "!"]],
  "d": [["alice", 13, 4]]
}
```

| Key | Meaning |
| --- | --- |
| `v` | The writer's version vector before the op. Local edits and `yseq_diff` fill it in. The untrusted write path requires it; the trusted one ignores it. |
| `i` | Inserts, in order: `[key, seq, originLeft, originRight, text]`. The characters of `text` get the ids `[key, seq]`, `[key, seq + 1]`, and so on. An origin is an id, or `null` for the start or the end of the document. |
| `d` | Deletes: `[key, seq, length]`, the ids `[key, seq]` to `[key, seq + length - 1]`. A delete does not say who deleted. |

Ids are never reused, so applying an op twice changes nothing. An op whose origins have not arrived yet is kept until they do. `yseq_ops_since` sends deleted characters as U+FFFD, because the column does not keep their text; the deletes in the same op hide them.

### Trusted and untrusted writers

| Path | Functions | Checks |
| --- | --- | --- |
| Local edits | `yseq_insert`, `yseq_delete`, `yseq_set`; `ydoc_insert`, `ydoc_delete`, `ydoc_set` | The entry key must be well formed. The caller chooses it: trusted server code. |
| Trusted merge | `yseq_merge` (states); `ydoc_merge` (ops) | Only the shape. For states or ops from your own servers, a sync job or a replay. |
| Untrusted apply | `yseq_apply`, `ydoc_apply` | Inserts only under the writer's own replica id or its device keys; `v` must be present and consistent with the op and with the document (rules V0 to V7); quotas. For ops from clients. |

The untrusted path exists because a client that may choose any origins could make two servers order the same characters differently, and then they would never converge. Its rules refuse such an op as a whole, with SQLSTATE `22023` and the rule in the message, so every server decides it the same way. An op whose `v` names characters this server has not received yet waits and is decided by a later write. The rules, with the argument for why they are enough, are in [`experiments/text-ref/README.md`](../../experiments/text-ref/README.md).

## Next

- Build it into an application: [Collaborative text for a blog post](../guides/collaborative-text.md).
- Every function, its errors and the limits: [Collaborative text column functions](../reference/yseq.md) (`yseq_`) and [Collaborative text functions](../reference/ydoc.md) (`ydoc_`).
