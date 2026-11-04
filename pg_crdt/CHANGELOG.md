# Changelog

## Extension 0.0.1

The first release adds the **PN-Counter** in the schema `crdt`: a counter that goes up and down, which several writers can change independently and merge later. It is SQL and PL/pgSQL only, needs no superuser, and works with any Postgres 16, 17 or 18 client, driver or API layer.

- **Type.** The domain `crdt.pn` over `jsonb`, with a versioned envelope `{t, v, p, n}`. See [PN-Counter](docs/types/pn-counter.md).
- **Functions.** `pn_empty`, `pn_increment`, `pn_decrement`, `pn_value`, `pn_merge`, the aggregate `pn_merge_agg`, and `pn_is_valid`. `pn_value` is `IMMUTABLE`, so it works in generated columns and expression indexes. See [PN-Counter functions](docs/reference/pn.md).
- **Untrusted writers.** `pn_apply_delta(state, delta, replica)` applies a delta from a writer you do not trust. It rejects entries that belong to another replica and malformed deltas, and treats stale entries as no-ops, so retries succeed. See [Accept writes from untrusted clients](docs/guides/security.md).
- **Identity.** `current_replica_id()` is the default identity: a JWT claim from `request.jwt.claims` (`sub`, or the claim named by `crdt.replica_id_claim`), else the setting `crdt.replica_id`. Nothing assumes a platform or UUID ids. A replica id is any non-empty text without `:`, and a key may carry a device suffix (`alice:phone`). See [Replicas and identity](docs/guides/replicas-and-identity.md).
- **Install.** One SQL file, as a plain script, through pg_tle or with the control file. The install refuses a `crdt` schema that another role controls. See [Install](docs/install.md).
- **Tests.** The specification in `test/spec/` covers the merge laws, convergence under shuffled, duplicated and stale delivery, concurrency, the install paths and the write path for untrusted writers, on Postgres 16, 17 and 18. See the [test suite](test/README.md).

Known limits: one type so far, the state grows with the number of replicas, no compaction for delta tables, and no upgrade path yet. See [Limits](docs/reference/limits.md).

Dropping the extension, or the schema of a direct install, with `cascade` drops every column of type `crdt.pn`, with its data. See [Install](docs/install.md#uninstall).
