# Sync counts from another device

Send each device's running total, not the amount added since its last request. Merge that state inside the database update so concurrent writes cannot replace each other.

Run this example as the table owner in a fresh test database with the extension installed. It creates its own table and simulates a trusted device. For browser input, use the [client update wrapper](security.md) instead of exposing `pn_merge` directly.

```sql
create table sync_counts (
  id bigint primary key,
  value crdt.pn not null default crdt.pn_empty()
);
insert into sync_counts (id) values (1);

update sync_counts
set value = crdt.pn_merge(
  value, '{"t":"pn","v":1,"p":{"alice:phone":5},"n":{}}'
)
where id = 1;

-- The phone adds two more. It sends 7, not 2.
update sync_counts
set value = crdt.pn_merge(
  value, '{"t":"pn","v":1,"p":{"alice:phone":7},"n":{}}'
)
where id = 1;

-- Retrying the same state does not add another 7.
update sync_counts
set value = crdt.pn_merge(
  value, '{"t":"pn","v":1,"p":{"alice:phone":7},"n":{}}'
)
where id = 1;
select crdt.pn_value(value) from sync_counts where id = 1;
-- 7
```

A delta can contain only the entries the device changed, but each entry is still a running total. Different independent devices need different keys. If a device loses its state, it must recover its totals or start under a new key; starting from zero under the old key silently suppresses counts.

## Next

[Identify writers and devices](replicas-and-identity.md), then [accept client updates](security.md) with ownership checks. For transaction retries and upserts, see [Update safely](safe-updates.md).
