-- Not monotone: ListObjects on `can_view: viewer but not blocked`
-- (seed_blocklist.sql), the set-based difference. Each user is blocked on one
-- document they see. Was the side script designs/d/but_not_list_objects.sql.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select count(*) from permissions.fga_list_object_ids_current('document', 'can_view');
commit;
