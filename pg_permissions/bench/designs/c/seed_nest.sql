-- Benchmark fixture for nest_check: nest the 1,000-member team md5('nest-src')
-- (seeded by seed_sharing.sql) into team :teams for good. That is the
-- deepest team of every shape (a leaf of the default tree, the bottom of a
-- chain in the deep shape), so the nested users inherit the longest chain.
-- Loaded after write_nest_team, which rolls back the same kind of write.

\set ON_ERROR_STOP 1

select permissions.grant('team', md5('team' || :teams)::uuid, 'member', 'team', md5('nest-src')::uuid, 'member');

-- The check nest_check measures must be true, or it would time a fast "no".
select (:teams::bigint * 9973 + 7919) % :docs + 1 as nest_doc \gset
select :nest_doc % :orgs + :orgs * ((:nest_doc / :orgs) % 10) as nest_folder \gset
select set_config('permissions.subject_id', md5('nest-user' || 1)::uuid::text, false) as nest_subject \gset
select permissions.can('document', md5('doc' || :nest_doc)::uuid, 'documents.read') as nest_ok \gset
\if :nest_ok
\else
do $$ begin raise exception 'nest_check fixture: the check is false for nest-user 1'; end $$;
\endif
