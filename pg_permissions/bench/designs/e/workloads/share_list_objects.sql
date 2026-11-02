-- Sharing: every document the user can read through direct grants and nested
-- teams (the list for the current subject, as the RLS policy calls it).
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select count(*) from permissions.cedar_list_resources_current('Action::"read"', 'Document');
commit;
