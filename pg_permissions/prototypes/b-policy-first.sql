/*
 * pg_permissions prototype: Design B (policy-first) STAND-IN + rbac preset
 *
 * See ../designs/b-policy-first.md. This is NOT a full implementation of
 * Design B. It has B's schema, a minimal evaluator for permit policies with
 * no `via` (no parent anchors, conditions, forbid, or closure triggers), and
 * the rbac preset on top. It exists to show that the rbac preset tests are
 * engine-independent:
 *
 *   ./test/run.sh --impl prototypes/b-policy-first.sql
 *
 * The zanzibar-level spec files (30_*, 31_*, 40_*) use Design A's API and
 * are expected to fail here.
 */

create schema if not exists permissions;

-- ============================================================================
-- Schema (from the design doc)
-- ============================================================================

create table permissions.entities (
    type  text  not null,
    id    text  not null,
    attrs jsonb not null default '{}',
    primary key (type, id)
);

create table permissions.parents (
    child_type  text not null,
    child_id    text not null,
    parent_type text not null,
    parent_id   text not null,
    primary key (child_type, child_id, parent_type, parent_id),
    check ((child_type, child_id) <> (parent_type, parent_id))
);

create table permissions.ancestors (
    child_type    text     not null,
    child_id      text     not null,
    ancestor_type text     not null,
    ancestor_id   text     not null,
    depth         smallint not null check (depth between 1 and 10),
    primary key (child_type, child_id, ancestor_type, ancestor_id)
);

create table permissions.roles (
    resource_type text not null,
    role          text not null,
    primary key (resource_type, role)
);

create table permissions.role_implies (
    resource_type text not null,
    role          text not null,
    implies       text not null,
    primary key (resource_type, role, implies),
    foreign key (resource_type, role)    references permissions.roles on delete cascade,
    foreign key (resource_type, implies) references permissions.roles on delete cascade
);

create table permissions.role_closure (
    resource_type text not null,
    role          text not null,
    implied       text not null,
    primary key (resource_type, implied, role)
);

create table permissions.role_grants (
    principal_type text not null,
    principal_id   text not null,
    role           text not null,
    resource_type  text not null,
    resource_id    text not null,
    expires_at     timestamptz,
    primary key (principal_type, principal_id, resource_type, resource_id, role),
    foreign key (resource_type, role) references permissions.roles on delete cascade
);
create index on permissions.role_grants (resource_type, resource_id);

create table permissions.policies (
    id            bigint generated always as identity primary key,
    name          text not null unique,
    effect        text not null default 'permit' check (effect = 'permit'),
    actions       text[] not null,
    resource_type text not null,
    roles         text[],
    via           text,
    managed_by    text,      -- 'rbac' for policies the preset generates
    enabled       boolean not null default true
);

-- ============================================================================
-- Identity (contract names: current_subject_id, permissions.subject_id)
-- ============================================================================

create function permissions.current_subject_id()
returns text
language sql stable
set search_path = ''
as $$
    select coalesce(
        nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', ''),
        nullif(current_setting('permissions.subject_id', true), '')
    )
$$;

create function permissions.current_subject_type()
returns text
language sql stable
set search_path = ''
as $$
    select coalesce(nullif(current_setting('permissions.subject_type', true), ''), 'user')
$$;

-- ============================================================================
-- Minimal engine
-- ============================================================================

create function permissions._rebuild_role_closure(p_type text)
returns void
language sql
set search_path = ''
as $$
    delete from permissions.role_closure where resource_type = p_type;
    insert into permissions.role_closure (resource_type, role, implied)
    with recursive c(role, implied) as (
        select role, role from permissions.roles where resource_type = p_type
      union
        select c.role, ri.implies
        from c join permissions.role_implies ri on ri.resource_type = p_type and ri.role = c.implied
    )
    select p_type, role, implied from c;
$$;

-- Resource IDs of p_type the subject can reach for p_action (permit, no via).
create function permissions.ids_for(p_subject_type text, p_subject_id text, p_action text, p_type text)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select coalesce(array_agg(distinct g.resource_id), '{}')
    from permissions.policies p
    join permissions.role_closure rc on rc.resource_type = p.resource_type and rc.implied = any (p.roles)
    join permissions.role_grants g on g.resource_type = p.resource_type and g.role = rc.role
    where p_subject_id is not null
      and p.enabled and p.via is null
      and p_action = any (p.actions) and p.resource_type = p_type
      and (g.expires_at is null or g.expires_at > now())
      and ((g.principal_type = p_subject_type and g.principal_id = p_subject_id)
           or (g.principal_type, g.principal_id) in (
               select ancestor_type, ancestor_id from permissions.ancestors
               where child_type = p_subject_type and child_id = p_subject_id))
$$;

