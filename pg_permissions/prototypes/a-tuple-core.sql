/*
 * pg_permissions prototype: Design A (shared tuple core) + rbac preset
 *
 * See ../designs/a-tuple-core.md. This is a prototype for testing and
 * benchmarking, not the extension itself. Run the test suite against it with:
 *
 *   ./test/run.sh --impl prototypes/a-tuple-core.sql
 */

create schema if not exists permissions;

-- ============================================================================
-- Core store
-- ============================================================================

create table permissions.object_types (
    name        text primary key,
    description text
);

create table permissions.relations (
    object_type text not null references permissions.object_types(name) on delete cascade,
    relation    text not null,
    implied_by  text[] not null default '{}',
    description text,
    primary key (object_type, relation)
);

create table permissions.tuples (
    id               bigint generated always as identity primary key,
    object_type      text not null,
    object_id        text not null,
    relation         text not null,
    subject_type     text not null,
    subject_id       text not null,
    subject_relation text not null default '',
    condition        jsonb,
    expires_at       timestamptz,
    created_at       timestamptz not null default now(),
    foreign key (object_type, relation) references permissions.relations(object_type, relation) on delete cascade,
    unique (object_type, object_id, relation, subject_type, subject_id, subject_relation)
);

create index on permissions.tuples (subject_type, subject_id, subject_relation);
create index on permissions.tuples (object_type, object_id, relation);

create table permissions.entities (
    entity_type text not null,
    entity_id   text not null,
    attributes  jsonb not null default '{}',
    primary key (entity_type, entity_id)
);

-- ============================================================================
-- Identity
-- ============================================================================

-- JWT `sub` (PostgREST / Supabase) wins; the session setting is the fallback
-- for plain Postgres, tests and server-side jobs.
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
-- Model definition
-- ============================================================================

create function permissions.define_type(p_name text, p_description text default null)
returns void
language sql security definer
set search_path = ''
as $$
    insert into permissions.object_types (name, description) values (p_name, p_description)
    on conflict (name) do update set description = coalesce(excluded.description, object_types.description)
$$;

-- Defining a relation again replaces its implied_by list.
create function permissions.define_relation(p_object_type text, p_relation text, p_implied_by text[] default '{}')
returns void
language sql security definer
set search_path = ''
as $$
    insert into permissions.relations (object_type, relation, implied_by) values (p_object_type, p_relation, p_implied_by)
    on conflict (object_type, relation) do update set implied_by = excluded.implied_by
$$;

-- ============================================================================
-- Writing tuples
-- ============================================================================

create function permissions.grant(
    p_object_type text, p_object_id text, p_relation text,
    p_subject_type text, p_subject_id text, p_subject_relation text default '',
    p_expires_at timestamptz default null
)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    if p_subject_relation <> '' and not exists (
        select 1 from permissions.relations where object_type = p_subject_type and relation = p_subject_relation
    ) then
        raise exception 'unknown relation %#%', p_subject_type, p_subject_relation using errcode = '22023';
    end if;

    insert into permissions.tuples (object_type, object_id, relation, subject_type, subject_id, subject_relation, expires_at)
    values (p_object_type, p_object_id, p_relation, p_subject_type, p_subject_id, coalesce(p_subject_relation, ''), p_expires_at)
    on conflict (object_type, object_id, relation, subject_type, subject_id, subject_relation)
    do update set expires_at = excluded.expires_at;
end;
$$;

create function permissions.revoke(
    p_object_type text, p_object_id text, p_relation text,
    p_subject_type text, p_subject_id text, p_subject_relation text default ''
)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
begin
    delete from permissions.tuples
    where object_type = p_object_type and object_id = p_object_id and relation = p_relation
      and subject_type = p_subject_type and subject_id = p_subject_id
      and subject_relation = coalesce(p_subject_relation, '');
    return found;
end;
$$;

create function permissions.delete_subject(p_subject_type text, p_subject_id text)
returns bigint
language sql security definer
set search_path = ''
as $$
    with d as (
        delete from permissions.tuples
        where (subject_type = p_subject_type and subject_id = p_subject_id)
           or (object_type = p_subject_type and object_id = p_subject_id)
        returning 1
    )
    select count(*) from d
$$;

create function permissions.delete_object(p_object_type text, p_object_id text)
returns bigint
language sql security definer
set search_path = ''
as $$
    with d as (
        delete from permissions.tuples where object_type = p_object_type and object_id = p_object_id
        returning 1
    )
    select count(*) from d
