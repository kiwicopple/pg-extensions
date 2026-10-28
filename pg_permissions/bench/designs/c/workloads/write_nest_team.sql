-- Admin write where Design C pays most: nest the 1,000-member team
-- md5('nest-src') (seeded by seed_sharing.sql) into a random team of the
-- nested tree. C writes 1,000 x (1 + ancestors of the target) membership rows
-- under the global advisory lock, so concurrent clients queue.
-- Rolled back so every transaction does the same work and the data doesn't change.
\set k random(1, :teams)
begin;
select permissions.grant('team', md5('team' || :k)::uuid, 'member', 'team', md5('nest-src')::uuid, 'member');
rollback;
