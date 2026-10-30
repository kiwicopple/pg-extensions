-- Conditions: first page through the policies after seed_conditions.sql (the
-- FGA policy on `cviewer`, org roles through seed_rbac.sql's RBAC policy).
-- The conditioned twin of parents_select_page.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select id, title from public.documents order by id limit 50;
commit;
