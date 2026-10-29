-- Sharing: every document the user can view through direct grants and nested
-- teams (ListObjects for the current subject, as the RLS policy calls it).
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select count(*) from permissions.fga_list_object_ids_current('document', 'viewer');
commit;
