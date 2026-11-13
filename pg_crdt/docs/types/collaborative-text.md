# How text merges

`crdt.yseq` stores a plain-text document and the metadata needed to combine independent edits. Every character has an id: its writer's entry key and a sequence number. Inserts record the ids of the neighbouring characters at the time of the edit. Those origins and ids determine a consistent order using the YjsMod rule.

Two writers inserting at the same position produce ordered runs of text rather than interleaved characters. Deletes name character ids, so deleting a character twice has the same result as deleting it once. Deletion metadata remains because later edits can refer to those characters.

A version vector records the highest integrated sequence number for each entry key. Operations arriving before their dependencies wait until those dependencies arrive. The same operations can be delivered more than once without duplicating text.

## Choose a shape

The active extension supports only the column type. Table-backed documents are [separate research](../../research/scope.md), kept out of the extension to keep its scope simple. Use an ordinary `text` column when you do not need independent edits to merge.

## The column type: `yseq_`

Use `yseq_new()` as the column default so each document has its own id. Edit the column in one `update` statement. Functions return a new state; your statement stores it. Read the visible text with `yseq_value`.

## Limits of the column

Every edit rewrites the entire state. Retained deletion metadata grows with edit history, and merge/apply/sync scan the document. Large documents and frequent edits can produce substantial WAL, TOAST churn and network traffic. See [Text-column limits and performance](../text/limits.md) for all known constraints, measurements and mitigation limits.

## What it cannot do

The extension does not provide rich text, cursor sharing, presence, undo, a Yjs-compatible wire format or a packaged column client. It does not garbage-collect deleted character metadata. A merge resolves ordering, not the human intent behind overlapping replacements.

## Ops

An operation, or op, is a JSON description of an edit. It contains the inserted text, the characters to delete, and the version the writer started from.

For an edit, use `yseq_diff(old, new)`. Fetch edits another copy needs with `yseq_ops_since`, and apply client operations with `yseq_apply`. An op looks like this:

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


## Trusted and untrusted writers

Server code chooses entry keys for local edits. `yseq_merge` combines states from trusted peers. A client sends operations to an authorized wrapper using `yseq_apply`, which checks ownership, causal rules and quotas. Do not grant clients direct updates to the state column.

The validation rules are documented in the [reference experiment](../../experiments/text-ref/README.md). The [SQL reference](../reference/yseq.md) describes each function and error.

## Next

Try [your first shared document](../get-started/text.md) or [save changes from a form](../text/forms.md).

## Earlier storage research

The table-backed sections and detailed benchmark tables from the former explanation are preserved in [the research snapshot](../../research/ydoc/docs/types/collaborative-text.md). For current column decisions, use [Text-column limits and performance](../text/limits.md).

<span id="how-text-merges"></span>

<span id="benchmarks-of-yseq_"></span>

<span id="the-table-backed-documents-ydoc_"></span>

<span id="the-document"></span>

<span id="privileges-and-the-wrapper-pattern"></span>

<span id="concurrency"></span>

<span id="storage"></span>

<span id="benchmarks-of-ydoc_"></span>
