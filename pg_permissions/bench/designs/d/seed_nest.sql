-- Benchmark fixture for nest_check (Design D): nest the 1,000-member team
-- md5('nest-src') (seeded by seed_sharing.sql) into team :teams for good,
-- `team:<teams>#member@team:<nest-src>#member`. That is the deepest team of
-- every shape (a leaf of the default tree, the bottom of a chain in the deep
-- shape), so the nested users inherit the longest chain. Loaded after
-- write_nest_team, which rolls back the same write.

\set ON_ERROR_STOP 1

select permissions.fga_write_tuple('team:' || md5('nest-src')::uuid || '#member', 'member',
                                   'team:' || md5('team' || :teams)::uuid);

-- The check nest_check measures must be true, or it would time a fast "no".
select (:teams::bigint * 9973 + 7919) % :docs + 1 as nest_doc \gset
select permissions.fga_check('user:' || md5('nest-user' || 1)::uuid, 'viewer',
                             'document:' || md5('doc' || :nest_doc)::uuid) as nest_ok \gset
\if :nest_ok
\else
do $$ begin raise exception 'nest_check fixture: the check is false for nest-user 1'; end $$;
\endif