$$;

-- ============================================================================
-- Evaluation
-- ============================================================================

-- Every (object_type, object_id, relation) node a subject can reach.
-- `union` removes duplicates, so cycles terminate.
create function permissions._reach(p_subject_type text, p_subject_id text)
returns table (object_type text, object_id text, relation text)
language sql stable security definer
set search_path = ''
as $$
    with recursive reach(object_type, object_id, relation) as (
        select p_subject_type, p_subject_id, ''::text
      union
        select n.object_type, n.object_id, n.relation
        from reach r
        cross join lateral (
            select t.object_type, t.object_id, t.relation
            from permissions.tuples t
            where t.subject_type = r.object_type
              and t.subject_id = r.object_id
              and t.subject_relation = r.relation
              and t.condition is null
              and (t.expires_at is null or t.expires_at > now())
          union all
            select r.object_type, r.object_id, rel.relation
            from permissions.relations rel
            where rel.object_type = r.object_type
              and r.relation = any (rel.implied_by)
        ) n
    )
    select * from reach where p_subject_id is not null
$$;

-- Explicit-subject variants: admin only (see the grants at the end).
create function permissions.check_for(
    p_subject_type text, p_subject_id text,
    p_object_type text, p_object_id text, p_relation text
)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select exists (
        select 1 from permissions._reach(p_subject_type, p_subject_id) r
        where r.object_type = p_object_type and r.object_id = p_object_id and r.relation = p_relation
    )
$$;

create function permissions.list_objects_for(
    p_subject_type text, p_subject_id text,
    p_object_type text, p_relation text
)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select coalesce(array_agg(distinct r.object_id), '{}')
    from permissions._reach(p_subject_type, p_subject_id) r
    where r.object_type = p_object_type and r.relation = p_relation
$$;

create function permissions.list_subjects(p_object_type text, p_object_id text, p_relation text)
returns table (subject_type text, subject_id text)
language sql stable security definer
set search_path = ''
as $$
    with recursive back(t, i, r) as (
        select p_object_type, p_object_id, p_relation
      union
        select n.t, n.i, n.r
        from back b
        cross join lateral (
            select tu.subject_type, tu.subject_id, tu.subject_relation
            from permissions.tuples tu
            where tu.object_type = b.t and tu.object_id = b.i and tu.relation = b.r
              and tu.condition is null
              and (tu.expires_at is null or tu.expires_at > now())
          union all
            select b.t, b.i, x
            from permissions.relations rel, unnest(rel.implied_by) x
            where rel.object_type = b.t and rel.relation = b.r
        ) n(t, i, r)
    )
    select distinct t, i from back where r = ''
$$;

