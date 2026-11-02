-- Parents, single branch: first page through the policies from
-- seed_parent_docs.sql (one Cedar call returns every document visible through
-- a share or the document's parent folder; org roles through seed_rbac.sql's
-- org policy). Needs that seed.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select id, title from public.documents order by id limit 50;
commit;
