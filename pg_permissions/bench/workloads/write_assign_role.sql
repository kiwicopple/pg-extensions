-- Admin write: assign a role to a new user in a random org.
\set n random(1, 1000000000)
\set o random(0, :orgs - 1)
select permissions.assign_role(md5('new-user' || :n)::uuid::text, 'viewer', md5('org' || :o)::uuid::text);
