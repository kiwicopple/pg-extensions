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
    from_parent text[] not null default '{}',  -- G10: relations inherited from the object's `parent`
    unless      text[] not null default '{}',  -- G12: excluded for subjects holding one of these relations
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
-- Which (subject_type, subject_relation) pairs have usersets, and which types
-- are parents: the walk only expands nodes that can have an outgoing edge
-- (see _reach). Small: usersets and parent links only, deduplicated keys.
create index tuples_edge_kinds_idx on permissions.tuples (subject_type, subject_relation)
    where subject_relation <> '' or relation = 'parent';

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

-- Defining a relation again replaces all three lists.
--
--   implied_by  relations on the same object that imply this one (editor => viewer)
--   from_parent relations on the object's parent that imply this one (G10, OpenFGA's
--               "viewer from parent"). The parent is whatever the object's `parent`
--               tuples point at, of any type; the relation is looked up by name there.
--   unless      relations on the same object that exclude this one (G12, OpenFGA's
--               "but not"). A subject holding one of them directly never reaches this
--               relation on that object, whichever path would have granted it.
create function permissions.define_relation(
    object_type text, relation text,
    implied_by text[] default '{}', from_parent text[] default '{}', unless text[] default '{}'
)
returns void
language sql security definer
set search_path = ''
as $$
    insert into permissions.relations (object_type, relation, implied_by, from_parent, unless)
    values (define_relation.object_type, define_relation.relation,
            define_relation.implied_by, define_relation.from_parent, define_relation.unless)
    on conflict on constraint relations_pkey do update
    set implied_by = excluded.implied_by, from_parent = excluded.from_parent, unless = excluded.unless
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
    -- G11: `user:*` means every user; `team:*#member` would mean nothing
    if p_subject_id = '*' and p_subject_relation <> '' then
        raise exception 'a wildcard subject can''t have a relation' using errcode = '22023';
    end if;
    -- G10/G12: parent links and exclusions only match one concrete subject.
    -- A blocked userset would need the walk itself to decide who is in it.
    if (p_subject_relation <> '' or p_subject_id = '*') and (
        p_relation = 'parent'
        or exists (select 1 from permissions.relations r
                   where r.object_type = p_object_type and p_relation = any (r.unless))
    ) then
        raise exception 'relation %#% only takes a direct subject, not a userset or wildcard', p_object_type, p_relation
            using errcode = '22023';
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

-- G10: an object's parent. Replaces any existing parent; null clears it.
-- A parent is just the tuple `child#parent@parent_type:parent_id`.
create function permissions.set_parent(
    p_object_type text, p_object_id text, p_parent_type text, p_parent_id text
)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    delete from permissions.tuples
    where object_type = p_object_type and object_id = p_object_id and relation = 'parent';
    if p_parent_id is not null then
        perform permissions.grant(p_object_type, p_object_id, 'parent', p_parent_type, p_parent_id);
    end if;
end;
$$;

-- G10: keep parent tuples in sync with an app column, so they can't drift.
--
--   create trigger documents_parent
--   after insert or update of folder_id or delete on public.documents
--   for each row execute function permissions.sync_parent('document', 'folder', 'folder_id');
--
-- Arguments: object type, parent type, parent column, id column (default 'id').
-- Execute is revoked from public: Postgres checks it when the trigger is
-- created, not when it fires, so only the owner can attach it to a table.
create function permissions.sync_parent()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
    id_col text := coalesce(tg_argv[3], 'id');
    o jsonb;
    n jsonb;
