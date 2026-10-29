-- Admin write: nest the 1,000-member team md5('nest-src') (seeded by
-- seed_sharing.sql) into a random team of the nested tree, as one tuple
-- `team:<k>#member@team:<nest-src>#member`. Same shape as the other designs'
-- write_nest_team. D writes one tuple; the cost moves to reads (the walk).
-- Rolled back so every transaction does the same work and the data doesn't
-- change.
\set k random(1, :teams)
begin;
select permissions.fga_write_tuple('team:' || md5('nest-src')::uuid || '#member', 'member', 'team:' || md5('team' || :k)::uuid);
rollback;
