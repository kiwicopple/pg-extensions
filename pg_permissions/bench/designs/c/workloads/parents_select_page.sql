-- Parents, single branch: first page through the policy from
-- seed_parent_docs.sql (one engine call returns every visible document id:
-- org roles and folder viewers through the document's parent link, plus
-- shares). Needs that seed.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select id, title from public.documents order by id limit 50;
commit;
