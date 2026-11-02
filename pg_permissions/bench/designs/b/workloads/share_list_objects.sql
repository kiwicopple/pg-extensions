-- Sharing: every document the user can view through direct grants and nested teams.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select cardinality(permissions.ids('select', 'document'));
commit;
