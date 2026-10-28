-- Parents, single branch: count every document visible through the policy from
-- seed_parent_docs.sql (worst case: touches every visible row). Needs that seed.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select count(*) from public.documents;
commit;
