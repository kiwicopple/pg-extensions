-- Benchmark seed, part 1, design E (the Cedar model, cedar_* in the
-- extension): tenant-scoped roles as Cedar groups. The same documents and the
-- same facts as bench/seed_rbac.sql (each user: a role in their home org,
-- viewer in a second org), written as Cedar entities and template links.
-- Run it with bench/run.sh --design e (the extension file).
--
-- psql variables (set by bench/run.sh): docs, users, orgs
--
-- Entities (the subject type is user, the default of current_subject_type()):
--   user::"<md5('user' || u)::uuid>"   parents: the user's two roles (and,
--                                        from seed_sharing.sql, their teams)
--   Role::"<org>/admin" in Role::"<org>/editor" in Role::"<org>/viewer"
--   Org::"<md5('org' || o)::uuid>"     no parents: a role is not in its org,
--                                        or `resource in Org` would walk every
--                                        member (the list walks descendants)
-- Policies, two templates linked once per org (the Cedar way to write RBAC
-- with tenant scopes; 2 links per org):
--   org_read: permit (principal in ?principal, action == Action::"read", resource in ?resource);
--             linked with Role::"<org>/viewer" and Org::"<org>"
--   org_edit: permit (principal in ?principal, action == Action::"edit", resource in ?resource);
--             linked with Role::"<org>/editor" and Org::"<org>"
-- RLS: the select policy lists the orgs (InitPlan), the update policy checks
-- per row, as design D's rbac_* policies do.

\set ON_ERROR_STOP 1

create table public.documents (
    id        uuid primary key,
    org_id    uuid not null,
    folder_id uuid not null,
    title     text not null
);

insert into public.documents (id, org_id, folder_id, title)
select md5('doc' || n)::uuid, md5('org' || (n % :orgs))::uuid,
       md5('folder' || (n % :orgs + :orgs * ((n / :orgs) % 10)))::uuid, 'document ' || n
from generate_series(1, :docs) n;

create index on public.documents (org_id);
create index on public.documents (folder_id);

-- the roles of user u, as Cedar uids: the home org's role and viewer in a second org
create view bench.cedar_user_roles as
select u, jsonb_build_object('type', 'Role', 'id', md5('org' || (u % :orgs))::uuid || '/' || (array['viewer', 'editor', 'admin'])[1 + u % 3]) as role
from generate_series(1, :users) u
union all
select u, jsonb_build_object('type', 'Role', 'id', md5('org' || ((u * 7 + 3) % :orgs))::uuid || '/viewer')
from generate_series(1, :users) u
where (u * 7 + 3) % :orgs <> u % :orgs;

select permissions.cedar_put_entities(entities => (
    select jsonb_agg(e) from (
        select jsonb_build_object('uid', jsonb_build_object('type', 'Org', 'id', md5('org' || o)::uuid)) as e
        from generate_series(0, :orgs - 1) o
        union all
        select jsonb_build_object('uid', jsonb_build_object('type', 'Role', 'id', md5('org' || o)::uuid || '/' || r.name),
                                  'parents', case when r.parent is null then '[]'::jsonb
                                                  else jsonb_build_array(jsonb_build_object('type', 'Role', 'id', md5('org' || o)::uuid || '/' || r.parent)) end)
        from generate_series(0, :orgs - 1) o,
             (values ('viewer', null), ('editor', 'viewer'), ('admin', 'editor')) r(name, parent)) x));

-- users, in calls of at most 5,000 entities (the limit is 10,000)
select permissions.cedar_put_entities(entities => es)
from (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', md5('user' || u)::uuid),
                                          'parents', rs)) as es
      from (select u, jsonb_agg(role) as rs from bench.cedar_user_roles group by u) r
      group by u / 5000) c;

select permissions.cedar_put_template(template_id => 'org_read',
    template => 'permit (principal in ?principal, action == Action::"read", resource in ?resource);');
select permissions.cedar_put_template(template_id => 'org_edit',
    template => 'permit (principal in ?principal, action == Action::"edit", resource in ?resource);');
select count(permissions.cedar_link_template(policy_id => 'org_' || t || '_' || o, template_id => 'org_' || t,
                                             principal => format('Role::"%s/%s"', md5('org' || o)::uuid, case t when 'read' then 'viewer' else 'editor' end),
                                             resource => format('Org::"%s"', md5('org' || o)::uuid)))
from generate_series(0, :orgs - 1) o, (values ('read'), ('edit')) a(t);

alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;

create policy documents_select on public.documents for select to authenticated
    using (org_id = any (array(select permissions.cedar_list_resources_current('Action::"read"', 'Org')::uuid)));
create policy documents_update on public.documents for update to authenticated
    using (permissions.cedar_is_authorized_current('Action::"edit"', 'Org::"' || org_id || '"'));
