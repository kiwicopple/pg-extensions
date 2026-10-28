/*
 * pg_permissions prototype: Design B (policy-first, Cedar-shaped) + rbac preset
 *
 * See ../designs/b-policy-first.md. This is a prototype for testing and
 * benchmarking, not the extension itself. Run the test suite against it with:
 *
 *   ./test/run.sh --impl prototypes/b-policy-first.sql
 *
 * Two concepts:
 *   facts     entities (attrs), parents (user in team, folder in org), role
 *             grants (principal holds role on resource, optional expiry), with
 *             two closures kept up to date on write: ancestors (parents) and
 *             role_closure (role implication).
 *   policies  permit / forbid rows: principal scope, actions, resource type,
 *             optional "role on anchor" (anchor = the resource itself, or a
 *             parent of type `via`), optional condition. Forbid beats permit.
 *
 * Evaluation is flat joins over the closures (no recursion at read time):
 *   can()   per-row check: matches policies against one resource.
 *   ids()   partial evaluation for RLS: the resource ids (via => null) or the
 *           parent ids of type `via` (a column such as folder_id) for which a
 *           resource would be permitted. Computed once per query.
 */

create schema if not exists permissions;

-- ============================================================================
-- Facts
-- ============================================================================

-- Attributes for principals (and other entities); only read by conditions.
create table permissions.entities (
    type  text  not null,
    id    text  not null,
    attrs jsonb not null default '{}',
    primary key (type, id)
);

-- "child is in parent": user in team, team in team, folder in org, folder in folder.
create table permissions.parents (
    child_type  text not null,
    child_id    text not null,
    parent_type text not null,
    parent_id   text not null,
    primary key (child_type, child_id, parent_type, parent_id),
    check ((child_type, child_id) <> (parent_type, parent_id))
);
create index on permissions.parents (parent_type, parent_id);

-- Transitive closure of parents (depth = shortest path), maintained by the
-- triggers below. Cycles and paths deeper than 10 are rejected on write.
create table permissions.ancestors (
    child_type    text     not null,
    child_id      text     not null,
    ancestor_type text     not null,
    ancestor_id   text     not null,
    depth         smallint not null check (depth between 1 and 10),
    primary key (child_type, child_id, ancestor_type, ancestor_id)
);
create index on permissions.ancestors (ancestor_type, ancestor_id, child_type);

-- Roles are declared per resource type, so typos fail at grant time.
create table permissions.roles (
    resource_type text not null,
    role          text not null,
    primary key (resource_type, role)
);

create table permissions.role_implies (
    resource_type text not null,
    role          text not null,   -- holding this role ...
    implies       text not null,   -- ... also gives this one
    primary key (resource_type, role, implies),
    foreign key (resource_type, role)    references permissions.roles on delete cascade,
    foreign key (resource_type, implies) references permissions.roles on delete cascade
);

-- Reflexive transitive closure of role_implies. Tiny; rebuilt per type on change.
create table permissions.role_closure (
    resource_type text not null,
    role          text not null,   -- granted role
    implied       text not null,   -- role it satisfies (includes itself)
    primary key (resource_type, role, implied)
);
create index on permissions.role_closure (resource_type, implied);

-- "principal holds role on resource". The principal may be a user or a group.
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

-- ============================================================================
-- Policies
-- ============================================================================

create table permissions.policies (
    id                  bigint generated always as identity primary key,
    name                text not null unique,
    effect              text not null default 'permit' check (effect in ('permit', 'forbid')),
    -- principal scope
    principal_type      text default 'user',   -- null = any type
    principal_id        text,                  -- optional: one specific principal
    principal_in_type   text,                  -- optional: principal must be in this group
    principal_in_id     text,
    -- action and resource scope
    actions             text[] not null check (cardinality(actions) > 0),
    resource_type       text not null,
    resource_id         text,                  -- optional: one specific resource
    -- relationship requirement
    roles               text[],                -- principal must hold one of these on the anchor
    via                 text,                  -- anchor: null = the resource itself, else a parent type
    -- condition as written, and its two halves (split on write, see _split_condition)
    condition           jsonb,
    principal_condition jsonb,                 -- principal.*, context.*, now: evaluated once per query
    resource_condition  jsonb,                 -- resource.*: per row (can) or compiled into RLS
    managed_by          text,                  -- 'rbac' for policies the preset generates
    enabled             boolean not null default true,
    check ((principal_in_type is null) = (principal_in_id is null)),
    check (via is null or roles is not null)
);

-- ============================================================================
-- Identity (contract: test/spec/01_identity.sql)
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
-- Closure maintenance
-- ============================================================================

-- Closures are computed from what the writing transaction can see after it
-- takes the closure lock. Under repeatable read that snapshot predates the
-- lock, so a concurrent writer's edges would be missed. Read committed (fresh
-- snapshot per statement) and serializable (conflicts abort) are both safe.
create function permissions._guard_isolation()
returns void
language plpgsql
set search_path = ''
as $$
begin
    if current_setting('transaction_isolation') = 'repeatable read' then
        raise exception 'permissions: changing parents or roles is not supported under repeatable read'
            using errcode = '0A000',
                  hint = 'Use read committed or serializable for permission writes.';
    end if;
end;
$$;

create function permissions._parents_after_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_depth int;
begin
    perform permissions._guard_isolation();
    perform pg_advisory_xact_lock(hashtext('permissions.closure'));

    if exists (
        select 1 from permissions.ancestors
        where child_type = new.parent_type and child_id = new.parent_id
          and ancestor_type = new.child_type and ancestor_id = new.child_id
    ) then
        raise exception 'permissions: % % is inside % %, so making it a parent would create a cycle',
            new.parent_type, new.parent_id, new.child_type, new.child_id
            using errcode = '23514';
    end if;

    with d(depth) as (
        select 0
        union all
        select depth from permissions.ancestors where ancestor_type = new.child_type and ancestor_id = new.child_id
    ), a(depth) as (
        select 0
        union all
        select depth from permissions.ancestors where child_type = new.parent_type and child_id = new.parent_id
    )
    select max(d.depth + 1 + a.depth) into v_depth from d, a;
    if v_depth > 10 then
        raise exception 'permissions: nesting % % in % % would be % levels deep (max 10)',
            new.child_type, new.child_id, new.parent_type, new.parent_id, v_depth
            using errcode = '23514';
    end if;

    -- every descendant-or-self of the child gets every ancestor-or-self of the parent
    insert into permissions.ancestors (child_type, child_id, ancestor_type, ancestor_id, depth)
    with d(t, id, depth) as (
        select new.child_type, new.child_id, 0
        union all
        select child_type, child_id, depth from permissions.ancestors
        where ancestor_type = new.child_type and ancestor_id = new.child_id
    ), a(t, id, depth) as (
        select new.parent_type, new.parent_id, 0
        union all
        select ancestor_type, ancestor_id, depth from permissions.ancestors
        where child_type = new.parent_type and child_id = new.parent_id
    )
    select d.t, d.id, a.t, a.id, d.depth + 1 + a.depth from d, a
    on conflict (child_type, child_id, ancestor_type, ancestor_id)
    do update set depth = least(ancestors.depth, excluded.depth);

    return null;
