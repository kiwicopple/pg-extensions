-- Count every document the user can see through RLS (worst case: touches every visible row).
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select count(*) from public.documents;
commit;
