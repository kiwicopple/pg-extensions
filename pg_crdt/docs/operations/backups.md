# Back up and restore

Counters and text documents live in your application tables. Back up the full `crdt.pn` and `crdt.yseq` columns to preserve their merge history. Saving only `pn_value` or `yseq_value` keeps the visible value but loses the information needed to merge offline changes.

## Installation method matters

With `create extension`, `pg_dump` records a command to recreate the extension. Make the matching extension files available on the restore server, or register that version with pg_tle, before restoring.

With a direct SQL install, the functions, domains and aggregates are ordinary schema objects. Include `crdt` and your application schemas in the dump, and restore into an empty database. A dump of only an application schema may omit the types and functions its columns require.

The current extension owns no document tables. Earlier development builds with `ydoc_` had different backup requirements; use the [archived guide](../../research/ydoc/docs/install.md#backups) for those databases.

## After restoring

Check visible values and full-state validity with `pn_value`, `pn_is_valid`, `yseq_value` and `yseq_is_valid`. Verify table privileges, wrapper functions and indexes too. Test restore procedures in a separate database before relying on them.

A restored backup may be older than copies on devices. Keep replica identities and pending updates consistent: starting a writer from zero under an old key can lose counter changes, and reusing text character ids with different content can lose text. Plan how clients resync before allowing writes. See [Troubleshooting](troubleshooting.md).
