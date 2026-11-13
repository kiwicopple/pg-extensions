# Troubleshooting

Start with the symptom below. For exact SQLSTATE codes and function-specific conditions, use [Errors](../reference/errors.md).

## My counter stopped increasing after a reinstall

The device may have restarted its totals from zero under an old entry key. Merge keeps the larger total, so the new count has no effect until it exceeds the old total. Read the device's entries from the server and continue from them, or use a fresh device id. See [Recover a lost state](../guides/replicas-and-identity.md#a-replica-that-lost-its-state).

## A form overwrote another person's edit

Pass the state the form originally loaded as `base` to `yseq_set`. Saving without it compares against the current text and can replace another editor's changes. Read text and base together, and refresh both after each save. See [Save changes from a form](../text/forms.md).

## Text disappeared after two clients synced

Check whether both clients used the same entry key. A text column skips character ids already present without detecting different content under those ids. Give each independent editor its own key. Keep the user's unsent text before reloading; do not blindly resubmit edits whose ids collide.

## An edit is missing but the write succeeded

Operations can wait for dependencies the server has not received. Send the missing earlier operations, then sync again. The column API returns a new state, not a separate acceptance status. Check quotas before sending a large backlog; see [Text function limits](../reference/yseq.md#limits).

## The server rejected an update

For `42501`, check the authenticated identity, entry ownership and wrapper permissions. For `22023`, inspect the operation format, version and causal rules. For `54000`, check device and pending-operation quotas. Preserve the user's text and reload a valid state before generating replacement edits. Repeatedly retrying malformed input does not repair it.

## A transaction failed with `40001`

Under REPEATABLE READ or SERIALIZABLE, concurrent writes can require a retry of the entire transaction. Merging the same state or applying the same operation again is safe. Repeating a local increment or insert after an uncertain commit can create an extra change; retries must preserve the original state or operation. See [Update safely](../guides/safe-updates.md#isolation-levels-and-retries).

## A small document uses a lot of disk or WAL

Visible text is only part of the state. Deleted character metadata remains, and every edit rewrites the full value. Vacuum can reclaim dead row versions but cannot remove live CRDT history. Compression, batching and autovacuum tuning have limits. See [Text-column limits and performance](../text/limits.md).

## Search results do not match the document

A stored generated column based on `yseq_value` updates with the row. Check that queries use that column and the same text-search configuration as its index. A manually maintained text copy can become stale. See [Search documents](../text/search.md).

## I get `permission denied for table ydoc_docs`

You are using an earlier table-backed build or its client. The active extension has no `ydoc_` tables or API. Do not grant broader permissions as a workaround. See the [scope decision and archive](../../research/scope.md).

## Text sync fails on encoding or positions

Use a UTF8 database. Positions are Unicode code points; convert JavaScript UTF-16 offsets and do not split surrogate pairs. Reject U+0000 and lone surrogates before sending text. See [Connect a live editor](../text/live-editor.md).
