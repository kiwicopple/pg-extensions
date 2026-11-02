-- Admin write: a new user with a role in a random org (put one entity with
-- the role as its parent). Rolled back so the data doesn't change.
\set n random(1, 1000000000)
\set o random(0, :orgs - 1)
begin;
select permissions.cedar_put_entities(entities => jsonb_build_array(jsonb_build_object(
    'uid', jsonb_build_object('type', 'user', 'id', md5('new-user' || :n)::uuid),
    'parents', jsonb_build_array(jsonb_build_object('type', 'Role', 'id', md5('org' || :o)::uuid || '/viewer')))));
rollback;
