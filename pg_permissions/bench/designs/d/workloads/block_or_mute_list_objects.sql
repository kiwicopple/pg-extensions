-- Not monotone: ListObjects on `can_view_unmuted: viewer but not (blocked or
-- muted)` (seed_blocklist.sql), a union under the subtract.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select count(*) from permissions.fga_list_object_ids_current('document', 'can_view_unmuted');
commit;
