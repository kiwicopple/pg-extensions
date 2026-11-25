-- Run as the table owner with pg_crdt installed. Input here is trusted.

create table like_deltas (
  id bigint generated always as identity primary key,
  post_id bigint not null,
  delta crdt.pn not null
);
create index on like_deltas (post_id);

insert into like_deltas (post_id, delta)
values (1, '{"t": "pn", "v": 1, "p": {"bob": 2}, "n": {}}');

insert into like_deltas (post_id, delta)
values (1, crdt.pn_increment(null, 'alice'));

select crdt.pn_value(crdt.pn_merge_agg(delta)) as likes
from like_deltas
where post_id = 1;
-- 3

create table like_snapshots (
  post_id bigint primary key,
  state crdt.pn not null
);

-- Combine old deltas with the snapshot atomically. New inserts remain
-- for a later pass. Reads must merge the snapshot and remaining deltas.
with folded as (
  delete from like_deltas
  where post_id = 1
  returning delta
)
insert into like_snapshots (post_id, state)
select 1, crdt.pn_merge_agg(delta)
from folded
having count(*) > 0
on conflict (post_id) do update
set state = crdt.pn_merge(like_snapshots.state, excluded.state);

select crdt.pn_value(
  crdt.pn_merge(
    (select state from like_snapshots where post_id = 1),
    (
      select crdt.pn_merge_agg(delta)
      from like_deltas
      where post_id = 1
    )
  )
);
-- 3
