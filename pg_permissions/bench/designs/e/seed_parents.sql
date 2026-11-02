-- Benchmark seed, part 3a (design E, Cedar): folders, with the two-arm
-- projection policy. Loaded after the share_* workloads; it replaces the
-- Cedar select policy. seed_parent_docs.sql follows.
--
--   Folder::"<md5('folder' || f)::uuid>"   stored, no parents (as in D, the
--                                           org arm covers what a folder ->
--                                           org link would add)
--   folder_read: permit (principal == ?principal, action == Action::"read", resource in ?resource);
--                one link per folder viewer (the user, the folder)
-- Documents are not linked to folders yet: their folder is only the app
-- column documents.folder_id, so the policy projects the folder arm onto it.

\set ON_ERROR_STOP 1

select permissions.cedar_put_entities(entities => (
    select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Folder', 'id', md5('folder' || f)::uuid)))
    from bench.folders));

select permissions.cedar_put_template(template_id => 'folder_read',
    template => 'permit (principal == ?principal, action == Action::"read", resource in ?resource);');
select count(permissions.cedar_link_template(policy_id => 'fv_' || u || '_' || f, template_id => 'folder_read',
                                             principal => format('user::"%s"', md5('user' || u)::uuid),
                                             resource => format('Folder::"%s"', md5('folder' || f)::uuid)))
from (select distinct u, f from bench.folder_viewers) v;

drop policy documents_select_cedar on public.documents;
create policy documents_select_cedar on public.documents for select to authenticated using (
    id = any (array(select permissions.cedar_list_resources_current('Action::"read"', 'Document')::uuid))
    or folder_id = any (array(select permissions.cedar_list_resources_current('Action::"read"', 'Folder')::uuid))
);
