# Try a counter

Create a visitor counter, add counts from two devices, then retry an update. Run these SQL blocks in order in a test database with [pg_crdt installed](../install.md), as the table owner.

## Create and update a counter

`crdt.pn` is a counter that can go up or down. PN means positive-negative. It stores each writer's additions and subtractions; `pn_value` returns the total.

```sql
create table pages (
  id bigint primary key,
  visits crdt.pn not null default crdt.pn_empty()
);
insert into pages (id) values (1);

update pages
set visits = crdt.pn_increment(visits, 'front-desk', amount => 3)
where id = 1;

select crdt.pn_value(visits) from pages where id = 1;
-- 3
```

`front-desk` names the writer. Use `pn_decrement` to subtract instead. Keep changes inside the `update` statement so simultaneous writes use the latest stored value.

## Add an offline device's count

A phone counted 2 more visitors. Its update contains its **running total**, in this JSON format:

```json
{"t": "pn", "v": 1, "p": {"phone": 2}, "n": {}}
```

`t` and `v` identify the type and format. `p` holds additions by writer; `n` holds subtractions. The maps can contain just the writers that changed.

Merge the phone's update into the stored counter:

```sql
update pages
set visits = crdt.pn_merge(
  visits,
  '{"t":"pn","v":1,"p":{"phone":2},"n":{}}'
)
where id = 1;

select crdt.pn_value(visits) from pages where id = 1;
-- 5
```

Run that block again. The result is still **5**: merge keeps the largest recorded total for each writer. If the phone counts one more visitor, it sends `3`, not `1`.

## Remember these rules

- Give each independent device its own stable name. If two offline devices use the same name, their counts can be lost.
- If a device loses its saved totals, recover them from the server or start with a new device name. Restarting at zero under the old name loses counts.
- Merging the same recorded update again is safe. Calling `pn_increment` again creates another increment.
- This example trusts the phone's data. For input from a browser or phone you do not control, use `pn_apply_delta` through an [authorized app endpoint](../guides/app.md).

A counter cannot enforce a shared minimum or maximum while devices are offline. Its stored data also grows with the number of writers. See [counter functions](../reference/pn.md) when you need the details.

Next: [try shared text](text.md).
