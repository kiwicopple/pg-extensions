-- Not monotone: ListObjects on `can_edit: editor and viewer`
-- (seed_blocklist.sql), an intersection.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select count(*) from permissions.fga_list_object_ids_current('document', 'can_edit');
commit;
