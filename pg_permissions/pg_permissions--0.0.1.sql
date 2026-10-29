/*
 * pg_permissions
 *
 * Copyright (c) 2026 Paul Copplestone: https://github.com/kiwicopple/pg-extensions/
 *
 * Design: ../designs/d-per-model.md. Two independent models in one schema:
 *
 *   rbac_*  roles, permissions, scoped assignments (the blessed path)
 *   fga_*   OpenFGA: JSON authorization models (schema 1.1), tuples, Check,
 *           ListObjects, ListUsers, Read, Write, with OpenFGA's semantics and
 *           error codes, tested against OpenFGA's own test suite (test/fga/)
 *
 * They share only the toolkit: subject identity, the plan-time guard
 * (_unfolded_null) and the grants. An app composes them in RLS: permissive
 * policies OR, restrictive policies AND.
 *
 * This file is the extension (design D, chosen at the end of session 4). The
 * A, B and C prototypes in prototypes/ are measured history.
 *
 *   ./test/run.sh
 */

create schema if not exists permissions;

-- ============================================================================
-- Toolkit: identity and the plan-time guard (shared by every model)
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

-- Default of the ignored trailing argument of functions that RLS policies
-- call inside `array(select unnest(f(...)))`. For a STABLE function with
-- all-constant arguments the planner evaluates the call while planning, to
-- estimate the unnest's row count, and the executor runs it again. A volatile
-- default makes the call non-constant while the function stays STABLE (and so
-- keeps the statement's snapshot). PLAN.md §4.
create function permissions._unfolded_null()
returns boolean
language plpgsql volatile
as $$
begin
    return null;
end;
$$;

-- Error hints (DECISION.md, end of session 4, point 5): every error has a
-- HINT, and a misspelt name gets the nearest existing one. Levenshtein edit
-- distance, written here because the extension stays plain SQL and PL/pgSQL
-- (pg_tle): no fuzzystrmatch or pg_trgm. Only ever called on an error path.
create function permissions._edit_distance(a text, b text)
returns int
language plpgsql immutable strict
as $$
declare
    la int := char_length(a);
    lb int := char_length(b);
    prev int[];
    cur int[];
begin
    if la = 0 or lb = 0 then
        return greatest(la, lb);
    end if;
    prev := array(select generate_series(0, lb));          -- prev[j + 1]: distance to b's first j characters
    for i in 1..la loop
        cur := array[i];
        for j in 1..lb loop
            cur := cur || least(prev[j + 1] + 1, cur[j] + 1,
                                prev[j] + case when substr(a, i, 1) = substr(b, j, 1) then 0 else 1 end);
        end loop;
        prev := cur;
    end loop;
    return prev[lb + 1];
end;
$$;

-- '<what>: a, b, c.' (sorted, at most 20 names), preceded by 'Did you mean
-- ''x''? ' when a name is within a third of the input's length (1 to 3 edits,
-- case-insensitive). Null when there are no names.
create function permissions._did_you_mean(p_input text, p_names text[], p_what text)
returns text
language sql immutable
as $$
    select concat(
        (select format('Did you mean ''%s''? ', n) from unnest(p_names) n
         where permissions._edit_distance(lower(p_input), lower(n)) <= greatest(1, least(3, char_length(p_input) / 3))
         order by permissions._edit_distance(lower(p_input), lower(n)), n limit 1),
        p_what, ': ',
        (select string_agg(n, ', ' order by n) from (select n from unnest(p_names) n order by n limit 20) l),
        case when cardinality(p_names) > 20 then format(' and %s more', cardinality(p_names) - 20) end,
        '.')
    where cardinality(p_names) > 0
$$;

-- ============================================================================
-- RBAC: rbac_* tables
-- ============================================================================
--
-- A role grants permissions and includes the roles it inherits. Assignments
-- give a user a role app-wide (scope null) or in one scope (a tenant or org
-- id). App-wide and scoped roles are separate: has_permission(p) looks only at
-- app-wide assignments, has_permission(p, scope) only at that scope.
--
-- rbac_role_closure is maintained by create_role/drop_role: every role a role
-- includes, itself too. Roles can't change after creation and a role can only
-- inherit roles that exist, so the closure of a new role is its parents'
-- closures plus itself, and no other row ever changes.

create table permissions.rbac_roles (
    role       text collate "C" primary key,
    created_at timestamptz not null default now()
);

create table permissions.rbac_role_permissions (
    role       text collate "C" not null references permissions.rbac_roles on delete cascade,
    permission text collate "C" not null,
    primary key (role, permission)
);
create index on permissions.rbac_role_permissions (permission);

create table permissions.rbac_role_inherits (
    role     text collate "C" not null references permissions.rbac_roles on delete cascade,
    inherits text collate "C" not null references permissions.rbac_roles,
    primary key (role, inherits)
);
create index on permissions.rbac_role_inherits (inherits);

create table permissions.rbac_role_closure (
    role     text collate "C" not null references permissions.rbac_roles on delete cascade,
    includes text collate "C" not null references permissions.rbac_roles on delete cascade,
    primary key (role, includes)
);
create index on permissions.rbac_role_closure (includes);

create table permissions.rbac_assignments (
    user_id    text collate "C" not null,
    role       text collate "C" not null references permissions.rbac_roles on delete cascade,
    scope      text collate "C",          -- null: app-wide
    created_at timestamptz not null default now(),
    constraint rbac_assignments_key unique nulls not distinct (user_id, scope, role)
);
create index on permissions.rbac_assignments (scope, role);
create index on permissions.rbac_assignments (role);

-- For an unknown role: the nearest existing role, or what to do first.
create function permissions._rbac_role_hint(p_role text)
returns text
language sql stable
as $$
    select coalesce(
        permissions._did_you_mean(p_role, array(select r.role from permissions.rbac_roles r), 'Existing roles'),
        format('No roles exist yet: create it first, e.g. select permissions.create_role(%L, ''{documents.read}'').', p_role))
$$;

create function permissions.create_role(p_role text, p_permissions text[], p_inherits text[] default '{}')
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    x text;
begin
    if exists (select 1 from permissions.rbac_roles where role = p_role) then
        raise exception 'role ''%'' already exists', p_role using errcode = '23505',
            hint = format('Roles are immutable: pick another name, or drop_role(%L) and create it again (that also removes its assignments).', p_role);
    end if;
    select case when exists (select 1 from permissions.rbac_role_permissions where permission = p_role)
                then format('%L is already a permission', p_role)
                when p_role = any (p_permissions)
                then format('role %L lists itself as a permission', p_role)
                else (select format('%L is already a role', r.role) from permissions.rbac_roles r
                      where r.role = any (p_permissions) order by r.role limit 1) end
    into x;
    if x is not null then
        raise exception 'role and permission names must not overlap: %', x using errcode = '22023',
            hint = 'has_role and has_permission share one namespace: use distinct names, e.g. a role ''editor'' with permissions like ''documents.edit''.';
    end if;
    select i into x from unnest(p_inherits) i
    where not exists (select 1 from permissions.rbac_roles where role = i) limit 1;
    if x is not null then
        raise exception 'unknown role ''%'' in inherits of role ''%''', x, p_role using errcode = '22023',
            hint = permissions._rbac_role_hint(x);
    end if;

    insert into permissions.rbac_roles (role) values (p_role);
    insert into permissions.rbac_role_permissions (role, permission)
    select distinct p_role, p from unnest(p_permissions) p where p is not null;
    insert into permissions.rbac_role_inherits (role, inherits)
    select distinct p_role, i from unnest(p_inherits) i;
    insert into permissions.rbac_role_closure (role, includes)
    select p_role, p_role
    union
    select p_role, c.includes from permissions.rbac_role_closure c where c.role = any (p_inherits);
end;
$$;

create function permissions.drop_role(p_role text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    heirs text[];
begin
    if not exists (select 1 from permissions.rbac_roles where role = p_role) then
        raise exception 'unknown role ''%''', p_role using errcode = '22023',
            hint = permissions._rbac_role_hint(p_role);
    end if;
    heirs := array(select role from permissions.rbac_role_inherits where inherits = p_role order by role);
    if cardinality(heirs) > 0 then
        raise exception 'role ''%'' is inherited by %', p_role,
            (select string_agg(format('%L', h), ', ') from unnest(heirs) h) using errcode = '2BP01',
            hint = format('Drop the roles that inherit it first (%s), or keep %L.',
                          (select string_agg(format('drop_role(%L)', h), ', ') from unnest(heirs) h), p_role);
    end if;
    -- cascades to its permissions, inherits, closure rows and assignments
    delete from permissions.rbac_roles where role = p_role;
end;
$$;

create function permissions.assign_role(p_user_id text, p_role text, p_scope text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    if not exists (select 1 from permissions.rbac_roles where role = p_role) then
        raise exception 'unknown role ''%''', p_role using errcode = '22023',
            hint = permissions._rbac_role_hint(p_role);
    end if;
    if p_user_id is null then
        raise exception 'user_id is required to assign role ''%''', p_role using errcode = '22004',
            hint = format('Pass the user''s id as text, e.g. select permissions.assign_role(user_id::text, %L, scope).', p_role);
    end if;
    insert into permissions.rbac_assignments (user_id, role, scope)
    values (p_user_id, p_role, p_scope)
    on conflict on constraint rbac_assignments_key do nothing;
end;
$$;

create function permissions.unassign_role(p_user_id text, p_role text, p_scope text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    if p_scope is null then
        delete from permissions.rbac_assignments where user_id = p_user_id and role = p_role and scope is null;
    else
        delete from permissions.rbac_assignments where user_id = p_user_id and role = p_role and scope = p_scope;
    end if;
end;
$$;

-- Checks for the current subject. Roles are held by `user` subjects; any other
-- subject type has none. PL/pgSQL so the plans are cached per session
-- (PLAN.md §4); app-wide and scoped lookups are separate statements so each
-- one probes rbac_assignments_key directly.
create function permissions.has_permission(p_permission text, p_scope text default null)
returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
    uid text := permissions.current_subject_id();
begin
    if uid is null or permissions.current_subject_type() <> 'user' then
        return false;
    end if;
    if p_scope is null then
        return exists (
            select 1
            from permissions.rbac_assignments a
            join permissions.rbac_role_closure c on c.role = a.role
            join permissions.rbac_role_permissions p on p.role = c.includes
            where a.user_id = uid and a.scope is null and p.permission = p_permission);
    end if;
    return exists (
        select 1
        from permissions.rbac_assignments a
        join permissions.rbac_role_closure c on c.role = a.role
        join permissions.rbac_role_permissions p on p.role = c.includes
        where a.user_id = uid and a.scope = p_scope and p.permission = p_permission);
end;
$$;

create function permissions.has_role(p_role text, p_scope text default null)
returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
    uid text := permissions.current_subject_id();
begin
    if uid is null or permissions.current_subject_type() <> 'user' then
        return false;
    end if;
    if p_scope is null then
        return exists (
            select 1
            from permissions.rbac_assignments a
            join permissions.rbac_role_closure c on c.role = a.role
            where a.user_id = uid and a.scope is null and c.includes = p_role);
    end if;
    return exists (
        select 1
        from permissions.rbac_assignments a
        join permissions.rbac_role_closure c on c.role = a.role
        where a.user_id = uid and a.scope = p_scope and c.includes = p_role);
end;
$$;

-- The RLS fast path for tenant scoping:
--   org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
-- p_unfold is ignored (see _unfolded_null). Unordered.
create function permissions.scopes_with_permission(p_permission text,
                                                   p_unfold boolean default permissions._unfolded_null())
returns text[]
language plpgsql stable security definer
set search_path = ''
as $$
declare
    uid text := permissions.current_subject_id();
begin
    if uid is null or permissions.current_subject_type() <> 'user' then
        return '{}';
    end if;
    return array(
        select distinct a.scope
        from permissions.rbac_assignments a
        join permissions.rbac_role_closure c on c.role = a.role
        join permissions.rbac_role_permissions p on p.role = c.includes
        where a.user_id = uid and a.scope is not null and p.permission = p_permission);
end;
$$;

-- Admin and debugging (not callable by clients)
create function permissions.user_permissions(p_user_id text, p_scope text default null)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select coalesce(array_agg(distinct p.permission order by p.permission), '{}')
    from permissions.rbac_assignments a
    join permissions.rbac_role_closure c on c.role = a.role
    join permissions.rbac_role_permissions p on p.role = c.includes
    where a.user_id = p_user_id and a.scope is not distinct from p_scope
$$;

create function permissions.users_with_role(p_role text, p_scope text default null)
returns setof text
language sql stable security definer
set search_path = ''
as $$
    select distinct a.user_id
    from permissions.rbac_role_closure c
    join permissions.rbac_assignments a on a.role = c.role
    where c.includes = p_role and a.scope is not distinct from p_scope
$$;

-- ============================================================================
-- OpenFGA: fga_* tables
-- ============================================================================
--
-- One implicit store per database (OpenFGA has many; see the design doc).
-- Authorization models are versioned and immutable: fga_write_authorization_model
-- validates a schema 1.1 JSON model and compiles it into the tables below, so
-- no check ever reads JSON. Tuples don't belong to a model: like OpenFGA, every
-- read filters them through the model in use (its type restrictions), so tuples
-- left over from an earlier model that no longer type-check are ignored.
--
-- Ids, types and relations are collate "C" (PLAN.md §4).

create type permissions.fga_tuple as (
    object_type   text collate "C",
    object_id     text collate "C",
    relation      text collate "C",
    user_type     text collate "C",
    user_id       text collate "C",   -- '*' for a typed wildcard (user:*)
    user_relation text collate "C"    -- '' unless the user is a userset (group:x#member)
);

create table permissions.fga_models (
    id             text collate "C" primary key,   -- ULID, like OpenFGA
    seq            bigint generated always as identity,
    schema_version text not null,
    model          jsonb not null,                   -- as written
    created_at     timestamptz not null default now()
);
create unique index fga_models_seq_idx on permissions.fga_models (seq);

create table permissions.fga_types (
    model_id text collate "C" not null references permissions.fga_models on delete cascade,
    type     text collate "C" not null,
    primary key (model_id, type)
);

create table permissions.fga_relations (
    model_id    text collate "C" not null,
    type        text collate "C" not null,
    relation    text collate "C" not null,
    -- false if the relation uses intersection/difference, or depends on one that does
    monotone    boolean not null default true,
    -- used as the tupleset of a tupleToUserset somewhere in its type
    is_tupleset boolean not null default false,
    -- `base but not subtract` that ListObjects and ListUsers evaluate set-based
    -- (see fga_write_authorization_model): the subtract's computed relation,
    -- and its tupleset for `but not r from ts`. Null otherwise.
    diff_relation text collate "C",
    diff_tupleset text collate "C",
    -- the subtract can recurse or is deep: recheck what it removes with _fga_rec
    diff_recheck  boolean not null default false,
    primary key (model_id, type, relation),
    foreign key (model_id, type) references permissions.fga_types on delete cascade
);

-- directly_related_user_types: [user], [user:*], [group#member]
create table permissions.fga_type_restrictions (
    model_id      text collate "C" not null,
    type          text collate "C" not null,
    relation      text collate "C" not null,
    user_type     text collate "C" not null,
    user_relation text collate "C" not null default '',
    wildcard      boolean not null default false,
    primary key (model_id, type, relation, user_type, user_relation, wildcard),
    foreign key (model_id, type, relation) references permissions.fga_relations on delete cascade
);

-- The rewrite tree of each relation, one row per node, numbered in preorder
-- from 1 (the root). Used by the general evaluator (_fga_rec).
create table permissions.fga_rewrite_nodes (
    model_id text collate "C" not null,
    type     text collate "C" not null,
    relation text collate "C" not null,
    node     int not null,
    parent   int,
    op       text check (op in ('this', 'computed', 'ttu', 'union', 'intersection', 'difference')),  -- null only while validating
    computed text collate "C",    -- computed and ttu: the relation computed
    tupleset text collate "C",    -- ttu: the tupleset relation
    in_subtract boolean not null, -- under the subtract of a difference (not in the positive graph)
    primary key (model_id, type, relation, node),
    foreign key (model_id, type, relation) references permissions.fga_relations on delete cascade
);

-- The positive graph (every rewrite operand except the subtract of a
-- difference), as edges between (type, relation) pairs, for the set-based
-- walks. An edge says: a node (src_type:id#src_relation) leads to dst.
--   d  direct: a tuple on dst_type:x#dst_relation whose user is the source
--      node (src_relation '' for a plain object; src_wildcard for type:*)
--   c  computed: same object, dst_relation computed from src_relation
--   t  tupleToUserset: a tuple dst_type:x#via whose user is the source object,
--      src_relation being the relation computed on it
create table permissions.fga_edges (
    model_id     text collate "C" not null references permissions.fga_models on delete cascade,
    kind         "char" not null check (kind in ('d', 'c', 't')),
    dst_type     text collate "C" not null,
    dst_relation text collate "C" not null,
    src_type     text collate "C" not null,
    src_relation text collate "C" not null,
    src_wildcard boolean not null default false,
    via          text collate "C"
);
create index on permissions.fga_edges (model_id, kind, src_type, src_relation);
create index on permissions.fga_edges (model_id, kind, dst_type, dst_relation);

-- Transitive closure of the `c` edges: on the same object, src_relation leads
-- to dst_relation. The walks apply it in one join.
create table permissions.fga_computed_closure (
    model_id     text collate "C" not null references permissions.fga_models on delete cascade,
    type         text collate "C" not null,
    src_relation text collate "C" not null,
    dst_relation text collate "C" not null,
    primary key (model_id, type, src_relation, dst_relation)
);
create index on permissions.fga_computed_closure (model_id, type, dst_relation);

-- OpenFGA's TypeSystem.PathExists: which user types (user, user:*, group#member)
-- a relation can reach through any operand. A check whose user type has no
-- path is false without reading tuples.
create table permissions.fga_paths (
    model_id      text collate "C" not null references permissions.fga_models on delete cascade,
    type          text collate "C" not null,
    relation      text collate "C" not null,
    user_type     text collate "C" not null,
    user_relation text collate "C" not null,
    wildcard      boolean not null,
    primary key (model_id, type, relation, user_type, user_relation, wildcard)
);

-- Reachability in the positive graph between (type, relation) pairs: a node of
-- (type, relation) leads to target_type#target_relation through d, c and t
-- edges (relation '' is a plain object: the user end). Reflexive for every
-- relation; `strict` when through at least one edge, so a reflexive row with
-- strict true is on a cycle. Used to compile fga_walk_steps and the
-- set-based differences.
create table permissions.fga_reach (
    model_id        text collate "C" not null references permissions.fga_models on delete cascade,
    target_type     text collate "C" not null,
    target_relation text collate "C" not null,
    type            text collate "C" not null,
    relation        text collate "C" not null,
    strict          boolean not null,
    primary key (model_id, target_type, target_relation, type, relation)
);

-- ListObjects' forward walk, compiled per target relation: every d and t edge
-- joined with the computed closure of its destination (so one tuple probe
-- yields every relation the hit implies), kept only if the node it yields can
-- reach the target. A step reads tuples object_type:x#tuple_relation whose
-- user is the source node with user_relation, and yields
-- object_type:x#out_relation. `expand`: that node has steps of its own toward
-- the target (otherwise it is a leaf, or the target itself).
create table permissions.fga_walk_steps (
    model_id        text collate "C" not null references permissions.fga_models on delete cascade,
    target_type     text collate "C" not null,
    target_relation text collate "C" not null,
    kind            "char" not null,   -- d: costs the source node's weight; t: costs 1
    src_type        text collate "C" not null,
    src_relation    text collate "C" not null,
    src_wildcard    boolean not null,
    user_relation   text collate "C" not null,   -- src_relation for d, '' for t
    object_type     text collate "C" not null,
    tuple_relation  text collate "C" not null,   -- dst_relation for d, via for t
    out_relation    text collate "C" not null,
    expand          boolean not null default false
);
create index on permissions.fga_walk_steps (model_id, target_type, target_relation);

create table permissions.fga_tuples (
    object_type   text collate "C" not null,
    object_id     text collate "C" not null,
    relation      text collate "C" not null,
    user_type     text collate "C" not null,
    user_id       text collate "C" not null,
    user_relation text collate "C" not null default '',
    inserted_at   timestamptz not null default now(),
    seq           bigint generated always as identity,  -- insertion order: Read's page order and continuation token
    primary key (object_type, object_id, relation, user_type, user_id, user_relation)
);
create index fga_tuples_user_idx on permissions.fga_tuples (user_type, user_id, user_relation, object_type, relation);
create unique index fga_tuples_seq_idx on permissions.fga_tuples (seq);

-- ----------------------------------------------------------------------------
-- Limits
-- ----------------------------------------------------------------------------
-- OpenFGA's default limits, fixed (OpenFGA makes them configurable; this
-- extension doesn't): ListObjects and ListUsers return at most 1,000 results,
-- truncated silently; Write takes at most 100 tuple keys (writes + deletes);
-- Read pages hold 50 tuples unless page_size (1 to 100) says otherwise. The
-- RLS helpers (fga_list_objects_current, fga_list_object_ids_current) are
-- uncapped: a cap there would silently hide rows.
create function permissions._fga_limits(out list_max int, out write_max int,
                                        out read_page_default int, out read_page_max int)
language sql immutable
as $$
    select 1000, 100, 50, 100
$$;

-- ----------------------------------------------------------------------------
-- Errors
-- ----------------------------------------------------------------------------
-- OpenFGA's numeric error code is in DETAIL as 'openfga:<code> <name>'. The
-- SQLSTATE is 54001 (statement_too_complex) for 2002 and 22023
-- (invalid_parameter_value) for every other code. Features we don't support
-- (conditions) raise 0A000 with DETAIL 'pg_permissions:conditions_not_supported'.
-- The message names the offending values; the hint is required and says how
-- to fix it (test/spec/d/35_error_hints.sql checks every call passes one).
create function permissions._fga_error(p_code int, p_message text, hint text)
returns void
language plpgsql
as $$
begin
    raise exception using
        message = p_message,
        errcode = case p_code when 2002 then '54001' else '22023' end,
        detail = 'openfga:' || p_code || ' ' || case p_code
            when 2000 then 'validation_error'
            when 2001 then 'authorization_model_not_found'
            when 2002 then 'authorization_model_resolution_too_complex'
            when 2003 then 'invalid_write_input'
            when 2004 then 'cannot_allow_duplicate_tuples_in_one_request'
            when 2005 then 'cannot_allow_duplicate_types_in_one_request'
            when 2007 then 'invalid_continuation_token'
            when 2017 then 'write_failed_due_to_invalid_input'
            when 2020 then 'latest_authorization_model_not_found'
            when 2021 then 'type_not_found'
            when 2022 then 'relation_not_found'
            when 2027 then 'invalid_tuple'
            when 2053 then 'exceeded_entity_limit'
            when 2056 then 'invalid_authorization_model'
            when 2057 then 'unsupported_schema_version'
            else 'error' end,
        hint = _fga_error.hint;
end;
$$;

create function permissions._fga_unsupported(p_message text, hint text)
returns void
language plpgsql
as $$
begin
    raise exception using
        message = p_message,
        errcode = '0A000',
        detail = 'pg_permissions:conditions_not_supported',
        hint = _fga_unsupported.hint;
end;
$$;

-- Hints for unknown names: the nearest one and the list (_did_you_mean).
create function permissions._fga_type_hint(p_m text, p_type text)
returns text
language sql stable
as $$
    select coalesce(
        permissions._did_you_mean(coalesce(p_type, ''),
                                  array(select t.type from permissions.fga_types t where t.model_id = p_m),
                                  format('Types in model %s', p_m)),
        format('Model %s defines no types.', p_m))
$$;

create function permissions._fga_relation_hint(p_m text, p_type text, p_rel text)
returns text
language sql stable
as $$
    select coalesce(
        permissions._did_you_mean(coalesce(p_rel, ''),
                                  array(select r.relation from permissions.fga_relations r
                                        where r.model_id = p_m and r.type = p_type),
                                  format('Relations on type ''%s''', p_type)),
        format('Type ''%s'' has no relations in model %s.', p_type, p_m))
$$;

-- The user types a relation's type restrictions allow.
create function permissions._fga_allowed_hint(p_m text, p_type text, p_rel text)
returns text
language sql stable
as $$
    select coalesce(
        (select format('''%s#%s'' allows users of type: %s.', p_type, p_rel,
                       string_agg(tr.user_type || case when tr.wildcard then ':*' else '' end
                                  || case when tr.user_relation <> '' then '#' || tr.user_relation else '' end,
                                  ', ' order by tr.user_type, tr.wildcard, tr.user_relation))
         from permissions.fga_type_restrictions tr
         where tr.model_id = p_m and tr.type = p_type and tr.relation = p_rel
         having count(*) > 0),
        format('''%s#%s'' takes no tuples of its own (no [...] type restrictions): write tuples for the relations it is computed from.',
               p_type, p_rel))
$$;

-- The valid model ids, newest first.
create function permissions._fga_models_hint()
returns text
language sql stable
as $$
    select coalesce(
        (select format('Model ids, newest first: %s%s. Omit authorization_model_id to use the latest.',
                       string_agg(m.id, ', ' order by m.seq desc) filter (where m.rn <= 10),
                       case when count(*) > 10 then format(' and %s more', count(*) - 10) end)
         from (select x.id, x.seq, row_number() over (order by x.seq desc) as rn from permissions.fga_models x) m
         having count(*) > 0),
        'No authorization model exists yet: write one first with select permissions.fga_write_authorization_model(...).')
$$;

-- ----------------------------------------------------------------------------
-- Strings: type:id, type:id#relation, type:* (pkg/tuple/tuple.go)
-- ----------------------------------------------------------------------------

-- 'type:id' (id may be '*'), else null
create function permissions._fga_split_object(p_object text, out object_type text, out object_id text)
language sql immutable
as $$
    select split_part(p_object, ':', 1), substr(p_object, strpos(p_object, ':') + 1)
    where p_object ~ '^[^:# [:cntrl:]]+:[^:# [:cntrl:]]+$'
$$;

-- 'type:id', 'type:*' or 'type:id#relation', else null
create function permissions._fga_split_user(p_user text, out user_type text, out user_id text, out user_relation text)
language sql immutable
as $$
    select split_part(p_user, ':', 1), substr(p_user, strpos(p_user, ':') + 1), ''
    where p_user ~ '^[^:# [:cntrl:]]+:[^:# [:cntrl:]]+$'
    union all
    select split_part(p_user, ':', 1),
           split_part(substr(p_user, strpos(p_user, ':') + 1), '#', 1),
           split_part(p_user, '#', 2)
    where p_user ~ '^[^:# [:cntrl:]]+:[^:#* [:cntrl:]]+#[^:#* [:cntrl:]]+$'
$$;

create function permissions._fga_user_string(p_type text, p_id text, p_relation text)
returns text
language sql immutable
as $$
    select p_type || ':' || p_id || case when p_relation <> '' then '#' || p_relation else '' end
$$;

-- validation.ValidateUser: the user is an object, a wildcard or a userset whose
-- type (and relation) exist. Raises p_code.
create function permissions._fga_parse_user(p_m text, p_user text, p_code int,
                                             out user_type text, out user_id text, out user_relation text)
language plpgsql stable
as $$
begin
    select s.user_type, s.user_id, s.user_relation into user_type, user_id, user_relation
    from permissions._fga_split_user(p_user) s;
    if user_type is null then
        perform permissions._fga_error(p_code, format('invalid ''user'' value: %s: the ''user'' field must be an object (e.g. document:1) or an ''object#relation'' or a typed wildcard (e.g. group:*)', p_user),
            hint => 'Write the user as ''type:id'' (''user:anne''), ''type:*'' (''user:*'') or ''type:id#relation'' (''team:eng#member'').');
    end if;
    if not exists (select 1 from permissions.fga_types t where t.model_id = p_m and t.type = user_type) then
        perform permissions._fga_error(p_code, format('invalid ''user'' value: %s: type ''%s'' not found', p_user, user_type),
            hint => permissions._fga_type_hint(p_m, user_type));
    end if;
    if user_relation <> '' and not exists (
        select 1 from permissions.fga_relations r
        where r.model_id = p_m and r.type = user_type and r.relation = user_relation) then
        perform permissions._fga_error(p_code, format('invalid ''user'' value: %s: relation ''%s#%s'' not found', p_user, user_type, user_relation),
            hint => permissions._fga_relation_hint(p_m, user_type, user_relation));
    end if;
end;
$$;

-- validation.ValidateObject + ValidateRelation. Raises p_code.
create function permissions._fga_parse_object(p_m text, p_object text, p_relation text, p_code int,
                                               out object_type text, out object_id text)
language plpgsql stable
as $$
begin
    -- _fga_split_object, inline (a plain expression, no statement)
    if p_object ~ '^[^:# [:cntrl:]]+:[^:# [:cntrl:]]+$' then
        object_type := split_part(p_object, ':', 1);
        object_id := substr(p_object, strpos(p_object, ':') + 1);
    end if;
    if object_type is null then
        perform permissions._fga_error(p_code, format('invalid ''object'' field format: %s', p_object),
            hint => 'Write the object as ''type:id'', e.g. ''document:1''.');
    end if;
    if object_id = '*' then
        perform permissions._fga_error(p_code, format('the ''object'' field cannot reference a typed wildcard: %s', p_object),
            hint => 'Name one object, ''type:id''. A typed wildcard (''type:*'') is only valid as a user.');
    end if;
    -- the relation exists (so does its type): one probe. Otherwise find which error, in OpenFGA's order.
    if exists (select 1 from permissions.fga_relations r
               where r.model_id = p_m and r.type = object_type and r.relation = p_relation) then
        return;
    end if;
    if not exists (select 1 from permissions.fga_types t where t.model_id = p_m and t.type = object_type) then
        perform permissions._fga_error(p_code, format('type ''%s'' not found', object_type),
            hint => permissions._fga_type_hint(p_m, object_type));
    end if;
    if p_relation is null or p_relation !~ '^[^:#@ [:cntrl:]]+$' then
        perform permissions._fga_error(p_code, format('the ''relation'' field is malformed: %s', p_relation),
            hint => permissions._fga_relation_hint(p_m, object_type, p_relation));
    end if;
    perform permissions._fga_error(p_code, format('relation ''%s#%s'' not found', object_type, p_relation),
        hint => permissions._fga_relation_hint(p_m, object_type, p_relation));
end;
$$;

-- validation.ValidateTupleForWrite: the tuple key is well formed and allowed by
-- the model's type restrictions. Raises p_code (2027 for writes and
-- contextual tuples).
create function permissions._fga_tuple_for_write(p_m text, p_key jsonb, p_code int)
returns permissions.fga_tuple
language plpgsql stable
as $$
declare
    u record;
    o record;
    t permissions.fga_tuple;
    k text := format('%s#%s@%s', p_key ->> 'object', p_key ->> 'relation', p_key ->> 'user');
    h text;
begin
    if jsonb_typeof(p_key) <> 'object' then
        perform permissions._fga_error(p_code, format('invalid tuple key: %s', p_key),
            hint => 'A tuple key is a JSON object: {"user": "user:anne", "relation": "viewer", "object": "document:1"}.');
    end if;
    if p_key ? 'condition' and jsonb_typeof(p_key -> 'condition') <> 'null' then
        perform permissions._fga_unsupported(
            format('relationship condition %s on tuple %L is not supported',
                   coalesce(quote_literal(p_key #>> '{condition,name}'), p_key ->> 'condition'), k),
            hint => 'OpenFGA conditions (CEL) are not implemented yet: write the tuple without "condition".');
    end if;
    begin
        select * into u from permissions._fga_parse_user(p_m, p_key ->> 'user', p_code);
        select * into o from permissions._fga_parse_object(p_m, p_key ->> 'object', p_key ->> 'relation', p_code);
    exception when invalid_parameter_value then
        get stacked diagnostics h = pg_exception_hint;
        perform permissions._fga_error(p_code, format('Invalid tuple ''%s''. Reason: %s', k, sqlerrm), hint => h);
    end;
    t := row(o.object_type, o.object_id, p_key ->> 'relation', u.user_type, u.user_id, u.user_relation);
    if exists (select 1 from permissions.fga_relations r
               where r.model_id = p_m and r.type = t.object_type and r.relation = t.relation and r.is_tupleset)
       and (t.user_id = '*' or t.user_relation <> '') then
        perform permissions._fga_error(p_code, format(
            'Invalid tuple ''%s''. Reason: unexpected %s with tupleset relation ''%s#%s''', k,
            case when t.user_id = '*' then 'wildcard relationship' else format('user ''%s''', p_key ->> 'user') end,
            t.object_type, t.relation),
            hint => format('''%s#%s'' is a tupleset relation (the parent in ''... from %s''): its users are plain objects, ''type:id''. %s',
                           t.object_type, t.relation, t.relation, permissions._fga_allowed_hint(p_m, t.object_type, t.relation)));
    end if;
    if not exists (select 1 from permissions.fga_type_restrictions tr
                   where tr.model_id = p_m and tr.type = t.object_type and tr.relation = t.relation
                     and tr.user_type = t.user_type and tr.user_relation = t.user_relation
                     and tr.wildcard = (t.user_id = '*')) then
        perform permissions._fga_error(p_code, format(
            'Invalid tuple ''%s''. Reason: %s is not an allowed type restriction for ''%s#%s''', k,
            case when t.user_relation <> '' then format('''%s#%s''', t.user_type, t.user_relation)
                 when t.user_id = '*' then format('the typed wildcard ''%s:*''', t.user_type)
                 else format('type ''%s''', t.user_type) end,
            t.object_type, t.relation),
            hint => permissions._fga_allowed_hint(p_m, t.object_type, t.relation));
    end if;
    return t;
end;
$$;

-- Contextual tuples: an array of tuple keys, or {"tuple_keys": [...]}.
-- Validated like writes (2027); duplicates collapse.
create function permissions._fga_ctx(p_m text, p_ctx jsonb)
returns permissions.fga_tuple[]
language plpgsql stable
as $$
begin
    if p_ctx is null or jsonb_typeof(p_ctx) = 'null' then
        return '{}';
    end if;
    if jsonb_typeof(p_ctx) = 'object' and p_ctx ? 'tuple_keys' then
        p_ctx := p_ctx -> 'tuple_keys';
    end if;
    if jsonb_typeof(p_ctx) <> 'array' then
        perform permissions._fga_error(2000, format('contextual_tuples must be an array of tuple keys, got a JSON %s', jsonb_typeof(p_ctx)),
            hint => 'Pass ''[{"user": "user:anne", "relation": "viewer", "object": "document:1"}]'' or ''{"tuple_keys": [...]}''.');
    end if;
    return array(
        select distinct permissions._fga_tuple_for_write(p_m, e, 2027)
        from jsonb_array_elements(p_ctx) e);
end;
$$;

-- The model to use: the given id, or the latest.
create function permissions._fga_model_id(p_id text)
returns text
language plpgsql stable
as $$
declare
    m text;
begin
    if p_id is null then
        select id into m from permissions.fga_models order by seq desc limit 1;
        if m is null then
            perform permissions._fga_error(2020, 'No authorization models found for store',
                hint => 'Write a model first: select permissions.fga_write_authorization_model(''{"schema_version": "1.1", "type_definitions": [...]}'').');
        end if;
        return m;
    end if;
    if not exists (select 1 from permissions.fga_models where id = p_id) then
        perform permissions._fga_error(2001, format('Authorization Model ''%s'' not found', p_id),
            hint => permissions._fga_models_hint());
    end if;
    return p_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- Authorization models
-- ----------------------------------------------------------------------------

-- ULID (OpenFGA's id format): 48-bit millisecond time, 80 random bits,
-- Crockford base32.
create function permissions._fga_ulid()
returns text
language plpgsql volatile
as $$
declare
    alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    ms bigint := floor(extract(epoch from clock_timestamp()) * 1000);
    r bytea := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    bits bit(130);
    s text := '';
begin
    -- bytes 7 and 9 of a v4 uuid carry its version and variant: skip them
    bits := substring(ms::bit(64) from 15 for 50)
         || ('x' || encode(substring(r from 1 for 6) || substring(r from 11 for 6), 'hex'))::bit(96)::bit(80);
    for k in 0..25 loop
        s := s || substr(alphabet, substring(bits from k * 5 + 1 for 5)::int + 1, 1);
    end loop;
    return s;
end;
$$;

-- The types a subtract `p_rel` (or `p_rel from p_ts`) of p_type#... names:
-- p_type itself, or the parent types p_ts allows that define p_rel.
create function permissions._fga_subtract_types(p_m text, p_type text, p_rel text, p_ts text)
returns setof text
language sql stable
as $$
    select p_type where p_ts is null
    union
    select tr.user_type
    from permissions.fga_type_restrictions tr
    join permissions.fga_relations y on y.model_id = p_m and y.type = tr.user_type and y.relation = p_rel
    where p_ts is not null and tr.model_id = p_m and tr.type = p_type and tr.relation = p_ts
      and tr.user_relation = '' and not tr.wildcard
$$;

-- Validate a schema 1.1 JSON AuthorizationModel ({schema_version,
-- type_definitions}, as `fga model transform` or the OpenFGA API produce) and
-- compile it. Returns the new model id; it becomes the latest model.
-- Raises openfga:2056 (invalid_authorization_model) or 2057 (schema version);
-- conditions raise 0A000.
create function permissions.fga_write_authorization_model(model jsonb)
returns text
language plpgsql security definer
set search_path = ''
as $$
declare
    m text;
    tds jsonb;
    bad text;
    bad_type text;
    h text;
begin
    if jsonb_typeof(model) <> 'object' then
        perform permissions._fga_error(2056, format('the authorization model must be a JSON object, got a JSON %s', jsonb_typeof(model)),
            hint => 'Pass the WriteAuthorizationModel body, {"schema_version": "1.1", "type_definitions": [...]}, as ''fga model transform --output-format json'' prints it.');
    end if;
    if coalesce(model ->> 'schema_version', '') <> '1.1' then
        perform permissions._fga_error(2057, format('unsupported schema version %s: only 1.1 is supported',
                                                    coalesce(model ->> 'schema_version', '(none)')),
            hint => 'Set "schema_version": "1.1" (in the DSL, ''schema 1.1'').');
    end if;
    if jsonb_typeof(model -> 'conditions') = 'object' and model -> 'conditions' <> '{}' then
        perform permissions._fga_unsupported(
            format('conditions are not supported: the model defines %s',
                   (select string_agg(format('condition %L', c), ', ' order by c) from jsonb_object_keys(model -> 'conditions') c)),
            hint => 'OpenFGA conditions (CEL) are not implemented yet: remove "conditions" and the conditions on type restrictions.');
    end if;
    tds := model -> 'type_definitions';
    if jsonb_typeof(tds) is distinct from 'array' or jsonb_array_length(tds) = 0 then
        perform permissions._fga_error(2056, format('type_definitions must be a non-empty array, got %s', coalesce(tds::text, 'nothing')),
            hint => 'List at least one type, e.g. "type_definitions": [{"type": "user"}].');
    end if;

    -- types
    select coalesce(td ->> 'type', '(missing)') into bad from jsonb_array_elements(tds) td
    where jsonb_typeof(td) <> 'object' or coalesce(td ->> 'type', '') !~ '^[^:#@[:space:]]{1,254}$' limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format('invalid type name ''%s''', bad),
            hint => 'Each type definition is an object {"type": "document", ...}. A type name is 1 to 254 characters with no '':'', ''#'', ''@'' or whitespace.');
    end if;
    select td ->> 'type' into bad from jsonb_array_elements(tds) td group by 1 having count(*) > 1 limit 1;
    if bad is not null then
        perform permissions._fga_error(2005, format('the type ''%s'' is defined more than once', bad),
            hint => format('Define each type once: merge the relations of every %L definition into one.', bad));
    end if;
    select format('%s#%s', td ->> 'type', r.key) into bad
    from jsonb_array_elements(tds) td
    cross join jsonb_each(case when jsonb_typeof(td -> 'relations') = 'object' then td -> 'relations' else '{}' end) r
    where r.key !~ '^[^:#@[:space:]]{1,50}$' or r.key in ('self', 'this') limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format('invalid relation name ''%s''', bad),
            hint => 'A relation name is 1 to 50 characters with no '':'', ''#'', ''@'' or whitespace, and not ''self'' or ''this''.');
    end if;

    m := permissions._fga_ulid();
    insert into permissions.fga_models (id, schema_version, model)
    values (m, '1.1', jsonb_build_object('schema_version', '1.1', 'type_definitions', tds));
    insert into permissions.fga_types (model_id, type)
    select m, td ->> 'type' from jsonb_array_elements(tds) td;
    insert into permissions.fga_relations (model_id, type, relation)
    select m, td ->> 'type', r.key
    from jsonb_array_elements(tds) td
    cross join jsonb_each(case when jsonb_typeof(td -> 'relations') = 'object' then td -> 'relations' else '{}' end) r;

    -- metadata for relations that don't exist
    select td ->> 'type', r.key into bad_type, bad
    from jsonb_array_elements(tds) td
    cross join jsonb_each(case when jsonb_typeof(td #> '{metadata,relations}') = 'object'
                               then td #> '{metadata,relations}' else '{}' end) r
    where not exists (select 1 from permissions.fga_relations x
                      where x.model_id = m and x.type = td ->> 'type' and x.relation = r.key) limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format('metadata for undefined relation ''%s#%s''', bad_type, bad),
            hint => format('%s Add the relation under the type''s "relations", or remove its metadata.',
                           permissions._fga_relation_hint(m, bad_type, bad)));
    end if;

    -- type restrictions
    select format('%L allows %L with condition %L', (td ->> 'type') || '#' || r.key,
                  (u ->> 'type') || coalesce('#' || (u ->> 'relation'), ''), u ->> 'condition') into bad
    from jsonb_array_elements(tds) td
    cross join jsonb_each(case when jsonb_typeof(td #> '{metadata,relations}') = 'object'
                               then td #> '{metadata,relations}' else '{}' end) r
    cross join jsonb_array_elements(case when jsonb_typeof(r.value -> 'directly_related_user_types') = 'array'
                                         then r.value -> 'directly_related_user_types' else '[]' end) u
    where coalesce(u ->> 'condition', '') <> '' limit 1;
    if bad is not null then
        perform permissions._fga_unsupported(format('conditions on type restrictions are not supported: %s', bad),
            hint => 'OpenFGA conditions (CEL) are not implemented yet: remove "conditions" and the conditions on type restrictions.');
    end if;
    insert into permissions.fga_type_restrictions (model_id, type, relation, user_type, user_relation, wildcard)
    select distinct m, td ->> 'type', r.key, u ->> 'type', coalesce(u ->> 'relation', ''), u ? 'wildcard'
    from jsonb_array_elements(tds) td
    cross join jsonb_each(case when jsonb_typeof(td #> '{metadata,relations}') = 'object'
                               then td #> '{metadata,relations}' else '{}' end) r
    cross join jsonb_array_elements(case when jsonb_typeof(r.value -> 'directly_related_user_types') = 'array'
                                         then r.value -> 'directly_related_user_types' else '[]' end) u;
    select format('%s#%s allows %s', tr.type, tr.relation,
                  tr.user_type || case when tr.wildcard then ':*' else '' end
                  || case when tr.user_relation <> '' then '#' || tr.user_relation else '' end),
           case when tr.user_type is null then 'Each entry of directly_related_user_types needs a "type".'
                when not exists (select 1 from permissions.fga_types t where t.model_id = m and t.type = tr.user_type)
                then permissions._fga_type_hint(m, tr.user_type)
                when tr.wildcard and tr.user_relation <> ''
                then 'A wildcard restriction is {"type": "user", "wildcard": {}}, with no relation.'
                else permissions._fga_relation_hint(m, tr.user_type, tr.user_relation) end
    into bad, h
    from permissions.fga_type_restrictions tr
    where tr.model_id = m
      and (tr.user_type is null
           or not exists (select 1 from permissions.fga_types t where t.model_id = m and t.type = tr.user_type)
           or (tr.user_relation <> '' and not exists (
                  select 1 from permissions.fga_relations x
                  where x.model_id = m and x.type = tr.user_type and x.relation = tr.user_relation))
           or (tr.wildcard and tr.user_relation <> ''))
    limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format('invalid type restriction: %s (undefined type or relation)', bad), hint => h);
    end if;

    -- rewrites, flattened in preorder
    with recursive n(type, relation, path, rw, in_sub) as (
        select td ->> 'type', r.key, array[]::int[], r.value, false
        from jsonb_array_elements(tds) td
        cross join jsonb_each(case when jsonb_typeof(td -> 'relations') = 'object' then td -> 'relations' else '{}' end) r
      union all
        select n.type, n.relation, n.path || c.pos, c.rw, n.in_sub or c.sub
        from n
        cross join lateral (
            select (x.o - 1)::int, x.v, false
            from jsonb_array_elements(case when jsonb_typeof(n.rw #> '{union,child}') = 'array'
                                           then n.rw #> '{union,child}' else '[]' end) with ordinality x(v, o)
          union all
            select (x.o - 1)::int, x.v, false
            from jsonb_array_elements(case when jsonb_typeof(n.rw #> '{intersection,child}') = 'array'
                                           then n.rw #> '{intersection,child}' else '[]' end) with ordinality x(v, o)
          union all
            select 0, n.rw #> '{difference,base}', false where n.rw #> '{difference,base}' is not null
          union all
            select 1, n.rw #> '{difference,subtract}', true where n.rw #> '{difference,subtract}' is not null
        ) c(pos, rw, sub)
        where jsonb_typeof(n.rw) = 'object' and cardinality(n.path) < 50
    ),
    k as (
        select n.*,
               row_number() over (partition by n.type, n.relation order by n.path)::int as node,
               case when jsonb_typeof(n.rw) <> 'object' then null
                    when (select count(*) from jsonb_object_keys(n.rw)) <> 1 then null
                    when n.rw ? 'this' then 'this'
                    when n.rw ? 'computedUserset' then 'computed'
                    when n.rw ? 'tupleToUserset' then 'ttu'
                    when n.rw ? 'union' then 'union'
                    when n.rw ? 'intersection' then 'intersection'
                    when n.rw ? 'difference' then 'difference' end as op
        from n
    )
    insert into permissions.fga_rewrite_nodes (model_id, type, relation, node, parent, op, computed, tupleset, in_subtract)
    select m, k.type, k.relation, k.node, p.node,
           k.op,
           coalesce(k.rw #>> '{computedUserset,relation}', k.rw #>> '{tupleToUserset,computedUserset,relation}'),
           k.rw #>> '{tupleToUserset,tupleset,relation}',
           k.in_sub
    from k
    left join k p on p.type = k.type and p.relation = k.relation and p.path = k.path[1:cardinality(k.path) - 1]
                 and cardinality(k.path) > 0;

    select format('%s#%s', n.type, n.relation) into bad
    from permissions.fga_rewrite_nodes n
    where n.model_id = m
      and (n.op is null
           or (n.op in ('union', 'intersection') and not exists (
                  select 1 from permissions.fga_rewrite_nodes c
                  where c.model_id = m and c.type = n.type and c.relation = n.relation and c.parent = n.node))
           or (n.op = 'difference' and (select count(*) from permissions.fga_rewrite_nodes c
                                        where c.model_id = m and c.type = n.type and c.relation = n.relation
                                          and c.parent = n.node) <> 2))
    limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format('invalid rewrite for relation ''%s''', bad),
            hint => 'A rewrite is one of this, computedUserset, tupleToUserset, union, intersection or difference. union and intersection need at least one child, difference a base and a subtract.');
    end if;
    select format('%s#%s: computed relation ''%s'' is not defined on type ''%s''', n.type, n.relation, n.computed, n.type),
           permissions._fga_relation_hint(m, n.type, n.computed)
    into bad, h
    from permissions.fga_rewrite_nodes n
    where n.model_id = m and n.op = 'computed'
      and not exists (select 1 from permissions.fga_relations r
                      where r.model_id = m and r.type = n.type and r.relation = n.computed)
    limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, bad, hint => h);
    end if;
    select format('%s#%s: tupleset ''%s'' %s', n.type, n.relation, n.tupleset,
                  case when not exists (select 1 from permissions.fga_relations r
                                        where r.model_id = m and r.type = n.type and r.relation = n.tupleset)
                       then 'is not defined'
                       when exists (select 1 from permissions.fga_rewrite_nodes x
                                    where x.model_id = m and x.type = n.type and x.relation = n.tupleset
                                      and (x.node > 1 or x.op <> 'this'))
                       then 'must be a direct relation ([type, ...] only)'
                       when exists (select 1 from permissions.fga_type_restrictions tr
                                    where tr.model_id = m and tr.type = n.type and tr.relation = n.tupleset
                                      and (tr.wildcard or tr.user_relation <> ''))
                       then 'can''t allow wildcards or usersets'
                       else format('has no type defining ''%s''', n.computed) end),
           case when not exists (select 1 from permissions.fga_relations r
                                 where r.model_id = m and r.type = n.type and r.relation = n.tupleset)
                then permissions._fga_relation_hint(m, n.type, n.tupleset)
                else format('In ''%s from %s'', %s must be a direct relation of type %s whose users are plain objects ([folder], no wildcards or usersets), and %s a relation of at least one of those types.',
                            n.computed, n.tupleset, n.tupleset, n.type, n.computed) end
    into bad, h
    from permissions.fga_rewrite_nodes n
    where n.model_id = m and n.op = 'ttu'
      and (n.tupleset is null or n.computed is null
           or not exists (select 1 from permissions.fga_relations r
                          where r.model_id = m and r.type = n.type and r.relation = n.tupleset)
           or exists (select 1 from permissions.fga_rewrite_nodes x
                      where x.model_id = m and x.type = n.type and x.relation = n.tupleset
                        and (x.node > 1 or x.op <> 'this'))
           or exists (select 1 from permissions.fga_type_restrictions tr
                      where tr.model_id = m and tr.type = n.type and tr.relation = n.tupleset
                        and (tr.wildcard or tr.user_relation <> ''))
           or not exists (select 1 from permissions.fga_type_restrictions tr
                          join permissions.fga_relations r
                            on r.model_id = m and r.type = tr.user_type and r.relation = n.computed
                          where tr.model_id = m and tr.type = n.type and tr.relation = n.tupleset))
    limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, bad, hint => h);
    end if;
    select format('%s#%s', r.type, r.relation) into bad
    from permissions.fga_relations r
    where r.model_id = m
      and exists (select 1 from permissions.fga_rewrite_nodes n
                  where n.model_id = m and n.type = r.type and n.relation = r.relation and n.op = 'this')
       <> exists (select 1 from permissions.fga_type_restrictions tr
                  where tr.model_id = m and tr.type = r.type and tr.relation = r.relation)
    limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format(
            'relation ''%s'': a direct relation ([...]) needs type restrictions, and only a direct relation can have them', bad),
            hint => 'Give a relation with {"this": {}} its "directly_related_user_types" under metadata.relations, and remove them from a relation without it.');
    end if;

    -- compile
    update permissions.fga_relations r set is_tupleset = true
    where r.model_id = m
      and exists (select 1 from permissions.fga_rewrite_nodes n
                  where n.model_id = m and n.type = r.type and n.op = 'ttu' and n.tupleset = r.relation);

    insert into permissions.fga_edges (model_id, kind, dst_type, dst_relation, src_type, src_relation, src_wildcard, via)
    select distinct m, 'd', n.type, n.relation, tr.user_type, tr.user_relation, tr.wildcard, null::text
    from permissions.fga_rewrite_nodes n
    join permissions.fga_type_restrictions tr on tr.model_id = m and tr.type = n.type and tr.relation = n.relation
    where n.model_id = m and n.op = 'this' and not n.in_subtract
    union
    select m, 'c', n.type, n.relation, n.type, n.computed, false, null
    from permissions.fga_rewrite_nodes n
    where n.model_id = m and n.op = 'computed' and not n.in_subtract
    union
    select m, 't', n.type, n.relation, tr.user_type, n.computed, false, n.tupleset
    from permissions.fga_rewrite_nodes n
    join permissions.fga_type_restrictions tr on tr.model_id = m and tr.type = n.type and tr.relation = n.tupleset
    join permissions.fga_relations r on r.model_id = m and r.type = tr.user_type and r.relation = n.computed
    where n.model_id = m and n.op = 'ttu' and not n.in_subtract;

    insert into permissions.fga_computed_closure (model_id, type, src_relation, dst_relation)
    with recursive cl(type, src, dst) as (
        select e.dst_type, e.src_relation, e.dst_relation
        from permissions.fga_edges e where e.model_id = m and e.kind = 'c'
      union
        select cl.type, cl.src, e.dst_relation
        from cl join permissions.fga_edges e
          on e.model_id = m and e.kind = 'c' and e.dst_type = cl.type and e.src_relation = cl.dst
    )
    select m, type, src, dst from cl where src <> dst;

    -- PathExists: every operand counts, subtracts included
    insert into permissions.fga_paths (model_id, type, relation, user_type, user_relation, wildcard)
    with recursive dep(type, relation, user_type, user_relation, wildcard) as (
        select n.type, n.relation, tr.user_type, tr.user_relation, tr.wildcard
        from permissions.fga_rewrite_nodes n
        join permissions.fga_type_restrictions tr on tr.model_id = m and tr.type = n.type and tr.relation = n.relation
        where n.model_id = m and n.op = 'this'
      union
        select n.type, n.relation, n.type, n.computed, false
        from permissions.fga_rewrite_nodes n
        where n.model_id = m and n.op = 'computed'
      union
        select n.type, n.relation, tr.user_type, n.computed, false
        from permissions.fga_rewrite_nodes n
        join permissions.fga_type_restrictions tr on tr.model_id = m and tr.type = n.type and tr.relation = n.tupleset
        join permissions.fga_relations r on r.model_id = m and r.type = tr.user_type and r.relation = n.computed
        where n.model_id = m and n.op = 'ttu'
    ),
    reach(type, relation, user_type, user_relation, wildcard) as (
        select r.type, r.relation, r.type, r.relation, false
        from permissions.fga_relations r where r.model_id = m
      union
        select reach.type, reach.relation, d.user_type, d.user_relation, d.wildcard
        from reach
        join dep d on d.type = reach.user_type and d.relation = reach.user_relation
        where reach.user_relation <> '' and not reach.wildcard
    )
    select m, * from reach;

    update permissions.fga_relations r set monotone = false
    where r.model_id = m
      and exists (select 1
                  from permissions.fga_paths p
                  join permissions.fga_rewrite_nodes n
                    on n.model_id = m and n.type = p.user_type and n.relation = p.user_relation
                   and n.op in ('intersection', 'difference')
                  where p.model_id = m and p.type = r.type and p.relation = r.relation);

    -- reachability between (type, relation) pairs in the positive graph
    insert into permissions.fga_reach (model_id, target_type, target_relation, type, relation, strict)
    with recursive g(st, sr, dt, dr) as (
        select distinct e.src_type, e.src_relation, e.dst_type, e.dst_relation
        from permissions.fga_edges e where e.model_id = m
    ),
    rc(type, relation, target_type, target_relation) as (
        select x.type, x.relation, x.type, x.relation from permissions.fga_relations x where x.model_id = m
      union
        select g.st, g.sr, rc.target_type, rc.target_relation
        from rc join g on g.dt = rc.type and g.dr = rc.relation
    )
    select m, rc.target_type, rc.target_relation, rc.type, rc.relation,
           exists (select 1 from g join rc r2
                     on r2.type = g.dt and r2.relation = g.dr
                    and r2.target_type = rc.target_type and r2.target_relation = rc.target_relation
                   where g.st = rc.type and g.sr = rc.relation)
    from rc;

    -- the forward walk's steps per target (pruned to nodes that reach it)
    insert into permissions.fga_walk_steps (model_id, target_type, target_relation, kind, src_type, src_relation,
                                            src_wildcard, user_relation, object_type, tuple_relation, out_relation)
    select distinct m, rc.target_type, rc.target_relation, e.kind, e.src_type, e.src_relation, e.src_wildcard,
           case e.kind when 'd' then e.src_relation else '' end,
           e.dst_type, case e.kind when 'd' then e.dst_relation else e.via end, o.out_relation
    from permissions.fga_edges e
    cross join lateral (
        select e.dst_relation
      union
        select cc.dst_relation from permissions.fga_computed_closure cc
        where cc.model_id = m and cc.type = e.dst_type and cc.src_relation = e.dst_relation
    ) o(out_relation)
    join permissions.fga_reach rc on rc.model_id = m and rc.type = e.dst_type and rc.relation = o.out_relation
    where e.model_id = m and e.kind in ('d', 't');
    update permissions.fga_walk_steps w set expand = true
    where w.model_id = m
      and exists (select 1 from permissions.fga_walk_steps x
                  where x.model_id = m and x.target_type = w.target_type and x.target_relation = w.target_relation
                    and x.src_type = w.object_type and x.src_relation = w.out_relation and not x.src_wildcard);

    -- Set-based differences: `base but not subtract` where
    --   - the base is a positive expression (no `and`, no nested `but not`)
    --     over monotone relations, the relation itself not among them, so the
    --     positive walk to the relation is exactly the base;
    --   - the subtract is `r` or `r from ts`, with r monotone on every type it
    --     names. _fga_rec evaluates a monotone relation by the bidirectional
    --     search, under a subtract too, so the subtract is true for an object
    --     exactly when the subtract's own walk reaches it.
    -- ListObjects and ListUsers compute base minus subtract with two walks;
    -- Check and every other non-monotone relation keep _fga_rec. The one
    -- thing a walk doesn't settle is the depth limit on the subtract: if r can
    -- recurse (a relation it depends on is on a cycle) or depends on as many
    -- relations as the limit (plus one for `from`), diff_recheck is set and
    -- the objects (users) the subtract removes are checked one by one with
    -- _fga_rec. Otherwise no evaluation of the subtract can reach depth 25.
    update permissions.fga_relations r set diff_relation = s.computed, diff_tupleset = s.tupleset
    from permissions.fga_rewrite_nodes root
    join permissions.fga_rewrite_nodes s
      on s.model_id = m and s.type = root.type and s.relation = root.relation and s.parent = 1 and s.in_subtract
    where root.model_id = m and root.node = 1 and root.op = 'difference'
      and r.model_id = m and r.type = root.type and r.relation = root.relation
      and s.op in ('computed', 'ttu')
      and not exists (select 1 from permissions.fga_rewrite_nodes x
                      where x.model_id = m and x.type = r.type and x.relation = r.relation
                        and x.node > 1 and x.op in ('intersection', 'difference'))
      and not exists (select 1 from permissions.fga_reach rc
                      join permissions.fga_relations x on x.model_id = m and x.type = rc.type and x.relation = rc.relation
                      where rc.model_id = m and rc.target_type = r.type and rc.target_relation = r.relation
                        and ((x.type, x.relation) <> (r.type, r.relation) and not x.monotone
                             or (x.type, x.relation) = (r.type, r.relation) and rc.strict))
      and not exists (
          select 1
          from permissions._fga_subtract_types(m, r.type, s.computed, s.tupleset) st
          join permissions.fga_relations y on y.model_id = m and y.type = st and y.relation = s.computed
          where not y.monotone);
    update permissions.fga_relations r set diff_recheck = true
    where r.model_id = m and r.diff_relation is not null
      and exists (
          select 1
          from permissions._fga_subtract_types(m, r.type, r.diff_relation, r.diff_tupleset) st
          where exists (select 1 from permissions.fga_reach rc
                        join permissions.fga_reach cyc
                          on cyc.model_id = m and cyc.target_type = rc.type and cyc.target_relation = rc.relation
                         and cyc.type = rc.type and cyc.relation = rc.relation and cyc.strict
                        where rc.model_id = m and rc.target_type = st and rc.target_relation = r.diff_relation)
             or (select count(*) from permissions.fga_reach rc
                 where rc.model_id = m and rc.target_type = st and rc.target_relation = r.diff_relation
                   and rc.relation <> '') + (r.diff_tupleset is not null)::int > 24);
    return m;
end;
$$;

create function permissions.fga_read_authorization_model(authorization_model_id text default null)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
    m text := permissions._fga_model_id(authorization_model_id);
begin
    return (select jsonb_build_object('id', id) || model from permissions.fga_models where id = m);
end;
$$;

create function permissions.fga_read_authorization_models()
returns table (id text, created_at timestamptz)
language sql stable security definer
set search_path = ''
as $$
    select m.id, m.created_at from permissions.fga_models m order by m.seq desc
$$;

-- OpenFGA's DeleteStore for the one implicit store: every model and tuple.
create function permissions.fga_delete_store()
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    delete from permissions.fga_tuples;
    delete from permissions.fga_models;
end;
$$;

-- ----------------------------------------------------------------------------
-- Tuples
-- ----------------------------------------------------------------------------

-- OpenFGA Write: writes and deletes in one transaction. Each is an array of
-- tuple keys ({user, relation, object}) or {"tuple_keys": [...]} with
-- "on_duplicate": "ignore" (writes) or "on_missing": "ignore" (deletes).
-- Writes are validated against the model (latest unless given): 2027. Writing
-- a tuple that exists or deleting one that doesn't is 2017 unless ignored.
-- Deletes only need to be well formed (2000 otherwise), so tuples a newer
-- model no longer allows can still be removed. Limits, as OpenFGA: a list that
-- is given must not be empty (2000), at least one must be given (2003), the
-- same tuple twice is 2004, and more than 100 tuple keys (writes + deletes)
-- is 2053 exceeded_entity_limit, checked after the duplicates.
create function permissions.fga_write(writes jsonb default null, deletes jsonb default null,
                                      authorization_model_id text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    m text;
    w permissions.fga_tuple[];
    d permissions.fga_tuple[];
    done permissions.fga_tuple[];
    w_given boolean := coalesce(jsonb_typeof(writes), 'null') <> 'null';
    d_given boolean := coalesce(jsonb_typeof(deletes), 'null') <> 'null';
    w_ignore boolean := false;
    d_ignore boolean := false;
    lim int := (select l.write_max from permissions._fga_limits() l);
    bad text;
begin
    if jsonb_typeof(writes) = 'object' then
        w_ignore := coalesce(writes ->> 'on_duplicate', 'error') = 'ignore';
        if coalesce(writes ->> 'on_duplicate', 'error') not in ('error', 'ignore') then
            perform permissions._fga_error(2000, format('invalid on_duplicate option: %s', writes ->> 'on_duplicate'),
                hint => 'on_duplicate is ''error'' (the default) or ''ignore''.');
        end if;
        writes := coalesce(writes -> 'tuple_keys', '[]');
    end if;
    if jsonb_typeof(deletes) = 'object' then
        d_ignore := coalesce(deletes ->> 'on_missing', 'error') = 'ignore';
        if coalesce(deletes ->> 'on_missing', 'error') not in ('error', 'ignore') then
            perform permissions._fga_error(2000, format('invalid on_missing option: %s', deletes ->> 'on_missing'),
                hint => 'on_missing is ''error'' (the default) or ''ignore''.');
        end if;
        deletes := coalesce(deletes -> 'tuple_keys', '[]');
    end if;
    if coalesce(jsonb_typeof(writes), 'null') not in ('array', 'null') or coalesce(jsonb_typeof(deletes), 'null') not in ('array', 'null') then
        perform permissions._fga_error(2000, format('writes and deletes must be arrays of tuple keys, got writes: %s, deletes: %s',
                                                    coalesce(jsonb_typeof(writes), 'null'), coalesce(jsonb_typeof(deletes), 'null')),
            hint => 'Pass an array of tuple keys or {"tuple_keys": [...]}, e.g. ''[{"user": "user:anne", "relation": "viewer", "object": "document:1"}]''.');
    end if;
    -- a list that is given must not be empty (OpenFGA: tuple_keys min_items 1)
    if (w_given and jsonb_array_length(writes) = 0) or (d_given and jsonb_array_length(deletes) = 0) then
        bad := case when w_given and jsonb_array_length(writes) = 0 then 'writes' else 'deletes' end;
        perform permissions._fga_error(2000, format('%s must contain at least 1 tuple key, got an empty list', bad),
            hint => format('Leave %s null (omit it) when there is nothing to %s.', bad, case bad when 'writes' then 'write' else 'delete' end));
    end if;
    if not w_given and not d_given then
        perform permissions._fga_error(2003, 'Invalid input. Make sure you provide at least one write, or at least one delete',
            hint => 'Pass writes, deletes or both, e.g. select permissions.fga_write(''[{"user": "user:anne", "relation": "viewer", "object": "document:1"}]'').');
    end if;
    m := permissions._fga_model_id(authorization_model_id);

    w := array(select permissions._fga_tuple_for_write(m, e, 2027)
               from jsonb_array_elements(coalesce(writes, '[]')) with ordinality x(e, o) order by o);
    d := array(
        select row(o.object_type, o.object_id, e ->> 'relation', u.user_type, u.user_id, u.user_relation)::permissions.fga_tuple
        from jsonb_array_elements(coalesce(deletes, '[]')) with ordinality x(e, i)
        left join lateral permissions._fga_split_object(e ->> 'object') o on true
        left join lateral permissions._fga_split_user(e ->> 'user') u on true
        order by i);
    select format('%s#%s@%s', e ->> 'object', e ->> 'relation', e ->> 'user') into bad
    from jsonb_array_elements(coalesce(deletes, '[]')) e
    where (permissions._fga_split_object(e ->> 'object')).object_type is null
       or (permissions._fga_split_user(e ->> 'user')).user_type is null
       or coalesce(e ->> 'relation', '') !~ '^[^:#@ [:cntrl:]]+$'
    limit 1;
    if bad is not null then
        perform permissions._fga_error(2000, format('Invalid tuple ''%s'' in deletes: malformed', bad),
            hint => 'A delete key needs a ''user'' (''type:id'', ''type:*'' or ''type:id#relation''), a ''relation'' and an ''object'' (''type:id'').');
    end if;
    select format('%s:%s#%s@%s', t.object_type, t.object_id, t.relation,
                  permissions._fga_user_string(t.user_type, t.user_id, t.user_relation)) into bad
    from unnest(w || d) t
    group by t.object_type, t.object_id, t.relation, t.user_type, t.user_id, t.user_relation
    having count(*) > 1 limit 1;
    if bad is not null then
        perform permissions._fga_error(2004, format('duplicate tuple in write or delete: %s', bad),
            hint => 'Send each tuple key once per request, in writes or in deletes.');
    end if;
    -- the cap counts writes and deletes together, after the duplicate check (OpenFGA's order)
    if cardinality(w) + cardinality(d) > lim then
        perform permissions._fga_error(2053, format(
            'The number of write operations exceeds the allowed limit of %s: got %s tuple keys (%s writes, %s deletes)',
            lim, cardinality(w) + cardinality(d), cardinality(w), cardinality(d)),
            hint => format('Split the tuple keys into batches of at most %s and call fga_write once per batch: calls in one transaction commit or roll back together.', lim));
    end if;

    with del as (
        delete from permissions.fga_tuples x
        using unnest(d) t
        where x.object_type = t.object_type and x.object_id = t.object_id and x.relation = t.relation
          and x.user_type = t.user_type and x.user_id = t.user_id and x.user_relation = t.user_relation
        returning row(x.object_type, x.object_id, x.relation, x.user_type, x.user_id, x.user_relation)::permissions.fga_tuple as k)
    select coalesce(array_agg(k), '{}') into done from del;
    if cardinality(done) < cardinality(d) and not d_ignore then
        select format('%s:%s#%s@%s', t.object_type, t.object_id, t.relation,
                      permissions._fga_user_string(t.user_type, t.user_id, t.user_relation)) into bad
        from unnest(d) t where not (t = any (done)) limit 1;
        perform permissions._fga_error(2017, format('cannot delete a tuple which does not exist: %s', bad),
            hint => 'Pass deletes as {"tuple_keys": [...], "on_missing": "ignore"} to skip tuples that are already gone.');
    end if;
    with ins as (
        insert into permissions.fga_tuples (object_type, object_id, relation, user_type, user_id, user_relation)
        select t.object_type, t.object_id, t.relation, t.user_type, t.user_id, t.user_relation from unnest(w) t
        on conflict do nothing
        returning row(object_type, object_id, relation, user_type, user_id, user_relation)::permissions.fga_tuple as k)
    select coalesce(array_agg(k), '{}') into done from ins;
    if cardinality(done) < cardinality(w) and not w_ignore then
        select format('%s:%s#%s@%s', t.object_type, t.object_id, t.relation,
                      permissions._fga_user_string(t.user_type, t.user_id, t.user_relation)) into bad
        from unnest(w) t where not (t = any (done)) limit 1;
        perform permissions._fga_error(2017, format('cannot write a tuple which already exists: %s', bad),
            hint => 'Pass writes as {"tuple_keys": [...], "on_duplicate": "ignore"} to skip tuples that already exist.');
    end if;
end;
$$;

-- Convenience: one tuple, OpenFGA strings. Idempotent (on_duplicate/on_missing ignore).
create function permissions.fga_write_tuple("user" text, relation text, object text)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    perform permissions.fga_write(
        jsonb_build_object('tuple_keys', jsonb_build_array(jsonb_build_object('user', "user", 'relation', relation, 'object', object)),
                           'on_duplicate', 'ignore'));
end;
$$;

create function permissions.fga_delete_tuple("user" text, relation text, object text)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    perform permissions.fga_write(deletes => jsonb_build_object(
        'tuple_keys', jsonb_build_array(jsonb_build_object('user', "user", 'relation', relation, 'object', object)),
        'on_missing', 'ignore'));
end;
$$;

-- OpenFGA Read: one page of the stored tuples matching a partial key, in
-- insertion order (fga_tuples.seq). object is 'type:id' or 'type:' (every
-- object of the type); user is 'type:id', 'type:*' or 'type:id#relation'. Not
-- filtered by the model. Returns OpenFGA's ReadResponse as one row: tuples, a
-- JSON array of {"key": {"user", "relation", "object"}, "timestamp"}, and
-- continuation_token, '' on the last page. Pass the token back unchanged for
-- the next page. page_size: default 50, 1 to 100 (2000 otherwise). The token
-- is base64url (padded) of '<seq>|', seq being the first tuple of the next
-- page (OpenFGA: '<ulid>|'), found by reading page_size + 1 rows. A token
-- outside the base64url alphabet or over 5,120 bytes is 2000; one that
-- doesn't decode to that shape is 2007. A token whose tuple was deleted since
-- seeks past it.
create function permissions.fga_read(p_object text default null, p_relation text default null, p_user text default null,
                                     p_page_size int default null, p_continuation_token text default null,
                                     out tuples jsonb, out continuation_token text)
language plpgsql stable security definer
set search_path = ''
as $$
declare
    l record;
    n int;
    from_seq bigint := 0;
    raw text;
    nxt bigint;
begin
    select * into l from permissions._fga_limits();
    n := coalesce(p_page_size, l.read_page_default);
    if n not between 1 and l.read_page_max then
        perform permissions._fga_error(2000, format('invalid ReadRequest.PageSize: value must be inside range [1, %s], got %s',
                                                    l.read_page_max, n),
            hint => format('Omit page_size for the default of %s, or pass 1 to %s.', l.read_page_default, l.read_page_max));
    end if;
    if coalesce(p_continuation_token, '') <> '' then
        if octet_length(p_continuation_token) > 5120 or p_continuation_token !~ '^[A-Za-z0-9_-]+={0,2}$' then
            perform permissions._fga_error(2000, case when octet_length(p_continuation_token) > 5120
                then format('invalid ReadRequest.ContinuationToken: value length must be at most 5120 bytes, got %s', octet_length(p_continuation_token))
                else format('invalid ReadRequest.ContinuationToken: value does not match regex pattern "^$|^[A-Za-z0-9-_]+={0,2}$", got %L', p_continuation_token) end,
                hint => 'Pass the continuation_token from the previous fga_read call unchanged, or '''' (or null) for the first page.');
        end if;
        begin
            raw := convert_from(decode(translate(p_continuation_token, '-_', '+/'), 'base64'), 'UTF8');
        exception when others then
            raw := null;
        end;
        if raw is null or raw !~ '^[0-9]{1,18}\|$' then
            perform permissions._fga_error(2007, format('Invalid continuation token: %L', p_continuation_token),
                hint => 'Pass the continuation_token from the previous fga_read call unchanged, or '''' (or null) for the first page.');
        end if;
        from_seq := left(raw, -1)::bigint;
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
               'key', jsonb_build_object('user', permissions._fga_user_string(r.user_type, r.user_id, r.user_relation),
                                         'relation', r.relation, 'object', r.object_type || ':' || r.object_id),
               'timestamp', r.inserted_at) order by r.seq) filter (where r.i <= n), '[]'),
           max(r.seq) filter (where r.i > n)
    into tuples, nxt
    from (select t.*, row_number() over (order by t.seq) as i
          from (select t.* from permissions.fga_tuples t
                where t.seq >= from_seq
                  and (p_object is null or t.object_type = split_part(p_object, ':', 1))
                  and (p_object is null or split_part(p_object, ':', 2) = '' or t.object_id = substr(p_object, strpos(p_object, ':') + 1))
                  and (p_relation is null or t.relation = p_relation)
                  and (p_user is null or permissions._fga_user_string(t.user_type, t.user_id, t.user_relation) = p_user)
                order by t.seq
                limit n + 1) t) r;
    continuation_token := coalesce(translate(encode(convert_to(nxt || '|', 'UTF8'), 'base64'), '+/', '-_'), '');
end;
$$;

-- ----------------------------------------------------------------------------
-- Evaluation
-- ----------------------------------------------------------------------------
--
-- A relation is `monotone` when neither it nor anything it depends on uses
-- intersection or difference. Then Check is reachability in the positive
-- graph (fga_edges), and the walks below answer it set-based. Otherwise
-- _fga_rec evaluates the rewrite tree the way OpenFGA's LocalChecker does,
-- with its cycle rule and its depth limit, and hands monotone subproblems
-- back to the walks when the cycle flag can't matter.
--
-- Depth, as in OpenFGA (resolve node limit 25): following a userset tuple or a
-- tupleToUserset costs one level, a computed relation and matching the user
-- directly cost none. A check whose answer needs 25 levels or more raises
-- openfga:2002.
--
-- Nodes are (type, id, relation) triples: relation '' is a plain object, id
-- '*' a typed wildcard. The walks keep frontiers and visited sets in parallel
-- arrays, like design A's check_for, and are PL/pgSQL so plans are cached.

-- One step forwards from frontier nodes: the tuples whose user is a frontier
-- node (direct and userset edges), the objects whose tupleset points at one
-- (tupleToUserset), then the relations those compute. Levels: a direct edge
-- adds the frontier node's w (0 for the user itself, 1 for a userset), a
-- tupleToUserset adds 1. Nodes already in st/si/sr are dropped.
create function permissions._fga_fstep(
    p_m text, p_ctx permissions.fga_tuple[],
    ft text[], fi text[], fr text[], fl int[], fw int[],
    st text[], si text[], sr text[])
returns table (t text, i text, r text, l int)
language plpgsql stable
rows 100
as $$
#variable_conflict use_column
begin
    return query
    with f(t, i, r, l, w) as materialized (
        select * from unnest(ft, fi, fr, fl, fw)
    ),
    hits(t, i, r, l) as (
        select tu.object_type, tu.object_id, tu.relation, f.l + f.w
        from f
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 'd' and e.src_type = f.t and e.src_relation = f.r
         and e.src_wildcard = (f.i = '*')
        join permissions.fga_tuples tu
          on tu.user_type = f.t and tu.user_id = f.i and tu.user_relation = f.r
         and tu.object_type = e.dst_type and tu.relation = e.dst_relation
      union all
        select c.object_type, c.object_id, c.relation, f.l + f.w
        from f
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 'd' and e.src_type = f.t and e.src_relation = f.r
         and e.src_wildcard = (f.i = '*')
        join unnest(p_ctx) c
          on c.user_type = f.t and c.user_id = f.i and c.user_relation = f.r
         and c.object_type = e.dst_type and c.relation = e.dst_relation
      union all
        select tu.object_type, tu.object_id, e.dst_relation, f.l + 1
        from f
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 't' and e.src_type = f.t and e.src_relation = f.r
        join permissions.fga_tuples tu
          on tu.user_type = f.t and tu.user_id = f.i and tu.user_relation = ''
         and tu.object_type = e.dst_type and tu.relation = e.via
      union all
        select c.object_type, c.object_id, e.dst_relation, f.l + 1
        from f
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 't' and e.src_type = f.t and e.src_relation = f.r
        join unnest(p_ctx) c
          on c.user_type = f.t and c.user_id = f.i and c.user_relation = ''
         and c.object_type = e.dst_type and c.relation = e.via
    ),
    closed(t, i, r, l) as (
        select * from hits
      union all
        select h.t, h.i, cc.dst_relation, h.l
        from hits h
        join permissions.fga_computed_closure cc
          on cc.model_id = p_m and cc.type = h.t and cc.src_relation = h.r
    )
    select c.t, c.i, c.r, min(c.l)::int
    from closed c
    where not exists (select 1 from unnest(st, si, sr) s(t, i, r)
                      where s.t = c.t and s.i = c.i and s.r = c.r)
    group by c.t, c.i, c.r;
end;
$$;

-- One step backwards from frontier relation nodes: the usersets in their
-- tuples and the tupleset parents (+1 level), then the relations they are
-- computed from (same level). With p_subjects, also the plain users and
-- wildcards in their tuples (relation '', the node's level): ListUsers needs
-- them, Check only probes for its own user.
create function permissions._fga_bstep(
    p_m text, p_ctx permissions.fga_tuple[],
    gt text[], gi text[], gr text[], gl int[],
    ut text[], ui text[], ur text[], p_subjects boolean)
returns table (t text, i text, r text, l int)
language plpgsql stable
rows 100
as $$
#variable_conflict use_column
begin
    return query
    with g(t, i, r, l) as materialized (
        select * from unnest(gt, gi, gr, gl)
    ),
    nx(t, i, r, l) as (
        select x.user_type, x.user_id, x.user_relation, g.l + case when x.user_relation = '' then 0 else 1 end
        from g
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 'd' and e.dst_type = g.t and e.dst_relation = g.r
         and (p_subjects or e.src_relation <> '')
        join permissions.fga_tuples x
          on x.object_type = g.t and x.object_id = g.i and x.relation = g.r
         and x.user_type = e.src_type and x.user_relation = e.src_relation
        where (x.user_id = '*') = e.src_wildcard
      union all
        select x.user_type, x.user_id, x.user_relation, g.l + case when x.user_relation = '' then 0 else 1 end
        from g
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 'd' and e.dst_type = g.t and e.dst_relation = g.r
         and (p_subjects or e.src_relation <> '')
        join unnest(p_ctx) x
          on x.object_type = g.t and x.object_id = g.i and x.relation = g.r
         and x.user_type = e.src_type and x.user_relation = e.src_relation
        where (x.user_id = '*') = e.src_wildcard
      union all
        select x.user_type, x.user_id, e.src_relation, g.l + 1
        from g
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 't' and e.dst_type = g.t and e.dst_relation = g.r
        join permissions.fga_tuples x
          on x.object_type = g.t and x.object_id = g.i and x.relation = e.via
         and x.user_type = e.src_type and x.user_relation = ''
      union all
        select x.user_type, x.user_id, e.src_relation, g.l + 1
        from g
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 't' and e.dst_type = g.t and e.dst_relation = g.r
        join unnest(p_ctx) x
          on x.object_type = g.t and x.object_id = g.i and x.relation = e.via
         and x.user_type = e.src_type and x.user_relation = ''
    ),
    closed(t, i, r, l) as (
        select * from nx
      union all
        select n.t, n.i, cc.src_relation, n.l
        from nx n
        join permissions.fga_computed_closure cc
          on cc.model_id = p_m and cc.type = n.t and cc.dst_relation = n.r
        where n.r <> ''
    )
    select c.t, c.i, c.r, min(c.l)::int
    from closed c
    where not exists (select 1 from unnest(ut, ui, ur) s(t, i, r)
                      where s.t = c.t and s.i = c.i and s.r = c.r)
    group by c.t, c.i, c.r;
end;
$$;

-- Check on a monotone relation: a bidirectional search, each step expanding
-- the smaller frontier, until the two sides meet. Returns 1 (allowed) if they
-- meet within p_max levels, 3 if only deeper, 0 if never.
create function permissions._fga_bidi(
    p_m text, p_ot text, p_oid text, p_rel text, p_ut text, p_uid text, p_urel text,
    p_ctx permissions.fga_tuple[], p_max int)
returns smallint
language plpgsql stable
as $$
declare
    xt text[]; xi text[]; xr text[];                       -- the user (and its type's wildcard)
    ft text[]; fi text[]; fr text[]; fl int[]; fw int[];   -- forward frontier
    st text[]; si text[]; sr text[]; sl int[];             -- forward: every node reached
    gt text[]; gi text[]; gr text[]; gl int[];             -- backward frontier
    ut text[]; ui text[]; ur text[]; ul int[];             -- backward: every node reached
    best int;
begin
    xt := array[p_ut]; xi := array[p_uid]; xr := array[p_urel];
    if p_urel = '' and p_uid <> '*' then
        xt := xt || p_ut; xi := xi || '*'::text; xr := xr || ''::text;
    end if;

    -- forward start: the user, and for a userset user the relations it computes
    if p_urel = '' then
        ft := xt; fi := xi; fr := xr;
        fl := array_fill(0, array[cardinality(xt)]); fw := fl;
    else
        select array_agg(n.t), array_agg(n.i), array_agg(n.r), array_agg(0), array_agg(n.w)
        into ft, fi, fr, fl, fw
        from (
            select x.t, x.i, x.r, min(x.w) as w
            from (
                select s.t, s.i, s.r, 0 as w from unnest(xt, xi, xr) s(t, i, r)
              union all
                select s.t, s.i, cc.dst_relation, 1
                from unnest(xt, xi, xr) s(t, i, r)
                join permissions.fga_computed_closure cc
                  on cc.model_id = p_m and cc.type = s.t and cc.src_relation = s.r
            ) x
            group by x.t, x.i, x.r
        ) n;
    end if;
    st := ft; si := fi; sr := fr; sl := fl;

    -- backward start: the target, and the relations that compute it
    select array_agg(n.t), array_agg(n.i), array_agg(n.r), array_agg(0)
    into gt, gi, gr, gl
    from (
        select p_ot::text as t, p_oid::text as i, p_rel::text as r
      union
        select p_ot, p_oid, cc.src_relation
        from permissions.fga_computed_closure cc
        where cc.model_id = p_m and cc.type = p_ot and cc.dst_relation = p_rel
    ) n;
    ut := gt; ui := gi; ur := gr; ul := gl;

    -- a plain user's nodes (relation '') never are relation nodes
    if p_urel <> '' then
        select min(f.l + b.l) into best
        from unnest(st, si, sr, sl) f(t, i, r, l)
        join unnest(ut, ui, ur, ul) b(t, i, r, l) on b.t = f.t and b.i = f.i and b.r = f.r;
    end if;

    loop
        if best is not null then
            return case when best < p_max then 1 else 3 end;
        end if;
        if cardinality(ft) < cardinality(gt) then
            select array_agg(n.t), array_agg(n.i), array_agg(n.r), array_agg(n.l)
            into ft, fi, fr, fl
            from permissions._fga_fstep(p_m, p_ctx, ft, fi, fr, fl, fw, st, si, sr) n;
            exit when ft is null;
            fw := array_fill(1, array[cardinality(ft)]);
            st := st || ft; si := si || fi; sr := sr || fr; sl := sl || fl;
            select min(f.l + b.l) into best
            from unnest(ft, fi, fr, fl) f(t, i, r, l)
            join unnest(ut, ui, ur, ul) b(t, i, r, l) on b.t = f.t and b.i = f.i and b.r = f.r;
        else
            -- the user itself (or its wildcard) in a tuple on a frontier node
            select min(g.l) into best
            from unnest(gt, gi, gr, gl) g(t, i, r, l)
            cross join unnest(xt, xi, xr) s(t, i, r)
            join permissions.fga_edges e
              on e.model_id = p_m and e.kind = 'd' and e.dst_type = g.t and e.dst_relation = g.r
             and e.src_type = s.t and e.src_relation = s.r and e.src_wildcard = (s.i = '*')
            where exists (select 1 from permissions.fga_tuples x
                          where x.object_type = g.t and x.object_id = g.i and x.relation = g.r
                            and x.user_type = s.t and x.user_id = s.i and x.user_relation = s.r)
               or exists (select 1 from unnest(p_ctx) x
                          where x.object_type = g.t and x.object_id = g.i and x.relation = g.r
                            and x.user_type = s.t and x.user_id = s.i and x.user_relation = s.r);
            continue when best is not null;
            select array_agg(n.t), array_agg(n.i), array_agg(n.r), array_agg(n.l)
            into gt, gi, gr, gl
            from permissions._fga_bstep(p_m, p_ctx, gt, gi, gr, gl, ut, ui, ur, false) n;
            exit when gt is null;
            ut := ut || gt; ui := ui || gi; ur := ur || gr; ul := ul || gl;
            select min(f.l + b.l) into best
            from unnest(st, si, sr, sl) f(t, i, r, l)
            join unnest(gt, gi, gr, gl) b(t, i, r, l) on b.t = f.t and b.i = f.i and b.r = f.r;
        end if;
    end loop;
    return 0;
end;
$$;

-- ListObjects' forward walk: every object of p_type the user reaches through
-- p_rel in the positive graph, with the lowest level it is reached at (25
-- meaning 25 or more). Exact for a monotone relation, a superset otherwise.
--
-- One recursive CTE, design A's _reach shape, over the steps compiled for this
-- target (fga_walk_steps): each step is one probe of fga_tuples (or the
-- contextual tuples) that already yields the computed closure of its hit, and
-- only nodes that can reach the target are produced. The recursion produces
-- only nodes with steps of their own toward the target (`expand`); the leaves
-- (most of a wide walk: documents) come from one last join of the reached
-- nodes, each at its lowest level, to the steps that yield the target.
--
-- Levels, as OpenFGA counts them (see Evaluation above): a direct edge costs
-- the node's weight c (0 for the user itself and a userset user's own
-- relation, 1 otherwise), a tupleToUserset 1. A node is a row per level it is
-- reached at, so a node reached through paths of different lengths is
-- expanded once per level, and a cycle goes around until level 25: the
-- recursion stops expanding there, which bounds it. Below 25 the lowest level
-- of every node is exact. If an expandable node is first reached at 25, the
-- walk stopped short of what lies behind it: _fga_forward_ids walks the rest
-- without levels, and every target found only there is reported at 25.
create function permissions._fga_forward(
    p_m text, p_ut text, p_uid text, p_urel text, p_ctx permissions.fga_tuple[],
    p_type text, p_rel text)
returns table (object_id text, lvl int)
language plpgsql stable
rows 100
as $$
#variable_conflict use_column
begin
    return query
    with recursive
    st as materialized (
        select s.kind, s.src_type, s.src_relation, s.src_wildcard, s.user_relation,
               s.object_type, s.tuple_relation, s.out_relation, s.expand
        from permissions.fga_walk_steps s
        where s.model_id = p_m and s.target_type = p_type and s.target_relation = p_rel
    ),
    w(t, i, r, l, c) as (
        select p_ut::text collate "C", p_uid::text collate "C", p_urel::text collate "C", 0, 0
      union all
        select p_ut, '*', '', 0, 0 where p_urel = '' and p_uid <> '*'
      union all
        select p_ut, p_uid, cc.dst_relation, 0, 1
        from permissions.fga_computed_closure cc
        where cc.model_id = p_m and cc.type = p_ut and cc.src_relation = p_urel and p_urel <> ''
      union
        select n.t, n.i, n.r, n.l, 1
        from w
        join st on st.src_type = w.t and st.src_relation = w.r and st.src_wildcard = (w.i = '*') and st.expand
        cross join lateral (
            select tu.object_type, tu.object_id, st.out_relation,
                   w.l + case when st.kind = 'd' then w.c else 1 end
            from permissions.fga_tuples tu
            where tu.user_type = w.t and tu.user_id = w.i and tu.user_relation = st.user_relation
              and tu.object_type = st.object_type and tu.relation = st.tuple_relation
          union all
            select x.object_type, x.object_id, st.out_relation,
                   w.l + case when st.kind = 'd' then w.c else 1 end
            from unnest(p_ctx) x
            where x.user_type = w.t and x.user_id = w.i and x.user_relation = st.user_relation
              and x.object_type = st.object_type and x.relation = st.tuple_relation
            offset 0
        ) n(t, i, r, l)
        where w.l < 25
    ),
    -- each reached node once: its lowest level, and the lowest level a direct
    -- edge from it reaches
    b(t, i, r, l, dl) as materialized (
        select w.t, w.i, w.r, min(w.l), min(w.l + w.c) from w group by w.t, w.i, w.r
    ),
    tg(i, l) as (
        select b.i, b.l from b where b.t = p_type and b.r = p_rel
      union all
        select n.i, n.l
        from b
        join st on st.src_type = b.t and st.src_relation = b.r and st.src_wildcard = (b.i = '*')
               and st.object_type = p_type and st.out_relation = p_rel
        cross join lateral (
            select tu.object_id, case when st.kind = 'd' then b.dl else b.l + 1 end
            from permissions.fga_tuples tu
            where tu.user_type = b.t and tu.user_id = b.i and tu.user_relation = st.user_relation
              and tu.object_type = st.object_type and tu.relation = st.tuple_relation
          union all
            select x.object_id, case when st.kind = 'd' then b.dl else b.l + 1 end
            from unnest(p_ctx) x
            where x.user_type = b.t and x.user_id = b.i and x.user_relation = st.user_relation
              and x.object_type = st.object_type and x.relation = st.tuple_relation
            offset 0
        ) n(i, l)
    ),
    res(i, l) as materialized (
        select tg.i, min(tg.l) from tg group by tg.i
    )
    select res.i, least(res.l, 25) from res
    union all
    select f, 25
    from permissions._fga_forward_ids(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, p_rel) f
    where exists (select 1 from b where b.l >= 25)
      and not exists (select 1 from res where res.i = f);
end;
$$;

-- The same walk without levels: every object of p_type the user reaches
-- through p_rel in the positive graph (a superset for a non-monotone
-- relation: ListObjects' candidates). A node is one row, so cycles and
-- reconverging paths cost nothing extra.
create function permissions._fga_forward_ids(
    p_m text, p_ut text, p_uid text, p_urel text, p_ctx permissions.fga_tuple[],
    p_type text, p_rel text)
returns setof text
language plpgsql stable
rows 100
as $$
#variable_conflict use_column
begin
    return query
    with recursive
    st as materialized (
        select s.src_type, s.src_relation, s.src_wildcard, s.user_relation,
               s.object_type, s.tuple_relation, s.out_relation, s.expand
        from permissions.fga_walk_steps s
        where s.model_id = p_m and s.target_type = p_type and s.target_relation = p_rel
    ),
    w(t, i, r) as (
        select p_ut::text collate "C", p_uid::text collate "C", p_urel::text collate "C"
      union all
        select p_ut, '*', '' where p_urel = '' and p_uid <> '*'
      union all
        select p_ut, p_uid, cc.dst_relation
        from permissions.fga_computed_closure cc
        where cc.model_id = p_m and cc.type = p_ut and cc.src_relation = p_urel and p_urel <> ''
      union
        select n.t, n.i, n.r
        from w
        join st on st.src_type = w.t and st.src_relation = w.r and st.src_wildcard = (w.i = '*') and st.expand
        cross join lateral (
            select tu.object_type, tu.object_id, st.out_relation
            from permissions.fga_tuples tu
            where tu.user_type = w.t and tu.user_id = w.i and tu.user_relation = st.user_relation
              and tu.object_type = st.object_type and tu.relation = st.tuple_relation
          union all
            select x.object_type, x.object_id, st.out_relation
            from unnest(p_ctx) x
            where x.user_type = w.t and x.user_id = w.i and x.user_relation = st.user_relation
              and x.object_type = st.object_type and x.relation = st.tuple_relation
            offset 0
        ) n(t, i, r)
    )
    select w.i from w where w.t = p_type and w.r = p_rel
    union
    select n.i
    from w
    join st on st.src_type = w.t and st.src_relation = w.r and st.src_wildcard = (w.i = '*')
           and st.object_type = p_type and st.out_relation = p_rel
    cross join lateral (
        select tu.object_id
        from permissions.fga_tuples tu
        where tu.user_type = w.t and tu.user_id = w.i and tu.user_relation = st.user_relation
          and tu.object_type = st.object_type and tu.relation = st.tuple_relation
      union all
        select x.object_id
        from unnest(p_ctx) x
        where x.user_type = w.t and x.user_id = w.i and x.user_relation = st.user_relation
          and x.object_type = st.object_type and x.relation = st.tuple_relation
        offset 0
    ) n(i);
end;
$$;

-- Everything p_type:p_id#p_rel reaches backwards in the positive graph:
-- relation nodes (usersets, tupleset parents, computed-from relations) and,
-- with relation '', the plain users and wildcards in their tuples. Raises
-- 2002 when a relation node is p_max levels deep, as OpenFGA's ListUsers does.
create function permissions._fga_backward(
    p_m text, p_ot text, p_oid text, p_rel text, p_ctx permissions.fga_tuple[], p_max int)
returns table (t text, i text, r text, l int)
language plpgsql stable
rows 100
as $$
#variable_conflict use_column
declare
    gt text[]; gi text[]; gr text[]; gl int[];
    ut text[]; ui text[]; ur text[];
    nt text[]; ni text[]; nr text[]; nl int[];
begin
    select array_agg(n.t), array_agg(n.i), array_agg(n.r), array_agg(0)
    into gt, gi, gr, gl
    from (
        select p_ot::text as t, p_oid::text as i, p_rel::text as r
      union
        select p_ot, p_oid, cc.src_relation
        from permissions.fga_computed_closure cc
        where cc.model_id = p_m and cc.type = p_ot and cc.dst_relation = p_rel
    ) n;
    ut := gt; ui := gi; ur := gr;
    return query select * from unnest(gt, gi, gr, gl);
    loop
        if exists (select 1 from unnest(gl) x where x >= p_max) then
            perform permissions._fga_too_complex();
        end if;
        select array_agg(n.t), array_agg(n.i), array_agg(n.r), array_agg(n.l)
        into nt, ni, nr, nl
        from permissions._fga_bstep(p_m, p_ctx, gt, gi, gr, gl, ut, ui, ur, true) n;
        exit when nt is null;
        ut := ut || nt; ui := ui || ni; ur := ur || nr;
        return query select * from unnest(nt, ni, nr, nl);
        select array_agg(n.t), array_agg(n.i), array_agg(n.r), array_agg(n.l)
        into gt, gi, gr, gl
        from unnest(nt, ni, nr, nl) n(t, i, r, l) where n.r <> '';
        exit when gt is null;
    end loop;
end;
$$;

create function permissions._fga_path_exists(p_m text, p_type text, p_rel text, p_ut text, p_urel text)
returns boolean
language sql stable
as $$
    select exists (
        select 1 from permissions.fga_paths p
        where p.model_id = p_m and p.type = p_type and p.relation = p_rel
          and p.user_type = p_ut and p.user_relation = p_urel
          and (p_urel = '' or not p.wildcard))
$$;

-- General evaluation, after OpenFGA's LocalChecker.ResolveCheck: depth limit,
-- cycle detection on the path (a subproblem already being resolved higher up
-- is false, flagged as a cycle), a userset user is in itself, PathExists, then
-- the rewrite tree. Results: 0 false, 1 true, 2 false through a cycle, 3 too
-- deep. The cycle flag only matters under the subtract of a difference (a
-- cycle there makes the difference false). A monotone relation, under a
-- subtract or not, goes to the set-based search instead: its least fixpoint,
-- in which a cycle of usersets contributes nobody (designs/d-per-model.md §5).
-- So the flag only comes from recursion through a non-monotone relation, such
-- as a relation that reaches itself through a subtract.
create function permissions._fga_rec(
    p_m text, p_ot text, p_oid text, p_rel text, p_ut text, p_uid text, p_urel text,
    p_ctx permissions.fga_tuple[], p_depth int, p_path text[])
returns smallint
language plpgsql stable
as $$
declare
    k text;
    mono boolean;
    ops text[]; pars int[]; cs text[]; tss text[];
begin
    if p_depth >= 25 then
        return 3;
    end if;
    k := p_ot || ':' || p_oid || '#' || p_rel || '@' || permissions._fga_user_string(p_ut, p_uid, p_urel);
    if k = any (p_path) then
        return 2;
    end if;
    if p_urel <> '' and p_ut = p_ot and p_uid = p_oid and p_urel = p_rel then
        return 1;
    end if;
    select r.monotone into mono
    from permissions.fga_relations r where r.model_id = p_m and r.type = p_ot and r.relation = p_rel;
    if mono is null or not permissions._fga_path_exists(p_m, p_ot, p_rel, p_ut, p_urel) then
        return 0;
    end if;
    if mono then
        return permissions._fga_bidi(p_m, p_ot, p_oid, p_rel, p_ut, p_uid, p_urel, p_ctx, 25 - p_depth);
    end if;
    select array_agg(n.op order by n.node), array_agg(n.parent order by n.node),
           array_agg(n.computed order by n.node), array_agg(n.tupleset order by n.node)
    into ops, pars, cs, tss
    from permissions.fga_rewrite_nodes n
    where n.model_id = p_m and n.type = p_ot and n.relation = p_rel;
    return permissions._fga_rec_node(p_m, ops, pars, cs, tss, 1, p_ot, p_oid, p_rel,
                                     p_ut, p_uid, p_urel, p_ctx, p_depth, p_path || k);
end;
$$;

-- One node of a relation's rewrite tree (arrays from fga_rewrite_nodes, index k).
create function permissions._fga_rec_node(
    p_m text, ops text[], pars int[], cs text[], tss text[], k int,
    p_ot text, p_oid text, p_rel text, p_ut text, p_uid text, p_urel text,
    p_ctx permissions.fga_tuple[], p_depth int, p_path text[])
returns smallint
language plpgsql stable
as $$
declare
    x smallint;
    b smallint;
    err boolean := false;
    cyc boolean := false;
    j int;
    first_child int;
    second_child int;
    rec record;
begin
    case ops[k]
    when 'this' then
        -- the user itself in a tuple, or (for a plain user) its type's wildcard
        if exists (
            select 1
            from permissions.fga_type_restrictions tr
            cross join (values (p_uid::text), ('*'::text)) c(uid)
            where tr.model_id = p_m and tr.type = p_ot and tr.relation = p_rel
              and tr.user_type = p_ut and tr.user_relation = p_urel and tr.wildcard = (c.uid = '*')
              and (c.uid = p_uid or p_urel = '')
              and (exists (select 1 from permissions.fga_tuples t
                           where t.object_type = p_ot and t.object_id = p_oid and t.relation = p_rel
                             and t.user_type = p_ut and t.user_id = c.uid and t.user_relation = p_urel)
                   or exists (select 1 from unnest(p_ctx) t
                              where t.object_type = p_ot and t.object_id = p_oid and t.relation = p_rel
                                and t.user_type = p_ut and t.user_id = c.uid and t.user_relation = p_urel))) then
            return 1;
        end if;
        for rec in
            select t.user_type, t.user_id, t.user_relation
            from permissions.fga_type_restrictions tr
            join permissions.fga_tuples t
              on t.object_type = p_ot and t.object_id = p_oid and t.relation = p_rel
             and t.user_type = tr.user_type and t.user_relation = tr.user_relation
            where tr.model_id = p_m and tr.type = p_ot and tr.relation = p_rel and tr.user_relation <> ''
          union
            select t.user_type, t.user_id, t.user_relation
            from permissions.fga_type_restrictions tr
            join unnest(p_ctx) t
              on t.object_type = p_ot and t.object_id = p_oid and t.relation = p_rel
             and t.user_type = tr.user_type and t.user_relation = tr.user_relation
            where tr.model_id = p_m and tr.type = p_ot and tr.relation = p_rel and tr.user_relation <> ''
        loop
            x := permissions._fga_rec(p_m, rec.user_type, rec.user_id, rec.user_relation, p_ut, p_uid, p_urel,
                                      p_ctx, p_depth + 1, p_path);
            if x = 1 then return 1; end if;
            err := err or x = 3;
            cyc := cyc or x = 2;
        end loop;
        return case when err then 3 when cyc then 2 else 0 end;

    when 'computed' then
        return permissions._fga_rec(p_m, p_ot, p_oid, cs[k], p_ut, p_uid, p_urel, p_ctx, p_depth, p_path);

    when 'ttu' then
        for rec in
            select t.user_type, t.user_id
            from permissions.fga_type_restrictions tr
            join permissions.fga_tuples t
              on t.object_type = p_ot and t.object_id = p_oid and t.relation = tss[k]
             and t.user_type = tr.user_type and t.user_relation = ''
            join permissions.fga_relations r on r.model_id = p_m and r.type = t.user_type and r.relation = cs[k]
            where tr.model_id = p_m and tr.type = p_ot and tr.relation = tss[k]
              and tr.user_relation = '' and not tr.wildcard and t.user_id <> '*'
          union
            select t.user_type, t.user_id
            from permissions.fga_type_restrictions tr
            join unnest(p_ctx) t
              on t.object_type = p_ot and t.object_id = p_oid and t.relation = tss[k]
             and t.user_type = tr.user_type and t.user_relation = ''
            join permissions.fga_relations r on r.model_id = p_m and r.type = t.user_type and r.relation = cs[k]
            where tr.model_id = p_m and tr.type = p_ot and tr.relation = tss[k]
              and tr.user_relation = '' and not tr.wildcard and t.user_id <> '*'
        loop
            x := permissions._fga_rec(p_m, rec.user_type, rec.user_id, cs[k], p_ut, p_uid, p_urel,
                                      p_ctx, p_depth + 1, p_path);
            if x = 1 then return 1; end if;
            err := err or x = 3;
            cyc := cyc or x = 2;
        end loop;
        return case when err then 3 when cyc then 2 else 0 end;

    when 'union' then
        for j in k + 1 .. cardinality(ops) loop
            continue when pars[j] is distinct from k;
            x := permissions._fga_rec_node(p_m, ops, pars, cs, tss, j, p_ot, p_oid, p_rel,
                                           p_ut, p_uid, p_urel, p_ctx, p_depth, p_path);
            if x = 1 then return 1; end if;
            err := err or x = 3;
            cyc := cyc or x = 2;
        end loop;
        return case when err then 3 when cyc then 2 else 0 end;

    when 'intersection' then
        for j in k + 1 .. cardinality(ops) loop
            continue when pars[j] is distinct from k;
            x := permissions._fga_rec_node(p_m, ops, pars, cs, tss, j, p_ot, p_oid, p_rel,
                                           p_ut, p_uid, p_urel, p_ctx, p_depth, p_path);
            if x in (0, 2) then return x; end if;
            err := err or x = 3;
        end loop;
        return case when err then 3 else 1 end;

    when 'difference' then
        for j in k + 1 .. cardinality(ops) loop
            continue when pars[j] is distinct from k;
            if first_child is null then first_child := j; else second_child := j; exit; end if;
        end loop;
        b := permissions._fga_rec_node(p_m, ops, pars, cs, tss, first_child, p_ot, p_oid, p_rel,
                                       p_ut, p_uid, p_urel, p_ctx, p_depth, p_path);
        if b in (0, 2) then return b; end if;
        x := permissions._fga_rec_node(p_m, ops, pars, cs, tss, second_child, p_ot, p_oid, p_rel,
                                       p_ut, p_uid, p_urel, p_ctx, p_depth, p_path);
        if x = 1 then return 0; end if;
        if x = 2 then return 2; end if;
        if b = 3 or x = 3 then return 3; end if;
        return 1;
    end case;
end;
$$;

create function permissions._fga_too_complex()
returns void
language sql
as $$
    select permissions._fga_error(2002, 'Authorization Model resolution required too many rewrite rules to be resolved. Try simplifying the Authorization Model.',
        hint => 'An answer may follow at most 25 userset or tupleToUserset hops: look for a very long chain or a cycle of usersets in the tuples or the model (for example nested groups).')
$$;

-- _fga_rec on a list candidate: true or false, raising 2002 when too deep.
create function permissions._fga_rec_ok(
    p_m text, p_ot text, p_oid text, p_rel text, p_ut text, p_uid text, p_urel text,
    p_ctx permissions.fga_tuple[])
returns boolean
language plpgsql stable
as $$
declare
    x smallint := permissions._fga_rec(p_m, p_ot, p_oid, p_rel, p_ut, p_uid, p_urel, p_ctx, 0, '{}');
begin
    if x = 3 then
        perform permissions._fga_too_complex();
    end if;
    return x = 1;
end;
$$;

-- For a list's filter: raises 2002 (an answer 25 levels deep or more).
create function permissions._fga_deep()
returns boolean
language plpgsql
as $$
begin
    perform permissions._fga_too_complex();
    return false;
end;
$$;

-- Check on parsed, validated input.
create function permissions._fga_check_impl(
    p_m text, p_ot text, p_oid text, p_rel text, p_ut text, p_uid text, p_urel text,
    p_ctx permissions.fga_tuple[])
returns boolean
language plpgsql stable
as $$
declare
    mono boolean;
    has_path boolean;
    x smallint;
begin
    if p_urel <> '' and p_ut = p_ot and p_uid = p_oid and p_urel = p_rel then
        return true;
    end if;
    select r.monotone,
           exists (select 1 from permissions.fga_paths p
                   where p.model_id = p_m and p.type = p_ot and p.relation = p_rel
                     and p.user_type = p_ut and p.user_relation = p_urel and (p_urel = '' or not p.wildcard))
    into mono, has_path
    from permissions.fga_relations r where r.model_id = p_m and r.type = p_ot and r.relation = p_rel;
    if not coalesce(has_path, false) then
        return false;
    end if;
    if mono then
        x := permissions._fga_bidi(p_m, p_ot, p_oid, p_rel, p_ut, p_uid, p_urel, p_ctx, 25);
    else
        x := permissions._fga_rec(p_m, p_ot, p_oid, p_rel, p_ut, p_uid, p_urel, p_ctx, 0, '{}');
    end if;
    if x = 3 then
        perform permissions._fga_too_complex();
    end if;
    return x = 1;
end;
$$;

-- ListObjects on parsed, validated input: object ids, unordered.
--   - monotone relation: the forward walk;
--   - set-based difference (fga_relations.diff_relation, compiled): the
--     walk to the relation (exactly its base) minus the walk to the subtract
--     (for `r from ts`, the objects whose ts is one of the parents the user
--     reaches through r). Results as _fga_rec's: a base deeper than the limit
--     is an error unless the subtract removes it; a userset user always has
--     its own relation; with diff_recheck, what the subtract removes is
--     checked with _fga_rec (the depth limit on a recursive subtract).
--   - otherwise: the candidates of the positive walk, each one checked by
--     _fga_rec.
create function permissions._fga_list_object_ids(
    p_m text, p_type text, p_rel text, p_ut text, p_uid text, p_urel text, p_ctx permissions.fga_tuple[])
returns setof text
language plpgsql stable
rows 100
as $$
declare
    mono boolean;
    sub_rel text;
    sub_ts text;
    recheck boolean;
    c text;
    x smallint;
begin
    if not permissions._fga_path_exists(p_m, p_type, p_rel, p_ut, p_urel) then
        return;
    end if;
    select r.monotone, r.diff_relation, r.diff_tupleset, r.diff_recheck into mono, sub_rel, sub_ts, recheck
    from permissions.fga_relations r where r.model_id = p_m and r.type = p_type and r.relation = p_rel;
    if mono then
        return query
        select f.object_id
        from permissions._fga_forward(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, p_rel) f
        where case when f.lvl < 25 then true else permissions._fga_deep() end;
        return;
    end if;
    if sub_rel is not null then
        return query
        with s(i) as materialized (
            select f from permissions._fga_forward_ids(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, sub_rel) f
            where sub_ts is null
          union
            select n.i
            from permissions.fga_type_restrictions tr
            join permissions.fga_relations pr on pr.model_id = p_m and pr.type = tr.user_type and pr.relation = sub_rel
            cross join lateral permissions._fga_forward_ids(p_m, p_ut, p_uid, p_urel, p_ctx, tr.user_type, sub_rel) p
            cross join lateral (
                select tu.object_id
                from permissions.fga_tuples tu
                where tu.user_type = tr.user_type and tu.user_id = p and tu.user_relation = ''
                  and tu.object_type = p_type and tu.relation = sub_ts
              union all
                select x.object_id
                from unnest(p_ctx) x
                where x.user_type = tr.user_type and x.user_id = p and x.user_relation = ''
                  and x.object_type = p_type and x.relation = sub_ts
                offset 0
            ) n(i)
            where sub_ts is not null and tr.model_id = p_m and tr.type = p_type and tr.relation = sub_ts
              and tr.user_relation = '' and not tr.wildcard
        )
        select b.object_id
        from permissions._fga_forward(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, p_rel) b
        left join s on s.i = b.object_id
        where case when s.i is not null and not (p_urel <> '' and p_ut = p_type and p_uid = b.object_id and p_urel = p_rel)
                   then case when recheck
                             then permissions._fga_rec_ok(p_m, p_type, b.object_id, p_rel, p_ut, p_uid, p_urel, p_ctx)
                             else false end
                   when b.lvl < 25 then true
                   else permissions._fga_deep() end;
        return;
    end if;
    -- candidates from the positive graph, each one checked
    for c in select f from permissions._fga_forward_ids(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, p_rel) f loop
        x := permissions._fga_rec(p_m, p_type, c, p_rel, p_ut, p_uid, p_urel, p_ctx, 0, '{}');
        if x = 3 then
            perform permissions._fga_too_complex();
        end if;
        if x = 1 then
            return next c;
        end if;
    end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- OpenFGA API (explicit user; admin only, like the other explicit-subject
-- functions: a client could ask what any user can access)
-- ----------------------------------------------------------------------------

-- Check. user: 'type:id', 'type:*' or 'type:id#relation'; object: 'type:id'.
-- Invalid input raises openfga:2000, an invalid contextual tuple 2027, too
-- deep a resolution 2002.
create function permissions.fga_check("user" text, relation text, object text,
                                      contextual_tuples jsonb default null,
                                      authorization_model_id text default null)
returns boolean
language plpgsql stable security definer
set search_path = ''
set plan_cache_mode = force_generic_plan
as $$
declare
    m text := permissions._fga_model_id(authorization_model_id);
    u record;
    o record;
begin
    select * into u from permissions._fga_parse_user(m, "user", 2000);
    select * into o from permissions._fga_parse_object(m, object, relation, 2000);
    return permissions._fga_check_impl(m, o.object_type, o.object_id, relation,
                                       u.user_type, u.user_id, u.user_relation,
                                       permissions._fga_ctx(m, contextual_tuples));
end;
$$;

-- ListObjects: 'type:id' strings, unordered, at most 1,000 (OpenFGA's cap,
-- _fga_limits; the rest are dropped silently, as OpenFGA does, and which ones
-- survive is unspecified). Errors as OpenFGA: an invalid contextual tuple
-- 2027, unknown type 2021, unknown relation 2022, invalid user 2000. The RLS
-- helpers (fga_list_objects_current, fga_list_object_ids_current) call the
-- uncapped _fga_list_object_ids.
create function permissions.fga_list_objects("user" text, type text, relation text,
                                             contextual_tuples jsonb default null,
                                             authorization_model_id text default null)
returns setof text
language plpgsql stable security definer
set search_path = ''
set plan_cache_mode = force_generic_plan
rows 100
as $$
declare
    m text := permissions._fga_model_id(authorization_model_id);
    ctx permissions.fga_tuple[] := permissions._fga_ctx(m, contextual_tuples);
    u record;
begin
    if not exists (select 1 from permissions.fga_types t where t.model_id = m and t.type = fga_list_objects.type) then
        perform permissions._fga_error(2021, format('type ''%s'' not found', fga_list_objects.type),
            hint => permissions._fga_type_hint(m, fga_list_objects.type));
    end if;
    if not exists (select 1 from permissions.fga_relations r
                   where r.model_id = m and r.type = fga_list_objects.type and r.relation = fga_list_objects.relation) then
        perform permissions._fga_error(2022, format('relation ''%s#%s'' not found', fga_list_objects.type, fga_list_objects.relation),
            hint => permissions._fga_relation_hint(m, fga_list_objects.type, fga_list_objects.relation));
    end if;
    select * into u from permissions._fga_parse_user(m, "user", 2000);
    return query
    select fga_list_objects.type || ':' || x
    from permissions._fga_list_object_ids(m, fga_list_objects.type, fga_list_objects.relation,
                                          u.user_type, u.user_id, u.user_relation, ctx) x
    limit (select l.list_max from permissions._fga_limits() l);
end;
$$;

-- ListUsers, uncapped (fga_list_users is the API, capped): users of the
-- filter types ('user', or 'group#member' for usersets) that have the
-- relation with the object, as 'type:id', 'type:*' or 'type:id#relation'.
-- Unordered.
create function permissions._fga_list_users(object text, relation text, user_filters text[],
                                            contextual_tuples jsonb default null,
                                            authorization_model_id text default null)
returns setof text
language plpgsql stable
set search_path = ''
set plan_cache_mode = force_generic_plan
rows 100
as $$
declare
    m text := permissions._fga_model_id(authorization_model_id);
    ctx permissions.fga_tuple[];
    o record;
    f text;
    mono boolean;
    sub_rel text;
    sub_ts text;
    recheck boolean;
    c record;
    x smallint;
begin
    select * into o from permissions._fga_split_object(object);
    if o.object_type is null or o.object_id = '*' then
        perform permissions._fga_error(2000, format('invalid ''object'' field format: %s', object),
            hint => 'Write the object as ''type:id'', e.g. ''document:1''.');
    end if;
    ctx := permissions._fga_ctx(m, contextual_tuples);
    if coalesce(cardinality(user_filters), 0) = 0 then
        perform permissions._fga_error(2000, 'user_filters must have at least one filter',
            hint => 'Pass the user types to return, e.g. ''{user}'' or ''{team#member}''.');
    end if;
    foreach f in array user_filters loop
        if not exists (select 1 from permissions.fga_types t where t.model_id = m and t.type = split_part(f, '#', 1)) then
            perform permissions._fga_error(2021, format('type ''%s'' not found (user_filters: %s)', split_part(f, '#', 1), f),
                hint => permissions._fga_type_hint(m, split_part(f, '#', 1)));
        end if;
        if split_part(f, '#', 2) <> '' and not exists (
            select 1 from permissions.fga_relations r
            where r.model_id = m and r.type = split_part(f, '#', 1) and r.relation = split_part(f, '#', 2)) then
            perform permissions._fga_error(2022, format('relation ''%s'' not found (user_filters: %s)', f, f),
                hint => permissions._fga_relation_hint(m, split_part(f, '#', 1), split_part(f, '#', 2)));
        end if;
    end loop;
    if not exists (select 1 from permissions.fga_types t where t.model_id = m and t.type = o.object_type) then
        perform permissions._fga_error(2021, format('type ''%s'' not found', o.object_type),
            hint => permissions._fga_type_hint(m, o.object_type));
    end if;
    select r.monotone, r.diff_relation, r.diff_tupleset, r.diff_recheck into mono, sub_rel, sub_ts, recheck
    from permissions.fga_relations r where r.model_id = m and r.type = o.object_type and r.relation = _fga_list_users.relation;
    if mono is null then
        perform permissions._fga_error(2022, format('relation ''%s#%s'' not found', o.object_type, _fga_list_users.relation),
            hint => permissions._fga_relation_hint(m, o.object_type, _fga_list_users.relation));
    end if;
    if sub_rel is not null then
        -- set-based difference (see _fga_list_object_ids): the users the base
        -- reaches minus those the subtract reaches. A plain user is also
        -- removed by its type's wildcard; the object's own userset stays; with
        -- diff_recheck the removed ones are checked with _fga_rec.
        return query
        with s(t, i, r) as materialized (
            select b.t, b.i, b.r
            from permissions._fga_backward(m, o.object_type, o.object_id, sub_rel, ctx, 25) b
            where sub_ts is null
          union
            select b.t, b.i, b.r
            from (select tu.user_type, tu.user_id
                  from permissions.fga_tuples tu
                  where tu.object_type = o.object_type and tu.object_id = o.object_id and tu.relation = sub_ts
                    and tu.user_relation = ''
                union
                  select x.user_type, x.user_id
                  from unnest(ctx) x
                  where x.object_type = o.object_type and x.object_id = o.object_id and x.relation = sub_ts
                    and x.user_relation = '') p
            join permissions.fga_type_restrictions tr
              on tr.model_id = m and tr.type = o.object_type and tr.relation = sub_ts
             and tr.user_type = p.user_type and tr.user_relation = '' and not tr.wildcard
            join permissions.fga_relations pr on pr.model_id = m and pr.type = p.user_type and pr.relation = sub_rel
            cross join lateral permissions._fga_backward(m, p.user_type, p.user_id, sub_rel, ctx, 25) b
            where sub_ts is not null and p.user_id <> '*'
        )
        select permissions._fga_user_string(k.t, k.i, k.r)
        from (select distinct b.t, b.i, b.r
              from permissions._fga_backward(m, o.object_type, o.object_id, _fga_list_users.relation, ctx, 25) b
              join unnest(user_filters) uf on b.t = split_part(uf, '#', 1) and b.r = split_part(uf, '#', 2)) k
        where case when (k.t, k.i, k.r) = (o.object_type, o.object_id, _fga_list_users.relation)
                     or not exists (select 1 from s
                                    where s.t = k.t and s.r = k.r and (s.i = k.i or (k.r = '' and s.i = '*')))
                   then true
                   when recheck
                   then permissions._fga_rec_ok(m, o.object_type, o.object_id, _fga_list_users.relation, k.t, k.i, k.r, ctx)
                   else false end;
        return;
    end if;
    for c in
        select distinct b.t, b.i, b.r
        from permissions._fga_backward(m, o.object_type, o.object_id, _fga_list_users.relation, ctx, 25) b
        join unnest(user_filters) uf on b.t = split_part(uf, '#', 1) and b.r = split_part(uf, '#', 2)
    loop
        if not mono then
            x := permissions._fga_rec(m, o.object_type, o.object_id, _fga_list_users.relation,
                                      c.t, c.i, c.r, ctx, 0, '{}');
            if x = 3 then
                perform permissions._fga_too_complex();
            end if;
            continue when x <> 1;
        end if;
        return next permissions._fga_user_string(c.t, c.i, c.r);
    end loop;
end;
$$;

-- ListUsers: at most 1,000 users (OpenFGA's cap, _fga_limits; the rest are
-- dropped silently, as OpenFGA does, and which ones survive is unspecified).
create function permissions.fga_list_users(object text, relation text, user_filters text[],
                                           contextual_tuples jsonb default null,
                                           authorization_model_id text default null)
returns setof text
language sql stable security definer
set search_path = ''
rows 100
as $$
    select u from permissions._fga_list_users($1, $2, $3, $4, $5) u
    limit (select l.list_max from permissions._fga_limits() l)
$$;

-- ----------------------------------------------------------------------------
-- Current subject: for clients and RLS policies (G1, G2)
-- ----------------------------------------------------------------------------
-- The user is current_subject_type():current_subject_id() (user:<JWT sub> on
-- Supabase). No subject, no model yet, or a subject type the model doesn't
-- define: false or nothing, so RLS denies instead of failing. An unknown
-- object type or relation still raises (2021/2022 or 2000), like OpenFGA.
-- No contextual tuples: a client could otherwise vouch for itself.

create function permissions._fga_current(out model_id text, out user_type text, out user_id text)
language plpgsql stable
as $$
begin
    user_id := permissions.current_subject_id();
    user_type := permissions.current_subject_type();
    select m.id into model_id from permissions.fga_models m order by m.seq desc limit 1;
    if user_id is null or user_id = '*' or model_id is null
       or not exists (select 1 from permissions.fga_types t where t.model_id = _fga_current.model_id and t.type = _fga_current.user_type) then
        model_id := null;
    end if;
end;
$$;

-- Per-row checks in RLS: using (permissions.fga_check_current('editor', 'document:' || id))
create function permissions.fga_check_current(relation text, object text)
returns boolean
language plpgsql stable security definer
set search_path = ''
set plan_cache_mode = force_generic_plan
as $$
declare
    s record;
    o record;
begin
    select * into s from permissions._fga_current();
    if s.model_id is null then
        return false;
    end if;
    select * into o from permissions._fga_parse_object(s.model_id, object, relation, 2000);
    return permissions._fga_check_impl(s.model_id, o.object_type, o.object_id, relation, s.user_type, s.user_id, '', '{}');
end;
$$;

-- 'type:id' strings
create function permissions.fga_list_objects_current(type text, relation text)
returns setof text
language plpgsql stable security definer
set search_path = ''
set plan_cache_mode = force_generic_plan
rows 100
as $$
declare
    s record;
begin
    select * into s from permissions._fga_current();
    if s.model_id is null then
        return;
    end if;
    perform permissions._fga_parse_object(s.model_id, fga_list_objects_current.type || ':x', relation, 2000);
    return query select fga_list_objects_current.type || ':' || x
    from permissions._fga_list_object_ids(s.model_id, fga_list_objects_current.type, relation,
                                          s.user_type, s.user_id, '', '{}') x;
end;
$$;

-- Bare ids, for the RLS fast path:
--   id = any (array(select permissions.fga_list_object_ids_current('document', 'viewer')::uuid))
-- A set-returning function is never evaluated at plan time (its row estimate
-- comes from `rows`), so it needs no _unfolded_null() argument.
create function permissions.fga_list_object_ids_current(type text, relation text)
returns setof text
language plpgsql stable security definer
set search_path = ''
set plan_cache_mode = force_generic_plan
rows 100
as $$
declare
    s record;
begin
    select * into s from permissions._fga_current();
    if s.model_id is null then
        return;
    end if;
    perform permissions._fga_parse_object(s.model_id, fga_list_object_ids_current.type || ':x', relation, 2000);
    return query select x from permissions._fga_list_object_ids(s.model_id, fga_list_object_ids_current.type, relation,
                                                                s.user_type, s.user_id, '', '{}') x;
end;
$$;

-- ============================================================================
-- Cleanup across models
-- ============================================================================

-- Forget a subject everywhere: its role assignments (user subjects) and every
-- FGA tuple naming it as user (any userset of it too) or as object.
create function permissions.delete_subject(p_subject_type text, p_subject_id text)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
    n bigint;
    k bigint;
begin
    delete from permissions.rbac_assignments where p_subject_type = 'user' and user_id = p_subject_id;
    get diagnostics n = row_count;
    delete from permissions.fga_tuples
    where (user_type = p_subject_type and user_id = p_subject_id)
       or (object_type = p_subject_type and object_id = p_subject_id);
    get diagnostics k = row_count;
    return n + k;
end;
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
    permissions._unfolded_null(),
    permissions.has_permission(text, text),
    permissions.has_role(text, text),
    permissions.scopes_with_permission(text, boolean),
    permissions.fga_check_current(text, text),
    permissions.fga_list_objects_current(text, text),
    permissions.fga_list_object_ids_current(text, text)
to public;

-- Everything else (role and model management, tuple writes, explicit-subject
-- checks and lists) is for the owner and whichever trusted roles the app
-- grants, e.g. service_role.