begin
    if tg_op in ('UPDATE', 'DELETE') then
        o := to_jsonb(old);
    end if;
    if tg_op in ('INSERT', 'UPDATE') then
        n := to_jsonb(new);
    end if;
    if tg_op = 'UPDATE' and o ->> id_col = n ->> id_col and o ->> tg_argv[2] is not distinct from n ->> tg_argv[2] then
        return null;
    end if;
    if o is not null and (n is null or o ->> id_col <> n ->> id_col) then
        perform permissions.set_parent(tg_argv[0], o ->> id_col, null, null);
    end if;
    if n is not null then
        perform permissions.set_parent(tg_argv[0], n ->> id_col, tg_argv[1], n ->> tg_argv[2]);
    end if;
    return null;
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
-- `union` removes duplicates, so cycles (groups or parents) terminate.
--
-- Three edges, all in one `lateral` because Postgres allows only one recursive
-- reference:
--   1. tuples where this node is the subject (direct grants, usersets)
--   2. relations implied by this one on the same object (implied_by)
--   3. relations inherited by this node's children (from_parent, G10)
-- The walk starts from the subject and from `subject_type:*` (G11), and never
-- enters a node the subject is excluded from (unless, G12), so nothing derived
-- through an excluded node is reached either.
--
-- Only nodes that can have an outgoing edge are expanded (`expandable`): their
-- (type, relation) has usersets, is implied_by another relation, or is
-- inherited from_parent by a type that has parent links. Everything else (most
-- of the walk: the documents a team or folder reaches) is a leaf, kept but
-- never probed. The usersets and parent types come from a loose index scan of
-- tuples_edge_kinds_idx (`kinds`, one probe per distinct pair). Without this,
-- every leaf cost three index probes, which was most of the time of a wide walk.
--
-- PL/pgSQL rather than SQL only so the plan is cached per session: Postgres 16
-- re-plans a SQL function body on every call, which cost ~0.25 ms per check
-- once the query grew the parent and exclusion steps. Generic plan forced: the
-- custom plans the plan cache otherwise keeps choosing cost ~0.3 ms to plan,
-- every call.
create function permissions._reach(p_subject_type text, p_subject_id text)
returns table (object_type text, object_id text, relation text)
language plpgsql stable security definer
set search_path = ''
set plan_cache_mode = force_generic_plan
as $$
#variable_conflict use_column
begin
    return query
    with recursive
    -- materialized: computed once. Inlined, the planner sometimes turns the
    -- anti-join below into one index probe per reached node.
    blocked(object_type, object_id, relation) as materialized (
        select t.object_type, t.object_id, rel.relation
        from permissions.tuples t
        join permissions.relations rel on rel.object_type = t.object_type and t.relation = any (rel.unless)
        where t.subject_type = p_subject_type
          and t.subject_id = p_subject_id
          and t.subject_relation = ''
          and t.condition is null
          and (t.expires_at is null or t.expires_at > now())
    ),
    kinds(t, r) as (
        (select x.subject_type, x.subject_relation
         from permissions.tuples x
         where x.subject_relation <> '' or x.relation = 'parent'
         order by x.subject_type, x.subject_relation
         limit 1)
      union all
        select y.subject_type, y.subject_relation
        from kinds k
        cross join lateral (
            select x.subject_type, x.subject_relation
            from permissions.tuples x
            where (x.subject_relation <> '' or x.relation = 'parent')
              and (x.subject_type, x.subject_relation) > (k.t, k.r)
            order by x.subject_type, x.subject_relation
            limit 1
        ) y
    ),
    expandable(t, r) as materialized (
        select k.t, k.r from kinds k where k.r <> ''
      union
        select rel.object_type, x from permissions.relations rel cross join unnest(rel.implied_by) x
      union
        select k.t, x from kinds k cross join permissions.relations rel cross join unnest(rel.from_parent) x
        where k.r = ''
      union
        select p_subject_type, ''
    ),
    reach(object_type, object_id, relation) as (
        select p_subject_type, s, ''::text
        from unnest(array[p_subject_id, '*']) s
        where p_subject_id is not null
      union
        select n.object_type, n.object_id, n.relation
        from reach r
        join expandable e on e.t = r.object_type and e.r = r.relation
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
          union all
            select c.object_type, c.object_id, rel.relation
            from permissions.tuples c
            join permissions.relations rel on rel.object_type = c.object_type and r.relation = any (rel.from_parent)
            where c.subject_type = r.object_type
              and c.subject_id = r.object_id
              and c.subject_relation = ''
              and c.relation = 'parent'
              and c.condition is null
              and (c.expires_at is null or c.expires_at > now())
        ) n
        where not exists (
            select 1 from blocked b
            where b.object_type = n.object_type and b.object_id = n.object_id and b.relation = n.relation
        )
    )
    select * from reach where p_subject_id is not null;
end;
$$;

