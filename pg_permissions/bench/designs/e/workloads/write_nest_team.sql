-- Admin write: nest the 1,000-member Team::"nest-src" (seeded by
-- seed_sharing.sql) in a random team, by putting it again with that team as
-- its parent: a re-parent of one entity. Same shape as the other designs'
-- write_nest_team. Rolled back so every transaction does the same work.
\set k random(1, :teams)
begin;
select permissions.cedar_put_entities(entities => jsonb_build_array(jsonb_build_object(
    'uid', jsonb_build_object('type', 'Team', 'id', md5('nest-src')::uuid),
    'parents', jsonb_build_array(jsonb_build_object('type', 'Team', 'id', md5('team' || :k)::uuid)))));
rollback;
