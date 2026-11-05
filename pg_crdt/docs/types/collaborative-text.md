# Collaborative text

Collaborative text is a plain-text document that several writers edit at the same time, online or offline, and that converges to the same text wherever the edits are merged. Its functions have the prefix `ydoc_`. Unlike the [PN-Counter](pn-counter.md), it is not a column type: a document lives in tables of the extension, one row per run of characters, and your table holds its id, a text.

```sql
create table posts (
  id bigint primary key,
  body_doc text not null references crdt.ydoc_docs (uid)
);
```

The algorithm is a sequence CRDT with the YjsMod ordering rule, as in Yjs and in Seph Gentle's reference CRDTs. The design and the reasons for storing documents in tables are in the research record: [`research/text.md`](../../research/text.md) and the [text benchmarks](../../research/benchmarks/text.md). For a complete application, follow [Collaborative text for a blog post](../guides/collaborative-text.md).

## The document

`crdt.ydoc_create()` creates a new, empty document and returns its id, a random UUID as text. Every other function takes that id. The id is `text`, like a [replica id](../guides/replicas-and-identity.md#replica-ids-and-entry-keys), so a client can also choose it: `crdt.ydoc_create('post:123')`. The extension accepts a UUID, a UUIDv7 or ULID, a Yjs room name or an application key. An id is non-empty, at most 256 bytes, with no control characters (`22023` otherwise), and ids are compared byte for byte: `Post` and `post` are two documents.

Creating is not idempotent. An id that exists raises `23505` (`unique_violation`) and never returns the existing document, so nobody can take a document over by creating its predictable id first. If the client chose the id, your application has to check that the document is its own: see [Create a document with a client-chosen id](../guides/collaborative-text.md#create-a-document-with-a-client-chosen-id).

An id names a document and grants nothing. Knowing it, or creating it, gives no right to read or edit the document, and that a document exists is never proof of who owns it. Access follows from the [privileges on the tables](#privileges-and-the-wrapper-pattern) and from your wrappers. When the client picks the id, it should be random (a UUID, UUIDv7 or ULID), so that nobody can guess it.

Each character has an id, `[key, seq]`: the [entry key](../guides/replicas-and-identity.md#replica-ids-and-entry-keys) of the writer that typed it, and that key's sequence number, counted from 1. Each insert also records its *origins*: the ids of the characters to its left and right when it was typed. The order of the document follows from the origins and the ids alone, so every server that has the same characters puts them in the same order, whatever order they arrived in. Deleted characters stay as tombstones, because a later insert may name them as its origin.

Positions and lengths count Unicode code points, as `length()` and `substr()` do in Postgres, not bytes or UTF-16 units. An emoji outside the Basic Multilingual Plane is one position. A JavaScript client counts it as two (`'😀'.length` is 2), so convert positions with `Array.from(text)` or a code-point iterator. The [JavaScript client](../reference/client.md) takes UTF-16 positions and converts them.

The version of a document, `crdt.ydoc_version(doc)`, is its version vector: for each entry key, the highest sequence number the document has.

## Ops

Every edit is described by an op, a `jsonb` value. Local edits return the op they made, `crdt.ydoc_ops_since` returns ops for a peer, and `crdt.ydoc_merge` and `crdt.ydoc_apply` take them:

```json
{
  "v": {"alice": 11},
  "i": [["bob", 1, ["alice", 11], null, "!"]],
  "d": [["alice", 13, 4]]
}
```

| Key | Meaning |
| --- | --- |
| `v` | The writer's version vector before the op. Local edits fill it in. The untrusted write path requires it; the trusted one ignores it. |
| `i` | Inserts, in order: `[key, seq, originLeft, originRight, text]`. The characters of `text` get the ids `[key, seq]`, `[key, seq + 1]`, and so on. An origin is an id, or `null` for the start or the end of the document. |
| `d` | Deletes: `[key, seq, length]`, the ids `[key, seq]` to `[key, seq + length - 1]`. A delete does not say who deleted. |

Ids are never reused, so applying an op twice changes nothing. An op whose origins have not arrived yet is kept until they do.

## How it behaves

**Local edits** change a document by position, under an entry key that you supply: `ydoc_insert(doc, pos, chars, replica)`, `ydoc_delete(doc, pos, len, replica)`, and `ydoc_set(doc, new_text, replica)`, which replaces the whole text with one delete and one insert (the common prefix and suffix are kept).

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

**Concurrent inserts at one place do not interleave.** When two writers type at the same position at the same time, one run of text ends up before the other, the same on every copy. Characters are never mixed:

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

**Saving a whole text from a form** uses `ydoc_set` with a base. Read `crdt.ydoc_base(doc)` in the same statement as the text, and pass it back with the new text. The new text is then diffed against the text at the base, so concurrent saves that changed different places both survive. Without a base, the diff is against the current text, and a save from a form opened before another save reverts that save, between the first and last character it changed. See [Save from a form](../guides/collaborative-text.md#save-from-a-form).

## Trusted and untrusted writers

| Path | Functions | Checks |
| --- | --- | --- |
| Local edits | `ydoc_insert`, `ydoc_delete`, `ydoc_set` | The entry key must be well formed. The caller chooses it: trusted server code. |
| Trusted merge | `ydoc_merge` | Only the shape of the op. For ops from your own servers, a sync job or a replay. |
| Untrusted apply | `ydoc_apply` | Inserts only under the writer's own replica id or its device keys; `v` must be present and consistent with the op and with the document (rules V0 to V7); quotas. For ops from clients. |

`ydoc_apply` exists because a client that may choose any origins could make two servers order the same characters differently, and then they would never converge. Its rules refuse such an op as a whole, with SQLSTATE `22023` and the rule in the message, so every server decides it the same way. An op whose `v` names characters this server has not received yet waits (`pending`) and is decided by a later write. The rules, with the argument for why they are enough, are in [`experiments/text-ref/README.md`](../../experiments/text-ref/README.md).

## Privileges and the wrapper pattern

The tables belong to the extension. At install, no role but their owner has privileges on them, and the `ydoc_` functions are not `security definer`: they run with the caller's privileges. So a call by any other role fails with `42501` until you grant the tables. Grant them to the role that owns your own `security definer` wrapper functions, which check your application's rule (may this user edit this post?) before they call `ydoc_apply` or `ydoc_set`. A view over `ydoc_value` does not work for readers, because the function reads the tables with the caller's privileges. Row-level security on the extension's tables is possible but not recommended: the policies are yours to maintain, and run for every row of every scan. See [Set up the roles and grants](../guides/collaborative-text.md#set-up-the-roles-and-grants).

## Concurrency

Every write locks the document's row in `crdt.ydoc_docs` first. Writes to one document run one at a time, each against the result of the one before, and writes to different documents do not wait for each other. A write never locks two documents, so writes cannot deadlock on them. Under `repeatable read` or `serializable`, a write that waited for the lock fails with `40001`; retry the transaction.

## Storage

A row holds a run of characters typed one after the other by one writer, up to 256 characters. Edits in the middle of a run split it, and deletes leave tombstone rows, so a document that is edited for a long time has more rows than it needs. `crdt.ydoc_compact(doc, horizon)` merges them again without changing the text or what peers receive. Run it on a schedule: see [Compact on a schedule](../guides/collaborative-text.md#compact-on-a-schedule).

In the benchmarks, a 5 kB blog post took about 24 kB across the tables, and the automerge-paper editing trace (about 260,000 edits, 104,852 characters) went from 149 to 26 bytes per character of text after one compaction. One-character edits took about 0.3 to 0.4 ms from 1 kB to 100 kB documents, and their WAL stayed under 2 kB. See [`research/benchmarks/text.md`](../../research/benchmarks/text.md) for the setup and every number.

## What it cannot do

- **Rich text, cursors, presence, undo.** The document is plain text. Formatting, selections and undo are your editor's.
- **Speak the Yjs wire format.** The ops are pg_crdt's own (see [Ops](#ops)). A client needs an implementation of the same algorithm. The [JavaScript client](../reference/client.md) has one: its engine is the reference implementation that the extension is tested against.
- **Forget deleted text.** Tombstones keep their characters, because a copy that has not seen an insert yet must receive it with its text. Compaction merges tombstone rows; it does not remove them.
- **Be indexed directly.** `ydoc_value` reads tables, so it is `STABLE`, and generated columns and expression indexes need `IMMUTABLE` functions. Keep a text column for search, refreshed on save: see [Search the posts](../guides/collaborative-text.md#search-the-posts).
- **Live in one row.** Your table holds an id. Row-level security, triggers and change feeds on your table do not see edits to the document.
- **Survive `drop extension`.** The tables belong to the extension: dropping it drops every document. See [Uninstall](../install.md#uninstall).

## The jsonb column alternative

An experiment, `yseq_` in [`experiments/text-column`](../../experiments/text-column/), keeps the same algorithm in one `jsonb` column instead of tables. It is not part of the extension and is not installed. It is smaller (about 6 kB for a 5 kB post) and lives in your row, but in the benchmarks every keystroke rewrote the whole state (18.6 kB of WAL at 5 kB, 114 kB at 100 kB), and the untrusted path was about 8 times slower. The head-to-head comparison and the reasons for choosing tables are in [`research/benchmarks/text.md`](../../research/benchmarks/text.md).

## Next

- Build it into an application: [Collaborative text for a blog post](../guides/collaborative-text.md).
- Every function, its errors and the limits: [Collaborative text functions](../reference/ydoc.md).
