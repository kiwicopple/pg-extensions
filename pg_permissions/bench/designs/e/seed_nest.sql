-- Benchmark fixture for nest_check (design E, Cedar): nest Team::"nest-src"
-- (1,000 members, seeded by seed_sharing.sql) in team :teams for good, by
-- putting it again with that team as its parent. Loaded after
-- write_nest_team, which rolls back the same write.

\set ON_ERROR_STOP 1

select permissions.cedar_put_entities(entities => jsonb_build_array(jsonb_build_object(
    'uid', jsonb_build_object('type', 'Team', 'id', md5('nest-src')::uuid),
    'parents', jsonb_build_array(jsonb_build_object('type', 'Team', 'id', md5('team' || :teams)::uuid)))));

-- The check nest_check measures must be true, or it would time a fast "no".
select (:teams::bigint * 9973 + 7919) % :docs + 1 as nest_doc \gset
select permissions.cedar_is_authorized(principal => format('user::"%s"', md5('nest-user' || 1)::uuid), action => 'Action::"read"',
                                       resource => format('Document::"%s"', md5('doc' || :nest_doc)::uuid)) ->> 'decision' = 'allow' as nest_ok \gset
\if :nest_ok
\else
do $$ begin raise exception 'nest_check fixture: the check is false for nest-user 1'; end $$;
\endif
