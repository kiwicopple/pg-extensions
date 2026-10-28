-- Read side of nesting: one check for a user who reaches a document only
-- through a nested team. User md5('nest-user' || i) is in team md5('nest-src'),
-- which seed_nest.sql nested in team :teams; the document is one of the
-- five shared with team :teams. can() with the row's folder, as RLS would pass
-- it: closure joins, no recursion.
\set i random(1, 1000)
\set j random(1, 5)
\set d (:teams * 9973 + :j * 7919) % :docs + 1
\set f (:d % :orgs) + :orgs * ((:d / :orgs) % 10)
begin;
select set_config('permissions.subject_id', md5('nest-user' || :i)::uuid::text, true);
set local role authenticated;
select permissions.can('select', 'document', md5('doc' || :d)::uuid::text,
                       jsonb_build_object('folder', md5('folder' || :f)::uuid::text));
commit;
