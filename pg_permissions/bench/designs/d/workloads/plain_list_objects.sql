-- Conditions, twin without: every document the user can view through
-- `viewer` (shares, nested teams, parent folders), on the data of the
-- conditions phase. The unconditioned twin of cond_list_objects.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select count(*) from permissions.fga_list_object_ids_current('document', 'viewer');
commit;
