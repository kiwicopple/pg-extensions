-- Admin write: nest the 1,000-member team md5('nest-src') (seeded by
-- seed_sharing.sql) into a random team of the nested tree. Same shape as
-- Design C's write_nest_team. B writes 1,001 x (1 + ancestors of the target)
-- closure rows under its global advisory lock, so concurrent clients queue.
-- Rolled back so every transaction does the same work and the data doesn't
-- change.
\set k random(1, :teams)
begin;
select permissions.add_parent('team', md5('nest-src')::uuid::text, 'team', md5('team' || :k)::uuid::text);
rollback;
