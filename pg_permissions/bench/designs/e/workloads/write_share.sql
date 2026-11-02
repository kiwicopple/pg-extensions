-- Sharing admin write: share a random document with a random user (one
-- template link). Rolled back so the data doesn't change.
\set u random(1, :users)
\set d random(1, :docs)
begin;
select permissions.cedar_link_template(policy_id => 'ws_' || :u || '_' || :d, template_id => 'share_read',
                                       principal => 'user::"' || md5('user' || :u)::uuid || '"',
                                       resource => 'Document::"' || md5('doc' || :d)::uuid || '"');
rollback;
