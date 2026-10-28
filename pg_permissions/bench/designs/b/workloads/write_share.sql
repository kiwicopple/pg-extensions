-- Sharing admin write: share a random document with a random user.
\set u random(1, :users)
\set d random(1, :docs)
select permissions.grant_role('user', md5('user' || :u)::uuid::text, 'viewer', 'document', md5('doc' || :d)::uuid::text);
