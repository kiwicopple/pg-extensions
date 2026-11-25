# Identity settings

Always qualify extension objects with `crdt.`. Names starting with `_` are internal. The extension functions return values; table permissions decide who can store them. None runs as `security definer`.

## Replica ids and entry keys

A **replica id** identifies an owner. An **entry key** identifies a writer, optionally a device belonging to that owner.

| Term | Rule | Example |
| --- | --- | --- |
| Replica id | Non-empty text without `:` | `alice` |
| Entry key | Replica id, optionally followed by `:` and a non-empty suffix | `alice:phone` |
| Owner | The part before the first `:` | `alice` |

A suffix may contain more colons. Text keys are limited to 256 bytes. Give each independent writer a unique, stable key. One shared key is safe only when updates are serialized against the current database row, rather than made in independent copies.

If a counter device loses its totals, recover its entries from the server or use a new key. Starting at zero under its old key loses counts. Reusing text character ids can lose edits too.

## The caller's identity

### `current_replica_id`

```text
crdt.current_replica_id() returns text
```

Returns the first available identity below, or null:

1. The claim in `request.jwt.claims` named by `crdt.replica_id_claim` (default `sub`).
2. The `crdt.replica_id` setting.

Empty or missing claims/settings fall through. Valid JSON that is not an object has no claim. Numeric claims become text; object or array claims become JSON text and are unsuitable as ids.

`STABLE`, not marked `PARALLEL SAFE`; `search_path` is pinned to `pg_catalog, pg_temp`. Public execution is allowed. Invalid JSON in `request.jwt.claims` raises `22P02`.

```sql
begin;
set local crdt.replica_id = 'alice';
select crdt.current_replica_id();
-- alice
commit;
```

This is the default owner for `pn_apply_delta` and `yseq_apply`. Their `replica` argument can instead be supplied explicitly.

### Settings

| Setting | Purpose |
| --- | --- |
| `request.jwt.claims` | Claims from a token verified by your API layer. |
| `crdt.replica_id_claim` | Claim name to read, default `sub`. |
| `crdt.replica_id` | Identity supplied by your server for this transaction. |

Use `set local`, or `set_config(name, value, true)` for parameters. Any SQL user can change these settings. Trust them only when your server controls the SQL; for direct database users, pass `session_user::text` and check row access using that same identity. Inside a `security definer` wrapper, `current_user` is the function owner, not the caller.

See [application examples](application.md) for wrappers and grants.

## Privileges

Installation grants `usage` on `crdt` and function execution to `public`. This grants no access to your tables. The [schema guard](installation.md#the-schema-guard) rejects unsafe schema ownership or creation privileges.

## State format and versions

Both column types store JSON with `t` for type and `v` for format version. The accepted format is `v = 1`; invalid outer structures fail with `23514`. See [counter state](pn.md#state-and-merge) and [text state](yseq.md#the-domain).

The extension version, currently `0.0.1`, is separate from the format version. There is no in-place upgrade or automatic state migration.
