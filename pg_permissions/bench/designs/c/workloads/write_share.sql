-- Sharing admin write: share a random document with a random user (1 tuple, no lock).
\set u random(1, :users)
\set d random(1, :docs)
select permissions.grant('document', md5('doc' || :d)::uuid, 'viewer', 'user', md5('user' || :u)::uuid);
