-- Sharing admin write: share a random document with a random user (1 tuple, no lock).
-- Rolled back so the data doesn't change: committed grants would differ per
-- engine (more tps, more rows) and leak into later phases and checksums.
\set u random(1, :users)
\set d random(1, :docs)
begin;
select permissions.grant('document', md5('doc' || :d)::uuid, 'viewer', 'user', md5('user' || :u)::uuid);
rollback;
