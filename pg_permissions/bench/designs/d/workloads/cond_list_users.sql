-- Conditions: ListUsers for the same documents as plain_list_users, through
-- `cviewer` (every membership and grant on the way carries the condition).
\set k random(1, :teams)
\set d (:k * 9973 + 7919) % :docs + 1
select count(*) from permissions.fga_list_users('document:' || md5('doc' || :d)::uuid, 'cviewer', '{user}');
