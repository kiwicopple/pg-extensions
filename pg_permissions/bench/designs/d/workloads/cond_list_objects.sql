-- Conditions: every document the user can view through `cviewer`, the
-- conditioned copy of `viewer` (seed_conditions.sql: a condition on every
-- team membership and team grant). Same ids as plain_list_objects.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select count(*) from permissions.fga_list_object_ids_current('document', 'cviewer');
commit;
