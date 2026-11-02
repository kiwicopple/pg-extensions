-- One permission check in the user's home org (the per-row path for writes):
-- edit on the org, through the user's role and the org_edit link.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select permissions.cedar_is_authorized_current('Action::"edit"', 'Org::"' || md5('org' || (:u % :orgs))::uuid || '"');
commit;
