-- Benchmark seed, part 1, design D (the extension): tenant-scoped RBAC
-- through the rbac_* API. The same statements and data as bench/seed_rbac.sql,
-- which the prototypes load with their unprefixed API; only the names differ.
--
-- psql variables (set by bench/run.sh): docs, users, orgs
--
-- IDs are md5-derived UUIDs so the pgbench workloads can compute them:
--   user u   -> md5('user' || u)::uuid
--   org o    -> md5('org'  || o)::uuid,  o in 0 .. orgs-1
--   doc n    -> md5('doc'  || n)::uuid,  in org (n % orgs)
--   documents.folder_id -> md5('folder' || f)::uuid, f = n % orgs + orgs * ((n / orgs) % 10):
--   one of the org's 10 folders (bench/seed_shape.sql). Unused until the
--   parents phase; it's here so every phase runs on the same table.

\set ON_ERROR_STOP 1

select permissions.rbac_create_role('viewer', '{documents.read}');
select permissions.rbac_create_role('editor', '{documents.edit}', '{viewer}');
select permissions.rbac_create_role('admin',  '{documents.delete,users.manage}', '{editor}');

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

-- each user: a role in their home org (viewer, editor or admin by u % 3), and viewer in a second org
select permissions.rbac_assign_role(md5('user' || u)::uuid::text,
                               (array['viewer', 'editor', 'admin'])[1 + u % 3],
                               md5('org' || (u % :orgs))::uuid::text)
from generate_series(1, :users) u;

select permissions.rbac_assign_role(md5('user' || u)::uuid::text, 'viewer',
                               md5('org' || ((u * 7 + 3) % :orgs))::uuid::text)
from generate_series(1, :users) u
where (u * 7 + 3) % :orgs <> u % :orgs;

alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;

create policy documents_select on public.documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.rbac_scopes_with_permission('documents.read'))::uuid)));
create policy documents_update on public.documents for update to authenticated
    using (permissions.rbac_has_permission('documents.edit', org_id::text));
