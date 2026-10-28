-- Admin write: nest the 1,000-member team md5('nest-src') (seeded by
-- seed_sharing.sql) into a random team of the nested tree. Same shape as
-- Design C's write_nest_team. A writes one tuple; the cost moves to reads (the
-- walk).
-- Rolled back so every transaction does the same work and the data doesn't
-- change.
\set k random(1, :teams)
begin;
select permissions.grant('team', md5('team' || :k)::uuid::text, 'member', 'team', md5('nest-src')::uuid::text, 'member');
rollback;