end;
$$;

-- Removing child -> parent can only change the closure of the child and its
-- descendants. Delete their rows and rebuild them from parents.
create function permissions._parents_after_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_types text[];
    v_ids   text[];
begin
    perform permissions._guard_isolation();
    perform pg_advisory_xact_lock(hashtext('permissions.closure'));

    select array_agg(t), array_agg(id) into v_types, v_ids
    from (
        select old.child_type, old.child_id
        union
        select child_type, child_id from permissions.ancestors
        where ancestor_type = old.child_type and ancestor_id = old.child_id
    ) f(t, id);

    delete from permissions.ancestors a
    using unnest(v_types, v_ids) f(t, id)
    where a.child_type = f.t and a.child_id = f.id;

    insert into permissions.ancestors (child_type, child_id, ancestor_type, ancestor_id, depth)
    with recursive walk(ct, cid, at, aid, depth) as (
        select f.t, f.id, p.parent_type, p.parent_id, 1
        from unnest(v_types, v_ids) f(t, id)
        join permissions.parents p on p.child_type = f.t and p.child_id = f.id
      union all
        select w.ct, w.cid, p.parent_type, p.parent_id, w.depth + 1
        from walk w
        join permissions.parents p on p.child_type = w.at and p.child_id = w.aid
        where w.depth < 10
    )
    select ct, cid, at, aid, min(depth) from walk group by ct, cid, at, aid;

    return null;
end;
$$;

create function permissions._parents_no_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    raise exception 'permissions: parents rows are immutable; remove and add instead' using errcode = '0A000';
end;
$$;

create trigger parents_closure_insert after insert on permissions.parents
    for each row execute function permissions._parents_after_insert();
create trigger parents_closure_delete after delete on permissions.parents
    for each row execute function permissions._parents_after_delete();
create trigger parents_no_update before update on permissions.parents
    for each row execute function permissions._parents_no_update();

create function permissions._rebuild_role_closure(p_type text)
returns void
language plpgsql
set search_path = ''
as $$
begin
    perform permissions._guard_isolation();
    perform pg_advisory_xact_lock(hashtext('permissions.roles'));
    delete from permissions.role_closure where resource_type = p_type;
    insert into permissions.role_closure (resource_type, role, implied)
    with recursive c(role, implied) as (
        select role, role from permissions.roles where resource_type = p_type
      union
        select c.role, ri.implies
        from c join permissions.role_implies ri on ri.resource_type = p_type and ri.role = c.implied
    )
    select p_type, role, implied from c;
end;
$$;

-- ============================================================================
-- Conditions: a jsonb AST, interpreted without dynamic SQL
--
--   {"op": "==", "left": {"var": "resource.status"}, "right": "published"}
--   ops: and / or (args: [...]), not (arg), has (var), ==, !=, <, <=, >, >=, in
--   vars: principal.id, principal.type, principal.attrs.*, resource.<attr>,
--         context.* (permissions.context setting; context.jwt = JWT claims), now
-- A comparison with a missing or null operand is false.
-- ============================================================================