-- Explicit-subject variants: admin only (see the grants at the end).
--
-- check_for is a bidirectional search over the same graph as _reach: forwards
-- from the subject (the edges above), backwards from the target (the tuples on
-- a node, the relations that imply it, the relations it inherits from its
-- parent), each step expanding the smaller frontier, until they meet. Both
-- sides skip excluded nodes, so the answer is what _reach would say. A user in
-- 50 teams with 50 documents each no longer walks 2,500 documents to check one:
-- the target's side is a handful of nodes. Backwards, direct subjects other
-- than the subject itself are dropped (a team's members are dead ends).
create function permissions.check_for(
    p_subject_type text, p_subject_id text,
    p_object_type text, p_object_id text, p_relation text
)
returns boolean
language plpgsql stable security definer
set search_path = ''
set plan_cache_mode = force_generic_plan
as $$
declare
    ft text[]; fi text[]; fr text[];   -- forward frontier
    st text[]; si text[]; sr text[];   -- forward: every node reached
    gt text[]; gi text[]; gr text[];   -- backward frontier
    ut text[]; ui text[]; ur text[];   -- backward: every node reached (all lead to the target)
    bt text[]; bi text[]; br text[];   -- nodes the subject is excluded from (G12)
    starts text[];
    hit boolean;
    blocked_target boolean;
begin
    if p_subject_id is null then
        return false;
    end if;
    starts := array[p_subject_id, '*'];
    if p_relation = '' and p_object_type = p_subject_type and p_object_id = any (starts) then
        return true;
    end if;

    -- The subject's own tuples give both its exclusions (G12) and the first
    -- forward step, so they are read once.
    with d as materialized (
        select t.subject_id, t.object_type, t.object_id, t.relation
        from permissions.tuples t
        where t.subject_type = p_subject_type
          and t.subject_id = any (starts)
          and t.subject_relation = ''
          and t.condition is null
          and (t.expires_at is null or t.expires_at > now())
    ),
    b as materialized (
        select d.object_type, d.object_id, rel.relation
        from d
        join permissions.relations rel on rel.object_type = d.object_type and d.relation = any (rel.unless)
        where d.subject_id = p_subject_id
    ),
    n as materialized (
        (
            select d.object_type, d.object_id, d.relation from d
          union all
            select p_subject_type, s, rel.relation
            from unnest(starts) s
            join permissions.relations rel on rel.object_type = p_subject_type and '' = any (rel.implied_by)
          union all
            select c.object_type, c.object_id, rel.relation
            from permissions.tuples c
            join permissions.relations rel on rel.object_type = c.object_type and '' = any (rel.from_parent)
            where c.subject_type = p_subject_type
              and c.subject_id = any (starts)
              and c.subject_relation = ''
              and c.relation = 'parent'
              and c.condition is null
              and (c.expires_at is null or c.expires_at > now())
        )
      except
        select * from b
    )
    select (select coalesce(array_agg(b.object_type), '{}') from b),
           (select coalesce(array_agg(b.object_id), '{}') from b),
           (select coalesce(array_agg(b.relation), '{}') from b),
           (select array_agg(n.object_type) from n),
           (select array_agg(n.object_id) from n),
           (select array_agg(n.relation) from n),
           exists (select 1 from n where n.object_type = p_object_type and n.object_id = p_object_id and n.relation = p_relation),
           exists (select 1 from b where b.object_type = p_object_type and b.object_id = p_object_id and b.relation = p_relation)
    into bt, bi, br, ft, fi, fr, hit, blocked_target;

    if blocked_target then
        return false;   -- the walk never enters an excluded node
    elsif hit then
        return true;
    elsif ft is null then
        return false;
    end if;
    st := array[p_subject_type, p_subject_type] || ft;
    si := starts || fi;
    sr := array['', ''] || fr;
    gt := array[p_object_type]; gi := array[p_object_id]; gr := array[p_relation];
    ut := gt; ui := gi; ur := gr;

    loop
        if cardinality(ft) <= cardinality(gt) then
            -- one step forwards from the subject side
            with n as materialized (
                (
                    select t.object_type, t.object_id, t.relation
                    from unnest(ft, fi, fr) f(t, i, r)
                    join permissions.tuples t
                      on t.subject_type = f.t and t.subject_id = f.i and t.subject_relation = f.r
                    where t.condition is null
                      and (t.expires_at is null or t.expires_at > now())
                  union all
                    select f.t, f.i, rel.relation
                    from unnest(ft, fi, fr) f(t, i, r)
                    join permissions.relations rel on rel.object_type = f.t and f.r = any (rel.implied_by)
                  union all
                    select c.object_type, c.object_id, rel.relation
                    from unnest(ft, fi, fr) f(t, i, r)
                    join permissions.tuples c
                      on c.subject_type = f.t and c.subject_id = f.i and c.subject_relation = ''
                    join permissions.relations rel on rel.object_type = c.object_type and f.r = any (rel.from_parent)
                    where c.relation = 'parent'
                      and c.condition is null
                      and (c.expires_at is null or c.expires_at > now())
                )
              except
                select * from unnest(st, si, sr)
              except
                select * from unnest(bt, bi, br)
            )
            select array_agg(n.object_type), array_agg(n.object_id), array_agg(n.relation),
                   exists (select 1 from n join unnest(ut, ui, ur) u(t, i, r)
                             on u.t = n.object_type and u.i = n.object_id and u.r = n.relation)
            into ft, fi, fr, hit
            from n;

            if hit then
                return true;
            end if;
            exit when ft is null;
            st := st || ft; si := si || fi; sr := sr || fr;
        else
            -- one step backwards from the object side
            with n as materialized (
                (
                    -- usersets granted the node. Direct subjects are dead ends here:
                    -- either not the subject, or its own tuples, which the first
                    -- forward step already followed.
                    select tu.subject_type, tu.subject_id, tu.subject_relation
                    from unnest(gt, gi, gr) g(t, i, r)
                    join permissions.tuples tu
                      on tu.object_type = g.t and tu.object_id = g.i and tu.relation = g.r
                    where tu.subject_relation <> ''
                      and tu.condition is null
                      and (tu.expires_at is null or tu.expires_at > now())
                  union all
                    select g.t, g.i, x
                    from unnest(gt, gi, gr) g(t, i, r)
                    join permissions.relations rel on rel.object_type = g.t and rel.relation = g.r
                    cross join unnest(rel.implied_by) x
                  union all
                    select pt.subject_type, pt.subject_id, x
                    from unnest(gt, gi, gr) g(t, i, r)
                    join permissions.relations rel on rel.object_type = g.t and rel.relation = g.r
                    cross join unnest(rel.from_parent) x
                    join permissions.tuples pt
                      on pt.object_type = g.t and pt.object_id = g.i and pt.relation = 'parent'
                    where pt.subject_relation = ''
                      and pt.condition is null
                      and (pt.expires_at is null or pt.expires_at > now())
                )
              except
                select * from unnest(ut, ui, ur)
              except
                select * from unnest(bt, bi, br)
            )
            select array_agg(n.subject_type), array_agg(n.subject_id), array_agg(n.subject_relation),
                   exists (select 1 from n join unnest(st, si, sr) s(t, i, r)
                             on s.t = n.subject_type and s.i = n.subject_id and s.r = n.subject_relation)
            into gt, gi, gr, hit
            from n;

            if hit then
                return true;
            end if;
            exit when gt is null;
            ut := ut || gt; ui := ui || gi; ur := ur || gr;
        end if;
    end loop;
    return false;
end;
$$;

-- Unordered. _reach returns each node once, so the ids are already distinct:
-- `array_agg(distinct)` sorted them with the database collation, 25 ms for
-- 10k ids under en_US-style collations.
--
-- VOLATILE, like list_objects and scopes_with_permission: a policy calls them
-- with constant arguments inside `array(select unnest(...))`, and for a STABLE
-- function the planner evaluates the whole call while planning, to estimate
-- the unnest's row count (estimate_expression_value), then the executor runs
-- it again. Every policy query paid for two walks.
create function permissions.list_objects_for(
    p_subject_type text, p_subject_id text,
    p_object_type text, p_relation text
)
returns text[]
language sql volatile security definer
set search_path = ''
as $$
    select coalesce(array_agg(r.object_id), '{}')
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
          union all
            -- G10: up to the parent, as the relations this one inherits
            select p.subject_type, p.subject_id, x
            from permissions.relations rel
            cross join unnest(rel.from_parent) x
            join permissions.tuples p
              on p.object_type = b.t and p.object_id = b.i and p.relation = 'parent' and p.subject_relation = ''
             and p.condition is null and (p.expires_at is null or p.expires_at > now())
            where rel.object_type = b.t and rel.relation = b.r
        ) n(t, i, r)
    ),
    candidates as (
        select distinct t, i from back where r = ''
    )
    -- G12: exclusions depend on the subject, not the path, so the reverse walk
    -- can't prune. Candidates holding any exclusion tuple are re-checked forwards.
    select c.t, c.i
    from candidates c
    where not exists (
            select 1
            from permissions.tuples x
            join permissions.relations rel on rel.object_type = x.object_type and x.relation = any (rel.unless)
            where x.subject_type = c.t and x.subject_id = c.i and x.subject_relation = ''
          )
       or permissions.check_for(c.t, c.i, p_object_type, p_object_id, p_relation)
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
language sql volatile security definer
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
language sql volatile security definer
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
