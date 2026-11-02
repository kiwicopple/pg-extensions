-- Benchmark seed, part 2 (design E, Cedar): per-document sharing with nested
-- teams. Data from the shape tables (bench/seed_shape.sql), as for every
-- design.
--
--   Team::"<md5('team' || k)::uuid>"   parents: the team it is nested in
--                                        (team k's members are members of
--                                        its parent, as in D's team#member)
--   user::"..."                         re-put with their roles and teams
--   Document::"<id>"                    every document, stored (the list
--                                        returns stored entities only), no
--                                        parents until seed_parent_docs.sql
--   share_read: permit (principal in ?principal, action == Action::"read", resource == ?resource);
--               one link per team grant (Team k, the document)
--   share_edit: permit (principal == ?principal, action in [Action::"read", Action::"edit"], resource == ?resource);
--               one link per direct grant (the user, the document): an
--               editor can view, as D's `viewer: ... or editor`
-- The org roles stay seed_rbac.sql's policy: permissive policies OR.
--
-- Plus the fixture of write_nest_team and nest_check: Team::"nest-src"
-- (md5('nest-src')::uuid) with 1,000 members md5('nest-user' || i)::uuid.

\set ON_ERROR_STOP 1

select permissions.cedar_put_entities(entities => es)
from (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Team', 'id', md5('team' || k)::uuid),
                                          'parents', coalesce((select jsonb_agg(jsonb_build_object('type', 'Team', 'id', md5('team' || p.parent)::uuid))
                                                               from bench.team_parents p where p.child = k), '[]'))) as es
      from generate_series(1, :teams) k
      group by k / 5000) c;

select permissions.cedar_put_entities(entities => es)
from (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', md5('user' || r.u)::uuid),
                                          'parents', r.rs || coalesce(t.ts, '[]'))) as es
      from (select u, jsonb_agg(role) as rs from bench.cedar_user_roles group by u) r
      left join (select u, jsonb_agg(distinct jsonb_build_object('type', 'Team', 'id', md5('team' || team)::uuid)) as ts
                 from bench.team_members group by u) t on t.u = r.u
      group by r.u / 5000) c;

select permissions.cedar_put_entities(entities => jsonb_build_array(jsonb_build_object('uid', jsonb_build_object('type', 'Team', 'id', md5('nest-src')::uuid))));
select permissions.cedar_put_entities(entities => (
    select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', md5('nest-user' || i)::uuid),
                                        'parents', jsonb_build_array(jsonb_build_object('type', 'Team', 'id', md5('nest-src')::uuid))))
    from generate_series(1, 1000) i));

select count(permissions.cedar_put_entities(entities => es))
from (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Document', 'id', d.id))) as es
      from (select id, row_number() over (order by id) as n from public.documents) d
      group by d.n / 10000) c;

select permissions.cedar_put_template(template_id => 'share_read',
    template => 'permit (principal in ?principal, action == Action::"read", resource == ?resource);');
select permissions.cedar_put_template(template_id => 'share_edit',
    template => 'permit (principal == ?principal, action in [Action::"read", Action::"edit"], resource == ?resource);');
select count(permissions.cedar_link_template(policy_id => 'tg_' || team || '_' || doc, template_id => 'share_read',
                                             principal => format('Team::"%s"', md5('team' || team)::uuid),
                                             resource => format('Document::"%s"', md5('doc' || doc)::uuid)))
from (select distinct team, doc from bench.team_grants) g;
select count(permissions.cedar_link_template(policy_id => 'ug_' || u || '_' || doc, template_id => 'share_edit',
                                             principal => format('user::"%s"', md5('user' || u)::uuid),
                                             resource => format('Document::"%s"', md5('doc' || doc)::uuid)))
from (select distinct u, doc from bench.user_grants) g;

create policy documents_select_cedar on public.documents for select to authenticated using (
    id = any (array(select permissions.cedar_list_resources_current('Action::"read"', 'Document')::uuid))
);

create policy documents_update_cedar on public.documents for update to authenticated using (
    permissions.cedar_is_authorized_current('Action::"edit"', 'Document::"' || id || '"')
);
