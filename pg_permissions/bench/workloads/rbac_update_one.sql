-- Update one document in the user's home org by primary key (single-row write under RLS).
\set u random(1, :users)
\set k random(0, :docs / :orgs - 1)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
update public.documents set title = title where id = md5('doc' || ((:u % :orgs) + :orgs * :k))::uuid;
commit;
