-- Per row (design E only, seed_rowcheck.sql): first page through the policy
-- that calls cedar_is_authorized_current on every row it reads, with the
-- row's org as a resource attribute.
\set u random(1, :users)
begin;
select set_config('permissions.subject_id', md5('user' || :u)::uuid::text, true);
set local role authenticated;
select id, title from public.documents order by id limit 50;
commit;
