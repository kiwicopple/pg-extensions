-- One permission check in the user's home org (the per-row path for writes).
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select permissions.has_permission('documents.edit', md5('org' || (:u % :orgs))::uuid::text);
commit;