-- Current-subject variants: safe for clients and RLS policies.
create function permissions.check(p_object_type text, p_object_id text, p_relation text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions.check_for(
        permissions.current_subject_type(), permissions.current_subject_id(),
        p_object_type, p_object_id, p_relation)
$$;

create function permissions.list_objects(p_object_type text, p_relation text)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select permissions.list_objects_for(
        permissions.current_subject_type(), permissions.current_subject_id(),
        p_object_type, p_relation)
$$;

-- ============================================================================
-- rbac preset (PLAN.md §6)
-- ============================================================================

select permissions.define_type('user');
select permissions.define_type('app', 'Single object app:global holds app-wide roles');
select permissions.define_type('tenant', 'One object per scope holds scoped roles');

create table permissions.rbac_roles (
    role        text primary key,
    permissions text[] not null,
    inherits    text[] not null default '{}'
);

create function permissions._scope_object(p_scope text, out object_type text, out object_id text)
language sql immutable
set search_path = ''
as $$
    select case when p_scope is null then 'app' else 'tenant' end, coalesce(p_scope, 'global')
$$;

create function permissions._add_implied_by(p_type text, p_relation text, p_by text)
returns void
language sql
set search_path = ''
as $$
    insert into permissions.relations (object_type, relation, implied_by) values (p_type, p_relation, array[p_by])
    on conflict (object_type, relation) do update
    set implied_by = array_append(relations.implied_by, p_by)
    where not p_by = any (relations.implied_by)
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
    if exists (select 1 from permissions.rbac_roles where role = p_role) then
        raise exception 'role % already exists', p_role using errcode = '23505';
    end if;
    if exists (select 1 from permissions.rbac_roles where p_role = any (permissions))
       or exists (select 1 from permissions.rbac_roles where role = any (p_permissions))
       or p_role = any (p_permissions) then
        raise exception 'role and permission names must not overlap' using errcode = '22023';
    end if;
    select i into x from unnest(p_inherits) i
    where not exists (select 1 from permissions.rbac_roles where role = i) limit 1;
    if x is not null then
        raise exception 'unknown role % in inherits', x using errcode = '22023';
    end if;

    insert into permissions.rbac_roles (role, permissions, inherits) values (p_role, p_permissions, p_inherits);

    foreach t in array array['app', 'tenant'] loop
        insert into permissions.relations (object_type, relation) values (t, p_role) on conflict do nothing;
        foreach x in array p_permissions loop perform permissions._add_implied_by(t, x, p_role); end loop;
        foreach x in array p_inherits    loop perform permissions._add_implied_by(t, x, p_role); end loop;
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
begin
    if not exists (select 1 from permissions.rbac_roles where role = p_role) then
        raise exception 'unknown role %', p_role using errcode = '22023';
    end if;
    select role into heir from permissions.rbac_roles where p_role = any (inherits) limit 1;
    if heir is not null then
        raise exception 'role % is inherited by %', p_role, heir using errcode = '2BP01';
    end if;

    delete from permissions.rbac_roles where role = p_role;
    -- removing the relation cascades to its tuples (the assignments)
    delete from permissions.relations where object_type in ('app', 'tenant') and relation = p_role;
    update permissions.relations set implied_by = array_remove(implied_by, p_role)
    where object_type in ('app', 'tenant') and p_role = any (implied_by);
    -- permissions no role grants any more
    delete from permissions.relations r
    where r.object_type in ('app', 'tenant') and r.implied_by = '{}'
      and not exists (select 1 from permissions.rbac_roles where role = r.relation);
end;
$$;

create function permissions.assign_role(p_user_id text, p_role text, p_scope text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    if not exists (select 1 from permissions.rbac_roles where role = p_role) then
        raise exception 'unknown role %', p_role using errcode = '22023';
    end if;
    perform permissions.grant(s.object_type, s.object_id, p_role, 'user', p_user_id)
    from permissions._scope_object(p_scope) s;
end;
$$;

create function permissions.unassign_role(p_user_id text, p_role text, p_scope text default null)
returns void
language sql security definer
set search_path = ''
as $$
    select permissions.revoke(s.object_type, s.object_id, p_role, 'user', p_user_id)
    from permissions._scope_object(p_scope) s
$$;

create function permissions.has_permission(p_permission text, p_scope text default null)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions.check(s.object_type, s.object_id, p_permission)
    from permissions._scope_object(p_scope) s
$$;

create function permissions.has_role(p_role text, p_scope text default null)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select exists (select 1 from permissions.rbac_roles where role = p_role)
       and permissions.check(s.object_type, s.object_id, p_role)
    from permissions._scope_object(p_scope) s
$$;

create function permissions.scopes_with_permission(p_permission text)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select permissions.list_objects('tenant', p_permission)
$$;

create function permissions.user_permissions(p_user_id text, p_scope text default null)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select coalesce(array_agg(distinct r.relation order by r.relation), '{}')
    from permissions._scope_object(p_scope) s
    join permissions._reach('user', p_user_id) r on r.object_type = s.object_type and r.object_id = s.object_id
    where exists (select 1 from permissions.rbac_roles rr where r.relation = any (rr.permissions))
$$;

create function permissions.users_with_role(p_role text, p_scope text default null)
returns setof text
language sql stable security definer
set search_path = ''
as $$
    select ls.subject_id
    from permissions._scope_object(p_scope) s,
         permissions.list_subjects(s.object_type, s.object_id, p_role) ls
    where ls.subject_type = 'user'
      and exists (select 1 from permissions.rbac_roles where role = p_role)
$$;

-- ============================================================================
-- Privileges
-- ============================================================================

revoke all on all tables in schema permissions from public;
revoke all on all functions in schema permissions from public;
grant usage on schema permissions to public;

-- Client-facing: current subject only.
grant execute on function
    permissions.current_subject_id(),
    permissions.current_subject_type(),
    permissions.check(text, text, text),
    permissions.list_objects(text, text),
    permissions.has_permission(text, text),
    permissions.has_role(text, text),
    permissions.scopes_with_permission(text)
to public;

-- Everything else (model definition, grants, explicit-subject checks) is for
-- the owner and whichever trusted roles the app grants, e.g. service_role.