create function permissions._cond_value(p_x jsonb, p_env jsonb)
returns jsonb
language sql immutable
set search_path = ''
as $$
    select case
        when jsonb_typeof(p_x) = 'object' and p_x ? 'var'
            then nullif(p_env #> string_to_array(p_x ->> 'var', '.'), 'null'::jsonb)
        else nullif(p_x, 'null'::jsonb)
    end
$$;

create function permissions._eval(p_cond jsonb, p_env jsonb)
returns boolean
language plpgsql immutable
set search_path = ''
as $$
declare
    v_op text := p_cond ->> 'op';
    v_x  jsonb;
    l    jsonb;
    r    jsonb;
begin
    if p_cond is null then
        return true;
    end if;
    case v_op
        when 'and' then
            for v_x in select * from jsonb_array_elements(p_cond -> 'args') loop
                if not permissions._eval(v_x, p_env) then return false; end if;
            end loop;
            return true;
        when 'or' then
            for v_x in select * from jsonb_array_elements(p_cond -> 'args') loop
                if permissions._eval(v_x, p_env) then return true; end if;
            end loop;
            return false;
        when 'not' then
            return not permissions._eval(p_cond -> 'arg', p_env);
        when 'has' then
            return permissions._cond_value(jsonb_build_object('var', p_cond -> 'var'), p_env) is not null;
        else
            l := permissions._cond_value(p_cond -> 'left', p_env);
            r := permissions._cond_value(p_cond -> 'right', p_env);
            if l is null or r is null then
                return false;
            end if;
            case v_op
                when '==' then return l = r;
                when '!=' then return l <> r;
                when '<'  then return l < r;
                when '<=' then return l <= r;
                when '>'  then return l > r;
                when '>=' then return l >= r;
                when 'in' then return jsonb_typeof(r) = 'array' and r @> jsonb_build_array(l);
                else raise exception 'permissions: unknown condition operator %', v_op using errcode = '22023';
            end case;
    end case;
end;
$$;

-- Compile a resource condition (resource.* vars only) to a SQL predicate over
-- the table's columns, for rls_expression. resource.<attr> is column <attr>.
-- Comparisons go through to_jsonb so they mean exactly what _eval means.
create function permissions._cond_sql(p_cond jsonb)
returns text
language plpgsql immutable
set search_path = ''
as $$
declare
    v_op text := p_cond ->> 'op';
    v_parts text[];
    v_x jsonb;
    l text;
    r text;
begin
    case v_op
        when 'and', 'or' then
            for v_x in select * from jsonb_array_elements(p_cond -> 'args') loop
                v_parts := v_parts || permissions._cond_sql(v_x);
            end loop;
            return '(' || array_to_string(v_parts, ' ' || v_op || ' ') || ')';
        when 'not' then
            return '(not ' || permissions._cond_sql(p_cond -> 'arg') || ')';
        when 'has' then
            return format('(%I is not null)', substr(p_cond ->> 'var', 10));
        else
            l := case when jsonb_typeof(p_cond -> 'left') = 'object' and p_cond -> 'left' ? 'var'
                      then format('to_jsonb(%I)', substr(p_cond -> 'left' ->> 'var', 10))
                      else format('%L::jsonb', (p_cond -> 'left')::text) end;
            r := case when jsonb_typeof(p_cond -> 'right') = 'object' and p_cond -> 'right' ? 'var'
                      then format('to_jsonb(%I)', substr(p_cond -> 'right' ->> 'var', 10))
                      else format('%L::jsonb', (p_cond -> 'right')::text) end;
            return case v_op
                when '==' then format('coalesce(%s = %s, false)', l, r)
                when '!=' then format('coalesce(%s <> %s, false)', l, r)
                when '<'  then format('coalesce(%s < %s, false)', l, r)
                when '<=' then format('coalesce(%s <= %s, false)', l, r)
                when '>'  then format('coalesce(%s > %s, false)', l, r)
                when '>=' then format('coalesce(%s >= %s, false)', l, r)
                when 'in' then format('coalesce(%s @> jsonb_build_array(%s), false)', r, l)
            end;
    end case;
end;
$$;

-- Split a condition into its row-independent half (principal/context/now,
-- evaluated once per query) and its resource half (per row). Top-level `and`
-- conjuncts are sorted by the vars they read; a conjunct that reads both
-- kinds can't be partially evaluated and is rejected.
create function permissions._split_condition(p_cond jsonb, out principal_part jsonb, out resource_part jsonb)
language plpgsql immutable
set search_path = ''
as $$
declare
    v_conj jsonb;
    v_vars text[];
    v_p jsonb[] := '{}';
    v_r jsonb[] := '{}';
    v_bad text;
begin
    if p_cond is null then
        return;
    end if;
    for v_conj in
        select x from jsonb_array_elements(case when p_cond ->> 'op' = 'and' then p_cond -> 'args'
                                                else jsonb_build_array(p_cond) end) x
    loop
        v_vars := array(select jsonb_path_query(v_conj, 'lax $.**.var') #>> '{}');
        select v into v_bad from unnest(v_vars) v
        where not (v ~ '^resource\.[A-Za-z_][A-Za-z0-9_]*$' or v ~ '^principal\.(id|type|attrs(\..+)?)$'
                   or v ~ '^context(\..+)?$' or v = 'now')
        limit 1;
        if v_bad is not null then
            raise exception 'permissions: unknown condition variable %', v_bad
                using errcode = '22023', hint = 'Use resource.<column>, principal.id, principal.type, principal.attrs.*, context.* or now.';
        end if;
        if exists (select 1 from unnest(v_vars) v where v like 'resource.%') then
            if exists (select 1 from unnest(v_vars) v where v not like 'resource.%') then
                raise exception 'permissions: a condition term mixes resource and non-resource variables'
                    using errcode = '22023', hint = 'Write it as an "and" of terms that each read only resource.* or only principal/context.';
            end if;
            v_r := v_r || v_conj;
        else
            v_p := v_p || v_conj;
        end if;
    end loop;
    principal_part := case cardinality(v_p) when 0 then null when 1 then v_p[1]
                      else jsonb_build_object('op', 'and', 'args', to_jsonb(v_p)) end;
    resource_part  := case cardinality(v_r) when 0 then null when 1 then v_r[1]
                      else jsonb_build_object('op', 'and', 'args', to_jsonb(v_r)) end;
end;
$$;

create function permissions._env(p_subject_type text, p_subject_id text, p_resource jsonb)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
    select jsonb_build_object(
        'principal', jsonb_build_object(
            'type', p_subject_type, 'id', p_subject_id,
            'attrs', coalesce((select attrs from permissions.entities where type = p_subject_type and id = p_subject_id), '{}')),
        'resource', coalesce(p_resource, '{}'),
        'context', coalesce(nullif(current_setting('permissions.context', true), '')::jsonb, '{}')
                   || jsonb_build_object('jwt', coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}')),
        'now', to_jsonb(now()))
$$;

-- ============================================================================
-- Evaluator
-- ============================================================================

-- Policies whose principal scope and row-independent condition match the
-- subject, for one action on one resource type. The single place where
-- principal matching is defined; can(), ids() and who_can() all use it.
create function permissions._candidate_policies(p_subject_type text, p_subject_id text, p_action text, p_type text)
returns setof permissions.policies
language plpgsql stable security definer
set search_path = ''
as $$
declare
    v_env jsonb;
begin
    if p_subject_id is null then
        return;
    end if;
    if exists (select 1 from permissions.policies p
               where p.enabled and p.resource_type = p_type and p_action = any (p.actions)
                 and p.principal_condition is not null) then
        v_env := permissions._env(p_subject_type, p_subject_id, null);
    end if;
    return query
    select p.*
    from permissions.policies p
    where p.enabled and p.resource_type = p_type and p_action = any (p.actions)
      and (p.principal_type is null or p.principal_type = p_subject_type)
      and (p.principal_id is null or p.principal_id = p_subject_id)
      and (p.principal_in_type is null
           or (p.principal_in_type = p_subject_type and p.principal_in_id = p_subject_id)
           or exists (select 1 from permissions.ancestors a
                      where a.child_type = p_subject_type and a.child_id = p_subject_id
                        and a.ancestor_type = p.principal_in_type and a.ancestor_id = p.principal_in_id))
      and case when p.principal_condition is null then true
               else permissions._eval(p.principal_condition, v_env) end;
end;
$$;

-- The keys of a resource jsonb that are read as the row's parents: a key that
-- names a type ("folder": <id>) is the parent of that type, except a key that
-- names a principal type (one a policy scopes principals by, or that holds a
-- grant), unless some policy on p_type anchors via that type. Principal types
-- live in the parents table as group membership (user in team in org), so
-- {"user": <author>} read as a parent would make the author's teams and orgs
-- the row's anchors. Null values name no parent.
create function permissions._parent_keys(p_type text, p_resource jsonb)
returns table (parent_type text, parent_id text)
language sql stable
set search_path = ''
as $$
    select j.key, j.value
    from jsonb_each_text(coalesce(p_resource, '{}')) j
    where j.value is not null
      and (exists (select 1 from permissions.policies p where p.enabled and p.resource_type = p_type and p.via = j.key)
           or not (exists (select 1 from permissions.policies p where j.key in (p.principal_type, p.principal_in_type))
                   or exists (select 1 from permissions.role_grants g where g.principal_type = j.key)))
$$;

-- Every policy that matches one concrete resource. p_resource carries the
-- row's attributes; its parent keys (_parent_keys, e.g. "folder") are also
-- read as the resource's parents, and those parents' own ancestors count too.
-- Parents stored in the parents table count as well.
--
-- Fails closed: a forbid that could apply to the subject (principal scope
-- matches, and it needs no role or the subject holds one of its roles on some
-- resource of its anchor type) must have its inputs. If it reads a
-- resource.<attr> that isn't a key of p_resource, or anchors via a parent
-- type that p_resource doesn't name and the stored ancestors don't supply,
-- this raises 22023 instead of letting the forbid silently not match. A key
-- with a null value means "the row has none" and counts as given.
create function permissions._matches(
    p_subject_type text, p_subject_id text, p_action text,
    p_type text, p_id text, p_resource jsonb default '{}'
)
returns table (effect text, policy text, anchor_type text, anchor_id text, granted_role text,
               grantee_type text, grantee_id text)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
    v_env jsonb;
    v_res jsonb := coalesce(p_resource, '{}');
    v_policy text;
    v_input text;
begin
    if p_subject_id is null then
        return;
    end if;
    if exists (select 1 from permissions.policies p
               where p.enabled and p.effect = 'forbid' and p.resource_type = p_type and p_action = any (p.actions)
                 and (p.via is not null or p.resource_condition is not null)) then
        select p.name, m.input into v_policy, v_input
        from permissions._candidate_policies(p_subject_type, p_subject_id, p_action, p_type) p
        cross join lateral (
            -- an attribute the resource condition reads
            select format('resource.%s', a.k) as input
            from (select distinct substr(x #>> '{}', 10) as k
                  from jsonb_path_query(p.resource_condition, 'lax $.**.var') x) a
            where p.resource_condition is not null and not (v_res ? a.k)
            union all
            -- the parent type it anchors on
            select format('a %s parent', p.via)
            where p.via is not null and not (v_res ? p.via)
              and not exists (select 1 from permissions.ancestors a
                              where a.child_type = p_type and a.child_id = p_id and a.ancestor_type = p.via)
              and not exists (select 1 from permissions._parent_keys(p_type, v_res) k
                              join permissions.ancestors a on a.child_type = k.parent_type and a.child_id = k.parent_id
                              where a.ancestor_type = p.via)
            limit 1
        ) m
        where p.effect = 'forbid' and (p.resource_id is null or p.resource_id = p_id)
          and (p.roles is null or exists (
                select 1
                from (select p_subject_type, p_subject_id
                      union all
                      select a.ancestor_type, a.ancestor_id from permissions.ancestors a
                      where a.child_type = p_subject_type and a.child_id = p_subject_id) s(t, id)
                join permissions.role_grants g
                  on g.principal_type = s.t and g.principal_id = s.id and g.resource_type = coalesce(p.via, p_type)
                join permissions.role_closure rc
                  on rc.resource_type = g.resource_type and rc.role = g.role and rc.implied = any (p.roles)
                where g.expires_at is null or g.expires_at > now()))
        limit 1;
        if v_policy is not null then
            raise exception 'permissions: forbid "%" needs % of %:%, which the resource argument does not include', v_policy, v_input, p_type, p_id
                using errcode = '22023',
                      hint = 'Pass the row''s parent columns and the attributes forbids read in resource; a null value means the row has none.';
        end if;
    end if;
    if exists (select 1 from permissions.policies p
               where p.enabled and p.resource_type = p_type and p_action = any (p.actions)
                 and p.resource_condition is not null) then
        v_env := permissions._env(p_subject_type, p_subject_id, p_resource);
    end if;
    return query
    with pol as (
        select p.effect, p.name, p.roles, p.via
        from permissions._candidate_policies(p_subject_type, p_subject_id, p_action, p_type) p
        where (p.resource_id is null or p.resource_id = p_id)
          and case when p.resource_condition is null then true
                   else permissions._eval(p.resource_condition, v_env) end
    ),
    subj(t, id) as (
        select p_subject_type, p_subject_id
        union all
        select a.ancestor_type, a.ancestor_id from permissions.ancestors a
        where a.child_type = p_subject_type and a.child_id = p_subject_id
    ),
    anc(t, id, self) as (
        select p_type, p_id, true where p_id is not null
        union all
        select a.ancestor_type, a.ancestor_id, false from permissions.ancestors a
        where a.child_type = p_type and a.child_id = p_id
        union all
        select k.parent_type, k.parent_id, false from permissions._parent_keys(p_type, p_resource) k
        union all
        select a.ancestor_type, a.ancestor_id, false
        from permissions._parent_keys(p_type, p_resource) k
        join permissions.ancestors a on a.child_type = k.parent_type and a.child_id = k.parent_id
    )
    select pol.effect, pol.name, anc.t, anc.id, g.role, g.principal_type, g.principal_id
    from pol
    join anc on (pol.via is null and anc.self) or (pol.via = anc.t and not anc.self)
    join subj on true
    join permissions.role_grants g
      on g.principal_type = subj.t and g.principal_id = subj.id
     and g.resource_type = anc.t and g.resource_id = anc.id
    join permissions.role_closure rc
      on rc.resource_type = g.resource_type and rc.role = g.role and rc.implied = any (pol.roles)
    where pol.roles is not null
      and (g.expires_at is null or g.expires_at > now())
    union all
    select pol.effect, pol.name, null, null, null, null, null
    from pol where pol.roles is null;
end;
$$;

-- Partial evaluation of one effect for RLS. Only policies whose resource
-- condition equals p_rcond take part (null = unconditioned policies).
--   p_via null: ids of p_type resources matched through their own grants,
--               their parents-table ancestors, or a resource_id policy.
--   p_via 'x':  ids of x-typed parents such that a resource whose direct
--               parent is that id is matched (the parent itself, or any of
--               its ancestors, is the anchor).
create function permissions._ids(
    p_subject_type text, p_subject_id text, p_effect text,
    p_action text, p_type text, p_via text, p_rcond jsonb
)
returns text[]
language plpgsql stable security definer
set search_path = ''
as $$
declare
    r text[];
begin
    if p_subject_id is null then
        return '{}';
    end if;
    if not exists (select 1 from permissions.policies p
                   where p.enabled and p.effect = p_effect and p.resource_type = p_type and p_action = any (p.actions)) then
        return '{}';
    end if;
    with pol as (
        select p.roles, p.via, p.resource_type, p.resource_id
        from permissions._candidate_policies(p_subject_type, p_subject_id, p_action, p_type) p
        where p.effect = p_effect and p.resource_condition is not distinct from p_rcond
    ),
    subj(t, id) as (
        select p_subject_type, p_subject_id
        union all
        select a.ancestor_type, a.ancestor_id from permissions.ancestors a
        where a.child_type = p_subject_type and a.child_id = p_subject_id
    ),
    held(t, id, implied) as (
        select g.resource_type, g.resource_id, rc.implied
        from subj
        join permissions.role_grants g on g.principal_type = subj.t and g.principal_id = subj.id
        join permissions.role_closure rc on rc.resource_type = g.resource_type and rc.role = g.role
        where (g.expires_at is null or g.expires_at > now())
    )
    select coalesce(array_agg(distinct x), '{}') into r
    from (
        -- the resource itself is the anchor
        select h.id from pol join held h on h.t = pol.resource_type and h.implied = any (pol.roles)
        where p_via is null and pol.via is null and pol.roles is not null
          and (pol.resource_id is null or pol.resource_id = h.id)
        union all
        -- a policy naming one resource, no role needed (e.g. public access)
        select pol.resource_id from pol
        where p_via is null and pol.roles is null and pol.resource_id is not null
        union all
        -- resources linked by parents rows below an anchor the subject holds
        select a.child_id from pol
        join held h on h.t = pol.via and h.implied = any (pol.roles)
        join permissions.ancestors a on a.ancestor_type = h.t and a.ancestor_id = h.id and a.child_type = pol.resource_type
        where p_via is null and pol.via is not null
          and (pol.resource_id is null or pol.resource_id = a.child_id)
        union all
        -- projection onto a parent column: the held anchor itself ...
        select h.id from pol join held h on h.t = pol.via and h.implied = any (pol.roles)
        where p_via is not null and pol.via = p_via and pol.resource_id is null
        union all
        -- ... and every p_via-typed descendant of a held anchor
        select a.child_id from pol
        join held h on h.t = pol.via and h.implied = any (pol.roles)
        join permissions.ancestors a on a.ancestor_type = h.t and a.ancestor_id = h.id and a.child_type = p_via
        where p_via is not null and pol.via is not null and pol.resource_id is null
    ) s(x);
    return r;
end;
$$;

-- Does a policy with no role and no resource restriction match the subject?
create function permissions._all(
    p_subject_type text, p_subject_id text, p_effect text,
    p_action text, p_type text, p_rcond jsonb
)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select exists (
        select 1
        from permissions._candidate_policies(p_subject_type, p_subject_id, p_action, p_type) p
        where p.effect = p_effect and p.roles is null and p.resource_id is null
          and p.resource_condition is not distinct from p_rcond
    )
$$;

-- ---------------------------------------------------------------------------
-- Explicit-subject API (admin only: revoked from public below)
-- ---------------------------------------------------------------------------

create function permissions.can_for(
    p_subject_type text, p_subject_id text, p_action text,
    p_type text, p_id text, p_resource jsonb default '{}'
)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select coalesce(bool_or(m.effect = 'permit') and not bool_or(m.effect = 'forbid'), false)
    from permissions._matches(p_subject_type, p_subject_id, p_action, p_type, p_id, p_resource) m
$$;

-- Net of unconditioned forbids for the same projection, so the list is what
-- the subject can actually reach (resource-level forbids are subtracted from
-- resource ids; parent-level forbids from parent ids).
create function permissions.ids_for(
    p_subject_type text, p_subject_id text, p_action text, p_type text,
    p_via text default null, p_resource_condition jsonb default null
)
returns text[]
language plpgsql stable security definer
set search_path = ''
as $$
declare
    r text[];
    d text[];
begin
    if p_subject_id is null
       or permissions._all(p_subject_type, p_subject_id, 'forbid', p_action, p_type, null) then
        return '{}';
    end if;
    r := permissions._ids(p_subject_type, p_subject_id, 'permit', p_action, p_type, p_via, p_resource_condition);
    if cardinality(r) > 0 then
        d := permissions._ids(p_subject_type, p_subject_id, 'forbid', p_action, p_type, p_via, null);
        if cardinality(d) > 0 then
            r := array(select unnest(r) except select unnest(d));
        end if;
    end if;
    return r;
end;
$$;

create function permissions.denied_ids_for(
    p_subject_type text, p_subject_id text, p_action text, p_type text,
    p_via text default null, p_resource_condition jsonb default null
)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select permissions._ids(p_subject_type, p_subject_id, 'forbid', p_action, p_type, p_via, p_resource_condition)
$$;

create function permissions.allows_all_for(
    p_subject_type text, p_subject_id text, p_action text, p_type text,
    p_resource_condition jsonb default null
)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions._all(p_subject_type, p_subject_id, 'permit', p_action, p_type, p_resource_condition)
       and not permissions._all(p_subject_type, p_subject_id, 'forbid', p_action, p_type, null)
$$;

create function permissions.denies_all_for(
    p_subject_type text, p_subject_id text, p_action text, p_type text,
    p_resource_condition jsonb default null
)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions._all(p_subject_type, p_subject_id, 'forbid', p_action, p_type, p_resource_condition)
$$;

-- Why does (or doesn't) the subject have access? Every matching policy, with
-- the grant that matched it. Forbid rows win.
create function permissions.explain(
    p_subject_type text, p_subject_id text, p_action text,
    p_type text, p_id text, p_resource jsonb default '{}'
)
returns table (effect text, policy text, matched_grant jsonb)
language sql stable security definer
set search_path = ''
as $$
    select m.effect, m.policy,
           case when m.anchor_type is not null then jsonb_build_object(
               'principal', m.grantee_type || ':' || m.grantee_id, 'role', m.granted_role,
               'on', m.anchor_type || ':' || m.anchor_id) end
    from permissions._matches(p_subject_type, p_subject_id, p_action, p_type, p_id, p_resource) m
    order by m.effect desc, m.policy
$$;

-- Is child inside parent, directly or transitively? (Cedar's `in`.)
create function permissions.is_in(p_child_type text, p_child_id text, p_parent_type text, p_parent_id text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select exists (
        select 1 from permissions.ancestors
        where child_type = p_child_type and child_id = p_child_id
          and ancestor_type = p_parent_type and ancestor_id = p_parent_id
    )
$$;

-- Who can do action on one resource? Runs each permit policy in reverse
-- (grants on the anchors, expanded down through group membership), then keeps
-- only candidates for whom can_for agrees, so forbids and conditions apply.
-- A policy with no principal restriction returns one ('*', '*') row.
create function permissions.who_can(p_action text, p_type text, p_id text, p_resource jsonb default '{}')
returns table (subject_type text, subject_id text, policy text)
language sql stable security definer
set search_path = ''
as $$
    with pol as (
        select p.* from permissions.policies p
        where p.enabled and p.effect = 'permit' and p.resource_type = p_type and p_action = any (p.actions)
          and (p.resource_id is null or p.resource_id = p_id)
    ),
    anc(t, id, self) as (
        select p_type, p_id, true
        union all
        select a.ancestor_type, a.ancestor_id, false from permissions.ancestors a
        where a.child_type = p_type and a.child_id = p_id
        union all
        select k.parent_type, k.parent_id, false from permissions._parent_keys(p_type, p_resource) k
        union all
        select a.ancestor_type, a.ancestor_id, false
        from permissions._parent_keys(p_type, p_resource) k
        join permissions.ancestors a on a.child_type = k.parent_type and a.child_id = k.parent_id
    ),
    grantees as (
        select pol.name, pol.principal_type as want, g.principal_type as gt, g.principal_id as gi
        from pol
        join anc on (pol.via is null and anc.self) or (pol.via = anc.t and not anc.self)
        join permissions.role_grants g on g.resource_type = anc.t and g.resource_id = anc.id
        join permissions.role_closure rc
          on rc.resource_type = g.resource_type and rc.role = g.role and rc.implied = any (pol.roles)
        where pol.roles is not null and (g.expires_at is null or g.expires_at > now())
    ),
    cand(st, sid, name) as (
        select gt, gi, name from grantees where want is null or gt = want
        union
        select a.child_type, a.child_id, g.name
        from grantees g
        join permissions.ancestors a on a.ancestor_type = g.gt and a.ancestor_id = g.gi
        where g.want is null or a.child_type = g.want
        union
        select coalesce(pol.principal_type, '*'), pol.principal_id, pol.name
        from pol where pol.roles is null and pol.principal_id is not null
        union
        select a.child_type, a.child_id, pol.name
        from pol
        join permissions.ancestors a on a.ancestor_type = pol.principal_in_type and a.ancestor_id = pol.principal_in_id
        where pol.roles is null and pol.principal_id is null
          and (pol.principal_type is null or a.child_type = pol.principal_type)
        union
        select '*', '*', pol.name
        from pol where pol.roles is null and pol.principal_id is null and pol.principal_in_type is null
    )
    select c.st, c.sid, c.name
    from cand c
    cross join lateral (
        select bool_or(m.effect = 'permit' and m.policy = c.name) as hit,
               bool_or(m.effect = 'forbid') as denied
        from permissions._matches(c.st, c.sid, p_action, p_type, p_id, p_resource) m
        where c.st <> '*'
    ) x
    where c.st = '*' or (x.hit and not coalesce(x.denied, false))
$$;

-- ---------------------------------------------------------------------------
-- Current-subject API (safe for clients and RLS policies)
-- ---------------------------------------------------------------------------

create function permissions.can(p_action text, p_type text, p_id text, p_resource jsonb default '{}')
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions.can_for(permissions.current_subject_type(), permissions.current_subject_id(),
                               p_action, p_type, p_id, p_resource)
$$;

create function permissions.ids(p_action text, p_type text, p_via text default null, p_resource_condition jsonb default null)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select permissions.ids_for(permissions.current_subject_type(), permissions.current_subject_id(),
                               p_action, p_type, p_via, p_resource_condition)
$$;

create function permissions.denied_ids(p_action text, p_type text, p_via text default null, p_resource_condition jsonb default null)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select permissions.denied_ids_for(permissions.current_subject_type(), permissions.current_subject_id(),
                                      p_action, p_type, p_via, p_resource_condition)
$$;

create function permissions.allows_all(p_action text, p_type text, p_resource_condition jsonb default null)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions.allows_all_for(permissions.current_subject_type(), permissions.current_subject_id(),
                                      p_action, p_type, p_resource_condition)
$$;

create function permissions.denies_all(p_action text, p_type text, p_resource_condition jsonb default null)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions.denies_all_for(permissions.current_subject_type(), permissions.current_subject_id(),
                                      p_action, p_type, p_resource_condition)
$$;

-- ============================================================================
-- Management (admin only)
-- ============================================================================

create function permissions.define_role(p_resource_type text, p_role text, p_implies text[] default '{}')
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    x text;
begin
    select i into x from unnest(p_implies) i
    where i <> p_role and not exists (select 1 from permissions.roles where resource_type = p_resource_type and role = i)
    limit 1;
    if x is not null then
        raise exception 'permissions: unknown role % on %', x, p_resource_type using errcode = '22023';
    end if;
    insert into permissions.roles (resource_type, role) values (p_resource_type, p_role) on conflict do nothing;
    insert into permissions.role_implies (resource_type, role, implies)
    select p_resource_type, p_role, i from unnest(p_implies) i where i <> p_role
    on conflict do nothing;
    perform permissions._rebuild_role_closure(p_resource_type);
end;
$$;

create function permissions.grant_role(
    p_principal_type text, p_principal_id text, p_role text,
    p_resource_type text, p_resource_id text, p_expires_at timestamptz default null
)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    if not exists (select 1 from permissions.roles where resource_type = p_resource_type and role = p_role) then
        raise exception 'permissions: unknown role % on %', p_role, p_resource_type using errcode = '22023';
    end if;
    insert into permissions.role_grants (principal_type, principal_id, role, resource_type, resource_id, expires_at)
    values (p_principal_type, p_principal_id, p_role, p_resource_type, p_resource_id, p_expires_at)
    on conflict (principal_type, principal_id, resource_type, resource_id, role)
    do update set expires_at = excluded.expires_at;
end;
$$;

create function permissions.revoke_role(
    p_principal_type text, p_principal_id text, p_role text,
    p_resource_type text, p_resource_id text
)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
begin
    delete from permissions.role_grants
    where principal_type = p_principal_type and principal_id = p_principal_id and role = p_role
      and resource_type = p_resource_type and resource_id = p_resource_id;
    return found;
end;
$$;

create function permissions.add_parent(p_child_type text, p_child_id text, p_parent_type text, p_parent_id text)
returns void
language sql security definer
set search_path = ''
as $$
    insert into permissions.parents (child_type, child_id, parent_type, parent_id)
    values (p_child_type, p_child_id, p_parent_type, p_parent_id)
    on conflict do nothing
$$;

create function permissions.remove_parent(p_child_type text, p_child_id text, p_parent_type text, p_parent_id text)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
begin
    delete from permissions.parents
    where child_type = p_child_type and child_id = p_child_id
      and parent_type = p_parent_type and parent_id = p_parent_id;
    return found;
end;
$$;

create function permissions.set_attrs(p_type text, p_id text, p_attrs jsonb)
returns void
language sql security definer
set search_path = ''
as $$
    insert into permissions.entities (type, id, attrs) values (p_type, p_id, coalesce(p_attrs, '{}'))
    on conflict (type, id) do update set attrs = excluded.attrs
$$;

create function permissions._add_policy(
    p_effect text, p_name text, p_actions text[], p_resource_type text,
    p_roles text[], p_via text, p_principal_in_type text, p_principal_in_id text,
    p_resource_id text, p_condition jsonb, p_principal_id text, p_principal_type text
)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
    v_anchor text := coalesce(p_via, p_resource_type);
    v_split record;
    x text;
    v_id bigint;
begin
    if p_via is not null and p_roles is null then
        raise exception 'permissions: a policy with via needs roles (the role held on the % parent)', p_via
            using errcode = '22023';
    end if;
    if p_via is not null and p_resource_id is not null then
        raise exception 'permissions: resource_id and via cannot be combined' using errcode = '22023';
    end if;
    select r into x from unnest(p_roles) r
    where not exists (select 1 from permissions.roles where resource_type = v_anchor and role = r)
    limit 1;
    if x is not null then
        raise exception 'permissions: unknown role % on %', x, v_anchor using errcode = '22023';
    end if;
    select * into v_split from permissions._split_condition(p_condition);
    insert into permissions.policies (name, effect, principal_type, principal_id, principal_in_type, principal_in_id,
                                      actions, resource_type, resource_id, roles, via,
                                      condition, principal_condition, resource_condition)
    values (p_name, p_effect, p_principal_type, p_principal_id, p_principal_in_type, p_principal_in_id,
            p_actions, p_resource_type, p_resource_id, p_roles, p_via,
            p_condition, v_split.principal_part, v_split.resource_part)
    returning id into v_id;
    return v_id;
end;
$$;

create function permissions.permit(
    p_name text, p_actions text[], p_resource_type text,
    roles text[] default null, via text default null,
    principal_in_type text default null, principal_in_id text default null,
    resource_id text default null, condition jsonb default null,
    principal_id text default null, principal_type text default 'user'
)
returns bigint
language sql security definer
set search_path = ''
as $$
    select permissions._add_policy('permit', p_name, p_actions, p_resource_type, roles, via,
                                   principal_in_type, principal_in_id, resource_id, condition, principal_id, principal_type)
$$;

create function permissions.forbid(
    p_name text, p_actions text[], p_resource_type text,
    roles text[] default null, via text default null,
    principal_in_type text default null, principal_in_id text default null,
    resource_id text default null, condition jsonb default null,
    principal_id text default null, principal_type text default 'user'
)
returns bigint
language sql security definer
set search_path = ''
as $$
    select permissions._add_policy('forbid', p_name, p_actions, p_resource_type, roles, via,
                                   principal_in_type, principal_in_id, resource_id, condition, principal_id, principal_type)
$$;

create function permissions.drop_policy(p_name text)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
begin
    if exists (select 1 from permissions.policies where name = p_name and managed_by is not null) then
        raise exception 'permissions: policy % is managed by the % preset', p_name,
            (select managed_by from permissions.policies where name = p_name)
            using errcode = '55000';
    end if;
    delete from permissions.policies where name = p_name;
    return found;
end;
$$;

-- Remove everything that names an entity: its attributes, grants it holds and
-- grants on it, its parent edges (closures follow) and unmanaged policies
-- that name it.
create function permissions.delete_entity(p_type text, p_id text)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
    n bigint;
    total bigint := 0;
begin
    delete from permissions.role_grants
    where (principal_type = p_type and principal_id = p_id) or (resource_type = p_type and resource_id = p_id);
    get diagnostics n = row_count; total := total + n;
    delete from permissions.parents
    where (child_type = p_type and child_id = p_id) or (parent_type = p_type and parent_id = p_id);
    get diagnostics n = row_count; total := total + n;
    delete from permissions.policies
    where managed_by is null
      and ((resource_type = p_type and resource_id = p_id)
           or (principal_type = p_type and principal_id = p_id)
           or (principal_in_type = p_type and principal_in_id = p_id));
    get diagnostics n = row_count; total := total + n;
    delete from permissions.entities where type = p_type and id = p_id;
    get diagnostics n = row_count; total := total + n;
    return total;
end;
$$;

-- Attach to an app's identity table:
--   create trigger cleanup_permissions after delete on public.profiles
--     for each row execute function permissions.on_entity_deleted('user', 'id');
create function permissions.on_entity_deleted()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
    perform permissions.delete_entity(tg_argv[0], to_jsonb(old) ->> tg_argv[1]);
    return null;
end;
$$;

-- ============================================================================
-- RLS tooling
-- ============================================================================

-- The USING expression for one action on a table: a permit side and a forbid
-- side, each with an allows-all flag, the table's id column and one branch per
-- parent column, and one extra group per distinct resource condition (the
-- condition compiled to SQL over the row's columns). Every function call is an
-- uncorrelated (select ...), so it runs once per query as an InitPlan.
-- Resource-conditioned groups are read from the policies table when this
-- runs: add such a policy later and the RLS policy must be regenerated.
create function permissions.rls_expression(
    p_action text, p_resource_type text, p_id_column text default 'id',
    p_via_columns jsonb default '{}', p_id_type regtype default 'uuid'
)
returns text
language plpgsql stable security definer
set search_path = ''
as $$
declare
    v_side text;
    v_cond jsonb;
    v_items text[];
    v_groups text[];
    v_sides text[] := '{}';
    v_args text;
    v_kv record;
    v_all_fn text;
    v_ids_fn text;
    v_branch text;
begin
    foreach v_side in array array['permit', 'forbid'] loop
        v_groups := '{}';
        v_all_fn := case v_side when 'permit' then 'allows_all' else 'denies_all' end;
        v_ids_fn := case v_side when 'permit' then 'ids' else 'denied_ids' end;
        for v_cond in
            select null::jsonb
            union all
            select distinct p.resource_condition from permissions.policies p
            where p.enabled and p.effect = v_side and p.resource_type = p_resource_type
              and p_action = any (p.actions) and p.resource_condition is not null
        loop
            v_args := format('%L, %L', p_action, p_resource_type);
            v_items := '{}';
            -- A boolean arm OR'd with the id arms stops Postgres from using a
            -- BitmapOr over the id/parent indexes (it falls back to a seq
            -- scan), so the permit side only gets it if an allow-all policy
            -- exists now. The forbid side is AND'd, so it is always present.
            if v_side = 'forbid' or exists (
                select 1 from permissions.policies p
                where p.enabled and p.effect = 'permit' and p.resource_type = p_resource_type
                  and p_action = any (p.actions) and p.roles is null and p.resource_id is null
                  and p.resource_condition is not distinct from v_cond
            ) then
                v_items := v_items || format('(select permissions.%s(%s%s))', v_all_fn, v_args,
                                             case when v_cond is not null then format(', %L::jsonb', v_cond::text) else '' end);
            end if;
            if p_id_column is not null then
                v_items := v_items || format('%I = any (array(select unnest(permissions.%s(%s%s))::%s))',
                    p_id_column, v_ids_fn, v_args,
                    case when v_cond is not null then format(', null, %L::jsonb', v_cond::text) else '' end,
                    p_id_type);
            end if;
            for v_kv in select key, value from jsonb_each_text(coalesce(p_via_columns, '{}')) order by key loop
                v_items := v_items || format('%I = any (array(select unnest(permissions.%s(%s, %L%s))::%s))',
                    v_kv.value, v_ids_fn, v_args, v_kv.key,
                    case when v_cond is not null then format(', %L::jsonb', v_cond::text) else '' end,
                    p_id_type);
            end loop;
            v_branch := coalesce(nullif(array_to_string(v_items, E'\n    or '), ''), 'false');
            if v_cond is not null then
                v_branch := format('(%s and (%s))', permissions._cond_sql(v_cond), v_branch);
            end if;
            v_groups := v_groups || v_branch;
        end loop;
        v_sides := v_sides || array_to_string(v_groups, E'\n    or ');
    end loop;
    return format(E'(\n    %s\n) and not (\n    %s\n)', v_sides[1], v_sides[2]);
end;
$$;

-- Create (or replace) the RLS policy for one command on a table, using
-- rls_expression. The only dynamic SQL in the extension; it runs with the
-- caller's rights (security invoker), so only the table owner can use it.
create function permissions.apply_rls(
    p_table regclass, p_command text, p_resource_type text, p_id_column text default 'id',
    p_via_columns jsonb default '{}', p_to_role name default 'authenticated'
)
returns text
language plpgsql
set search_path = ''
as $$
declare
    v_expr text;
    v_name text;
begin
    if p_command not in ('select', 'insert', 'update', 'delete') then
        raise exception 'permissions: command must be select, insert, update or delete' using errcode = '22023';
    end if;
    v_expr := permissions.rls_expression(p_command, p_resource_type, p_id_column, p_via_columns);
    v_name := 'permissions_' || p_command;
    execute format('drop policy if exists %I on %s', v_name, p_table);
    execute format('create policy %I on %s for %s to %I %s', v_name, p_table, p_command, p_to_role,
        case p_command
            when 'insert' then format('with check (%s)', v_expr)
            when 'update' then format('using (%s) with check (%s)', v_expr, v_expr)
            else format('using (%s)', v_expr)
        end);
    return v_name;
end;
$$;

-- Problems a developer should know about. Checks RLS policies textually.
create function permissions.lint()
returns table (problem text, policy text)
language sql stable security definer
set search_path = ''
as $$
    with rls as (
        select coalesce(pg_get_expr(p.polqual, p.polrelid), '') || ' ' ||
               coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') as expr
        from pg_catalog.pg_policy p
    )
    select format('role %s is not declared on %s', r, coalesce(p.via, p.resource_type)), p.name
    from permissions.policies p, unnest(p.roles) r
    where not exists (select 1 from permissions.roles x where x.resource_type = coalesce(p.via, p.resource_type) and x.role = r)
    union all
    select format('forbid on %s/%s is not enforced by any RLS policy (no denied_ids branch); can() still applies it', a, p.resource_type), p.name
    from permissions.policies p, unnest(p.actions) a
    where p.effect = 'forbid' and p.enabled
      and not exists (select 1 from rls where rls.expr like '%denied_ids(' || quote_literal(a) || '::text, ' || quote_literal(p.resource_type) || '::text%')
    union all
    select format('allow-all permit on %s/%s is not in any RLS policy (no allows_all branch); re-run apply_rls', a, p.resource_type), p.name
    from permissions.policies p, unnest(p.actions) a
    where p.effect = 'permit' and p.enabled and p.roles is null and p.resource_id is null and p.resource_condition is null
      and not exists (select 1 from rls where rls.expr like '%allows_all(' || quote_literal(a) || '::text, ' || quote_literal(p.resource_type) || '::text%')
    union all
    select format('resource condition on %s/%s is not in any RLS policy; re-run apply_rls', a, p.resource_type), p.name
    from permissions.policies p, unnest(p.actions) a
    where p.resource_condition is not null and p.enabled
      and not exists (select 1 from rls where position(quote_literal(p.resource_condition::text) in rls.expr) > 0)
$$;

-- ============================================================================
-- rbac preset (PLAN.md §6)
--
-- Two built-in resource types hold roles: `app` (one resource, app:global) and
-- `tenant` (one resource per scope). A role is declared on both, its
-- inheritance is role_implies, and its permissions are one generated policy
-- per type (managed_by = 'rbac', so drop_policy refuses to touch them).
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
        perform permissions.define_role(t, p_role, p_inherits);
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
language plpgsql security definer
set search_path = ''
as $$
begin
    if not exists (select 1 from permissions.roles where resource_type = 'app' and role = p_role) then
        raise exception 'unknown role %', p_role using errcode = '22023';
    end if;
    insert into permissions.role_grants (principal_type, principal_id, role, resource_type, resource_id)
    select 'user', p_user_id, p_role, s.resource_type, s.resource_id from permissions._scope_resource(p_scope) s
    on conflict do nothing;
end;
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
                               p_permission, case when p_scope is null then 'app' else 'tenant' end,
                               coalesce(p_scope, 'global'))
$$;

create function permissions._holds_role(p_subject_type text, p_subject_id text, p_role text, p_type text, p_id text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select exists (
        select 1
        from (select p_subject_type, p_subject_id
              union all
              select ancestor_type, ancestor_id from permissions.ancestors
              where child_type = p_subject_type and child_id = p_subject_id) s(t, id)
        join permissions.role_grants g
          on g.principal_type = s.t and g.principal_id = s.id and g.resource_type = p_type and g.resource_id = p_id
        join permissions.role_closure rc on rc.resource_type = g.resource_type and rc.role = g.role
        where rc.implied = p_role and p_subject_id is not null
          and (g.expires_at is null or g.expires_at > now())
    )
$$;

create function permissions.has_role(p_role text, p_scope text default null)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions._holds_role(permissions.current_subject_type(), permissions.current_subject_id(),
                                   p_role, case when p_scope is null then 'app' else 'tenant' end,
                                   coalesce(p_scope, 'global'))
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
    with holders as (
        select g.principal_type, g.principal_id
        from permissions._scope_resource(p_scope) s
        join permissions.role_grants g on g.resource_type = s.resource_type and g.resource_id = s.resource_id
        join permissions.role_closure rc on rc.resource_type = g.resource_type and rc.role = g.role
        where rc.implied = p_role and (g.expires_at is null or g.expires_at > now())
    )
    select principal_id from holders where principal_type = 'user'
    union
    select a.child_id from holders h
    join permissions.ancestors a on a.ancestor_type = h.principal_type and a.ancestor_id = h.principal_id
    where a.child_type = 'user'
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
    permissions.can(text, text, text, jsonb),
    permissions.ids(text, text, text, jsonb),
    permissions.denied_ids(text, text, text, jsonb),
    permissions.allows_all(text, text, jsonb),
    permissions.denies_all(text, text, jsonb),
    permissions.has_permission(text, text),
    permissions.has_role(text, text),
    permissions.scopes_with_permission(text)
to public;

-- Everything else (facts, policies, explicit-subject checks, who_can, explain,
-- RLS tooling) is for the owner and whichever trusted roles the app grants,
-- e.g. service_role.
