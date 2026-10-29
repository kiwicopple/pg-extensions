-- Sharing admin write: share a random document with a random user (one
-- OpenFGA Write through the fga_write_tuple convenience).
-- Rolled back so the data doesn't change: committed grants would differ per
-- engine (more tps, more rows) and leak into later phases and checksums.
\set u random(1, :users)
\set d random(1, :docs)
begin;
select permissions.fga_write_tuple('user:' || md5('user' || :u)::uuid, 'viewer', 'document:' || md5('doc' || :d)::uuid);
rollback;
