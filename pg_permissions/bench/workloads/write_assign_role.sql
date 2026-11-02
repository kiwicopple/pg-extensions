-- Admin write: assign a role to a new user in a random org.
-- Rolled back so the data doesn't change: committed grants would differ per
-- engine (more tps, more rows) and leak into later phases and checksums.
\set n random(1, 1000000000)
\set o random(0, :orgs - 1)
begin;
select permissions.assign_role(md5('new-user' || :n)::uuid::text, 'viewer', md5('org' || :o)::uuid::text);
rollback;