create function permissions.can_for(p_subject_type text, p_subject_id text, p_action text, p_type text, p_id text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select coalesce(p_id = any (permissions.ids_for(p_subject_type, p_subject_id, p_action, p_type)), false)
$$;

create function permissions._holds_role(p_subject_type text, p_subject_id text, p_role text, p_type text, p_id text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select exists (
        select 1
        from permissions.role_grants g
        join permissions.role_closure rc on rc.resource_type = g.resource_type and rc.role = g.role
        where g.resource_type = p_type and g.resource_id = p_id and rc.implied = p_role
          and g.principal_type = p_subject_type and g.principal_id = p_subject_id
          and (g.expires_at is null or g.expires_at > now())
    )
$$;

-- ============================================================================
-- rbac preset (PLAN.md §6)
-- ============================================================================

create function permissions._scope_resource(p_scope text, out resource_type text, out resource_id text)
language sql immutable
set search_path = ''
as $$
    select case when p_scope is null then 'app' else 'tenant' end, coalesce(p_scope, 'global')
$$;

create function permissions.create_role(p_role text, p_permissions text[], p_inherits text[] default '{}')
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    t text;
    x text;
begin
    if exists (select 1 from permissions.roles where resource_type = 'app' and role = p_role) then
        raise exception 'role % already exists', p_role using errcode = '23505';
    end if;
    if exists (select 1 from permissions.policies where managed_by = 'rbac' and p_role = any (actions))
       or exists (select 1 from permissions.roles where resource_type = 'app' and role = any (p_permissions))
       or p_role = any (p_permissions) then
        raise exception 'role and permission names must not overlap' using errcode = '22023';
    end if;
    select i into x from unnest(p_inherits) i
    where not exists (select 1 from permissions.roles where resource_type = 'app' and role = i) limit 1;
    if x is not null then
        raise exception 'unknown role % in inherits', x using errcode = '22023';
    end if;

    foreach t in array array['app', 'tenant'] loop
        insert into permissions.roles values (t, p_role);
        insert into permissions.role_implies select t, p_role, i from unnest(p_inherits) i;
        perform permissions._rebuild_role_closure(t);
        insert into permissions.policies (name, actions, resource_type, roles, managed_by)
        values ('rbac:' || t || ':' || p_role, p_permissions, t, array[p_role], 'rbac');
    end loop;
end;
$$;

create function permissions.drop_role(p_role text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    heir text;
    t text;
begin
    if not exists (select 1 from permissions.roles where resource_type = 'app' and role = p_role) then
        raise exception 'unknown role %', p_role using errcode = '22023';
    end if;
    select role into heir from permissions.role_implies where resource_type = 'app' and implies = p_role limit 1;
    if heir is not null then
        raise exception 'role % is inherited by %', p_role, heir using errcode = '2BP01';
    end if;
    foreach t in array array['app', 'tenant'] loop
        delete from permissions.policies where name = 'rbac:' || t || ':' || p_role;
        delete from permissions.roles where resource_type = t and role = p_role;  -- cascades to grants and implications
        perform permissions._rebuild_role_closure(t);
    end loop;
end;
$$;

create function permissions.assign_role(p_user_id text, p_role text, p_scope text default null)
returns void
language sql security definer
set search_path = ''
as $$
    insert into permissions.role_grants (principal_type, principal_id, role, resource_type, resource_id)
    select 'user', p_user_id, p_role, s.resource_type, s.resource_id from permissions._scope_resource(p_scope) s
    on conflict do nothing
$$;

create function permissions.unassign_role(p_user_id text, p_role text, p_scope text default null)
returns void
language sql security definer
set search_path = ''
as $$
    delete from permissions.role_grants g
    using permissions._scope_resource(p_scope) s
    where g.principal_type = 'user' and g.principal_id = p_user_id and g.role = p_role
      and g.resource_type = s.resource_type and g.resource_id = s.resource_id
$$;

create function permissions.has_permission(p_permission text, p_scope text default null)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions.can_for(permissions.current_subject_type(), permissions.current_subject_id(),
                               p_permission, s.resource_type, s.resource_id)
    from permissions._scope_resource(p_scope) s
$$;

create function permissions.has_role(p_role text, p_scope text default null)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions._holds_role(permissions.current_subject_type(), permissions.current_subject_id(),
                                   p_role, s.resource_type, s.resource_id)
    from permissions._scope_resource(p_scope) s
$$;

create function permissions.scopes_with_permission(p_permission text)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select permissions.ids_for(permissions.current_subject_type(), permissions.current_subject_id(), p_permission, 'tenant')
$$;

create function permissions.user_permissions(p_user_id text, p_scope text default null)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select coalesce(array_agg(distinct a order by a), '{}')
    from permissions._scope_resource(p_scope) s, permissions.policies p, unnest(p.actions) a
    where p.managed_by = 'rbac' and p.resource_type = s.resource_type
      and permissions.can_for('user', p_user_id, a, s.resource_type, s.resource_id)
$$;

create function permissions.users_with_role(p_role text, p_scope text default null)
returns setof text
language sql stable security definer
set search_path = ''
as $$
    select distinct g.principal_id
    from permissions._scope_resource(p_scope) s
    join permissions.role_grants g on g.resource_type = s.resource_type and g.resource_id = s.resource_id
    join permissions.role_closure rc on rc.resource_type = g.resource_type and rc.role = g.role
    where rc.implied = p_role and g.principal_type = 'user'
      and (g.expires_at is null or g.expires_at > now())
$$;

-- ============================================================================
-- Privileges
-- ============================================================================

revoke all on all tables in schema permissions from public;
revoke all on all functions in schema permissions from public;
grant usage on schema permissions to public;

grant execute on function
    permissions.current_subject_id(),
    permissions.current_subject_type(),
    permissions.has_permission(text, text),
    permissions.has_role(text, text),
    permissions.scopes_with_permission(text)
to public;
