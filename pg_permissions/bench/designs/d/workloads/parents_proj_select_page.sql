-- Parents, two-arm projection: first page through the policies from
-- seed_parents.sql (FGA: shares by id and folder viewers projected onto
-- folder_id; org roles through seed_rbac.sql's RBAC policy). Needs that seed.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select id, title from public.documents order by id limit 50;
commit;
