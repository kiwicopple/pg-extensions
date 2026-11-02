/*
 * pg_permissions
 *
 * Copyright (c) 2026 Paul Copplestone: https://github.com/kiwicopple/pg-extensions/
 *
 * Design: research/designs/d-per-model.md. Independent models in one schema:
 *
 *   rbac_*   roles, permissions, scoped assignments (the blessed path)
 *   fga_*    OpenFGA: JSON authorization models (schema 1.1), tuples, Check,
 *            ListObjects, ListUsers, Read, Write, with OpenFGA's semantics and
 *            error codes, tested against OpenFGA's own test suite (test/fga/)
 *   cedar_*  Cedar 4.x policies over stored entities, with Cedar's semantics,
 *            tested against Cedar's integration tests (test/cedar/); built in
 *            phases (research/plan-cedar.md), so far the core evaluator
 *
 * They share only the toolkit: subject identity, the plan-time guard
 * (_unfolded_null), error hints, value helpers (IP, timestamp, duration) and
 * the grants. An app composes them in RLS: permissive policies OR,
 * restrictive policies AND.
 *
 * This file is the extension (design D, chosen at the end of session 4). The
 * A, B and C prototypes in prototypes/ are measured history.
 *
 * Version 0.1.0. A fresh install runs this file. An installed 0.0.1 upgrades
 * with pg_permissions--0.0.1--0.1.0.sql (ALTER EXTENSION ... UPDATE under
 * pg_tle, or psql -f for a plain install). pg_permissions--0.0.1.sql is the
 * released 0.0.1 and does not change.
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

-- ---------------------------------------------------------------------------
-- Toolkit: value helpers (shared by FGA conditions and Cedar)
-- ---------------------------------------------------------------------------

-- Canonical text of an IP address, a timestamp and a duration. FGA's CEL
-- conditions use them for OpenFGA's ipaddress, timestamp and duration
-- parameters; Cedar's ipaddr, datetime and duration extensions build on them.
-- Each returns null for input it does not accept, and the caller reports the
-- model's own error.

-- netip.ParseAddr, then Unmap (an IPv4-mapped IPv6 address is its IPv4
-- address): the address's text, or null. IPv6 zones (fe80::1%eth0) are not
-- accepted (inet has none).
create function permissions._ip_canon(s text)
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

-- RFC 3339 as Go's time.Parse(time.RFC3339) reads it (OpenFGA's timestamp
-- parameters and cel-go's timestamp()): upper-case T and Z, seconds required,
-- an optional fraction, Z or +hh:mm. The canonical text in UTC with
-- microseconds (CEL keeps nanoseconds: the digits beyond are dropped), or null.
create function permissions._ts_canon(s text)
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

-- Go's time.ParseDuration ("1h30m", "300ms", "-1.5h"; units ns us µs μs ms s
-- m h): integer nanoseconds, or null (also beyond int64).
create function permissions._duration_ns(s text)
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
            detail = 'rbac:null_argument argument=role',
            hint = 'Pass the name of the role as text, e.g. select permissions.rbac_create_role(role => ''editor'', permissions => ''{documents.edit}'').';
    end if;
    if rbac_create_role.permissions is null then
        raise exception 'permissions is required to create role ''%''', rbac_create_role.role using errcode = '22004',
            detail = 'rbac:null_argument argument=permissions',
            hint = format('Pass an array of permission names, or ''{}'' for a role that only inherits: select permissions.rbac_create_role(role => %L, permissions => ''{documents.read}'').', rbac_create_role.role);
    end if;
    if rbac_create_role.inherits is null then
        raise exception 'inherits must not be null for role ''%''', rbac_create_role.role using errcode = '22004',
            detail = 'rbac:null_argument argument=inherits',
            hint = format('Pass an array of role names, or omit inherits: select permissions.rbac_create_role(role => %L, permissions => ''{documents.read}'', inherits => ''{viewer}'').', rbac_create_role.role);
    end if;
    if exists (select 1 from permissions.rbac_roles r where r.role = rbac_create_role.role) then
        raise exception 'role ''%'' already exists', rbac_create_role.role using errcode = '23505',
            detail = format('rbac:role_exists role=%L', rbac_create_role.role),
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
            detail = 'rbac:name_overlap',
            hint = 'rbac_has_role and rbac_has_permission share one namespace: use distinct names, e.g. a role ''editor'' with permissions like ''documents.edit''.';
    end if;
    select i into x from unnest(rbac_create_role.inherits) i
    where not exists (select 1 from permissions.rbac_roles r where r.role = i) limit 1;
    if x is not null then
        raise exception 'unknown role ''%'' in inherits of role ''%''', x, rbac_create_role.role using errcode = '22023',
            detail = format('rbac:unknown_role role=%L', x),
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
            detail = format('rbac:unknown_role role=%L', rbac_drop_role.role),
            hint = permissions._rbac_role_hint(rbac_drop_role.role);
    end if;
    heirs := array(select i.role from permissions.rbac_role_inherits i where i.inherits = rbac_drop_role.role order by i.role);
    if cardinality(heirs) > 0 then
        raise exception 'role ''%'' is inherited by %', rbac_drop_role.role,
            (select string_agg(format('%L', h), ', ') from unnest(heirs) h) using errcode = '2BP01',
            detail = format('rbac:role_in_use role=%L', rbac_drop_role.role),
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
            detail = format('rbac:unknown_role role=%L', rbac_assign_role.role),
            hint = permissions._rbac_role_hint(rbac_assign_role.role);
    end if;
    if rbac_assign_role.user_id is null then
        raise exception 'user_id is required to assign role ''%''', rbac_assign_role.role using errcode = '22004',
            detail = 'rbac:null_argument argument=user_id',
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
            detail = 'rbac:null_argument argument=user_id',
            hint = format('Pass the user''s id as text, e.g. select permissions.rbac_unassign_role(user_id => id::text, role => %L, scope => org_id::text).', rbac_unassign_role.role);
    end if;
    if rbac_unassign_role.role is null then
        raise exception 'role is required to unassign a role' using errcode = '22004',
            detail = 'rbac:null_argument argument=role',
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

-- IP addresses, timestamps and durations are parsed by the toolkit's value
-- helpers (_ip_canon, _ts_canon, _duration_ns), which Cedar shares.

-- A timestamptz as the canonical value, or null outside CEL's range (years
-- 1 to 9999).
create function permissions._fga_cel_ts_val(ts timestamptz)
returns jsonb
language sql immutable
as $$
    select case when ts >= '0001-01-01 00:00:00+00' and ts < '10000-01-01 00:00:00+00'
                then to_jsonb(to_char(ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) end
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
            num := permissions._duration_ns(v #>> '{}');
            if num is not null then
                return row(to_jsonb(num), null::text, 0);
            end if;
            return row(null::jsonb, format('expected a valid duration string, but found: ''%s''', v #>> '{}'), 0);
        end if;
        return row(null::jsonb, format('expected a duration string, but found: %s', v), 0);
    elsif tn = 'timestamp' then
        if jt = 'string' then
            s := permissions._ts_canon(v #>> '{}');
            if s is not null then
                return row(to_jsonb(s), null::text, 0);
            end if;
            return row(null::jsonb, format('expected RFC 3339 formatted timestamp string, but found ''%s''', v #>> '{}'), 0);
        end if;
        return row(null::jsonb, format('expected RFC 3339 formatted timestamp string, but found: %s', v), 0);
    elsif tn = 'ipaddress' then
        if jt = 'string' then
            s := permissions._ip_canon(v #>> '{}');
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
        s2 := permissions._ip_canon(s1);
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

-- >>> cedar section: begin
-- Everything from this line to the matching end line is the Cedar model.
-- tools/sync-upgrade.sh copies it, unchanged, into the marked region of
-- pg_permissions--0.0.1--0.1.0.sql: edit it here, then run the script.
-- ============================================================================
-- Cedar: cedar_* tables
-- ============================================================================
--
-- Cedar 4.x (research/plan-cedar.md; design research/designs/e-cedar.md),
-- tested against Cedar's own integration tests (test/cedar/). A policy is put
-- as Cedar text or in Cedar's JSON policy format (the EST; text is parsed to
-- the EST), checked and compiled once: the EST is kept in `est`, the
-- conditions as a compact tree in `ast` (e-cedar.md section 2.3) and the
-- scope in columns, so a request matches the scope in SQL and evaluates only
-- the conditions of the policies whose scope matches. A template link is a
-- policy too, with the template's slots filled in when it is linked.
--
-- Entities (uid, attrs, parents, tags) are stored as the app syncs them, one
-- row per entity and one per direct parent. `in` follows the parents
-- recursively (e-cedar.md "Phase 2 measurements": a closure table reads
-- faster only on deep hierarchies, and needs a lock to stay correct under
-- concurrent writes).
--
-- Values are jsonb in one canonical form (e-cedar.md section 3): Bool, Long
-- and String as JSON, an entity as {"__entity": {"type", "id"}}, a set as a
-- sorted array without duplicates, a record as an object. Cedar `==` is jsonb
-- equality. Ids and types are collate "C".

-- Policy templates. A link is a row of cedar_policies that names its
-- template, with the slots filled in at link time (cedar_link_template).
create table permissions.cedar_templates (
    template_id text collate "C" primary key,
    source      text,                  -- the Cedar text as written; null when put as JSON
    est         jsonb not null,        -- Cedar's JSON policy format, with slots
    ast         jsonb,                 -- the conditions, compiled; links copy it
    annotations jsonb not null default '{}'
);

create table permissions.cedar_policies (
    policy_id      text collate "C" primary key,
    effect         text collate "C" not null check (effect in ('permit', 'forbid')),
    source         text,               -- the Cedar text as written; null when put as policy_json
    est            jsonb not null,     -- Cedar's JSON policy format, as put
    ast            jsonb,              -- the conditions, compiled (_cedar_compile); null: none (true)
    annotations    jsonb not null default '{}',
    -- the scope; a uid is its key (_cedar_key), a type its name
    principal_op   text collate "C" not null check (principal_op in ('All', '==', 'in', 'is')),
    principal_type text collate "C",   -- is
    principal_uid  text collate "C",   -- ==, in, is ... in
    action_op      text collate "C" not null check (action_op in ('All', '==', 'in')),
    action_uids    text[] collate "C", -- ==: one, in: one or more
    resource_op    text collate "C" not null check (resource_op in ('All', '==', 'in', 'is')),
    resource_type  text collate "C",
    resource_uid   text collate "C",
    template_id    text collate "C" references permissions.cedar_templates (template_id),
    slots          jsonb               -- a link's slot values: {"?principal": {"type", "id"}, ...}
);
create index on permissions.cedar_policies (template_id) where template_id is not null;

-- The scope index (e-cedar.md section 15.1): one row per policy and action
-- of its action scope, keyed so that a request finds its candidate policies
-- with equality probes, = any(keys), and no scan of cedar_policies:
--   action_key     each uid of the action scope; '*' for All
--   principal_key  ==, in and is ... in: the uid; is: the type; All: '*'
--   resource_key   the same for the resource
-- A request probes the principal's and the resource's own key, their
-- ancestors' keys, their type and '*', through the index that leads with the
-- side with fewer keys. That finds every policy whose scope can match, and
-- a few that don't (a == on an ancestor, an is ... in of another type); the
-- scope predicate in _cedar_candidates is exact.
-- _cedar_store_policy keeps it; a policy's rows go with it.
create table permissions.cedar_policy_scopes (
    policy_id     text collate "C" not null references permissions.cedar_policies (policy_id) on delete cascade,
    action_key    text collate "C" not null,
    principal_key text collate "C" not null,
    resource_key  text collate "C" not null,
    primary key (policy_id, action_key)
);
create index on permissions.cedar_policy_scopes (action_key, principal_key, resource_key) include (policy_id);
create index on permissions.cedar_policy_scopes (action_key, resource_key, principal_key) include (policy_id);

create table permissions.cedar_entities (
    type  text collate "C" not null,
    id    text collate "C" not null,
    attrs jsonb not null default '{}',
    tags  jsonb not null default '{}',
    primary key (type, id)
);

-- Direct parents only. A parent need not be a stored entity (Cedar allows
-- that; it then has no ancestors of its own).
create table permissions.cedar_entity_parents (
    type        text collate "C" not null,
    id          text collate "C" not null,
    parent_type text collate "C" not null,
    parent_id   text collate "C" not null,
    primary key (type, id, parent_type, parent_id),
    foreign key (type, id) references permissions.cedar_entities (type, id) on delete cascade
);
create index on permissions.cedar_entity_parents (parent_type, parent_id);

-- ----------------------------------------------------------------------------
-- Limits (e-cedar.md section 6), fixed, each well above the corpus maximum
-- ----------------------------------------------------------------------------
-- policy_bytes: the text of a policy, or its JSON; policy_nodes and
-- policy_depth: expression nodes and nesting of one policy; value_depth: the
-- nesting of sets and records in entity data and context; put_entities:
-- entities in one cedar_put_entities call; request_entities: the entities
-- overlay of one request. Cedar's evaluation has no loops, so these static
-- limits bound its cost; there is no runtime counter (section 4.3).
create function permissions._cedar_limits(out policy_bytes int, out policy_nodes int, out policy_depth int,
                                          out value_depth int, out put_entities int, out request_entities int)
language sql immutable
as $$
    select 65536, 4096, 64, 32, 10000, 1000
$$;

-- ----------------------------------------------------------------------------
-- Errors
-- ----------------------------------------------------------------------------
-- API and argument errors raise with DETAIL 'cedar:<code>[ key=''value'' ...]',
-- a MESSAGE that names the values and a HINT (e-cedar.md section 5; every
-- call passes one, test/spec/d/35_error_hints.sql). Evaluation errors never
-- raise out of cedar_is_authorized: they are its `errors`.
create function permissions._cedar_error(p_code text, p_message text, hint text, p_detail text default null)
returns void
language plpgsql
as $$
begin
    raise exception using
        message = p_message,
        errcode = case p_code
            when 'parse_error' then '42601'
            when 'template_in_use' then '2BP01'
            when 'id_in_use' then '23505'
            when 'unsupported' then '0A000'
            when 'null_argument' then '22004'
            when 'limit_exceeded' then '54000'
            else '22023' end,
        detail = 'cedar:' || p_code || coalesce(' ' || p_detail, ''),
        hint = _cedar_error.hint;
end;
$$;

-- An evaluation error. The evaluator returns SQL null for an error, so the
-- hot path never builds a message (e-cedar.md section 4.1); when a policy
-- errs, cedar_is_authorized evaluates it once more with p_why, which raises
-- here with the message (SQLSTATE CE001, caught right there; it never
-- reaches the caller). The message starts with the kind of Cedar's
-- EvaluationError: type_error, entity_does_not_exist, attribute_not_found,
-- tag_not_found, overflow, extension_error.
create function permissions._cedar_eval_fail(p_why boolean, p_message text)
returns jsonb
language plpgsql immutable
as $$
begin
    if p_why then
        raise exception using
            message = p_message,
            errcode = 'CE001',
            detail = 'cedar:evaluation_error',
            hint = 'Internal: cedar_is_authorized catches this and reports it in errors.';
    end if;
    return null;
end;
$$;

-- ----------------------------------------------------------------------------
-- Uids and values
-- ----------------------------------------------------------------------------

-- The lookup key of a uid: Type::"id" without escapes. An entity type never
-- holds a double quote, so the key is unique (the type ends at the first ").
create function permissions._cedar_key(p_type text, p_id text)
returns text
language sql immutable
as $$
    select p_type || '::"' || p_id || '"'
$$;

-- A uid as Cedar text, Type::"id" with Cedar's string escapes. The escapes
-- match uid() in js/src/cedar/uid.ts: \" \\ \n \r \t, and \u{hex} for the
-- other control characters and DEL. Messages and cedar_uid use it.
create function permissions._cedar_uid_text(p_type text, p_id text)
returns text
language sql immutable
as $$
    select p_type || '::"' || case
        when coalesce(p_id, '') !~ '[\x01-\x1f"\\\x7f]' then coalesce(p_id, '')
        else (select string_agg(case when c = '"' then '\"' when c = '\' then '\\'
                                     when c = chr(10) then '\n' when c = chr(13) then '\r' when c = chr(9) then '\t'
                                     when ascii(c) < 32 or ascii(c) = 127 then format('\u{%s}', to_hex(ascii(c)))
                                     else c end, '' order by o)
              from regexp_split_to_table(p_id, '') with ordinality s(c, o) where c <> '')
        end || '"'
$$;

-- A valid entity type name: Ident(::Ident)*.
create function permissions._cedar_is_name(p_name text)
returns boolean
language sql immutable
as $$
    select coalesce(p_name ~ '^[_a-zA-Z][_a-zA-Z0-9]*(::[_a-zA-Z][_a-zA-Z0-9]*)*$', false)
$$;

-- A uid in entity JSON or the EST: {"type": T, "id": "x"}, or the same inside
-- {"__entity": ...}. {type, id}, or null when it is not one.
create function permissions._cedar_uid_json(v jsonb, out type text, out id text)
language plpgsql immutable
as $$
begin
    if jsonb_typeof(v) = 'object' and v ? '__entity' and v - '__entity' = '{}' then
        v := v -> '__entity';
    end if;
    if jsonb_typeof(v) = 'object' and jsonb_typeof(v -> 'type') = 'string' and jsonb_typeof(v -> 'id') = 'string'
       and v - 'type' - 'id' = '{}' and permissions._cedar_is_name(v ->> 'type') then
        type := v ->> 'type';
        id := v ->> 'id';
    end if;
end;
$$;

-- A uid argument in Cedar text, Type::"id" (Cedar's string escapes: \n \r \t
-- \\ \0 \' \" \xHH \u{H..}). Raises cedar:invalid_uid, or with p_quiet
-- returns nulls.
create function permissions._cedar_uid(p_text text, p_arg text, p_quiet boolean default false, out type text, out id text)
language plpgsql immutable
as $$
declare
    m text[];
    s text;
    r text := '';
    i int := 1;
    c text;
    h text[];
    bad text;
begin
    -- the common case without escapes: the type ends at the first ::" (a
    -- type has no double quote), the id at the last character
    i := strpos(p_text, '::"');
    if i > 0 and right(p_text, 1) = '"' and strpos(p_text, '\') = 0 and char_length(p_text) > i + 2
       and strpos(substr(p_text, i + 3, char_length(p_text) - i - 3), '"') = 0
       and permissions._cedar_is_name(left(p_text, i - 1)) then
        type := left(p_text, i - 1);
        id := substr(p_text, i + 3, char_length(p_text) - i - 3);
        return;
    end if;
    i := 1;
    m := regexp_match(p_text, '^\s*([_a-zA-Z][_a-zA-Z0-9]*(?:::[_a-zA-Z][_a-zA-Z0-9]*)*)::"((?:[^"\\]|\\.)*)"\s*$');
    if m is not null and m[2] !~ '\\' then
        type := m[1];
        id := m[2];
        return;
    end if;
    if m is null then
        bad := 'it is not Type::"id"';
    else
        s := m[2];
        while i <= char_length(s) loop
            c := substr(s, i, 1);
            if c <> '\' then
                r := r || c;
                i := i + 1;
                continue;
            end if;
            c := substr(s, i + 1, 1);
            if c in ('n', 'r', 't', '\', '"', '''') then
                r := r || case c when 'n' then e'\n' when 'r' then e'\r' when 't' then e'\t' else c end;
                i := i + 2;
            elsif c = 'x' and substr(s, i + 2, 2) ~ '^[0-7][0-9a-fA-F]$' and substr(s, i + 2, 2) <> '00' then
                r := r || chr(('x' || lpad(substr(s, i + 2, 2), 8, '0'))::bit(32)::int);
                i := i + 4;
            elsif c = 'u' then
                h := regexp_match(substr(s, i + 2), '^\{([0-9a-fA-F]{1,6})\}');
                if h is null or ('x' || lpad(h[1], 8, '0'))::bit(32)::int not between 1 and 1114111
                   or ('x' || lpad(h[1], 8, '0'))::bit(32)::int between 55296 and 57343 then
                    bad := format('the escape \u%s is not a Unicode scalar value (U+0000 is not supported)', coalesce(substr(s, i + 2, 8), ''));
                    exit;
                end if;
                r := r || chr(('x' || lpad(h[1], 8, '0'))::bit(32)::int);
                i := i + 3 + char_length(h[1]) + 1;
            else
                bad := format('the escape \%s is not valid in a Cedar string (U+0000 is not supported)', c);
                exit;
            end if;
        end loop;
        if bad is null then
            type := m[1];
            id := r;
            return;
        end if;
    end if;
    if p_quiet then
        return;
    end if;
    perform permissions._cedar_error('invalid_uid', format('invalid entity uid for %s: %s: %s', p_arg, p_text, bad),
        hint => format('Write a uid as Cedar text, a type and a quoted id: %s => ''User::"alice"'' (a namespaced type: ''App::User::"alice"'').', p_arg),
        p_detail => format('value=%L', p_text));
end;
$$;

-- The Cedar type of an internal value, for messages.
create function permissions._cedar_type_of(v jsonb)
returns text
language sql immutable
as $$
    select case jsonb_typeof(v)
        when 'boolean' then 'Bool' when 'number' then 'Long' when 'string' then 'String' when 'array' then 'Set'
        when 'object' then case when v ? '__entity' then 'Entity'
                                when v ? '__extn' then case v -> '__extn' ->> 'fn' when 'ip' then 'ipaddr'
                                                       else coalesce(v -> '__extn' ->> 'fn', 'extension') end
                                else 'Record' end
        else 'no value' end
$$;

-- The extension functions and methods of Cedar 4.x, and the extension type
-- each belongs to: for a method, the type of its receiver. An unknown name
-- gets the nearest of these (cedar:invalid_policy).
create function permissions._cedar_extensions()
returns jsonb
language sql immutable
as $$
    select '{"decimal": "decimal", "lessThan": "decimal", "lessThanOrEqual": "decimal",
             "greaterThan": "decimal", "greaterThanOrEqual": "decimal",
             "ip": "ipaddr", "isIpv4": "ipaddr", "isIpv6": "ipaddr", "isLoopback": "ipaddr",
             "isMulticast": "ipaddr", "isInRange": "ipaddr",
             "datetime": "datetime", "offset": "datetime", "durationSince": "datetime",
             "toDate": "datetime", "toTime": "datetime",
             "duration": "duration", "toDays": "duration", "toHours": "duration", "toMinutes": "duration",
             "toSeconds": "duration", "toMilliseconds": "duration"}'::jsonb
$$;

-- A set in canonical form: sorted by jsonb order, without duplicates.
create function permissions._cedar_set(p_items jsonb)
returns jsonb
language sql immutable
as $$
    select coalesce(jsonb_agg(x order by x), '[]') from (select distinct x from jsonb_array_elements(p_items) x) d
$$;

-- ----------------------------------------------------------------------------
-- Extension types: decimal, ipaddr, datetime, duration (e-cedar.md section 14)
-- ----------------------------------------------------------------------------
-- An extension value is {"__extn": {"fn": F, "v": V}} internally, one
-- canonical V per value, so Cedar == stays jsonb equality:
--
--   decimal   F "decimal", V the i64 value times 10^4 (decimal("1.0") ==
--             decimal("1.0000"))
--   ipaddr    F "ip", V the inet text with the prefix length always
--             written, as Cedar prints it: "10.0.0.1/32" for ip("10.0.0.1"),
--             host bits kept ("10.0.0.1/24" <> "10.0.0.0/24"), IPv6 always
--             in hex groups
--   datetime  F "datetime", V i64 milliseconds since the Unix epoch
--   duration  F "duration", V i64 milliseconds
--
-- Entity and context JSON write them as {"__extn": {"fn", "arg": "<text>"}}
-- (Cedar's form); _cedar_value_in converts on input and _cedar_value_out on
-- output. The parsers below follow Cedar 4.14's own (cedar-policy-core,
-- src/extensions/), not the toolkit's _ip_canon, _ts_canon and _duration_ns,
-- which follow Go for FGA: each returns null for text Cedar rejects.

-- Cedar's decimal("…"): -?digits.digits, 1 to 4 digits after the point,
-- within i64 / 10^4. The value times 10^4, or null.
create function permissions._cedar_decimal(s text)
returns bigint
language plpgsql immutable
as $$
declare
    m text[] := regexp_match(s, '^(-?)([0-9]+)\.([0-9]{1,4})$');
    v numeric;
begin
    if m is null then
        return null;
    end if;
    v := (m[2]::numeric * 10000 + rpad(m[3], 4, '0')::numeric) * case when m[1] = '-' then -1 else 1 end;
    if v not between -9223372036854775808 and 9223372036854775807 then
        return null;
    end if;
    return v;
end;
$$;

-- Cedar's ip("…"): an IPv4 address (four decimal octets, no leading zeros)
-- or an IPv6 address in hex groups (Rust's std parser), with an optional
-- /prefix (decimal, no leading zeros, at most 32 or 128). At most 43 bytes.
-- No zone (%eth0), and no IPv4 embedded in IPv6: Cedar rejects any text with
-- two colons and two dots (::ffff:1.2.3.4); ::ffff:102:304 is an IPv6
-- address. The canonical text (see above), or null.
create function permissions._cedar_ip(s text)
returns text
language plpgsql immutable
as $$
declare
    i int := strpos(s, '/');
    a text := case when i > 0 then left(s, i - 1) else s end;
    p text := case when i > 0 then substr(s, i + 1) end;
    v6 boolean;
    t text;
    m text[];
begin
    if octet_length(s) > 43 or (s ~ ':.*:' and s ~ '\..*\.') then
        return null;
    end if;
    if a ~ '^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$' then
        v6 := false;
    elsif a ~ '^[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){7}$'
          or (a ~ '^(([0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{1,4})?::(([0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{1,4})?$'
              and (select count(*) from regexp_matches(a, '[0-9a-fA-F]+', 'g') g) <= 7) then
        v6 := true;
    else
        return null;
    end if;
    if p is not null and (p !~ '^(0|[1-9][0-9]{0,2})$' or p::int > (case when v6 then 128 else 32 end)) then
        return null;
    end if;
    t := (a || coalesce('/' || p, ''))::inet::text;
    -- Postgres prints ::ffff:a.b.c.d and ::a.b.c.d with an IPv4 tail, which
    -- Cedar would not read back: write the tail as two hex groups
    if v6 and strpos(t, '.') > 0 then
        m := regexp_match(t, '^(.*:)([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)(/[0-9]+)?$');
        t := m[1] || to_hex(m[2]::int * 256 + m[3]::int) || ':' || to_hex(m[4]::int * 256 + m[5]::int) || coalesce(m[6], '');
    end if;
    return t;
end;
$$;

-- Cedar's datetime("…") (RFC 80): YYYY-MM-DD, optionally followed by
-- Thh:mm:ss, an optional .SSS, and Z or an offset +hhmm / -hhmm (hh < 24,
-- mm < 60). Years 0000 to 9999 of the proleptic Gregorian calendar; no leap
-- second. Milliseconds since the Unix epoch, or null.
create function permissions._cedar_datetime(s text)
returns bigint
language plpgsql immutable
as $$
declare
    m text[] := regexp_match(s, '^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{3}))?(?:Z|([+-])([0-9]{2})([0-9]{2})))?$');
    y int;
    mo int;
    d int;
    era int;
    yoe int;
    doe int;
begin
    if m is null then
        return null;
    end if;
    y := m[1]::int;
    mo := m[2]::int;
    d := m[3]::int;
    if mo not between 1 and 12 or d < 1
       or d > (case when mo = 2 then (case when y % 4 = 0 and (y % 100 <> 0 or y % 400 = 0) then 29 else 28 end)
                    when mo in (4, 6, 9, 11) then 30 else 31 end)
       or coalesce(m[4]::int > 23 or m[5]::int > 59 or m[6]::int > 59, false)
       or coalesce(m[9]::int > 23 or m[10]::int > 59, false) then
        return null;
    end if;
    -- days from 1970-01-01 (H. Hinnant's days_from_civil)
    y := y - (mo <= 2)::int;
    era := (case when y >= 0 then y else y - 399 end) / 400;
    yoe := y - era * 400;
    doe := yoe * 365 + yoe / 4 - yoe / 100 + (153 * (mo + case when mo > 2 then -3 else 9 end) + 2) / 5 + d - 1;
    return (era * 146097 + doe - 719468)::bigint * 86400000
           + coalesce(m[4]::bigint * 3600000 + m[5]::bigint * 60000 + m[6]::bigint * 1000, 0) + coalesce(m[7]::bigint, 0)
           - coalesce(case m[8] when '+' then 1 else -1 end * (m[9]::bigint * 3600000 + m[10]::bigint * 60000), 0);
end;
$$;

-- Cedar's duration("…") (RFC 80): an optional -, then quantity-unit pairs in
-- the order d, h, m, s, ms, each at most once, at least one ("1d2h3m4s5ms",
-- "-90m"). Milliseconds, or null (also beyond i64).
create function permissions._cedar_duration(s text)
returns bigint
language plpgsql immutable
as $$
declare
    m text[] := regexp_match(s, '^(-?)(?:([0-9]+)d)?(?:([0-9]+)h)?(?:([0-9]+)m)?(?:([0-9]+)s)?(?:([0-9]+)ms)?$');
    v numeric;
begin
    if m is null or s = '' or s = '-' then
        return null;
    end if;
    v := coalesce(m[2]::numeric * 86400000, 0) + coalesce(m[3]::numeric * 3600000, 0) + coalesce(m[4]::numeric * 60000, 0)
         + coalesce(m[5]::numeric * 1000, 0) + coalesce(m[6]::numeric, 0);
    if m[1] = '-' then
        v := -v;
    end if;
    if v not between -9223372036854775808 and 9223372036854775807 then
        return null;
    end if;
    return v;
end;
$$;

-- An extension value from its constructor and text: fn is decimal, ip,
-- datetime or duration. The internal value, or null when Cedar's
-- constructor would fail.
create function permissions._cedar_extn(fn text, arg text)
returns jsonb
language plpgsql immutable
as $$
declare
    v jsonb := case fn when 'decimal' then to_jsonb(permissions._cedar_decimal(arg))
                       when 'ip' then to_jsonb(permissions._cedar_ip(arg))
                       when 'datetime' then to_jsonb(permissions._cedar_datetime(arg))
                       when 'duration' then to_jsonb(permissions._cedar_duration(arg)) end;
begin
    if v is null then
        return null;
    end if;
    return jsonb_build_object('__extn', jsonb_build_object('fn', fn, 'v', v));
end;
$$;

-- What a constructor accepts, for messages and hints.
create function permissions._cedar_extn_help(fn text)
returns text
language sql immutable
as $$
    select case fn
        when 'decimal' then 'a decimal has digits on both sides of the point, at most 4 after it, and lies within -922337203685477.5808 and 922337203685477.5807, like "12.34"'
        when 'ip' then 'an ipaddr is an IPv4 or IPv6 address with an optional CIDR prefix, like "10.0.0.1", "10.0.0.0/8" or "ffee::/64", with no leading zeros, no zone and no IPv4 embedded in IPv6'
        when 'datetime' then 'a datetime is "YYYY-MM-DD", optionally followed by "Thh:mm:ss", an optional ".SSS", and "Z" or an offset "+hhmm" or "-hhmm", like "2024-10-15T11:35:00Z"'
        when 'duration' then 'a duration is quantity-unit pairs in the order d, h, m, s, ms with an optional leading "-", like "1d2h3m4s5ms", within the 64-bit range of milliseconds'
        else 'the constructors are decimal, ip, datetime and duration' end
$$;

-- A datetime as text, YYYY-MM-DDThh:mm:ss.SSSZ, or null outside the years
-- 0000 to 9999 (which only offset reaches; H. Hinnant's civil_from_days).
create function permissions._cedar_datetime_text(ms bigint)
returns text
language plpgsql immutable
as $$
declare
    tod bigint := mod(mod(ms, 86400000) + 86400000, 86400000);
    days bigint := div(ms::numeric - tod, 86400000);
    z bigint := days + 719468;
    era bigint := (case when z >= 0 then z else z - 146096 end) / 146097;
    doe bigint := z - era * 146097;
    yoe bigint := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    doy bigint := doe - (365 * yoe + yoe / 4 - yoe / 100);
    mp bigint := (5 * doy + 2) / 153;
    mo bigint := case when mp < 10 then mp + 3 else mp - 9 end;
    y bigint := yoe + era * 400 + (mo <= 2)::int;
begin
    if y not between 0 and 9999 then
        return null;
    end if;
    return format('%s-%s-%sT%s:%s:%s.%sZ', lpad(y::text, 4, '0'), lpad(mo::text, 2, '0'), lpad((doy - (153 * mp + 2) / 5 + 1)::text, 2, '0'),
                  lpad((tod / 3600000)::text, 2, '0'), lpad((tod / 60000 % 60)::text, 2, '0'), lpad((tod / 1000 % 60)::text, 2, '0'),
                  lpad((tod % 1000)::text, 3, '0'));
end;
$$;

-- An internal extension value in Cedar's JSON form: {"__extn": {"fn", "arg"}}
-- with the canonical text (decimal "1.2300", ip "10.0.0.1/32", datetime
-- "2024-01-01T00:00:00.000Z", duration "5400000ms"). A datetime outside the
-- years 0000 to 9999 is Cedar's own form for it, offset(datetime("1970-01-01"),
-- duration("<ms>ms")), which _cedar_value_in reads back.
create function permissions._cedar_extn_out(v jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
    fn text := v -> '__extn' ->> 'fn';
    x jsonb := v -> '__extn' -> 'v';
    t text;
begin
    if fn = 'decimal' then
        t := case when x::text::numeric < 0 then '-' else '' end || div(abs(x::text::numeric), 10000)::text
             || '.' || lpad(mod(abs(x::text::numeric), 10000)::text, 4, '0');
    elsif fn = 'ip' then
        t := x #>> '{}';
    elsif fn = 'duration' then
        t := x::text || 'ms';
    else
        t := permissions._cedar_datetime_text(x::text::bigint);
        if t is null then
            return jsonb_build_object('__extn', jsonb_build_object('fn', 'offset', 'args', jsonb_build_array(
                jsonb_build_object('__extn', jsonb_build_object('fn', 'datetime', 'arg', '1970-01-01')),
                jsonb_build_object('__extn', jsonb_build_object('fn', 'duration', 'arg', x::text || 'ms')))));
        end if;
    end if;
    return jsonb_build_object('__extn', jsonb_build_object('fn', fn, 'arg', t));
end;
$$;

-- A Cedar JSON value (entity attrs and tags, context, an EST Value) in the
-- internal form, or an error: code is invalid, unsupported or limit, and err
-- says what and where (p_path, a JSON path).
create function permissions._cedar_value_in(v jsonb, p_path text, p_depth int,
                                            out val jsonb, out code text, out err text)
language plpgsql immutable
as $$
declare
    t text := jsonb_typeof(v);
    u record;
    x record;
    kv record;
    acc jsonb;
    i int;
    fn text;
    w jsonb;
    vals jsonb[];
begin
    if t in ('boolean', 'string') then
        val := v;
        return;
    elsif t = 'number' then
        if scale(v::text::numeric) > 0 or v::text::numeric not between -9223372036854775808 and 9223372036854775807 then
            code := 'invalid';
            err := format('%s: %s is not a Long (an integer from -9223372036854775808 to 9223372036854775807)', p_path, v);
            return;
        end if;
        val := v;
        return;
    elsif t = 'null' then
        code := 'invalid';
        err := format('%s: null is not a Cedar value', p_path);
        return;
    end if;
    if p_depth > (permissions._cedar_limits()).value_depth then
        code := 'limit';
        err := format('%s: sets and records nest deeper than %s levels', p_path, (permissions._cedar_limits()).value_depth);
        return;
    end if;
    if t = 'array' then
        acc := '[]';
        for i in 0 .. jsonb_array_length(v) - 1 loop
            if jsonb_typeof(v -> i) in ('boolean', 'string') then
                acc := acc || jsonb_build_array(v -> i);
                continue;
            end if;
            select * into x from permissions._cedar_value_in(v -> i, p_path || '[' || i || ']', p_depth + 1) r;
            if x.code is not null then
                code := x.code;
                err := x.err;
                return;
            end if;
            acc := acc || jsonb_build_array(x.val);
        end loop;
        val := permissions._cedar_set(acc);
        return;
    end if;
    -- an object: an entity reference, an extension value or a record
    if v ? '__entity' then
        select * into u from permissions._cedar_uid_json(v);
        if u.type is null then
            code := 'invalid';
            err := format('%s: an entity reference is {"__entity": {"type": "<Type>", "id": "<id>"}} with a valid type name, got %s', p_path, v);
            return;
        end if;
        val := jsonb_build_object('__entity', jsonb_build_object('type', u.type, 'id', u.id));
        return;
    elsif v ? '__extn' then
        -- Cedar's {"fn", "arg"}, or {"fn", "args": [...]} (its own output
        -- for a datetime is offset(datetime(...), duration(...)) in that form);
        -- the arguments are values too
        w := v -> '__extn';
        if (select count(*) from jsonb_object_keys(v)) <> 1 or jsonb_typeof(w) <> 'object'
           or jsonb_typeof(w -> 'fn') is distinct from 'string' or w - '{fn,arg,args}'::text[] <> '{}'
           or (w ? 'arg') = (w ? 'args') or (w ? 'args' and jsonb_typeof(w -> 'args') <> 'array') then
            code := 'invalid';
            err := format('%s: an extension value is {"__extn": {"fn": "<function>", "arg": "<text>"}}, got %s', p_path, v);
            return;
        end if;
        fn := w ->> 'fn';
        if not permissions._cedar_extensions() ? fn then
            code := 'invalid';
            err := format('%s: unknown extension function ''%s''', p_path, fn);
            return;
        end if;
        -- Cedar applies the function to the arguments (each a value, a
        -- constructor's a string) as it would in a policy: decimal, ip,
        -- datetime and duration, but also offset or toDate. An error there
        -- is an invalid value.
        if fn in ('decimal', 'ip', 'datetime', 'duration') and jsonb_typeof(w -> 'arg') = 'string' then
            -- the common case, without the general call
            val := permissions._cedar_extn(fn, w ->> 'arg');
            if val is not null then
                return;
            end if;
        end if;
        acc := case when w ? 'arg' then jsonb_build_array(w -> 'arg') else w -> 'args' end;
        for i in 0 .. jsonb_array_length(acc) - 1 loop
            select * into x from permissions._cedar_value_in(acc -> i, p_path || '.__extn.' || case when w ? 'arg' then 'arg' else 'args[' || i || ']' end,
                                                             p_depth + 1) r;
            if x.code is not null then
                code := x.code;
                err := x.err;
                return;
            end if;
            vals := vals || x.val;
        end loop;
        val := permissions._cedar_call(fn, vals, false);
        if val is null then
            code := 'extension';
            begin
                perform permissions._cedar_call(fn, vals, true);
            exception when sqlstate 'CE001' then
                err := format('%s: %s', p_path, sqlerrm);
            end;
            return;
        end if;
        return;
    end if;
    -- a record: Bools and Strings stay as they are; everything else is
    -- checked or converted, and the record is rebuilt only if a value changed
    acc := v;
    for kv in select * from jsonb_each(v) e where jsonb_typeof(e.value) not in ('boolean', 'string') loop
        select * into x from permissions._cedar_value_in(kv.value, p_path || '.' || kv.key, p_depth + 1) r;
        if x.code is not null then
            code := x.code;
            err := x.err;
            return;
        end if;
        if x.val <> kv.value then
            acc := acc || jsonb_build_object(kv.key, x.val);
        end if;
    end loop;
    val := acc;
end;
$$;

-- An internal value in Cedar's JSON form (cedar_read_entities): the same
-- value, with each extension value back in {"__extn": {"fn", "arg"}}.
create function permissions._cedar_value_out(v jsonb)
returns jsonb
language plpgsql immutable
as $$
begin
    if strpos(v::text, '"__extn"') = 0 then
        return v;
    elsif jsonb_typeof(v) = 'array' then
        return (select jsonb_agg(permissions._cedar_value_out(e) order by o) from jsonb_array_elements(v) with ordinality t(e, o));
    elsif v ? '__extn' then
        return permissions._cedar_extn_out(v);
    end if;
    return (select jsonb_object_agg(e.key, permissions._cedar_value_out(e.value)) from jsonb_each(v) e);
end;
$$;

-- One entity of Cedar entity JSON ({"uid", "attrs", "parents", "tags"}),
-- checked and in internal form, or an error (code: invalid, unsupported or
-- limit; err says what).
create function permissions._cedar_entity_in(e jsonb, out t text, out i text, out attrs jsonb, out tags jsonb,
                                             out parents jsonb, out code text, out err text)
language plpgsql immutable
as $$
declare
    u record;
    x record;
    pv jsonb;
    acc jsonb[];
begin
    code := 'invalid';
    if jsonb_typeof(e) <> 'object' then
        err := format('an entity must be a JSON object, got a JSON %s', jsonb_typeof(e));
        return;
    end if;
    if e - '{uid,attrs,parents,tags}'::text[] <> '{}' then
        err := format('unknown keys %s (an entity has uid, attrs, parents and tags)',
                      (select string_agg(k, ', ' order by k) from jsonb_object_keys(e - '{uid,attrs,parents,tags}'::text[]) k));
        return;
    end if;
    select * into u from permissions._cedar_uid_json(e -> 'uid');
    if u.type is null then
        err := format('uid must be {"type": "<Type>", "id": "<id>"} with a valid type name, got %s',
                      coalesce((e -> 'uid')::text, 'nothing'));
        return;
    end if;
    if jsonb_typeof(coalesce(e -> 'attrs', '{}')) not in ('object', 'null') then
        err := format('%s: attrs must be a JSON object, got a JSON %s', permissions._cedar_uid_text(u.type, u.id), jsonb_typeof(e -> 'attrs'));
        return;
    end if;
    if jsonb_typeof(coalesce(e -> 'tags', '{}')) not in ('object', 'null') then
        err := format('%s: tags must be a JSON object, got a JSON %s', permissions._cedar_uid_text(u.type, u.id), jsonb_typeof(e -> 'tags'));
        return;
    end if;
    if jsonb_typeof(coalesce(e -> 'parents', '[]')) not in ('array', 'null') then
        err := format('%s: parents must be a JSON array of uids, got a JSON %s', permissions._cedar_uid_text(u.type, u.id), jsonb_typeof(e -> 'parents'));
        return;
    end if;
    if jsonb_typeof(e -> 'parents') = 'array' then
        for pv in select p from jsonb_array_elements(e -> 'parents') p loop
            select * into x from permissions._cedar_uid_json(pv);
            if x.type is null then
                err := format('%s: a parent is not a uid {"type": "<Type>", "id": "<id>"}: %s', permissions._cedar_uid_text(u.type, u.id), pv);
                return;
            end if;
            acc := acc || jsonb_build_array(x.type, x.id);
        end loop;
    end if;
    attrs := '{}';
    tags := '{}';
    if not (e -> 'attrs' is null or e -> 'attrs' = 'null' or e -> 'attrs' = '{}') then
        select * into x from permissions._cedar_value_in(e -> 'attrs', 'attrs', 1) r;
        attrs := x.val;
        code := x.code;
        err := x.err;
    end if;
    if err is null and not (e -> 'tags' is null or e -> 'tags' = 'null' or e -> 'tags' = '{}') then
        select * into x from permissions._cedar_value_in(e -> 'tags', 'tags', 1) r;
        tags := x.val;
        code := x.code;
        err := x.err;
    end if;
    if err is not null then
        err := format('%s: %s', permissions._cedar_uid_text(u.type, u.id), err);
        return;
    end if;
    code := null;
    t := u.type;
    i := u.id;
    parents := case when cardinality(acc) > 1 then permissions._cedar_set(to_jsonb(acc)) else coalesce(to_jsonb(acc), '[]') end;
end;
$$;

-- Cedar entity JSON (an array of entities), checked and in internal form:
-- [{"t", "i", "attrs", "tags", "parents": [[type, id], ...]}]. p_arg names
-- the argument for the messages and p_max is the limit on the number of
-- entities. Raises cedar:invalid_entity or cedar:limit_exceeded at the first bad entity.
create function permissions._cedar_entities_in(p_entities jsonb, p_arg text, p_max int)
returns jsonb
language plpgsql stable
as $$
declare
    r jsonb;
    res jsonb;
begin
    if jsonb_typeof(p_entities) <> 'array' then
        r := jsonb_build_object('n', 0, 'code', 'invalid',
                                'err', format('%s must be a JSON array of entities, got a JSON %s', p_arg, jsonb_typeof(p_entities)));
    elsif jsonb_array_length(p_entities) > p_max then
        r := jsonb_build_object('n', 0, 'code', 'limit',
                                'err', format('too many entities: %s (the limit is %s)', jsonb_array_length(p_entities), p_max));
    else
        select jsonb_agg(jsonb_build_object('t', x.t, 'i', x.i, 'attrs', x.attrs, 'tags', x.tags, 'parents', x.parents)
                         order by x.n) filter (where x.code is null),
               jsonb_agg(jsonb_build_object('n', x.n, 'code', x.code, 'err', x.err) order by x.n)
                 filter (where x.code is not null) -> 0
        into res, r
        from (select e.n - 1 as n, v.t, v.i, v.attrs, v.tags, v.parents,
                     case when v.code is null and row_number() over (partition by v.t, v.i order by e.n) > 1
                          then 'invalid' else v.code end as code,
                     case when v.code is null and row_number() over (partition by v.t, v.i order by e.n) > 1
                          then format('duplicate entity %s', permissions._cedar_uid_text(v.t, v.i)) else v.err end as err
              from jsonb_array_elements(p_entities) with ordinality e(v, n)
              cross join lateral permissions._cedar_entity_in(e.v) v) x;
        if r is null then
            return coalesce(res, '[]');
        end if;
    end if;
    perform permissions._cedar_error(case r ->> 'code' when 'limit' then 'limit_exceeded' else 'invalid_entity' end,
        format('invalid entity at index %s of %s: %s', r ->> 'n', p_arg, r ->> 'err'),
        hint => case r ->> 'code'
            when 'limit' then format('An argument holds at most %s entities, and sets and records in attributes and tags nest at most %s levels.',
                                     p_max, (permissions._cedar_limits()).value_depth)
            when 'extension' then 'Write an extension value as {"__extn": {"fn": "decimal", "arg": "12.34"}}, with fn one of decimal, ip, datetime and duration and an arg its constructor accepts: decimal("12.34"), ip("10.0.0.0/8"), datetime("2024-10-15T11:35:00Z"), duration("1h30m").'
            else 'Each entity is {"uid": {"type": "User", "id": "alice"}, "attrs": {...}, "parents": [{"type": "Group", "id": "staff"}], "tags": {...}}; write an entity reference in an attribute as {"__entity": {"type": "User", "id": "alice"}}.' end,
        p_detail => format('index=%s', r ->> 'n'));
end;
$$;

-- A Cedar JSON value as an EST expression: each {"__extn": {"fn", "arg"}} a
-- call of fn, each set a Set and each record a Record. The compiler uses it
-- for a Value with an extension value that Cedar would fail to build, so the
-- error happens when the call is evaluated, as in Cedar.
create function permissions._cedar_value_expr(v jsonb)
returns jsonb
language plpgsql immutable
as $$
begin
    return case
        when jsonb_typeof(v) = 'array' then
            jsonb_build_object('Set', coalesce((select jsonb_agg(permissions._cedar_value_expr(e) order by o)
                                                from jsonb_array_elements(v) with ordinality t(e, o)), '[]'))
        when jsonb_typeof(v) <> 'object' or v ? '__entity' then jsonb_build_object('Value', v)
        when v ? '__extn' and jsonb_typeof(v -> '__extn') = 'object' and jsonb_typeof(v -> '__extn' -> 'fn') = 'string' then
            jsonb_build_object(v -> '__extn' ->> 'fn',
                               coalesce((select jsonb_agg(permissions._cedar_value_expr(e) order by o)
                                         from jsonb_array_elements(case when v -> '__extn' ? 'arg' then jsonb_build_array(v -> '__extn' -> 'arg')
                                                                        else v -> '__extn' -> 'args' end) with ordinality t(e, o)), '[]'))
        else jsonb_build_object('Record', coalesce((select jsonb_object_agg(e.key, permissions._cedar_value_expr(e.value)) from jsonb_each(v) e), '{}'))
    end;
end;
$$;

-- ----------------------------------------------------------------------------
-- Compiler: the EST (Cedar's JSON policy format) to the ast
-- ----------------------------------------------------------------------------
-- The ast (e-cedar.md section 2.3). Every node has its kind in "k":
--
--   {"k":"lit","v":V}                  a value, internal form (sets and records of constants folded)
--   {"k":"var","n":"principal"}        principal, action, resource, context
--   {"k":"and"|"or","a":x,"b":y}
--   {"k":"if","c":c,"t":t,"e":e}
--   {"k":"not"|"neg"|"isEmpty","a":x}
--   {"k":"eq"|"ne"|"lt"|"le"|"gt"|"ge"|"add"|"sub"|"mul"|"in"|"contains"|"containsAll"|"containsAny"
--        |"hasTag"|"getTag","a":x,"b":y}
--   {"k":"get"|"has","a":x,"f":"name"}  `e has a.b` is has(e,a) && has(e.a,b), as in Cedar
--   {"k":"is","a":x,"t":"Type"}        with "in":y for `is ... in`
--   {"k":"like","a":x,"p":"<SQL LIKE pattern, \ escapes>"}
--   {"k":"set","a":[x,...]}, {"k":"rec","a":{"key":x,...}}
--   {"k":"call","f":"name","a":[x,...]}  an extension function or method (receiver first);
--                                      a constructor of a valid string literal is a lit
--
-- The conditions of a policy are one chain of "and" in source order, with
-- `unless c` as not(c). The scope is not in the ast: it goes to the scope
-- columns of cedar_policies.

-- One EST expression: {"ast", "n" (nodes)} or {"code", "err", "path"} where
-- code is invalid_policy, unsupported or limit_exceeded.
create function permissions._cedar_compile(e jsonb, p_path text, p_depth int)
returns jsonb
language plpgsql immutable
as $$
declare
    op text;
    a jsonb;
    x jsonb;
    y jsonb;
    z jsonb;
    v record;
    kv record;
    i int;
    n int := 1;
    lits boolean := true;
    acc jsonb;
    pat text := '';
    attrs jsonb;
    bin constant jsonb := '{"==": "eq", "!=": "ne", "<": "lt", "<=": "le", ">": "gt", ">=": "ge",
                            "+": "add", "-": "sub", "*": "mul", "in": "in", "&&": "and", "||": "or",
                            "contains": "contains", "containsAll": "containsAll", "containsAny": "containsAny",
                            "hasTag": "hasTag", "getTag": "getTag"}';
    lim record := permissions._cedar_limits();
begin
    if p_depth > lim.policy_depth then
        return jsonb_build_object('code', 'limit_exceeded', 'path', p_path,
                                  'err', format('expressions nest deeper than %s levels', lim.policy_depth));
    end if;
    if jsonb_typeof(e) <> 'object' or (select count(*) from jsonb_object_keys(e)) <> 1 then
        return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                  'err', format('an expression is a JSON object with one key (the operator), got %s', left(e::text, 200)));
    end if;
    select k into op from jsonb_object_keys(e) k;
    a := e -> op;
    p_path := p_path || '.' || case when op ~ '^[A-Za-z_][A-Za-z0-9_]*$' then op else '"' || op || '"' end;

    -- the arguments' shape
    if op in ('!', 'neg', 'isEmpty') then
        if jsonb_typeof(a) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(a) k) <> '{arg}' then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path, 'err', format('%s takes {"arg": <expression>}', op));
        end if;
    elsif bin ? op then
        if jsonb_typeof(a) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(a) k) <> '{left,right}' then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', format('%s takes {"left": <expression>, "right": <expression>}', op));
        end if;
    elsif op in ('.', 'has') then
        if jsonb_typeof(a) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(a) k) <> '{attr,left}'
           or not (jsonb_typeof(a -> 'attr') = 'string'
                   or (op = 'has' and jsonb_typeof(a -> 'attr') = 'array' and jsonb_array_length(a -> 'attr') > 0
                       and not exists (select 1 from jsonb_array_elements(a -> 'attr') t where jsonb_typeof(t) <> 'string'))) then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', format('%s takes {"left": <expression>, "attr": "<name>"}', op));
        end if;
    elsif op = 'is' then
        if jsonb_typeof(a) <> 'object'
           or exists (select 1 from jsonb_object_keys(a) k where k not in ('left', 'entity_type', 'in'))
           or not (a ? 'left') or not permissions._cedar_is_name(a ->> 'entity_type') then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', 'is takes {"left": <expression>, "entity_type": "<Type>"} and an optional "in": <expression>');
        end if;
    elsif op = 'like' then
        if jsonb_typeof(a) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(a) k) <> '{left,pattern}'
           or jsonb_typeof(a -> 'pattern') <> 'array'
           or exists (select 1 from jsonb_array_elements(a -> 'pattern') t
                      where t <> '"Wildcard"' and not (jsonb_typeof(t) = 'object' and jsonb_typeof(t -> 'Literal') = 'string'
                                                       and (select count(*) from jsonb_object_keys(t)) = 1)) then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', 'like takes {"left": <expression>, "pattern": ["Wildcard", {"Literal": "<text>"}, ...]}');
        end if;
    elsif op = 'if-then-else' then
        if jsonb_typeof(a) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(a) k) <> '{else,if,then}' then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', 'if-then-else takes {"if": <expression>, "then": <expression>, "else": <expression>}');
        end if;
    end if;

    if op = 'Value' then
        select * into v from permissions._cedar_value_in(a, 'value', 1) r;
        if v.code = 'extension' then
            -- an extension value Cedar would fail to build: as in Cedar, a
            -- call that errs when it is evaluated
            return permissions._cedar_compile(permissions._cedar_value_expr(a), p_path, p_depth);
        elsif v.code is not null then
            return jsonb_build_object('code', case v.code when 'limit' then 'limit_exceeded' else 'invalid_policy' end,
                                      'path', p_path, 'err', v.err);
        end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'lit', 'v', v.val), 'n', 1);
    elsif op = 'Var' then
        if jsonb_typeof(a) <> 'string' or a #>> '{}' not in ('principal', 'action', 'resource', 'context') then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', format('Var is "principal", "action", "resource" or "context", got %s', a));
        end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'var', 'n', a #>> '{}'), 'n', 1);
    elsif op = 'Slot' then
        -- Cedar allows slots in the scope only (SlotsInConditionClause).
        return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                  'err', format('a slot (%s) can appear only in the principal or resource scope of a template, not in a condition', a),
                                  'hint', 'Constrain the slot in the scope (principal == ?principal, resource in ?resource) and compare principal or resource in the condition.');
    elsif op = 'Unknown' then
        return jsonb_build_object('code', 'unsupported', 'path', p_path,
                                  'err', 'Unknown is for partial evaluation, which is not supported');
    elsif op in ('!', 'neg', 'isEmpty') then
        x := permissions._cedar_compile(a -> 'arg', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        return jsonb_build_object('ast', jsonb_build_object('k', case op when '!' then 'not' else op end, 'a', x -> 'ast'),
                                  'n', 1 + (x ->> 'n')::int);
    elsif bin ? op then
        x := permissions._cedar_compile(a -> 'left', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        y := permissions._cedar_compile(a -> 'right', p_path, p_depth + 1);
        if y ? 'code' then return y; end if;
        return jsonb_build_object('ast', jsonb_build_object('k', bin ->> op, 'a', x -> 'ast', 'b', y -> 'ast'),
                                  'n', 1 + (x ->> 'n')::int + (y ->> 'n')::int);
    elsif op = '.' then
        x := permissions._cedar_compile(a -> 'left', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'get', 'a', x -> 'ast', 'f', a ->> 'attr'),
                                  'n', 1 + (x ->> 'n')::int);
    elsif op = 'has' then
        x := permissions._cedar_compile(a -> 'left', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        attrs := case when jsonb_typeof(a -> 'attr') = 'string' then jsonb_build_array(a -> 'attr') else a -> 'attr' end;
        -- e has a.b.c: e has a && e.a has b && e.a.b has c
        y := x -> 'ast';                                  -- e, then e.a, then e.a.b
        z := null;                                        -- the chain so far
        for i in 0 .. jsonb_array_length(attrs) - 1 loop
            acc := jsonb_build_object('k', 'has', 'a', y, 'f', attrs ->> i);
            z := case when z is null then acc else jsonb_build_object('k', 'and', 'a', z, 'b', acc) end;
            y := jsonb_build_object('k', 'get', 'a', y, 'f', attrs ->> i);
        end loop;
        return jsonb_build_object('ast', z, 'n', jsonb_array_length(attrs) + (x ->> 'n')::int);
    elsif op = 'is' then
        x := permissions._cedar_compile(a -> 'left', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        acc := jsonb_build_object('k', 'is', 'a', x -> 'ast', 't', a ->> 'entity_type');
        n := 1 + (x ->> 'n')::int;
        if a ? 'in' then
            y := permissions._cedar_compile(a -> 'in', p_path, p_depth + 1);
            if y ? 'code' then return y; end if;
            acc := acc || jsonb_build_object('in', y -> 'ast');
            n := n + (y ->> 'n')::int;
        end if;
        return jsonb_build_object('ast', acc, 'n', n);
    elsif op = 'like' then
        x := permissions._cedar_compile(a -> 'left', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        for z in select t from jsonb_array_elements(a -> 'pattern') t loop
            pat := pat || case when z = '"Wildcard"' then '%'
                               else regexp_replace(z ->> 'Literal', '([\\%_])', '\\\1', 'g') end;
        end loop;
        return jsonb_build_object('ast', jsonb_build_object('k', 'like', 'a', x -> 'ast', 'p', pat),
                                  'n', 1 + (x ->> 'n')::int);
    elsif op = 'if-then-else' then
        x := permissions._cedar_compile(a -> 'if', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        y := permissions._cedar_compile(a -> 'then', p_path, p_depth + 1);
        if y ? 'code' then return y; end if;
        z := permissions._cedar_compile(a -> 'else', p_path, p_depth + 1);
        if z ? 'code' then return z; end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'if', 'c', x -> 'ast', 't', y -> 'ast', 'e', z -> 'ast'),
                                  'n', 1 + (x ->> 'n')::int + (y ->> 'n')::int + (z ->> 'n')::int);
    elsif op = 'Set' then
        if jsonb_typeof(a) <> 'array' then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path, 'err', 'Set takes an array of expressions');
        end if;
        acc := '[]';
        for i in 0 .. jsonb_array_length(a) - 1 loop
            x := permissions._cedar_compile(a -> i, p_path || '[' || i || ']', p_depth + 1);
            if x ? 'code' then return x; end if;
            acc := acc || jsonb_build_array(x -> 'ast');
            n := n + (x ->> 'n')::int;
            lits := lits and x -> 'ast' ->> 'k' = 'lit';
        end loop;
        if lits then
            return jsonb_build_object('ast', jsonb_build_object('k', 'lit', 'v',
                                          permissions._cedar_set(coalesce((select jsonb_agg(t -> 'v') from jsonb_array_elements(acc) t), '[]'))),
                                      'n', n);
        end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'set', 'a', acc), 'n', n);
    elsif op = 'Record' then
        if jsonb_typeof(a) <> 'object' then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path, 'err', 'Record takes an object of expressions');
        end if;
        if a ? '__entity' or a ? '__extn' then
            return jsonb_build_object('code', 'unsupported', 'path', p_path,
                                      'err', 'a record with the key __entity or __extn (it would read as an entity or an extension value)');
        end if;
        acc := '{}';
        for kv in select * from jsonb_each(a) loop
            x := permissions._cedar_compile(kv.value, p_path || '.' || kv.key, p_depth + 1);
            if x ? 'code' then return x; end if;
            acc := acc || jsonb_build_object(kv.key, x -> 'ast');
            n := n + (x ->> 'n')::int;
            lits := lits and x -> 'ast' ->> 'k' = 'lit';
        end loop;
        if lits then
            return jsonb_build_object('ast', jsonb_build_object('k', 'lit', 'v',
                                          coalesce((select jsonb_object_agg(t.key, t.value -> 'v') from jsonb_each(acc) t), '{}')),
                                      'n', n);
        end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'rec', 'a', acc), 'n', n);
    elsif jsonb_typeof(a) = 'array' then
        -- an extension function or method: {"name": [receiver, args...]}
        if not permissions._cedar_extensions() ? op then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', format('unknown extension function ''%s''', op),
                                      'hint', permissions._did_you_mean(op, array(select jsonb_object_keys(permissions._cedar_extensions())),
                                                                        'Extension functions'));
        end if;
        acc := '[]';
        for i in 0 .. jsonb_array_length(a) - 1 loop
            x := permissions._cedar_compile(a -> i, p_path || '[' || i || ']', p_depth + 1);
            if x ? 'code' then return x; end if;
            acc := acc || jsonb_build_array(x -> 'ast');
            n := n + (x ->> 'n')::int;
        end loop;
        -- A constructor of a valid string literal is folded into its value.
        -- Cedar checks the string only when it evaluates the call, so an
        -- invalid one stays a call and errs then (the arity, too).
        if op in ('decimal', 'ip', 'datetime', 'duration') and jsonb_array_length(acc) = 1
           and acc #>> '{0,k}' = 'lit' and jsonb_typeof(acc #> '{0,v}') = 'string' then
            y := permissions._cedar_extn(op, acc #>> '{0,v}');
            if y is not null then
                return jsonb_build_object('ast', jsonb_build_object('k', 'lit', 'v', y), 'n', n);
            end if;
        end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'call', 'f', op, 'a', acc), 'n', n);
    end if;
    return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                              'err', format('unknown expression kind ''%s''', op),
                              'hint', permissions._did_you_mean(op,
                                  '{Value,Var,Slot,!,neg,==,!=,in,<,<=,>,>=,&&,||,+,-,*,contains,containsAll,containsAny,isEmpty,hasTag,getTag,.,has,is,like,if-then-else,Set,Record}',
                                  'Expression kinds'));
end;
$$;

-- One scope constraint of the EST ({"op": ...}): {"op", "type", "uid"} for the
-- scope columns, or {"code", "err", "path"}. p_var is principal, action or
-- resource. For a template (p_template), the principal and resource scopes
-- may hold their slot instead of an entity: {"op": "==" or "in", "slot":
-- "?principal"}, or "in": {"slot": ...} under "is". The result then has
-- "slot" instead of "uid"; a link fills it (_cedar_link).
create function permissions._cedar_compile_scope(s jsonb, p_var text, p_template boolean default false)
returns jsonb
language plpgsql immutable
as $$
declare
    op text := s ->> 'op';
    u record;
    keys text[];
    e jsonb;
    path text := '$.' || p_var;
    act boolean := p_var = 'action';
    form text := case when p_var = 'action'
                      then '{"op": "All"}, {"op": "==", "entity": E}, {"op": "in", "entity": E} or {"op": "in", "entities": [E, ...]}'
                      else '{"op": "All"}, {"op": "==", "entity": E}, {"op": "in", "entity": E} or {"op": "is", "entity_type": "T"} with an optional "in": {"entity": E}' end
                 || ', where E is {"type": "<Type>", "id": "<id>"}';
begin
    if jsonb_typeof(s) <> 'object' or op is null then
        return jsonb_build_object('code', 'invalid_policy', 'path', path, 'err', format('the %s scope is %s', p_var, form));
    end if;
    if s ? 'slot' or (jsonb_typeof(s -> 'in') = 'object' and s -> 'in' ? 'slot') then
        e := coalesce(s -> 'slot', s -> 'in' -> 'slot');
        if not p_template then
            return jsonb_build_object('code', 'invalid_policy', 'path', path,
                                      'err', format('a static policy has no slots, and the %s scope has %s', p_var, e),
                                      'hint', 'A policy with slots is a template: put it with cedar_put_template(template_id => ..., template => ...), then fill the slots with cedar_link_template.');
        end if;
        if act or e is distinct from to_jsonb('?' || p_var) then
            return jsonb_build_object('code', 'invalid_policy', 'path', path,
                                      'err', format('the %s scope can hold only the slot %s, got %s', p_var,
                                                    case when act then 'none: templates have the slots ?principal and ?resource' else '?' || p_var end, e),
                                      'hint', 'A template has at most two slots: ?principal in the principal scope and ?resource in the resource scope.');
        end if;
        if op in ('==', 'in') and (select count(*) from jsonb_object_keys(s)) = 2 then
            return jsonb_build_object('op', op, 'slot', e);
        elsif op = 'is' and permissions._cedar_is_name(s ->> 'entity_type') and (select count(*) from jsonb_object_keys(s)) = 3
              and (select count(*) from jsonb_object_keys(s -> 'in')) = 1 then
            return jsonb_build_object('op', 'is', 'type', s ->> 'entity_type', 'slot', e);
        end if;
        return jsonb_build_object('code', 'invalid_policy', 'path', path,
                                  'err', format('the %s scope is {"op": "==" or "in", "slot": "?%s"} or {"op": "is", "entity_type": "T", "in": {"slot": "?%s"}}; got %s',
                                                p_var, p_var, p_var, left(s::text, 200)));
    end if;
    if op = 'All' and (select count(*) from jsonb_object_keys(s)) = 1 then
        return jsonb_build_object('op', 'All');
    elsif op in ('==', 'in') and s ? 'entity' and (select count(*) from jsonb_object_keys(s)) = 2 then
        select * into u from permissions._cedar_uid_json(s -> 'entity');
        if u.type is not null and (not act or u.type ~ '(^|::)Action$') then
            return jsonb_build_object('op', op, 'uids', jsonb_build_array(permissions._cedar_key(u.type, u.id)),
                                      'uid', permissions._cedar_key(u.type, u.id));
        end if;
        if u.type is not null then
            return jsonb_build_object('code', 'invalid_policy', 'path', path || '.entity',
                                      'err', format('the action scope names %s, which is not an action (an action''s type is Action or Namespace::Action)',
                                                    permissions._cedar_uid_text(u.type, u.id)));
        end if;
    elsif act and op = 'in' and jsonb_typeof(s -> 'entities') = 'array' and (select count(*) from jsonb_object_keys(s)) = 2 then
        for e in select x from jsonb_array_elements(s -> 'entities') x loop
            select * into u from permissions._cedar_uid_json(e);
            if u.type is null or u.type !~ '(^|::)Action$' then
                return jsonb_build_object('code', 'invalid_policy', 'path', path || '.entities',
                                          'err', format('the action scope lists %s, which is not an action uid (type Action or Namespace::Action)', e));
            end if;
            keys := keys || permissions._cedar_key(u.type, u.id);
        end loop;
        return jsonb_build_object('op', 'in', 'uids', coalesce(to_jsonb(keys), '[]'));
    elsif not act and op = 'is' and permissions._cedar_is_name(s ->> 'entity_type')
          and not exists (select 1 from jsonb_object_keys(s) k where k not in ('op', 'entity_type', 'in')) then
        if not s ? 'in' then
            return jsonb_build_object('op', 'is', 'type', s ->> 'entity_type');
        end if;
        if jsonb_typeof(s -> 'in') = 'object' and (select count(*) from jsonb_object_keys(s -> 'in')) = 1 then
            select * into u from permissions._cedar_uid_json(s -> 'in' -> 'entity');
            if u.type is not null then
                return jsonb_build_object('op', 'is', 'type', s ->> 'entity_type', 'uid', permissions._cedar_key(u.type, u.id));
            end if;
        end if;
    end if;
    return jsonb_build_object('code', 'invalid_policy', 'path', path,
                              'err', format('the %s scope is %s; got %s', p_var, form, left(s::text, 200)));
end;
$$;

-- A policy in the EST: its columns for cedar_policies ({"effect", "ast",
-- "annotations", "principal", "action", "resource"}, the scopes as
-- _cedar_compile_scope returns them). Raises cedar:invalid_policy,
-- cedar:unsupported or cedar:limit_exceeded. p_template: a template, which
-- has a slot in its principal or resource scope or both (a static policy has
-- none). p_text: the EST came from Cedar text, whose size the parser already
-- checked (policy_bytes limits the text, not the larger EST).
create function permissions._cedar_compile_policy(p_est jsonb, p_id text, p_template boolean default false,
                                                  p_text boolean default false)
returns jsonb
language plpgsql immutable
as $$
declare
    lim record := permissions._cedar_limits();
    r jsonb;
    c jsonb;
    x jsonb;
    ast jsonb;
    n int := 0;
    i int;
    s text;
    res jsonb := '{}';
begin
    if not p_text and octet_length(p_est::text) > lim.policy_bytes then
        r := jsonb_build_object('code', 'limit_exceeded', 'path', '$',
                                'err', format('the policy is %s bytes of JSON (the limit is %s)', octet_length(p_est::text), lim.policy_bytes),
                                'limit', 'policy_bytes');
    elsif jsonb_typeof(p_est) <> 'object' then
        r := jsonb_build_object('code', 'invalid_policy', 'path', '$', 'err', format('a policy is a JSON object, got a JSON %s', jsonb_typeof(p_est)));
    else
        s := (select string_agg(k, ', ' order by k) from jsonb_object_keys(p_est) k
              where k not in ('effect', 'principal', 'action', 'resource', 'conditions', 'annotations'));
        if s is not null then
            r := jsonb_build_object('code', 'invalid_policy', 'path', '$',
                                    'err', format('unknown keys %s (a policy has effect, principal, action, resource, conditions and annotations)', s));
        elsif p_est ->> 'effect' is null or p_est ->> 'effect' not in ('permit', 'forbid') or jsonb_typeof(p_est -> 'effect') <> 'string' then
            r := jsonb_build_object('code', 'invalid_policy', 'path', '$.effect',
                                    'err', format('effect is "permit" or "forbid", got %s', coalesce((p_est -> 'effect')::text, 'nothing')));
        elsif p_est ? 'annotations' and jsonb_typeof(p_est -> 'annotations') <> 'object'
              or exists (select 1 from jsonb_each(case when jsonb_typeof(p_est -> 'annotations') = 'object' then p_est -> 'annotations' end) a
                         where jsonb_typeof(a.value) not in ('string', 'null') or a.key !~ '^[_a-zA-Z][_a-zA-Z0-9]*$') then
            r := jsonb_build_object('code', 'invalid_policy', 'path', '$.annotations',
                                    'err', format('annotations are an object of identifiers to strings, got %s', left((p_est -> 'annotations')::text, 200)));
        elsif not (coalesce(jsonb_typeof(p_est -> 'conditions'), 'array') = 'array'
                   and not exists (select 1 from jsonb_array_elements(coalesce(p_est -> 'conditions', '[]')) w(cl)
                                   where jsonb_typeof(w.cl) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(w.cl) k) <> '{body,kind}'
                                      or w.cl ->> 'kind' not in ('when', 'unless') or jsonb_typeof(w.cl -> 'kind') <> 'string')) then
            r := jsonb_build_object('code', 'invalid_policy', 'path', '$.conditions',
                                    'err', 'conditions are an array of {"kind": "when" or "unless", "body": <expression>}');
        else
            res := jsonb_build_object('effect', p_est ->> 'effect',
                                      'annotations', coalesce((select jsonb_object_agg(a.key, coalesce(a.value #>> '{}', ''))
                                                               from jsonb_each(p_est -> 'annotations') a), '{}'));
            foreach s in array array['principal', 'action', 'resource'] loop
                x := permissions._cedar_compile_scope(p_est -> s, s, p_template);
                if x ? 'code' then
                    r := x;
                    exit;
                end if;
                res := res || jsonb_build_object(s, x);
            end loop;
            if r is null and p_template and not (res -> 'principal' ? 'slot' or res -> 'resource' ? 'slot') then
                r := jsonb_build_object('code', 'invalid_policy', 'path', '$',
                                        'err', 'a template has a slot (?principal or ?resource) in its scope, and this one has none',
                                        'hint', 'Put a policy without slots with cedar_put_policy, or write the template with a slot, for example permit (principal == ?principal, action, resource);');
            end if;
            if r is null then
                i := 0;
                for c in select t from jsonb_array_elements(coalesce(p_est -> 'conditions', '[]')) t loop
                    x := permissions._cedar_compile(c -> 'body', '$.conditions[' || i || '].body', 1);
                    if x ? 'code' then
                        r := x;
                        exit;
                    end if;
                    n := n + (x ->> 'n')::int;
                    x := case when c ->> 'kind' = 'unless' then jsonb_build_object('k', 'not', 'a', x -> 'ast') else x -> 'ast' end;
                    ast := case when ast is null then x else jsonb_build_object('k', 'and', 'a', ast, 'b', x) end;
                    i := i + 1;
                end loop;
            end if;
            if r is null and n > lim.policy_nodes then
                r := jsonb_build_object('code', 'limit_exceeded', 'path', '$.conditions', 'limit', 'policy_nodes',
                                        'err', format('the conditions have %s expression nodes (the limit is %s)', n, lim.policy_nodes));
            end if;
        end if;
    end if;
    if r is not null then
        perform permissions._cedar_error(r ->> 'code',
            format('invalid %s %L at %s: %s', case when p_template then 'template' else 'policy' end, p_id, r ->> 'path', r ->> 'err'),
            hint => coalesce(r ->> 'hint', case r ->> 'code'
                when 'limit_exceeded' then format('Split the policy into smaller policies: a policy holds at most %s bytes, %s expression nodes and %s levels of nesting.',
                                                  lim.policy_bytes, lim.policy_nodes, lim.policy_depth)
                when 'unsupported' then 'Partial evaluation (Unknown) is not supported, and a record literal cannot have the key __entity or __extn, which Cedar''s JSON reserves for entity and extension values.'
                else 'Pass the policy in Cedar''s JSON policy format, as `cedar translate-policy --direction cedar-to-json` prints it (https://docs.cedarpolicy.com/policies/json-format.html).' end),
            p_detail => case r ->> 'code'
                when 'limit_exceeded' then format('limit=%L', coalesce(r ->> 'limit', 'policy_depth'))
                when 'unsupported' then format('feature=%L', coalesce(r ->> 'feature', r ->> 'err'))
                else format('path=%L', r ->> 'path') end);
    end if;
    return res || jsonb_build_object('ast', ast);
end;
$$;

-- ----------------------------------------------------------------------------
-- Cedar text: the policy parser (phase 3)
-- ----------------------------------------------------------------------------
-- Cedar policy text parses to Cedar's JSON policy format (the EST), exactly
-- as cedar-policy-cli 4.14.0 `translate-policy --direction cedar-to-json`
-- writes it, so text and JSON reach one compiler (_cedar_compile_policy) and
-- one evaluator. jsonb equality with the CLI's output is the oracle: every
-- text policy of the corpus (test/cedar/generate.py --parse-est), and the
-- stored EST after a text put (--check-est).
--
--   _cedar_parse_policy(src) returns jsonb
--     Exactly one policy or template: its EST object {"effect", "principal",
--     "action", "resource", "conditions", "annotations"?}. "annotations" is
--     present only when the policy has some. A template is a policy whose
--     principal or resource scope holds a slot ({"slot": "?principal"}, or
--     "in": {"slot": ...} under "is"); the caller (cedar_put_policy,
--     cedar_put_template) checks which one it wants. No policy, or more than
--     one, is a parse error.
--
--   _cedar_parse_policies(src) returns jsonb
--     A policy set (zero or more policies), in the CLI's policy-set shape:
--       {"staticPolicies": {id: EST, ...}, "templates": {id: EST, ...},
--        "templateLinks": []}
--     Policy ids follow the CLI: the value of an @id annotation when the
--     policy has one (a bare @id gives ""), else "policy<i>", where i counts
--     every policy and template of the text from 0 in source order. A
--     duplicate id is a parse error. No public function takes a policy set
--     (e-cedar.md section 13); the parser oracle checks this path.
--
-- Both return null for a null src. Errors raise through _cedar_error:
--   cedar:parse_error line=<n> column=<n>      SQLSTATE 42601
--   cedar:limit_exceeded limit='<name>'         SQLSTATE 54000
--   cedar:unsupported feature='U+0000'          SQLSTATE 0A000
-- with a MESSAGE that names the token found and what was expected, and a HINT
-- (test/spec/d/55_cedar_parse.sql checks them). The limits are those of
-- _cedar_limits: policy_bytes for the text of one policy, policy_nodes, and
-- policy_depth (the depth of the EST, and of brackets in the text).
--
-- CLI quirks the EST reproduces (and the compiler accepts):
--   - A negative integer literal folds into Value (-5 is {"Value": -5}); a
--     minus before anything else is neg. --5 is neg(Value -5).
--     -9223372036854775808 is valid only this way.
--   - action in [A] with one entity is {"op": "in", "entity": A}; with
--     zero or two or more it is {"op": "in", "entities": [...]}.
--   - e has a.b.c (several attributes) is {"has": {"left", "attr": ["a",
--     "b", "c"]}}: attr is an array. One attribute gives a string.
--   - like patterns are one {"Literal": "c"} per character, and "Wildcard"
--     for each *; a * written as an escape (\u{2a}, \x2a) is a wildcard too,
--     only \* is a literal star.
--   - A bare annotation @foo has the value null.
--   - !x applied n times nests n "!" nodes (no folding).

-- A token for an error message.
create function permissions._cedar_token_text(p_kind text, p_value text)
returns text
language sql
immutable
as $$
    select case p_kind
        when 'eof' then 'end of input'
        when 'str' then format('string literal "%s"', case when length(p_value) > 30 then left(p_value, 27) || '...' else p_value end)
        when 'int' then format('number %s', p_value)
        when 'id' then format('''%s''', p_value)
        when 'slot' then format('slot %s', p_value)
        else format('''%s''', p_kind) end
$$;

-- "unexpected <token> at line L, column C: expected <what>"
create function permissions._cedar_syntax_error(k text[], v text[], ln int[], cl int[], q int, p_expected text, hint text)
returns void
language plpgsql
as $$
begin
    perform permissions._cedar_error('parse_error',
        format('unexpected %s at line %s, column %s: expected %s',
               permissions._cedar_token_text(k[q], v[q]), ln[q], cl[q], p_expected),
        hint => coalesce(hint, 'Check the policy against the Cedar grammar: https://docs.cedarpolicy.com/policies/syntax-grammar.html'),
        p_detail => format('line=%s column=%s', ln[q], cl[q]));
end;
$$;

-- Any other parse error, at a position.
create function permissions._cedar_parse_fail(p_message text, p_line int, p_col int, hint text)
returns void
language plpgsql
as $$
begin
    perform permissions._cedar_error('parse_error', format('%s at line %s, column %s', p_message, p_line, p_col),
        hint => coalesce(hint, 'Check the policy against the Cedar grammar: https://docs.cedarpolicy.com/policies/syntax-grammar.html'),
        p_detail => format('line=%s column=%s', p_line, p_col));
end;
$$;

-- ----------------------------------------------------------------------------
-- Tokens
-- ----------------------------------------------------------------------------
-- One regular expression splits the whole text (the scan runs in C, and each
-- match is a token, white space or a comment; the last branch takes any other
-- character, so the matches cover the text). Kinds: id (identifiers and
-- keywords, v is the text), int (v is the digits), str (v is the body between
-- the quotes, still escaped: like patterns read the escapes differently),
-- slot (v is ?name), the punctuators themselves (:: == != <= >= && || ( ) [ ]
-- { } , ; . < > + - * ! : @), and eof (three of them, so a lookahead never
-- leaves the arrays). ln and cl are the line and column (1-based,
-- characters) of each token, off its character offset.
create function permissions._cedar_tokens(p_src text, out k text[], out v text[], out ln int[], out cl int[], out off int[])
language plpgsql
immutable strict
as $$
declare
    m text;
    c text;
    len int;
    nl int;
    line int := 1;
    col int := 1;
    o int := 1;
begin
    k := '{}'; v := '{}'; ln := '{}'; cl := '{}'; off := '{}';
    for m in
        select t[1]
        from regexp_matches(p_src,
            '\s+|//[^\n\r]*|"(?:[^"\\]|\\[^\n])*"|[A-Za-z_][A-Za-z0-9_]*|[0-9]+|\?[A-Za-z_][A-Za-z0-9_]*|::|==|!=|<=|>=|&&|\|\||[\s\S]',
            'g') t
    loop
        c := left(m, 1);
        len := length(m);
        if c ~ '\s' or left(m, 2) = '//' then
            null;
        elsif c = '"' then
            if len = 1 then
                perform permissions._cedar_parse_fail('unterminated string literal', line, col,
                    'Close the string with ". A backslash cannot continue a string on the next line; Cedar strings may contain the line break itself.');
            end if;
            k := k || 'str'::text; v := v || substr(m, 2, len - 2);
        elsif c ~ '[A-Za-z_]' then
            k := k || 'id'::text; v := v || m;
        elsif c ~ '[0-9]' then
            k := k || 'int'::text; v := v || m;
        elsif c = '?' and len > 1 then
            k := k || 'slot'::text; v := v || m;
        elsif m in ('::', '==', '!=', '<=', '>=', '&&', '||', '(', ')', '[', ']', '{', '}', ',', ';', '.', '<', '>', '+', '-', '*', '!', ':', '@') then
            k := k || m; v := v || m;
        else
            perform permissions._cedar_parse_fail(format('invalid character %L', m), line, col,
                case when m in ('=', '&', '|') then format('Cedar has no single %L operator: use %L.', m, m || m)
                     when m = '''' then 'Cedar strings use double quotes: "text".'
                     else 'Outside string literals Cedar uses ASCII letters, digits, _ and its operators. Put other text in a string literal ("...").' end);
        end if;
        if c !~ '\s' and left(m, 2) <> '//' then
            ln := ln || line; cl := cl || col; off := off || o;
        end if;
        nl := len - length(replace(m, E'\n', ''));
        if nl > 0 then
            line := line + nl;
            col := strpos(reverse(m), E'\n');
        else
            col := col + len;
        end if;
        o := o + len;
    end loop;
    k := k || '{eof,eof,eof}'::text[]; v := v || '{"","",""}'::text[];
    ln := ln || array[line, line, line]; cl := cl || array[col, col, col]; off := off || array[o, o, o];
end;
$$;

-- ----------------------------------------------------------------------------
-- String literals
-- ----------------------------------------------------------------------------
-- Cedar reads escapes as Rust does (rustc_lexer): \n \r \t \\ \0 \' \", \xHH
-- up to \x7f, and \u{H...} with 1 to 6 hex digits (underscores allowed, not
-- first), no surrogates, at most 10FFFF. A bare carriage return is an error.
-- U+0000 cannot be held by Postgres text: cedar:unsupported.
--
-- p_pattern false: the decoded text, as a jsonb string.
-- p_pattern true: a like pattern, a jsonb array of "Wildcard" for each * and
-- {"Literal": c} for every other character. \* is a literal star, and a star
-- from any other escape (\u{2a}) is a wildcard, as in Cedar.
create function permissions._cedar_unescape(p_raw text, p_pattern boolean, p_line int, p_col int)
returns jsonb
language plpgsql
immutable
as $$
declare
    m text;
    e text;
    h text;
    cp int;
    ch text;
    s text := '';
    pat jsonb := '[]';
    bad text;
begin
    if strpos(p_raw, '\') = 0 and strpos(p_raw, E'\r') = 0 then
        if not p_pattern then
            return to_jsonb(p_raw);
        end if;
        if p_raw = '' then
            return '[]';
        end if;
        return (select coalesce(jsonb_agg(case when c = '*' then '"Wildcard"'::jsonb else jsonb_build_object('Literal', c) end order by o), '[]')
                from regexp_split_to_table(p_raw, '') with ordinality t(c, o));
    end if;
    for m in
        select t[1] from regexp_matches(p_raw, '[^\\\r]+|\\u\{[0-9A-Fa-f_]*\}|\\x[0-9A-Fa-f]{2}|\\[\s\S]?|\r', 'g') t
    loop
        if left(m, 1) <> '\' and m <> E'\r' then
            if p_pattern then
                pat := pat || (select jsonb_agg(case when c = '*' then '"Wildcard"'::jsonb else jsonb_build_object('Literal', c) end order by o)
                               from regexp_split_to_table(m, '') with ordinality t(c, o));
            else
                s := s || m;
            end if;
            continue;
        end if;
        e := substr(m, 2, 1);
        ch := null;
        bad := null;
        if m = E'\r' then
            bad := 'a bare carriage return';
        elsif e in ('n', 'r', 't', '\', '"', '''') then
            ch := case e when 'n' then E'\n' when 'r' then E'\r' when 't' then E'\t' else e end;
        elsif e = '0' then
            cp := 0;
        elsif e = '*' and p_pattern then
            pat := pat || jsonb_build_array(jsonb_build_object('Literal', '*'));
            continue;
        elsif e = 'x' and length(m) = 4 then
            cp := ('x' || lpad(substr(m, 3), 8, '0'))::bit(32)::int;
            if cp > 127 then
                bad := m;
            end if;
        elsif e = 'u' and length(m) > 3 then
            h := substr(m, 4, length(m) - 4);
            if left(h, 1) = '_' or replace(h, '_', '') = '' or length(replace(h, '_', '')) > 6 then
                bad := m;
            else
                cp := ('x' || lpad(replace(h, '_', ''), 8, '0'))::bit(32)::int;
                if cp > 1114111 or cp between 55296 and 57343 then
                    bad := m;
                end if;
            end if;
        else
            bad := m;
        end if;
        if bad is not null then
            perform permissions._cedar_parse_fail(
                case when left(bad, 1) = '\' then format('invalid escape %s in a string literal', bad)
                     else format('%s in a string literal', bad) end, p_line, p_col,
                case when bad = '\*' then 'Only a like pattern can escape a star (\*). In other strings write * as it is.'
                     when bad = 'a bare carriage return' then 'Write a carriage return in a string as \r.'
                     else 'The escapes are \n, \r, \t, \\, \0, \'', \", \x00 to \x7f, and \u{...} with 1 to 6 hex digits (a Unicode scalar value).' end);
        end if;
        if ch is null then
            if cp = 0 then
                perform permissions._cedar_error('unsupported',
                    format('a string literal at line %s, column %s contains U+0000, which Postgres text cannot hold', p_line, p_col),
                    hint => 'Remove the U+0000 character (\0, \x00 or \u{0}) from the string.',
                    p_detail => 'feature=''U+0000''');
            end if;
            ch := chr(cp);
        end if;
        if p_pattern then
            pat := pat || jsonb_build_array(case when ch = '*' then '"Wildcard"'::jsonb else jsonb_build_object('Literal', ch) end);
        else
            s := s || ch;
        end if;
    end loop;
    if p_pattern then
        return pat;
    end if;
    return to_jsonb(s);
end;
$$;

-- ----------------------------------------------------------------------------
-- Expressions
-- ----------------------------------------------------------------------------
--   Expr     = "if" Expr "then" Expr "else" Expr | Or
--   Or       = And { "||" And }                                   prec 1
--   And      = Relation { "&&" Relation }                         prec 2
--   Relation = Add [ RelOp Add ] | Add "has" (Ident {"." Ident} | Str)
--            | Add "like" Str | Add "is" Path [ "in" Add ]       prec 3, one per operand
--   RelOp    = "<" | "<=" | ">" | ">=" | "==" | "!=" | "in"
--   Add      = Mult { ("+" | "-") Mult }                          prec 4
--   Mult     = Unary { "*" Unary }                                prec 5
--   Unary    = ("!" | "-"){0,4} Member      (one kind of operator per run)
--   Member   = Primary { "." Ident [ "(" [Exprs] ")" ] | "[" Str "]" }
--   Primary  = Int | Str | "true" | "false" | Var | Path "::" Str
--            | Path "(" [Exprs] ")" | "(" Expr ")" | "[" [Exprs] "]"
--            | "{" [ (Ident | Str) ":" Expr {"," ...} ] "}"
-- (lists may end with a comma). One function: the binary operators are
-- reduced with an operator stack (precedence climbing without one call per
-- level), and the function calls itself only for a nested expression, so the
-- PL/pgSQL recursion is about the bracket nesting of the text. minprec 4
-- parses an Add (the right side of "is ... in"). lvl is the bracket nesting.
-- Returns the EST node, the next token, the node's depth and its node count.
create function permissions._cedar_parse_expr(k text[], v text[], ln int[], cl int[], p int, lvl int, minprec int,
                                              out node jsonb, out np int, out dep int, out cnt int)
language plpgsql
immutable
as $$
declare
    q int := p;
    r record;
    nodes jsonb[] := '{}';
    deps int[] := '{}';
    nn int := 0;
    ops text[] := '{}';
    opp int[] := '{}';
    no int := 0;
    relq int := 0;
    x jsonb;
    xd int;
    y jsonb;
    a jsonb;
    ad int;
    op text;
    pr int;
    unop text;
    unn int;
    unq int;
    name text;
    nq int;
    key text;
    ty text;
    seg text;
    lit numeric;
    reserved constant text[] := '{true,false,if,then,else,in,is,like,has,__cedar}';
    vars constant text[] := '{principal,action,resource,context}';
    ext_fns constant text[] := '{decimal,ip,datetime,duration}';
    ext_methods constant text[] := '{lessThan,lessThanOrEqual,greaterThan,greaterThanOrEqual,isIpv4,isIpv6,isLoopback,isMulticast,isInRange,offset,durationSince,toDate,toTime,toDays,toHours,toMinutes,toSeconds,toMilliseconds}';
    bin_methods constant text[] := '{contains,containsAll,containsAny,getTag,hasTag}';
    reserved_hint constant text := 'true, false, if, then, else, in, is, like, has and __cedar are reserved. Use a string instead: e["if"], e has "if", {"if": 1}.';
begin
    cnt := 0;
    if lvl > (permissions._cedar_limits()).policy_depth then
        perform permissions._cedar_error('limit_exceeded',
            format('the expression at line %s, column %s is nested more than %s levels deep', ln[p], cl[p], (permissions._cedar_limits()).policy_depth),
            hint => 'Split the condition into simpler parts, for example several when clauses.',
            p_detail => 'limit=''policy_depth''');
    end if;

    if minprec = 0 and k[q] = 'id' and v[q] = 'if' then
        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
        x := r.node; xd := r.dep; cnt := r.cnt; q := r.np;
        if k[q] <> 'id' or v[q] <> 'then' then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''then''', 'An if expression is: if <condition> then <value> else <value>.');
        end if;
        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
        y := r.node; xd := greatest(xd, r.dep); cnt := cnt + r.cnt; q := r.np;
        if k[q] <> 'id' or v[q] <> 'else' then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''else''', 'An if expression is: if <condition> then <value> else <value>. The else branch is required.');
        end if;
        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
        node := jsonb_build_object('if-then-else', jsonb_build_object('if', x, 'then', y, 'else', r.node));
        dep := 1 + greatest(xd, r.dep); cnt := cnt + r.cnt + 1; np := r.np;
        return;
    end if;

    <<operands>>
    loop
        -- unary operators: a run of one kind, at most 4
        unop := null; unn := 0; unq := q;
        if k[q] in ('!', '-') then
            unop := k[q];
            while k[q] = unop loop
                unn := unn + 1;
                q := q + 1;
            end loop;
            if unn > 4 then
                perform permissions._cedar_parse_fail(format('too many occurrences of ''%s'' (%s)', unop, unn), ln[unq], cl[unq],
                    'Cedar allows at most 4 unary operators in a row. Use parentheses, or remove pairs that cancel.');
            end if;
            if k[q] in ('!', '-') then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an expression',
                    format('Put the operand of ''%s'' in parentheses: %s(%s...).', unop, unop, k[q]));
            end if;
        end if;

        -- primary
        if k[q] = 'int' then
            lit := v[q]::numeric;
            if unop = '-' and k[q + 1] not in ('.', '[') then
                lit := -lit;                    -- a negative literal: Cedar folds the minus
                unn := unn - 1;
            end if;
            if lit > 9223372036854775807 or lit < -9223372036854775808 then
                perform permissions._cedar_parse_fail(format('integer literal %s is too large', v[q]), ln[q], cl[q],
                    'A Cedar Long is from -9223372036854775808 to 9223372036854775807.');
            end if;
            x := jsonb_build_object('Value', lit);
            xd := 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = 'str' then
            x := jsonb_build_object('Value', permissions._cedar_unescape(v[q], false, ln[q], cl[q]));
            xd := 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = '(' then
            r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
            x := r.node; xd := r.dep; cnt := cnt + r.cnt; q := r.np;
            if k[q] <> ')' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''')'' or an operator', null);
            end if;
            q := q + 1;
        elsif k[q] in ('[', '{') then
            op := k[q];
            a := case op when '[' then '[]' else '{}' end::jsonb;
            ad := 0;
            seg := case op when '[' then ']' else '}' end;
            q := q + 1;
            while k[q] <> seg loop
                if op = '{' then
                    if k[q] = 'id' then
                        key := v[q];
                        if key = any (reserved) then
                            perform permissions._cedar_parse_fail(format('this identifier is reserved and cannot be a record key: %s', key), ln[q], cl[q], reserved_hint);
                        end if;
                    elsif k[q] = 'str' then
                        key := permissions._cedar_unescape(v[q], false, ln[q], cl[q]) #>> '{}';
                    else
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'a record key (an identifier or a string literal)', null);
                    end if;
                    if a ? key then
                        perform permissions._cedar_parse_fail(format('duplicate key %L in a record literal', key), ln[q], cl[q],
                            'Each key of a record literal must be different.');
                    end if;
                    if k[q + 1] <> ':' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, ''':''', 'A record literal is {key: value, ...}.');
                    end if;
                    r := permissions._cedar_parse_expr(k, v, ln, cl, q + 2, lvl + 1, 0);
                    a := a || jsonb_build_object(key, r.node);
                else
                    r := permissions._cedar_parse_expr(k, v, ln, cl, q, lvl + 1, 0);
                    a := a || jsonb_build_array(r.node);
                end if;
                ad := greatest(ad, r.dep); cnt := cnt + r.cnt; q := r.np;
                if k[q] = ',' then
                    q := q + 1;
                elsif k[q] <> seg then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q, format(''','' or ''%s''', seg), null);
                end if;
            end loop;
            x := jsonb_build_object(case op when '[' then 'Set' else 'Record' end, a);
            xd := ad + 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = 'slot' then
            perform permissions._cedar_parse_fail(format('found template slot %s in a condition', v[q]), ln[q], cl[q],
                'Slots (?principal, ?resource) can appear only in the policy scope, not in when or unless clauses.');
        elsif k[q] = 'id' and v[q] in ('true', 'false') then
            x := jsonb_build_object('Value', v[q] = 'true');
            xd := 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = 'id' and v[q] in ('if', 'then', 'else', 'in', 'is', 'like', 'has') then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an expression',
                case when v[q] = 'if' then 'Put an if expression in parentheses here: (if c then a else b).' end);
        elsif k[q] = 'id' then
            nq := q;
            name := v[q];
            q := q + 1;
            while k[q] = '::' and k[q + 1] = 'id' loop
                name := name || '::' || v[q + 1];
                q := q + 2;
            end loop;
            if k[q] = '::' or k[q] = '(' or nq + 1 < q then
                foreach seg in array string_to_array(name, '::') loop
                    if seg = any (reserved) then
                        perform permissions._cedar_parse_fail(
                            case when seg = '__cedar' then format('the name %s contains __cedar, which is reserved', name)
                                 else format('this identifier is reserved and cannot be used in a name: %s', seg) end,
                            ln[nq], cl[nq], 'Rename the entity type or namespace.');
                    end if;
                end loop;
            end if;
            if k[q] = '::' and k[q + 1] = 'str' then
                x := jsonb_build_object('Value', jsonb_build_object('__entity',
                        jsonb_build_object('type', name, 'id', permissions._cedar_unescape(v[q + 1], false, ln[q + 1], cl[q + 1]))));
                xd := 1; cnt := cnt + 1; q := q + 2;
            elsif k[q] = '::' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an identifier or a quoted entity id',
                    'An entity is written Type::"id", for example User::"alice".');
            elsif k[q] = '(' then
                if name = any (vars) then
                    perform permissions._cedar_parse_fail(format('%s(...) is not a valid function call', name), ln[nq], cl[nq],
                        'Variables cannot be called as functions.');
                elsif name = any (ext_methods || bin_methods || '{isEmpty}'::text[]) then
                    perform permissions._cedar_parse_fail(format('%s is a method, not a function', name), ln[nq], cl[nq],
                        format('Use a method call: e.%s(...).', name));
                elsif name <> all (ext_fns) then
                    perform permissions._cedar_parse_fail(format('%s is not a valid function', name), ln[nq], cl[nq],
                        permissions._did_you_mean(name, ext_fns, 'The extension functions are'));
                end if;
                a := '[]'; ad := 0;
                q := q + 1;
                while k[q] <> ')' loop
                    r := permissions._cedar_parse_expr(k, v, ln, cl, q, lvl + 1, 0);
                    a := a || jsonb_build_array(r.node);
                    ad := greatest(ad, r.dep); cnt := cnt + r.cnt; q := r.np;
                    if k[q] = ',' then
                        q := q + 1;
                    elsif k[q] <> ')' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''','' or '')''', null);
                    end if;
                end loop;
                x := jsonb_build_object(name, a);
                xd := ad + 1; cnt := cnt + 1; q := q + 1;
            elsif nq + 1 = q and name = any (vars) then
                x := jsonb_build_object('Var', name);
                xd := 1; cnt := cnt + 1;
            else
                perform permissions._cedar_parse_fail(format('invalid variable: %s', name), ln[nq], cl[nq],
                    coalesce(permissions._did_you_mean(name, vars, 'The Cedar variables are') || ' ', '')
                    || format('For a string write "%s"; for an entity write %s::"id".', name, name));
            end if;
        else
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an expression', null);
        end if;

        -- member access and method calls
        loop
            if k[q] = '.' then
                if k[q + 1] <> 'id' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an attribute or method name', null);
                end if;
                name := v[q + 1];
                if name = any (reserved) then
                    perform permissions._cedar_parse_fail(
                        case when name = '__cedar' then 'the name __cedar is reserved'
                             else format('this identifier is reserved and cannot be used: %s', name) end,
                        ln[q + 1], cl[q + 1], reserved_hint);
                end if;
                if k[q + 2] = '(' then
                    nq := q + 1;
                    a := '[]'; ad := 0;
                    q := q + 3;
                    while k[q] <> ')' loop
                        r := permissions._cedar_parse_expr(k, v, ln, cl, q, lvl + 1, 0);
                        a := a || jsonb_build_array(r.node);
                        ad := greatest(ad, r.dep); cnt := cnt + r.cnt; q := r.np;
                        if k[q] = ',' then
                            q := q + 1;
                        elsif k[q] <> ')' then
                            perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''','' or '')''', null);
                        end if;
                    end loop;
                    q := q + 1;
                    if name = any (bin_methods) or name = 'isEmpty' then
                        if jsonb_array_length(a) <> (case when name = 'isEmpty' then 0 else 1 end) then
                            perform permissions._cedar_parse_fail(
                                format('call to %s requires exactly %s, but got %s', name,
                                       case when name = 'isEmpty' then '0 arguments' else '1 argument' end,
                                       jsonb_array_length(a) || case when jsonb_array_length(a) = 1 then ' argument' else ' arguments' end),
                                ln[nq], cl[nq],
                                case when name = 'isEmpty' then 'Write s.isEmpty().' else format('Write e.%s(x) with one argument.', name) end);
                        end if;
                        x := case when name = 'isEmpty' then jsonb_build_object(name, jsonb_build_object('arg', x))
                                  else jsonb_build_object(name, jsonb_build_object('left', x, 'right', a -> 0)) end;
                    elsif name = any (ext_methods) then
                        x := jsonb_build_object(name, jsonb_build_array(x) || a);
                    elsif name = any (ext_fns) then
                        perform permissions._cedar_parse_fail(format('%s is a function, not a method', name), ln[nq], cl[nq],
                            format('Use a function call: %s(...).', name));
                    else
                        perform permissions._cedar_parse_fail(format('%s is not a valid method', name), ln[nq], cl[nq],
                            permissions._did_you_mean(name, bin_methods || ext_methods || '{isEmpty}'::text[], 'The methods are'));
                    end if;
                    xd := 1 + greatest(xd, ad); cnt := cnt + 1;
                else
                    x := jsonb_build_object('.', jsonb_build_object('left', x, 'attr', name));
                    xd := xd + 1; cnt := cnt + 1; q := q + 2;
                end if;
            elsif k[q] = '[' then
                if k[q + 1] <> 'str' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'a string literal',
                        'Only an attribute name in a string literal can follow [ : e["name"].');
                end if;
                if k[q + 2] <> ']' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 2, ''']''', null);
                end if;
                x := jsonb_build_object('.', jsonb_build_object('left', x, 'attr', permissions._cedar_unescape(v[q + 1], false, ln[q + 1], cl[q + 1])));
                xd := xd + 1; cnt := cnt + 1; q := q + 3;
            elsif k[q] = '(' then
                perform permissions._cedar_parse_fail('function calls must be of the form name(arg1, arg2, ...)', ln[q], cl[q],
                    'Only extension functions (decimal, ip, datetime, duration) and methods (e.name(...)) can be called.');
            else
                exit;
            end if;
        end loop;

        for i in 1..unn loop
            x := jsonb_build_object(case unop when '!' then '!' else 'neg' end, jsonb_build_object('arg', x));
            xd := xd + 1; cnt := cnt + 1;
        end loop;
        nn := nn + 1; nodes[nn] := x; deps[nn] := xd;

        -- binary operators, and the has / like / is relations
        <<binops>>
        loop
            op := null; pr := null;
            if k[q] = '||' then op := '||'; pr := 1;
            elsif k[q] = '&&' then op := '&&'; pr := 2;
            elsif k[q] in ('<', '<=', '>', '>=', '==', '!=') then op := k[q]; pr := 3;
            elsif k[q] = 'id' and v[q] in ('in', 'has', 'like', 'is') then op := v[q]; pr := 3;
            elsif k[q] in ('+', '-') then op := k[q]; pr := 4;
            elsif k[q] = '*' then op := '*'; pr := 5;
            end if;
            if pr is null or pr < minprec then
                exit operands;
            end if;
            while no > 0 and (opp[no] > pr or (opp[no] = pr and pr <> 3)) loop
                nodes[nn - 1] := jsonb_build_object(ops[no], jsonb_build_object('left', nodes[nn - 1], 'right', nodes[nn]));
                deps[nn - 1] := 1 + greatest(deps[nn - 1], deps[nn]);
                nn := nn - 1; no := no - 1; cnt := cnt + 1;
            end loop;
            if pr = 3 then
                if relq > 0 then
                    perform permissions._cedar_parse_fail(
                        format('multiple relational operators (%s at line %s, column %s, then %s)', v[relq], ln[relq], cl[relq], v[q]),
                        ln[q], cl[q], 'Use parentheses to make the order explicit, for example (a == b) == c.');
                end if;
                relq := q;
            elsif pr < 3 then
                relq := 0;
            end if;
            if op in ('has', 'like', 'is') then
                x := nodes[nn]; xd := deps[nn];
                nq := q;
                q := q + 1;
                if op = 'has' then
                    if k[q] = 'str' then
                        x := jsonb_build_object('has', jsonb_build_object('left', x, 'attr', permissions._cedar_unescape(v[q], false, ln[q], cl[q])));
                        q := q + 1;
                    elsif k[q] = 'id' then
                        a := '[]';
                        loop
                            if v[q] = any (reserved) then
                                perform permissions._cedar_parse_fail(
                                    case when v[q] = '__cedar' then 'the name __cedar is reserved'
                                         else format('this identifier is reserved and cannot be used: %s', v[q]) end,
                                    ln[q], cl[q], reserved_hint);
                            end if;
                            a := a || to_jsonb(v[q]);
                            q := q + 1;
                            exit when k[q] <> '.' or k[q + 1] <> 'id';
                            q := q + 1;
                        end loop;
                        x := jsonb_build_object('has', jsonb_build_object('left', x,
                                'attr', case when jsonb_array_length(a) = 1 then a -> 0 else a end));
                    else
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an attribute name (identifiers separated by ''.'', or a string literal)', null);
                    end if;
                elsif op = 'like' then
                    if k[q] <> 'str' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'a pattern string literal',
                            'The right side of like is a string literal, where * matches any text and \* is a literal star.');
                    end if;
                    x := jsonb_build_object('like', jsonb_build_object('left', x, 'pattern', permissions._cedar_unescape(v[q], true, ln[q], cl[q])));
                    q := q + 1;
                else
                    if k[q] <> 'id' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an entity type name',
                            case when k[q] = 'str' then format('Remove the quotes: is %s.', v[q]) end);
                    end if;
                    ty := v[q];
                    nq := q;
                    q := q + 1;
                    while k[q] = '::' and k[q + 1] = 'id' loop
                        ty := ty || '::' || v[q + 1];
                        q := q + 2;
                    end loop;
                    foreach seg in array string_to_array(ty, '::') loop
                        if seg = any (reserved) then
                            perform permissions._cedar_parse_fail(format('this identifier is reserved and cannot be used in a type name: %s', seg),
                                ln[nq], cl[nq], 'Rename the entity type or namespace.');
                        end if;
                    end loop;
                    if k[q] = '::' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''in'', an operator or the end of the expression',
                            'The right side of is is an entity type, such as User or App::User, not an entity.');
                    end if;
                    if k[q] = 'id' and v[q] = 'in' then
                        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 4);
                        x := jsonb_build_object('is', jsonb_build_object('left', x, 'entity_type', ty, 'in', r.node));
                        xd := greatest(xd, r.dep); cnt := cnt + r.cnt; q := r.np;
                    else
                        x := jsonb_build_object('is', jsonb_build_object('left', x, 'entity_type', ty));
                    end if;
                end if;
                if k[q] in ('+', '-', '*', '.', '[', '(', '::') then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''&&'', ''||'' or the end of the expression',
                        format('The right side of %s must stand alone. Use parentheses around the whole %s expression.', op, op));
                end if;
                nodes[nn] := x; deps[nn] := xd + 1; cnt := cnt + 1;
                continue binops;
            end if;
            no := no + 1; ops[no] := op; opp[no] := pr;
            q := q + 1;
            exit binops;
        end loop;
    end loop;

    while no > 0 loop
        nodes[nn - 1] := jsonb_build_object(ops[no], jsonb_build_object('left', nodes[nn - 1], 'right', nodes[nn]));
        deps[nn - 1] := 1 + greatest(deps[nn - 1], deps[nn]);
        nn := nn - 1; no := no - 1; cnt := cnt + 1;
    end loop;
    node := nodes[1]; dep := deps[1]; np := q;
end;
$$;

-- ----------------------------------------------------------------------------
-- Policies
-- ----------------------------------------------------------------------------
-- An entity in the scope: Path "::" Str. Returns {"type", "id"} and the next
-- token. p_var names the scope variable for the messages.
create function permissions._cedar_parse_ref(k text[], v text[], ln int[], cl int[], p int, p_var text,
                                             out ent jsonb, out np int)
language plpgsql
immutable
as $$
declare
    q int := p;
    name text;
    seg text;
begin
    if k[q] = 'str' then
        perform permissions._cedar_parse_fail(format('expected an entity uid for %s, found a string literal', p_var), ln[q], cl[q],
            format('Include the entity type: %s::"%s".', case p_var when 'action' then 'Action' else 'User' end, v[q]));
    elsif k[q] = '[' then
        perform permissions._cedar_parse_fail(format('expected a single entity uid for %s, found a set', p_var), ln[q], cl[q],
            'Only the action scope takes a list, with in: action in [Action::"a", Action::"b"].');
    elsif k[q] <> 'id' then
        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an entity uid (Type::"id")', null);
    end if;
    name := v[q];
    q := q + 1;
    while k[q] = '::' and k[q + 1] = 'id' loop
        name := name || '::' || v[q + 1];
        q := q + 2;
    end loop;
    if k[q] <> '::' or k[q + 1] <> 'str' then
        perform permissions._cedar_syntax_error(k, v, ln, cl, case when k[q] = '::' then q + 1 else q end,
            format('''::'' and a quoted entity id after %s', name),
            format('An entity is written Type::"id", for example %s::"alice".', name));
    end if;
    foreach seg in array string_to_array(name, '::') loop
        if seg in ('true', 'false', 'if', 'then', 'else', 'in', 'is', 'like', 'has', '__cedar') then
            perform permissions._cedar_parse_fail(format('this identifier is reserved and cannot be used in a type name: %s', seg),
                ln[p], cl[p], 'Rename the entity type or namespace.');
        end if;
    end loop;
    ent := jsonb_build_object('type', name, 'id', permissions._cedar_unescape(v[q + 1], false, ln[q + 1], cl[q + 1]));
    if p_var = 'action' and name <> 'Action' and name not like '%::Action' then
        perform permissions._cedar_parse_fail(format('expected an entity uid with type Action but got %s::"%s"', name, ent ->> 'id'),
            ln[p], cl[p], 'Action entities have the type Action, optionally in a namespace (App::Action).');
    end if;
    np := q + 2;
end;
$$;

-- The policies of a text. p_single: exactly one, returned as its EST; else
-- the policy-set object (see the top of this file).
create function permissions._cedar_parse_text(p_src text, p_single boolean)
returns jsonb
language plpgsql
immutable
as $$
declare
    t record;
    r record;
    k text[];
    v text[];
    ln int[];
    cl int[];
    off int[];
    q int := 1;
    n int := 0;
    start int;
    annos jsonb;
    pid text;
    eff text;
    scope jsonb;
    conds jsonb;
    est jsonb;
    is_template boolean;
    statics jsonb := '{}';
    templates jsonb := '{}';
    nodes int;
    sv text;
    ent jsonb;
    ents jsonb;
    ty text;
    nq int;
    kind text;
    scope_hint constant text := 'A policy scope lists principal, action and resource, in that order: permit (principal, action, resource);';
    lim record := permissions._cedar_limits();
begin
    if p_single and octet_length(p_src) > lim.policy_bytes then
        perform permissions._cedar_error('limit_exceeded',
            format('the policy text is %s bytes, more than the limit of %s', octet_length(p_src), lim.policy_bytes),
            hint => 'Split the policy into several smaller policies.',
            p_detail => 'limit=''policy_bytes''');
    end if;
    t := permissions._cedar_tokens(p_src);
    k := t.k; v := t.v; ln := t.ln; cl := t.cl; off := t.off;

    while k[q] <> 'eof' loop
        start := q;
        annos := '{}';
        pid := null;
        nodes := 0;

        -- annotations
        while k[q] = '@' loop
            if k[q + 1] <> 'id' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an annotation name', 'An annotation is @name("value") or @name.');
            end if;
            if annos ? v[q + 1] then
                perform permissions._cedar_parse_fail(format('duplicate annotation @%s', v[q + 1]), ln[q], cl[q],
                    'Each annotation name may appear once in a policy.');
            end if;
            if k[q + 2] = '(' then
                if k[q + 3] <> 'str' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 3, 'a string literal', 'An annotation is @name("value") or @name.');
                end if;
                if k[q + 4] <> ')' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 4, ''')''', 'An annotation is @name("value") or @name.');
                end if;
                annos := annos || jsonb_build_object(v[q + 1], permissions._cedar_unescape(v[q + 3], false, ln[q + 3], cl[q + 3]));
                q := q + 5;
            else
                annos := annos || jsonb_build_object(v[q + 1], null);
                q := q + 2;
            end if;
        end loop;
        if annos ? 'id' then
            pid := coalesce(annos ->> 'id', '');
        end if;

        -- effect
        if k[q] <> 'id' or v[q] not in ('permit', 'forbid') then
            if k[q] = 'id' then
                perform permissions._cedar_parse_fail(format('invalid policy effect: %s', v[q]), ln[q], cl[q],
                    permissions._did_you_mean(v[q], '{permit,forbid}', 'A policy starts with'));
            end if;
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''permit'' or ''forbid''',
                'A policy is: [@annotations] permit|forbid (principal, action, resource) [when { ... }] [unless { ... }];');
        end if;
        eff := v[q];
        q := q + 1;
        if k[q] <> '(' then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''(''', scope_hint);
        end if;
        q := q + 1;

        -- scope: principal, action, resource
        scope := '{}';
        is_template := false;
        foreach sv in array array['principal', 'action', 'resource'] loop
            if k[q] <> 'id' or v[q] <> sv then
                if k[q] = 'id' and v[q] in ('principal', 'action', 'resource', 'context') then
                    perform permissions._cedar_parse_fail(format('found the variable %s where the variable %s must be', v[q], sv), ln[q], cl[q], scope_hint);
                elsif k[q] = 'id' then
                    perform permissions._cedar_parse_fail(format('found %s where the variable %s must be', v[q], sv), ln[q], cl[q],
                        coalesce(permissions._did_you_mean(v[q], array[sv], 'The scope variable here is') || ' ', '') || scope_hint);
                elsif k[q] = ')' then
                    perform permissions._cedar_parse_fail(format('this policy is missing the %s variable in the scope', sv), ln[q], cl[q], scope_hint);
                end if;
                perform permissions._cedar_syntax_error(k, v, ln, cl, q, format('''%s''', sv), scope_hint);
            end if;
            nq := q;
            q := q + 1;
            if k[q] = ':' then
                perform permissions._cedar_parse_fail('type constraints using : are not supported', ln[q], cl[q],
                    format('Use is instead: %s is User.', sv));
            end if;
            if sv = 'action' then
                if k[q] = '==' then
                    if k[q + 1] = 'slot' then
                        perform permissions._cedar_parse_fail('the action scope cannot hold a slot', ln[q + 1], cl[q + 1],
                            'Templates have slots for the principal and the resource only.');
                    end if;
                    r := permissions._cedar_parse_ref(k, v, ln, cl, q + 1, sv);
                    scope := scope || jsonb_build_object('action', jsonb_build_object('op', '==', 'entity', r.ent));
                    q := r.np;
                elsif k[q] = 'id' and v[q] = 'in' then
                    if k[q + 1] = '[' then
                        ents := '[]';
                        q := q + 2;
                        while k[q] <> ']' loop
                            r := permissions._cedar_parse_ref(k, v, ln, cl, q, sv);
                            ents := ents || jsonb_build_array(r.ent);
                            q := r.np;
                            if k[q] = ',' then
                                q := q + 1;
                            elsif k[q] <> ']' then
                                perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''','' or '']''', null);
                            end if;
                        end loop;
                        q := q + 1;
                        scope := scope || jsonb_build_object('action',
                            case when jsonb_array_length(ents) = 1 then jsonb_build_object('op', 'in', 'entity', ents -> 0)
                                 else jsonb_build_object('op', 'in', 'entities', ents) end);
                    else
                        if k[q + 1] = 'slot' then
                            perform permissions._cedar_parse_fail('the action scope cannot hold a slot', ln[q + 1], cl[q + 1],
                                'Templates have slots for the principal and the resource only.');
                        end if;
                        r := permissions._cedar_parse_ref(k, v, ln, cl, q + 1, sv);
                        scope := scope || jsonb_build_object('action', jsonb_build_object('op', 'in', 'entity', r.ent));
                        q := r.np;
                    end if;
                elsif k[q] = 'id' and v[q] = 'is' then
                    perform permissions._cedar_parse_fail('is cannot appear in the action scope', ln[q], cl[q],
                        'Move action is ... into a when condition.');
                else
                    scope := scope || '{"action": {"op": "All"}}';
                end if;
            else
                kind := null;
                if k[q] = 'id' and v[q] = 'is' then
                    if k[q + 1] <> 'id' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an entity type name',
                            case when k[q + 1] = 'str' then format('Remove the quotes: is %s.', v[q + 1]) end);
                    end if;
                    ty := v[q + 1];
                    q := q + 2;
                    while k[q] = '::' and k[q + 1] = 'id' loop
                        ty := ty || '::' || v[q + 1];
                        q := q + 2;
                    end loop;
                    if ty ~ '(^|::)(true|false|if|then|else|in|is|like|has|__cedar)(::|$)' then
                        perform permissions._cedar_parse_fail(format('the type name %s uses a reserved identifier', ty), ln[nq], cl[nq],
                            'true, false, if, then, else, in, is, like, has and __cedar are reserved.');
                    end if;
                    if k[q] = '::' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, format('''in'', '','' or '')'' after the type %s', ty),
                            format('is takes an entity type; to name one entity use ==: %s == %s::"id".', sv, ty));
                    end if;
                    if k[q] = 'id' and v[q] = 'in' then
                        kind := 'is_in';
                        q := q + 1;
                    else
                        scope := scope || jsonb_build_object(sv, jsonb_build_object('op', 'is', 'entity_type', ty));
                    end if;
                elsif k[q] = '==' then
                    kind := '==';
                    q := q + 1;
                elsif k[q] = 'id' and v[q] = 'in' then
                    kind := 'in';
                    q := q + 1;
                else
                    scope := scope || jsonb_build_object(sv, '{"op": "All"}'::jsonb);
                end if;
                if kind is not null then
                    if k[q] = 'slot' then
                        if v[q] <> '?' || sv then
                            perform permissions._cedar_parse_fail(format('expected an entity uid or the slot ?%s, found %s', sv, v[q]), ln[q], cl[q],
                                format('The %s scope can hold only the slot ?%s.', sv, sv));
                        end if;
                        ent := jsonb_build_object('slot', v[q]);
                        is_template := true;
                        q := q + 1;
                    else
                        r := permissions._cedar_parse_ref(k, v, ln, cl, q, sv);
                        ent := jsonb_build_object('entity', r.ent);
                        q := r.np;
                    end if;
                    scope := scope || jsonb_build_object(sv,
                        case kind when 'is_in' then jsonb_build_object('op', 'is', 'entity_type', ty, 'in', ent)
                                  else jsonb_build_object('op', kind) || ent end);
                end if;
            end if;
            if sv <> 'resource' then
                if k[q] <> ',' then
                    if k[q] = ')' then
                        perform permissions._cedar_parse_fail(format('this policy is missing the %s variable in the scope',
                            case sv when 'principal' then 'action' else 'resource' end), ln[q], cl[q], scope_hint);
                    end if;
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''',''', scope_hint);
                end if;
                q := q + 1;
            end if;
        end loop;
        if k[q] = ',' and k[q + 1] = ')' then
            q := q + 1;
        end if;
        if k[q] <> ')' then
            if k[q] = ',' and k[q + 1] = 'id' then
                perform permissions._cedar_parse_fail(format('this policy has an extra element in the scope: %s', v[q + 1]), ln[q + 1], cl[q + 1],
                    scope_hint || ' Conditions go in when or unless clauses after the scope.');
            end if;
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''')''', scope_hint);
        end if;
        q := q + 1;

        -- conditions
        conds := '[]';
        while k[q] = 'id' and v[q] in ('when', 'unless') loop
            if k[q + 1] <> '{' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, '''{''', format('A condition is %s { <expression> }.', v[q]));
            end if;
            if k[q + 2] = '}' then
                perform permissions._cedar_parse_fail(format('the %s condition clause is empty', v[q]), ln[q], cl[q],
                    format('Write an expression between the braces, or remove the %s clause.', v[q]));
            end if;
            r := permissions._cedar_parse_expr(k, v, ln, cl, q + 2, 1, 0);
            if k[r.np] <> '}' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, r.np, 'an operator or ''}''', null);
            end if;
            if r.dep > lim.policy_depth then
                perform permissions._cedar_error('limit_exceeded',
                    format('the %s condition at line %s, column %s is %s levels deep, more than the limit of %s', v[q], ln[q], cl[q], r.dep, lim.policy_depth),
                    hint => 'Split the condition into simpler parts, for example several when clauses.',
                    p_detail => 'limit=''policy_depth''');
            end if;
            nodes := nodes + r.cnt;
            conds := conds || jsonb_build_array(jsonb_build_object('kind', v[q], 'body', r.node));
            q := r.np + 1;
        end loop;
        if k[q] <> ';' then
            if k[q] = 'id' then
                perform permissions._cedar_parse_fail(format('invalid policy condition: %s', v[q]), ln[q], cl[q],
                    coalesce(permissions._did_you_mean(v[q], '{when,unless}', 'A condition starts with'), '')
                    || case when v[q] in ('permit', 'forbid') then ' Or end the previous policy with '';''.' else '' end);
            end if;
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''when'', ''unless'' or '';''',
                case when k[q] in ('eof', '@') then 'End each policy with '';''.' end);
        end if;
        if nodes > lim.policy_nodes then
            perform permissions._cedar_error('limit_exceeded',
                format('the policy at line %s, column %s has %s expression nodes, more than the limit of %s', ln[start], cl[start], nodes, lim.policy_nodes),
                hint => 'Split the policy into several smaller policies.',
                p_detail => 'limit=''policy_nodes''');
        end if;
        if not p_single and octet_length(substr(p_src, off[start], off[q] + 1 - off[start])) > lim.policy_bytes then
            perform permissions._cedar_error('limit_exceeded',
                format('the policy at line %s, column %s is more than %s bytes long', ln[start], cl[start], lim.policy_bytes),
                hint => 'Split the policy into several smaller policies.',
                p_detail => 'limit=''policy_bytes''');
        end if;
        q := q + 1;

        est := jsonb_build_object('effect', eff) || scope || jsonb_build_object('conditions', conds);
        if annos <> '{}' then
            est := est || jsonb_build_object('annotations', annos);
        end if;
        if p_single then
            if k[q] <> 'eof' then
                perform permissions._cedar_parse_fail(
                    case when k[q] = '@' or (k[q] = 'id' and v[q] in ('permit', 'forbid'))
                         then 'expected exactly one policy, found a second policy'
                         else 'expected exactly one policy, found more text after the first' end, ln[q], cl[q],
                    'A call puts one policy or template: put each one with its own call and id, for example select permissions.cedar_put_policy(policy_id => ''second'', policy => ''forbid (principal, action, resource);'').');
            end if;
            return est;
        end if;
        pid := coalesce(pid, 'policy' || n);
        if statics ? pid or templates ? pid then
            perform permissions._cedar_parse_fail(format('duplicate template or policy id %L', pid), ln[start], cl[start],
                'Policy ids come from @id("...") or are policy0, policy1, ... by position. Give each policy a different @id.');
        end if;
        if is_template then
            templates := templates || jsonb_build_object(pid, est);
        else
            statics := statics || jsonb_build_object(pid, est);
        end if;
        n := n + 1;
    end loop;
    if p_single then
        perform permissions._cedar_parse_fail('expected a policy, found no policy', ln[q], cl[q],
            'Write one policy, for example: permit (principal, action, resource);');
    end if;
    return jsonb_build_object('staticPolicies', statics, 'templates', templates, 'templateLinks', '[]'::jsonb);
end;
$$;

-- Exactly one policy or template: its EST.
create function permissions._cedar_parse_policy(src text)
returns jsonb
language sql
immutable strict
as $$
    select permissions._cedar_parse_text(src, true)
$$;

-- A policy set: {"staticPolicies", "templates", "templateLinks": []}.
create function permissions._cedar_parse_policies(src text)
returns jsonb
language sql
immutable strict
as $$
    select permissions._cedar_parse_text(src, false)
$$;

-- ----------------------------------------------------------------------------
-- Evaluator
-- ----------------------------------------------------------------------------
-- The environment of one request (built once by _cedar_env):
--
--   principal, action, resource   the entities, internal form
--   context                       a record, internal form
--   anc   {key: [ancestor keys]}  the ancestors of principal, action and resource
--   ent   {key: {"attrs", "tags"} or null}  entity data looked up already: the
--         three request entities (null: not stored) and every overlay entity
--   ov    {key: {"attrs", "tags", "parents": [[type, id], ...]}}  the
--         `entities` overlay of the request; absent without one
--
-- An overlay entity replaces the stored entity with the same uid (attrs,
-- tags and parents).

-- Every ancestor of an entity (not the entity itself), as a jsonb array of
-- keys. Without an overlay, a recursive walk over the direct parents (UNION
-- ends it on a cycle: cedar_put_entities rejects cycles, but two concurrent
-- puts could still make one). With an overlay, breadth first: each entity's
-- parents come from the overlay if it has the entity, else from storage.
-- A generic plan: the walk's plan does not depend on the uid, and planning
-- it per call would cost more than running it.
create function permissions._cedar_ancestors(p_type text, p_id text, p_ov jsonb)
returns jsonb
language plpgsql stable
set plan_cache_mode = force_generic_plan
as $$
declare
    r jsonb;
    seen jsonb := '{}';
    ts text[] := array[p_type];
    ids text[] := array[p_id];
    nt text[];
    ni text[];
    k text;
    e jsonb;
    i int;
begin
    if p_ov is null then
        with recursive a(t, i) as (
            select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
            where p.type = p_type and p.id = p_id
            union
            -- offset 0 keeps the lateral subquery, so each step is an index
            -- probe (a join would hash the whole table: the planner guesses
            -- 10 rows per step)
            select q.parent_type, q.parent_id from a cross join lateral (
                select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
                where p.type = a.t and p.id = a.i offset 0) q
        )
        select jsonb_agg(permissions._cedar_key(a.t, a.i)) into r from a;
        return coalesce(r, '[]');
    end if;
    while cardinality(ts) > 0 loop
        nt := '{}';
        ni := '{}';
        for i in 1 .. cardinality(ts) loop
            k := permissions._cedar_key(ts[i], ids[i]);
            if p_ov ? k then
                for e in select x from jsonb_array_elements(p_ov -> k -> 'parents') x loop
                    nt := nt || (e ->> 0);
                    ni := ni || (e ->> 1);
                end loop;
            else
                select nt || array_agg(p.parent_type), ni || array_agg(p.parent_id) into nt, ni
                from permissions.cedar_entity_parents p
                where p.type = ts[i] and p.id = ids[i];
            end if;
        end loop;
        ts := '{}';
        ids := '{}';
        for i in 1 .. cardinality(nt) loop
            k := permissions._cedar_key(nt[i], ni[i]);
            if not seen ? k then
                seen := seen || jsonb_build_object(k, true);
                ts := ts || nt[i];
                ids := ids || ni[i];
            end if;
        end loop;
    end loop;
    return coalesce((select jsonb_agg(x) from jsonb_object_keys(seen) x), '[]');
end;
$$;

-- The data of an entity value ({"attrs", "tags"}), or null if it does not
-- exist: from env.ent, else stored.
create function permissions._cedar_entity(env jsonb, v jsonb)
returns jsonb
language plpgsql stable
as $$
declare
    k text := permissions._cedar_key(v -> '__entity' ->> 'type', v -> '__entity' ->> 'id');
    r jsonb := env -> 'ent' -> k;
begin
    if r is not null then
        return nullif(r, 'null');
    end if;
    if env -> 'ov' ? k then
        return env -> 'ov' -> k;
    end if;
    select jsonb_build_object('attrs', e.attrs, 'tags', e.tags) into r
    from permissions.cedar_entities e
    where e.type = v -> '__entity' ->> 'type' and e.id = v -> '__entity' ->> 'id';
    return r;
end;
$$;

-- x in y, for x an entity: y is an entity or a set of entities (else a type
-- error, also for any element of the set that is not an entity). True if x
-- is y or y is an ancestor of x. Null is an error.
create function permissions._cedar_in(x jsonb, y jsonb, env jsonb, why boolean)
returns jsonb
language plpgsql stable
as $$
declare
    k text;
    anc jsonb;
begin
    if jsonb_typeof(y) = 'object' and y ? '__entity' then
        if x = y then
            return 'true';
        end if;
    elsif jsonb_typeof(y) = 'array' then
        if exists (select 1 from jsonb_array_elements(y) e where not (jsonb_typeof(e) = 'object' and e ? '__entity')) then
            return permissions._cedar_eval_fail(why, format('type_error: in: the set %s holds a value that is not an entity',
                                                             left(y::text, 200)));
        end if;
        if jsonb_array_length(y) = 0 then
            return 'false';
        end if;
        if exists (select 1 from jsonb_array_elements(y) e where e = x) then
            return 'true';
        end if;
    else
        return permissions._cedar_eval_fail(why, format('type_error: in: expected an entity or a set of entities on the right, got %s',
                                                         permissions._cedar_type_of(y)));
    end if;
    k := permissions._cedar_key(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id');
    anc := coalesce(env -> 'anc' -> k,
                    permissions._cedar_ancestors(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id', env -> 'ov'));
    if jsonb_typeof(y) = 'object' then
        return to_jsonb(anc ? permissions._cedar_key(y -> '__entity' ->> 'type', y -> '__entity' ->> 'id'));
    end if;
    return to_jsonb(exists (select 1 from jsonb_array_elements(y) e
                            where anc ? permissions._cedar_key(e -> '__entity' ->> 'type', e -> '__entity' ->> 'id')));
end;
$$;

-- An extension function or method applied to its evaluated arguments (the
-- receiver first): the value, or null for an error (Cedar's
-- extension_error, wrong number of arguments, or type_error). The
-- arguments are already evaluated, left to right, as Cedar does before it
-- checks the arity and the types.
create function permissions._cedar_call(f text, a jsonb[], why boolean)
returns jsonb
language plpgsql immutable
as $$
declare
    n int := coalesce(cardinality(a), 0);
    want int := case when f in ('decimal', 'ip', 'datetime', 'duration', 'isIpv4', 'isIpv6', 'isLoopback', 'isMulticast',
                                'toDate', 'toTime', 'toMilliseconds', 'toSeconds', 'toMinutes', 'toHours', 'toDays') then 1 else 2 end;
    t text := permissions._cedar_extensions() ->> f;
    x numeric;
    y numeric;
    r numeric;
    ip inet;
    i int;
begin
    if n <> want then
        return permissions._cedar_eval_fail(why, format('extension_error: wrong number of arguments to %s (a method counts its receiver): expected %s, got %s',
                                                         f, want, n));
    end if;
    if f = t or f = 'ip' then
        -- a constructor
        if jsonb_typeof(a[1]) <> 'string' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected String, got %s', f, permissions._cedar_type_of(a[1])));
        end if;
        return coalesce(permissions._cedar_extn(f, a[1] #>> '{}'),
                        permissions._cedar_eval_fail(why, format('extension_error: %s(%s) is not valid: %s', f, a[1], permissions._cedar_extn_help(f))));
    end if;
    -- a method: every argument has the receiver's type, except offset's
    -- duration
    for i in 1 .. n loop
        if (a[i] -> '__extn' ->> 'fn') is distinct from (case when i > 1 and f = 'offset' then 'duration' when t = 'ipaddr' then 'ip' else t end) then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected %s, got %s', f,
                case when i > 1 and f = 'offset' then 'duration' else t end, permissions._cedar_type_of(a[i])));
        end if;
    end loop;
    if t = 'ipaddr' then
        ip := (a[1] #>> '{__extn,v}')::inet;
        return to_jsonb(case f
            when 'isIpv4' then family(ip) = 4
            when 'isIpv6' then family(ip) = 6
            -- the address in 127.0.0.0/8 or ::1, and a prefix at least as long
            when 'isLoopback' then ip <<= '127.0.0.0/8'::inet or ip <<= '::1/128'::inet
            when 'isMulticast' then ip <<= '224.0.0.0/4'::inet or ip <<= 'ff00::/8'::inet
            -- isInRange: the range holds the receiver's whole range (false
            -- across families)
            else ip <<= (a[2] #>> '{__extn,v}')::inet end);
    end if;
    x := (a[1] #>> '{__extn,v}')::numeric;
    y := (a[2] #>> '{__extn,v}')::numeric;
    if f in ('lessThan', 'lessThanOrEqual', 'greaterThan', 'greaterThanOrEqual') then
        return to_jsonb(case f when 'lessThan' then x < y when 'lessThanOrEqual' then x <= y
                               when 'greaterThan' then x > y else x >= y end);
    elsif f in ('toMilliseconds', 'toSeconds', 'toMinutes', 'toHours', 'toDays') then
        -- truncated toward zero, as Rust's integer division
        return to_jsonb(div(x, case f when 'toMilliseconds' then 1 when 'toSeconds' then 1000 when 'toMinutes' then 60000
                                      when 'toHours' then 3600000 else 86400000 end));
    end if;
    -- toTime: the time of day, x mod a day (the Euclidean remainder: a
    -- datetime before 1970 has a time of day >= 0); toDate: x minus it
    r := mod(x, 86400000);
    if r < 0 then
        r := r + 86400000;
    end if;
    if f = 'toTime' then
        return jsonb_build_object('__extn', jsonb_build_object('fn', 'duration', 'v', r));
    end if;
    r := case f when 'offset' then x + y when 'durationSince' then x - y else x - r end;
    if r not between -9223372036854775808 and 9223372036854775807 then
        return permissions._cedar_eval_fail(why, format('extension_error: %s overflows the 64-bit range of milliseconds', f));
    end if;
    return jsonb_build_object('__extn', jsonb_build_object('fn', case f when 'durationSince' then 'duration' else 'datetime' end, 'v', r));
end;
$$;

-- One node of an ast over an environment: the value, or SQL null for an
-- evaluation error (with why, the error raises instead: _cedar_eval_fail).
-- Cedar's rules (e-cedar.md section 4.2): && and || evaluate the left side
-- first and the right side only when the left does not decide, and both
-- sides must be Bool; if-then-else evaluates only the chosen branch; every
-- other operator evaluates its operands left to right, and the first error
-- is the result. == never errs: values of different types are not equal.
create function permissions._cedar_eval(n jsonb, env jsonb, why boolean)
returns jsonb
language plpgsql stable
as $$
declare
    k text := n ->> 'k';
    x jsonb;
    y jsonb;
    r numeric;
    d jsonb;
    f text;
    vals jsonb[];
    kv record;
begin
    if k = 'lit' then
        return n -> 'v';
    elsif k = 'var' then
        return env -> (n ->> 'n');
    elsif k = 'and' or k = 'or' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'boolean' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected Bool on the left, got %s',
                                                             case k when 'and' then '&&' else '||' end, permissions._cedar_type_of(x)));
        elsif (x = 'true') = (k = 'or') then
            return x;
        end if;
        y := permissions._cedar_eval(n -> 'b', env, why);
        if y is null then
            return null;
        elsif jsonb_typeof(y) <> 'boolean' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected Bool on the right, got %s',
                                                             case k when 'and' then '&&' else '||' end, permissions._cedar_type_of(y)));
        end if;
        return y;
    elsif k = 'if' then
        x := permissions._cedar_eval(n -> 'c', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'boolean' then
            return permissions._cedar_eval_fail(why, format('type_error: if: expected a Bool condition, got %s', permissions._cedar_type_of(x)));
        end if;
        return permissions._cedar_eval(n -> case when x = 'true' then 't' else 'e' end, env, why);
    elsif k = 'get' or k = 'has' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        end if;
        f := n ->> 'f';
        if jsonb_typeof(x) = 'object' and x ? '__entity' then
            d := permissions._cedar_entity(env, x);
            if k = 'has' then
                return to_jsonb(coalesce(d -> 'attrs' ? f, false));
            elsif d is null then
                return permissions._cedar_eval_fail(why, format('entity_does_not_exist: %s (reading .%s)',
                                                                 permissions._cedar_uid_text(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id'), f));
            elsif not d -> 'attrs' ? f then
                return permissions._cedar_eval_fail(why, format('attribute_not_found: %s has no attribute %s',
                                                                 permissions._cedar_uid_text(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id'), to_jsonb(f)));
            end if;
            return d -> 'attrs' -> f;
        elsif jsonb_typeof(x) = 'object' and not x ? '__extn' then
            if k = 'has' then
                return to_jsonb(x ? f);
            elsif not x ? f then
                return permissions._cedar_eval_fail(why, format('attribute_not_found: the record has no attribute %s', to_jsonb(f)));
            end if;
            return x -> f;
        end if;
        return permissions._cedar_eval_fail(why, format('type_error: %s: expected an entity or a record, got %s',
                                                         case k when 'get' then '.' || f else 'has ' || f end, permissions._cedar_type_of(x)));
    elsif k = 'not' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'boolean' then
            return permissions._cedar_eval_fail(why, format('type_error: !: expected Bool, got %s', permissions._cedar_type_of(x)));
        end if;
        return to_jsonb(x = 'false');
    elsif k = 'neg' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'number' then
            return permissions._cedar_eval_fail(why, format('type_error: -: expected Long, got %s', permissions._cedar_type_of(x)));
        elsif x::text::numeric = -9223372036854775808 then
            return permissions._cedar_eval_fail(why, format('overflow: -(%s)', x));
        end if;
        return to_jsonb(-(x::text::numeric));
    elsif k = 'is' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif not (jsonb_typeof(x) = 'object' and x ? '__entity') then
            return permissions._cedar_eval_fail(why, format('type_error: is: expected an entity, got %s', permissions._cedar_type_of(x)));
        elsif x -> '__entity' ->> 'type' <> n ->> 't' then
            return 'false';
        elsif not n ? 'in' then
            return 'true';
        end if;
        y := permissions._cedar_eval(n -> 'in', env, why);
        if y is null then
            return null;
        end if;
        return permissions._cedar_in(x, y, env, why);
    elsif k = 'like' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'string' then
            return permissions._cedar_eval_fail(why, format('type_error: like: expected String, got %s', permissions._cedar_type_of(x)));
        end if;
        return to_jsonb((x #>> '{}') collate "C" like (n ->> 'p'));
    elsif k = 'isEmpty' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'array' then
            return permissions._cedar_eval_fail(why, format('type_error: isEmpty: expected Set, got %s', permissions._cedar_type_of(x)));
        end if;
        return to_jsonb(jsonb_array_length(x) = 0);
    elsif k = 'set' then
        for x in select e from jsonb_array_elements(n -> 'a') e loop
            y := permissions._cedar_eval(x, env, why);
            if y is null then
                return null;
            end if;
            vals := vals || y;
        end loop;
        return permissions._cedar_set(to_jsonb(vals));
    elsif k = 'rec' then
        d := '{}';
        for kv in select * from jsonb_each(n -> 'a') loop
            y := permissions._cedar_eval(kv.value, env, why);
            if y is null then
                return null;
            end if;
            d := d || jsonb_build_object(kv.key, y);
        end loop;
        return d;
    elsif k = 'call' then
        for x in select e from jsonb_array_elements(n -> 'a') e loop
            y := permissions._cedar_eval(x, env, why);
            if y is null then
                return null;
            end if;
            vals := vals || y;
        end loop;
        return permissions._cedar_call(n ->> 'f', vals, why);
    end if;

    -- binary operators: both operands, left to right
    x := permissions._cedar_eval(n -> 'a', env, why);
    if x is null then
        return null;
    end if;
    y := permissions._cedar_eval(n -> 'b', env, why);
    if y is null then
        return null;
    end if;
    if k = 'eq' then
        return to_jsonb(x = y);
    elsif k = 'ne' then
        return to_jsonb(x <> y);
    elsif k in ('lt', 'le', 'gt', 'ge') then
        -- two Longs, two datetimes or two durations (Cedar's operator
        -- overloading; decimals compare with their methods only)
        if jsonb_typeof(x) = 'number' and jsonb_typeof(y) = 'number' then
            null;
        elsif (x -> '__extn' ->> 'fn') in ('datetime', 'duration') and x -> '__extn' ->> 'fn' = y -> '__extn' ->> 'fn' then
            x := x -> '__extn' -> 'v';
            y := y -> '__extn' -> 'v';
        else
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected two Longs, two datetimes or two durations, got %s and %s',
                                                             case k when 'lt' then '<' when 'le' then '<=' when 'gt' then '>' else '>=' end,
                                                             permissions._cedar_type_of(x), permissions._cedar_type_of(y)));
        end if;
        return to_jsonb(case k when 'lt' then x::text::numeric < y::text::numeric
                               when 'le' then x::text::numeric <= y::text::numeric
                               when 'gt' then x::text::numeric > y::text::numeric
                               else x::text::numeric >= y::text::numeric end);
    elsif k in ('add', 'sub', 'mul') then
        if jsonb_typeof(x) <> 'number' or jsonb_typeof(y) <> 'number' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected two Longs, got %s and %s',
                                                             case k when 'add' then '+' when 'sub' then '-' else '*' end,
                                                             permissions._cedar_type_of(x), permissions._cedar_type_of(y)));
        end if;
        r := case k when 'add' then x::text::numeric + y::text::numeric
                    when 'sub' then x::text::numeric - y::text::numeric
                    else x::text::numeric * y::text::numeric end;
        if r not between -9223372036854775808 and 9223372036854775807 then
            return permissions._cedar_eval_fail(why, format('overflow: %s %s %s', x, case k when 'add' then '+' when 'sub' then '-' else '*' end, y));
        end if;
        return to_jsonb(r);
    elsif k = 'in' then
        if not (jsonb_typeof(x) = 'object' and x ? '__entity') then
            return permissions._cedar_eval_fail(why, format('type_error: in: expected an entity on the left, got %s', permissions._cedar_type_of(x)));
        end if;
        return permissions._cedar_in(x, y, env, why);
    elsif k = 'contains' then
        if jsonb_typeof(x) <> 'array' then
            return permissions._cedar_eval_fail(why, format('type_error: contains: expected Set, got %s', permissions._cedar_type_of(x)));
        end if;
        return to_jsonb(exists (select 1 from jsonb_array_elements(x) e where e = y));
    elsif k = 'containsAll' or k = 'containsAny' then
        if jsonb_typeof(x) <> 'array' or jsonb_typeof(y) <> 'array' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected two Sets, got %s and %s', k,
                                                             permissions._cedar_type_of(x), permissions._cedar_type_of(y)));
        elsif k = 'containsAll' then
            return to_jsonb(not exists (select 1 from jsonb_array_elements(y) b
                                        where not exists (select 1 from jsonb_array_elements(x) a where a = b)));
        end if;
        return to_jsonb(exists (select 1 from jsonb_array_elements(y) b join jsonb_array_elements(x) a on a = b));
    elsif k = 'hasTag' or k = 'getTag' then
        if not (jsonb_typeof(x) = 'object' and x ? '__entity') or jsonb_typeof(y) <> 'string' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected an entity and a String, got %s and %s', k,
                                                             permissions._cedar_type_of(x), permissions._cedar_type_of(y)));
        end if;
        d := permissions._cedar_entity(env, x);
        f := y #>> '{}';
        if k = 'hasTag' then
            return to_jsonb(coalesce(d -> 'tags' ? f, false));
        elsif d is null then
            return permissions._cedar_eval_fail(why, format('entity_does_not_exist: %s (reading tag %s)',
                                                             permissions._cedar_uid_text(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id'), y));
        elsif not d -> 'tags' ? f then
            return permissions._cedar_eval_fail(why, format('tag_not_found: %s has no tag %s',
                                                             permissions._cedar_uid_text(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id'), y));
        end if;
        return d -> 'tags' -> f;
    end if;
    return permissions._cedar_eval_fail(why, format('internal: unknown ast node %s', k));
end;
$$;

-- ----------------------------------------------------------------------------
-- Authorization
-- ----------------------------------------------------------------------------

-- A request context: a record (null is {}), in internal form. Raises
-- cedar:invalid_context or cedar:limit_exceeded.
create function permissions._cedar_context(p_context jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
    x record;
    code text := 'invalid';
    err text;
begin
    if p_context is null or p_context = 'null' then
        return '{}';
    end if;
    if jsonb_typeof(p_context) <> 'object' or p_context ? '__entity' or p_context ? '__extn' then
        err := format('the context must be a record (a JSON object), got %s', left(p_context::text, 200));
    else
        select * into x from permissions._cedar_value_in(p_context, 'context', 1) r;
        if x.code is null then
            return x.val;
        end if;
        code := x.code;
        err := x.err;
    end if;
    perform permissions._cedar_error(case code when 'limit' then 'limit_exceeded' else 'invalid_context' end,
        format('invalid context: %s', err),
        hint => case code
            when 'limit' then format('Flatten the context: sets and records nest at most %s levels.', (permissions._cedar_limits()).value_depth)
            when 'extension' then 'Write an extension value as {"__extn": {"fn": "decimal", "arg": "12.34"}}, with fn one of decimal, ip, datetime and duration and an arg its constructor accepts: decimal("12.34"), ip("10.0.0.0/8"), datetime("2024-10-15T11:35:00Z"), duration("1h30m").'
            else 'Pass context => ''{"mfa": true, "level": 3, "owner": {"__entity": {"type": "User", "id": "alice"}}}''::jsonb: Bools, Longs, Strings, sets, records, entity references and extension values ({"__extn": {"fn": "ip", "arg": "10.0.0.1"}}).' end,
        p_detail => case code when 'limit' then 'limit=''value_depth''' end);
end;
$$;

-- The keys of the request entities for the scope match, from storage: each
-- entity's key, then its ancestors' keys (pk, ak, rk). The three walks run
-- in one query (as in _cedar_ancestors). A null type gives a null array.
create function permissions._cedar_keys(p_pt text, p_pi text, p_at text, p_ai text, p_rt text, p_ri text,
                                        out pk text[], out ak text[], out rk text[])
language plpgsql stable
as $$
begin
    with recursive w(o, t, i) as (
        select v.o, q.parent_type, q.parent_id
        from (values (1, p_pt, p_pi), (2, p_at, p_ai), (3, p_rt, p_ri)) v(o, t, i)
        cross join lateral (select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
                            where p.type = v.t and p.id = v.i offset 0) q
        union
        select w.o, q.parent_type, q.parent_id from w cross join lateral (
            select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
            where p.type = w.t and p.id = w.i offset 0) q
    )
    select coalesce(array_agg(permissions._cedar_key(w.t, w.i)) filter (where w.o = 1), '{}'),
           coalesce(array_agg(permissions._cedar_key(w.t, w.i)) filter (where w.o = 2), '{}'),
           coalesce(array_agg(permissions._cedar_key(w.t, w.i)) filter (where w.o = 3), '{}')
    into pk, ak, rk
    from w;
    pk := permissions._cedar_key(p_pt, p_pi) || pk;
    ak := permissions._cedar_key(p_at, p_ai) || ak;
    rk := case when p_rt is not null then permissions._cedar_key(p_rt, p_ri) || rk end;
end;
$$;

-- The policies whose scope matches a request (e-cedar.md section 4.4, step
-- 2): pk, ak and rk are _cedar_keys' arrays, p_pt and p_rt the principal's
-- and the resource's type. cedar_policy_scopes gives the candidates: one
-- index scan for each action key and each key of the side with fewer keys
-- (usually the resource), with the other side's keys in its index
-- condition. The predicate after it is the exact scope match. The lateral
-- subqueries with offset 0 keep each probe an index probe: with the three
-- arrays in one scan, the planner scanned the table on a thousand policies
-- and tested each row against the arrays (e-cedar.md section 15.1).
create function permissions._cedar_candidates(pk text[], ak text[], rk text[], p_pt text, p_rt text)
returns table (policy_id text, effect text, ast jsonb)
language sql stable
as $$
    select c.policy_id, c.effect, c.ast
    from (select distinct x.policy_id
          from unnest((ak || '*'::text) collate "C") a(k)
          cross join unnest((pk || p_pt || '*'::text) collate "C") p(k)
          cross join lateral (select s.policy_id from permissions.cedar_policy_scopes s
                              where s.action_key = a.k and s.principal_key = p.k
                                and s.resource_key = any((rk || p_rt || '*'::text) collate "C") offset 0) x
          where cardinality(pk) <= cardinality(rk)
          union
          select x.policy_id
          from unnest((ak || '*'::text) collate "C") a(k)
          cross join unnest((rk || p_rt || '*'::text) collate "C") r(k)
          cross join lateral (select s.policy_id from permissions.cedar_policy_scopes s
                              where s.action_key = a.k and s.resource_key = r.k
                                and s.principal_key = any((pk || p_pt || '*'::text) collate "C") offset 0) x
          where cardinality(pk) > cardinality(rk)) s
    cross join lateral (select * from permissions.cedar_policies x where x.policy_id = s.policy_id offset 0) c
    where (c.principal_op = 'All' or (c.principal_op = '==' and c.principal_uid = pk[1])
           or (c.principal_op = 'in' and c.principal_uid = any(pk))
           or (c.principal_op = 'is' and c.principal_type = p_pt and (c.principal_uid is null or c.principal_uid = any(pk))))
      and (c.action_op = 'All' or (c.action_op = '==' and c.action_uids[1] = ak[1]) or (c.action_op = 'in' and c.action_uids && ak))
      and (c.resource_op = 'All' or (c.resource_op = '==' and c.resource_uid = rk[1])
           or (c.resource_op = 'in' and c.resource_uid = any(rk))
           or (c.resource_op = 'is' and c.resource_type = p_rt and (c.resource_uid is null or c.resource_uid = any(rk))))
$$;

-- The environment of one request (see the Evaluator section): the request
-- entities, the context, their ancestors and their stored data, and the
-- overlay (p_ov: _cedar_entities_in's output, or null). Also each request
-- entity's key with its ancestors' keys (pk, ak, rk), for the scope match.
create function permissions._cedar_env(p_pt text, p_pi text, p_at text, p_ai text, p_rt text, p_ri text,
                                       p_context jsonb, p_ov jsonb,
                                       out env jsonb, out pk text[], out ak text[], out rk text[])
language plpgsql stable
as $$
declare
    ov jsonb;
    ent jsonb;
begin
    if p_ov is null then
        select k.pk[2:], k.ak[2:], k.rk[2:] into pk, ak, rk
        from permissions._cedar_keys(p_pt, p_pi, p_at, p_ai, p_rt, p_ri) k;
        select jsonb_object_agg(permissions._cedar_key(v.t, v.i),
                                case when e.type is not null then jsonb_build_object('attrs', e.attrs, 'tags', e.tags) else 'null' end)
        into ent
        from (values (p_pt, p_pi), (p_at, p_ai), (p_rt, p_ri)) v(t, i)
        left join permissions.cedar_entities e on e.type = v.t and e.id = v.i;
    else
        select jsonb_object_agg(permissions._cedar_key(e ->> 't', e ->> 'i'), e - 't' - 'i') into ov
        from jsonb_array_elements(p_ov) e;
        ov := coalesce(ov, '{}');
        pk := array(select jsonb_array_elements_text(permissions._cedar_ancestors(p_pt, p_pi, ov)));
        ak := array(select jsonb_array_elements_text(permissions._cedar_ancestors(p_at, p_ai, ov)));
        rk := array(select jsonb_array_elements_text(permissions._cedar_ancestors(p_rt, p_ri, ov)));
        select jsonb_object_agg(v.k, coalesce(ov -> v.k,
                                              case when e.type is not null then jsonb_build_object('attrs', e.attrs, 'tags', e.tags) end,
                                              'null'))
        into ent
        from (values (p_pt, p_pi), (p_at, p_ai), (p_rt, p_ri)) v0(t, i)
        cross join lateral (select v0.t, v0.i, permissions._cedar_key(v0.t, v0.i) as k) v
        left join permissions.cedar_entities e on e.type = v.t and e.id = v.i and not ov ? v.k;
    end if;
    env := jsonb_build_object(
        'principal', jsonb_build_object('__entity', jsonb_build_object('type', p_pt, 'id', p_pi)),
        'action', jsonb_build_object('__entity', jsonb_build_object('type', p_at, 'id', p_ai)),
        'resource', jsonb_build_object('__entity', jsonb_build_object('type', p_rt, 'id', p_ri)),
        'context', p_context,
        'anc', jsonb_build_object(permissions._cedar_key(p_pt, p_pi), to_jsonb(pk),
                                  permissions._cedar_key(p_at, p_ai), to_jsonb(ak),
                                  permissions._cedar_key(p_rt, p_ri), to_jsonb(rk)),
        'ent', ent)
        || case when ov is null then '{}' else jsonb_build_object('ov', ov) end;
    -- for the scope: the entity first, then its ancestors
    pk := permissions._cedar_key(p_pt, p_pi) || pk;
    ak := permissions._cedar_key(p_at, p_ai) || ak;
    rk := permissions._cedar_key(p_rt, p_ri) || rk;
end;
$$;

-- Cedar's authorizer (e-cedar.md section 4.4). principal, action and resource
-- are uids in Cedar text (Type::"id"), context a record (null: {}), entities
-- an overlay of Cedar entity JSON for this request only: an entity there
-- replaces the stored entity with the same uid. The policies whose scope
-- matches are evaluated; a forbid that holds denies, else a permit that holds
-- allows, else the default is deny. A policy whose evaluation errs is
-- skipped and reported in errors (Cedar's semantics: it neither permits nor
-- forbids). Returns {"decision": "allow" or "deny", "reasons": [policy ids],
-- "errors": [{"policy_id", "message"}]}, ids sorted (collate "C").
create function permissions.cedar_is_authorized(principal text, action text, resource text,
                                                 context jsonb default null, entities jsonb default null)
returns jsonb
language plpgsql stable security definer
set search_path = ''
set plan_cache_mode = force_generic_plan
as $$
declare
    p record;
    a record;
    r record;
    e record;
    env jsonb;
    pk text[];
    ak text[];
    rk text[];
    pol record;
    v jsonb;
    msg text;
    permits text[] := '{}';
    forbids text[] := '{}';
    errs jsonb := '[]';
begin
    if principal is null or action is null or resource is null then
        perform permissions._cedar_error('null_argument',
            format('%s is required to authorize a request', case when principal is null then 'principal' when action is null then 'action' else 'resource' end),
            hint => 'Pass three uids in Cedar text: principal => ''User::"alice"'', action => ''Action::"view"'', resource => ''Photo::"vacation.jpg"''.',
            p_detail => format('argument=%L', case when principal is null then 'principal' when action is null then 'action' else 'resource' end));
    end if;
    select * into p from permissions._cedar_uid(principal, 'principal');
    select * into a from permissions._cedar_uid(action, 'action');
    select * into r from permissions._cedar_uid(resource, 'resource');
    select * into e
    from permissions._cedar_env(p.type, p.id, a.type, a.id, r.type, r.id,
                                permissions._cedar_context(context),
                                case when entities is not null and entities <> 'null'
                                     then permissions._cedar_entities_in(entities, 'entities', (permissions._cedar_limits()).request_entities) end);
    env := e.env;
    pk := e.pk;
    ak := e.ak;
    rk := e.rk;
    for pol in select * from permissions._cedar_candidates(pk, ak, rk, p.type, r.type) loop
        v := case when pol.ast is null then 'true' else permissions._cedar_eval(pol.ast, env, false) end;
        if v = 'true' then
            if pol.effect = 'permit' then
                permits := permits || pol.policy_id;
            else
                forbids := forbids || pol.policy_id;
            end if;
        elsif v is null or jsonb_typeof(v) <> 'boolean' then
            -- the error's message: evaluate again, raising at the error
            begin
                v := permissions._cedar_eval(pol.ast, env, true);
                msg := case when v is null then 'internal: the condition has no value'
                            else format('type_error: a condition must be Bool, got %s', permissions._cedar_type_of(v)) end;
            exception when sqlstate 'CE001' then
                msg := sqlerrm;
            end;
            errs := errs || jsonb_build_array(jsonb_build_object('policy_id', pol.policy_id, 'message', msg));
        end if;
    end loop;
    return jsonb_build_object(
        'decision', case when cardinality(forbids) = 0 and cardinality(permits) > 0 then 'allow' else 'deny' end,
        'reasons', to_jsonb(array(select x from unnest(case when cardinality(forbids) > 0 then forbids else permits end) x
                                  order by x collate "C")),
        'errors', coalesce((select jsonb_agg(x order by x ->> 'policy_id' collate "C") from jsonb_array_elements(errs) x), '[]'));
end;
$$;

-- ----------------------------------------------------------------------------
-- RLS: the current subject (phase 5)
-- ----------------------------------------------------------------------------
-- cedar_is_authorized_current and cedar_list_resources_current decide for
-- the current subject (e-cedar.md sections 7 and 15). The principal is
-- current_subject_type()::"current_subject_id()": the type and the id are
-- used as they are, never through Cedar text, so an id needs no escapes. A
-- subject type that is not a Cedar type name can't be a principal. No
-- context: a client could otherwise vouch for itself.
--
-- They differ from cedar_is_authorized in one rule (plan-cedar.md, decision
-- 1): they fail closed. A forbid whose scope matches and whose conditions
-- hold or err denies; a permit that errs is skipped, as in Cedar. No
-- subject: false or nothing, so RLS denies instead of failing. An action or
-- resource that is not Cedar text (Type::"id") still raises
-- cedar:invalid_uid, like fga_check_current's unknown type or relation: it
-- is a mistake in the RLS policy, not a decision.

-- The policies whose principal and action scopes match, for any resource:
-- _cedar_candidates without the resource, plus the resource scope, for the
-- statement-level filter and the list.
create function permissions._cedar_principal_candidates(pk text[], ak text[], p_pt text)
returns table (policy_id text, effect text, ast jsonb, resource_op text, resource_type text, resource_uid text)
language sql stable
as $$
    select c.policy_id, c.effect, c.ast, c.resource_op, c.resource_type, c.resource_uid
    from (select distinct x.policy_id
          from unnest((ak || '*'::text) collate "C") a(k)
          cross join unnest((pk || p_pt || '*'::text) collate "C") p(k)
          cross join lateral (select s.policy_id from permissions.cedar_policy_scopes s
                              where s.action_key = a.k and s.principal_key = p.k offset 0) x) s
    cross join lateral (select * from permissions.cedar_policies x where x.policy_id = s.policy_id offset 0) c
    where (c.principal_op = 'All' or (c.principal_op = '==' and c.principal_uid = pk[1])
           or (c.principal_op = 'in' and c.principal_uid = any(pk))
           or (c.principal_op = 'is' and c.principal_type = p_pt and (c.principal_uid is null or c.principal_uid = any(pk))))
      and (c.action_op = 'All' or (c.action_op = '==' and c.action_uids[1] = ak[1]) or (c.action_op = 'in' and c.action_uids && ak))
$$;

-- The environment of a current-subject request without its resource: the
-- principal and the action, their ancestors (pk and ak: _cedar_keys'
-- arrays), their stored data, and an empty context.
create function permissions._cedar_current_env(p_pt text, p_pi text, p_at text, p_ai text, pk text[], ak text[])
returns jsonb
language sql stable
as $$
    select jsonb_build_object(
        'principal', jsonb_build_object('__entity', jsonb_build_object('type', p_pt, 'id', p_pi)),
        'action', jsonb_build_object('__entity', jsonb_build_object('type', p_at, 'id', p_ai)),
        'context', '{}'::jsonb,
        'anc', jsonb_build_object(pk[1], to_jsonb(pk[2:]), ak[1], to_jsonb(ak[2:])),
        'ent', (select jsonb_object_agg(permissions._cedar_key(v.t, v.i),
                                        case when e.type is not null then jsonb_build_object('attrs', e.attrs, 'tags', e.tags) else 'null' end)
                from (values (p_pt, p_pi), (p_at, p_ai)) v(t, i)
                left join permissions.cedar_entities e on e.type = v.t and e.id = v.i))
$$;

-- One request of cedar_is_authorized_current from scratch: the walks, the
-- candidates of the scope index, then their conditions, forbids first.
-- p_attrs: the resource's attrs in internal form, which replace the stored
-- ones (null: the stored entity's).
create function permissions._cedar_current_check(p_pt text, p_pi text, p_at text, p_ai text, p_rt text, p_ri text,
                                                  p_attrs jsonb)
returns boolean
language plpgsql stable
set plan_cache_mode = force_generic_plan
as $$
declare
    k record;
    pol record;
    env jsonb;
    v jsonb;
begin
    select * into k from permissions._cedar_keys(p_pt, p_pi, p_at, p_ai, p_rt, p_ri);
    -- 'forbid' sorts before 'permit'
    for pol in select c.effect, c.ast from permissions._cedar_candidates(k.pk, k.ak, k.rk, p_pt, p_rt) c order by c.effect loop
        if pol.ast is null then
            -- no conditions: a forbid denies; a permit allows, as every
            -- forbid before it was false
            return pol.effect = 'permit';
        end if;
        if env is null then
            env := permissions._cedar_current_env(p_pt, p_pi, p_at, p_ai, k.pk, k.ak)
                   || jsonb_build_object('resource', jsonb_build_object('__entity', jsonb_build_object('type', p_rt, 'id', p_ri)));
            env := jsonb_set(env, '{anc}', (env -> 'anc') || jsonb_build_object(k.rk[1], to_jsonb(k.rk[2:])));
            if p_attrs is not null then
                env := jsonb_set(env, '{ent}', (env -> 'ent') || jsonb_build_object(k.rk[1], jsonb_build_object('attrs', p_attrs,
                    'tags', coalesce((select e.tags from permissions.cedar_entities e where e.type = p_rt and e.id = p_ri), '{}'))));
            end if;
        end if;
        v := permissions._cedar_eval(pol.ast, env, false);
        if pol.effect = 'forbid' then
            if v is distinct from 'false' then
                return false;               -- it holds, or it errs: fail closed
            end if;
        elsif v = 'true' then
            return true;                    -- a permit that errs is skipped
        end if;
    end loop;
    return false;
end;
$$;

-- The statement-level part of cedar_is_authorized_current (e-cedar.md
-- section 15.2): computed once per statement, kept as text in a
-- transaction-local setting. Two parts, split by chr(28):
--   1. Flags, chr(30), then one entry per permit whose principal and action
--      scopes match, each followed by chr(30): its resource scope, E:<key>
--      (resource == key), I:<key> (resource in key), T:<type> (resource is
--      type) or A:* (any resource) for a permit without conditions; e:,
--      i:, t: and a:* for a permit with conditions, or with is ... in (as
--      i:<key>). Flags: F, a forbid's principal and action scopes match; X,
--      part 2 would be too large to parse per row.
--   2. Unless X, and if there is a forbid or an entry in lower case, the
--      forbids and the lower-case permits grouped by resource scope, with
--      the environment without the resource, as jsonb text:
--        {"pf": {"e": {key: [p]}, "i": {key: [p]}, "t": {type: [p]}, "a": [p]},
--         "env": _cedar_current_env, "tags": a condition uses tags}
--      with p {"f": forbid?, "a": ast or null, "t": the type of is ... in}.
-- Part 2 is parsed for the rows that need it, so it is capped: 8 KiB parse
-- in about 40 us, about what the check from scratch costs.
create function permissions._cedar_current_filter(p_pt text, p_pi text, p_at text, p_ai text)
returns text
language plpgsql stable
set plan_cache_mode = force_generic_plan
as $$
declare
    k record;
    cs jsonb;
    f text;
    payload text;
begin
    select * into k from permissions._cedar_keys(p_pt, p_pi, p_at, p_ai, null, null);
    select coalesce(jsonb_agg(jsonb_build_object(
               'f', x.effect = 'forbid', 'a', x.ast,
               'k', case x.resource_op when '==' then 'e' when 'in' then 'i' when 'All' then 'a'
                                       else case when x.resource_uid is null then 't' else 'i' end end,
               'v', case x.resource_op when 'All' then '*' when 'is' then coalesce(x.resource_uid, x.resource_type) else x.resource_uid end,
               't', case when x.resource_op = 'is' and x.resource_uid is not null then x.resource_type end,
               'free', x.effect = 'permit' and x.ast is null and not (x.resource_op = 'is' and x.resource_uid is not null))), '[]')
    into cs
    from permissions._cedar_principal_candidates(k.pk, k.ak, p_pt) x;
    if exists (select 1 from jsonb_array_elements(cs) c where strpos(c ->> 'v', chr(28)) > 0 or strpos(c ->> 'v', chr(30)) > 0) then
        -- a resource scope holds a separator of this layout: every row that
        -- a permit can match is checked from scratch (flag X, entry a:*)
        return 'X' || chr(30) || 'a:*' || chr(30) || chr(28);
    end if;
    f := case when exists (select 1 from jsonb_array_elements(cs) c where (c ->> 'f')::boolean) then 'F' else '' end || chr(30)
         || coalesce((select string_agg(case when (c ->> 'free')::boolean then upper(c ->> 'k') else c ->> 'k' end
                                        || ':' || (c ->> 'v') || chr(30), '')
                      from jsonb_array_elements(cs) c where not (c ->> 'f')::boolean), '');
    if exists (select 1 from jsonb_array_elements(cs) c where not (c ->> 'free')::boolean) then
        with p as (select c ->> 'k' as k, c ->> 'v' as v, jsonb_build_object('f', c -> 'f', 'a', c -> 'a', 't', c -> 't') as p
                   from jsonb_array_elements(cs) c where not (c ->> 'free')::boolean)
        select jsonb_build_object(
                   'pf', jsonb_build_object(
                       'e', coalesce((select jsonb_object_agg(g.v, g.ps) from (select p.v, jsonb_agg(p.p) as ps from p where p.k = 'e' group by p.v) g), '{}'),
                       'i', coalesce((select jsonb_object_agg(g.v, g.ps) from (select p.v, jsonb_agg(p.p) as ps from p where p.k = 'i' group by p.v) g), '{}'),
                       't', coalesce((select jsonb_object_agg(g.v, g.ps) from (select p.v, jsonb_agg(p.p) as ps from p where p.k = 't' group by p.v) g), '{}'),
                       'a', coalesce((select jsonb_agg(p.p) from p where p.k = 'a'), '[]')),
                   'env', permissions._cedar_current_env(p_pt, p_pi, p_at, p_ai, k.pk, k.ak),
                   'tags', exists (select 1 from p where (p.p -> 'a')::text ~ '"k": "(has|get)Tag"'))::text
        into payload;
        if octet_length(payload) > 8192 then
            f := 'X' || f;
            payload := '';
        end if;
    end if;
    return f || chr(28) || coalesce(payload, '');
end;
$$;

-- The decision for one resource from part 2 of the statement's filter (x,
-- parsed): the forbids and the permits with conditions whose resource scope
-- matches, forbids first, failing closed; p_free: a permit without
-- conditions matches (part 1 says). p_attrs: the row's attributes, internal
-- form, or null for the stored ones; p_anc: the resource's ancestors if the
-- caller walked them already.
create function permissions._cedar_decide(x jsonb, p_rt text, p_ri text, p_attrs jsonb, p_anc jsonb, p_free boolean)
returns boolean
language plpgsql stable
as $$
declare
    rk text := permissions._cedar_key(p_rt, p_ri);
    pf jsonb := x -> 'pf';
    anc jsonb := p_anc;
    m jsonb;
    e jsonb;
    p jsonb;
    v jsonb;
begin
    m := coalesce(pf -> 'e' -> rk, '[]') || coalesce(pf -> 't' -> p_rt, '[]') || coalesce(pf -> 'a', '[]');
    if pf -> 'i' <> '{}' then
        anc := coalesce(anc, permissions._cedar_ancestors(p_rt, p_ri, null));
        m := m || coalesce((select jsonb_agg(q) from jsonb_array_elements_text(anc || to_jsonb(rk)) a(k)
                            cross join lateral jsonb_array_elements(pf -> 'i' -> a.k) q
                            where q ->> 't' is null or q ->> 't' = p_rt), '[]');
    end if;
    if m = '[]' then
        return p_free;
    end if;
    e := (x -> 'env') || jsonb_build_object('resource', jsonb_build_object('__entity', jsonb_build_object('type', p_rt, 'id', p_ri)));
    if anc is not null then
        e := jsonb_set(e, '{anc}', (e -> 'anc') || jsonb_build_object(rk, anc));
    end if;
    if p_attrs is not null then
        e := jsonb_set(e, '{ent}', (e -> 'ent') || jsonb_build_object(rk, jsonb_build_object('attrs', p_attrs,
            'tags', case when (x ->> 'tags')::boolean
                         then coalesce((select t.tags from permissions.cedar_entities t where t.type = p_rt and t.id = p_ri), '{}')
                         else '{}' end)));
    end if;
    for p in select q from jsonb_array_elements(m) q where (q ->> 'f')::boolean loop
        v := case when p -> 'a' = 'null' then 'true' else permissions._cedar_eval(p -> 'a', e, false) end;
        if v is distinct from 'false' then
            return false;                   -- a forbid holds, or errs: fail closed
        end if;
    end loop;
    if p_free then
        return true;
    end if;
    for p in select q from jsonb_array_elements(m) q where not (q ->> 'f')::boolean loop
        if p -> 'a' = 'null' or permissions._cedar_eval(p -> 'a', e, false) = 'true' then
            return true;                    -- a permit that errs is skipped
        end if;
    end loop;
    return false;
end;
$$;

-- Own writes end the filters that cedar_is_authorized_current cached in
-- this transaction: the cache key holds this setting. Writes of other
-- transactions change the snapshot, which the key holds too.
create function permissions._cedar_changed()
returns trigger
language plpgsql
as $$
begin
    perform set_config('permissions.cedar_generation', gen_random_uuid()::text, true);
    return null;
end;
$$;

create trigger cedar_changed after insert or update or delete or truncate on permissions.cedar_policies
    for each statement execute function permissions._cedar_changed();
create trigger cedar_changed after insert or update or delete or truncate on permissions.cedar_entities
    for each statement execute function permissions._cedar_changed();
create trigger cedar_changed after insert or update or delete or truncate on permissions.cedar_entity_parents
    for each statement execute function permissions._cedar_changed();

-- Whether a record of attributes is already in internal form (e-cedar.md
-- section 3), so the row overlay of cedar_is_authorized_current needs no
-- conversion: every value a String, a Bool, a Long in range, or an entity
-- reference {"__entity": {"type", "id"}}. Anything else (sets, records,
-- extension values) goes through _cedar_value_in.
create function permissions._cedar_attrs_plain(v jsonb)
returns boolean
language sql immutable
as $$
    select not exists (
        select 1 from jsonb_each(v) e
        where not case jsonb_typeof(e.value)
            when 'string' then true
            when 'boolean' then true
            when 'number' then scale(e.value::text::numeric) = 0
                               and e.value::text::numeric between -9223372036854775808 and 9223372036854775807
            when 'object' then e.value - '__entity' = '{}' and jsonb_typeof(e.value -> '__entity') = 'object'
                               and (e.value -> '__entity') - 'type' - 'id' = '{}'
                               and jsonb_typeof(e.value -> '__entity' -> 'id') = 'string'
                               and jsonb_typeof(e.value -> '__entity' -> 'type') = 'string'
                               and permissions._cedar_is_name(e.value -> '__entity' ->> 'type')
            else false end)
$$;

-- Per-row checks in RLS:
--   using (permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || id || '"'))
-- with a row's columns as the resource's attributes (Cedar entity JSON):
--   using (permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || id || '"',
--          resource_attrs => jsonb_build_object('owner', jsonb_build_object('__entity',
--                                jsonb_build_object('type', 'User', 'id', owner_id)), 'level', level)))
-- resource_attrs replaces the stored entity's attrs; its parents and tags
-- still come from storage, and a resource that is not stored has no parents
-- and no tags. Attributes Cedar can't hold (a fraction, a null) deny, as
-- does a null action or resource, and a resource Type::"..." whose id is
-- not a Cedar string (a row's id with " or \ concatenated unescaped): data
-- never raises. Other resource text, and an action that is not a uid, are
-- the caller's typos and raise cedar:invalid_uid. Ids may hold any
-- character. plan_time_guard is ignored: its volatile
-- default keeps a constant call out of plan-time evaluation (see
-- _unfolded_null); don't pass it.
--
-- Once per statement (e-cedar.md section 15.2): the principal's and the
-- action's walks, the candidate policies and the environment
-- (_cedar_current_filter), kept in a transaction-local setting under a key
-- of the snapshot, the settings the subject comes from, the action and
-- cedar_generation (own writes). Per row: the resource's scope against the
-- candidates; only a resource that a forbid or a permit with conditions can
-- match evaluates anything. The setting is no weaker than the subject: a
-- client that can write it can write request.jwt.claims or
-- permissions.subject_id too, and be anyone (docs: Identity).
create function permissions.cedar_is_authorized_current(action text, resource text, resource_attrs jsonb default null,
                                                        plan_time_guard boolean default permissions._unfolded_null())
returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
    g text;
    key text;
    f text;
    payload text;
    a record;
    rt text;
    ri text;
    rk text;
    i int;
    x record;
    anc jsonb;
    free boolean;
    cond boolean;
    sep boolean;
    attrs jsonb;
begin
    if action is null or resource is null then
        return false;
    end if;
    -- the statement's filter
    g := 'permissions.cedar_filter_' || md5(action);
    key := format('%s %L %L %L %L %L', pg_current_snapshot(), current_setting('request.jwt.claims', true),
                  current_setting('permissions.subject_id', true), current_setting('permissions.subject_type', true),
                  current_setting('permissions.cedar_generation', true), action) || chr(29);
    f := current_setting(g, true);
    if f is null or not starts_with(f, key) then
        select * into a from permissions._cedar_uid(action, 'action');
        f := key || case when permissions.current_subject_id() is null or not permissions._cedar_is_name(permissions.current_subject_type())
                         then chr(30) || chr(28)
                         else permissions._cedar_current_filter(permissions.current_subject_type(), permissions.current_subject_id(), a.type, a.id) end;
        perform set_config(g, f, true);
    end if;
    f := substr(f, char_length(key) + 1);
    i := strpos(f, chr(28));
    payload := substr(f, i + 1);
    f := left(f, i - 1);
    -- the resource uid (_cedar_uid's common case inline: no escapes)
    i := strpos(resource, '::"');
    if i > 0 and right(resource, 1) = '"' and strpos(resource, '\') = 0 and char_length(resource) > i + 2
       and strpos(substr(resource, i + 3, char_length(resource) - i - 3), '"') = 0
       and permissions._cedar_is_name(left(resource, i - 1)) then
        rt := left(resource, i - 1);
        ri := substr(resource, i + 3, char_length(resource) - i - 3);
    else
        select * into x from permissions._cedar_uid(resource, 'resource', true);
        if x.type is null then
            -- Type::"..." whose id is not a Cedar string, as when a row's id
            -- with " or \ is concatenated unescaped: data, so the row is
            -- denied. Any other text is the caller's typo and raises.
            if resource !~ '^\s*[_a-zA-Z][_a-zA-Z0-9]*(::[_a-zA-Z][_a-zA-Z0-9]*)*::".*"\s*$' then
                perform permissions._cedar_uid(resource, 'resource');
            end if;
            return false;
        end if;
        rt := x.type;
        ri := x.id;
    end if;
    if strpos(f, ':') = 0 then
        return false;                       -- no subject, or no permit for it
    end if;
    -- which permits' resource scopes match: free (no conditions), cond (others)
    rk := permissions._cedar_key(rt, ri);
    free := strpos(f, chr(30) || 'A:*' || chr(30)) > 0 or strpos(f, chr(30) || 'E:' || rk || chr(30)) > 0
            or strpos(f, chr(30) || 'T:' || rt || chr(30)) > 0;
    cond := strpos(f, chr(30) || 'a:*' || chr(30)) > 0 or strpos(f, chr(30) || 'e:' || rk || chr(30)) > 0
            or strpos(f, chr(30) || 't:' || rt || chr(30)) > 0;
    sep := strpos(rk, chr(30)) > 0;
    if (not free and strpos(f, chr(30) || 'I:') > 0) or (not cond and strpos(f, chr(30) || 'i:') > 0) then
        anc := permissions._cedar_ancestors(rt, ri, null);
        select free or coalesce(bool_or(strpos(f, chr(30) || 'I:' || k.k || chr(30)) > 0), false),
               cond or coalesce(bool_or(strpos(f, chr(30) || 'i:' || k.k || chr(30)) > 0), false),
               sep or coalesce(bool_or(strpos(k.k, chr(30)) > 0), false)
        into free, cond, sep
        from jsonb_array_elements_text(anc || to_jsonb(rk)) k(k);
    end if;
    if sep then
        -- the resource's key or an ancestor's holds chr(30), the separator
        -- of the entries, so the matches above can be false: from scratch
        f := 'X';
        free := false;
        cond := true;
    end if;
    if not free and not cond then
        return false;
    elsif free and strpos(split_part(f, chr(30), 1), 'F') = 0 then
        return true;                        -- a permit without conditions, and no forbid can match
    end if;
    if resource_attrs is not null and resource_attrs <> 'null' then
        if jsonb_typeof(resource_attrs) <> 'object' or resource_attrs ? '__entity' or resource_attrs ? '__extn' then
            return false;
        elsif permissions._cedar_attrs_plain(resource_attrs) then
            attrs := resource_attrs;
        else
            select * into x from permissions._cedar_value_in(resource_attrs, 'resource_attrs', 1);
            if x.code is not null then
                return false;
            end if;
            attrs := x.val;
        end if;
    end if;
    if strpos(split_part(f, chr(30), 1), 'X') > 0 then
        select * into a from permissions._cedar_uid(action, 'action');
        return permissions._cedar_current_check(permissions.current_subject_type(), permissions.current_subject_id(),
                                                a.type, a.id, rt, ri, attrs);
    end if;
    return permissions._cedar_decide(payload::jsonb, rt, ri, attrs, anc, free);
end;
$$;

-- The candidate resources of cedar_list_resources_current: the ids of the
-- stored entities of type p_type that a permit of pf names in its resource
-- scope (pf as _cedar_eval_resource takes it), and whether a permit without
-- conditions names it (free). ==: that entity; in X: X and its descendants;
-- All and is: every entity of the type.
create function permissions._cedar_list_candidates(pf jsonb, p_type text)
returns table (id text, free boolean)
language sql stable
as $$
    with recursive p as materialized (
        select x ->> 'op' as op, x ->> 'u' as u, split_part(x ->> 'u', '::"', 1) as ut,
               x -> 'a' = 'null' as free
        from jsonb_array_elements(pf) x
        where not (x ->> 'f')::boolean
    ), d(t, i, root, free) as (
        select p.ut collate "C", substr(p.u, char_length(p.ut) + 4, char_length(p.u) - char_length(p.ut) - 4) collate "C", true, p.free
        from p
        where p.op = 'in' or (p.op = 'is' and p.u is not null)
        union
        -- a child in cedar_entity_parents is a stored entity
        select q.type, q.id, false, d.free from d cross join lateral (
            select x.type, x.id from permissions.cedar_entity_parents x
            where x.parent_type = d.t and x.parent_id = d.i offset 0) q
    )
    select c.id, bool_or(c.free)
    -- lateral subqueries with offset 0: run only for the scopes that need
    -- them (a join here became a hash of every entity of the type)
    from (select q.id, p.free from p cross join lateral (
              select e.id from permissions.cedar_entities e where e.type = p_type offset 0) q
          where p.op = 'All' or (p.op = 'is' and p.u is null)
          union all
          select q.id, p.free from p cross join lateral (
              select e.id from permissions.cedar_entities e
              where e.type = p_type and e.id = substr(p.u, char_length(p.ut) + 4, char_length(p.u) - char_length(p.ut) - 4) offset 0) q
          where p.op = '==' and p.ut = p_type
          union all
          select d.i, d.free from d
          where d.t = p_type and not d.root
          union all
          -- a root (X itself) must be stored: a primary-key probe (an
          -- exists here became a hashed scan of every entity)
          select d.i, d.free from d cross join lateral (
              select 1 from permissions.cedar_entities e where e.type = d.t and e.id = d.i offset 0) q
          where d.t = p_type and d.root) c
    group by c.id
$$;

-- Whether the policies pf allow a resource, failing closed. pf: a jsonb
-- array, forbids first, of {"f": forbid?, "a": ast or null, "op", "t", "u"}
-- (the resource scope: op, type and uid key) of policies whose principal
-- and action scopes match; env: _cedar_current_env's. The resource's
-- ancestors are walked only if an in scope needs them.
create function permissions._cedar_eval_resource(pf jsonb, env jsonb, p_rt text, p_ri text)
returns boolean
language plpgsql stable
as $$
declare
    rk text := permissions._cedar_key(p_rt, p_ri);
    anc jsonb;
    e jsonb;
    p jsonb;
    v jsonb;
begin
    e := env || jsonb_build_object('resource', jsonb_build_object('__entity', jsonb_build_object('type', p_rt, 'id', p_ri)));
    for p in select x from jsonb_array_elements(pf) x loop
        if p ->> 'op' = '==' then
            continue when p ->> 'u' <> rk;
        elsif p ->> 'op' <> 'All' then
            continue when p ->> 'op' = 'is' and p ->> 't' <> p_rt;
            if p ->> 'u' is not null and p ->> 'u' <> rk then
                if anc is null then
                    anc := permissions._cedar_ancestors(p_rt, p_ri, null);
                    e := jsonb_set(e, '{anc}', (e -> 'anc') || jsonb_build_object(rk, anc));
                end if;
                continue when not anc ? (p ->> 'u');
            end if;
        end if;
        v := case when p -> 'a' = 'null' then 'true' else permissions._cedar_eval(p -> 'a', e, false) end;
        if (p ->> 'f')::boolean then
            if v is distinct from 'false' then
                return false;
            end if;
        elsif v = 'true' then
            return true;
        end if;
    end loop;
    return false;
end;
$$;

-- Ids (without the type) of the stored entities of resource_type that the
-- current subject may perform action on, for RLS:
--   id = any (array(select permissions.cedar_list_resources_current('Action::"view"', 'Document')::uuid))
-- Stored entities only (plan-cedar.md, decision 3): a resource that is not
-- stored is never listed, even when a policy names it, and no row
-- attributes apply. Uncapped, unordered, and fails closed like
-- cedar_is_authorized_current. The candidates come from the resource scopes
-- of the permits (section 15.3); a candidate is evaluated only when a
-- forbid could match or only a permit with conditions names it. A
-- set-returning function is never evaluated at plan time (its estimate is
-- `rows`), so it needs no plan_time_guard. No JIT: the generic plan of
-- _cedar_list_candidates is costed for every branch (with a million
-- documents, over jit_above_cost), and compiling it took 10 ms a call on
-- Postgres 18 for a query that runs in 0.2 ms (e-cedar.md section 15.3).
create function permissions.cedar_list_resources_current(action text, resource_type text)
returns setof text
language plpgsql stable security definer
set search_path = ''
set plan_cache_mode = force_generic_plan
set jit = off
rows 100
as $$
declare
    pt text := permissions.current_subject_type();
    pi text := permissions.current_subject_id();
    a record;
    k record;
    pf jsonb;
    env jsonb;
    cand record;
    forbids boolean;
begin
    if action is null or resource_type is null then
        return;
    end if;
    select * into a from permissions._cedar_uid(action, 'action');
    if not permissions._cedar_is_name(resource_type) then
        perform permissions._cedar_error('invalid_argument', format('invalid entity type for resource_type: %s', resource_type),
            hint => 'Pass an entity type name without an id: resource_type => ''Document'' (a namespaced type: ''App::Document'').',
            p_detail => format('value=%L', resource_type));
    end if;
    if pi is null or not permissions._cedar_is_name(pt) then
        return;
    end if;
    select * into k from permissions._cedar_keys(pt, pi, a.type, a.id, null, null);
    select coalesce(jsonb_agg(jsonb_build_object('f', c.effect = 'forbid', 'a', c.ast, 'op', c.resource_op,
                                                 't', c.resource_type, 'u', c.resource_uid)
                              order by c.effect, c.policy_id), '[]')
    into pf
    from permissions._cedar_principal_candidates(k.pk, k.ak, pt) c
    where c.resource_op in ('All', 'in')
       or (c.resource_op = 'is' and c.resource_type = cedar_list_resources_current.resource_type)
       or (c.resource_op = '==' and split_part(c.resource_uid, '::"', 1) = cedar_list_resources_current.resource_type);
    if not exists (select 1 from jsonb_array_elements(pf) p where not (p ->> 'f')::boolean) then
        return;
    end if;
    forbids := exists (select 1 from jsonb_array_elements(pf) p where (p ->> 'f')::boolean);
    if not forbids and not exists (select 1 from jsonb_array_elements(pf) p where p -> 'a' <> 'null') then
        -- permits without conditions: their scopes are the answer
        return query select l.id from permissions._cedar_list_candidates(pf, resource_type) l;
        return;
    end if;
    env := permissions._cedar_current_env(pt, pi, a.type, a.id, k.pk, k.ak);
    for cand in select * from permissions._cedar_list_candidates(pf, resource_type) loop
        if (cand.free and not forbids) or permissions._cedar_eval_resource(pf, env, resource_type, cand.id) then
            return next cand.id;
        end if;
    end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- Admin API: policies
-- ----------------------------------------------------------------------------

-- The nearest policy ids (_did_you_mean), for hints; or that the id is a
-- template's.
create function permissions._cedar_policy_hint(p_id text)
returns text
language sql stable
as $$
    select coalesce(case when exists (select 1 from permissions.cedar_templates t where t.template_id = p_id)
                         then format('%L is a template: delete it with select permissions.cedar_delete_template(template_id => %L).', p_id, p_id) end,
                    permissions._did_you_mean(coalesce(p_id, ''),
                                              array(select c.policy_id from permissions.cedar_policies c),
                                              'Policy ids'),
                    'No policy exists yet: put one with select permissions.cedar_put_policy(policy_id => ..., policy => ...).')
$$;

-- The nearest template ids, for hints; or that the id is a policy's.
create function permissions._cedar_template_hint(p_id text)
returns text
language sql stable
as $$
    select coalesce(case when exists (select 1 from permissions.cedar_policies c where c.policy_id = p_id)
                         then format('%L is a policy or a link, not a template: see select * from permissions.cedar_policies().', p_id) end,
                    permissions._did_you_mean(coalesce(p_id, ''),
                                              array(select t.template_id from permissions.cedar_templates t),
                                              'Template ids'),
                    'No template exists yet: put one with select permissions.cedar_put_template(template_id => ..., template => ...).')
$$;

-- Static policies, template links and templates share one set of ids, as in
-- a Cedar policy set. p_kind is what the caller puts: 'policy' (a static
-- policy), 'link' or 'template'. A put may replace an id of its own kind;
-- an id of another kind raises cedar:id_in_use.
create function permissions._cedar_check_id(p_id text, p_kind text)
returns void
language plpgsql stable
as $$
declare
    tid text;
    other text;
begin
    if p_kind <> 'template' and exists (select 1 from permissions.cedar_templates t where t.template_id = p_id) then
        other := 'a template';
    else
        select c.template_id into tid from permissions.cedar_policies c
        where c.policy_id = p_id and (p_kind = 'template' or (p_kind = 'policy') = (c.template_id is not null));
        if found then
            other := case when tid is null then 'a static policy' else format('a link of template %L', tid) end;
        end if;
    end if;
    if other is not null then
        perform permissions._cedar_error('id_in_use',
            format('%L is already %s, so it cannot be %s', p_id, other,
                   case p_kind when 'policy' then 'a static policy' when 'link' then 'a template link' else 'a template' end),
            hint => 'Static policies, template links and templates share one set of ids: choose another id, or first delete the existing one (cedar_delete_policy for a policy or a link, cedar_delete_template for a template).',
            p_detail => format('id=%L', p_id));
    end if;
end;
$$;

-- Insert or replace one row of cedar_policies: a static policy (p_template_id
-- null) or a link, and its rows of cedar_policy_scopes. c is
-- _cedar_compile_policy's result.
create function permissions._cedar_store_policy(p_id text, p_source text, p_est jsonb, c jsonb,
                                                p_template_id text, p_slots jsonb)
returns void
language sql
as $$
    insert into permissions.cedar_policies as x (policy_id, effect, source, est, ast, annotations,
                                                 principal_op, principal_type, principal_uid,
                                                 action_op, action_uids,
                                                 resource_op, resource_type, resource_uid,
                                                 template_id, slots)
    values (p_id, c ->> 'effect', p_source, p_est, nullif(c -> 'ast', 'null'), c -> 'annotations',
            c -> 'principal' ->> 'op', c -> 'principal' ->> 'type', c -> 'principal' ->> 'uid',
            c -> 'action' ->> 'op', array(select jsonb_array_elements_text(c -> 'action' -> 'uids')),
            c -> 'resource' ->> 'op', c -> 'resource' ->> 'type', c -> 'resource' ->> 'uid',
            p_template_id, p_slots)
    on conflict on constraint cedar_policies_pkey do update
        set effect = excluded.effect, source = excluded.source, est = excluded.est, ast = excluded.ast,
            annotations = excluded.annotations,
            principal_op = excluded.principal_op, principal_type = excluded.principal_type, principal_uid = excluded.principal_uid,
            action_op = excluded.action_op, action_uids = excluded.action_uids,
            resource_op = excluded.resource_op, resource_type = excluded.resource_type, resource_uid = excluded.resource_uid,
            template_id = excluded.template_id, slots = excluded.slots;
    -- the scope index: one row per action (none for action in [], which
    -- matches no request)
    delete from permissions.cedar_policy_scopes s where s.policy_id = p_id;
    insert into permissions.cedar_policy_scopes (policy_id, action_key, principal_key, resource_key)
    select p_id, a.k,
           case c -> 'principal' ->> 'op' when 'All' then '*' else coalesce(c -> 'principal' ->> 'uid', c -> 'principal' ->> 'type') end,
           case c -> 'resource' ->> 'op' when 'All' then '*' else coalesce(c -> 'resource' ->> 'uid', c -> 'resource' ->> 'type') end
    from (select '*' as k where c -> 'action' ->> 'op' = 'All'
          union
          select jsonb_array_elements_text(c -> 'action' -> 'uids')) a;
$$;

-- Put (insert or replace) one static policy. Give exactly one of policy
-- (Cedar text, one policy) and policy_json (Cedar's JSON policy format, the
-- EST, as `cedar translate-policy` prints it). Text is parsed to the EST
-- here and kept as source; the EST is checked and compiled; requests never
-- parse. Annotations are metadata. The policy_id argument names the policy:
-- an @id annotation in the text stays an annotation (e-cedar.md section 13).
create function permissions.cedar_put_policy(policy_id text, policy text default null, policy_json jsonb default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    est jsonb;
    c jsonb;
begin
    if policy_id is null or (cedar_put_policy.policy is null and policy_json is null) then
        perform permissions._cedar_error('null_argument',
            case when policy_id is null then 'policy_id is required to put a policy'
                 else format('policy %L needs policy (Cedar text) or policy_json: both are null', policy_id) end,
            hint => 'select permissions.cedar_put_policy(policy_id => ''view-own'', policy => ''permit (principal, action == Action::"view", resource) when { resource.owner == principal };'');',
            p_detail => format('argument=%L', case when policy_id is null then 'policy_id' else 'policy' end));
    end if;
    if cedar_put_policy.policy is not null and policy_json is not null then
        perform permissions._cedar_error('invalid_argument', format('policy %L has both policy and policy_json', policy_id),
            hint => 'Pass exactly one: policy => Cedar text, or policy_json => the same policy in Cedar''s JSON format.',
            p_detail => 'argument=''policy''');
    end if;
    est := coalesce(permissions._cedar_parse_policy(cedar_put_policy.policy), policy_json);
    perform permissions._cedar_check_id(policy_id, 'policy');
    c := permissions._cedar_compile_policy(est, policy_id, p_text => cedar_put_policy.policy is not null);
    perform permissions._cedar_store_policy(policy_id, cedar_put_policy.policy, est, c, null, null);
end;
$$;

-- Delete a static policy or a template link.
create function permissions.cedar_delete_policy(policy_id text)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    delete from permissions.cedar_policies c where c.policy_id = cedar_delete_policy.policy_id;
    if not found then
        perform permissions._cedar_error(case when policy_id is null then 'null_argument' else 'unknown_policy' end,
            case when policy_id is null then 'policy_id is required to delete a policy' else format('unknown policy %L', policy_id) end,
            hint => permissions._cedar_policy_hint(policy_id),
            p_detail => case when policy_id is null then 'argument=''policy_id''' else format('policy_id=%L', policy_id) end);
    end if;
end;
$$;

-- Every policy, static and linked, by id: its effect, Cedar text (null when
-- put as JSON, and for a link), EST (a link's has the slots filled in) and
-- annotations; for a link, its template and slot values
-- ({"?principal": {"type", "id"}, "?resource": ...}).
create function permissions.cedar_policies()
returns table (policy_id text, effect text, source text, est jsonb, annotations jsonb, template_id text, slots jsonb)
language sql stable security definer
set search_path = ''
as $$
    select c.policy_id, c.effect, c.source, c.est, c.annotations, c.template_id, c.slots
    from permissions.cedar_policies c
    order by c.policy_id
$$;

-- ----------------------------------------------------------------------------
-- Admin API: templates and links (phase 4c)
-- ----------------------------------------------------------------------------
-- A template is a policy with the slot ?principal in its principal scope, the
-- slot ?resource in its resource scope, or both (Cedar allows slots nowhere
-- else). A link fills every slot with an entity and becomes a policy of its
-- own, a row of cedar_policies under its own policy_id. The slots are filled
-- at link time (_cedar_link): the link stores the filled EST, the template's
-- compiled conditions and the filled scope columns, so a request treats a
-- link exactly like a static policy and never sees a slot (e-cedar.md
-- section 13). Replacing a template re-links its links.

-- The slots of a template's EST: '{?principal}', '{?resource}' or both.
create function permissions._cedar_template_slots(p_est jsonb)
returns text[]
language sql immutable
as $$
    select array_remove(array[
        case when p_est -> 'principal' ? 'slot' or coalesce(p_est #> '{principal,in}' ? 'slot', false) then '?principal' end,
        case when p_est -> 'resource' ? 'slot' or coalesce(p_est #> '{resource,in}' ? 'slot', false) then '?resource' end], null)
$$;

-- Store the link p_id of a template: fill the slots of its EST with p_values
-- ({"?principal": {"type", "id"}, ...}, every slot present), compile the
-- filled scopes, and reuse the template's compiled conditions (p_ast) and
-- annotations.
create function permissions._cedar_link(p_id text, p_template_id text, p_est jsonb, p_ast jsonb, p_annotations jsonb, p_values jsonb)
returns void
language plpgsql
as $$
declare
    est jsonb := p_est;
    s text;
    sc jsonb;
begin
    foreach s in array array['principal', 'resource'] loop
        sc := est -> s;
        if sc ? 'slot' then
            est := jsonb_set(est, array[s], (sc - 'slot') || jsonb_build_object('entity', p_values -> (sc ->> 'slot')));
        elsif jsonb_typeof(sc -> 'in') = 'object' and sc -> 'in' ? 'slot' then
            est := jsonb_set(est, array[s, 'in'], jsonb_build_object('entity', p_values -> (sc -> 'in' ->> 'slot')));
        end if;
    end loop;
    perform permissions._cedar_store_policy(p_id, null, est,
        jsonb_build_object('effect', est ->> 'effect', 'ast', p_ast, 'annotations', p_annotations,
                           'principal', permissions._cedar_compile_scope(est -> 'principal', 'principal'),
                           'action', permissions._cedar_compile_scope(est -> 'action', 'action'),
                           'resource', permissions._cedar_compile_scope(est -> 'resource', 'resource')),
        p_template_id, p_values);
end;
$$;

-- Put (insert or replace) one template. Give exactly one of template (Cedar
-- text) and template_json (Cedar's JSON policy format, with slots). When the
-- template exists and has links, each link is filled again from the new
-- template; the new template must keep the slots its links fill.
create function permissions.cedar_put_template(template_id text, template text default null, template_json jsonb default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    est jsonb;
    c jsonb;
    want text[];
    bad text;
    l record;
begin
    if template_id is null or (cedar_put_template.template is null and template_json is null) then
        perform permissions._cedar_error('null_argument',
            case when template_id is null then 'template_id is required to put a template'
                 else format('template %L needs template (Cedar text) or template_json: both are null', template_id) end,
            hint => 'select permissions.cedar_put_template(template_id => ''owner-access'', template => ''permit (principal == ?principal, action, resource in ?resource);'');',
            p_detail => format('argument=%L', case when template_id is null then 'template_id' else 'template' end));
    end if;
    if cedar_put_template.template is not null and template_json is not null then
        perform permissions._cedar_error('invalid_argument', format('template %L has both template and template_json', template_id),
            hint => 'Pass exactly one: template => Cedar text, or template_json => the same template in Cedar''s JSON format.',
            p_detail => 'argument=''template''');
    end if;
    est := coalesce(permissions._cedar_parse_policy(cedar_put_template.template), template_json);
    perform permissions._cedar_check_id(template_id, 'template');
    c := permissions._cedar_compile_policy(est, template_id, p_template => true, p_text => cedar_put_template.template is not null);
    want := permissions._cedar_template_slots(est);
    select string_agg(format('%s (%s)', x.policy_id, (select string_agg(k, ', ' order by k) from jsonb_object_keys(x.slots) k)), ', ' order by x.policy_id)
    into bad
    from permissions.cedar_policies x
    where x.template_id = cedar_put_template.template_id
      and array(select k from jsonb_object_keys(x.slots) k order by k) <> want;
    if bad is not null then
        perform permissions._cedar_error('template_in_use',
            format('template %L has links that fill other slots than the new template''s %s: %s', template_id, array_to_string(want, ' and '), bad),
            hint => 'Keep the slots of the template, or first delete those links with select permissions.cedar_delete_policy(policy_id => ...).',
            p_detail => format('template_id=%L', template_id));
    end if;
    insert into permissions.cedar_templates as x (template_id, source, est, ast, annotations)
    values (cedar_put_template.template_id, cedar_put_template.template, est, nullif(c -> 'ast', 'null'), c -> 'annotations')
    on conflict on constraint cedar_templates_pkey do update
        set source = excluded.source, est = excluded.est, ast = excluded.ast, annotations = excluded.annotations;
    for l in select x.policy_id, x.slots from permissions.cedar_policies x where x.template_id = cedar_put_template.template_id loop
        perform permissions._cedar_link(l.policy_id, template_id, est, nullif(c -> 'ast', 'null'), c -> 'annotations', l.slots);
    end loop;
end;
$$;

-- Link a template: the policy policy_id is the template with its slots
-- filled, ?principal with principal and ?resource with resource (uids in
-- Cedar text, Type::"id"). Give a value for exactly the template's slots.
-- Linking an existing link's id again replaces that link.
create function permissions.cedar_link_template(policy_id text, template_id text, principal text default null, resource text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    t record;
    u record;
    s text;
    given text;
    vals jsonb := '{}';
    want text[];
begin
    if policy_id is null or template_id is null then
        perform permissions._cedar_error('null_argument',
            format('%s is required to link a template', case when policy_id is null then 'policy_id' else 'template_id' end),
            hint => 'select permissions.cedar_link_template(policy_id => ''alice-docs'', template_id => ''owner-access'', principal => ''User::"alice"'', resource => ''Folder::"docs"'');',
            p_detail => format('argument=%L', case when policy_id is null then 'policy_id' else 'template_id' end));
    end if;
    select x.est, x.ast, x.annotations into t from permissions.cedar_templates x where x.template_id = cedar_link_template.template_id;
    if not found then
        perform permissions._cedar_error('unknown_template', format('unknown template %L', template_id),
            hint => permissions._cedar_template_hint(template_id),
            p_detail => format('template_id=%L', template_id));
    end if;
    perform permissions._cedar_check_id(policy_id, 'link');
    want := permissions._cedar_template_slots(t.est);
    foreach s in array array['principal', 'resource'] loop
        given := case s when 'principal' then cedar_link_template.principal else cedar_link_template.resource end;
        if (('?' || s) = any(want)) <> (given is not null) then
            perform permissions._cedar_error('invalid_link',
                case when given is null then format('template %L has the slot ?%s, and the link gives it no value', template_id, s)
                     else format('template %L has no slot ?%s, and the link gives it %s', template_id, s, given) end,
                hint => format('Template %L has the slots %s: pass a value for each and nothing else, for example %s.', template_id,
                               array_to_string(want, ' and '),
                               (select string_agg(case w when '?principal' then 'principal => ''User::"alice"''' else 'resource => ''Folder::"docs"''' end, ', ')
                                from unnest(want) w)),
                p_detail => format('slot=%L', '?' || s));
        end if;
        if given is not null then
            select * into u from permissions._cedar_uid(given, s);
            vals := vals || jsonb_build_object('?' || s, jsonb_build_object('type', u.type, 'id', u.id));
        end if;
    end loop;
    perform permissions._cedar_link(policy_id, template_id, t.est, t.ast, t.annotations, vals);
end;
$$;

-- Delete a template that has no links.
create function permissions.cedar_delete_template(template_id text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    n bigint;
    first_links text;
begin
    select count(*), string_agg(x.policy_id, ', ' order by x.policy_id) filter (where x.r <= 5)
    into n, first_links
    from (select c.policy_id, row_number() over (order by c.policy_id) as r
          from permissions.cedar_policies c where c.template_id = cedar_delete_template.template_id) x;
    if n > 0 then
        perform permissions._cedar_error('template_in_use', format('template %L has %s link%s', template_id, n, case when n = 1 then '' else 's' end),
            hint => format('Delete its links first, with select permissions.cedar_delete_policy(policy_id => ...) for each: %s%s.',
                           first_links, case when n > 5 then ', ...' else '' end),
            p_detail => format('template_id=%L', template_id));
    end if;
    delete from permissions.cedar_templates x where x.template_id = cedar_delete_template.template_id;
    if not found then
        perform permissions._cedar_error(case when template_id is null then 'null_argument' else 'unknown_template' end,
            case when template_id is null then 'template_id is required to delete a template' else format('unknown template %L', template_id) end,
            hint => permissions._cedar_template_hint(template_id),
            p_detail => case when template_id is null then 'argument=''template_id''' else format('template_id=%L', template_id) end);
    end if;
end;
$$;

-- Every template, by id: its Cedar text (null when put as JSON), EST and
-- annotations. cedar_policies() lists the links, with their template_id.
create function permissions.cedar_templates()
returns table (template_id text, source text, est jsonb, annotations jsonb)
language sql stable security definer
set search_path = ''
as $$
    select t.template_id, t.source, t.est, t.annotations
    from permissions.cedar_templates t
    order by t.template_id
$$;

-- ----------------------------------------------------------------------------
-- Admin API: entities
-- ----------------------------------------------------------------------------

-- Put (insert or replace) entities: Cedar entity JSON, an array of {"uid":
-- {"type", "id"}, "attrs": {...}, "parents": [uids], "tags": {...}}. Entity
-- references in attrs and tags are {"__entity": {"type", "id"}}, extension
-- values {"__extn": {"fn", "arg"}}. An entity's attrs, tags and parents are
-- replaced as a whole. Parents need not exist. A cycle in the hierarchy
-- raises cedar:invalid_entity, as in Cedar.
create function permissions.cedar_put_entities(entities jsonb)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    v jsonb;
    n int;
    ec int[];
    ep int[];
    names jsonb[];
    first int[];
    color int[];
    stk int[];
    pos int[];
    top int;
    u int;
    w int;
    i int;
    cyc text;
    ts text[];
    ids text[];
    attrs jsonb[];
    tags jsonb[];
    cts text[];
    cis text[];
    pts text[];
    pis text[];
begin
    if entities is null then
        perform permissions._cedar_error('null_argument', 'entities is required to put entities',
            hint => 'select permissions.cedar_put_entities(entities => ''[{"uid": {"type": "User", "id": "alice"}, "attrs": {}, "parents": []}]''::jsonb);',
            p_detail => 'argument=''entities''');
    end if;
    v := permissions._cedar_entities_in(entities, 'entities', (permissions._cedar_limits()).put_entities);
    -- The statements below go from the put entities to the tables through
    -- index probes (lateral subqueries with offset 0 or limit 1): the planner
    -- would otherwise hash a whole table for a few entities.
    select array_agg(x ->> 't'), array_agg(x ->> 'i'), array_agg(x -> 'attrs'), array_agg(x -> 'tags')
    into ts, ids, attrs, tags
    from jsonb_array_elements(v) x;
    select coalesce(array_agg(x ->> 't'), '{}'), coalesce(array_agg(x ->> 'i'), '{}'),
           coalesce(array_agg(y ->> 0), '{}'), coalesce(array_agg(y ->> 1), '{}')
    into cts, cis, pts, pis
    from jsonb_array_elements(v) x cross join lateral jsonb_array_elements(x -> 'parents') y;
    insert into permissions.cedar_entities as e (type, id, attrs, tags)
    select * from unnest(ts, ids, attrs, tags)
    on conflict (type, id) do update set attrs = excluded.attrs, tags = excluded.tags;
    delete from permissions.cedar_entity_parents p
    using (select q.ctid as c
           from unnest(ts, ids) d(t, i)
           cross join lateral (select x.ctid, x.type, x.id, x.parent_type, x.parent_id
                               from permissions.cedar_entity_parents x
                               where x.type = d.t and x.id = d.i offset 0) q
           where (q.type, q.id, q.parent_type, q.parent_id) not in (select * from unnest(cts, cis, pts, pis))) z
    where p.ctid = z.c;
    insert into permissions.cedar_entity_parents (type, id, parent_type, parent_id)
    select * from unnest(cts, cis, pts, pis)
    on conflict do nothing;

    -- Cycles. A new cycle passes through an entity put here that is the
    -- parent of another entity (a new leaf can't close one). If there is
    -- such an entity, take the put entities and their ancestors, number them,
    -- list the parent edges among them, and search for a back edge
    -- (depth-first, iterative).
    if not exists (select 1 from unnest(ts, ids) d(t, i)
                   cross join lateral (select 1 from permissions.cedar_entity_parents p
                                       where p.parent_type = d.t and p.parent_id = d.i limit 1) q) then
        return;
    end if;
    with recursive s(t, i) as (
        select d.t collate "C", d.i collate "C" from unnest(ts, ids) d(t, i)
        union
        select q.parent_type, q.parent_id from s cross join lateral (
            select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
            where p.type = s.t and p.id = s.i offset 0) q
    ), nodes as (
        select s.t, s.i, (row_number() over (order by s.t, s.i))::int as no from s
    ), edges as (
        select c.no as c, q.no as p
        from nodes c
        join permissions.cedar_entity_parents e on e.type = c.t and e.id = c.i
        join nodes q on q.t = e.parent_type and q.i = e.parent_id
    )
    select (select count(*)::int from nodes),
           array(select jsonb_build_array(nodes.t, nodes.i) from nodes order by nodes.no),
           array(select edges.c from edges order by edges.c, edges.p),
           array(select edges.p from edges order by edges.c, edges.p)
    into n, names, ec, ep;
    if cardinality(ec) > 0 then
        first := array_fill(cardinality(ec) + 1, array[n + 1]);
        for i in reverse cardinality(ec) .. 1 loop
            first[ec[i]] := i;
        end loop;
        color := array_fill(0, array[n]);
        <<roots>>
        for u in 1 .. n loop
            continue when color[u] <> 0;
            stk := array[u];
            pos := array[first[u]];
            color[u] := 1;
            top := 1;
            while top > 0 loop
                i := pos[top];
                if i <= cardinality(ec) and ec[i] = stk[top] then
                    pos[top] := i + 1;
                    w := ep[i];
                    if color[w] = 1 then
                        cyc := permissions._cedar_uid_text(names[w] ->> 0, names[w] ->> 1);
                        exit roots;
                    elsif color[w] = 0 then
                        color[w] := 1;
                        top := top + 1;
                        stk[top] := w;
                        pos[top] := first[w];
                    end if;
                else
                    color[stk[top]] := 2;
                    top := top - 1;
                end if;
            end loop;
        end loop;
    end if;
    if cyc is not null then
        perform permissions._cedar_error('invalid_entity', format('the entity hierarchy has a cycle through %s', cyc),
            hint => 'An entity cannot be its own ancestor (Cedar rejects cycles): remove one of the parent links of the cycle.',
            p_detail => format('uid=%L', cyc));
    end if;
end;
$$;

-- Delete entities by uid: a JSON array of {"type", "id"} (or {"__entity":
-- ...}) or of Cedar text uids ("User::\"alice\""). Their attributes, tags and
-- parent links go with them; links from other entities to them stay (a
-- parent need not exist). Returns the number of entities deleted.
create function permissions.cedar_delete_entities(uids jsonb)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
    n bigint;
    bad jsonb;
    x jsonb;
    u record;
    ts text[] := '{}';
    ids text[] := '{}';
begin
    if uids is null or jsonb_typeof(uids) <> 'array' then
        perform permissions._cedar_error(case when uids is null then 'null_argument' else 'invalid_uid' end,
            case when uids is null then 'uids is required to delete entities'
                 else format('uids must be a JSON array of uids, got a JSON %s', jsonb_typeof(uids)) end,
            hint => 'select permissions.cedar_delete_entities(uids => ''[{"type": "User", "id": "alice"}, "Group::\"staff\""]''::jsonb);',
            p_detail => case when uids is null then 'argument=''uids''' else format('value=%L', left(uids::text, 200)) end);
    end if;
    select j into bad from jsonb_array_elements(uids) j
    where jsonb_typeof(j) <> 'string' and (permissions._cedar_uid_json(j)).type is null
    limit 1;
    if bad is not null then
        perform permissions._cedar_error('invalid_uid', format('invalid entity uid in uids: %s', left(bad::text, 200)),
            hint => 'A uid is {"type": "User", "id": "alice"} or Cedar text, "User::\"alice\"".',
            p_detail => format('value=%L', left(bad::text, 200)));
    end if;
    for x in select e from jsonb_array_elements(uids) e loop
        if jsonb_typeof(x) = 'string' then
            select * into u from permissions._cedar_uid(x #>> '{}', 'uids');
        else
            select * into u from permissions._cedar_uid_json(x);
        end if;
        ts := ts || u.type;
        ids := ids || u.id;
    end loop;
    delete from permissions.cedar_entities e
    using unnest(ts, ids) d(t, i)
    where e.type = d.t and e.id = d.i;
    get diagnostics n = row_count;
    return n;
end;
$$;

-- Stored entities as Cedar entity JSON, by type and id: all of them, one
-- type's, or (with ids) some of one type.
create function permissions.cedar_read_entities(type text default null, ids text[] default null)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
begin
    if ids is not null and cedar_read_entities.type is null then
        perform permissions._cedar_error('null_argument', 'type is required with ids',
            hint => 'select permissions.cedar_read_entities(type => ''User'', ids => ''{alice,bob}'');',
            p_detail => 'argument=''type''');
    end if;
    return coalesce((
        select jsonb_agg(jsonb_build_object(
                   'uid', jsonb_build_object('type', e.type, 'id', e.id),
                   'attrs', permissions._cedar_value_out(e.attrs),
                   'parents', coalesce((select jsonb_agg(jsonb_build_object('type', p.parent_type, 'id', p.parent_id)
                                                         order by p.parent_type, p.parent_id)
                                        from permissions.cedar_entity_parents p
                                        where p.type = e.type and p.id = e.id), '[]'),
                   'tags', permissions._cedar_value_out(e.tags))
                   order by e.type, e.id)
        from permissions.cedar_entities e
        where (cedar_read_entities.type is null or e.type = cedar_read_entities.type)
          and (ids is null or e.id = any(ids))), '[]');
end;
$$;

-- A uid as Cedar text, for resource arguments built from row ids:
--   resource => permissions.cedar_uid('Document', id::text)
-- It escapes " and \ and control characters, as uid() does in the JS client,
-- so an id never changes how the text parses. The type is not checked here;
-- a bad type gives cedar:invalid_uid when the uid is used. A null argument
-- gives null. Pure, so any role may call it (granted to PUBLIC below).
create function permissions.cedar_uid(type text, id text)
returns text
language sql immutable strict parallel safe security definer
set search_path = ''
as $$
    select permissions._cedar_uid_text(cedar_uid.type, cedar_uid.id)
$$;

-- Privileges. Every cedar_* function and table is for the owner and the
-- trusted roles the app grants (e.g. service_role), never PUBLIC, except the
-- two current-subject helpers, cedar_is_authorized_current and
-- cedar_list_resources_current, and cedar_uid, which the Privileges section at the end of
-- each file grants to PUBLIC after this. A fresh install revokes everything
-- from PUBLIC at the end of the file; this does the same for the objects
-- above when the upgrade script adds them.
do $$
declare
    f regprocedure;
    t regclass;
begin
    for f in select p.oid::regprocedure from pg_proc p
             where p.pronamespace = 'permissions'::regnamespace and p.proname ~ '^_?cedar_' loop
        execute format('revoke all on function %s from public', f);
    end loop;
    for t in select c.oid::regclass from pg_class c
             where c.relnamespace = 'permissions'::regnamespace and c.relkind = 'r' and c.relname ~ '^cedar_' loop
        execute format('revoke all on table %s from public', t);
    end loop;
end;
$$;
-- <<< cedar section: end

-- ============================================================================
-- Cleanup across models
-- ============================================================================

-- >>> cleanup section: begin
-- tools/sync-upgrade.sh copies this section into the upgrade script, where
-- it replaces 0.0.1's delete_subject; `or replace` keeps its privileges.
--
-- Forget a subject everywhere, and return the number of rows deleted:
--   rbac  its role assignments (user subjects only)
--   fga   every tuple naming it as user (any userset of it too) or as object
--   cedar the entity <subject_type>::"<subject_id>" (the principal type is
--         the subject type verbatim, e-cedar.md section 7.1); its parent
--         edges (its memberships) and the edges that name it as a parent
--         (the memberships in it), so nothing stays `in` a deleted entity;
--         and the template links whose ?principal or ?resource slot names
--         it, so a reused id gets none of their access. Static policies and
--         templates are the app's code and stay, as do references to the
--         entity in other entities' attrs and tags.
create or replace function permissions.delete_subject(subject_type text, subject_id text)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
    u jsonb := jsonb_build_object('type', subject_type, 'id', subject_id);
    total bigint := 0;
    n bigint;
begin
    delete from permissions.rbac_assignments a
    where delete_subject.subject_type = 'user' and a.user_id = delete_subject.subject_id;
    get diagnostics n = row_count;
    total := total + n;
    delete from permissions.fga_tuples t
    where (t.user_type = delete_subject.subject_type and t.user_id = delete_subject.subject_id)
       or (t.object_type = delete_subject.subject_type and t.object_id = delete_subject.subject_id);
    get diagnostics n = row_count;
    total := total + n;
    -- a link's scope rows in cedar_policy_scopes go with it (on delete cascade)
    delete from permissions.cedar_policies p
    where p.template_id is not null and (p.slots -> '?principal' = u or p.slots -> '?resource' = u);
    get diagnostics n = row_count;
    total := total + n;
    delete from permissions.cedar_entity_parents e
    where (e.type = delete_subject.subject_type and e.id = delete_subject.subject_id)
       or (e.parent_type = delete_subject.subject_type and e.parent_id = delete_subject.subject_id);
    get diagnostics n = row_count;
    total := total + n;
    delete from permissions.cedar_entities e
    where e.type = delete_subject.subject_type and e.id = delete_subject.subject_id;
    get diagnostics n = row_count;
    return total + n;
end;
$$;
-- <<< cleanup section: end

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
    permissions.fga_list_object_ids_current(text, text),
    permissions.cedar_is_authorized_current(text, text, jsonb, boolean),
    permissions.cedar_list_resources_current(text, text),
    permissions.cedar_uid(text, text)
to public;

-- Everything else (role and model management, tuple writes, explicit-subject
-- checks and lists) is for the owner and whichever trusted roles the app
-- grants, e.g. service_role.
