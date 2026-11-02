-- Conditions, twin without: ListUsers (the admin API, fga_list_users) for the
-- users who can view a document shared with a random team, through `viewer`.
-- The unconditioned twin of cond_list_users.
\set k random(1, :teams)
\set d (:k * 9973 + 7919) % :docs + 1
select count(*) from permissions.fga_list_users('document:' || md5('doc' || :d)::uuid, 'viewer', '{user}');
