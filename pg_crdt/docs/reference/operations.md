# Operations

Back up the full CRDT columns and plan how devices reconnect after a restore. The visible number or text alone cannot preserve merge history.

## Backups

For a direct SQL install, include both `crdt` and your application schemas in the dump; restore into an empty database. For `create extension` or pg_tle, make the matching extension version available on the destination before restoring.

Test restores in a separate database. Check visible values, `pn_is_valid`, `yseq_is_valid`, permissions and indexes. A backup may be older than devices' copies. Recover their state before writing again; restarting totals or reusing character ids can lose changes.

## Troubleshooting

| Symptom | Check or action |
| --- | --- |
| Counter stops increasing after a device reset | Recover that device's stored totals, or use a new key. Lower totals look like old updates and are ignored. |
| Two devices lose counts or text | Check for shared writer keys. Each independent copy needs its own key. Preserve unsent text before recovery. |
| A form undoes another edit | Send the original base with the edited text. Reload text and base together after each save. |
| A text write succeeds but an edit is missing | Earlier edits may be missing. Send those dependencies and sync again. |
| Error `42501` | Check the authenticated identity, row permission and entry ownership. |
| Error `22023` or `54000` | Check the input format or quota. Keep unsent text; repeated retries will not repair it. |
| Error `40001` | Retry the whole transaction on one connection. Reuse the same recorded updates. |
| Small text uses lots of disk | History remains after deletion; each edit rewrites it. See [storage](storage.md#text). |
| Text positions are wrong | Use UTF8 and convert JavaScript offsets to Unicode code points. |

The [errors reference](errors.md) gives function-specific conditions.

## Uninstall

Back up first. Dropping the extension or schema with `cascade` can delete dependent columns and their data.

1. Preserve the full CRDT columns as ordinary `jsonb` if their history is needed. Optionally save their readable number or text too.
2. Remove dependent defaults, generated expressions, indexes, constraints and application functions.
3. For an extension install, run `drop extension pg_crdt` **without** `cascade`. Inspect any remaining dependency that blocks it.
4. A direct SQL install has no extension entry. Only after preserving data and removing application dependencies, remove its objects with `drop schema crdt cascade`.

This SQL is a fragment for a table with `body`, stored generated `body_text`, and `likes` columns. Adapt it to your schema after checking dependencies:

```sql
alter table posts alter column body_text drop expression;
alter table posts alter column body drop default;
alter table posts alter column likes drop default;
-- Remove other dependencies on crdt before converting.
alter table posts alter column body type jsonb;
alter table posts alter column likes type jsonb;
drop extension pg_crdt;
```
