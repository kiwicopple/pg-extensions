/*
 * pg_permissions
 *
 * Copyright (c) 2026 Paul Copplestone: https://github.com/kiwicopple/pg-extensions/
 *
 * Design: research/designs/d-per-model.md. Two independent models in one schema:
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
-- keeps the statement's snapshot). research/plan.md §4.
create function permissions._unfolded_null()
returns boolean
language plpgsql volatile
as $$
begin
    return null;
end;
$$;

-- Error hints (research/decision.md, end of session 4, point 5): every error has a
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
-- id). App-wide and scoped roles are separate: rbac_has_permission(p) looks
-- only at app-wide assignments, rbac_has_permission(p, scope) only at that
-- scope.
--
-- rbac_role_closure is maintained by rbac_create_role/rbac_drop_role: every
-- role a role includes, itself too. Roles can't change after creation and a
-- role can only inherit roles that exist, so the closure of a new role is its
-- parents' closures plus itself, and no other row ever changes.

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
        format('No roles exist yet: create it first, e.g. select permissions.rbac_create_role(role => %L, permissions => ''{documents.read}'').', p_role))
$$;

-- Parameters share names with the rbac_* columns (role, permission, scope,
-- user_id, inherits), so bodies qualify every parameter with the function's
-- name and every column with its table alias. PL/pgSQL's default
-- variable_conflict = error turns any unqualified clash into an error; the
-- SQL functions would silently read the column, so they qualify too.
create function permissions.rbac_create_role(role text, permissions text[], inherits text[] default '{}')
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    x text;
begin
    if rbac_create_role.role is null then
        raise exception 'role is required to create a role' using errcode = '22004',
            hint = 'Pass the name of the role as text, e.g. select permissions.rbac_create_role(role => ''editor'', permissions => ''{documents.edit}'').';
    end if;
    if rbac_create_role.permissions is null then
        raise exception 'permissions is required to create role ''%''', rbac_create_role.role using errcode = '22004',
            hint = format('Pass an array of permission names, or ''{}'' for a role that only inherits: select permissions.rbac_create_role(role => %L, permissions => ''{documents.read}'').', rbac_create_role.role);
    end if;
    if rbac_create_role.inherits is null then
        raise exception 'inherits must not be null for role ''%''', rbac_create_role.role using errcode = '22004',
            hint = format('Pass an array of role names, or omit inherits: select permissions.rbac_create_role(role => %L, permissions => ''{documents.read}'', inherits => ''{viewer}'').', rbac_create_role.role);
    end if;
    if exists (select 1 from permissions.rbac_roles r where r.role = rbac_create_role.role) then
        raise exception 'role ''%'' already exists', rbac_create_role.role using errcode = '23505',
            hint = format('Roles are immutable: pick another name, or rbac_drop_role(role => %L) and create it again (that also removes its assignments).', rbac_create_role.role);
    end if;
    select case when exists (select 1 from permissions.rbac_role_permissions rp where rp.permission = rbac_create_role.role)
                then format('%L is already a permission', rbac_create_role.role)
                when rbac_create_role.role = any (rbac_create_role.permissions)
                then format('role %L lists itself as a permission', rbac_create_role.role)
                else (select format('%L is already a role', r.role) from permissions.rbac_roles r
                      where r.role = any (rbac_create_role.permissions) order by r.role limit 1) end
    into x;
    if x is not null then
        raise exception 'role and permission names must not overlap: %', x using errcode = '22023',
            hint = 'rbac_has_role and rbac_has_permission share one namespace: use distinct names, e.g. a role ''editor'' with permissions like ''documents.edit''.';
    end if;
    select i into x from unnest(rbac_create_role.inherits) i
    where not exists (select 1 from permissions.rbac_roles r where r.role = i) limit 1;
    if x is not null then
        raise exception 'unknown role ''%'' in inherits of role ''%''', x, rbac_create_role.role using errcode = '22023',
            hint = permissions._rbac_role_hint(x);
    end if;

    insert into permissions.rbac_roles (role) values (rbac_create_role.role);
    insert into permissions.rbac_role_permissions (role, permission)
    select distinct rbac_create_role.role, p from unnest(rbac_create_role.permissions) p where p is not null;
    insert into permissions.rbac_role_inherits (role, inherits)
    select distinct rbac_create_role.role, i from unnest(rbac_create_role.inherits) i;
    insert into permissions.rbac_role_closure (role, includes)
    select rbac_create_role.role, rbac_create_role.role
    union
    select rbac_create_role.role, c.includes from permissions.rbac_role_closure c where c.role = any (rbac_create_role.inherits);
end;
$$;

create function permissions.rbac_drop_role(role text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    heirs text[];
begin
    if not exists (select 1 from permissions.rbac_roles r where r.role = rbac_drop_role.role) then
        raise exception 'unknown role ''%''', rbac_drop_role.role using errcode = '22023',
            hint = permissions._rbac_role_hint(rbac_drop_role.role);
    end if;
    heirs := array(select i.role from permissions.rbac_role_inherits i where i.inherits = rbac_drop_role.role order by i.role);
    if cardinality(heirs) > 0 then
        raise exception 'role ''%'' is inherited by %', rbac_drop_role.role,
            (select string_agg(format('%L', h), ', ') from unnest(heirs) h) using errcode = '2BP01',
            hint = format('Drop the roles that inherit it first (%s), or keep %L.',
                          (select string_agg(format('rbac_drop_role(role => %L)', h), ', ') from unnest(heirs) h), rbac_drop_role.role);
    end if;
    -- cascades to its permissions, inherits, closure rows and assignments
    delete from permissions.rbac_roles r where r.role = rbac_drop_role.role;
end;
$$;

create function permissions.rbac_assign_role(user_id text, role text, scope text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    if not exists (select 1 from permissions.rbac_roles r where r.role = rbac_assign_role.role) then
        raise exception 'unknown role ''%''', rbac_assign_role.role using errcode = '22023',
            hint = permissions._rbac_role_hint(rbac_assign_role.role);
    end if;
    if rbac_assign_role.user_id is null then
        raise exception 'user_id is required to assign role ''%''', rbac_assign_role.role using errcode = '22004',
            hint = format('Pass the user''s id as text, e.g. select permissions.rbac_assign_role(user_id => id::text, role => %L, scope => org_id::text).', rbac_assign_role.role);
    end if;
    insert into permissions.rbac_assignments (user_id, role, scope)
    values (rbac_assign_role.user_id, rbac_assign_role.role, rbac_assign_role.scope)
    on conflict on constraint rbac_assignments_key do nothing;
end;
$$;

create function permissions.rbac_unassign_role(user_id text, role text, scope text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    if rbac_unassign_role.user_id is null then
        raise exception 'user_id is required to unassign role ''%''', rbac_unassign_role.role using errcode = '22004',
            hint = format('Pass the user''s id as text, e.g. select permissions.rbac_unassign_role(user_id => id::text, role => %L, scope => org_id::text).', rbac_unassign_role.role);
    end if;
    if rbac_unassign_role.role is null then
        raise exception 'role is required to unassign a role' using errcode = '22004',
            hint = 'Pass the name of the role as text, e.g. select permissions.rbac_unassign_role(user_id => id::text, role => ''editor'').';
    end if;
    if rbac_unassign_role.scope is null then
        delete from permissions.rbac_assignments a
        where a.user_id = rbac_unassign_role.user_id and a.role = rbac_unassign_role.role and a.scope is null;
    else
        delete from permissions.rbac_assignments a
        where a.user_id = rbac_unassign_role.user_id and a.role = rbac_unassign_role.role and a.scope = rbac_unassign_role.scope;
    end if;
end;
$$;

-- Checks for the current subject. Roles are held by `user` subjects; any other
-- subject type has none. PL/pgSQL so the plans are cached per session
-- (research/plan.md §4); app-wide and scoped lookups are separate statements so each
-- one probes rbac_assignments_key directly.
create function permissions.rbac_has_permission(permission text, scope text default null)
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
    if rbac_has_permission.scope is null then
        return exists (
            select 1
            from permissions.rbac_assignments a
            join permissions.rbac_role_closure c on c.role = a.role
            join permissions.rbac_role_permissions p on p.role = c.includes
            where a.user_id = uid and a.scope is null and p.permission = rbac_has_permission.permission);
    end if;
    return exists (
        select 1
        from permissions.rbac_assignments a
        join permissions.rbac_role_closure c on c.role = a.role
        join permissions.rbac_role_permissions p on p.role = c.includes
        where a.user_id = uid and a.scope = rbac_has_permission.scope and p.permission = rbac_has_permission.permission);
end;
$$;

create function permissions.rbac_has_role(role text, scope text default null)
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
    if rbac_has_role.scope is null then
        return exists (
            select 1
            from permissions.rbac_assignments a
            join permissions.rbac_role_closure c on c.role = a.role
            where a.user_id = uid and a.scope is null and c.includes = rbac_has_role.role);
    end if;
    return exists (
        select 1
        from permissions.rbac_assignments a
        join permissions.rbac_role_closure c on c.role = a.role
        where a.user_id = uid and a.scope = rbac_has_role.scope and c.includes = rbac_has_role.role);
end;
$$;

-- The RLS fast path for tenant scoping:
--   org_id = any (array(select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid))
-- plan_time_guard is ignored: its volatile default keeps the call out of
-- plan-time evaluation (see _unfolded_null); don't pass it. Unordered.
create function permissions.rbac_scopes_with_permission(permission text,
                                                        plan_time_guard boolean default permissions._unfolded_null())
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
        where a.user_id = uid and a.scope is not null and p.permission = rbac_scopes_with_permission.permission);
end;
$$;

-- Admin and debugging (not callable by clients)
create function permissions.rbac_user_permissions(user_id text, scope text default null)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select coalesce(array_agg(distinct p.permission order by p.permission), '{}')
    from permissions.rbac_assignments a
    join permissions.rbac_role_closure c on c.role = a.role
    join permissions.rbac_role_permissions p on p.role = c.includes
    where a.user_id = rbac_user_permissions.user_id and a.scope is not distinct from rbac_user_permissions.scope
$$;

create function permissions.rbac_users_with_role(role text, scope text default null)
returns setof text
language sql stable security definer
set search_path = ''
as $$
    select distinct a.user_id
    from permissions.rbac_role_closure c
    join permissions.rbac_assignments a on a.role = c.role
    where c.includes = rbac_users_with_role.role and a.scope is not distinct from rbac_users_with_role.scope
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
-- Ids, types and relations are collate "C" (research/plan.md §4).

create type permissions.fga_tuple as (
    object_type   text collate "C",
    object_id     text collate "C",
    relation      text collate "C",
    user_type     text collate "C",
    user_id       text collate "C",   -- '*' for a typed wildcard (user:*)
    user_relation text collate "C",   -- '' unless the user is a userset (group:x#member)
    condition_name    text collate "C",   -- '' unless the tuple has a condition
    condition_context jsonb               -- its context ({} if none given); null without a condition
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
    -- not monotone, and ListObjects evaluates its rewrite tree set-based
    -- (_fga_set_rel; see fga_write_authorization_model): every leaf is a
    -- walk, combined by union, intersection and difference
    set_eval      boolean not null default false,
    -- a conditioned type restriction (or tupleset restriction) is reachable
    -- from it through any operand: evaluations take the conditional path.
    -- False: today's statements, no condition is ever evaluated.
    conditional   boolean not null default false,
    primary key (model_id, type, relation),
    foreign key (model_id, type) references permissions.fga_types on delete cascade
);

-- directly_related_user_types: [user], [user:*], [group#member], [user with c]
-- ([user, user with c] is two rows)
create table permissions.fga_type_restrictions (
    model_id      text collate "C" not null,
    type          text collate "C" not null,
    relation      text collate "C" not null,
    user_type     text collate "C" not null,
    user_relation text collate "C" not null default '',
    wildcard      boolean not null default false,
    condition     text collate "C" not null default '',   -- '' none
    primary key (model_id, type, relation, user_type, user_relation, wildcard, condition),
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
-- condition: the type restriction's condition (d) or the tupleset
-- restriction's (t), '' for none; an edge per allowed condition, so a tuple
-- matches exactly one edge (tuple.condition_name = edge.condition), and a
-- tuple whose condition the model doesn't allow for its facet matches none.
create table permissions.fga_edges (
    model_id     text collate "C" not null references permissions.fga_models on delete cascade,
    kind         "char" not null check (kind in ('d', 'c', 't')),
    dst_type     text collate "C" not null,
    dst_relation text collate "C" not null,
    src_type     text collate "C" not null,
    src_relation text collate "C" not null,
    src_wildcard boolean not null default false,
    via          text collate "C",
    condition    text collate "C" not null default ''
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
    expand          boolean not null default false,
    condition       text collate "C" not null default ''   -- the edge's condition
);
create index on permissions.fga_walk_steps (model_id, target_type, target_relation);

-- The model's conditions, compiled when the model is written
-- (research/designs/d-conditions.md): parameters as CEL types ({"x": "int", "l":
-- ["list", "string"]}), ast the typed tree _fga_cel_eval walks.
create table permissions.fga_conditions (
    model_id   text collate "C" not null references permissions.fga_models on delete cascade,
    name       text collate "C" not null,
    expression text not null,
    parameters jsonb not null,
    ast        jsonb not null,
    primary key (model_id, name)
);

create table permissions.fga_tuples (
    object_type   text collate "C" not null,
    object_id     text collate "C" not null,
    relation      text collate "C" not null,
    user_type     text collate "C" not null,
    user_id       text collate "C" not null,
    user_relation text collate "C" not null default '',
    -- the tuple's condition: not part of the key (OpenFGA's isn't either)
    condition_name    text collate "C" not null default '',
    condition_context jsonb,   -- {} for a condition without context, null without a condition
    inserted_at   timestamptz not null default now(),
    seq           bigint generated always as identity,  -- insertion order: Read's page order and continuation token
    primary key (object_type, object_id, relation, user_type, user_id, user_relation)
);
create index fga_tuples_user_idx on permissions.fga_tuples (user_type, user_id, user_relation, object_type, relation);
create unique index fga_tuples_seq_idx on permissions.fga_tuples (seq);
-- The userset tuples of an object's relation, for the backward step of Check
-- (_fga_bstep): without it, finding the one nested team among a team's
-- thousand members reads all thousand (the primary key has user_id before
-- user_relation). Partial: plain users and wildcards, most tuples, aren't in
-- it (phase 5 of session 5).
create index fga_tuples_userset_idx on permissions.fga_tuples (object_type, object_id, relation, user_type, user_relation)
    where user_relation <> '';

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
-- (invalid_parameter_value) for every other code.
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
            when 2047 then 'type_invalid_pattern'
            when 2050 then 'relations_invalid_pattern'
            when 2053 then 'exceeded_entity_limit'
            when 2056 then 'invalid_authorization_model'
            when 2057 then 'unsupported_schema_version'
            else 'error' end,
        hint = _fga_error.hint;
end;
$$;

-- The request's condition context (OpenFGA's `context`): a JSON object, or
-- null for none ({}).
create function permissions._fga_req_context(p_context jsonb)
returns jsonb
language plpgsql immutable
as $$
begin
    if p_context is null or jsonb_typeof(p_context) = 'null' then
        return '{}';
    end if;
    if jsonb_typeof(p_context) <> 'object' then
        perform permissions._fga_error(2000, format('invalid context: must be a JSON object of condition parameters, got a JSON %s', jsonb_typeof(p_context)),
            hint => 'Pass context => ''{"x": 10, "user_ip": "10.0.0.1"}''::jsonb (the parameters of the conditions to evaluate), or omit it.');
    end if;
    return p_context;
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
                                  || case when tr.user_relation <> '' then '#' || tr.user_relation else '' end
                                  || case when tr.condition <> '' then ' with ' || tr.condition else '' end,
                                  ', ' order by tr.user_type, tr.wildcard, tr.user_relation, tr.condition))
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
        (select format('Model ids, newest first: %s%s. Omit model_id to use the latest.',
                       string_agg(m.id, ', ' order by m.seq desc) filter (where m.rn <= 10),
                       case when count(*) > 10 then format(' and %s more', count(*) - 10) end)
         from (select x.id, x.seq, row_number() over (order by x.seq desc) as rn from permissions.fga_models x) m
         having count(*) > 0),
        'No authorization model exists yet: write one first with select permissions.fga_write_authorization_model(model => ...).')
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

-- The typed write path (phase 5 of session 5): a tuple key from its three
-- strings, split as _fga_split_object and _fga_split_user do, without
-- validating anything against a model (object_id may be '*'). All fields null
-- if either string is malformed; the relation is copied as given.
create function permissions._fga_typed_key(p_user text, p_relation text, p_object text)
returns permissions.fga_tuple
language plpgsql immutable
as $$
declare
    t permissions.fga_tuple;
begin
    if p_object ~ '^[^:# [:cntrl:]]+:[^:# [:cntrl:]]+$' then
        if p_user ~ '^[^:# [:cntrl:]]+:[^:# [:cntrl:]]+$' then
            t := row(split_part(p_object, ':', 1), substr(p_object, strpos(p_object, ':') + 1), p_relation,
                     split_part(p_user, ':', 1), substr(p_user, strpos(p_user, ':') + 1), '', '', null);
        elsif p_user ~ '^[^:# [:cntrl:]]+:[^:#* [:cntrl:]]+#[^:#* [:cntrl:]]+$' then
            t := row(split_part(p_object, ':', 1), substr(p_object, strpos(p_object, ':') + 1), p_relation,
                     split_part(p_user, ':', 1), split_part(substr(p_user, strpos(p_user, ':') + 1), '#', 1),
                     split_part(p_user, '#', 2), '', null);
        end if;
    end if;
    return t;
end;
$$;

-- The typed write path's validation in one lookup: an unconditioned type
-- restriction of model p_m allows the key. That is everything
-- _fga_tuple_for_write checks for a key without a condition: a restriction
-- names only types and relations the model defines, and a tupleset
-- relation's restrictions are plain types (fga_write_authorization_model
-- rejects wildcards and usersets there), so true means it would accept the
-- key; false means "ask _fga_tuple_for_write", which finds the error.
create function permissions._fga_write_key_ok(p_m text, p_ot text, p_rel text, p_ut text, p_uid text, p_urel text)
returns boolean
language plpgsql stable
as $$
begin
    return exists (
        select 1
        from permissions.fga_type_restrictions tr
        where tr.model_id = p_m and tr.type = p_ot and tr.relation = p_rel
          and tr.user_type = p_ut and tr.user_relation = p_urel and tr.wildcard = (p_uid = '*')
          and tr.condition = '');
end;
$$;

-- validation.ValidateTupleForWrite: the tuple key is well formed and allowed by
-- the model's type restrictions. Raises p_code (2027 for writes and
-- contextual tuples). Then its condition ({"name", "context"}, optional):
-- defined in the model, allowed for the tuple's facet (a tuple without one
-- needs a restriction without one), context keys that are parameters, values
-- of their types (validation.go validateCondition). Raises p_cond_code: 2000
-- for writes and for ListObjects' and ListUsers' contextual tuples, 2027 for
-- Check's (OpenFGA wraps every contextual tuple error in Check).
create function permissions._fga_tuple_for_write(p_m text, p_key jsonb, p_code int, p_cond_code int default null)
returns permissions.fga_tuple
language plpgsql stable
as $$
declare
    u record;
    o record;
    t permissions.fga_tuple;
    k text := format('%s#%s@%s', p_key ->> 'object', p_key ->> 'relation', p_key ->> 'user');
    h text;
    cd jsonb;
    cp jsonb;
    bad text;
    x record;
begin
    -- the typed path: a key without a condition that an unconditioned
    -- restriction allows (one lookup instead of six)
    if jsonb_typeof(p_key) = 'object' and coalesce(jsonb_typeof(p_key -> 'condition'), 'null') = 'null' then
        t := permissions._fga_typed_key(p_key ->> 'user', p_key ->> 'relation', p_key ->> 'object');
        if t.object_id <> '*' and permissions._fga_write_key_ok(p_m, t.object_type, t.relation, t.user_type, t.user_id, t.user_relation) then
            return t;
        end if;
    end if;
    if jsonb_typeof(p_key) <> 'object' then
        perform permissions._fga_error(p_code, format('invalid tuple key: %s', p_key),
            hint => 'A tuple key is a JSON object: {"user": "user:anne", "relation": "viewer", "object": "document:1"}.');
    end if;
    begin
        select * into u from permissions._fga_parse_user(p_m, p_key ->> 'user', p_code);
        select * into o from permissions._fga_parse_object(p_m, p_key ->> 'object', p_key ->> 'relation', p_code);
    exception when invalid_parameter_value then
        get stacked diagnostics h = pg_exception_hint;
        perform permissions._fga_error(p_code, format('Invalid tuple ''%s''. Reason: %s', k, sqlerrm), hint => h);
    end;
    t := row(o.object_type, o.object_id, p_key ->> 'relation', u.user_type, u.user_id, u.user_relation, '', null);
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

    -- the condition
    cd := case when jsonb_typeof(p_key -> 'condition') = 'null' then null else p_key -> 'condition' end;
    if cd is not null then
        if jsonb_typeof(cd) <> 'object' or jsonb_typeof(cd -> 'name') is distinct from 'string' then
            bad := format('the condition must be {"name": "...", "context": {...}}, got %s', cd);
        elsif char_length(cd ->> 'name') not between 2 and 256 or cd ->> 'name' ~ '[[:space:]]' then
            bad := format('invalid RelationshipCondition.Name %L: value does not match regex pattern "^[^\s]{2,256}$"', cd ->> 'name');
        elsif coalesce(jsonb_typeof(cd -> 'context'), 'null') not in ('object', 'null') then
            bad := format('the condition context must be a JSON object, got a JSON %s', jsonb_typeof(cd -> 'context'));
        else
            t.condition_name := cd ->> 'name';
            t.condition_context := case when jsonb_typeof(cd -> 'context') = 'object' then cd -> 'context' else '{}' end;
        end if;
    end if;
    if bad is null and t.condition_name <> '' then
        select c.parameters into cp from permissions.fga_conditions c where c.model_id = p_m and c.name = t.condition_name;
        if cp is null then
            bad := format('undefined condition ''%s''', t.condition_name);
        end if;
    end if;
    if bad is null and not exists (
        select 1 from permissions.fga_type_restrictions tr
        where tr.model_id = p_m and tr.type = t.object_type and tr.relation = t.relation
          and tr.user_type = t.user_type and tr.user_relation = t.user_relation
          and tr.wildcard = (t.user_id = '*') and tr.condition = t.condition_name) then
        bad := case when t.condition_name = '' then 'condition is missing'
                    else format('invalid condition ''%s'' for type restriction', t.condition_name) end;
    end if;
    if bad is null and t.condition_name <> '' then
        for x in select * from jsonb_each(t.condition_context) loop
            if not cp ? x.key then
                bad := format('found invalid context parameter: %s', x.key);
            elsif (permissions._fga_cel_convert(cp -> x.key, x.value)).e is not null then
                bad := format('failed to convert context parameter ''%s'': %s', x.key,
                              (permissions._fga_cel_convert(cp -> x.key, x.value)).e);
            end if;
            exit when bad is not null;
        end loop;
    end if;
    if bad is not null then
        perform permissions._fga_error(coalesce(p_cond_code, p_code), format('Invalid tuple ''%s''. Reason: %s', k, bad),
            hint => case when bad like 'condition is missing' or bad like 'invalid condition%'
                         then permissions._fga_allowed_hint(p_m, t.object_type, t.relation) || ' Name the condition the restriction allows: {"user": ..., "condition": {"name": "...", "context": {...}}}.'
                         when cp is not null
                         then format('Condition ''%s'' takes the parameters: %s. The context holds some of them, with values of their types.', t.condition_name,
                                     coalesce((select string_agg(e.key || ' ' || permissions._fga_cel_tname(e.value), ', ' order by e.key) from jsonb_each(cp) e), 'none'))
                         else format('A condition is {"name": "...", "context": {...}}, the name one of the model''s conditions: %s.',
                                     coalesce((select string_agg(c.name, ', ' order by c.name) from permissions.fga_conditions c where c.model_id = p_m), 'none')) end);
    end if;
    return t;
end;
$$;

-- Contextual tuples: an array of tuple keys, or {"tuple_keys": [...]}.
-- Validated like writes (2027; their conditions p_cond_code, see
-- _fga_tuple_for_write); duplicates collapse.
create function permissions._fga_ctx(p_m text, p_ctx jsonb, p_cond_code int default 2027)
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
        select distinct permissions._fga_tuple_for_write(p_m, e, 2027, p_cond_code)
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
                hint => 'Write a model first: select permissions.fga_write_authorization_model(model => ''{"schema_version": "1.1", "type_definitions": [...]}'').');
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
-- Conditions (CEL): compiler and evaluator
-- ----------------------------------------------------------------------------
-- research/designs/d-conditions.md. A model's conditions are compiled when the model is
-- written: tokens, a precedence-climbing parser, macro expansion and a type
-- checker that resolves every operator to one overload, stored as a jsonb AST
-- in fga_conditions (no parsing at Check time, no generated functions). The
-- evaluator walks that tree over typed values with CEL's error semantics:
-- `||` and `&&` absorb an error when the other side decides, everything else
-- propagates it. Errors are values (fga_cel_result.e), not exceptions.
--
-- Types are jsonb: "int", "uint", "double", "bool", "string", "null",
-- "timestamp", "duration", "ipaddress", "dyn" (OpenFGA's `any`, and anything
-- whose type is only known at run time), ["list", T], ["map", K, V].
-- Values are jsonb in a canonical form per type: numbers for int, uint and
-- double (a double through float8's shortest text), durations as integer
-- nanoseconds, timestamps as 'YYYY-MM-DDTHH:MI:SS.USZ' in UTC (so text order is
-- time order), ip addresses as their text, lists as arrays, maps as objects
-- keyed by the key's text. A value of type dyn is plain JSON: a number is a
-- double, as in OpenFGA's JSON context.

create type permissions.fga_cel_result as (
    v jsonb,   -- the value (canonical form of the node's type)
    e text,    -- an error message, else null
    c int      -- cost so far (research/designs/d-conditions.md section 6, cost limit)
);

-- OpenFGA's cost limit (pkg/server/config/config.go: MaxConditionEvaluationCost
-- 100), approximated: 1 per identifier, call, operator, selection and index
-- evaluated (literals and the logical operators cost nothing, as in cel-go),
-- plus 3 per comprehension iteration. cel-go counts differently (strings by
-- size, for one), so the threshold matches only roughly: `l.exists(e, e ==
-- "zzz")` passes over 19 elements and fails over 20 here; OpenFGA v1.22.1
-- passes over 10 and fails over 20 (test/fga_abac/probe.sh, P38).
create function permissions._fga_cel_cost_limit()
returns int
language sql immutable
as $$ select 100 $$;

-- A type for messages: int, list(string), map(string, int).
create function permissions._fga_cel_tname(t jsonb)
returns text
language plpgsql immutable
as $$
begin
    if jsonb_typeof(t) = 'array' then
        if t ->> 0 = 'list' then
            return 'list(' || permissions._fga_cel_tname(t -> 1) || ')';
        end if;
        return 'map(' || permissions._fga_cel_tname(t -> 1) || ', ' || permissions._fga_cel_tname(t -> 2) || ')';
    end if;
    return t #>> '{}';
end;
$$;

-- The type both a and b fit (dyn joins anything), or null.
create function permissions._fga_cel_tjoin(a jsonb, b jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
    x jsonb;
    y jsonb;
begin
    if a = b then
        return a;
    end if;
    if a = '"dyn"' or b = '"dyn"' then
        return '"dyn"';
    end if;
    if jsonb_typeof(a) = 'array' and jsonb_typeof(b) = 'array' and a ->> 0 = b ->> 0 then
        x := permissions._fga_cel_tjoin(a -> 1, b -> 1);
        if a ->> 0 = 'list' then
            return case when x is null then null else jsonb_build_array('list', x) end;
        end if;
        y := permissions._fga_cel_tjoin(a -> 2, b -> 2);
        return case when x is null or y is null then null else jsonb_build_array('map', x, y) end;
    end if;
    return null;
end;
$$;

-- An OpenFGA parameter type ({"type_name": "TYPE_NAME_INT"}, generic_types
-- for maps and lists) as a CEL type, or {"err": message} (objects are never
-- types).
create function permissions._fga_cel_ptype(p jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
    tn text := p ->> 'type_name';
    g jsonb;
begin
    if jsonb_typeof(p) is distinct from 'object' then
        return jsonb_build_object('err', format('a parameter type must be an object {"type_name": ...}, got %s', coalesce(p::text, 'nothing')));
    end if;
    if tn in ('TYPE_NAME_LIST', 'TYPE_NAME_MAP') then
        if jsonb_typeof(p -> 'generic_types') is distinct from 'array' or jsonb_array_length(p -> 'generic_types') <> 1 then
            return jsonb_build_object('err', format('%s requires exactly one generic type (generic_types), got %s',
                                                    tn, coalesce(p -> 'generic_types', '[]')));
        end if;
        g := permissions._fga_cel_ptype(p #> '{generic_types,0}');
        if jsonb_typeof(g) = 'object' then
            return g;
        end if;
        return case tn when 'TYPE_NAME_LIST' then jsonb_build_array('list', g) else jsonb_build_array('map', 'string', g) end;
    end if;
    if jsonb_typeof(p -> 'generic_types') = 'array' and jsonb_array_length(p -> 'generic_types') > 0 then
        return jsonb_build_object('err', format('%s takes no generic types', tn));
    end if;
    return case tn
        when 'TYPE_NAME_ANY' then '"dyn"'
        when 'TYPE_NAME_BOOL' then '"bool"'
        when 'TYPE_NAME_STRING' then '"string"'
        when 'TYPE_NAME_INT' then '"int"'
        when 'TYPE_NAME_UINT' then '"uint"'
        when 'TYPE_NAME_DOUBLE' then '"double"'
        when 'TYPE_NAME_DURATION' then '"duration"'
        when 'TYPE_NAME_TIMESTAMP' then '"timestamp"'
        when 'TYPE_NAME_IPADDRESS' then '"ipaddress"'
        when 'TYPE_NAME_BYTES' then jsonb_build_object('err', 'the bytes parameter type is not supported', 'tier3', true)
        else jsonb_build_object('err', format('unknown condition parameter type %s', coalesce(p ->> 'type_name', p::text)))
        end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tokens
-- ---------------------------------------------------------------------------
-- Kinds: id, int, uint, dbl, str, bool, null, the punctuators themselves
-- (|| && == != < <= > >= + - * / % ! ? : . , [ ] ( ) { } in), and eof.
-- v holds the value: digits for numbers (decimal; hex is converted), the
-- decoded text of a string. err is a message with the column, else null.
create function permissions._fga_cel_tokens(p_src text, out k text[], out v text[], out pos int[], out err text)
language plpgsql immutable
as $$
declare
    n int := length(p_src);
    i int := 1;
    ch text;
    rest text;
    m text;
    q text;
    is_raw boolean;
    is_bytes boolean;
    s text;
    c text;
    e text;
    h text;
    cp bigint;
    start int;
begin
    k := '{}'; v := '{}'; pos := '{}';
    while i <= n loop
        ch := substr(p_src, i, 1);
        if ch in (' ', E'\t', E'\n', E'\r', E'\f') then
            i := i + 1;
            continue;
        end if;
        rest := substr(p_src, i);
        if left(rest, 2) = '//' then
            if strpos(rest, E'\n') = 0 then
                exit;
            end if;
            i := i + strpos(rest, E'\n');
            continue;
        end if;
        start := i;
        -- numbers
        if ch ~ '[0-9]' or (ch = '.' and substr(p_src, i + 1, 1) ~ '[0-9]') then
            m := substring(rest from '^(0[xX][0-9a-fA-F]+[uU]?|[0-9]*\.[0-9]+(?:[eE][+-]?[0-9]+)?|[0-9]+[eE][+-]?[0-9]+|[0-9]+[uU]?)');
            i := i + length(m);
            if substr(p_src, i, 1) ~ '[A-Za-z_0-9.]' then
                err := format('Syntax error: invalid number %L at column %s', m || substr(p_src, i, 1), start);
                return;
            end if;
            if m ~* '^0x' then
                h := lower(regexp_replace(substr(m, 3), '[uU]$', ''));
                if length(ltrim(h, '0')) > 16 then
                    err := format('Syntax error: integer literal %s out of range at column %s', m, start);
                    return;
                end if;
                cp := 0;
                s := '0';
                foreach c in array regexp_split_to_array(h, '') loop
                    s := (s::numeric * 16 + strpos('0123456789abcdef', c) - 1)::text;
                end loop;
                k := k || case when m ~ '[uU]$' then 'uint' else 'int' end;
                v := v || s;
            elsif m ~ '[uU]$' then
                k := k || 'uint'::text;
                v := v || left(m, -1);
            elsif m ~ '[.eE]' then
                k := k || 'dbl'::text;
                v := v || m;
            else
                k := k || 'int'::text;
                v := v || m;
            end if;
            pos := pos || start;
            continue;
        end if;
        -- strings: optional r/R (raw) or b/B (bytes) prefix, then ' " ''' """
        m := substring(rest from '^([rRbB]{0,2})(?:''''''|"""|''|")');
        if m is not null and (m = '' or m ~ '^([rR]|[bB]|[rR][bB]|[bB][rR])$') then
            is_raw := m ~ '[rR]';
            is_bytes := m ~ '[bB]';
            i := i + length(m);
            q := case when substr(p_src, i, 3) in ('''''''', '"""') then substr(p_src, i, 3) else substr(p_src, i, 1) end;
            i := i + length(q);
            if is_bytes then
                err := format('bytes literals are not supported (column %s)', start);
                return;
            end if;
            s := '';
            loop
                if i > n then
                    err := format('Syntax error: unterminated string starting at column %s', start);
                    return;
                end if;
                if substr(p_src, i, length(q)) = q then
                    i := i + length(q);
                    exit;
                end if;
                c := substr(p_src, i, 1);
                if c = E'\n' and length(q) = 1 then
                    err := format('Syntax error: newline in a string starting at column %s (use a triple-quoted string)', start);
                    return;
                end if;
                if c = '\' and not is_raw then
                    e := substr(p_src, i + 1, 1);
                    if e in ('\', '"', '''', '`', '?') then
                        s := s || e; i := i + 2;
                    elsif e in ('a', 'b', 'f', 'n', 'r', 't', 'v') then
                        s := s || chr(case e when 'a' then 7 when 'b' then 8 when 'f' then 12 when 'n' then 10
                                             when 'r' then 13 when 't' then 9 else 11 end);
                        i := i + 2;
                    elsif e in ('x', 'X', 'u', 'U') or e ~ '[0-3]' then
                        h := case when e in ('x', 'X') then substr(p_src, i + 2, 2)
                                  when e = 'u' then substr(p_src, i + 2, 4)
                                  when e = 'U' then substr(p_src, i + 2, 8)
                                  else substr(p_src, i + 1, 3) end;
                        if (e ~ '[0-3]' and h !~ '^[0-7]{3}$')
                           or (e !~ '[0-3]' and h !~ ('^[0-9a-fA-F]{' || case when e in ('x', 'X') then 2 when e = 'u' then 4 else 8 end || '}$')) then
                            err := format('Syntax error: invalid escape sequence in the string at column %s', start);
                            return;
                        end if;
                        if e ~ '[0-3]' then
                            cp := (substr(h, 1, 1)::int * 64 + substr(h, 2, 1)::int * 8 + substr(h, 3, 1)::int);
                            i := i + 4;
                        else
                            cp := 0;
                            foreach c in array regexp_split_to_array(lower(h), '') loop
                                cp := cp * 16 + strpos('0123456789abcdef', c) - 1;
                            end loop;
                            i := i + 2 + length(h);
                        end if;
                        if cp = 0 or cp > 1114111 or cp between 55296 and 57343 then
                            err := format('Syntax error: invalid code point in the string at column %s', start);
                            return;
                        end if;
                        s := s || chr(cp::int);
                    else
                        err := format('Syntax error: invalid escape sequence ''\%s'' in the string at column %s', e, start);
                        return;
                    end if;
                else
                    s := s || c;
                    i := i + 1;
                end if;
            end loop;
            k := k || 'str'::text; v := v || s; pos := pos || start;
            continue;
        end if;
        -- identifiers and keywords
        m := substring(rest from '^[A-Za-z_][A-Za-z0-9_]*');
        if m is not null then
            i := i + length(m);
            if m in ('true', 'false') then
                k := k || 'bool'::text; v := v || m;
            elsif m = 'null' then
                k := k || 'null'::text; v := v || m;
            elsif m = 'in' then
                k := k || 'in'::text; v := v || m;
            elsif m in ('as', 'break', 'const', 'continue', 'else', 'for', 'function', 'if', 'import', 'let', 'loop',
                        'package', 'namespace', 'return', 'var', 'void', 'while') then
                err := format('Syntax error: reserved identifier %L at column %s', m, start);
                return;
            else
                k := k || 'id'::text; v := v || m;
            end if;
            pos := pos || start;
            continue;
        end if;
        m := case when left(rest, 2) in ('||', '&&', '==', '!=', '<=', '>=') then left(rest, 2)
                  when ch in ('<', '>', '+', '-', '*', '/', '%', '!', '?', ':', '.', ',', '[', ']', '(', ')', '{', '}') then ch end;
        if m is null then
            err := format('Syntax error: unexpected character %L at column %s', ch, start);
            return;
        end if;
        k := k || m; v := v || m; pos := pos || start;
        i := i + length(m);
    end loop;
    k := k || 'eof'::text; v := v || ''::text; pos := pos || (n + 1);
end;
$$;

-- ---------------------------------------------------------------------------
-- Parser: CEL's grammar by precedence, one recursive function
-- ---------------------------------------------------------------------------
--   lvl 0  Expr    = Or [ "?" Or ":" Expr ]
--   lvl 1  Or      = And { "||" And }
--   lvl 2  And     = Rel { "&&" Rel }
--   lvl 3  Rel     = Add { ("<" | "<=" | ">=" | ">" | "==" | "!=" | "in") Add }
--   lvl 4  Add     = Mul { ("+" | "-") Mul }
--   lvl 5  Mul     = Unary { ("*" | "/" | "%") Unary }
--   lvl 6  Unary   = Member | "!" {"!"} Member | "-" {"-"} Member
--   lvl 7  Member  = Primary { "." IDENT [ "(" [Args] ")" ] | "[" Expr "]" }
--          Primary = IDENT [ "(" [Args] ")" ] | "(" Expr ")" | "[" [Args] [","] "]"
--                  | "{" [Inits] [","] "}" | LITERAL
-- Untyped nodes: lit {t, v}, id {n}, call {f, a} (operators: ! neg + - * / %
-- < <= > >= == != in [] ; global functions by name), mcall {f, a: [receiver,
-- args...]}, sel {f, a: [operand]}, or, and, cond, list, map {a: [k1, v1, ...]}.
-- Every node has p, its column. An error is {k: err, m, h}.
create function permissions._fga_cel_parse(k text[], v text[], pos int[], p int, lvl int,
                                           out node jsonb, out np int)
language plpgsql immutable
as $$
declare
    x jsonb;
    y jsonb;
    z jsonb;
    q int;
    op text;
    ops text[];
    cnt int;
    args jsonb;
    name text;
    sh constant text := 'Check the expression''s CEL syntax (https://github.com/google/cel-spec/blob/master/doc/langdef.md), e.g. x < 100 || user_ip.in_cidr("10.0.0.0/8").';
begin
    if lvl = 0 then
        select r.node, r.np into x, q from permissions._fga_cel_parse(k, v, pos, p, 1) r;
        if x ->> 'k' = 'err' or k[q] <> '?' then
            node := x; np := q; return;
        end if;
        cnt := pos[q];
        select r.node, r.np into y, q from permissions._fga_cel_parse(k, v, pos, q + 1, 1) r;
        if y ->> 'k' = 'err' then node := y; np := q; return; end if;
        if k[q] <> ':' then
            node := jsonb_build_object('k', 'err', 'm', format('Syntax error: expected '':'' at column %s, found %L', pos[q], v[q]), 'h', sh);
            np := q; return;
        end if;
        select r.node, r.np into z, q from permissions._fga_cel_parse(k, v, pos, q + 1, 0) r;
        if z ->> 'k' = 'err' then node := z; np := q; return; end if;
        node := jsonb_build_object('k', 'cond', 'p', cnt, 'a', jsonb_build_array(x, y, z));
        np := q;
        return;
    end if;

    if lvl between 1 and 5 then
        ops := case lvl when 1 then '{||}' when 2 then '{&&}' when 3 then '{<,<=,>,>=,==,!=,in}'
                        when 4 then '{+,-}' else '{*,/,%}' end::text[];
        select r.node, r.np into x, q from permissions._fga_cel_parse(k, v, pos, p, lvl + 1) r;
        if x ->> 'k' = 'err' then node := x; np := q; return; end if;
        while k[q] = any (ops) loop
            op := k[q];
            cnt := pos[q];
            select r.node, r.np into y, q from permissions._fga_cel_parse(k, v, pos, q + 1, lvl + 1) r;
            if y ->> 'k' = 'err' then node := y; np := q; return; end if;
            x := case op when '||' then jsonb_build_object('k', 'or', 'p', cnt, 'a', jsonb_build_array(x, y))
                         when '&&' then jsonb_build_object('k', 'and', 'p', cnt, 'a', jsonb_build_array(x, y))
                         else jsonb_build_object('k', 'call', 'f', op, 'p', cnt, 'a', jsonb_build_array(x, y)) end;
        end loop;
        node := x; np := q;
        return;
    end if;

    if lvl = 6 then
        if k[p] in ('!', '-') then
            op := k[p];
            cnt := 0;
            q := p;
            while k[q] = op loop
                cnt := cnt + 1;
                q := q + 1;
            end loop;
            -- a minus sign directly before a number is part of the literal
            if op = '-' and k[q] in ('int', 'dbl') then
                q := q - 1;
                cnt := cnt - 1;
            end if;
            select r.node, r.np into x, np from permissions._fga_cel_parse(k, v, pos, q, 7) r;
            if x ->> 'k' = 'err' or cnt % 2 = 0 then
                node := x; return;
            end if;
            node := jsonb_build_object('k', 'call', 'f', case op when '!' then '!' else 'neg' end, 'p', pos[p], 'a', jsonb_build_array(x));
            return;
        end if;
        select r.node, r.np into node, np from permissions._fga_cel_parse(k, v, pos, p, 7) r;
        return;
    end if;

    -- lvl 7: Primary, then member suffixes
    q := p;
    if k[q] = '-' and k[q + 1] in ('int', 'dbl') then
        x := jsonb_build_object('k', 'lit', 't', case k[q + 1] when 'int' then 'int' else 'double' end, 's', '-' || v[q + 1], 'p', pos[q]);
        q := q + 2;
    elsif k[q] in ('int', 'uint', 'dbl', 'str', 'bool', 'null') then
        x := jsonb_build_object('k', 'lit', 't', case k[q] when 'dbl' then 'double' when 'str' then 'string' else k[q] end,
                                's', v[q], 'p', pos[q]);
        q := q + 1;
    elsif k[q] = '(' then
        select r.node, r.np into x, q from permissions._fga_cel_parse(k, v, pos, q + 1, 0) r;
        if x ->> 'k' = 'err' then node := x; np := q; return; end if;
        if k[q] <> ')' then
            node := jsonb_build_object('k', 'err', 'm', format('Syntax error: expected '')'' at column %s, found %L', pos[q], v[q]), 'h', sh);
            np := q; return;
        end if;
        q := q + 1;
    elsif k[q] in ('[', '{') then
        op := k[q];
        args := '[]';
        q := q + 1;
        while k[q] <> case op when '[' then ']' else '}' end loop
            select r.node, r.np into y, q from permissions._fga_cel_parse(k, v, pos, q, 0) r;
            if y ->> 'k' = 'err' then node := y; np := q; return; end if;
            args := args || jsonb_build_array(y);
            if op = '{' then
                if k[q] <> ':' then
                    node := jsonb_build_object('k', 'err', 'm', format('Syntax error: expected '':'' in a map literal at column %s, found %L', pos[q], v[q]), 'h', sh);
                    np := q; return;
                end if;
                select r.node, r.np into y, q from permissions._fga_cel_parse(k, v, pos, q + 1, 0) r;
                if y ->> 'k' = 'err' then node := y; np := q; return; end if;
                args := args || jsonb_build_array(y);
            end if;
            if k[q] = ',' then
                q := q + 1;
            elsif k[q] <> (case op when '[' then ']' else '}' end) then
                node := jsonb_build_object('k', 'err', 'm', format('Syntax error: expected '','' or ''%s'' at column %s, found %L',
                                                                  case op when '[' then ']' else '}' end, pos[q], v[q]), 'h', sh);
                np := q; return;
            end if;
        end loop;
        x := jsonb_build_object('k', case op when '[' then 'list' else 'map' end, 'p', pos[p], 'a', args);
        q := q + 1;
    elsif k[q] = 'id' then
        name := v[q];
        q := q + 1;
        if k[q] = '(' then
            select r.node, r.np into args, q from permissions._fga_cel_parse_args(k, v, pos, q + 1) r;
            if args ->> 'k' = 'err' then node := args; np := q; return; end if;
            x := jsonb_build_object('k', 'call', 'f', name, 'p', pos[p], 'a', args);
        elsif k[q] = '{' then
            node := jsonb_build_object('k', 'err', 'm', format('message construction (%s{...}) is not supported (column %s)', name, pos[p]), 't3', true,
                                       'h', 'Use a map literal {"key": value} or a map parameter instead.');
            np := q; return;
        else
            x := jsonb_build_object('k', 'id', 'n', name, 'p', pos[p]);
        end if;
    elsif k[q] = '.' and k[q + 1] = 'id' then
        node := jsonb_build_object('k', 'err', 'm', format('Syntax error: a leading ''.'' (absolute name) is not supported at column %s', pos[q]), 'h', sh);
        np := q; return;
    else
        node := jsonb_build_object('k', 'err', 'm', case when k[q] = 'eof' then 'Syntax error: unexpected end of expression'
                                                         else format('Syntax error: unexpected %L at column %s', v[q], pos[q]) end, 'h', sh);
        np := q; return;
    end if;

    loop
        if k[q] = '.' then
            if k[q + 1] = '?' or k[q + 1] <> 'id' then
                node := jsonb_build_object('k', 'err', 'm', case when k[q + 1] = '?' then format('optional field selection (.?) is not supported (column %s)', pos[q])
                                                                 else format('Syntax error: expected a field or method name after ''.'' at column %s', pos[q]) end,
                                           'h', sh, 't3', k[q + 1] = '?');
                np := q; return;
            end if;
            name := v[q + 1];
            if k[q + 2] = '(' then
                select r.node, r.np into args, q from permissions._fga_cel_parse_args(k, v, pos, q + 3) r;
                if args ->> 'k' = 'err' then node := args; np := q; return; end if;
                x := jsonb_build_object('k', 'mcall', 'f', name, 'p', pos[p], 'a', jsonb_build_array(x) || args);
            else
                x := jsonb_build_object('k', 'sel', 'f', name, 'p', pos[p], 'a', jsonb_build_array(x));
                q := q + 2;
            end if;
        elsif k[q] = '[' then
            if k[q + 1] = '?' then
                node := jsonb_build_object('k', 'err', 'm', format('optional index ([?...]) is not supported (column %s)', pos[q]), 'h', sh, 't3', true);
                np := q; return;
            end if;
            select r.node, r.np into y, q from permissions._fga_cel_parse(k, v, pos, q + 1, 0) r;
            if y ->> 'k' = 'err' then node := y; np := q; return; end if;
            if k[q] <> ']' then
                node := jsonb_build_object('k', 'err', 'm', format('Syntax error: expected '']'' at column %s, found %L', pos[q], v[q]), 'h', sh);
                np := q; return;
            end if;
            x := jsonb_build_object('k', 'call', 'f', '[]', 'p', pos[p], 'a', jsonb_build_array(x, y));
            q := q + 1;
        else
            exit;
        end if;
    end loop;
    node := x;
    np := q;
end;
$$;

-- Call arguments after '(': expressions separated by ',' up to ')'. node is
-- the jsonb array of arguments (or an error node), np the token after ')'.
create function permissions._fga_cel_parse_args(k text[], v text[], pos int[], p int, out node jsonb, out np int)
language plpgsql immutable
as $$
declare
    y jsonb;
    q int := p;
begin
    node := '[]';
    while k[q] <> ')' loop
        select r.node, r.np into y, q from permissions._fga_cel_parse(k, v, pos, q, 0) r;
        if y ->> 'k' = 'err' then node := y; np := q; return; end if;
        node := node || jsonb_build_array(y);
        if k[q] = ',' then
            q := q + 1;
        elsif k[q] <> ')' then
            node := jsonb_build_object('k', 'err', 'm', format('Syntax error: expected '','' or '')'' at column %s, found %L', pos[q], v[q]),
                                       'h', 'Check the expression''s CEL syntax (https://github.com/google/cel-spec/blob/master/doc/langdef.md), e.g. x < 100 || user_ip.in_cidr("10.0.0.0/8").');
            np := q; return;
        end if;
    end loop;
    np := q + 1;
end;
$$;

-- ---------------------------------------------------------------------------
-- Type checker and macro expansion
-- ---------------------------------------------------------------------------
-- Resolves every operator and function to one overload (f) for the evaluator,
-- annotates every node with its type (t), expands the macros (has() and the
-- comprehensions all, exists, exists_one, map, filter), folds timestamp(),
-- duration() and ipaddress() of a valid literal, and turns literals into
-- their canonical values. Like cel-go's default environment there are no
-- implicit conversions: `x < 1.5` with x an int is an error. env maps
-- parameter (and comprehension variable) names to types. Returns the typed
-- node or {k: err, m, h, t3}.
create function permissions._fga_cel_check(n jsonb, env jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
    kk text := n ->> 'k';
    f text := n ->> 'f';
    a jsonb := '[]';
    t jsonb[] := '{}';
    x jsonb;
    y jsonb;
    rt jsonb;
    ov text;
    s text;
    na int;
    i int;
    tn text[];
    cname text;
    cv permissions.fga_cel_result;
    oh constant text := 'CEL has no implicit conversions: both operands of an operator need the same type (int with int, double with double, string with string); convert with int(), uint(), double(), string(), or write the literal in the other type (1.0 for a double).';
begin
    if kk = 'lit' then
        s := n ->> 's';
        if n ->> 't' = 'int' then
            if s::numeric not between -9223372036854775808 and 9223372036854775807 then
                return jsonb_build_object('k', 'err', 'm', format('integer literal %s is out of range (column %s)', s, n -> 'p'),
                                          'h', 'An int is 64 bits: -9223372036854775808 to 9223372036854775807. Use a uint (5u) or a double (5.0) for larger values.');
            end if;
            return jsonb_build_object('k', 'lit', 't', 'int', 'v', s::numeric);
        elsif n ->> 't' = 'uint' then
            if s::numeric > 18446744073709551615 then
                return jsonb_build_object('k', 'err', 'm', format('unsigned integer literal %su is out of range (column %s)', s, n -> 'p'),
                                          'h', 'A uint is 64 bits: 0u to 18446744073709551615u.');
            end if;
            return jsonb_build_object('k', 'lit', 't', 'uint', 'v', s::numeric);
        elsif n ->> 't' = 'double' then
            if not pg_input_is_valid(s, 'float8') then
                return jsonb_build_object('k', 'err', 'm', format('double literal %s is out of range (column %s)', s, n -> 'p'),
                                          'h', 'A double is a 64-bit float: about 1.8e308 at most.');
            end if;
            return jsonb_build_object('k', 'lit', 't', 'double', 'v', to_jsonb(s::float8));
        elsif n ->> 't' = 'string' then
            return jsonb_build_object('k', 'lit', 't', 'string', 'v', to_jsonb(s));
        elsif n ->> 't' = 'bool' then
            return jsonb_build_object('k', 'lit', 't', 'bool', 'v', to_jsonb(s = 'true'));
        end if;
        return jsonb_build_object('k', 'lit', 't', 'null', 'v', 'null'::jsonb);
    end if;

    if kk = 'id' then
        if env ? (n ->> 'n') then
            return jsonb_build_object('k', 'id', 't', env -> (n ->> 'n'), 'n', n ->> 'n');
        end if;
        if n ->> 'n' in ('int', 'uint', 'double', 'bool', 'string', 'bytes', 'list', 'map', 'null_type', 'type', 'dyn') then
            return jsonb_build_object('k', 'err', 't3', true,
                'm', format('type names used as values are not supported: %s (column %s)', n ->> 'n', n -> 'p'),
                'h', 'Compare values, not types.');
        end if;
        return jsonb_build_object('k', 'err', 'm', format('undeclared reference to ''%s'' (column %s)', n ->> 'n', n -> 'p'),
                                  'h', format('Every name in the expression must be a parameter of the condition. Parameters: %s.',
                                              coalesce((select string_agg(e.key, ', ' order by e.key) from jsonb_object_keys(env) e(key)), 'none')));
    end if;

    if kk = 'sel' then
        x := permissions._fga_cel_check(n #> '{a,0}', env);
        if x ->> 'k' = 'err' then
            -- a.b where a is undeclared: cel-go reports the qualified name
            if n #>> '{a,0,k}' = 'id' and x ->> 'm' like 'undeclared reference%' then
                x := jsonb_set(x, '{m}', to_jsonb(format('undeclared reference to ''%s.%s'' (column %s)', n #>> '{a,0,n}', f, n -> 'p')));
            end if;
            return x;
        end if;
        if x -> 't' = '"dyn"' then
            rt := '"dyn"';
        elsif x #>> '{t,0}' = 'map' and x #> '{t,1}' in ('"string"', '"dyn"') then
            rt := x #> '{t,2}';
        else
            return jsonb_build_object('k', 'err', 'm', format('type ''%s'' does not support field selection (.%s, column %s)',
                                                              permissions._fga_cel_tname(x -> 't'), f, n -> 'p'),
                                      'h', 'Field selection (.name) works on maps with string keys: declare the parameter as map<T>.');
        end if;
        return jsonb_build_object('k', 'sel', 't', rt, 'f', f, 'a', jsonb_build_array(x));
    end if;

    if kk in ('or', 'and') then
        for i in 0 .. 1 loop
            x := permissions._fga_cel_check(n -> 'a' -> i, env);
            if x ->> 'k' = 'err' then return x; end if;
            if x -> 't' not in ('"bool"', '"dyn"') then
                return jsonb_build_object('k', 'err', 'm', format('found no matching overload for ''%s'' applied to a %s (column %s)',
                                                                  case kk when 'or' then '_||_' else '_&&_' end,
                                                                  permissions._fga_cel_tname(x -> 't'), n -> 'p'), 'h', oh);
            end if;
            a := a || jsonb_build_array(x);
        end loop;
        return jsonb_build_object('k', kk, 't', 'bool', 'a', a);
    end if;

    if kk = 'cond' then
        for i in 0 .. 2 loop
            x := permissions._fga_cel_check(n -> 'a' -> i, env);
            if x ->> 'k' = 'err' then return x; end if;
            a := a || jsonb_build_array(x);
            t := t || (x -> 't');
        end loop;
        rt := permissions._fga_cel_tjoin(t[2], t[3]);
        if t[1] not in ('"bool"', '"dyn"') or rt is null then
            return jsonb_build_object('k', 'err', 'm', format('found no matching overload for ''_?_:_'' applied to ''(%s, %s, %s)'' (column %s)',
                                                              permissions._fga_cel_tname(t[1]), permissions._fga_cel_tname(t[2]),
                                                              permissions._fga_cel_tname(t[3]), n -> 'p'),
                                      'h', 'In c ? a : b the condition c must be a bool and a and b must have the same type.');
        end if;
        return jsonb_build_object('k', 'cond', 't', rt, 'a', a);
    end if;

    if kk in ('list', 'map') then
        na := jsonb_array_length(n -> 'a');
        for i in 0 .. na - 1 loop
            x := permissions._fga_cel_check(n -> 'a' -> i, env);
            if x ->> 'k' = 'err' then return x; end if;
            a := a || jsonb_build_array(x);
            t := t || (x -> 't');
        end loop;
        if kk = 'list' then
            rt := null;
            for i in 1 .. na loop
                rt := case when rt is null then t[i] else coalesce(permissions._fga_cel_tjoin(rt, t[i]), '"dyn"') end;
            end loop;
            return jsonb_build_object('k', 'list', 't', jsonb_build_array('list', coalesce(rt, '"dyn"')), 'a', a);
        end if;
        x := null; y := null;
        for i in 1 .. na loop
            if i % 2 = 1 then
                if t[i] not in ('"int"', '"uint"', '"bool"', '"string"', '"dyn"') then
                    return jsonb_build_object('k', 'err', 'm', format('unsupported map key type %s (column %s)', permissions._fga_cel_tname(t[i]), n -> 'p'),
                                              'h', 'Map keys are int, uint, bool or string.');
                end if;
                x := case when x is null then t[i] else coalesce(permissions._fga_cel_tjoin(x, t[i]), '"dyn"') end;
            else
                y := case when y is null then t[i] else coalesce(permissions._fga_cel_tjoin(y, t[i]), '"dyn"') end;
            end if;
        end loop;
        return jsonb_build_object('k', 'map', 't', jsonb_build_array('map', coalesce(x, '"dyn"'), coalesce(y, '"dyn"')), 'a', a);
    end if;

    -- macros
    if kk = 'call' and f = 'has' then
        if jsonb_array_length(n -> 'a') <> 1 or n #>> '{a,0,k}' <> 'sel' then
            return jsonb_build_object('k', 'err', 'm', format('invalid argument to has() macro (column %s)', n -> 'p'),
                                      'h', 'has() takes a field selection: has(m.key), m a map parameter.');
        end if;
        x := permissions._fga_cel_check(n #> '{a,0,a,0}', env);
        if x ->> 'k' = 'err' then return x; end if;
        if not (x -> 't' = '"dyn"' or (x #>> '{t,0}' = 'map' and x #> '{t,1}' in ('"string"', '"dyn"'))) then
            return jsonb_build_object('k', 'err', 'm', format('type ''%s'' does not support field selection (has(), column %s)',
                                                              permissions._fga_cel_tname(x -> 't'), n -> 'p'),
                                      'h', 'has() tests a key of a map with string keys: has(m.key).');
        end if;
        return jsonb_build_object('k', 'has', 't', 'bool', 'f', n #>> '{a,0,f}', 'a', jsonb_build_array(x));
    end if;
    if kk = 'mcall' and f in ('all', 'exists', 'exists_one', 'map', 'filter') then
        na := jsonb_array_length(n -> 'a');
        if not (na = 3 or (na = 4 and f = 'map')) or n #>> '{a,1,k}' <> 'id' then
            return jsonb_build_object('k', 'err', 'm', format('invalid arguments to the %s() macro (column %s)', f, n -> 'p'),
                                      'h', format('Write range.%s(x, predicate) with a variable name x%s.', f,
                                                  case f when 'map' then ' (or range.map(x, filter, expression))' else '' end));
        end if;
        x := permissions._fga_cel_check(n #> '{a,0}', env);
        if x ->> 'k' = 'err' then return x; end if;
        if x -> 't' = '"dyn"' then
            y := '"dyn"';
        elsif x #>> '{t,0}' in ('list', 'map') then
            y := x #> '{t,1}';
        else
            return jsonb_build_object('k', 'err', 'm', format('expression of type ''%s'' cannot be the range of a comprehension (column %s)',
                                                              permissions._fga_cel_tname(x -> 't'), n -> 'p'),
                                      'h', 'all, exists, exists_one, map and filter iterate over a list, or over the keys of a map.');
        end if;
        a := jsonb_build_array(x);
        env := env || jsonb_build_object(n #>> '{a,1,n}', y);
        for i in 2 .. na - 1 loop
            x := permissions._fga_cel_check(n -> 'a' -> i, env);
            if x ->> 'k' = 'err' then return x; end if;
            if (f <> 'map' or (na = 4 and i = 2)) and x -> 't' not in ('"bool"', '"dyn"') then
                return jsonb_build_object('k', 'err', 'm', format('the predicate of %s() must be a bool, got %s (column %s)',
                                                                  f, permissions._fga_cel_tname(x -> 't'), n -> 'p'),
                                          'h', format('Write range.%s(x, predicate), the predicate a bool expression of x.', f));
            end if;
            a := a || jsonb_build_array(x);
        end loop;
        rt := case f when 'map' then jsonb_build_array('list', x -> 't')
                     when 'filter' then jsonb_build_array('list', y)
                     else '"bool"' end;
        return jsonb_build_object('k', 'comp', 't', rt, 'm', f, 'v', n #>> '{a,1,n}', 'a', a);
    end if;

    -- every other call: check the arguments (the receiver first for a method)
    na := jsonb_array_length(n -> 'a');
    for i in 0 .. na - 1 loop
        x := permissions._fga_cel_check(n -> 'a' -> i, env);
        if x ->> 'k' = 'err' then return x; end if;
        a := a || jsonb_build_array(x);
        t := t || (x -> 't');
    end loop;
    tn := array(select permissions._fga_cel_tname(e) from unnest(t) e);
    ov := null;
    rt := null;

    if kk = 'call' and f = '!' then
        if t[1] in ('"bool"', '"dyn"') then ov := 'not'; rt := '"bool"'; end if;
    elsif kk = 'call' and f = 'neg' then
        if t[1] in ('"int"', '"double"', '"dyn"') then
            ov := 'neg_' || case t[1] when '"int"' then 'int' when '"double"' then 'dbl' else 'dyn' end;
            rt := t[1];
        end if;
    elsif kk = 'call' and f in ('+', '-', '*', '/', '%') then
        s := case f when '+' then 'add' when '-' then 'sub' when '*' then 'mul' when '/' then 'div' else 'mod' end;
        if t[1] = '"dyn"' or t[2] = '"dyn"' then
            ov := s || '_dyn'; rt := '"dyn"';
        elsif t[1] = t[2] and t[1] in ('"int"', '"uint"') then
            ov := s || '_' || (t[1] #>> '{}'); rt := t[1];
        elsif t[1] = t[2] and t[1] = '"double"' and f <> '%' then
            ov := s || '_dbl'; rt := t[1];
        elsif f = '+' and t[1] = '"string"' and t[2] = '"string"' then
            ov := 'add_str'; rt := t[1];
        elsif f = '+' and t[1] #>> '{0}' = 'list' and t[2] #>> '{0}' = 'list' then
            ov := 'add_list'; rt := jsonb_build_array('list', coalesce(permissions._fga_cel_tjoin(t[1] -> 1, t[2] -> 1), '"dyn"'));
        elsif f = '+' and t[1] = '"timestamp"' and t[2] = '"duration"' then
            ov := 'add_ts_du'; rt := '"timestamp"';
        elsif f = '+' and t[1] = '"duration"' and t[2] = '"timestamp"' then
            ov := 'add_du_ts'; rt := '"timestamp"';
        elsif f in ('+', '-') and t[1] = '"duration"' and t[2] = '"duration"' then
            ov := s || '_du'; rt := '"duration"';
        elsif f = '-' and t[1] = '"timestamp"' and t[2] = '"timestamp"' then
            ov := 'sub_ts_ts'; rt := '"duration"';
        elsif f = '-' and t[1] = '"timestamp"' and t[2] = '"duration"' then
            ov := 'sub_ts_du'; rt := '"timestamp"';
        end if;
    elsif kk = 'call' and f in ('<', '<=', '>', '>=') then
        s := case f when '<' then 'lt' when '<=' then 'le' when '>' then 'gt' else 'ge' end;
        if (t[1] = '"dyn"' and t[2] in ('"dyn"', '"int"', '"uint"', '"double"', '"string"', '"bool"'))
           or (t[2] = '"dyn"' and t[1] in ('"int"', '"uint"', '"double"', '"string"', '"bool"')) then
            ov := s || '_dyn';
        elsif t[1] = t[2] and t[1] in ('"int"', '"uint"', '"double"', '"bool"', '"duration"') then
            ov := s || '_num';
        elsif t[1] = t[2] and t[1] in ('"string"', '"timestamp"') then
            ov := s || '_str';
        end if;
        rt := '"bool"';
    elsif kk = 'call' and f in ('==', '!=') then
        if permissions._fga_cel_tjoin(t[1], t[2]) is not null then
            ov := case f when '==' then 'eq' else 'ne' end;
        end if;
        rt := '"bool"';
    elsif kk = 'call' and f = 'in' then
        if t[2] = '"dyn"' then
            ov := 'in_dyn';
        elsif t[2] #>> '{0}' = 'list' and permissions._fga_cel_tjoin(t[1], t[2] -> 1) is not null then
            ov := 'in_list';
        elsif t[2] #>> '{0}' = 'map' and permissions._fga_cel_tjoin(t[1], t[2] -> 1) is not null then
            ov := 'in_map';
        end if;
        rt := '"bool"';
    elsif kk = 'call' and f = '[]' then
        if t[1] = '"dyn"' then
            ov := 'idx_dyn'; rt := '"dyn"';
        elsif t[1] #>> '{0}' = 'list' and t[2] in ('"int"', '"uint"', '"dyn"') then
            ov := 'idx_list'; rt := t[1] -> 1;
        elsif t[1] #>> '{0}' = 'map' and permissions._fga_cel_tjoin(t[2], t[1] -> 1) is not null then
            ov := 'idx_map'; rt := t[1] -> 2;
        end if;
    elsif f = 'size' and ((kk = 'call' and na = 1) or (kk = 'mcall' and na = 1)) then
        if t[1] = '"string"' then ov := 'size_str';
        elsif t[1] = '"dyn"' then ov := 'size_dyn';
        elsif t[1] #>> '{0}' = 'list' then ov := 'size_list';
        elsif t[1] #>> '{0}' = 'map' then ov := 'size_map';
        end if;
        rt := '"int"';
    elsif kk = 'call' and f in ('dyn', 'type', 'bytes') then
        return jsonb_build_object('k', 'err', 't3', true, 'm', format('%s() is not supported (column %s)', f, n -> 'p'),
                                  'h', 'Declare the parameter with the type you need (any for a JSON value).');
    elsif kk = 'call' and na = 1 and f in ('int', 'uint', 'double', 'string', 'bool', 'timestamp', 'duration', 'ipaddress') then
        if t[1] = '"dyn"'
           or (f = 'int' and t[1] in ('"int"', '"uint"', '"double"', '"string"', '"timestamp"'))
           or (f = 'uint' and t[1] in ('"int"', '"uint"', '"double"', '"string"'))
           or (f = 'double' and t[1] in ('"int"', '"uint"', '"double"', '"string"'))
           or (f = 'string' and t[1] in ('"int"', '"uint"', '"double"', '"bool"', '"string"', '"timestamp"', '"duration"'))
           or (f = 'bool' and t[1] in ('"bool"', '"string"'))
           or (f = 'timestamp' and t[1] in ('"string"', '"int"', '"timestamp"'))
           or (f = 'duration' and t[1] in ('"string"', '"duration"'))
           or (f = 'ipaddress' and t[1] = '"string"') then
            ov := 'to_' || f;
            rt := to_jsonb(case f when 'ipaddress' then 'ipaddress' else f end);
            -- a conversion of a valid literal is folded into a literal
            if a #>> '{0,k}' = 'lit' and f in ('timestamp', 'duration', 'ipaddress') and t[1] = '"string"' then
                cv := permissions._fga_cel_convert(rt, a #> '{0,v}');
                if cv.e is null then
                    return jsonb_build_object('k', 'lit', 't', rt, 'v', cv.v);
                end if;
            end if;
        end if;
    elsif kk = 'call' and f = 'matches' and na = 2 then
        if t[1] in ('"string"', '"dyn"') and t[2] in ('"string"', '"dyn"') then ov := 'matches'; rt := '"bool"'; end if;
    elsif kk = 'mcall' and f in ('contains', 'startsWith', 'endsWith', 'matches') and na = 2 then
        if t[1] in ('"string"', '"dyn"') and t[2] in ('"string"', '"dyn"') then
            ov := case f when 'startsWith' then 'starts' when 'endsWith' then 'ends' else f end;
            rt := '"bool"';
        end if;
    elsif kk = 'mcall' and f = 'in_cidr' and na = 2 then
        if t[1] = '"ipaddress"' and t[2] in ('"string"', '"dyn"') then ov := 'in_cidr'; rt := '"bool"'; end if;
    elsif kk = 'mcall' and f in ('getFullYear', 'getMonth', 'getDate', 'getDayOfMonth', 'getDayOfWeek', 'getDayOfYear',
                                 'getHours', 'getMinutes', 'getSeconds', 'getMilliseconds') then
        if t[1] = '"timestamp"' and (na = 1 or (na = 2 and t[2] in ('"string"', '"dyn"'))) then
            return jsonb_build_object('k', 'call', 't', 'int', 'f', 'ts_get', 'g', f, 'a', a);
        elsif t[1] = '"duration"' and na = 1 and f in ('getHours', 'getMinutes', 'getSeconds', 'getMilliseconds') then
            return jsonb_build_object('k', 'call', 't', 'int', 'f', 'du_get', 'g', f, 'a', a);
        end if;
    else
        cname := f;
        if kk = 'call' and f not in ('!', 'neg', '+', '-', '*', '/', '%', '<', '<=', '>', '>=', '==', '!=', 'in', '[]') then
            return jsonb_build_object('k', 'err', 'm', format('undeclared reference to ''%s'' (column %s)', f, n -> 'p'),
                                      'h', 'Functions: size, int, uint, double, string, bool, timestamp, duration, ipaddress, matches, has; methods: contains, startsWith, endsWith, matches, in_cidr, size, the timestamp and duration getters, and the macros all, exists, exists_one, map, filter.');
        end if;
    end if;

    if ov is null then
        cname := case f when '!' then '!_' when 'neg' then '-_' when '[]' then '_[_]' when 'in' then '@in'
                        when '+' then '_+_' when '-' then '_-_' when '*' then '_*_' when '/' then '_/_' when '%' then '_%_'
                        when '<' then '_<_' when '<=' then '_<=_' when '>' then '_>_' when '>=' then '_>=_'
                        when '==' then '_==_' when '!=' then '_!=_' else f end;
        return jsonb_build_object('k', 'err',
            'm', format('found no matching overload for ''%s'' applied to ''%s(%s)'' (column %s)', cname,
                        case when kk = 'mcall' then tn[1] || '.' else '' end,
                        array_to_string(case when kk = 'mcall' then tn[2:] else tn end, ', '), n -> 'p'),
            'h', oh);
    end if;
    x := jsonb_build_object('k', 'call', 't', rt, 'f', ov, 'a', a);
    if ov like '%dyn' or ov like 'to\_%' or ov in ('in_map', 'idx_map') then
        x := x || jsonb_build_object('s', to_jsonb(t));
    end if;
    return x;
end;
$$;

-- Compile an expression for a condition's parameters ({name: type}): the
-- typed AST, or {k: err, m, h, t3}. The result must be a bool.
create function permissions._fga_cel_compile(p_expr text, p_params jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
    tk record;
    r record;
    ast jsonb;
begin
    select * into tk from permissions._fga_cel_tokens(p_expr);
    if tk.err is not null then
        return jsonb_build_object('k', 'err', 'm', tk.err, 't3', tk.err like 'bytes%',
            'h', case when tk.err like 'bytes%' then 'Use a string.'
                      else 'Check the expression''s CEL syntax (https://github.com/google/cel-spec/blob/master/doc/langdef.md), e.g. x < 100 || user_ip.in_cidr("10.0.0.0/8").' end);
    end if;
    select * into r from permissions._fga_cel_parse(tk.k, tk.v, tk.pos, 1, 0);
    if r.node ->> 'k' = 'err' then
        return r.node;
    end if;
    if tk.k[r.np] <> 'eof' then
        return jsonb_build_object('k', 'err', 'm', format('Syntax error: unexpected %L at column %s', tk.v[r.np], tk.pos[r.np]),
            'h', 'Check the expression''s CEL syntax (https://github.com/google/cel-spec/blob/master/doc/langdef.md), e.g. x < 100 || user_ip.in_cidr("10.0.0.0/8").');
    end if;
    ast := permissions._fga_cel_check(r.node, p_params);
    if ast ->> 'k' = 'err' then
        return ast;
    end if;
    if ast -> 't' <> '"bool"' then
        return jsonb_build_object('k', 'err', 'm', format('expected a bool condition expression output, but got ''%s''',
                                                          permissions._fga_cel_tname(ast -> 't')),
            'h', 'A condition is a bool expression: compare the value, e.g. x < 100 or a == true.');
    end if;
    return ast;
end;
$$;

-- ---------------------------------------------------------------------------
-- Values: parsing and formatting
-- ---------------------------------------------------------------------------

-- RFC 3339 as Go's time.Parse(time.RFC3339) reads it (OpenFGA's timestamp
-- parameters and cel-go's timestamp()): upper-case T and Z, seconds required,
-- an optional fraction, Z or +hh:mm. The canonical text in UTC with
-- microseconds (CEL keeps nanoseconds: the digits beyond are dropped), or null.
create function permissions._fga_cel_ts(s text)
returns text
language plpgsql immutable
as $$
declare
    m text[];
    t text;
begin
    m := regexp_match(s, '^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:[.,]([0-9]+))?(Z|[+-]([0-9]{2}):([0-9]{2}))$');
    if m is null or m[2]::int > 23 or m[3]::int > 59 or m[4]::int > 59
       or coalesce(m[7]::int, 0) > 23 or coalesce(m[8]::int, 0) > 59
       or not pg_input_is_valid(m[1], 'date') or m[1] < '0001' then
        return null;
    end if;
    t := m[1] || ' ' || m[2] || ':' || m[3] || ':' || m[4] || coalesce('.' || left(m[5], 6), '')
         || case when m[6] = 'Z' then '+00:00' else m[6] end;
    return to_char(t::timestamptz at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
end;
$$;

-- A timestamptz as the canonical value, or null outside CEL's range (years
-- 1 to 9999).
create function permissions._fga_cel_ts_val(ts timestamptz)
returns jsonb
language sql immutable
as $$
    select case when ts >= '0001-01-01 00:00:00+00' and ts < '10000-01-01 00:00:00+00'
                then to_jsonb(to_char(ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) end
$$;

-- Go's time.ParseDuration ("1h30m", "300ms", "-1.5h"; units ns us µs μs ms s
-- m h): integer nanoseconds, or null (also beyond int64).
create function permissions._fga_cel_du(s text)
returns numeric
language plpgsql immutable
as $$
declare
    body text;
    total numeric := 0;
    m text[];
begin
    if s = '0' or s = '+0' or s = '-0' then
        return 0;
    end if;
    if s !~ '^[+-]?(([0-9]+(\.[0-9]*)?|\.[0-9]+)(ns|us|µs|μs|ms|s|m|h))+$' then
        return null;
    end if;
    body := ltrim(s, '+-');
    for m in select regexp_matches(body, '([0-9]*\.?[0-9]*)(ns|us|µs|μs|ms|s|m|h)', 'g') loop
        total := total + (case when m[1] like '.%' then '0' || m[1] when m[1] like '%.' then m[1] || '0' else m[1] end)::numeric
                 * case m[2] when 'ns' then 1 when 'ms' then 1000000 when 's' then 1000000000 when 'm' then 60000000000
                             when 'h' then 3600000000000 else 1000 end;
    end loop;
    total := trunc(total);
    if left(s, 1) = '-' then
        total := -total;
    end if;
    if total not between -9223372036854775808 and 9223372036854775807 then
        return null;
    end if;
    return total;
end;
$$;

-- netip.ParseAddr, then Unmap (an IPv4-mapped IPv6 address is its IPv4
-- address): the address's text, or null. IPv6 zones (fe80::1%eth0) are not
-- accepted (inet has none).
create function permissions._fga_cel_ip(s text)
returns text
language plpgsql immutable
as $$
declare
    ip inet;
begin
    if s ~ '^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$' then
        return host(s::inet);
    end if;
    if s !~ ':' or s ~ '[/%]' or not pg_input_is_valid(s, 'inet') then
        return null;
    end if;
    ip := s::inet;
    if ip <<= '::ffff:0:0/96'::inet then
        return host(('0.0.0.0'::inet + (ip - '::ffff:0:0'::inet)));
    end if;
    return host(ip);
end;
$$;

-- Go's FormatFloat(f, 'g', -1, 64), as cel-go's string(double) prints it,
-- from float8's shortest text.
create function permissions._fga_cel_dbl_text(d float8)
returns text
language sql immutable
as $$
    select d::text
$$;

-- An OpenFGA context value (JSON) as the canonical value of a parameter type,
-- following OpenFGA's converters (internal/condition/types/converters.go):
-- numbers go through float64 (a JSON number is a float64 in a
-- google.protobuf.Struct), numeric strings through a 64-bit big float; an int
-- or uint must be integral and is clamped to int64 (uint rejects a negative);
-- a double from a string must be exactly a float64; duration and timestamp
-- are Go's formats; a list or a map converts each element.
create function permissions._fga_cel_convert(t jsonb, v jsonb)
returns permissions.fga_cel_result
language plpgsql immutable
as $$
declare
    tn text := case when jsonb_typeof(t) = 'string' then t #>> '{}' else t ->> 0 end;
    jt text := jsonb_typeof(v);
    s text;
    num numeric;
    f float8;
    r permissions.fga_cel_result;
    acc jsonb;
    e record;
    i int;
begin
    if tn = 'dyn' then
        return row(v, null::text, 0);
    elsif tn in ('bool', 'string') then
        if jt = (case tn when 'bool' then 'boolean' else 'string' end) then
            return row(v, null::text, 0);
        end if;
        return row(null::jsonb, format('expected type value ''%s'', but found ''%s''', tn, case jt when 'number' then 'float64' when 'boolean' then 'bool' when 'array' then '[]interface {}' when 'object' then 'map[string]interface {}' when 'null' then '<nil>' else jt end), 0);
    elsif tn in ('int', 'uint', 'double') then
        if jt = 'number' then
            if not pg_input_is_valid(v::text, 'float8') then
                return row(null::jsonb, format('number cannot be represented as a float64: %s', v), 0);
            end if;
            f := (v::text)::float8;
            if tn = 'double' then
                return row(to_jsonb(f), null::text, 0);
            end if;
            if f <> trunc(f) then
                return row(null::jsonb, format('expected %s %s value, but found numeric value ''%s''', case tn when 'int' then 'an' else 'a' end, tn, f), 0);
            end if;
            num := case when f >= 9223372036854775807::float8 then 9223372036854775807
                        when f <= -9223372036854775808::float8 then -9223372036854775808
                        else f::bigint end;
        elsif jt = 'string' then
            s := v #>> '{}';
            if s !~ '^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$' then
                return row(null::jsonb, format('expected a %s value, but found invalid string value ''%s''', case tn when 'int' then 'int64' when 'uint' then 'uint64' else 'float64' end, s), 0);
            end if;
            num := s::numeric;
            if tn = 'double' then
                if not permissions._fga_cel_exact_double(num) then
                    return row(null::jsonb, format('number cannot be represented as a float64: %s', s), 0);
                end if;
                return row(to_jsonb(num::float8), null::text, 0);
            end if;
            if num <> trunc(num) and abs(num) < 18446744073709551616 then
                return row(null::jsonb, format('expected %s %s value, but found numeric value ''%s''', case tn when 'int' then 'an' else 'a' end, tn, s), 0);
            end if;
            num := greatest(least(trunc(num), 9223372036854775807), -9223372036854775808);
        else
            return row(null::jsonb, format('expected type value ''%s'', but found ''%s''', case tn when 'int' then 'int64' when 'uint' then 'uint64' else 'float64' end,
                                    case jt when 'boolean' then 'bool' when 'array' then '[]interface {}' when 'object' then 'map[string]interface {}' when 'null' then '<nil>' else jt end), 0);
        end if;
        if tn = 'uint' and num < 0 then
            return row(null::jsonb, format('expected a uint value, but found int64 value ''%s''', num), 0);
        end if;
        return row(to_jsonb(num), null::text, 0);
    elsif tn = 'duration' then
        if jt = 'string' then
            num := permissions._fga_cel_du(v #>> '{}');
            if num is not null then
                return row(to_jsonb(num), null::text, 0);
            end if;
            return row(null::jsonb, format('expected a valid duration string, but found: ''%s''', v #>> '{}'), 0);
        end if;
        return row(null::jsonb, format('expected a duration string, but found: %s', v), 0);
    elsif tn = 'timestamp' then
        if jt = 'string' then
            s := permissions._fga_cel_ts(v #>> '{}');
            if s is not null then
                return row(to_jsonb(s), null::text, 0);
            end if;
            return row(null::jsonb, format('expected RFC 3339 formatted timestamp string, but found ''%s''', v #>> '{}'), 0);
        end if;
        return row(null::jsonb, format('expected RFC 3339 formatted timestamp string, but found: %s', v), 0);
    elsif tn = 'ipaddress' then
        if jt = 'string' then
            s := permissions._fga_cel_ip(v #>> '{}');
            if s is not null then
                return row(to_jsonb(s), null::text, 0);
            end if;
            return row(null::jsonb, format('expected a well-formed IP address, but found: ''%s''', v #>> '{}'), 0);
        end if;
        return row(null::jsonb, format('expected an ipaddress string, but found: %s', v), 0);
    elsif tn = 'list' then
        if jt <> 'array' then
            return row(null::jsonb, format('list requires a list, found: %s', v), 0);
        end if;
        acc := '[]';
        for i in 0 .. jsonb_array_length(v) - 1 loop
            r := permissions._fga_cel_convert(t -> 1, v -> i);
            if r.e is not null then
                return row(null::jsonb, format('found an invalid list item at index `%s`: %s', i, r.e), 0);
            end if;
            acc := acc || jsonb_build_array(r.v);
        end loop;
        return row(acc, null::text, 0);
    elsif tn = 'map' then
        if jt <> 'object' then
            return row(null::jsonb, format('map requires a map, found: %s', v), 0);
        end if;
        acc := '{}';
        for e in select * from jsonb_each(v) loop
            r := permissions._fga_cel_convert(t -> 2, e.value);
            if r.e is not null then
                return row(null::jsonb, format('found an invalid value for key ''%s'': %s', e.key, r.e), 0);
            end if;
            acc := acc || jsonb_build_object(e.key, r.v);
        end loop;
        return row(acc, null::text, 0);
    end if;
    return row(null::jsonb, format('unsupported parameter type %s', permissions._fga_cel_tname(t)), 0);
end;
$$;

-- big.ParseFloat(s, 10, 64, 0).Float64() is exact: the decimal, rounded to a
-- 64-bit mantissa (to nearest, ties to even), fits a float64's 53 bits and
-- range. OpenFGA rejects a double parameter given as a string otherwise
-- ("0.1" is not exact, "1.5" is).
create function permissions._fga_cel_exact_double(x numeric)
returns boolean
language plpgsql immutable
as $$
declare
    a numeric := abs(x);
    e int;
    m numeric;
    r numeric;
begin
    if a = 0 then
        return true;
    end if;
    e := floor(log(2, a))::int;
    while power(2::numeric, e) > a loop e := e - 1; end loop;
    while power(2::numeric, e + 1) <= a loop e := e + 1; end loop;
    if e > 1023 or e < -1074 then
        return false;
    end if;
    -- a = m * 2^(e - 63) with m in [2^63, 2^64)
    if e >= 63 then
        m := div(trunc(a), power(2::numeric, e - 63));
        r := a - m * power(2::numeric, e - 63);
        r := r / power(2::numeric, e - 63);
    else
        m := trunc(a * power(2::numeric, 63 - e));
        r := a * power(2::numeric, 63 - e) - m;
    end if;
    if r > 0.5 or (r = 0.5 and mod(m, 2) = 1) then
        m := m + 1;
    end if;
    -- 53 bits (fewer for a subnormal): the low 11 bits of the 64 are zero
    return mod(m, power(2::numeric, 11 + greatest(-1022 - e, 0))) = 0;
end;
$$;

-- ---------------------------------------------------------------------------
-- Evaluator
-- ---------------------------------------------------------------------------

-- The run-time kind of a value of static type st: st itself, or for dyn the
-- JSON value's kind (a number is a double).
create function permissions._fga_cel_kind(st jsonb, v jsonb)
returns text
language sql immutable
as $$
    select case when st = '"dyn"' then case jsonb_typeof(v) when 'number' then 'double' when 'string' then 'string'
                                                            when 'boolean' then 'bool' when 'array' then 'list'
                                                            when 'object' then 'map' else 'null' end
                when jsonb_typeof(st) = 'array' then st ->> 0
                else st #>> '{}' end
$$;

-- An integer result in range for its kind, else an overflow error.
create function permissions._fga_cel_intres(x numeric, kind text, c int)
returns permissions.fga_cel_result
language sql immutable
as $$
    select case when (kind = 'uint' and x between 0 and 18446744073709551615)
                  or (kind <> 'uint' and x between -9223372036854775808 and 9223372036854775807)
                then row(to_jsonb(x), null::text, c)::permissions.fga_cel_result
                else row(null::jsonb, case kind when 'uint' then 'unsigned integer overflow' when 'duration' then 'duration overflow'
                                         else 'integer overflow' end, c)::permissions.fga_cel_result end
$$;

-- One node of a typed AST (_fga_cel_compile) over an activation (parameter
-- name -> canonical value; every parameter is present). c is the cost so far.
create function permissions._fga_cel_eval(n jsonb, act jsonb, c int)
returns permissions.fga_cel_result
language plpgsql immutable
as $$
declare
    kk text := n ->> 'k';
    f text;
    an jsonb;
    na int;
    vals jsonb[];
    x permissions.fga_cel_result;
    y permissions.fga_cel_result;
    v1 jsonb;
    v2 jsonb;
    k1 text;
    k2 text;
    a1 numeric;
    a2 numeric;
    d1 float8;
    d2 float8;
    s1 text collate "C";
    s2 text collate "C";
    ts timestamptz;
    lt timestamp;
    i int;
    j int;
    err text;
    acc jsonb;
    items jsonb;
    cnt int;
    lim constant int := permissions._fga_cel_cost_limit();
begin
    if kk = 'lit' then
        return row(n -> 'v', null::text, c);
    elsif kk = 'id' then
        c := c + 1;
        if c > lim then return row(null::jsonb, 'operation cancelled: actual cost limit exceeded'::text, c); end if;
        return row(act -> (n ->> 'n'), null::text, c);
    elsif kk in ('or', 'and') then
        -- commutative, absorbing an error when the other side decides
        x := permissions._fga_cel_eval(n #> '{a,0}', act, c);
        if x.e is null and x.v = to_jsonb(kk = 'or') then
            return x;
        end if;
        y := permissions._fga_cel_eval(n #> '{a,1}', act, x.c);
        if y.e is null and y.v = to_jsonb(kk = 'or') then
            return y;
        end if;
        if x.e is not null then
            return row(null::jsonb, x.e, y.c);
        end if;
        if y.e is not null then
            return y;
        end if;
        if jsonb_typeof(x.v) <> 'boolean' or jsonb_typeof(y.v) <> 'boolean' then
            return row(null::jsonb, 'no such overload'::text, y.c);
        end if;
        return row(to_jsonb(kk = 'and'), null::text, y.c);
    elsif kk = 'cond' then
        x := permissions._fga_cel_eval(n #> '{a,0}', act, c);
        if x.e is not null then return x; end if;
        if jsonb_typeof(x.v) <> 'boolean' then return row(null::jsonb, 'no such overload'::text, x.c); end if;
        return permissions._fga_cel_eval(n -> 'a' -> case when x.v = 'true' then 1 else 2 end, act, x.c);
    elsif kk = 'comp' then
        x := permissions._fga_cel_eval(n #> '{a,0}', act, c);
        if x.e is not null then return x; end if;
        c := x.c + 1;
        if jsonb_typeof(x.v) = 'array' then
            items := x.v;
        elsif jsonb_typeof(x.v) = 'object' then
            -- a map ranges over its keys
            k1 := permissions._fga_cel_kind(n #> '{a,0,t,1}', 'null');
            select coalesce(jsonb_agg(case when k1 in ('int', 'uint') then to_jsonb(e.key::numeric)
                                           when k1 = 'bool' then to_jsonb(e.key::boolean) else to_jsonb(e.key) end), '[]')
            into items from jsonb_object_keys(x.v) e(key);
        else
            return row(null::jsonb, 'no such overload'::text, c);
        end if;
        f := n ->> 'm';
        na := jsonb_array_length(n -> 'a');
        acc := case when f in ('map', 'filter') then '[]'::jsonb end;
        cnt := 0;
        err := null;
        for i in 0 .. jsonb_array_length(items) - 1 loop
            c := c + 3;
            if c > lim then return row(null::jsonb, 'operation cancelled: actual cost limit exceeded'::text, c); end if;
            v1 := act || jsonb_build_object(n ->> 'v', items -> i);
            y := permissions._fga_cel_eval(n #> '{a,1}', v1, c);
            c := y.c;
            if f in ('exists', 'all') then
                if y.e is null and jsonb_typeof(y.v) <> 'boolean' then
                    y.e := 'no such overload';
                end if;
                if y.e is null and y.v = to_jsonb(f = 'exists') then
                    return row(to_jsonb(f = 'exists'), null::text, c);
                end if;
                err := coalesce(err, y.e);
            else
                if y.e is not null then return y; end if;
                if f = 'exists_one' then
                    if jsonb_typeof(y.v) <> 'boolean' then return row(null::jsonb, 'no such overload'::text, c); end if;
                    cnt := cnt + (y.v = 'true')::int;
                elsif f = 'filter' then
                    if jsonb_typeof(y.v) <> 'boolean' then return row(null::jsonb, 'no such overload'::text, c); end if;
                    if y.v = 'true' then acc := acc || jsonb_build_array(items -> i); end if;
                elsif na = 2 then
                    acc := acc || jsonb_build_array(y.v);
                else
                    if jsonb_typeof(y.v) <> 'boolean' then return row(null::jsonb, 'no such overload'::text, c); end if;
                    if y.v = 'true' then
                        y := permissions._fga_cel_eval(n #> '{a,2}', v1, c);
                        if y.e is not null then return y; end if;
                        c := y.c;
                        acc := acc || jsonb_build_array(y.v);
                    end if;
                end if;
            end if;
        end loop;
        if f in ('exists', 'all') then
            if err is not null then return row(null::jsonb, err, c); end if;
            return row(to_jsonb(f = 'all'), null::text, c);
        elsif f = 'exists_one' then
            return row(to_jsonb(cnt = 1), null::text, c);
        end if;
        return row(acc, null::text, c);
    end if;

    -- every other node evaluates its arguments first, left to right; the
    -- first error is the result
    c := c + 1;
    if c > lim then return row(null::jsonb, 'operation cancelled: actual cost limit exceeded'::text, c); end if;
    na := jsonb_array_length(n -> 'a');
    for i in 0 .. na - 1 loop
        an := n -> 'a' -> i;
        if an ->> 'k' = 'lit' then
            vals[i + 1] := an -> 'v';
        elsif an ->> 'k' = 'id' then
            c := c + 1;
            if c > lim then return row(null::jsonb, 'operation cancelled: actual cost limit exceeded'::text, c); end if;
            vals[i + 1] := act -> (an ->> 'n');
        else
            x := permissions._fga_cel_eval(an, act, c);
            if x.e is not null then return x; end if;
            c := x.c;
            vals[i + 1] := x.v;
        end if;
    end loop;
    v1 := vals[1];
    v2 := vals[2];

    if kk in ('sel', 'has') then
        if jsonb_typeof(v1) <> 'object' then
            return row(null::jsonb, 'no such overload'::text, c);
        end if;
        if kk = 'has' then
            return row(to_jsonb(v1 ? (n ->> 'f')), null::text, c);
        end if;
        if not v1 ? (n ->> 'f') then
            return row(null::jsonb, format('no such key: %s', n ->> 'f'), c);
        end if;
        return row(v1 -> (n ->> 'f'), null::text, c);
    elsif kk = 'list' then
        return row(coalesce(to_jsonb(vals), '[]'), null::text, c);
    elsif kk = 'map' then
        acc := '{}';
        k1 := permissions._fga_cel_kind(n #> '{t,1}', 'null');
        for i in 1 .. na by 2 loop
            s1 := case when jsonb_typeof(vals[i]) = 'string' then vals[i] #>> '{}' else vals[i]::text end;
            if acc ? s1 then
                return row(null::jsonb, format('Failed with repeated key: %s', vals[i]), c);
            end if;
            acc := acc || jsonb_build_object(s1, vals[i + 1]);
        end loop;
        return row(acc, null::text, c);
    end if;

    f := n ->> 'f';
    -- comparisons
    if f in ('eq', 'ne') then
        return row(to_jsonb((v1 = v2) = (f = 'eq')), null::text, c);
    elsif f in ('lt_num', 'le_num', 'gt_num', 'ge_num') then
        return row(to_jsonb(case left(f, 2) when 'lt' then v1 < v2 when 'le' then v1 <= v2 when 'gt' then v1 > v2 else v1 >= v2 end), null::text, c);
    elsif f in ('lt_str', 'le_str', 'gt_str', 'ge_str') then
        s1 := v1 #>> '{}';
        s2 := v2 #>> '{}';
        return row(to_jsonb(case left(f, 2) when 'lt' then s1 < s2 when 'le' then s1 <= s2 when 'gt' then s1 > s2 else s1 >= s2 end), null::text, c);
    elsif f in ('lt_dyn', 'le_dyn', 'gt_dyn', 'ge_dyn') then
        k1 := permissions._fga_cel_kind(n #> '{s,0}', v1);
        k2 := permissions._fga_cel_kind(n #> '{s,1}', v2);
        if k1 in ('int', 'uint', 'double') and k2 in ('int', 'uint', 'double') then
            a1 := v1::text::numeric; a2 := v2::text::numeric;
            return row(to_jsonb(case left(f, 2) when 'lt' then a1 < a2 when 'le' then a1 <= a2 when 'gt' then a1 > a2 else a1 >= a2 end), null::text, c);
        elsif k1 = k2 and k1 = 'string' then
            s1 := v1 #>> '{}';
            s2 := v2 #>> '{}';
            return row(to_jsonb(case left(f, 2) when 'lt' then s1 < s2 when 'le' then s1 <= s2 when 'gt' then s1 > s2 else s1 >= s2 end), null::text, c);
        elsif k1 = k2 and k1 = 'bool' then
            return row(to_jsonb(case left(f, 2) when 'lt' then v1 < v2 when 'le' then v1 <= v2 when 'gt' then v1 > v2 else v1 >= v2 end), null::text, c);
        end if;
        return row(null::jsonb, 'no such overload'::text, c);
    elsif f = 'not' then
        if jsonb_typeof(v1) <> 'boolean' then return row(null::jsonb, 'no such overload'::text, c); end if;
        return row(to_jsonb(v1 = 'false'), null::text, c);
    elsif f = 'in_cidr' then
        k1 := v2 #>> '{}';
        if jsonb_typeof(v2) <> 'string' then
            return row(null::jsonb, 'a CIDR string is required for comparison'::text, c);
        end if;
        s1 := substring(k1 from '^(.*)/(?:0|[1-9][0-9]{0,2})$');
        i := substring(k1 from '/([0-9]+)$')::int;
        s2 := permissions._fga_cel_ip(s1);
        if s1 is null or s2 is null or s1 ~ '%' or i > (case when s1 ~ ':' then 128 else 32 end) then
            return row(null::jsonb, format('''%s'' is a malformed CIDR string', k1), c);
        end if;
        -- ParsePrefix then Unmap: an IPv4-mapped prefix of 96 bits or more is its IPv4 prefix
        if s1 ~ ':' and s2 !~ ':' then
            if i < 96 then
                return row(to_jsonb((v1 #>> '{}')::inet <<= (host(s1::inet) || '/' || i)::inet), null::text, c);
            end if;
            i := i - 96;
        end if;
        return row(to_jsonb((v1 #>> '{}')::inet <<= (s2 || '/' || i)::inet), null::text, c);
    elsif f in ('in_list', 'in_map', 'in_dyn') then
        if jsonb_typeof(v2) = 'object' then
            k1 := permissions._fga_cel_kind(coalesce(n #> '{s,1,1}', '"string"'), 'null');
            if f = 'in_dyn' and jsonb_typeof(v1) <> 'string' then
                return row('false'::jsonb, null::text, c);
            end if;
            return row(to_jsonb(v2 ? (case when jsonb_typeof(v1) = 'string' then v1 #>> '{}' else v1::text end)), null::text, c);
        elsif jsonb_typeof(v2) = 'array' then
            if jsonb_typeof(v1) in ('array', 'object') then
                return row(to_jsonb(exists (select 1 from jsonb_array_elements(v2) e where e = v1)), null::text, c);
            end if;
            return row(to_jsonb(v2 @> jsonb_build_array(v1)), null::text, c);
        end if;
        return row(null::jsonb, 'no such overload'::text, c);
    elsif f in ('idx_list', 'idx_map', 'idx_dyn') then
        if jsonb_typeof(v1) = 'array' then
            if jsonb_typeof(v2) <> 'number' or v2::text::numeric <> trunc(v2::text::numeric) then
                return row(null::jsonb, 'unsupported index type'::text, c);
            end if;
            a1 := v2::text::numeric;
            if a1 < 0 or a1 >= jsonb_array_length(v1) then
                return row(null::jsonb, format('index out of range: %s', a1), c);
            end if;
            return row(v1 -> a1::int, null::text, c);
        elsif jsonb_typeof(v1) = 'object' then
            s1 := case when jsonb_typeof(v2) = 'string' then v2 #>> '{}' else v2::text end;
            if not v1 ? s1 then
                return row(null::jsonb, format('no such key: %s', s1), c);
            end if;
            return row(v1 -> s1, null::text, c);
        end if;
        return row(null::jsonb, 'no such overload'::text, c);
    elsif f in ('size_str', 'size_list', 'size_map', 'size_dyn') then
        return case jsonb_typeof(v1)
            when 'string' then row(to_jsonb(char_length(v1 #>> '{}')), null::text, c)
            when 'array' then row(to_jsonb(jsonb_array_length(v1)), null::text, c)
            when 'object' then row(to_jsonb((select count(*) from jsonb_object_keys(v1))), null::text, c)
            else row(null::jsonb, 'no such overload'::text, c) end;
    elsif f in ('contains', 'starts', 'ends', 'matches') then
        if jsonb_typeof(v1) <> 'string' or jsonb_typeof(v2) <> 'string' then
            return row(null::jsonb, 'no such overload'::text, c);
        end if;
        s1 := v1 #>> '{}';
        s2 := v2 #>> '{}';
        if f = 'contains' then
            return row(to_jsonb(strpos(s1, s2) > 0), null::text, c);
        elsif f = 'starts' then
            return row(to_jsonb(left(s1, char_length(s2)) = s2), null::text, c);
        elsif f = 'ends' then
            return row(to_jsonb(right(s1, char_length(s2)) = s2), null::text, c);
        end if;
        begin
            return row(to_jsonb(s1 ~ s2), null::text, c);
        exception when invalid_regular_expression then
            return row(null::jsonb, format('invalid regular expression ''%s''', s2), c);
        end;
    end if;

    -- arithmetic
    if f like 'add\_%' or f like 'sub\_%' or f like 'mul\_%' or f like 'div\_%' or f like 'mod\_%' or f like 'neg\_%' then
        k1 := left(f, 3);
        k2 := substr(f, 5);
        if k2 = 'dyn' then
            -- dispatch on the run-time kinds
            s1 := permissions._fga_cel_kind(n #> '{s,0}', v1);
            s2 := case when k1 = 'neg' then s1 else permissions._fga_cel_kind(n #> '{s,1}', v2) end;
            if s1 <> s2 then
                return row(null::jsonb, 'no such overload'::text, c);
            end if;
            k2 := case s1 when 'double' then 'dbl' when 'string' then 'str' else s1 end;
            if k2 not in ('int', 'uint', 'dbl') and not (k1 = 'add' and k2 in ('str', 'list')) then
                return row(null::jsonb, 'no such overload'::text, c);
            end if;
        end if;
        if k2 in ('int', 'uint', 'du') then
            a1 := v1::text::numeric;
            a2 := case when k1 = 'neg' then 0 else v2::text::numeric end;
            if k1 in ('div', 'mod') and a2 = 0 then
                return row(null::jsonb, case k1 when 'div' then 'division by zero' else 'modulus by zero' end, c);
            end if;
            return permissions._fga_cel_intres(case k1 when 'add' then a1 + a2 when 'sub' then a1 - a2 when 'mul' then a1 * a2
                                                        when 'div' then trunc(a1 / a2) when 'mod' then mod(a1, a2) else -a1 end,
                                               case k2 when 'du' then 'duration' else k2 end, c);
        elsif k2 = 'dbl' then
            d1 := v1::text::float8;
            d2 := case when k1 = 'neg' then 0 else v2::text::float8 end;
            if k1 = 'div' and d2 = 0 then
                return row(null::jsonb, 'division by zero'::text, c);
            end if;
            begin
                return row(to_jsonb(case k1 when 'add' then d1 + d2 when 'sub' then d1 - d2 when 'mul' then d1 * d2
                                            when 'div' then d1 / d2 else -d1 end), null::text, c);
            exception when numeric_value_out_of_range then
                return row(null::jsonb, 'double overflow'::text, c);
            end;
        elsif k2 = 'str' then
            return row(to_jsonb((v1 #>> '{}') || (v2 #>> '{}')), null::text, c);
        elsif k2 = 'list' then
            return row(v1 || v2, null::text, c);
        elsif f in ('add_ts_du', 'sub_ts_du', 'add_du_ts') then
            if f = 'add_du_ts' then
                an := v1; v1 := v2; v2 := an;
            end if;
            ts := (v1 #>> '{}')::timestamptz
                  + ((case when f = 'sub_ts_du' then -1 else 1 end * trunc(v2::text::numeric / 1000)) || ' microseconds')::interval;
            an := permissions._fga_cel_ts_val(ts);
            if an is null then
                return row(null::jsonb, 'timestamp overflow'::text, c);
            end if;
            return row(an, null::text, c);
        elsif f = 'sub_ts_ts' then
            return permissions._fga_cel_intres((extract(epoch from (v1 #>> '{}')::timestamptz) - extract(epoch from (v2 #>> '{}')::timestamptz)) * 1000000000,
                                               'duration', c);
        end if;
        return row(null::jsonb, 'no such overload'::text, c);
    end if;

    -- conversions
    if f like 'to\_%' then
        k1 := permissions._fga_cel_kind(n #> '{s,0}', v1);
        k2 := substr(f, 4);
        if k1 = k2 then
            return row(v1, null::text, c);
        end if;
        if k2 in ('int', 'uint') then
            if k1 in ('int', 'uint', 'double') then
                a1 := trunc(v1::text::numeric);
            elsif k1 = 'string' then
                if (v1 #>> '{}') !~ (case k2 when 'int' then '^[+-]?[0-9]+$' else '^[0-9]+$' end) then
                    return row(null::jsonb, format('cannot convert string ''%s'' to %s', v1 #>> '{}', k2), c);
                end if;
                a1 := (v1 #>> '{}')::numeric;
            elsif k1 = 'timestamp' then
                a1 := floor(extract(epoch from (v1 #>> '{}')::timestamptz));
            else
                return row(null::jsonb, 'no such overload'::text, c);
            end if;
            if (k2 = 'int' and a1 not between -9223372036854775808 and 9223372036854775807)
               or (k2 = 'uint' and a1 not between 0 and 18446744073709551615) then
                return row(null::jsonb, format('%s overflow', k2), c);
            end if;
            return row(to_jsonb(a1), null::text, c);
        elsif k2 = 'double' then
            if k1 in ('int', 'uint') then
                return row(to_jsonb(v1::text::float8), null::text, c);
            elsif k1 = 'string' then
                if (v1 #>> '{}') !~ '^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$' or not pg_input_is_valid(v1 #>> '{}', 'float8') then
                    return row(null::jsonb, format('cannot convert string ''%s'' to double', v1 #>> '{}'), c);
                end if;
                return row(to_jsonb((v1 #>> '{}')::float8), null::text, c);
            end if;
        elsif k2 = 'string' then
            if k1 in ('int', 'uint') then
                return row(to_jsonb(v1::text), null::text, c);
            elsif k1 = 'double' then
                return row(to_jsonb(permissions._fga_cel_dbl_text(v1::text::float8)), null::text, c);
            elsif k1 = 'bool' then
                return row(to_jsonb(v1::text), null::text, c);
            elsif k1 = 'timestamp' then
                -- RFC 3339 with the fraction's trailing zeros dropped (Go's RFC3339Nano)
                return row(to_jsonb(regexp_replace(regexp_replace(v1 #>> '{}', '0+Z$', 'Z'), '\.Z$', 'Z')), null::text, c);
            elsif k1 = 'duration' then
                return row(to_jsonb(trim_scale(v1::text::numeric / 1000000000)::text || 's'), null::text, c);
            end if;
        elsif k2 = 'bool' then
            if k1 = 'string' then
                s1 := v1 #>> '{}';
                if s1 in ('1', 't', 'T', 'TRUE', 'true', 'True') then return row('true'::jsonb, null::text, c); end if;
                if s1 in ('0', 'f', 'F', 'FALSE', 'false', 'False') then return row('false'::jsonb, null::text, c); end if;
                return row(null::jsonb, format('cannot convert string ''%s'' to bool', s1), c);
            end if;
        elsif k2 in ('timestamp', 'duration', 'ipaddress') then
            if k1 = 'string' then
                x := permissions._fga_cel_convert(to_jsonb(k2), v1);
                if x.e is not null then
                    return row(null::jsonb, x.e, c);
                end if;
                return row(x.v, null::text, c);
            elsif k1 = 'int' and k2 = 'timestamp' then
                if abs(v1::text::numeric) > 253402300800 then
                    return row(null::jsonb, 'timestamp overflow'::text, c);
                end if;
                an := permissions._fga_cel_ts_val(to_timestamp(0) + (v1::text || ' seconds')::interval);
                if an is null then
                    return row(null::jsonb, 'timestamp overflow'::text, c);
                end if;
                return row(an, null::text, c);
            end if;
        end if;
        return row(null::jsonb, 'no such overload'::text, c);
    end if;

    -- getters
    if f = 'ts_get' then
        s1 := coalesce(v2 #>> '{}', 'UTC');
        -- a time zone name, or an offset (+02:00 is two hours east, unlike POSIX)
        if s1 ~ '^[+-][0-9]{2}:[0-9]{2}$' then
            lt := ((v1 #>> '{}')::timestamptz at time zone 'UTC') + (s1 || ':00')::interval;
        else
            begin
                lt := (v1 #>> '{}')::timestamptz at time zone s1;
            exception when invalid_parameter_value then
                return row(null::jsonb, format('invalid time zone ''%s''', s1), c);
            end;
        end if;
        return row(to_jsonb(case n ->> 'g'
            when 'getFullYear' then extract(year from lt)
            when 'getMonth' then extract(month from lt) - 1
            when 'getDate' then extract(day from lt)
            when 'getDayOfMonth' then extract(day from lt) - 1
            when 'getDayOfWeek' then extract(dow from lt)
            when 'getDayOfYear' then extract(doy from lt) - 1
            when 'getHours' then extract(hour from lt)
            when 'getMinutes' then extract(minute from lt)
            when 'getSeconds' then floor(extract(second from lt))
            else floor(extract(milliseconds from lt)) - floor(extract(second from lt)) * 1000 end::int), null::text, c);
    elsif f = 'du_get' then
        a1 := v1::text::numeric;
        return row(to_jsonb(trunc(a1 / case n ->> 'g' when 'getHours' then 3600000000000 when 'getMinutes' then 60000000000
                                                      when 'getSeconds' then 1000000000 else 1000000 end)), null::text, c);
    end if;
    return row(null::jsonb, format('no such overload: %s', f), c);
end;
$$;

-- ---------------------------------------------------------------------------
-- Evaluating a tuple's condition
-- ---------------------------------------------------------------------------

-- A tuple's condition p_name under model p_m, with its stored context p_tctx
-- and the request's context p_req: 't', 'f', or an error message.
-- OpenFGA's rules (internal/condition/eval, condition.go; research/designs/d-conditions.md
-- section 3): the tuple's context wins over the request's on a shared key;
-- every declared parameter must have a value, whatever the expression would
-- give without it; each value is converted to its declared type. A stored
-- context the model no longer accepts (a key that isn't a parameter, a value
-- that doesn't convert) makes the tuple ignored ('f'), as OpenFGA's Check
-- does; a request value that doesn't convert is an error. A condition with no
-- parameters and a non-empty context is an error (OpenFGA's
-- CastContextToTypedParameters).
create function permissions._fga_cond_eval(p_m text, p_name text, p_tctx jsonb, p_req jsonb)
returns text
language plpgsql stable
as $$
declare
    cd record;
    act jsonb := '{}';
    p record;
    r permissions.fga_cel_result;
    missing text[];
begin
    select c.ast, c.parameters into cd
    from permissions.fga_conditions c where c.model_id = p_m and c.name = p_name;
    if cd.ast is null then
        return 'f';
    end if;
    if p_tctx is not null and exists (select 1 from jsonb_object_keys(p_tctx) x where not cd.parameters ? x) then
        return 'f';
    end if;
    if cd.parameters = '{}' then
        if coalesce(p_req, '{}') <> '{}' or coalesce(p_tctx, '{}') <> '{}' then
            return format('failed to evaluate relationship condition: parameter type error on condition ''%s'' - no parameters defined for the condition', p_name);
        end if;
    end if;
    for p in select * from jsonb_each(cd.parameters) loop
        if p_tctx ? p.key then
            r := permissions._fga_cel_convert(p.value, p_tctx -> p.key);
            if r.e is not null then
                return 'f';
            end if;
        elsif p_req ? p.key then
            r := permissions._fga_cel_convert(p.value, p_req -> p.key);
            if r.e is not null then
                return format('failed to evaluate relationship condition: parameter type error on condition ''%s'' - failed to convert context parameter ''%s'': %s',
                              p_name, p.key, r.e);
            end if;
        else
            missing := missing || p.key;
            continue;
        end if;
        act := act || jsonb_build_object(p.key, r.v);
    end loop;
    if missing is not null then
        return format('failed to evaluate relationship condition: ''%s'' - context is missing parameters ''[%s]''%s',
                      p_name, array_to_string(missing, ' '),
                      case when coalesce(p_tctx, '{}') <> '{}' then format(' (tuple context %s)', p_tctx) else '' end);
    end if;
    r := permissions._fga_cel_eval(cd.ast, act, 0);
    if r.e is not null then
        return format('failed to evaluate relationship condition: ''%s'' - failed to evaluate condition expression: %s', p_name, r.e);
    end if;
    return case when r.v = 'true' then 't' else 'f' end;
end;
$$;

-- An evaluation error: openfga:2000, OpenFGA's validation_error for a
-- condition that can't be evaluated.
create function permissions._fga_cond_fail(p_msg text)
returns boolean
language plpgsql stable
as $$
begin
    perform permissions._fga_error(2000, p_msg,
        hint => 'Pass every parameter the condition declares, in the request''s context argument or in the tuple''s condition context, with a value of its type. A tuple''s context wins over the request''s.');
    return false;
end;
$$;

-- A tuple's condition as a filter: true, false, and an error by p_mode:
-- r fails with openfga:2000 (the API), t gives null (the caller records it),
-- n gives true (an edge under a subtract, for the RLS helpers: taking it
-- removes access, so an error denies), anything else false (the RLS
-- helpers' positive walks: not taking it denies).
create function permissions._fga_cond(p_m text, p_name text, p_tctx jsonb, p_req jsonb, p_mode "char")
returns boolean
language plpgsql stable
as $$
declare
    r text;
begin
    if p_name = '' then
        return true;
    end if;
    r := permissions._fga_cond_eval(p_m, p_name, p_tctx, p_req);
    if r = 't' then
        return true;
    elsif r = 'f' then
        return false;
    elsif p_mode = 'r' then
        return permissions._fga_cond_fail(r);
    elsif p_mode = 't' then
        return null;
    end if;
    return p_mode = 'n';
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
-- Raises openfga:2056 (invalid_authorization_model) or 2057 (schema version),
-- 2000 for what OpenFGA's request validation rejects. Conditions are
-- compiled into fga_conditions (research/designs/d-conditions.md).
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
    entry jsonb;
    added jsonb;
    conds jsonb;
    cnd record;
    pt jsonb;
    params jsonb;
    ast jsonb;
begin
    if jsonb_typeof(model) <> 'object' then
        perform permissions._fga_error(2056, format('the authorization model must be a JSON object, got a JSON %s', jsonb_typeof(model)),
            hint => 'Pass the WriteAuthorizationModel body, {"schema_version": "1.1", "type_definitions": [...]}, as ''fga model transform --output-format json'' prints it.');
    end if;
    -- OpenFGA v1.22.1: a version outside 1.0, 1.1 and 1.2 fails the request's
    -- validation (2000); 1.0 is invalid_authorization_model (2056). 1.2 (modular
    -- models) is valid there but not supported here (2057).
    if coalesce(model ->> 'schema_version', '') <> '1.1' then
        perform permissions._fga_error(
            case model ->> 'schema_version' when '1.0' then 2056 when '1.2' then 2057 else 2000 end,
            format('unsupported schema version %s: only 1.1 is supported', coalesce(model ->> 'schema_version', '(none)')),
            hint => 'Set "schema_version": "1.1" (in the DSL, ''schema 1.1''). Modular models (schema 1.2) are not supported.');
    end if;
    -- conditions: the request's validation (openfga/api authzmodel.proto:
    -- names, expression size, parameter count), 2000
    conds := case when jsonb_typeof(model -> 'conditions') = 'object' then model -> 'conditions' else '{}' end;
    select x.msg into bad
    from (
        select 1 as o, format('invalid WriteAuthorizationModelRequest.Conditions: must be an object of conditions by name, got a JSON %s',
                              jsonb_typeof(model -> 'conditions')) as msg
        where coalesce(jsonb_typeof(model -> 'conditions'), 'null') not in ('object', 'null')
      union all
        select 2, format('invalid Condition %L: must be an object {"name", "expression", "parameters"}', e.key)
        from jsonb_each(conds) e where jsonb_typeof(e.value) <> 'object'
      union all
        select 3, format('invalid Condition.Name %L: value does not match regex pattern "^[^:#@\s]{1,50}$"', coalesce(e.value ->> 'name', e.key))
        from jsonb_each(conds) e
        where jsonb_typeof(e.value) = 'object' and coalesce(e.value ->> 'name', '') !~ '^[^:#@[:space:]]{1,50}$'
      union all
        select 4, format('invalid Condition.Expression of condition %L: value length must be at most 512 bytes, got %s', e.key, octet_length(e.value ->> 'expression'))
        from jsonb_each(conds) e where jsonb_typeof(e.value) = 'object' and octet_length(e.value ->> 'expression') > 512
      union all
        select 5, format('invalid Condition.Parameters of condition %L: value must contain no more than 25 pair(s), got %s', e.key,
                         (select count(*) from jsonb_object_keys(e.value -> 'parameters')))
        from jsonb_each(conds) e
        where jsonb_typeof(e.value -> 'parameters') = 'object' and (select count(*) from jsonb_object_keys(e.value -> 'parameters')) > 25
      union all
        select 6, format('invalid Condition.Parameters of condition %L: parameter name %L does not match regex pattern "^[^:#@\s]{1,50}$"', e.key, pk)
        from jsonb_each(conds) e
        cross join jsonb_object_keys(case when jsonb_typeof(e.value -> 'parameters') = 'object' then e.value -> 'parameters' else '{}' end) pk
        where pk !~ '^[^:#@[:space:]]{1,50}$'
    ) x order by x.o limit 1;
    if bad is not null then
        perform permissions._fga_error(2000, bad,
            hint => 'A condition is {"name": "c", "expression": "x < 100", "parameters": {"x": {"type_name": "TYPE_NAME_INT"}}}: a name of 1 to 50 characters with no '':'', ''#'', ''@'' or whitespace, an expression of at most 512 bytes, at most 25 parameters.');
    end if;
    -- inline conditions ($expression) are an experimental OpenFGA feature, off
    -- by default; the default server rejects them at request validation
    select format('%s#%s allows %s with condition %L', td ->> 'type', r.key, u ->> 'type', u ->> 'condition') into bad
    from jsonb_array_elements(case when jsonb_typeof(model -> 'type_definitions') = 'array' then model -> 'type_definitions' else '[]' end) td
    cross join jsonb_each(case when jsonb_typeof(td #> '{metadata,relations}') = 'object'
                               then td #> '{metadata,relations}' else '{}' end) r
    cross join jsonb_array_elements(case when jsonb_typeof(r.value -> 'directly_related_user_types') = 'array'
                                         then r.value -> 'directly_related_user_types' else '[]' end) u
    where u ->> 'condition' like '$%' limit 1;
    if bad is not null then
        perform permissions._fga_error(2000, format('$expression requires the "inline_expressions" experimental feature flag: %s', bad),
            hint => 'Inline expressions are not supported: define a named condition under "conditions" and name it on the type restriction ([user with my_condition]).');
    end if;
    tds := model -> 'type_definitions';
    if jsonb_typeof(tds) is distinct from 'array' or jsonb_array_length(tds) = 0 then
        perform permissions._fga_error(2056, format('type_definitions must be a non-empty array, got %s', coalesce(tds::text, 'nothing')),
            hint => 'List at least one type, e.g. "type_definitions": [{"type": "user"}].');
    end if;

    -- names: the request's patterns (2047, 2050), then NewAndValidate's
    -- duplicate types and reserved names (2056)
    select coalesce(td ->> 'type', '(missing)') into bad from jsonb_array_elements(tds) td
    where jsonb_typeof(td) <> 'object' or coalesce(td ->> 'type', '') !~ '^[^:#@[:space:]]{1,254}$' limit 1;
    if bad is not null then
        perform permissions._fga_error(2047, format('invalid type name ''%s''', bad),
            hint => 'Each type definition is an object {"type": "document", ...}. A type name is 1 to 254 characters with no '':'', ''#'', ''@'' or whitespace.');
    end if;
    select format('%s#%s', td ->> 'type', r.key) into bad
    from jsonb_array_elements(tds) td
    cross join jsonb_each(case when jsonb_typeof(td -> 'relations') = 'object' then td -> 'relations' else '{}' end) r
    where r.key !~ '^[^:#@[:space:]]{1,50}$' limit 1;
    if bad is not null then
        perform permissions._fga_error(2050, format('invalid relation name ''%s''', bad),
            hint => 'A relation name is 1 to 50 characters with no '':'', ''#'', ''@'' or whitespace.');
    end if;
    select td ->> 'type' into bad from jsonb_array_elements(tds) td group by 1 having count(*) > 1 limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format('the type ''%s'' is defined more than once', bad),
            hint => format('Define each type once: merge the relations of every %L definition into one.', bad));
    end if;
    select td ->> 'type' into bad from jsonb_array_elements(tds) td where td ->> 'type' in ('self', 'this') limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format('the definition of type ''%s'' is invalid: self and this are reserved keywords', bad),
            hint => 'Rename the type: ''self'' and ''this'' are reserved keywords.');
    end if;
    select format('%s#%s', td ->> 'type', r.key) into bad
    from jsonb_array_elements(tds) td
    cross join jsonb_each(case when jsonb_typeof(td -> 'relations') = 'object' then td -> 'relations' else '{}' end) r
    where r.key in ('self', 'this') limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format('invalid relation name ''%s'': self and this are reserved keywords', bad),
            hint => 'Rename the relation: ''self'' and ''this'' are reserved keywords.');
    end if;

    m := permissions._fga_ulid();
    insert into permissions.fga_models (id, schema_version, model)
    values (m, '1.1', jsonb_build_object('schema_version', '1.1', 'type_definitions', tds)
                      || case when conds <> '{}' then jsonb_build_object('conditions', conds) else '{}' end);
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

    -- conditions (research/designs/d-conditions.md): the key is the name, the
    -- parameter types are OpenFGA's, the expression compiles (parsed and
    -- type-checked, a bool) for those parameters. 2056 otherwise.
    for cnd in select e.key, e.value from jsonb_each(conds) e order by e.key loop
        bad := null;
        h := null;
        params := '{}';
        if cnd.value ->> 'name' is distinct from cnd.key then
            bad := format('the condition key %L differs from its name %L', cnd.key, cnd.value ->> 'name');
            h := 'Give each condition its own name as its key: "conditions": {"c": {"name": "c", ...}}.';
        else
            select x.key, permissions._fga_cel_ptype(x.value) into bad_type, pt
            from jsonb_each(case when jsonb_typeof(cnd.value -> 'parameters') = 'object' then cnd.value -> 'parameters' else '{}' end) x
            where jsonb_typeof(permissions._fga_cel_ptype(x.value)) = 'object'
            order by x.key limit 1;
            if pt is not null then
                bad := format('failed to decode parameter type for parameter ''%s'': %s', bad_type, pt ->> 'err');
                h := case when pt ? 'tier3' then 'bytes is not supported by pg_permissions (nor by the DSL): use a string parameter.'
                          else 'Parameter types: TYPE_NAME_ANY, BOOL, STRING, INT, UINT, DOUBLE, DURATION, TIMESTAMP, IPADDRESS, and MAP or LIST with one generic type ({"type_name": "TYPE_NAME_LIST", "generic_types": [{"type_name": "TYPE_NAME_STRING"}]}).' end;
            else
                select coalesce(jsonb_object_agg(x.key, permissions._fga_cel_ptype(x.value)), '{}') into params
                from jsonb_each(case when jsonb_typeof(cnd.value -> 'parameters') = 'object' then cnd.value -> 'parameters' else '{}' end) x;
                ast := permissions._fga_cel_compile(coalesce(cnd.value ->> 'expression', ''), params);
                if ast ->> 'k' = 'err' then
                    bad := ast ->> 'm';
                    h := case when (ast ->> 't3')::boolean
                              then (ast ->> 'h') || ' pg_permissions'' CEL leaves out bytes, type(), dyn(), protobuf messages and optional syntax (see docs/conditions.md).'
                              else ast ->> 'h' end;
                end if;
            end if;
        end if;
        if bad is not null then
            perform permissions._fga_error(2056, format('failed to compile expression on condition ''%s'' - %s', cnd.key, bad), hint => h);
        end if;
        insert into permissions.fga_conditions (model_id, name, expression, parameters, ast)
        values (m, cnd.key, cnd.value ->> 'expression', params, ast);
    end loop;

    -- type restrictions
    insert into permissions.fga_type_restrictions (model_id, type, relation, user_type, user_relation, wildcard, condition)
    select distinct m, td ->> 'type', r.key, u ->> 'type', coalesce(u ->> 'relation', ''), u ? 'wildcard', coalesce(u ->> 'condition', '')
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
    select tr.condition, tr.relation, format('%s#%s allows %s with %s', tr.type, tr.relation, tr.user_type, tr.condition)
    into bad, bad_type, h
    from permissions.fga_type_restrictions tr
    where tr.model_id = m and tr.condition <> ''
      and not exists (select 1 from permissions.fga_conditions c where c.model_id = m and c.name = tr.condition)
    order by tr.type, tr.relation, tr.condition limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format('condition %s is undefined for relation %s (%s)', bad, bad_type, h),
            hint => format('Define the condition under the model''s "conditions" (in the DSL: condition %s(x: int) { x < 100 }), or remove "with %s" from the type restriction. Conditions in this model: %s.',
                           bad, bad, coalesce((select string_agg(c.name, ', ' order by c.name) from permissions.fga_conditions c where c.model_id = m), 'none')));
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

    -- Entrypoints (OpenFGA's hasEntrypoints, pkg/typesystem/typesystem.go): every
    -- relation needs a way to a concrete user type, else no tuple can ever
    -- satisfy it. The least fixpoint over the rewrite nodes, one round per
    -- level: a node has an entrypoint when
    --   this          a type restriction is a plain type or a wildcard, or a
    --                 userset type#relation whose relation has one
    --   computed      the computed relation has one
    --   ttu           the computed relation has one on a type the tupleset allows
    --   union         one child has one
    --   intersection, difference: every child has one (subtract included)
    -- Keys are 'type#relation#node' (names have no '#').
    entry := '{}';
    loop
        select jsonb_object_agg(n.type || '#' || n.relation || '#' || n.node, true) into added
        from permissions.fga_rewrite_nodes n
        where n.model_id = m
          and not entry ? (n.type || '#' || n.relation || '#' || n.node)
          and case n.op
              when 'this' then exists (
                  select 1 from permissions.fga_type_restrictions tr
                  where tr.model_id = m and tr.type = n.type and tr.relation = n.relation
                    and (tr.user_relation = '' or tr.wildcard
                         or entry ? (tr.user_type || '#' || tr.user_relation || '#1')))
              when 'computed' then entry ? (n.type || '#' || n.computed || '#1')
              when 'ttu' then exists (
                  select 1 from permissions.fga_type_restrictions tr
                  where tr.model_id = m and tr.type = n.type and tr.relation = n.tupleset
                    and entry ? (tr.user_type || '#' || n.computed || '#1'))
              when 'union' then exists (
                  select 1 from permissions.fga_rewrite_nodes c
                  where c.model_id = m and c.type = n.type and c.relation = n.relation and c.parent = n.node
                    and entry ? (c.type || '#' || c.relation || '#' || c.node))
              else not exists (
                  select 1 from permissions.fga_rewrite_nodes c
                  where c.model_id = m and c.type = n.type and c.relation = n.relation and c.parent = n.node
                    and not entry ? (c.type || '#' || c.relation || '#' || c.node))
              end;
        exit when added is null;
        entry := entry || added;
    end loop;
    select r.type, r.relation into bad_type, bad
    from permissions.fga_relations r
    where r.model_id = m and not entry ? (r.type || '#' || r.relation || '#1')
    order by r.type, r.relation limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format(
            'the definition of relation ''%s'' in object type ''%s'' is invalid: no entrypoints defined (no path from %s#%s to a concrete user type)',
            bad, bad_type, bad_type, bad),
            hint => format('Give %s#%s a way in: a direct type restriction such as [user] or [user:*] on it, or on a relation it is computed from. Relations that only refer to each other (define a: b, define b: a) are never satisfied, and every operand of ''and'' and ''but not'' needs a way in too.',
                           bad_type, bad));
    end if;

    -- Cycles (OpenFGA's HasCycle): computed relations on one type must not
    -- refer to each other in a cycle, through any operator, subtracts included,
    -- even when each has an entrypoint. Recursion through usersets and
    -- tuple-to-userset is allowed.
    with recursive e(type, src, dst) as (
        select distinct n.type, n.relation, n.computed
        from permissions.fga_rewrite_nodes n
        where n.model_id = m and n.op = 'computed'
    ),
    cl(type, src, dst) as (
        select e.type, e.src, e.dst from e
      union
        select cl.type, cl.src, e.dst from cl join e on e.type = cl.type and e.src = cl.dst
    )
    select c.type, c.src,
           (select string_agg(c.type || '#' || x.dst, ', ' order by x.dst)
            from cl x where x.type = c.type and x.src = c.src
              and exists (select 1 from cl y where y.type = c.type and y.src = x.dst and y.dst = c.src))
    into bad_type, bad, h
    from cl c
    where c.src = c.dst
    order by c.type, c.src limit 1;
    if bad is not null then
        perform permissions._fga_error(2056, format(
            'the definition of relation ''%s'' in object type ''%s'' is invalid: an authorization model cannot contain a cycle (computed relations on the cycle: %s)',
            bad, bad_type, h),
            hint => format('Computed relations on one type must not refer to each other in a cycle (%s), even when each also has a direct type restriction. Remove one of the references. Recursion is allowed through a userset ([%s#%s]) or a tuple-to-userset (%s from parent).',
                           h, bad_type, bad, bad));
    end if;

    -- compile
    update permissions.fga_relations r set is_tupleset = true
    where r.model_id = m
      and exists (select 1 from permissions.fga_rewrite_nodes n
                  where n.model_id = m and n.type = r.type and n.op = 'ttu' and n.tupleset = r.relation);

    insert into permissions.fga_edges (model_id, kind, dst_type, dst_relation, src_type, src_relation, src_wildcard, via, condition)
    select distinct m, 'd', n.type, n.relation, tr.user_type, tr.user_relation, tr.wildcard, null::text, tr.condition
    from permissions.fga_rewrite_nodes n
    join permissions.fga_type_restrictions tr on tr.model_id = m and tr.type = n.type and tr.relation = n.relation
    where n.model_id = m and n.op = 'this' and not n.in_subtract
    union
    select m, 'c', n.type, n.relation, n.type, n.computed, false, null, ''
    from permissions.fga_rewrite_nodes n
    where n.model_id = m and n.op = 'computed' and not n.in_subtract
    union
    select m, 't', n.type, n.relation, tr.user_type, n.computed, false, n.tupleset, tr.condition
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

    -- conditional: a conditioned restriction (or a conditioned tupleset
    -- restriction of a tupleToUserset) on a relation reachable through any
    -- operand, subtracts included (fga_paths, reflexive). Otherwise no
    -- evaluation of the relation can meet a condition, and the walks keep
    -- their unconditioned statements.
    update permissions.fga_relations r set conditional = true
    where r.model_id = m
      and exists (select 1
                  from permissions.fga_paths p
                  where p.model_id = m and p.type = r.type and p.relation = r.relation
                    and p.user_relation <> '' and not p.wildcard
                    and (exists (select 1 from permissions.fga_type_restrictions tr
                                 where tr.model_id = m and tr.type = p.user_type and tr.relation = p.user_relation
                                   and tr.condition <> '')
                         or exists (select 1 from permissions.fga_rewrite_nodes n
                                    join permissions.fga_type_restrictions tr
                                      on tr.model_id = m and tr.type = n.type and tr.relation = n.tupleset and tr.condition <> ''
                                    where n.model_id = m and n.type = p.user_type and n.relation = p.user_relation
                                      and n.op = 'ttu')));

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
                                            src_wildcard, user_relation, object_type, tuple_relation, out_relation, condition)
    select distinct m, rc.target_type, rc.target_relation, e.kind, e.src_type, e.src_relation, e.src_wildcard,
           case e.kind when 'd' then e.src_relation else '' end,
           e.dst_type, case e.kind when 'd' then e.dst_relation else e.via end, o.out_relation, e.condition
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

    -- Set-based ListObjects for the other relations that are not monotone
    -- (set_eval; phase 5 of session 5): ListObjects evaluates the rewrite
    -- tree bottom-up over sets of objects with levels (_fga_set_rel,
    -- _fga_set_node) when every leaf is a walk that is exact:
    --   - `this`: every userset in its type restrictions is monotone, so the
    --     forward walk's direct tuples on the relation are exactly its
    --     operand;
    --   - a computed relation, and the relation of a tupleToUserset on every
    --     parent type, are monotone or set_eval themselves;
    --   - the relation doesn't reach itself in the positive graph (no
    --     recursion through it), and the fixpoint below never marks a cycle
    --     through a subtract (each relation needs its operands marked first).
    -- A relation with a set-based difference (diff_relation) qualifies too:
    -- its own ListObjects keeps that path, but other relations' trees can
    -- use it as a leaf.
    loop
        update permissions.fga_relations r set set_eval = true
        where r.model_id = m and not r.monotone and not r.set_eval
          and not exists (select 1 from permissions.fga_reach rc
                          where rc.model_id = m and rc.target_type = r.type and rc.target_relation = r.relation
                            and rc.type = r.type and rc.relation = r.relation and rc.strict)
          and not exists (
              select 1
              from permissions.fga_rewrite_nodes n
              where n.model_id = m and n.type = r.type and n.relation = r.relation
                and case n.op
                    when 'this' then exists (
                        select 1 from permissions.fga_type_restrictions tr
                        join permissions.fga_relations y on y.model_id = m and y.type = tr.user_type and y.relation = tr.user_relation
                        where tr.model_id = m and tr.type = r.type and tr.relation = r.relation and not y.monotone)
                    when 'computed' then exists (
                        select 1 from permissions.fga_relations y
                        where y.model_id = m and y.type = r.type and y.relation = n.computed
                          and not (y.monotone or y.set_eval))
                    when 'ttu' then exists (
                        select 1
                        from permissions._fga_subtract_types(m, r.type, n.computed, n.tupleset) st
                        join permissions.fga_relations y on y.model_id = m and y.type = st and y.relation = n.computed
                        where not (y.monotone or y.set_eval))
                    when 'union' then false
                    when 'intersection' then false
                    when 'difference' then false
                    else true end);
        exit when not found;
    end loop;
    return m;
end;
$$;

create function permissions.fga_read_authorization_model(model_id text default null)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
    m text := permissions._fga_model_id(fga_read_authorization_model.model_id);
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
-- is 2053 exceeded_entity_limit, checked after the duplicates. A tuple key may
-- carry a condition, {"name": "...", "context": {...}}, validated against
-- the model (2000); it is not part of the key: deletes ignore it, and writing
-- a key that exists with a different condition is 2017 even with
-- on_duplicate ignore (OpenFGA answers 409 Aborted there, which has no code).
create function permissions.fga_write(writes jsonb default null, deletes jsonb default null,
                                      model_id text default null)
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
            hint => 'Pass writes, deletes or both, e.g. select permissions.fga_write(writes => ''[{"user": "user:anne", "relation": "viewer", "object": "document:1"}]'').');
    end if;
    m := permissions._fga_model_id(fga_write.model_id);

    w := array(select permissions._fga_tuple_for_write(m, e, 2027, 2000)
               from jsonb_array_elements(coalesce(writes, '[]')) with ordinality x(e, o) order by o);
    d := array(
        select row(o.object_type, o.object_id, e ->> 'relation', u.user_type, u.user_id, u.user_relation, '', null)::permissions.fga_tuple
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
        returning row(x.object_type, x.object_id, x.relation, x.user_type, x.user_id, x.user_relation, '', null)::permissions.fga_tuple as k)
    select coalesce(array_agg(k), '{}') into done from del;
    if cardinality(done) < cardinality(d) and not d_ignore then
        select format('%s:%s#%s@%s', t.object_type, t.object_id, t.relation,
                      permissions._fga_user_string(t.user_type, t.user_id, t.user_relation)) into bad
        from unnest(d) t where not (t = any (done)) limit 1;
        perform permissions._fga_error(2017, format('cannot delete a tuple which does not exist: %s', bad),
            hint => 'Pass deletes as {"tuple_keys": [...], "on_missing": "ignore"} to skip tuples that are already gone.');
    end if;
    with ins as (
        insert into permissions.fga_tuples (object_type, object_id, relation, user_type, user_id, user_relation,
                                            condition_name, condition_context)
        select t.object_type, t.object_id, t.relation, t.user_type, t.user_id, t.user_relation,
               t.condition_name, t.condition_context from unnest(w) t
        on conflict do nothing
        returning row(object_type, object_id, relation, user_type, user_id, user_relation,
                      condition_name, condition_context)::permissions.fga_tuple as k)
    select coalesce(array_agg(k), '{}') into done from ins;
    if cardinality(done) < cardinality(w) and not w_ignore then
        select format('%s:%s#%s@%s', t.object_type, t.object_id, t.relation,
                      permissions._fga_user_string(t.user_type, t.user_id, t.user_relation)) into bad
        from unnest(w) t where not (t = any (done)) limit 1;
        perform permissions._fga_error(2017, format('cannot write a tuple which already exists: %s', bad),
            hint => 'Pass writes as {"tuple_keys": [...], "on_duplicate": "ignore"} to skip tuples that already exist.');
    end if;
    -- on_duplicate ignore skips a tuple that exists with the same condition
    -- only (OpenFGA: 409 Aborted, "attempted to write a tuple which already
    -- exists with a different condition")
    if cardinality(done) < cardinality(w) then
        select format('%s:%s#%s@%s (stored: %s, written: %s)', t.object_type, t.object_id, t.relation,
                      permissions._fga_user_string(t.user_type, t.user_id, t.user_relation),
                      case when x.condition_name = '' then 'no condition' else format('condition %s %s', x.condition_name, x.condition_context) end,
                      case when t.condition_name = '' then 'no condition' else format('condition %s %s', t.condition_name, t.condition_context) end)
        into bad
        from unnest(w) t
        join permissions.fga_tuples x
          on x.object_type = t.object_type and x.object_id = t.object_id and x.relation = t.relation
         and x.user_type = t.user_type and x.user_id = t.user_id and x.user_relation = t.user_relation
        where not (t = any (done))
          and (x.condition_name <> t.condition_name or x.condition_context is distinct from t.condition_context)
        limit 1;
        if bad is not null then
            perform permissions._fga_error(2017, format('attempted to write a tuple which already exists with a different condition: %s', bad),
                hint => 'on_duplicate ignore skips only a tuple stored with the same condition and context. To change a tuple''s condition, delete it, then write it again: two fga_write calls, which commit together inside one transaction.');
        end if;
    end if;
end;
$$;

-- Convenience: one tuple, OpenFGA strings (subject is OpenFGA's user field).
-- Idempotent (on_duplicate/on_missing ignore).
--
-- Typed path (phase 5 of session 5): no JSON round trip. A well-formed key
-- that an unconditioned type restriction of the latest model allows (one
-- lookup: _fga_write_key_ok) is inserted directly; one that exists without a
-- condition is left alone. Everything else (no model, a malformed or
-- disallowed key, a key stored with a condition) goes to fga_write with the
-- JSON key, which decides as before and raises its own error, so both
-- functions behave exactly as the JSON path (test/spec/d/42_fga_write_paths).
create function permissions.fga_write_tuple(subject text, relation text, object text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    m text;
    t permissions.fga_tuple;
begin
    select x.id into m from permissions.fga_models x order by x.seq desc limit 1;
    t := permissions._fga_typed_key(subject, relation, object);
    if m is not null and t.object_id <> '*'
       and permissions._fga_write_key_ok(m, t.object_type, t.relation, t.user_type, t.user_id, t.user_relation) then
        insert into permissions.fga_tuples (object_type, object_id, relation, user_type, user_id, user_relation,
                                            condition_name, condition_context)
        values (t.object_type, t.object_id, t.relation, t.user_type, t.user_id, t.user_relation, '', null)
        on conflict do nothing;
        if found or exists (
            select 1 from permissions.fga_tuples x
            where x.object_type = t.object_type and x.object_id = t.object_id and x.relation = t.relation
              and x.user_type = t.user_type and x.user_id = t.user_id and x.user_relation = t.user_relation
              and x.condition_name = '' and x.condition_context is null) then
            return;
        end if;
    end if;
    perform permissions.fga_write(
        jsonb_build_object('tuple_keys', jsonb_build_array(jsonb_build_object('user', subject, 'relation', relation, 'object', object)),
                           'on_duplicate', 'ignore'));
end;
$$;

-- Typed path as fga_write_tuple's: deletes only need a well-formed key (and a
-- model to exist, as fga_write requires).
create function permissions.fga_delete_tuple(subject text, relation text, object text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    t permissions.fga_tuple := permissions._fga_typed_key(subject, relation, object);
begin
    if t.object_type is not null and t.relation ~ '^[^:#@ [:cntrl:]]+$'
       and exists (select 1 from permissions.fga_models) then
        delete from permissions.fga_tuples x
        where x.object_type = t.object_type and x.object_id = t.object_id and x.relation = t.relation
          and x.user_type = t.user_type and x.user_id = t.user_id and x.user_relation = t.user_relation;
        return;
    end if;
    perform permissions.fga_write(deletes => jsonb_build_object(
        'tuple_keys', jsonb_build_array(jsonb_build_object('user', subject, 'relation', relation, 'object', object)),
        'on_missing', 'ignore'));
end;
$$;

-- OpenFGA Read: one page of the stored tuples matching a partial key, in
-- insertion order (fga_tuples.seq). object is 'type:id' or 'type:' (every
-- object of the type); subject (OpenFGA's user field) is 'type:id', 'type:*'
-- or 'type:id#relation'. Not filtered by the model. Returns OpenFGA's
-- ReadResponse as one row: tuples, a JSON array of {"key": {"user",
-- "relation", "object"[, "condition": {"name", "context"}]}, "timestamp"}, and
-- continuation_token, '' on the last page. Pass the token back unchanged for
-- the next page (continuation_token is INOUT: the input and the output column
-- share OpenFGA's name, and PL/pgSQL allows one variable per name). page_size:
-- default 50, 1 to 100 (2000 otherwise). The token is base64url (padded) of
-- '<seq>|', seq being the first tuple of the next page (OpenFGA: '<ulid>|'),
-- found by reading page_size + 1 rows. A token outside the base64url alphabet
-- or over 5,120 bytes is 2000; one that doesn't decode to that shape is 2007.
-- A token whose tuple was deleted since seeks past it.
create function permissions.fga_read(object text default null, relation text default null, subject text default null,
                                     page_size int default null,
                                     out tuples jsonb, inout continuation_token text default null)
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
    n := coalesce(fga_read.page_size, l.read_page_default);
    if n not between 1 and l.read_page_max then
        perform permissions._fga_error(2000, format('invalid ReadRequest.PageSize: value must be inside range [1, %s], got %s',
                                                    l.read_page_max, n),
            hint => format('Omit page_size for the default of %s, or pass 1 to %s.', l.read_page_default, l.read_page_max));
    end if;
    if coalesce(fga_read.continuation_token, '') <> '' then
        if octet_length(fga_read.continuation_token) > 5120 or fga_read.continuation_token !~ '^[A-Za-z0-9_-]+={0,2}$' then
            perform permissions._fga_error(2000, case when octet_length(fga_read.continuation_token) > 5120
                then format('invalid ReadRequest.ContinuationToken: value length must be at most 5120 bytes, got %s', octet_length(fga_read.continuation_token))
                else format('invalid ReadRequest.ContinuationToken: value does not match regex pattern "^$|^[A-Za-z0-9-_]+={0,2}$", got %L', fga_read.continuation_token) end,
                hint => 'Pass the continuation_token from the previous fga_read call unchanged, or '''' (or null) for the first page.');
        end if;
        begin
            raw := convert_from(decode(translate(fga_read.continuation_token, '-_', '+/'), 'base64'), 'UTF8');
        exception when others then
            raw := null;
        end;
        if raw is null or raw !~ '^[0-9]{1,18}\|$' then
            perform permissions._fga_error(2007, format('Invalid continuation token: %L', fga_read.continuation_token),
                hint => 'Pass the continuation_token from the previous fga_read call unchanged, or '''' (or null) for the first page.');
        end if;
        from_seq := left(raw, -1)::bigint;
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
               'key', jsonb_build_object('user', permissions._fga_user_string(r.user_type, r.user_id, r.user_relation),
                                         'relation', r.relation, 'object', r.object_type || ':' || r.object_id)
                      || case when r.condition_name <> ''
                              then jsonb_build_object('condition', jsonb_build_object('name', r.condition_name, 'context', r.condition_context))
                              else '{}' end,
               'timestamp', r.inserted_at) order by r.seq) filter (where r.i <= n), '[]'),
           max(r.seq) filter (where r.i > n)
    into fga_read.tuples, nxt
    from (select t.*, row_number() over (order by t.seq) as i
          from (select t.* from permissions.fga_tuples t
                where t.seq >= from_seq
                  and (fga_read.object is null or t.object_type = split_part(fga_read.object, ':', 1))
                  and (fga_read.object is null or split_part(fga_read.object, ':', 2) = ''
                       or t.object_id = substr(fga_read.object, strpos(fga_read.object, ':') + 1))
                  and (fga_read.relation is null or t.relation = fga_read.relation)
                  and (fga_read.subject is null
                       or permissions._fga_user_string(t.user_type, t.user_id, t.user_relation) = fga_read.subject)
                order by t.seq
                limit n + 1) t) r;
    fga_read.continuation_token := coalesce(translate(encode(convert_to(nxt || '|', 'UTF8'), 'base64'), '+/', '-_'), '');
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
--
-- Conditions (research/designs/d-conditions.md section 7): a tuple matches the edge of
-- its own condition (tuple.condition_name = edge.condition), and a
-- conditioned tuple is taken only when its condition is true. Every walk
-- takes p_req (the request's context) and p_mode, how an evaluation error
-- counts: r fails with openfga:2000 (the API's lists), d is false (the RLS
-- helpers' positive walks), n is true (the RLS helpers' subtract walks: an
-- error there removes access), t is reported to the caller (_fga_rec's
-- result 4, Check), e is returned by _fga_bstep as a row (the error walk of
-- Check). The RLS helpers never fail and deny whenever the answer depends on
-- an error: _fga_rec runs in mode t for them and 4 is false. A null p_mode is
-- the unconditioned fast path: the relation is not `conditional`, so the
-- walks run their unconditioned statements and never evaluate a condition.

-- The true ones among (condition, context) pairs ([[name, context], ...]),
-- each evaluated once: a walk step evaluates a condition once per distinct
-- context, however many tuples share it. An error by p_mode: r fails, d is
-- false, n is true, e ends the result with a row (null, the message as a
-- JSON string).
create function permissions._fga_conds_ok(p_m text, p_pairs jsonb, p_req jsonb, p_mode "char")
returns table (cn text, cc jsonb)
language plpgsql stable
rows 10
as $$
declare
    x jsonb;
    r text;
begin
    for x in select jsonb_array_elements(coalesce(p_pairs, '[]')) loop
        r := permissions._fga_cond_eval(p_m, x ->> 0, nullif(x -> 1, 'null'::jsonb), p_req);
        if r = 't' or (r <> 'f' and p_mode = 'n') then
            cn := x ->> 0;
            cc := nullif(x -> 1, 'null'::jsonb);
            return next;
        elsif r <> 'f' then
            if p_mode = 'r' then
                perform permissions._fga_cond_fail(r);
            elsif p_mode = 'e' then
                cn := null;
                cc := to_jsonb(r);
                return next;
                return;
            end if;
        end if;
    end loop;
end;
$$;

-- Each (condition, context) pair of p_pairs ([[name, context], ...])
-- evaluated once: 't', 'f' or the error message (_fga_cond_eval). The
-- forward walks evaluate the pairs of every conditioned tuple their recursion
-- could take this way, then look each tuple up (_fga_cond_take), so a
-- condition is evaluated once per distinct context instead of once per tuple
-- and level (phase 5 of session 5).
create function permissions._fga_conds_eval(p_m text, p_pairs jsonb, p_req jsonb)
returns table (cn text, cc jsonb, r text)
language sql stable
rows 10
as $$
    select x ->> 0, nullif(x -> 1, 'null'::jsonb), permissions._fga_cond_eval(p_m, x ->> 0, nullif(x -> 1, 'null'::jsonb), p_req)
    from jsonb_array_elements(coalesce(p_pairs, '[]')) x
$$;

-- An evaluated pair as a filter, by p_mode as _fga_cond: true, false, an
-- error fails (r), is true (n) or false (d); no pair (null) is false. Called
-- on the one pair of the tuple, looked up by a scalar subquery, so an error
-- counts only for a tuple that has it.
create function permissions._fga_cond_take(p_r text, p_mode "char")
returns boolean
language sql stable
as $$
    select case when p_r is null then false
                when p_r = 't' then true
                when p_r = 'f' then false
                when p_mode = 'r' then permissions._fga_cond_fail(p_r)
                else p_mode = 'n' end
$$;

-- One step forwards from frontier nodes: the tuples whose user is a frontier
-- node (direct and userset edges), the objects whose tupleset points at one
-- (tupleToUserset), then the relations those compute. Levels: a direct edge
-- adds the frontier node's w (0 for the user itself, 1 for a userset), a
-- tupleToUserset adds 1. Nodes already in st/si/sr are dropped. With p_req,
-- conditioned tuples are taken when their condition is true (an error is
-- false: Check's error rule is _fga_bidi_errors').
create function permissions._fga_fstep(
    p_m text, p_ctx permissions.fga_tuple[],
    ft text[], fi text[], fr text[], fl int[], fw int[],
    st text[], si text[], sr text[], p_req jsonb default null)
returns table (t text, i text, r text, l int)
language plpgsql stable
rows 100
as $$
#variable_conflict use_column
begin
    if p_req is null then
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
             and tu.object_type = e.dst_type and tu.relation = e.dst_relation and tu.condition_name = e.condition
          union all
            select c.object_type, c.object_id, c.relation, f.l + f.w
            from f
            join permissions.fga_edges e
              on e.model_id = p_m and e.kind = 'd' and e.src_type = f.t and e.src_relation = f.r
             and e.src_wildcard = (f.i = '*')
            join unnest(p_ctx) c
              on c.user_type = f.t and c.user_id = f.i and c.user_relation = f.r
             and c.object_type = e.dst_type and c.relation = e.dst_relation and c.condition_name = e.condition
          union all
            select tu.object_type, tu.object_id, e.dst_relation, f.l + 1
            from f
            join permissions.fga_edges e
              on e.model_id = p_m and e.kind = 't' and e.src_type = f.t and e.src_relation = f.r
            join permissions.fga_tuples tu
              on tu.user_type = f.t and tu.user_id = f.i and tu.user_relation = ''
             and tu.object_type = e.dst_type and tu.relation = e.via and tu.condition_name = e.condition
          union all
            select c.object_type, c.object_id, e.dst_relation, f.l + 1
            from f
            join permissions.fga_edges e
              on e.model_id = p_m and e.kind = 't' and e.src_type = f.t and e.src_relation = f.r
            join unnest(p_ctx) c
              on c.user_type = f.t and c.user_id = f.i and c.user_relation = ''
             and c.object_type = e.dst_type and c.relation = e.via and c.condition_name = e.condition
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
        return;
    end if;
    return query
    with f(t, i, r, l, w) as materialized (
        select * from unnest(ft, fi, fr, fl, fw)
    ),
    hits(t, i, r, l, cn, cx) as materialized (
        select tu.object_type, tu.object_id, tu.relation, f.l + f.w, tu.condition_name, tu.condition_context
        from f
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 'd' and e.src_type = f.t and e.src_relation = f.r
         and e.src_wildcard = (f.i = '*')
        join permissions.fga_tuples tu
          on tu.user_type = f.t and tu.user_id = f.i and tu.user_relation = f.r
         and tu.object_type = e.dst_type and tu.relation = e.dst_relation and tu.condition_name = e.condition
      union all
        select c.object_type, c.object_id, c.relation, f.l + f.w, c.condition_name, c.condition_context
        from f
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 'd' and e.src_type = f.t and e.src_relation = f.r
         and e.src_wildcard = (f.i = '*')
        join unnest(p_ctx) c
          on c.user_type = f.t and c.user_id = f.i and c.user_relation = f.r
         and c.object_type = e.dst_type and c.relation = e.dst_relation and c.condition_name = e.condition
      union all
        select tu.object_type, tu.object_id, e.dst_relation, f.l + 1, tu.condition_name, tu.condition_context
        from f
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 't' and e.src_type = f.t and e.src_relation = f.r
        join permissions.fga_tuples tu
          on tu.user_type = f.t and tu.user_id = f.i and tu.user_relation = ''
         and tu.object_type = e.dst_type and tu.relation = e.via and tu.condition_name = e.condition
      union all
        select c.object_type, c.object_id, e.dst_relation, f.l + 1, c.condition_name, c.condition_context
        from f
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 't' and e.src_type = f.t and e.src_relation = f.r
        join unnest(p_ctx) c
          on c.user_type = f.t and c.user_id = f.i and c.user_relation = ''
         and c.object_type = e.dst_type and c.relation = e.via and c.condition_name = e.condition
    ),
    ok(cn, cx) as materialized (
        select o.cn, o.cc
        from permissions._fga_conds_ok(p_m, (select jsonb_agg(jsonb_build_array(d.cn, d.cx))
                                             from (select distinct h.cn, h.cx from hits h where h.cn <> '') d),
                                       p_req, 'd') o
    ),
    good(t, i, r, l) as (
        select h.t, h.i, h.r, h.l from hits h where h.cn = ''
      union all
        -- a conditioned tuple always has a context ({} if none was given)
        select h.t, h.i, h.r, h.l from hits h join ok on ok.cn = h.cn and ok.cx = h.cx
    ),
    closed(t, i, r, l) as (
        select * from good
      union all
        select h.t, h.i, cc.dst_relation, h.l
        from good h
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
-- them, Check only probes for its own user. With p_mode, conditioned tuples
-- are taken when their condition is true, an error counted by p_mode (r, d,
-- or e: one row (null, the message) and nothing else); p_types, if given,
-- limits the plain users (and their wildcards) to those types, so ListUsers
-- never evaluates a condition on a user it would not return.
create function permissions._fga_bstep(
    p_m text, p_ctx permissions.fga_tuple[],
    gt text[], gi text[], gr text[], gl int[],
    ut text[], ui text[], ur text[], p_subjects boolean,
    p_req jsonb default null, p_mode "char" default null, p_types text[] default null)
returns table (t text, i text, r text, l int)
language plpgsql stable
rows 100
as $$
#variable_conflict use_column
begin
    if p_mode is null then
        return query
        with g(t, i, r, l) as materialized (
            select * from unnest(gt, gi, gr, gl)
        ),
        nx(t, i, r, l) as (
            -- usersets (fga_tuples_userset_idx), then plain users and wildcards (ListUsers only)
            select x.user_type, x.user_id, x.user_relation, g.l + 1
            from g
            join permissions.fga_edges e
              on e.model_id = p_m and e.kind = 'd' and e.dst_type = g.t and e.dst_relation = g.r
             and e.src_relation <> ''
            join permissions.fga_tuples x
              on x.object_type = g.t and x.object_id = g.i and x.relation = g.r
             and x.user_type = e.src_type and x.user_relation = e.src_relation and x.condition_name = e.condition
            where x.user_relation <> '' and x.user_id <> '*'
          union all
            select x.user_type, x.user_id, x.user_relation, g.l
            from g
            join permissions.fga_edges e
              on e.model_id = p_m and e.kind = 'd' and e.dst_type = g.t and e.dst_relation = g.r
             and e.src_relation = ''
            join permissions.fga_tuples x
              on x.object_type = g.t and x.object_id = g.i and x.relation = g.r
             and x.user_type = e.src_type and x.user_relation = '' and x.condition_name = e.condition
            where p_subjects and (x.user_id = '*') = e.src_wildcard
          union all
            select x.user_type, x.user_id, x.user_relation, g.l + case when x.user_relation = '' then 0 else 1 end
            from g
            join permissions.fga_edges e
              on e.model_id = p_m and e.kind = 'd' and e.dst_type = g.t and e.dst_relation = g.r
             and (p_subjects or e.src_relation <> '')
            join unnest(p_ctx) x
              on x.object_type = g.t and x.object_id = g.i and x.relation = g.r
             and x.user_type = e.src_type and x.user_relation = e.src_relation and x.condition_name = e.condition
            where (x.user_id = '*') = e.src_wildcard
          union all
            select x.user_type, x.user_id, e.src_relation, g.l + 1
            from g
            join permissions.fga_edges e
              on e.model_id = p_m and e.kind = 't' and e.dst_type = g.t and e.dst_relation = g.r
            join permissions.fga_tuples x
              on x.object_type = g.t and x.object_id = g.i and x.relation = e.via
             and x.user_type = e.src_type and x.user_relation = '' and x.condition_name = e.condition
          union all
            select x.user_type, x.user_id, e.src_relation, g.l + 1
            from g
            join permissions.fga_edges e
              on e.model_id = p_m and e.kind = 't' and e.dst_type = g.t and e.dst_relation = g.r
            join unnest(p_ctx) x
              on x.object_type = g.t and x.object_id = g.i and x.relation = e.via
             and x.user_type = e.src_type and x.user_relation = '' and x.condition_name = e.condition
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
        return;
    end if;
    return query
    with g(t, i, r, l) as materialized (
        select * from unnest(gt, gi, gr, gl)
    ),
    nx(t, i, r, l, cn, cx) as materialized (
        -- usersets (fga_tuples_userset_idx), then plain users and wildcards (ListUsers only)
        select x.user_type, x.user_id, x.user_relation, g.l + 1, x.condition_name, x.condition_context
        from g
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 'd' and e.dst_type = g.t and e.dst_relation = g.r
         and e.src_relation <> ''
        join permissions.fga_tuples x
          on x.object_type = g.t and x.object_id = g.i and x.relation = g.r
         and x.user_type = e.src_type and x.user_relation = e.src_relation and x.condition_name = e.condition
        where x.user_relation <> '' and x.user_id <> '*'
      union all
        select x.user_type, x.user_id, x.user_relation, g.l, x.condition_name, x.condition_context
        from g
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 'd' and e.dst_type = g.t and e.dst_relation = g.r
         and e.src_relation = ''
         and (p_types is null or e.src_type = any (p_types))
        join permissions.fga_tuples x
          on x.object_type = g.t and x.object_id = g.i and x.relation = g.r
         and x.user_type = e.src_type and x.user_relation = '' and x.condition_name = e.condition
        where p_subjects and (x.user_id = '*') = e.src_wildcard
      union all
        select x.user_type, x.user_id, x.user_relation, g.l + case when x.user_relation = '' then 0 else 1 end,
               x.condition_name, x.condition_context
        from g
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 'd' and e.dst_type = g.t and e.dst_relation = g.r
         and (p_subjects or e.src_relation <> '')
         and (e.src_relation <> '' or p_types is null or e.src_type = any (p_types))
        join unnest(p_ctx) x
          on x.object_type = g.t and x.object_id = g.i and x.relation = g.r
         and x.user_type = e.src_type and x.user_relation = e.src_relation and x.condition_name = e.condition
        where (x.user_id = '*') = e.src_wildcard
      union all
        select x.user_type, x.user_id, e.src_relation, g.l + 1, x.condition_name, x.condition_context
        from g
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 't' and e.dst_type = g.t and e.dst_relation = g.r
        join permissions.fga_tuples x
          on x.object_type = g.t and x.object_id = g.i and x.relation = e.via
         and x.user_type = e.src_type and x.user_relation = '' and x.condition_name = e.condition
      union all
        select x.user_type, x.user_id, e.src_relation, g.l + 1, x.condition_name, x.condition_context
        from g
        join permissions.fga_edges e
          on e.model_id = p_m and e.kind = 't' and e.dst_type = g.t and e.dst_relation = g.r
        join unnest(p_ctx) x
          on x.object_type = g.t and x.object_id = g.i and x.relation = e.via
         and x.user_type = e.src_type and x.user_relation = '' and x.condition_name = e.condition
    ),
    ok(cn, cx) as materialized (
        select o.cn, o.cc
        from permissions._fga_conds_ok(p_m, (select jsonb_agg(jsonb_build_array(d.cn, d.cx))
                                             from (select distinct n.cn, n.cx from nx n where n.cn <> '') d),
                                       p_req, p_mode) o
    ),
    good(t, i, r, l) as (
        select n.t, n.i, n.r, n.l from nx n
        where n.cn = '' and not exists (select 1 from ok where ok.cn is null)
      union all
        -- a conditioned tuple always has a context ({} if none was given)
        select n.t, n.i, n.r, n.l from nx n join ok on ok.cn = n.cn and ok.cx = n.cx
        where not exists (select 1 from ok where ok.cn is null)
    ),
    closed(t, i, r, l) as (
        select * from good
      union all
        select n.t, n.i, cc.src_relation, n.l
        from good n
        join permissions.fga_computed_closure cc
          on cc.model_id = p_m and cc.type = n.t and cc.dst_relation = n.r
        where n.r <> ''
    )
    select c.t, c.i, c.r, min(c.l)::int
    from closed c
    where not exists (select 1 from unnest(ut, ui, ur) s(t, i, r)
                      where s.t = c.t and s.i = c.i and s.r = c.r)
    group by c.t, c.i, c.r
    union all
    select null, ok.cx #>> '{}', null, null from ok where ok.cn is null;
end;
$$;

-- Check on a monotone relation: a bidirectional search, each step expanding
-- the smaller frontier, until the two sides meet. Returns 1 (allowed) if they
-- meet within p_max levels, 3 if only deeper, 0 if never. With p_mode
-- (conditional relations), conditioned tuples are taken when true and an
-- error counts as false; then a false answer runs the error walk
-- (_fga_bidi_errors, OpenFGA's rule): p_mode r fails with its error, t
-- returns 4 (a condition error, for _fga_rec), d returns 0 (RLS).
create function permissions._fga_bidi(
    p_m text, p_ot text, p_oid text, p_rel text, p_ut text, p_uid text, p_urel text,
    p_ctx permissions.fga_tuple[], p_max int, p_req jsonb default null, p_mode "char" default null)
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
    rq jsonb := case when p_mode is not null then p_req end;
    bm "char" := case when p_mode is not null then 'd' end;
    msg text;
    fwd_rel boolean := p_urel <> '';                       -- the forward side holds relation nodes
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
            from permissions._fga_fstep(p_m, p_ctx, ft, fi, fr, fl, fw, st, si, sr, rq) n;
            exit when ft is null;
            fw := array_fill(1, array[cardinality(ft)]);
            st := st || ft; si := si || fi; sr := sr || fr; sl := sl || fl;
            fwd_rel := true;
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
                            and x.user_type = s.t and x.user_id = s.i and x.user_relation = s.r
                            and x.condition_name = e.condition
                            and (x.condition_name = '' or permissions._fga_cond(p_m, x.condition_name, x.condition_context, p_req, 'd')))
               or exists (select 1 from unnest(p_ctx) x
                          where x.object_type = g.t and x.object_id = g.i and x.relation = g.r
                            and x.user_type = s.t and x.user_id = s.i and x.user_relation = s.r
                            and x.condition_name = e.condition
                            and (x.condition_name = '' or permissions._fga_cond(p_m, x.condition_name, x.condition_context, p_req, 'd')));
            continue when best is not null;
            select array_agg(n.t), array_agg(n.i), array_agg(n.r), array_agg(n.l)
            into gt, gi, gr, gl
            from permissions._fga_bstep(p_m, p_ctx, gt, gi, gr, gl, ut, ui, ur, false, rq, bm) n;
            exit when gt is null;
            ut := ut || gt; ui := ui || gi; ur := ur || gr; ul := ul || gl;
            -- a plain user's forward side holds only the user (relation '')
            -- until its first step: nothing to meet yet
            continue when not fwd_rel;
            select min(f.l + b.l) into best
            from unnest(st, si, sr, sl) f(t, i, r, l)
            join unnest(gt, gi, gr, gl) b(t, i, r, l) on b.t = f.t and b.i = f.i and b.r = f.r;
        end if;
    end loop;
    if p_mode in ('r', 't') then
        msg := permissions._fga_bidi_errors(p_m, p_ot, p_oid, p_rel, p_ut, p_uid, p_urel, p_ctx, p_req);
        if msg is not null then
            if p_mode = 'r' then
                perform permissions._fga_cond_fail(msg);
            end if;
            return 4;
        end if;
    end if;
    return 0;
end;
$$;

-- OpenFGA's error rule for a Check that found no true path (research/designs/d-conditions.md
-- section 3, rule 7): its top-down search fails with the error of any
-- conditioned tuple it evaluates, even one off the user's path. That search
-- reads, from the object down, the userset and tupleset tuples of every node
-- it reaches (taking those whose condition is true) and the user's own
-- tuples (and its wildcard's) on each node. Walks that backward closure (up
-- to depth 25) and returns the first evaluation error, or null.
create function permissions._fga_bidi_errors(
    p_m text, p_ot text, p_oid text, p_rel text, p_ut text, p_uid text, p_urel text,
    p_ctx permissions.fga_tuple[], p_req jsonb)
returns text
language plpgsql stable
as $$
declare
    xt text[]; xi text[]; xr text[];
    gt text[]; gi text[]; gr text[]; gl int[];
    ut text[]; ui text[]; ur text[];
    nt text[]; ni text[]; nr text[]; nl int[];
    msg text;
begin
    xt := array[p_ut]; xi := array[p_uid]; xr := array[p_urel];
    if p_urel = '' and p_uid <> '*' then
        xt := xt || p_ut; xi := xi || '*'::text; xr := xr || ''::text;
    end if;
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
    loop
        -- the user's own conditioned tuples on the frontier
        select o.cc #>> '{}' into msg
        from permissions._fga_conds_ok(p_m, (
            select jsonb_agg(distinct jsonb_build_array(x.cn, x.cx))
            from unnest(gt, gi, gr) g(t, i, r)
            cross join unnest(xt, xi, xr) s(t, i, r)
            join permissions.fga_edges e
              on e.model_id = p_m and e.kind = 'd' and e.dst_type = g.t and e.dst_relation = g.r
             and e.src_type = s.t and e.src_relation = s.r and e.src_wildcard = (s.i = '*') and e.condition <> ''
            cross join lateral (
                select tu.condition_name, tu.condition_context from permissions.fga_tuples tu
                where tu.object_type = g.t and tu.object_id = g.i and tu.relation = g.r
                  and tu.user_type = s.t and tu.user_id = s.i and tu.user_relation = s.r and tu.condition_name = e.condition
              union all
                select c.condition_name, c.condition_context from unnest(p_ctx) c
                where c.object_type = g.t and c.object_id = g.i and c.relation = g.r
                  and c.user_type = s.t and c.user_id = s.i and c.user_relation = s.r and c.condition_name = e.condition
            ) x(cn, cx)), p_req, 'e') o
        where o.cn is null;
        if msg is not null then
            return msg;
        end if;
        select array_agg(n.t), array_agg(n.i), array_agg(n.r), array_agg(n.l)
        into nt, ni, nr, nl
        from permissions._fga_bstep(p_m, p_ctx, gt, gi, gr, gl, ut, ui, ur, false, p_req, 'e') n;
        if nt is not null and array_position(nt, null) is not null then
            return ni[array_position(nt, null)];
        end if;
        ut := ut || nt; ui := ui || ni; ur := ur || nr;
        select array_agg(n.t), array_agg(n.i), array_agg(n.r), array_agg(n.l)
        into gt, gi, gr, gl
        from unnest(nt, ni, nr, nl) n(t, i, r, l) where n.l < 25;
        exit when gt is null;
    end loop;
    return null;
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
--
-- With p_mode (r or d), a conditioned tuple is taken when its condition is
-- true: evaluated per tuple inside the recursion (a recursive term can't
-- deduplicate), once per distinct context for the leaves.
--
-- p_direct: only the objects reached through a direct tuple on p_rel itself
-- (the `this` operand of p_rel's rewrite; the set-based evaluator,
-- _fga_set_node), not through its other operands nor the user being
-- p_type:id#p_rel.
create function permissions._fga_forward(
    p_m text, p_ut text, p_uid text, p_urel text, p_ctx permissions.fga_tuple[],
    p_type text, p_rel text, p_req jsonb default null, p_mode "char" default null,
    p_direct boolean default false)
returns table (object_id text, lvl int)
language plpgsql stable
rows 100
as $$
#variable_conflict use_column
begin
    if p_mode is null then
        return query
        with recursive
        st as materialized (
            select s.kind, s.src_type, s.src_relation, s.src_wildcard, s.user_relation,
                   s.object_type, s.tuple_relation, s.out_relation, s.expand, s.condition
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
                  and tu.condition_name = st.condition
              union all
                select x.object_type, x.object_id, st.out_relation,
                       w.l + case when st.kind = 'd' then w.c else 1 end
                from unnest(p_ctx) x
                where x.user_type = w.t and x.user_id = w.i and x.user_relation = st.user_relation
                  and x.object_type = st.object_type and x.relation = st.tuple_relation
                  and x.condition_name = st.condition
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
            select b.i, b.l from b where b.t = p_type and b.r = p_rel and not p_direct
          union all
            select n.i, n.l
            from b
            join st on st.src_type = b.t and st.src_relation = b.r and st.src_wildcard = (b.i = '*')
                   and st.object_type = p_type and st.out_relation = p_rel
                   and (not p_direct or (st.kind = 'd' and st.tuple_relation = p_rel))
            cross join lateral (
                select tu.object_id, case when st.kind = 'd' then b.dl else b.l + 1 end
                from permissions.fga_tuples tu
                where tu.user_type = b.t and tu.user_id = b.i and tu.user_relation = st.user_relation
                  and tu.object_type = st.object_type and tu.relation = st.tuple_relation
                  and tu.condition_name = st.condition
              union all
                select x.object_id, case when st.kind = 'd' then b.dl else b.l + 1 end
                from unnest(p_ctx) x
                where x.user_type = b.t and x.user_id = b.i and x.user_relation = st.user_relation
                  and x.object_type = st.object_type and x.relation = st.tuple_relation
                  and x.condition_name = st.condition
                offset 0
            ) n(i, l)
        ),
        res(i, l) as materialized (
            select tg.i, min(tg.l) from tg group by tg.i
        )
        select res.i, least(res.l, 25) from res
        union all
        select f, 25
        from permissions._fga_forward_ids(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, p_rel, null, null, p_direct) f
        where exists (select 1 from b where b.l >= 25)
          and not exists (select 1 from res where res.i = f);
        return;
    end if;
    return query
    with recursive
    st as materialized (
        select s.kind, s.src_type, s.src_relation, s.src_wildcard, s.user_relation,
               s.object_type, s.tuple_relation, s.out_relation, s.expand, s.condition
        from permissions.fga_walk_steps s
        where s.model_id = p_m and s.target_type = p_type and s.target_relation = p_rel
    ),
    -- first the recursion without conditions and levels (one row per node,
    -- a superset of what the walk reaches), for the distinct (condition,
    -- context) pairs of the conditioned tuples it could take, each evaluated
    -- once (ev); the leveled walk then takes a tuple by looking its pair up,
    -- so an error counts only on a tuple it takes
    w0(t, i, r) as (
        select p_ut::text collate "C", p_uid::text collate "C", p_urel::text collate "C"
      union all
        select p_ut, '*', '' where p_urel = '' and p_uid <> '*'
      union all
        select p_ut, p_uid, cc.dst_relation
        from permissions.fga_computed_closure cc
        where cc.model_id = p_m and cc.type = p_ut and cc.src_relation = p_urel and p_urel <> ''
      union
        select n.t, n.i, n.r
        from w0
        join st on st.src_type = w0.t and st.src_relation = w0.r and st.src_wildcard = (w0.i = '*') and st.expand
        cross join lateral (
            select tu.object_type, tu.object_id, st.out_relation
            from permissions.fga_tuples tu
            where tu.user_type = w0.t and tu.user_id = w0.i and tu.user_relation = st.user_relation
              and tu.object_type = st.object_type and tu.relation = st.tuple_relation
              and tu.condition_name = st.condition
          union all
            select x.object_type, x.object_id, st.out_relation
            from unnest(p_ctx) x
            where x.user_type = w0.t and x.user_id = w0.i and x.user_relation = st.user_relation
              and x.object_type = st.object_type and x.relation = st.tuple_relation
              and x.condition_name = st.condition
            offset 0
        ) n(t, i, r)
    ),
    ev(cn, cc, r) as materialized (
        select e.cn, e.cc, e.r
        from permissions._fga_conds_eval(p_m, (
            select jsonb_agg(jsonb_build_array(d.cn, d.cx))
            from (select distinct tu.condition_name as cn, tu.condition_context as cx
                  from w0
                  join st on st.src_type = w0.t and st.src_relation = w0.r and st.src_wildcard = (w0.i = '*')
                         and st.expand and st.condition <> ''
                  join permissions.fga_tuples tu
                    on tu.user_type = w0.t and tu.user_id = w0.i and tu.user_relation = st.user_relation
                   and tu.object_type = st.object_type and tu.relation = st.tuple_relation
                   and tu.condition_name = st.condition
                union
                  select x.condition_name, x.condition_context
                  from unnest(p_ctx) x
                  where x.condition_name <> '') d), p_req) e
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
              and tu.condition_name = st.condition
              and (tu.condition_name = '' or permissions._fga_cond_take(
                       (select ev.r from ev where ev.cn = tu.condition_name and ev.cc = tu.condition_context), p_mode))
          union all
            select x.object_type, x.object_id, st.out_relation,
                   w.l + case when st.kind = 'd' then w.c else 1 end
            from unnest(p_ctx) x
            where x.user_type = w.t and x.user_id = w.i and x.user_relation = st.user_relation
              and x.object_type = st.object_type and x.relation = st.tuple_relation
              and x.condition_name = st.condition
              and (x.condition_name = '' or permissions._fga_cond_take(
                       (select ev.r from ev where ev.cn = x.condition_name and ev.cc = x.condition_context), p_mode))
            offset 0
        ) n(t, i, r, l)
        where w.l < 25
    ),
    b(t, i, r, l, dl) as materialized (
        select w.t, w.i, w.r, min(w.l), min(w.l + w.c) from w group by w.t, w.i, w.r
    ),
    leaves(i, l, cn, cx) as materialized (
        select n.i, n.l, n.cn, n.cx
        from b
        join st on st.src_type = b.t and st.src_relation = b.r and st.src_wildcard = (b.i = '*')
               and st.object_type = p_type and st.out_relation = p_rel
               and (not p_direct or (st.kind = 'd' and st.tuple_relation = p_rel))
        cross join lateral (
            select tu.object_id, case when st.kind = 'd' then b.dl else b.l + 1 end, tu.condition_name, tu.condition_context
            from permissions.fga_tuples tu
            where tu.user_type = b.t and tu.user_id = b.i and tu.user_relation = st.user_relation
              and tu.object_type = st.object_type and tu.relation = st.tuple_relation
              and tu.condition_name = st.condition
          union all
            select x.object_id, case when st.kind = 'd' then b.dl else b.l + 1 end, x.condition_name, x.condition_context
            from unnest(p_ctx) x
            where x.user_type = b.t and x.user_id = b.i and x.user_relation = st.user_relation
              and x.object_type = st.object_type and x.relation = st.tuple_relation
              and x.condition_name = st.condition
            offset 0
        ) n(i, l, cn, cx)
    ),
    ok(cn, cx) as materialized (
        select o.cn, o.cc
        from permissions._fga_conds_ok(p_m, (select jsonb_agg(jsonb_build_array(d.cn, d.cx))
                                             from (select distinct v.cn, v.cx from leaves v where v.cn <> '') d),
                                       p_req, p_mode) o
    ),
    tg(i, l) as (
        select b.i, b.l from b where b.t = p_type and b.r = p_rel and not p_direct
      union all
        select v.i, v.l from leaves v where v.cn = ''
      union all
        -- a conditioned tuple always has a context ({} if none was given)
        select v.i, v.l from leaves v join ok on ok.cn = v.cn and ok.cx = v.cx
    ),
    res(i, l) as materialized (
        select tg.i, min(tg.l) from tg group by tg.i
    )
    select res.i, least(res.l, 25) from res
    union all
    select f, 25
    from permissions._fga_forward_ids(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, p_rel, p_req, p_mode, p_direct) f
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
    p_type text, p_rel text, p_req jsonb default null, p_mode "char" default null,
    p_direct boolean default false)
returns setof text
language plpgsql stable
rows 100
as $$
#variable_conflict use_column
begin
    if p_mode is null then
        return query
        with recursive
        st as materialized (
            select s.kind, s.src_type, s.src_relation, s.src_wildcard, s.user_relation,
                   s.object_type, s.tuple_relation, s.out_relation, s.expand, s.condition
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
                  and tu.condition_name = st.condition
              union all
                select x.object_type, x.object_id, st.out_relation
                from unnest(p_ctx) x
                where x.user_type = w.t and x.user_id = w.i and x.user_relation = st.user_relation
                  and x.object_type = st.object_type and x.relation = st.tuple_relation
                  and x.condition_name = st.condition
                offset 0
            ) n(t, i, r)
        )
        select w.i from w where w.t = p_type and w.r = p_rel and not p_direct
        union
        select n.i
        from w
        join st on st.src_type = w.t and st.src_relation = w.r and st.src_wildcard = (w.i = '*')
               and st.object_type = p_type and st.out_relation = p_rel
               and (not p_direct or (st.kind = 'd' and st.tuple_relation = p_rel))
        cross join lateral (
            select tu.object_id
            from permissions.fga_tuples tu
            where tu.user_type = w.t and tu.user_id = w.i and tu.user_relation = st.user_relation
              and tu.object_type = st.object_type and tu.relation = st.tuple_relation
              and tu.condition_name = st.condition
          union all
            select x.object_id
            from unnest(p_ctx) x
            where x.user_type = w.t and x.user_id = w.i and x.user_relation = st.user_relation
              and x.object_type = st.object_type and x.relation = st.tuple_relation
              and x.condition_name = st.condition
            offset 0
        ) n(i);
        return;
    end if;
    return query
    with recursive
    st as materialized (
        select s.kind, s.src_type, s.src_relation, s.src_wildcard, s.user_relation,
               s.object_type, s.tuple_relation, s.out_relation, s.expand, s.condition
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
              and tu.condition_name = st.condition
              and (tu.condition_name = '' or permissions._fga_cond(p_m, tu.condition_name, tu.condition_context, p_req, p_mode))
          union all
            select x.object_type, x.object_id, st.out_relation
            from unnest(p_ctx) x
            where x.user_type = w.t and x.user_id = w.i and x.user_relation = st.user_relation
              and x.object_type = st.object_type and x.relation = st.tuple_relation
              and x.condition_name = st.condition
              and (x.condition_name = '' or permissions._fga_cond(p_m, x.condition_name, x.condition_context, p_req, p_mode))
            offset 0
        ) n(t, i, r)
    ),
    leaves(i, cn, cx) as materialized (
        select n.i, n.cn, n.cx
        from w
        join st on st.src_type = w.t and st.src_relation = w.r and st.src_wildcard = (w.i = '*')
               and st.object_type = p_type and st.out_relation = p_rel
               and (not p_direct or (st.kind = 'd' and st.tuple_relation = p_rel))
        cross join lateral (
            select tu.object_id, tu.condition_name, tu.condition_context
            from permissions.fga_tuples tu
            where tu.user_type = w.t and tu.user_id = w.i and tu.user_relation = st.user_relation
              and tu.object_type = st.object_type and tu.relation = st.tuple_relation
              and tu.condition_name = st.condition
          union all
            select x.object_id, x.condition_name, x.condition_context
            from unnest(p_ctx) x
            where x.user_type = w.t and x.user_id = w.i and x.user_relation = st.user_relation
              and x.object_type = st.object_type and x.relation = st.tuple_relation
              and x.condition_name = st.condition
            offset 0
        ) n(i, cn, cx)
    ),
    ok(cn, cx) as materialized (
        select o.cn, o.cc
        from permissions._fga_conds_ok(p_m, (select jsonb_agg(jsonb_build_array(d.cn, d.cx))
                                             from (select distinct v.cn, v.cx from leaves v where v.cn <> '') d),
                                       p_req, p_mode) o
    )
    select w.i from w where w.t = p_type and w.r = p_rel and not p_direct
    union
    select v.i from leaves v where v.cn = ''
    union
    -- a conditioned tuple always has a context ({} if none was given)
    select v.i from leaves v join ok on ok.cn = v.cn and ok.cx = v.cx;
end;
$$;

-- Everything p_type:p_id#p_rel reaches backwards in the positive graph:
-- relation nodes (usersets, tupleset parents, computed-from relations) and,
-- with relation '', the plain users and wildcards in their tuples. Raises
-- 2002 when a relation node is p_max levels deep, as OpenFGA's ListUsers does.
-- With p_mode, conditions as _fga_bstep; p_types limits the plain users.
create function permissions._fga_backward(
    p_m text, p_ot text, p_oid text, p_rel text, p_ctx permissions.fga_tuple[], p_max int,
    p_req jsonb default null, p_mode "char" default null, p_types text[] default null)
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
        from permissions._fga_bstep(p_m, p_ctx, gt, gi, gr, gl, ut, ui, ur, true, p_req, p_mode, p_types) n;
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
-- deep, 4 a condition error (p_mode t). The cycle flag only matters under the
-- subtract of a difference (a cycle there makes the difference false). A
-- monotone relation, under a subtract or not, goes to the set-based search
-- instead: its least fixpoint, in which a cycle of usersets contributes
-- nobody (research/designs/d-per-model.md §5). So the flag only comes from recursion
-- through a non-monotone relation, such as a relation that reaches itself
-- through a subtract.
--
-- Conditions are evaluated where OpenFGA's top-down search evaluates them:
-- the user's own tuple (or its wildcard's), each userset tuple, each
-- tupleset tuple. False skips the tuple; an error is 4 in mode t (combined
-- like 3, which outranks it), fails in mode r, is false in mode d.
create function permissions._fga_rec(
    p_m text, p_ot text, p_oid text, p_rel text, p_ut text, p_uid text, p_urel text,
    p_ctx permissions.fga_tuple[], p_depth int, p_path text[],
    p_req jsonb default null, p_mode "char" default null)
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
        return permissions._fga_bidi(p_m, p_ot, p_oid, p_rel, p_ut, p_uid, p_urel, p_ctx, 25 - p_depth, p_req, p_mode);
    end if;
    select array_agg(n.op order by n.node), array_agg(n.parent order by n.node),
           array_agg(n.computed order by n.node), array_agg(n.tupleset order by n.node)
    into ops, pars, cs, tss
    from permissions.fga_rewrite_nodes n
    where n.model_id = p_m and n.type = p_ot and n.relation = p_rel;
    return permissions._fga_rec_node(p_m, ops, pars, cs, tss, 1, p_ot, p_oid, p_rel,
                                     p_ut, p_uid, p_urel, p_ctx, p_depth, p_path || k, p_req, p_mode);
end;
$$;

-- One node of a relation's rewrite tree (arrays from fga_rewrite_nodes, index k).
create function permissions._fga_rec_node(
    p_m text, ops text[], pars int[], cs text[], tss text[], k int,
    p_ot text, p_oid text, p_rel text, p_ut text, p_uid text, p_urel text,
    p_ctx permissions.fga_tuple[], p_depth int, p_path text[],
    p_req jsonb default null, p_mode "char" default null)
returns smallint
language plpgsql stable
as $$
declare
    x smallint;
    b smallint;
    err boolean := false;
    cyc boolean := false;
    cerr boolean := false;
    ok boolean;
    j int;
    first_child int;
    second_child int;
    rec record;
begin
    case ops[k]
    when 'this' then
        -- the user itself in a tuple, or (for a plain user) its type's wildcard
        if p_mode is null then
            if exists (
                select 1
                from permissions.fga_type_restrictions tr
                cross join (values (p_uid::text), ('*'::text)) c(uid)
                where tr.model_id = p_m and tr.type = p_ot and tr.relation = p_rel
                  and tr.user_type = p_ut and tr.user_relation = p_urel and tr.wildcard = (c.uid = '*')
                  and (c.uid = p_uid or p_urel = '')
                  and (exists (select 1 from permissions.fga_tuples t
                               where t.object_type = p_ot and t.object_id = p_oid and t.relation = p_rel
                                 and t.user_type = p_ut and t.user_id = c.uid and t.user_relation = p_urel
                                 and t.condition_name = tr.condition)
                       or exists (select 1 from unnest(p_ctx) t
                                  where t.object_type = p_ot and t.object_id = p_oid and t.relation = p_rel
                                    and t.user_type = p_ut and t.user_id = c.uid and t.user_relation = p_urel
                                    and t.condition_name = tr.condition))) then
                return 1;
            end if;
        else
            for rec in
                select t.condition_name as cn, t.condition_context as cx
                from permissions.fga_type_restrictions tr
                cross join (values (p_uid::text), ('*'::text)) c(uid)
                join permissions.fga_tuples t
                  on t.object_type = p_ot and t.object_id = p_oid and t.relation = p_rel
                 and t.user_type = p_ut and t.user_id = c.uid and t.user_relation = p_urel
                 and t.condition_name = tr.condition
                where tr.model_id = p_m and tr.type = p_ot and tr.relation = p_rel
                  and tr.user_type = p_ut and tr.user_relation = p_urel and tr.wildcard = (c.uid = '*')
                  and (c.uid = p_uid or p_urel = '')
              union all
                select t.condition_name, t.condition_context
                from permissions.fga_type_restrictions tr
                cross join (values (p_uid::text), ('*'::text)) c(uid)
                join unnest(p_ctx) t
                  on t.object_type = p_ot and t.object_id = p_oid and t.relation = p_rel
                 and t.user_type = p_ut and t.user_id = c.uid and t.user_relation = p_urel
                 and t.condition_name = tr.condition
                where tr.model_id = p_m and tr.type = p_ot and tr.relation = p_rel
                  and tr.user_type = p_ut and tr.user_relation = p_urel and tr.wildcard = (c.uid = '*')
                  and (c.uid = p_uid or p_urel = '')
            loop
                ok := permissions._fga_cond(p_m, rec.cn, rec.cx, p_req, p_mode);
                if ok then return 1; end if;
                cerr := cerr or ok is null;
            end loop;
        end if;
        for rec in
            select t.user_type, t.user_id, t.user_relation, t.condition_name as cn, t.condition_context as cx
            from permissions.fga_type_restrictions tr
            join permissions.fga_tuples t
              on t.object_type = p_ot and t.object_id = p_oid and t.relation = p_rel
             and t.user_type = tr.user_type and t.user_relation = tr.user_relation and t.condition_name = tr.condition
            where tr.model_id = p_m and tr.type = p_ot and tr.relation = p_rel and tr.user_relation <> ''
          union
            select t.user_type, t.user_id, t.user_relation, t.condition_name, t.condition_context
            from permissions.fga_type_restrictions tr
            join unnest(p_ctx) t
              on t.object_type = p_ot and t.object_id = p_oid and t.relation = p_rel
             and t.user_type = tr.user_type and t.user_relation = tr.user_relation and t.condition_name = tr.condition
            where tr.model_id = p_m and tr.type = p_ot and tr.relation = p_rel and tr.user_relation <> ''
        loop
            if rec.cn <> '' then
                ok := permissions._fga_cond(p_m, rec.cn, rec.cx, p_req, p_mode);
                cerr := cerr or ok is null;
                continue when not coalesce(ok, false);
            end if;
            x := permissions._fga_rec(p_m, rec.user_type, rec.user_id, rec.user_relation, p_ut, p_uid, p_urel,
                                      p_ctx, p_depth + 1, p_path, p_req, p_mode);
            if x = 1 then return 1; end if;
            err := err or x = 3;
            cerr := cerr or x = 4;
            cyc := cyc or x = 2;
        end loop;
        return case when err then 3 when cerr then 4 when cyc then 2 else 0 end;

    when 'computed' then
        return permissions._fga_rec(p_m, p_ot, p_oid, cs[k], p_ut, p_uid, p_urel, p_ctx, p_depth, p_path, p_req, p_mode);

    when 'ttu' then
        for rec in
            select t.user_type, t.user_id, t.condition_name as cn, t.condition_context as cx
            from permissions.fga_type_restrictions tr
            join permissions.fga_tuples t
              on t.object_type = p_ot and t.object_id = p_oid and t.relation = tss[k]
             and t.user_type = tr.user_type and t.user_relation = '' and t.condition_name = tr.condition
            join permissions.fga_relations r on r.model_id = p_m and r.type = t.user_type and r.relation = cs[k]
            where tr.model_id = p_m and tr.type = p_ot and tr.relation = tss[k]
              and tr.user_relation = '' and not tr.wildcard and t.user_id <> '*'
          union
            select t.user_type, t.user_id, t.condition_name, t.condition_context
            from permissions.fga_type_restrictions tr
            join unnest(p_ctx) t
              on t.object_type = p_ot and t.object_id = p_oid and t.relation = tss[k]
             and t.user_type = tr.user_type and t.user_relation = '' and t.condition_name = tr.condition
            join permissions.fga_relations r on r.model_id = p_m and r.type = t.user_type and r.relation = cs[k]
            where tr.model_id = p_m and tr.type = p_ot and tr.relation = tss[k]
              and tr.user_relation = '' and not tr.wildcard and t.user_id <> '*'
        loop
            if rec.cn <> '' then
                ok := permissions._fga_cond(p_m, rec.cn, rec.cx, p_req, p_mode);
                cerr := cerr or ok is null;
                continue when not coalesce(ok, false);
            end if;
            x := permissions._fga_rec(p_m, rec.user_type, rec.user_id, cs[k], p_ut, p_uid, p_urel,
                                      p_ctx, p_depth + 1, p_path, p_req, p_mode);
            if x = 1 then return 1; end if;
            err := err or x = 3;
            cerr := cerr or x = 4;
            cyc := cyc or x = 2;
        end loop;
        return case when err then 3 when cerr then 4 when cyc then 2 else 0 end;

    when 'union' then
        for j in k + 1 .. cardinality(ops) loop
            continue when pars[j] is distinct from k;
            x := permissions._fga_rec_node(p_m, ops, pars, cs, tss, j, p_ot, p_oid, p_rel,
                                           p_ut, p_uid, p_urel, p_ctx, p_depth, p_path, p_req, p_mode);
            if x = 1 then return 1; end if;
            err := err or x = 3;
            cerr := cerr or x = 4;
            cyc := cyc or x = 2;
        end loop;
        return case when err then 3 when cerr then 4 when cyc then 2 else 0 end;

    when 'intersection' then
        for j in k + 1 .. cardinality(ops) loop
            continue when pars[j] is distinct from k;
            x := permissions._fga_rec_node(p_m, ops, pars, cs, tss, j, p_ot, p_oid, p_rel,
                                           p_ut, p_uid, p_urel, p_ctx, p_depth, p_path, p_req, p_mode);
            if x in (0, 2) then return x; end if;
            err := err or x = 3;
            cerr := cerr or x = 4;
        end loop;
        return case when err then 3 when cerr then 4 else 1 end;

    when 'difference' then
        for j in k + 1 .. cardinality(ops) loop
            continue when pars[j] is distinct from k;
            if first_child is null then first_child := j; else second_child := j; exit; end if;
        end loop;
        b := permissions._fga_rec_node(p_m, ops, pars, cs, tss, first_child, p_ot, p_oid, p_rel,
                                       p_ut, p_uid, p_urel, p_ctx, p_depth, p_path, p_req, p_mode);
        if b in (0, 2) then return b; end if;
        x := permissions._fga_rec_node(p_m, ops, pars, cs, tss, second_child, p_ot, p_oid, p_rel,
                                       p_ut, p_uid, p_urel, p_ctx, p_depth, p_path, p_req, p_mode);
        if x = 1 then return 0; end if;
        if x = 2 then return 2; end if;
        if b = 3 or x = 3 then return 3; end if;
        if b = 4 or x = 4 then return 4; end if;
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

-- _fga_rec on a list candidate or a Check: true or false, raising 2002 when
-- too deep. _fga_rec runs in mode t (an error loses to a branch that
-- decides) and a result of 4 is a condition error: in mode r it is run again
-- in mode r, which fails at the first error it meets (openfga:2000); in mode
-- d (RLS) it is false.
create function permissions._fga_rec_ok(
    p_m text, p_ot text, p_oid text, p_rel text, p_ut text, p_uid text, p_urel text,
    p_ctx permissions.fga_tuple[], p_req jsonb default null, p_mode "char" default null)
returns boolean
language plpgsql stable
as $$
declare
    x smallint := permissions._fga_rec(p_m, p_ot, p_oid, p_rel, p_ut, p_uid, p_urel, p_ctx, 0, '{}',
                                       p_req, case when p_mode is not null then 't'::"char" end);
begin
    if x = 3 then
        perform permissions._fga_too_complex();
    end if;
    if x = 4 and p_mode = 'r' then
        perform permissions._fga_rec(p_m, p_ot, p_oid, p_rel, p_ut, p_uid, p_urel, p_ctx, 0, '{}', p_req, 'r');
        perform permissions._fga_cond_fail(format('failed to evaluate a relationship condition while checking %s:%s#%s@%s',
                                                  p_ot, p_oid, p_rel, permissions._fga_user_string(p_ut, p_uid, p_urel)));
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

-- Check on parsed, validated input. p_mode: r for the API (an evaluation
-- error fails with openfga:2000, by OpenFGA's rule), d for the RLS helpers
-- (an error is false). A relation that is not `conditional` takes the
-- unconditioned path whatever p_mode says.
create function permissions._fga_check_impl(
    p_m text, p_ot text, p_oid text, p_rel text, p_ut text, p_uid text, p_urel text,
    p_ctx permissions.fga_tuple[], p_req jsonb default null, p_mode "char" default null)
returns boolean
language plpgsql stable
as $$
declare
    mono boolean;
    cond boolean;
    has_path boolean;
    md "char";
    x smallint;
begin
    if p_urel <> '' and p_ut = p_ot and p_uid = p_oid and p_urel = p_rel then
        return true;
    end if;
    select r.monotone, r.conditional,
           exists (select 1 from permissions.fga_paths p
                   where p.model_id = p_m and p.type = p_ot and p.relation = p_rel
                     and p.user_type = p_ut and p.user_relation = p_urel and (p_urel = '' or not p.wildcard))
    into mono, cond, has_path
    from permissions.fga_relations r where r.model_id = p_m and r.type = p_ot and r.relation = p_rel;
    if not coalesce(has_path, false) then
        return false;
    end if;
    md := case when cond then p_mode end;
    if mono then
        x := permissions._fga_bidi(p_m, p_ot, p_oid, p_rel, p_ut, p_uid, p_urel, p_ctx, 25, p_req, md);
    else
        return permissions._fga_rec_ok(p_m, p_ot, p_oid, p_rel, p_ut, p_uid, p_urel, p_ctx, p_req, md);
    end if;
    if x = 3 then
        perform permissions._fga_too_complex();
    end if;
    return x = 1;
end;
$$;

-- Set-based ListObjects over a rewrite tree (fga_relations.set_eval, phase 5
-- of session 5). Every object of p_type the user has p_rel with, and the
-- level of the answer, 25 meaning 25 or more (_fga_rec's result 3, too deep).
-- One row per object. Each node is evaluated for all objects at once, with
-- _fga_rec's rules for combining results:
--   - this: the forward walk's direct tuples on p_rel (_fga_forward, p_direct);
--   - computed r: r's own set (a monotone relation is its forward walk);
--   - r from ts: the parents' sets for r, through the ts tuples, one level more;
--   - union: present in any child, the lowest level (a true branch decides);
--   - intersection: present in every child, the highest level (a false
--     branch decides, then a too deep one);
--   - difference: in the base and not in the subtract below 25 (a subtract
--     that is true decides); a base or subtract 25 deep or more is 25.
-- Conditions: p_mode as the walks take it, per relation (conditional);
-- under a subtract (p_neg) an error in mode d counts as true (n), as in the
-- set-based difference. A userset user always has its own relation.
create function permissions._fga_set_rel(
    p_m text, p_type text, p_rel text, p_ut text, p_uid text, p_urel text, p_ctx permissions.fga_tuple[],
    p_req jsonb, p_mode "char", p_neg boolean)
returns table (object_id text, lvl int)
language plpgsql stable
rows 100
as $$
#variable_conflict use_column
declare
    mono boolean;
    md "char";
    ops text[]; pars int[]; cs text[]; tss text[];
begin
    select r.monotone, case when r.conditional then p_mode end
    into mono, md
    from permissions.fga_relations r where r.model_id = p_m and r.type = p_type and r.relation = p_rel;
    if mono is null then
        return;
    end if;
    if mono then
        return query
        select f.object_id, f.lvl
        from permissions._fga_forward(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, p_rel, p_req,
                                      case when p_neg and md = 'd' then 'n'::"char" else md end) f;
        return;
    end if;
    -- not monotone: set_eval, which fga_write_authorization_model gives a
    -- relation only when every operand it names is monotone or set_eval
    select array_agg(n.op order by n.node), array_agg(n.parent order by n.node),
           array_agg(n.computed order by n.node), array_agg(n.tupleset order by n.node)
    into ops, pars, cs, tss
    from permissions.fga_rewrite_nodes n
    where n.model_id = p_m and n.type = p_type and n.relation = p_rel;
    return query
    select x.object_id, min(x.lvl)::int
    from (select p_uid as object_id, 0 as lvl where p_urel <> '' and p_ut = p_type and p_urel = p_rel
          union all
          select * from permissions._fga_set_node(p_m, ops, pars, cs, tss, 1, p_type, p_rel,
                                                  p_ut, p_uid, p_urel, p_ctx, p_req, md, p_neg)) x
    group by x.object_id;
end;
$$;

-- One node of p_rel's rewrite tree (arrays from fga_rewrite_nodes, index k)
-- for _fga_set_rel. One row per object.
create function permissions._fga_set_node(
    p_m text, ops text[], pars int[], cs text[], tss text[], k int, p_type text, p_rel text,
    p_ut text, p_uid text, p_urel text, p_ctx permissions.fga_tuple[],
    p_req jsonb, p_mode "char", p_neg boolean)
returns table (object_id text, lvl int)
language plpgsql stable
rows 100
as $$
#variable_conflict use_column
declare
    wm "char" := case when p_neg and p_mode = 'd' then 'n'::"char" else p_mode end;
    kids int[] := array(select j from generate_subscripts(pars, 1) j where j > k and pars[j] = k order by j);
begin
    case ops[k]
    when 'this' then
        return query
        select f.object_id, f.lvl
        from permissions._fga_forward(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, p_rel, p_req, wm, true) f;
    when 'computed' then
        return query
        select * from permissions._fga_set_rel(p_m, p_type, cs[k], p_ut, p_uid, p_urel, p_ctx, p_req, p_mode, p_neg);
    when 'ttu' then
        return query
        select n.i, least(min(p.lvl) + 1, 25)::int
        from permissions.fga_type_restrictions tr
        join permissions.fga_relations pr on pr.model_id = p_m and pr.type = tr.user_type and pr.relation = cs[k]
        cross join lateral permissions._fga_set_rel(p_m, tr.user_type, cs[k], p_ut, p_uid, p_urel, p_ctx, p_req, p_mode, p_neg) p
        cross join lateral (
            select tu.object_id
            from permissions.fga_tuples tu
            where tu.user_type = tr.user_type and tu.user_id = p.object_id and tu.user_relation = ''
              and tu.object_type = p_type and tu.relation = tss[k] and tu.condition_name = tr.condition
              and (tu.condition_name = '' or permissions._fga_cond(p_m, tu.condition_name, tu.condition_context, p_req, wm))
          union all
            select x.object_id
            from unnest(p_ctx) x
            where x.user_type = tr.user_type and x.user_id = p.object_id and x.user_relation = ''
              and x.object_type = p_type and x.relation = tss[k] and x.condition_name = tr.condition
              and (x.condition_name = '' or permissions._fga_cond(p_m, x.condition_name, x.condition_context, p_req, wm))
            offset 0
        ) n(i)
        where tr.model_id = p_m and tr.type = p_type and tr.relation = tss[k]
          and tr.user_relation = '' and not tr.wildcard and p.object_id <> '*'
        group by n.i;
    when 'union' then
        return query
        select c.object_id, min(c.lvl)::int
        from unnest(kids) j
        cross join lateral permissions._fga_set_node(p_m, ops, pars, cs, tss, j, p_type, p_rel,
                                                     p_ut, p_uid, p_urel, p_ctx, p_req, p_mode, p_neg) c
        group by c.object_id;
    when 'intersection' then
        return query
        select c.object_id, max(c.lvl)::int
        from unnest(kids) j
        cross join lateral permissions._fga_set_node(p_m, ops, pars, cs, tss, j, p_type, p_rel,
                                                     p_ut, p_uid, p_urel, p_ctx, p_req, p_mode, p_neg) c
        group by c.object_id
        having count(*) = cardinality(kids);
    when 'difference' then
        return query
        with b as materialized (
            select * from permissions._fga_set_node(p_m, ops, pars, cs, tss, kids[1], p_type, p_rel,
                                                    p_ut, p_uid, p_urel, p_ctx, p_req, p_mode, p_neg)
        ),
        s as materialized (
            select * from permissions._fga_set_node(p_m, ops, pars, cs, tss, kids[2], p_type, p_rel,
                                                    p_ut, p_uid, p_urel, p_ctx, p_req, p_mode, not p_neg)
        )
        select b.object_id, case when s.object_id is null then b.lvl else 25 end
        from b left join s on s.object_id = b.object_id
        where s.object_id is null or s.lvl >= 25;
    end case;
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
--   - set_eval (compiled): the rewrite tree over sets (_fga_set_rel), each
--     leaf a walk, an object 25 levels deep or more an error;
--   - otherwise: the candidates of the positive walk, each one checked by
--     _fga_rec.
-- p_mode: r for the API (an evaluation error on an edge the walk takes fails
-- with openfga:2000, as OpenFGA's ListObjects), d for the RLS helpers.
create function permissions._fga_list_object_ids(
    p_m text, p_type text, p_rel text, p_ut text, p_uid text, p_urel text, p_ctx permissions.fga_tuple[],
    p_req jsonb default null, p_mode "char" default null)
returns setof text
language plpgsql stable
rows 100
as $$
declare
    mono boolean;
    sub_rel text;
    sub_ts text;
    recheck boolean;
    sev boolean;
    md "char";
    sd "char";
    c text;
begin
    if not permissions._fga_path_exists(p_m, p_type, p_rel, p_ut, p_urel) then
        return;
    end if;
    select r.monotone, r.diff_relation, r.diff_tupleset, r.diff_recheck, r.set_eval, case when r.conditional then p_mode end
    into mono, sub_rel, sub_ts, recheck, sev, md
    from permissions.fga_relations r where r.model_id = p_m and r.type = p_type and r.relation = p_rel;
    -- the subtract's walk: in mode d (RLS) an erroring edge is taken, so the
    -- error removes the object (deny) instead of granting it
    sd := case when md = 'd' then 'n' else md end;
    if mono then
        return query
        select f.object_id
        from permissions._fga_forward(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, p_rel, p_req, md) f
        where case when f.lvl < 25 then true else permissions._fga_deep() end;
        return;
    end if;
    if sub_rel is not null then
        return query
        with s(i) as materialized (
            select f from permissions._fga_forward_ids(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, sub_rel, p_req, sd) f
            where sub_ts is null
          union
            select n.i
            from permissions.fga_type_restrictions tr
            join permissions.fga_relations pr on pr.model_id = p_m and pr.type = tr.user_type and pr.relation = sub_rel
            cross join lateral permissions._fga_forward_ids(p_m, p_ut, p_uid, p_urel, p_ctx, tr.user_type, sub_rel, p_req, sd) p
            cross join lateral (
                select tu.object_id
                from permissions.fga_tuples tu
                where tu.user_type = tr.user_type and tu.user_id = p and tu.user_relation = ''
                  and tu.object_type = p_type and tu.relation = sub_ts and tu.condition_name = tr.condition
                  and (tu.condition_name = '' or permissions._fga_cond(p_m, tu.condition_name, tu.condition_context, p_req, sd))
              union all
                select x.object_id
                from unnest(p_ctx) x
                where x.user_type = tr.user_type and x.user_id = p and x.user_relation = ''
                  and x.object_type = p_type and x.relation = sub_ts and x.condition_name = tr.condition
                  and (x.condition_name = '' or permissions._fga_cond(p_m, x.condition_name, x.condition_context, p_req, sd))
                offset 0
            ) n(i)
            where sub_ts is not null and tr.model_id = p_m and tr.type = p_type and tr.relation = sub_ts
              and tr.user_relation = '' and not tr.wildcard
        )
        select b.object_id
        from permissions._fga_forward(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, p_rel, p_req, md) b
        left join s on s.i = b.object_id
        where case when s.i is not null and not (p_urel <> '' and p_ut = p_type and p_uid = b.object_id and p_urel = p_rel)
                   then case when recheck
                             then permissions._fga_rec_ok(p_m, p_type, b.object_id, p_rel, p_ut, p_uid, p_urel, p_ctx, p_req, md)
                             else false end
                   when b.lvl < 25 then true
                   else permissions._fga_deep() end;
        return;
    end if;
    -- the rewrite tree evaluated set-based (set_eval)
    if sev then
        return query
        select f.object_id
        from permissions._fga_set_rel(p_m, p_type, p_rel, p_ut, p_uid, p_urel, p_ctx, p_req, p_mode, false) f
        where case when f.lvl < 25 then true else permissions._fga_deep() end;
        return;
    end if;
    -- candidates from the positive graph, each one checked
    for c in select f from permissions._fga_forward_ids(p_m, p_ut, p_uid, p_urel, p_ctx, p_type, p_rel, p_req, md) f loop
        if permissions._fga_rec_ok(p_m, p_type, c, p_rel, p_ut, p_uid, p_urel, p_ctx, p_req, md) then
            return next c;
        end if;
    end loop;
end;
$$;


-- ----------------------------------------------------------------------------
-- OpenFGA API (explicit user; admin only, like the other explicit-subject
-- functions: a client could ask what any user can access)
-- ----------------------------------------------------------------------------

-- Check. subject (OpenFGA's user field; `user` is reserved in SQL): 'type:id',
-- 'type:*' or 'type:id#relation'; object: 'type:id'.
-- context: OpenFGA's request context, the condition parameters as a JSON
-- object. Invalid input raises openfga:2000, an invalid contextual tuple 2027,
-- too deep a resolution 2002, a condition that can't be evaluated 2000
-- (OpenFGA's rule: when no path of true edges exists and the search met an
-- edge whose condition errors, research/designs/d-conditions.md section 3).
create function permissions.fga_check(subject text, relation text, object text,
                                      contextual_tuples jsonb default null,
                                      model_id text default null,
                                      context jsonb default null)
returns boolean
language plpgsql stable security definer
set search_path = ''
set plan_cache_mode = force_generic_plan
as $$
declare
    req jsonb := permissions._fga_req_context(context);
    m text := permissions._fga_model_id(fga_check.model_id);
    u record;
    o record;
begin
    select * into u from permissions._fga_parse_user(m, subject, 2000);
    select * into o from permissions._fga_parse_object(m, object, relation, 2000);
    return permissions._fga_check_impl(m, o.object_type, o.object_id, relation,
                                       u.user_type, u.user_id, u.user_relation,
                                       permissions._fga_ctx(m, contextual_tuples), req, 'r');
end;
$$;

-- ListObjects: 'type:id' strings, unordered, at most 1,000 (OpenFGA's cap,
-- _fga_limits; the rest are dropped silently, as OpenFGA does, and which ones
-- survive is unspecified). Errors as OpenFGA: an invalid contextual tuple
-- 2027, unknown type 2021, unknown relation 2022, invalid user 2000, a
-- condition that errors on an edge the walk takes 2000 (context: the request's
-- condition parameters). The RLS helpers (fga_list_objects_current,
-- fga_list_object_ids_current) call the uncapped _fga_list_object_ids.
create function permissions.fga_list_objects(subject text, type text, relation text,
                                             contextual_tuples jsonb default null,
                                             model_id text default null,
                                             context jsonb default null)
returns setof text
language plpgsql stable security definer
set search_path = ''
set plan_cache_mode = force_generic_plan
rows 100
as $$
declare
    req jsonb := permissions._fga_req_context(context);
    m text := permissions._fga_model_id(fga_list_objects.model_id);
    ctx permissions.fga_tuple[] := permissions._fga_ctx(m, contextual_tuples, 2000);
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
    select * into u from permissions._fga_parse_user(m, subject, 2000);
    return query
    select fga_list_objects.type || ':' || x
    from permissions._fga_list_object_ids(m, fga_list_objects.type, fga_list_objects.relation,
                                          u.user_type, u.user_id, u.user_relation, ctx, req, 'r') x
    limit (select l.list_max from permissions._fga_limits() l);
end;
$$;

-- ListUsers, uncapped (fga_list_users is the API, capped): users of the
-- filter types ('user', or 'group#member' for usersets) that have the
-- relation with the object, as 'type:id', 'type:*' or 'type:id#relation'.
-- Unordered. context: the request's condition parameters; a condition that
-- errors on an edge the backward walk takes fails with openfga:2000, as
-- OpenFGA's ListUsers (plain users of types the filters don't name are not
-- evaluated).
create function permissions._fga_list_users(object text, relation text, user_filters text[],
                                            contextual_tuples jsonb default null,
                                            authorization_model_id text default null,
                                            context jsonb default null)
returns setof text
language plpgsql stable
set search_path = ''
set plan_cache_mode = force_generic_plan
rows 100
as $$
declare
    req jsonb := permissions._fga_req_context(context);
    m text := permissions._fga_model_id(authorization_model_id);
    ctx permissions.fga_tuple[];
    o record;
    f text;
    mono boolean;
    sub_rel text;
    sub_ts text;
    recheck boolean;
    md "char";
    pt text[];
    c record;
begin
    select * into o from permissions._fga_split_object(object);
    if o.object_type is null or o.object_id = '*' then
        perform permissions._fga_error(2000, format('invalid ''object'' field format: %s', object),
            hint => 'Write the object as ''type:id'', e.g. ''document:1''.');
    end if;
    ctx := permissions._fga_ctx(m, contextual_tuples, 2000);
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
    select r.monotone, r.diff_relation, r.diff_tupleset, r.diff_recheck, case when r.conditional then 'r' end
    into mono, sub_rel, sub_ts, recheck, md
    from permissions.fga_relations r where r.model_id = m and r.type = o.object_type and r.relation = _fga_list_users.relation;
    if mono is null then
        perform permissions._fga_error(2022, format('relation ''%s#%s'' not found', o.object_type, _fga_list_users.relation),
            hint => permissions._fga_relation_hint(m, o.object_type, _fga_list_users.relation));
    end if;
    -- the plain-user types the filters ask for
    pt := array(select uf from unnest(user_filters) uf where uf !~ '#');
    if sub_rel is not null then
        -- set-based difference (see _fga_list_object_ids): the users the base
        -- reaches minus those the subtract reaches. A plain user is also
        -- removed by its type's wildcard; the object's own userset stays; with
        -- diff_recheck the removed ones are checked with _fga_rec.
        return query
        with s(t, i, r) as materialized (
            select b.t, b.i, b.r
            from permissions._fga_backward(m, o.object_type, o.object_id, sub_rel, ctx, 25, req, md, pt) b
            where sub_ts is null
          union
            select b.t, b.i, b.r
            from (select tu.user_type, tu.user_id, tu.condition_name, tu.condition_context
                  from permissions.fga_tuples tu
                  where tu.object_type = o.object_type and tu.object_id = o.object_id and tu.relation = sub_ts
                    and tu.user_relation = ''
                union
                  select x.user_type, x.user_id, x.condition_name, x.condition_context
                  from unnest(ctx) x
                  where x.object_type = o.object_type and x.object_id = o.object_id and x.relation = sub_ts
                    and x.user_relation = '') p
            join permissions.fga_type_restrictions tr
              on tr.model_id = m and tr.type = o.object_type and tr.relation = sub_ts
             and tr.user_type = p.user_type and tr.user_relation = '' and not tr.wildcard and tr.condition = p.condition_name
            join permissions.fga_relations pr on pr.model_id = m and pr.type = p.user_type and pr.relation = sub_rel
            cross join lateral permissions._fga_backward(m, p.user_type, p.user_id, sub_rel, ctx, 25, req, md, pt) b
            where sub_ts is not null and p.user_id <> '*'
              and (p.condition_name = '' or permissions._fga_cond(m, p.condition_name, p.condition_context, req, md))
        )
        select permissions._fga_user_string(k.t, k.i, k.r)
        from (select distinct b.t, b.i, b.r
              from permissions._fga_backward(m, o.object_type, o.object_id, _fga_list_users.relation, ctx, 25, req, md, pt) b
              join unnest(user_filters) uf on b.t = split_part(uf, '#', 1) and b.r = split_part(uf, '#', 2)) k
        where case when (k.t, k.i, k.r) = (o.object_type, o.object_id, _fga_list_users.relation)
                     or not exists (select 1 from s
                                    where s.t = k.t and s.r = k.r and (s.i = k.i or (k.r = '' and s.i = '*')))
                   then true
                   when recheck
                   then permissions._fga_rec_ok(m, o.object_type, o.object_id, _fga_list_users.relation, k.t, k.i, k.r, ctx, req, md)
                   else false end;
        return;
    end if;
    for c in
        select distinct b.t, b.i, b.r
        from permissions._fga_backward(m, o.object_type, o.object_id, _fga_list_users.relation, ctx, 25, req, md, pt) b
        join unnest(user_filters) uf on b.t = split_part(uf, '#', 1) and b.r = split_part(uf, '#', 2)
    loop
        if not mono then
            continue when not permissions._fga_rec_ok(m, o.object_type, o.object_id, _fga_list_users.relation,
                                                      c.t, c.i, c.r, ctx, req, md);
        end if;
        return next permissions._fga_user_string(c.t, c.i, c.r);
    end loop;
end;
$$;

-- ListUsers: at most 1,000 users (OpenFGA's cap, _fga_limits; the rest are
-- dropped silently, as OpenFGA does, and which ones survive is unspecified).
create function permissions.fga_list_users(object text, relation text, user_filters text[],
                                           contextual_tuples jsonb default null,
                                           model_id text default null,
                                           context jsonb default null)
returns setof text
language sql stable security definer
set search_path = ''
rows 100
as $$
    select u from permissions._fga_list_users($1, $2, $3, $4, $5, $6) u
    limit (select l.list_max from permissions._fga_limits() l)
$$;

-- ----------------------------------------------------------------------------
-- Current subject: for clients and RLS policies (G1, G2)
-- ----------------------------------------------------------------------------
-- The user is current_subject_type():current_subject_id() (user:<JWT sub> on
-- Supabase). No subject, no model yet, or a subject type the model doesn't
-- define: false or nothing, so RLS denies instead of failing. An unknown
-- object type or relation still raises (2021/2022 or 2000), like OpenFGA.
-- No contextual tuples: a client could otherwise vouch for itself. No request
-- context either: a conditioned tuple counts when its condition is true with
-- its own stored context alone; one whose condition needs a request
-- parameter, or errors, is denied (never an error in a policy).

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
    return permissions._fga_check_impl(s.model_id, o.object_type, o.object_id, relation, s.user_type, s.user_id, '', '{}', '{}', 'd');
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
                                          s.user_type, s.user_id, '', '{}', '{}', 'd') x;
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
                                                                s.user_type, s.user_id, '', '{}', '{}', 'd') x;
end;
$$;

-- ============================================================================
-- Cleanup across models
-- ============================================================================

-- Forget a subject everywhere: its role assignments (user subjects) and every
-- FGA tuple naming it as user (any userset of it too) or as object.
create function permissions.delete_subject(subject_type text, subject_id text)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
    n bigint;
    k bigint;
begin
    delete from permissions.rbac_assignments a
    where delete_subject.subject_type = 'user' and a.user_id = delete_subject.subject_id;
    get diagnostics n = row_count;
    delete from permissions.fga_tuples t
    where (t.user_type = delete_subject.subject_type and t.user_id = delete_subject.subject_id)
       or (t.object_type = delete_subject.subject_type and t.object_id = delete_subject.subject_id);
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
    permissions.rbac_has_permission(text, text),
    permissions.rbac_has_role(text, text),
    permissions.rbac_scopes_with_permission(text, boolean),
    permissions.fga_check_current(text, text),
    permissions.fga_list_objects_current(text, text),
    permissions.fga_list_object_ids_current(text, text)
to public;

-- Everything else (role and model management, tuple writes, explicit-subject
-- checks and lists) is for the owner and whichever trusted roles the app
-- grants, e.g. service_role.
