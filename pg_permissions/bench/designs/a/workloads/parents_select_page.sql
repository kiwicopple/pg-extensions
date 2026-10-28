-- PROVISIONAL (parents): first page through the single-branch policy from
-- seed_parents.sql (org roles arrive through parent tuples). Needs that seed.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select id, title from public.documents order by id limit 50;
commit;
