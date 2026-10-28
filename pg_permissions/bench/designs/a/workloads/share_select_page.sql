-- PROVISIONAL (sharing): first page through the two-branch RLS policy (org roles or shares).
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select id, title from public.documents order by id limit 50;
commit;
