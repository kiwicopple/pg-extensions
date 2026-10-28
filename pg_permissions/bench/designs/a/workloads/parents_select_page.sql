-- Parents: first page through the parent-aware policy from seed_parents.sql
-- (org roles and folder viewers arrive through the folder chain; no
-- hand-written org_id branch). Needs that seed.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select id, title from public.documents order by id limit 50;
commit;
