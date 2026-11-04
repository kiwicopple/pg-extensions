# Shared

What every type in `pg_crdt` has in common: the schema and naming, replica ids, the function that finds the caller's identity, and the state envelope with its versioning. Functions of the PN-Counter are in [PN-Counter functions](pn.md), those of collaborative text in [Collaborative text functions](ydoc.md).

## Schema and naming

- Everything is in the schema `crdt`. Call functions with the schema (`crdt.pn_merge(...)`), and do not add `crdt` to `search_path`.
- Each type has a name prefix: `pn_` for the PN-Counter, `ydoc_` for collaborative text. The prefix names the algorithm, not the family, because a later set or register type has a different merge. The same verbs apply where they fit: `<prefix>_empty`, `<prefix>_value`, `<prefix>_merge`, `<prefix>_merge_agg`, plus the verbs of the type, such as `pn_increment` or `ydoc_insert`. A text document is not a value, so `ydoc_` has `ydoc_create` instead of `_empty`, and no aggregate.
- Names that start with `_` are internal (`_ydoc_*`). Do not call them.
- There is no generic `crdt.merge(a, b)`. Each type has its own merge, so a wrong type is a function-resolution error, not a run-time one, and no call pays for a dispatch.
- Pure functions are `IMMUTABLE PARALLEL SAFE`. A function that decides on the caller's identity pins `search_path` to `pg_catalog, pg_temp`, and so does every `ydoc_` function written in PL/pgSQL. Where a function differs, its entry says so.
- None of the functions is `security definer`.

### Privileges

At install, every privilege on the functions, tables and sequences in `crdt` is revoked from every role but the owner. Then `EXECUTE` is granted to `public` for the whole API (and for the `_ydoc_` internals, which the `ydoc_` functions call with the caller's privileges), and `USAGE` on the schema is granted to `public`. The PN-Counter functions are pure or read only the caller's own settings, so none needs privileges of its own. Decide who may write which rows with your own privileges, row-level security, or [wrapper functions](../guides/security.md).

The collaborative text tables (`crdt.ydoc_*`) and their sequences keep no grants. The `ydoc_` functions read and write them with the caller's privileges, so you grant them to the role that owns your wrapper functions. See [Collaborative text functions](ydoc.md#tables).

The install refuses an existing `crdt` schema that belongs to another non-superuser role, or on which another role has `CREATE`. See [Install](../install.md#the-schema-guard).

## Replica ids and entry keys

| Term | Rule | Pattern |
| --- | --- | --- |
| Replica id | Non-empty text without `:`. | `^[^:]+$` |
| Entry key | A replica id, or `<replica id>:<device>` with a non-empty device suffix, which may contain more `:`. | `^[^:]+(:.+)?$` |
| Owner of a key | The part before the first `:`. | `split_part(key, ':', 1)` |

`pn_increment` and `pn_decrement` check the key they are given. `pn_merge` does not: it must accept whatever other replicas send. `pn_apply_delta` checks the replica id it is given and every key in the delta. The [guide](../guides/replicas-and-identity.md) explains how to choose ids.

## The caller's identity

### `current_replica_id`

```text
crdt.current_replica_id() returns text
```

The default identity of a writer, used as the default of the `replica` argument of [`pn_apply_delta`](pn.md#pn_apply_delta). Nothing in it is specific to one platform. It returns the first of these that is set, and null if none is. This is the same order that `pg_permissions` uses for its subject (JWT `sub`, then a setting):

1. The claim of the JSON object in the setting `request.jwt.claims`. The claim is named by the setting `crdt.replica_id_claim`, and is `sub` when that is not set. A numeric claim is returned as text.
2. The setting `crdt.replica_id`.

**Returns** `text`, or null. **Labels:** `STABLE`, `search_path` pinned to `pg_catalog, pg_temp`. It is not marked `PARALLEL SAFE`.

**Behavior**

- An empty setting or claim counts as not set.
- If `request.jwt.claims` is set but does not contain the claim, the function falls through to `crdt.replica_id`. If both are present, the claim wins.
- A `request.jwt.claims` that is valid JSON but not an object (a string or an array) has no claim, and falls through as well. A claim that is itself an object or an array is returned as its JSON text, which is not a useful replica id.
- The function reads settings with `current_setting(..., true)`, so an unset setting is not an error.

**Privileges.** `EXECUTE` is granted to `public`.

**Errors.** `22P02` (`invalid_text_representation`) when `request.jwt.claims` is set to text that is not valid JSON.

**Example**

```sql
begin;
set local request.jwt.claims = '{"sub": "u-7"}';
select crdt.current_replica_id();
-- u-7
set local crdt.replica_id = 'user-1842';
select crdt.current_replica_id();
-- u-7
commit;
```

The claim wins over `crdt.replica_id`. Without the claim, `user-1842` is returned.

### Settings

| Setting | Set by | Meaning | Default |
| --- | --- | --- | --- |
| `request.jwt.claims` | An API layer that follows the PostgREST convention, for each request | A JSON object with the claims of the verified token | Not set |
| `crdt.replica_id_claim` | You, per database, role or transaction | The name of the claim to read from `request.jwt.claims` | `sub` |
| `crdt.replica_id` | An app server, per transaction | The replica id of the writer | Not set |

Set a setting for one transaction with `set local name = 'value'`, or with `select set_config('name', 'value', true)` when the value is a parameter. Set `crdt.replica_id_claim` for a database with `alter database app set crdt.replica_id_claim = 'email'`.

**Trust.** Any role can `set` a custom setting. The default identity is therefore as strong as whoever can set `request.jwt.claims` and `crdt.replica_id`. Use it only for writers that cannot run their own SQL, and pass `session_user` for those that can. See [Trust model](../guides/replicas-and-identity.md#trust-model).

## The state envelope

Every type that is a value stores its state as `jsonb` with a versioned envelope, inside a domain named after the type (collaborative text is stored in tables instead):

| Key | Meaning |
| --- | --- |
| `t` | The type: `"pn"` for the PN-Counter. Every function checks it. |
| `v` | The format version of that type's state. `1` for `pn`. |
| Other keys | Defined by the type. For `pn`: `p` and `n`. |

The envelope is closed: a state has exactly the keys of its type. For the PN-Counter, the domain `crdt.pn` rejects anything else with SQLSTATE `23514`. See [PN-Counter](../types/pn-counter.md#the-crdtpn-domain).

### Versioning

There are two version numbers, and they are independent:

- **The extension version**, `0.0.1`, in the file name and the control file.
- **The format version `v`** in each state. The domain accepts only `v = 1`. A state with another `v` is rejected.

0.0.1 has no upgrade path: no `--` upgrade scripts, and no migration of old states. The design is that merge will upgrade a state with an older `v`, and that the upgrade must commute with merge. That is not built. Until a type has a second format version, `v` is only a guard. A direct install (psql) has no extension object and cannot be upgraded in place. See [Install](../install.md).
