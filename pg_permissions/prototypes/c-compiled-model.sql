/*
 * pg_permissions prototype: Design C (compiled model) + rbac preset
 *
 * See ../designs/c-compiled-model.md. This is a prototype for testing and
 * benchmarking, not the extension itself:
 *
 *   ./test/run.sh --impl prototypes/c-compiled-model.sql
 *
 * Layout:
 *   1. Catalog   models (version history), types, relations, allowed_subjects,
 *                parent_types, satisfies (the compiled relation axis)
 *   2. Data      tuples (object axis, stored as written), parents (one per object)
 *   3. Derived   memberships (subject axis) and ancestors (container closure),
 *                maintained by triggers under one advisory lock
 *   4. Compiler  apply_model()
 *   5. Reads     can, accessible, who_can (+ admin-only *_for variants)
 *   6. Writes    grant, revoke, grant_public, revoke_public, set_parent, ...
 *   7. Upkeep    verify, rebuild
 *   8. rbac preset (PLAN.md §6)
 *
 * All IDs are uuid. No dynamic SQL and no DDL after install.
 */

create schema if not exists permissions;

-- ============================================================================
-- 1. Catalog
-- ============================================================================

-- Model history. The latest row is the active model (the full definition,
-- including the rbac preset's types).
create table permissions.models (
    version     int generated always as identity primary key,
    definition  jsonb not null,
    applied_at  timestamptz not null default now(),
    applied_by  name not null default current_user
);

-- Names map to small ids that stay the same across model versions.
create table permissions.types (
    id         smallint generated always as identity primary key,
    name       text not null unique check (name ~ '^[a-z][a-z0-9_]{0,62}$'),
    principal  boolean not null default false,
    container  boolean not null default false     -- some type lists it as a parent
);

create table permissions.relations (
    id             smallint generated always as identity primary key,
    type_id        smallint not null references permissions.types on delete cascade,
    name           text not null check (name ~ '^[a-z][a-z0-9_.]{0,62}$'),
    kind           text not null check (kind in ('relation', 'permission')),
    is_userset     boolean not null default false,  -- appears as type#relation in the model
    feeds_userset  boolean not null default false,  -- granting it changes memberships
    unique (type_id, name)
);

-- Which subjects may hold a relation. wildcard = "every principal of subject_type".
create table permissions.allowed_subjects (
    relation_id       smallint not null references permissions.relations on delete cascade,
    subject_type      smallint not null references permissions.types on delete cascade,
    subject_relation  smallint references permissions.relations on delete cascade,
    wildcard          boolean not null default false,
    unique nulls not distinct (relation_id, subject_type, subject_relation, wildcard)
);

-- Which types an object of type_id may have as its parent.
create table permissions.parent_types (
    type_id      smallint not null references permissions.types on delete cascade,
    parent_type  smallint not null references permissions.types on delete cascade,
    primary key (type_id, parent_type)
);

-- The compiled relation axis. A tuple with relation `relation_id` satisfies
-- (or, with forbid, vetoes) `grants_id`:
--   via_parent = false: when the tuple is on the checked object itself
--   via_parent = true:  when the tuple is on any ancestor of the checked object
create table permissions.satisfies (
    grants_id    smallint not null references permissions.relations on delete cascade,
    relation_id  smallint not null references permissions.relations on delete cascade,
    via_parent   boolean not null default false,
    forbid       boolean not null default false,
    primary key (grants_id, forbid, via_parent, relation_id)
);

-- ============================================================================
-- 2. Data
-- ============================================================================

-- Object axis: grants as written. Only expires_at can be updated (by grant()).
-- subject_id null = public grant (every principal of subject_type), written
-- only by grant_public(), so a null from a failed lookup can't grant public access.
create table permissions.tuples (
    id                bigint generated always as identity primary key,
    object_type       smallint not null references permissions.types,
    object_id         uuid not null,
    relation          smallint not null references permissions.relations,
    subject_type      smallint not null references permissions.types,
    subject_id        uuid,
    subject_relation  smallint references permissions.relations,
    expires_at        timestamptz,
    created_at        timestamptz not null default now(),
    -- object_type is implied by relation (relation ids are per type)
    constraint tuples_key unique nulls not distinct (object_id, relation, subject_type, subject_id, subject_relation),
    check (subject_id is not null or subject_relation is null)
);
create index tuples_direct on permissions.tuples (subject_id, relation)
    include (object_type, object_id, expires_at) where subject_relation is null;
create index tuples_userset on permissions.tuples (subject_id, subject_relation, relation)
    include (object_type, object_id, expires_at) where subject_relation is not null;
create index tuples_public on permissions.tuples (relation)
    include (object_type, object_id, subject_type, expires_at) where subject_id is null;

-- Parent links: at most one parent per object (folder trees, org hierarchies).
-- Moving an object is one upsert.
create table permissions.parents (
    object_type  smallint not null references permissions.types,
    object_id    uuid not null,
    parent_type  smallint not null references permissions.types,
    parent_id    uuid not null,
    primary key (object_id, object_type)
);
create index parents_by_parent on permissions.parents (parent_id, parent_type) include (object_type, object_id);

-- ============================================================================
-- 3. Derived (maintained by triggers and set_parent; checked by verify())
-- ============================================================================

-- Subject axis: principal is (transitively) in userset set_id#set_relation.
-- depth = length of the shortest path (1 = direct member).
create table permissions.memberships (
    principal_id  uuid not null,
    set_type      smallint not null,
    set_id        uuid not null,
    set_relation  smallint not null,
    depth         smallint not null,
    primary key (principal_id, set_id, set_relation)
);
create index memberships_by_set on permissions.memberships (set_id, set_relation) include (principal_id, set_type);

-- Ancestor closure, only for objects of container types (types that can be
-- a parent). Leaf objects (documents) store just their parent link, so moving
-- a folder rewrites rows for its sub-folders, never for its documents.
create table permissions.ancestors (
    object_type    smallint not null,
    object_id      uuid not null,
    ancestor_type  smallint not null,
    ancestor_id    uuid not null,
    depth          smallint not null,
    primary key (object_id, object_type, ancestor_id, ancestor_type)
);
create index ancestors_by_ancestor on permissions.ancestors (ancestor_id, ancestor_type) include (object_type, object_id);

-- ============================================================================
-- Identity
-- ============================================================================

-- JWT `sub` (PostgREST / Supabase) wins; the session setting is the fallback.
-- Anything that isn't a uuid is no subject.
create function permissions.current_subject_id()
returns uuid
language sql stable
set search_path = ''
as $$
    select case when s ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then s::uuid end
    from (select coalesce(
        nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', ''),
        nullif(current_setting('permissions.subject_id', true), '')
    ) as s) x
$$;

create function permissions.current_subject_type()
returns text
language sql stable
set search_path = ''
as $$
    select coalesce(nullif(current_setting('permissions.subject_type', true), ''), 'user')
$$;

create function permissions._uuid(p text)
returns uuid
language sql immutable
set search_path = ''
as $$
    select case when p ~* '^[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}$' then p::uuid end
$$;

-- ============================================================================
-- Locking. Every write that changes memberships or the ancestor closure takes
-- one global advisory lock, and is refused under repeatable read: the
-- snapshot is fixed before the lock is taken, so a concurrent writer's
-- committed rows would stay invisible and the derived rows would drift.
-- read committed (each statement after the lock sees fresh data) and
-- serializable (SSI aborts one of two conflicting writers) are safe.
-- ============================================================================

create function permissions._lock_graph()
returns void
language plpgsql
set search_path = ''
as $$
begin
    if current_setting('transaction_isolation') = 'repeatable read' then
        raise exception 'pg_permissions: group membership and parent changes are not allowed in repeatable read transactions'
            using errcode = '0A000',
                  hint = 'Run this write in read committed (the default) or serializable.';
    end if;
    perform pg_advisory_xact_lock(1885697139, 1);
end;
$$;

-- ============================================================================
-- Derived-data computation
-- ============================================================================

-- Every userset the given principals are in. Relations that imply a userset
-- relation count (org admin -> org#member). A principal's first hop is one of
-- its own tuples (to a direct set); the rest of every path is a walk between
-- usersets, so the walk runs once per distinct direct set, not once per
-- principal: recomputing a 1,000-member team walks up from that team once
-- instead of 1,000 times. depth = 1 + distance from the nearest direct set, so
-- a path longer than 10 shows up as depth 11. The walk follows only tuples of
-- relations that feed a userset, filtered in the index (tuples_userset ends in
-- `relation`), so a team's document grants are never visited.
create function permissions._memberships_for(p_principals uuid[])
returns table (principal_id uuid, set_type smallint, set_id uuid, set_relation smallint, depth int)
language plpgsql stable   -- not sql: Postgres 16 plans a non-inlined SQL function body on every call
set search_path = ''
as $$
begin
    return query
    with recursive feeds as materialized (   -- relation -> the userset relations it satisfies
        select s.relation_id, s.grants_id
        from permissions.satisfies s join permissions.relations u on u.id = s.grants_id and u.is_userset
        where not s.via_parent and not s.forbid
    ), direct as materialized (
        select t.subject_id as principal_id, t.object_type, t.object_id, f.grants_id
        from permissions.tuples t join feeds f on f.relation_id = t.relation
        where t.subject_id = any (p_principals) and t.subject_relation is null
    ), up(src_type, src_id, src_rel, set_type, set_id, set_relation, depth) as (
        select distinct d.object_type, d.object_id, d.grants_id, d.object_type, d.object_id, d.grants_id, 0
        from direct d
      union
        select w.src_type, w.src_id, w.src_rel, t.object_type, t.object_id, f.grants_id, w.depth + 1
        from up w
        join permissions.tuples t
          on t.subject_id = w.set_id and t.subject_relation = w.set_relation and t.subject_type = w.set_type
         and t.relation = any ((select array_agg(relation_id) from feeds)::smallint[])
        join feeds f on f.relation_id = t.relation
        where w.depth < 10
    )
    select d.principal_id, u.set_type, u.set_id, u.set_relation, min(u.depth + 1)::int
    from direct d
    join up u on u.src_id = d.object_id and u.src_rel = d.grants_id and u.src_type = d.object_type
    group by 1, 2, 3, 4;
end;
$$;

-- Every membership, walked per principal. Used by verify() and rebuild().
-- Deliberately not the set-level walk of _memberships_for and the insert
-- trigger: verify() is the drift oracle for the incremental code, so it keeps
-- its own, independent walk.
create function permissions._memberships_all()
returns table (principal_id uuid, set_type smallint, set_id uuid, set_relation smallint, depth int)
language sql stable
set search_path = ''
as $$
    with recursive walk(principal_id, set_type, set_id, set_relation, depth) as (
        select t.subject_id, t.object_type, t.object_id, s.grants_id, 1
        from permissions.tuples t
        join permissions.types pt on pt.id = t.subject_type and pt.principal
        join permissions.satisfies s on s.relation_id = t.relation and not s.via_parent and not s.forbid
        join permissions.relations u on u.id = s.grants_id and u.is_userset
        where t.subject_relation is null and t.subject_id is not null
      union
        select w.principal_id, t.object_type, t.object_id, s.grants_id, w.depth + 1
        from walk w
        join permissions.tuples t
          on t.subject_id = w.set_id and t.subject_relation = w.set_relation and t.subject_type = w.set_type
        join permissions.satisfies s on s.relation_id = t.relation and not s.via_parent and not s.forbid
        join permissions.relations u on u.id = s.grants_id and u.is_userset
        where w.depth <= 10
    )
    select principal_id, set_type, set_id, set_relation, min(depth)
    from walk group by 1, 2, 3, 4
$$;

-- Recompute the full membership set of each given principal and apply the
-- difference. Caller holds the graph lock.
create function permissions._recompute_memberships(p_principals uuid[])
returns void
language plpgsql
set search_path = ''
as $$
declare
    v_max int;
begin
    if p_principals is null or cardinality(p_principals) = 0 then
        return;
    end if;
    with target as (
        select * from permissions._memberships_for(p_principals)
    ), del as (
        delete from permissions.memberships m
        where m.principal_id = any (p_principals)
          and not exists (select 1 from target x
                          where x.principal_id = m.principal_id and x.set_id = m.set_id
                            and x.set_relation = m.set_relation)
        returning 1
    ), ins as (
        insert into permissions.memberships (principal_id, set_type, set_id, set_relation, depth)
        select principal_id, set_type, set_id, set_relation, depth from target
        on conflict (principal_id, set_id, set_relation) do update set depth = excluded.depth
        where memberships.depth <> excluded.depth
        returning 1
    )
    select max(depth) into v_max from target;
    if v_max > 10 then
        raise exception 'pg_permissions: group nesting deeper than 10 levels' using errcode = '54001';
    end if;
end;
$$;

-- Upward walk over parent links for the given container objects (or all).
create function permissions._ancestors_for(p_types smallint[], p_ids uuid[])
returns table (object_type smallint, object_id uuid, ancestor_type smallint, ancestor_id uuid, depth int)
language sql stable
set search_path = ''
as $$
    with recursive up(object_type, object_id, ancestor_type, ancestor_id, depth) as (
        select p.object_type, p.object_id, p.parent_type, p.parent_id, 1
        from permissions.parents p
        join permissions.types t on t.id = p.object_type and t.container
        where p_ids is null
           or (p.object_type, p.object_id) in (select * from unnest(p_types, p_ids))
      union all
        select u.object_type, u.object_id, p.parent_type, p.parent_id, u.depth + 1
        from up u
        join permissions.parents p on p.object_id = u.ancestor_id and p.object_type = u.ancestor_type
        where u.depth <= 10
    )
    select object_type, object_id, ancestor_type, ancestor_id, min(depth)
    from up group by 1, 2, 3, 4
$$;

-- Caller holds the graph lock.
create function permissions._recompute_ancestors(p_types smallint[], p_ids uuid[])
returns void
language plpgsql
set search_path = ''
as $$
begin
    delete from permissions.ancestors a
    using unnest(p_types, p_ids) s(t, i)
    where a.object_type = s.t and a.object_id = s.i;
    insert into permissions.ancestors (object_type, object_id, ancestor_type, ancestor_id, depth)
    select * from permissions._ancestors_for(p_types, p_ids);
    if exists (select 1 from permissions.ancestors a
               join unnest(p_types, p_ids) s(t, i) on a.object_type = s.t and a.object_id = s.i
               where a.depth > 10) then
        raise exception 'pg_permissions: parent chain deeper than 10 levels' using errcode = '54001';
    end if;
end;
$$;

-- The object and its container descendants, from the current closure.
create function permissions._subtree(p_type smallint, p_id uuid, out types smallint[], out ids uuid[])
language sql stable
set search_path = ''
as $$
    select array_agg(t), array_agg(i)
    from (select p_type, p_id
          union all
          select a.object_type, a.object_id from permissions.ancestors a
          where a.ancestor_id = p_id and a.ancestor_type = p_type) s(t, i)
$$;

-- ============================================================================
-- Triggers on tuples
-- ============================================================================

create function permissions._tuples_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if (new.object_type, new.object_id, new.relation, new.subject_type, new.subject_id, new.subject_relation)
       is distinct from
       (old.object_type, old.object_id, old.relation, old.subject_type, old.subject_id, old.subject_relation) then
        raise exception 'pg_permissions: tuples are immutable; revoke and grant instead' using errcode = '55000';
    end if;
    if new.expires_at is not null
       and (select feeds_userset from permissions.relations where id = new.relation) then
        raise exception 'pg_permissions: grants that change group membership cannot expire' using errcode = '0A000';
    end if;
    return new;
end;
$$;

create function permissions._tuples_after_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_bad record;
    v_max int;
begin
    -- Type check every new row against the compiled model, so even the owner
    -- can't insert an ill-typed tuple.
    select n.*, r.kind, r.type_id, r.feeds_userset into v_bad
    from new_rows n join permissions.relations r on r.id = n.relation
    where r.kind <> 'relation'
       or r.type_id <> n.object_type
       or (n.expires_at is not null and r.feeds_userset)
       or not exists (select 1 from permissions.allowed_subjects a
                      where a.relation_id = n.relation and a.subject_type = n.subject_type
                        and a.subject_relation is not distinct from n.subject_relation
                        and a.wildcard = (n.subject_id is null))
    limit 1;
    if found then
        raise exception 'pg_permissions: tuple does not match the model (relation %, subject type %, subject relation %)',
            v_bad.relation, v_bad.subject_type, v_bad.subject_relation using errcode = '23514';
    end if;

    if not exists (select 1 from new_rows n join permissions.relations r on r.id = n.relation where r.feeds_userset) then
        return null;   -- object grants: nothing to maintain
    end if;

    perform permissions._lock_graph();
    -- Insertions only add paths, so memberships only gain rows or get
    -- shorter: apply the delta instead of recomputing the affected principals.
    -- Take any new path from a principal to a set and the first new tuple on
    -- it, n (subject S, object O). The part before n uses only old tuples, so
    -- the principal is S itself or a member of S in the stored memberships
    -- (still in their pre-statement state); the part after n is an upward
    -- walk from O's usersets over the current tuples. So the candidates are
    -- (members of S) x (O's usersets and every set above them) with depth =
    -- depth in S + 1 + distance above O, and the new shortest depth is the
    -- least of that and the stored one. Every candidate is a real path, so
    -- nothing is over-granted. A set first reachable at depth 11 has a
    -- candidate of 11 (the walk goes 10 hops up), so the depth limit holds.
    with recursive feeds as materialized (   -- relation -> the userset relations it satisfies
        select s.relation_id, s.grants_id
        from permissions.satisfies s join permissions.relations u on u.id = s.grants_id and u.is_userset
        where not s.via_parent and not s.forbid
    ), edges as materialized (   -- new tuples that feed a userset, once per userset fed
        select n.object_type, n.object_id, f.grants_id, n.subject_id, n.subject_relation
        from new_rows n join feeds f on f.relation_id = n.relation
    ), up(src_type, src_id, src_rel, set_type, set_id, set_relation, depth) as (
        select distinct e.object_type, e.object_id, e.grants_id, e.object_type, e.object_id, e.grants_id, 0
        from edges e
      union
        select w.src_type, w.src_id, w.src_rel, t.object_type, t.object_id, f.grants_id, w.depth + 1
        from up w
        join permissions.tuples t
          on t.subject_id = w.set_id and t.subject_relation = w.set_relation and t.subject_type = w.set_type
         and t.relation = any ((select array_agg(relation_id) from feeds)::smallint[])
        join feeds f on f.relation_id = t.relation
        where w.depth < 10
    ), members as (   -- (edge, principal, depth in the edge's subject)
        select e.object_type, e.object_id, e.grants_id, e.subject_id as principal_id, 0 as depth
        from edges e where e.subject_relation is null
      union all
        select e.object_type, e.object_id, e.grants_id, m.principal_id, m.depth
        from edges e
        join permissions.memberships m on m.set_id = e.subject_id and m.set_relation = e.subject_relation
        where e.subject_relation is not null
    ), cand as materialized (
        select m.principal_id, u.set_type, u.set_id, u.set_relation, min(m.depth + 1 + u.depth) as depth
        from members m
        join up u on u.src_id = m.object_id and u.src_type = m.object_type and u.src_rel = m.grants_id
        group by 1, 2, 3, 4
    ), ins as (
        insert into permissions.memberships (principal_id, set_type, set_id, set_relation, depth)
        select principal_id, set_type, set_id, set_relation, depth from cand
        on conflict (principal_id, set_id, set_relation) do update set depth = excluded.depth
        where excluded.depth < memberships.depth
    )
    select max(c.depth) into v_max
    from cand c
    where c.depth > 10
      and not exists (select 1 from permissions.memberships m
                      where m.principal_id = c.principal_id and m.set_id = c.set_id
                        and m.set_relation = c.set_relation);
    if v_max > 10 then
        raise exception 'pg_permissions: group nesting deeper than 10 levels' using errcode = '54001';
    end if;
    return null;
end;
$$;

create function permissions._tuples_after_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if not exists (select 1 from old_rows o join permissions.relations r on r.id = o.relation where r.feeds_userset) then
        return null;
    end if;
    perform permissions._lock_graph();
    perform permissions._recompute_memberships(array(
        select o.subject_id
        from old_rows o join permissions.relations r on r.id = o.relation
        where r.feeds_userset and o.subject_relation is null
      union
        select m.principal_id
        from old_rows o join permissions.relations r on r.id = o.relation
        join permissions.memberships m on m.set_id = o.subject_id and m.set_relation = o.subject_relation
        where r.feeds_userset and o.subject_relation is not null));
    return null;
end;
$$;

create function permissions._tuples_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    raise exception 'pg_permissions: truncating tuples would leave memberships stale; delete rows or call rebuild()'
        using errcode = '55000';
end;
$$;

create trigger tuples_before_update before update on permissions.tuples
    for each row execute function permissions._tuples_before_update();
create trigger tuples_after_insert after insert on permissions.tuples
    referencing new table as new_rows
    for each statement execute function permissions._tuples_after_insert();
create trigger tuples_after_delete after delete on permissions.tuples
    referencing old table as old_rows
    for each statement execute function permissions._tuples_after_delete();
create trigger tuples_truncate before truncate on permissions.tuples
    for each statement execute function permissions._tuples_truncate();

-- ============================================================================
-- 4. Compiler
-- ============================================================================

create function permissions._is_text_array(j jsonb)
returns boolean
language sql immutable
set search_path = ''
as $$
    select jsonb_typeof(j) = 'array'
       and not exists (select 1 from jsonb_array_elements(j) e where jsonb_typeof(e) <> 'string')
$$;

-- Flattened views of a (shape-checked) model definition.
create function permissions._model_names(d jsonb)
returns table (type_name text, name text, kind text)
language sql immutable
set search_path = ''
as $$
    select t.key, r.key, 'relation'
    from jsonb_each(d -> 'types') t, jsonb_each(coalesce(t.value -> 'relations', '{}')) r
  union all
    select t.key, p.key, 'permission'
    from jsonb_each(d -> 'types') t, jsonb_each(coalesce(t.value -> 'permissions', '{}')) p
$$;

create function permissions._model_subjects(d jsonb)
returns table (type_name text, relation text, spec text, subject_type text, subject_relation text, wildcard boolean)
language sql immutable
set search_path = ''
as $$
    select t.key, r.key, s.value,
           case when s.value like '%#%' then split_part(s.value, '#', 1)
                when s.value like '%:*' then left(s.value, -2)
                else s.value end,
           case when s.value like '%#%' then split_part(s.value, '#', 2) end,
           s.value like '%:*'
    from jsonb_each(d -> 'types') t,
         jsonb_each(coalesce(t.value -> 'relations', '{}')) r,
         jsonb_array_elements_text(r.value) s
$$;

create function permissions._model_implies(d jsonb)
returns table (type_name text, holder text, implied text)
language sql immutable
set search_path = ''
as $$
    select t.key, i.key, x.value
    from jsonb_each(d -> 'types') t,
         jsonb_each(coalesce(t.value -> 'implies', '{}')) i,
         jsonb_array_elements_text(i.value) x
$$;

-- forbid = false: the item satisfies the permission; true: it vetoes it.
create function permissions._model_perm_items(d jsonb)
returns table (type_name text, permission text, item text, forbid boolean)
language sql immutable
set search_path = ''
as $$
    select t.key, p.key, x.value, false
    from jsonb_each(d -> 'types') t,
         jsonb_each(coalesce(t.value -> 'permissions', '{}')) p,
         jsonb_array_elements_text(case jsonb_typeof(p.value) when 'array' then p.value
                                        else coalesce(p.value -> 'any', '[]') end) x
  union all
    select t.key, p.key, x.value, true
    from jsonb_each(d -> 'types') t,
         jsonb_each(coalesce(t.value -> 'permissions', '{}')) p,
         jsonb_array_elements_text(case jsonb_typeof(p.value) when 'object'
                                        then coalesce(p.value -> 'but_not', '[]') else '[]' end) x
$$;

create function permissions._model_parents(d jsonb)
returns table (type_name text, parent_type text)
language sql immutable
set search_path = ''
as $$
    select t.key, x.value
    from jsonb_each(d -> 'types') t, jsonb_array_elements_text(coalesce(t.value -> 'parent', '[]')) x
$$;

-- What memberships depend on: userset relations and the relations that feed them.
create function permissions._memberships_fingerprint()
returns text
language sql stable
set search_path = ''
as $$
    select coalesce(string_agg(format('%s<%s', s.grants_id, s.relation_id), ',' order by s.grants_id, s.relation_id), '')
        || '|' || coalesce((select string_agg(id::text, ',' order by id) from permissions.types where principal), '')
    from permissions.satisfies s
    join permissions.relations u on u.id = s.grants_id and u.is_userset
    where not s.via_parent and not s.forbid
$$;

create function permissions._ancestors_fingerprint()
returns text
language sql stable
set search_path = ''
as $$
    select coalesce(string_agg(format('%s<%s', type_id, parent_type), ',' order by type_id, parent_type), '')
    from permissions.parent_types
$$;

create function permissions._rebuild_memberships()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
    v_n bigint;
begin
    perform permissions._lock_graph();
    delete from permissions.memberships;
    insert into permissions.memberships (principal_id, set_type, set_id, set_relation, depth)
    select * from permissions._memberships_all();
    get diagnostics v_n = row_count;
    if exists (select 1 from permissions.memberships where depth > 10) then
        raise exception 'pg_permissions: group nesting deeper than 10 levels' using errcode = '54001';
    end if;
    return v_n;
end;
$$;

create function permissions._rebuild_ancestors()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
    v_n bigint;
begin
    perform permissions._lock_graph();
    delete from permissions.ancestors;
    insert into permissions.ancestors (object_type, object_id, ancestor_type, ancestor_id, depth)
    select * from permissions._ancestors_for(null, null);
    get diagnostics v_n = row_count;
    if exists (select 1 from permissions.ancestors where depth > 10) then
        raise exception 'pg_permissions: parent chain deeper than 10 levels (or a cycle)' using errcode = '54001';
    end if;
    return v_n;
end;
$$;

-- Validate, diff against the catalog, compile, and record a new version.
-- p_def is the full definition (apply_model() adds the preset's types).
create function permissions._apply_model(p_def jsonb, p_dry_run boolean, p_force boolean)
returns table (change text, detail text)
language plpgsql
set search_path = ''
as $$
declare
    v_types   jsonb := p_def -> 'types';
    v_t       record;
    v_key     text;
    v_bad     text;
    v_n       bigint;
    v_fp_m    text;
    v_fp_a    text;
    v_changes text[] := '{}';
    v_details text[] := '{}';
    v_version int;
begin
    -- ---- shape ----------------------------------------------------------
    if jsonb_typeof(p_def) is distinct from 'object' or jsonb_typeof(v_types) is distinct from 'object' then
        raise exception 'model must be an object with a "types" object' using errcode = '22023';
    end if;
    for v_t in select key, value from jsonb_each(v_types) loop
        if v_t.key !~ '^[a-z][a-z0-9_]{0,62}$' then
            raise exception 'invalid type name "%"', v_t.key using errcode = '22023';
        end if;
        if jsonb_typeof(v_t.value) <> 'object' then
            raise exception 'type %: must be an object', v_t.key using errcode = '22023';
        end if;
        select string_agg(k, ', ') into v_bad from jsonb_object_keys(v_t.value) k
        where k not in ('principal', 'parent', 'relations', 'implies', 'permissions');
        if v_bad is not null then
            raise exception 'type %: unknown key(s) %', v_t.key, v_bad using errcode = '22023';
        end if;
        if v_t.value ? 'principal' and jsonb_typeof(v_t.value -> 'principal') <> 'boolean' then
            raise exception 'type %: "principal" must be true or false', v_t.key using errcode = '22023';
        end if;
        if v_t.value ? 'parent' and not permissions._is_text_array(v_t.value -> 'parent') then
            raise exception 'type %: "parent" must be an array of type names', v_t.key using errcode = '22023';
        end if;
        foreach v_key in array array['relations', 'implies'] loop
            if v_t.value ? v_key then
                if jsonb_typeof(v_t.value -> v_key) <> 'object' then
                    raise exception 'type %: "%" must be an object', v_t.key, v_key using errcode = '22023';
                end if;
                select string_agg(e.key, ', ') into v_bad from jsonb_each(v_t.value -> v_key) e
                where not permissions._is_text_array(e.value);
                if v_bad is not null then
                    raise exception 'type %: % entries must be arrays of strings (%)', v_t.key, v_key, v_bad using errcode = '22023';
                end if;
            end if;
        end loop;
        if v_t.value ? 'permissions' then
            if jsonb_typeof(v_t.value -> 'permissions') <> 'object' then
                raise exception 'type %: "permissions" must be an object', v_t.key using errcode = '22023';
            end if;
            select string_agg(e.key, ', ') into v_bad from jsonb_each(v_t.value -> 'permissions') e
            where not (permissions._is_text_array(e.value)
                       or (jsonb_typeof(e.value) = 'object'
                           and not exists (select 1 from jsonb_object_keys(e.value) k where k not in ('any', 'but_not'))
                           and permissions._is_text_array(coalesce(e.value -> 'any', '[]'))
                           and permissions._is_text_array(coalesce(e.value -> 'but_not', '[]'))));
            if v_bad is not null then
                raise exception 'type %: permission % must be an array of strings or {"any": [...], "but_not": [...]}', v_t.key, v_bad
                    using errcode = '22023';
            end if;
        end if;
    end loop;

    -- ---- names and references -------------------------------------------
    select string_agg(format('%s.%s', type_name, name), ', ') into v_bad
    from permissions._model_names(p_def) where name !~ '^[a-z][a-z0-9_.]{0,62}$';
    if v_bad is not null then
        raise exception 'invalid relation or permission name(s): %', v_bad using errcode = '22023';
    end if;

    select string_agg(format('%s.%s', type_name, name), ', ') into v_bad
    from (select type_name, name from permissions._model_names(p_def) group by 1, 2 having count(*) > 1) x;
    if v_bad is not null then
        raise exception 'name(s) used for both a relation and a permission: %', v_bad using errcode = '22023';
    end if;

    select string_agg(format('%s.%s', t.key, r.key), ', ') into v_bad
    from jsonb_each(v_types) t, jsonb_each(coalesce(t.value -> 'relations', '{}')) r
    where jsonb_array_length(r.value) = 0;
    if v_bad is not null then
        raise exception 'relation(s) accept no subjects: %', v_bad using errcode = '22023';
    end if;

    select string_agg(format('%s.%s: %s', s.type_name, s.relation, s.spec), ', ') into v_bad
    from permissions._model_subjects(p_def) s
    left join jsonb_each(v_types) st on st.key = s.subject_type
    where s.spec !~ '^[a-z][a-z0-9_]{0,62}(#[a-z][a-z0-9_.]{0,62}|:\*)?$'
       or st.key is null
       or (s.subject_relation is null and not coalesce((st.value ->> 'principal')::boolean, false))
       or (s.subject_relation is not null and not coalesce(st.value -> 'relations', '{}') ? s.subject_relation);
    if v_bad is not null then
        raise exception 'invalid subject(s) (a principal type, type:* for a principal type, or type#relation): %', v_bad
            using errcode = '22023';
    end if;

    select string_agg(format('%s: %s -> %s', i.type_name, i.holder, i.implied), ', ') into v_bad
    from permissions._model_implies(p_def) i
    where not exists (select 1 from permissions._model_names(p_def) n
                      where n.type_name = i.type_name and n.name = i.holder and n.kind = 'relation')
       or not exists (select 1 from permissions._model_names(p_def) n
                      where n.type_name = i.type_name and n.name = i.implied and n.kind = 'relation');
    if v_bad is not null then
        raise exception 'implies must name relations of the same type: %', v_bad using errcode = '22023';
    end if;

    select string_agg(format('%s.%s', p.type_name, p.parent_type), ', ') into v_bad
    from permissions._model_parents(p_def) p
    left join jsonb_each(v_types) pt on pt.key = p.parent_type
    where pt.key is null or coalesce((pt.value ->> 'principal')::boolean, false);
    if v_bad is not null then
        raise exception 'parent must name non-principal types: %', v_bad using errcode = '22023';
    end if;

    select string_agg(format('%s.%s: %s', i.type_name, i.permission, i.item), ', ') into v_bad
    from permissions._model_perm_items(p_def) i
    where case
        when i.item like 'parent->%' then
            i.forbid
            or i.item <> 'parent->' || i.permission
            or not exists (select 1 from permissions._model_parents(p_def) p where p.type_name = i.type_name)
        else not exists (select 1 from permissions._model_names(p_def) n
                         where n.type_name = i.type_name and n.name = i.item and n.kind = 'relation')
    end;
    if v_bad is not null then
        raise exception 'permission items must be relations of the same type, or parent->P inside permission P on a type with a parent: %', v_bad
            using errcode = '22023';
    end if;

    select string_agg(format('%s.%s', n.type_name, n.name), ', ') into v_bad
    from permissions._model_names(p_def) n
    where n.kind = 'permission'
      and not exists (select 1 from permissions._model_perm_items(p_def) i
                      where i.type_name = n.type_name and i.permission = n.name and not i.forbid);
    if v_bad is not null then
        raise exception 'permission(s) with nothing that grants them: %', v_bad using errcode = '22023';
    end if;

    -- Parent inheritance is all-or-nothing along a hierarchy: if X.P inherits
    -- P from its parent, every parent type must define P, and must inherit it
    -- too if it has parents of its own. That keeps "P on any ancestor" exact.
    with recursive clo(type_name, holder, target) as (
        select type_name, holder, implied from permissions._model_implies(p_def)
      union
        select c.type_name, i.holder, c.target
        from clo c join permissions._model_implies(p_def) i on i.type_name = c.type_name and i.implied = c.holder
    )
    select string_agg(distinct format('%s.%s', type_name, holder), ', ') into v_bad from clo where holder = target;
    if v_bad is not null then
        raise exception 'implies has a cycle through: %', v_bad using errcode = '22023';
    end if;

    select string_agg(format('%s.%s (parent type %s)', i.type_name, i.permission, pt.parent_type), ', ') into v_bad
    from permissions._model_perm_items(p_def) i
    join permissions._model_parents(p_def) pt on pt.type_name = i.type_name
    where i.item = 'parent->' || i.permission
      and (not exists (select 1 from permissions._model_names(p_def) n
                       where n.type_name = pt.parent_type and n.name = i.permission)
           or (exists (select 1 from permissions._model_parents(p_def) pp where pp.type_name = pt.parent_type)
               and not exists (select 1 from permissions._model_perm_items(p_def) j
                               where j.type_name = pt.parent_type and j.permission = i.permission
                                 and j.item = 'parent->' || i.permission)));
    if v_bad is not null then
        raise exception 'inherited permission(s) must be defined, and inherited again, by every parent type that has a parent: %', v_bad
            using errcode = '22023';
    end if;

    -- ---- unchanged? ------------------------------------------------------
    if p_def = (select m.definition from permissions.models m order by m.version desc limit 1) then
        return query select 'unchanged'::text, format('version %s', (select max(m.version) from permissions.models m));
        return;
    end if;

    perform pg_advisory_xact_lock(1885697139, 1);
    v_fp_m := permissions._memberships_fingerprint();
    v_fp_a := permissions._ancestors_fingerprint();

    begin   -- a dry run raises PP001 at the end, rolling back everything in this block
        -- ---- removals (tuples and parent links go first; force required) --
        for v_t in
            select t.id, t.name from permissions.types t
            where not v_types ? t.name
        loop
            select (select count(*) from permissions.tuples x where x.object_type = v_t.id or x.subject_type = v_t.id)
                 + (select count(*) from permissions.parents x where x.object_type = v_t.id or x.parent_type = v_t.id)
            into v_n;
            if v_n > 0 and not p_force and not p_dry_run then
                raise exception 'removing type % would delete % tuples and parent links; pass force => true', v_t.name, v_n
                    using errcode = '2BP01';
            end if;
            delete from permissions.tuples x where x.object_type = v_t.id or x.subject_type = v_t.id;
            delete from permissions.parents x where x.object_type = v_t.id or x.parent_type = v_t.id;
            delete from permissions.types where id = v_t.id;
            v_changes := v_changes || 'remove type'::text;
            v_details := v_details || format('%s%s', v_t.name, case when v_n > 0 then format(' (deletes %s rows, needs force)', v_n) else '' end);
        end loop;

        for v_t in
            select r.id, t.name as type_name, r.name, r.kind, n.kind as new_kind
            from permissions.relations r
            join permissions.types t on t.id = r.type_id
            left join permissions._model_names(p_def) n on n.type_name = t.name and n.name = r.name
            where n.kind is distinct from r.kind
        loop
            select count(*) into v_n from permissions.tuples x where x.relation = v_t.id or x.subject_relation = v_t.id;
            if v_n > 0 and not p_force and not p_dry_run then
                raise exception 'removing %.% would delete % tuples; pass force => true', v_t.type_name, v_t.name, v_n
                    using errcode = '2BP01';
            end if;
            delete from permissions.tuples x where x.relation = v_t.id or x.subject_relation = v_t.id;
            if v_t.new_kind is null then
                delete from permissions.relations where id = v_t.id;
                v_changes := v_changes || format('remove %s', v_t.kind);
            else
                update permissions.relations set kind = v_t.new_kind where id = v_t.id;
                v_changes := v_changes || format('change %s to %s', v_t.kind, v_t.new_kind);
            end if;
            v_details := v_details || format('%s.%s%s', v_t.type_name, v_t.name,
                                             case when v_n > 0 then format(' (deletes %s tuples, needs force)', v_n) else '' end);
        end loop;

        -- ---- additions ---------------------------------------------------
        with ins as (
            insert into permissions.types (name, principal)
            select t.key, coalesce((t.value ->> 'principal')::boolean, false) from jsonb_each(v_types) t
            on conflict (name) do update set principal = excluded.principal
            where types.principal <> excluded.principal
            returning name, xmax = 0 as added
        )
        select v_changes || array_agg(case when added then 'add type' else 'change principal' end),
               v_details || array_agg(name)
        into v_changes, v_details from ins having count(*) > 0;
        v_changes := coalesce(v_changes, '{}'); v_details := coalesce(v_details, '{}');

        with ins as (
            insert into permissions.relations (type_id, name, kind)
            select t.id, n.name, n.kind from permissions._model_names(p_def) n
            join permissions.types t on t.name = n.type_name
            on conflict (type_id, name) do nothing
            returning type_id, name, kind
        )
        select v_changes || array_agg('add ' || i.kind order by t.name, i.name),
               v_details || array_agg(t.name || '.' || i.name order by t.name, i.name)
        into v_changes, v_details
        from ins i join permissions.types t on t.id = i.type_id having count(*) > 0;
        v_changes := coalesce(v_changes, '{}'); v_details := coalesce(v_details, '{}');

        -- ---- compiled tables (rewritten) ---------------------------------
        delete from permissions.allowed_subjects;
        insert into permissions.allowed_subjects (relation_id, subject_type, subject_relation, wildcard)
        select r.id, st.id, sr.id, s.wildcard
        from permissions._model_subjects(p_def) s
        join permissions.types t on t.name = s.type_name
        join permissions.relations r on r.type_id = t.id and r.name = s.relation
        join permissions.types st on st.name = s.subject_type
        left join permissions.relations sr on sr.type_id = st.id and sr.name = s.subject_relation
        on conflict do nothing;

        delete from permissions.parent_types;
        insert into permissions.parent_types (type_id, parent_type)
        select t.id, pt.id from permissions._model_parents(p_def) p
        join permissions.types t on t.name = p.type_name
        join permissions.types pt on pt.name = p.parent_type
        on conflict do nothing;
        update permissions.types t set container = exists (select 1 from permissions.parent_types p where p.parent_type = t.id);

        update permissions.relations r set is_userset = exists (
            select 1 from permissions.allowed_subjects a where a.subject_relation = r.id);

        -- relations: reflexive + implies*
        delete from permissions.satisfies;
        insert into permissions.satisfies (grants_id, relation_id)
        with recursive imp as (
            select h.id as holder, x.id as implied
            from permissions._model_implies(p_def) i
            join permissions.types t on t.name = i.type_name
            join permissions.relations h on h.type_id = t.id and h.name = i.holder
            join permissions.relations x on x.type_id = t.id and x.name = i.implied
        ), clo(holder, target) as (
            select id, id from permissions.relations where kind = 'relation'
          union
            select i.holder, c.target from clo c join imp i on i.implied = c.holder
        )
        select target, holder from clo;

        -- permissions on their own type (permit and forbid)
        insert into permissions.satisfies (grants_id, relation_id, via_parent, forbid)
        select p.id, s.relation_id, false, i.forbid
        from permissions._model_perm_items(p_def) i
        join permissions.types t on t.name = i.type_name
        join permissions.relations p on p.type_id = t.id and p.name = i.permission
        join permissions.relations ir on ir.type_id = t.id and ir.name = i.item
        join permissions.satisfies s on s.grants_id = ir.id and not s.via_parent and not s.forbid
        where i.item not like 'parent->%'
        on conflict do nothing;

        -- parent->P: P's own-type rules of every type up the hierarchy apply
        -- to a tuple on any ancestor (exact because of the all-or-nothing rule)
        insert into permissions.satisfies (grants_id, relation_id, via_parent, forbid)
        with recursive up(root_perm, perm_name, type_id) as (
            select p.id, p.name, pt.parent_type
            from permissions._model_perm_items(p_def) i
            join permissions.types t on t.name = i.type_name
            join permissions.relations p on p.type_id = t.id and p.name = i.permission
            join permissions.parent_types pt on pt.type_id = t.id
            where i.item = 'parent->' || i.permission
          union
            select u.root_perm, u.perm_name, pt.parent_type
            from up u join permissions.parent_types pt on pt.type_id = u.type_id
        )
        select u.root_perm, s.relation_id, true, s.forbid
        from up u
        join permissions.relations r on r.type_id = u.type_id and r.name = u.perm_name
        join permissions.satisfies s on s.grants_id = r.id and not s.via_parent
        on conflict do nothing;

        update permissions.relations r set feeds_userset = exists (
            select 1 from permissions.satisfies s join permissions.relations u on u.id = s.grants_id
            where s.relation_id = r.id and u.is_userset and not s.via_parent and not s.forbid);

        -- ---- checks that need the compiled catalog -----------------------
        select string_agg(format('%s.%s', t.name, r.name), ', ') into v_bad
        from permissions.allowed_subjects a
        join permissions.relations r on r.id = a.relation_id
        join permissions.types t on t.id = r.type_id
        where a.wildcard and r.feeds_userset;
        if v_bad is not null then
            raise exception 'public (type:*) subjects are not allowed on relations that feed a userset: %', v_bad
                using errcode = '22023';
        end if;

        if exists (select 1 from permissions.tuples x join permissions.relations r on r.id = x.relation
                   where x.expires_at is not null and r.feeds_userset) then
            raise exception 'this model makes expiring grants feed a userset; revoke them first' using errcode = '22023';
        end if;

        -- existing data the new model no longer accepts
        select count(*) into v_n from permissions.tuples x
        where not exists (select 1 from permissions.allowed_subjects a
                          where a.relation_id = x.relation and a.subject_type = x.subject_type
                            and a.subject_relation is not distinct from x.subject_relation
                            and a.wildcard = (x.subject_id is null));
        if v_n > 0 then
            if not p_force and not p_dry_run then
                raise exception 'the new model rejects % existing tuples; pass force => true to delete them', v_n using errcode = '2BP01';
            end if;
            delete from permissions.tuples x
            where not exists (select 1 from permissions.allowed_subjects a
                              where a.relation_id = x.relation and a.subject_type = x.subject_type
                                and a.subject_relation is not distinct from x.subject_relation
                                and a.wildcard = (x.subject_id is null));
            v_changes := v_changes || 'delete tuples'::text;
            v_details := v_details || format('%s no longer allowed by the model (needs force)', v_n);
        end if;

        select count(*) into v_n from permissions.parents x
        where not exists (select 1 from permissions.parent_types p where p.type_id = x.object_type and p.parent_type = x.parent_type);
        if v_n > 0 then
            if not p_force and not p_dry_run then
                raise exception 'the new model rejects % existing parent links; pass force => true to delete them', v_n using errcode = '2BP01';
            end if;
            delete from permissions.parents x
            where not exists (select 1 from permissions.parent_types p where p.type_id = x.object_type and p.parent_type = x.parent_type);
            v_changes := v_changes || 'delete parent links'::text;
            v_details := v_details || format('%s no longer allowed by the model (needs force)', v_n);
        end if;

        -- ---- derived data ------------------------------------------------
        if permissions._memberships_fingerprint() <> v_fp_m then
            v_changes := v_changes || 'rebuild memberships'::text;
            v_details := v_details || 'usersets or what feeds them changed'::text;
            if not p_dry_run then
                perform permissions._rebuild_memberships();
            end if;
        end if;
        if permissions._ancestors_fingerprint() <> v_fp_a then
            v_changes := v_changes || 'rebuild ancestors'::text;
            v_details := v_details || 'parent types changed'::text;
            if not p_dry_run then
                perform permissions._rebuild_ancestors();
            end if;
        end if;

        insert into permissions.models (definition) values (p_def) returning version into v_version;
        v_changes := v_changes || 'version'::text;
        v_details := v_details || v_version::text;

        if p_dry_run then
            raise exception using errcode = 'PP001';
        end if;
    exception when sqlstate 'PP001' then
        v_changes := v_changes[1:cardinality(v_changes) - 1] || 'dry run'::text;
        v_details := v_details[1:cardinality(v_details) - 1] || 'nothing was changed'::text;
    end;

    return query select * from unnest(v_changes, v_details);
end;
$$;

-- The developer's model. Types `app` and `tenant` belong to the rbac preset
-- and are carried over from the active model; `user` is added if missing.
-- Defining or redefining them is refused (the check is on the top-level type
-- keys only), but naming one as a parent is supported: "parent": ["tenant"]
-- lets an object's permissions inherit the preset roles of its scope.
-- Returns the plan; executed unless dry_run. Removing relations or types that
-- still have grants needs force.
create function permissions.apply_model(p_definition jsonb, p_dry_run boolean default false, p_force boolean default false)
returns table (change text, detail text)
language plpgsql security definer
set search_path = ''
as $$
declare
    v_current jsonb := (select m.definition from permissions.models m order by m.version desc limit 1);
    v_types   jsonb := p_definition -> 'types';
begin
    if jsonb_typeof(v_types) is distinct from 'object' then
        raise exception 'model must be an object with a "types" object' using errcode = '22023';
    end if;
    if v_types ? 'app' or v_types ? 'tenant' then
        raise exception 'types app and tenant are managed by the rbac preset (create_role, drop_role); they can be named as parents but not defined' using errcode = '22023';
    end if;
    if not v_types ? 'user' then
        v_types := v_types || '{"user": {"principal": true}}';
    elsif (v_types #>> '{user,principal}') is distinct from 'true' then
        raise exception 'type user must be a principal ("principal": true)' using errcode = '22023';
    end if;
    v_types := v_types || jsonb_build_object('app', v_current #> '{types,app}', 'tenant', v_current #> '{types,tenant}');
    return query select * from permissions._apply_model(jsonb_build_object('types', v_types), p_dry_run, p_force);
end;
$$;

create function permissions.model()
returns jsonb
language sql stable security definer
set search_path = ''
as $$
    select definition from permissions.models order by version desc limit 1
$$;

-- ============================================================================
-- 5. Reads (internal: no privilege checks, called by the public wrappers)
-- ============================================================================

-- Rules for one check: which (relation, via_parent, forbid) satisfy or veto it.
-- Unknown type or permission names have no rules, so every read returns false
-- or empty rather than raising (same rule as the rbac preset, PLAN.md §6).

create function permissions._can(
    p_subject_type text, p_subject_id uuid,
    p_object_type text, p_object_id uuid, p_name text, p_kind text default null
)
returns boolean
language plpgsql stable
set search_path = ''
as $$
begin
    if p_subject_id is null or p_object_id is null then
        return false;
    end if;
    return (
        with g as (
            select r.id, r.type_id
            from permissions.relations r join permissions.types t on t.id = r.type_id
            where t.name = p_object_type and r.name = p_name and (p_kind is null or r.kind = p_kind)
        ), st as (
            select id from permissions.types where name = p_subject_type
        ), objs as (   -- the object, its parent and the parent's ancestors: no recursion
            select g.type_id as otype, p_object_id as oid, false as via_parent from g
          union all
            select p.parent_type, p.parent_id, true
            from g join permissions.parents p on p.object_id = p_object_id and p.object_type = g.type_id
          union all
            select a.ancestor_type, a.ancestor_id, true
            from g join permissions.parents p on p.object_id = p_object_id and p.object_type = g.type_id
            join permissions.ancestors a on a.object_id = p.parent_id and a.object_type = p.parent_type
        ), rules as (
            select o.otype, o.oid, s.relation_id, s.forbid
            from objs o join g on true
            join permissions.satisfies s on s.grants_id = g.id and s.via_parent = o.via_parent
        ), held as (
            select r.forbid    -- direct grant
            from rules r join permissions.tuples t
              on t.object_id = r.oid and t.relation = r.relation_id and t.object_type = r.otype
            where t.subject_type = (select id from st) and t.subject_id = p_subject_id and t.subject_relation is null
              and (t.expires_at is null or t.expires_at > now())
          union all
            select r.forbid    -- public grant
            from rules r join permissions.tuples t
              on t.object_id = r.oid and t.relation = r.relation_id and t.object_type = r.otype
            where t.subject_type = (select id from st) and t.subject_id is null and t.subject_relation is null
              and (t.expires_at is null or t.expires_at > now())
          union all
            select r.forbid    -- through a userset the subject is in (precomputed)
            from rules r
            join permissions.memberships m on m.principal_id = p_subject_id
            join permissions.tuples t
              on t.object_id = r.oid and t.relation = r.relation_id and t.object_type = r.otype
             and t.subject_type = m.set_type and t.subject_id = m.set_id and t.subject_relation = m.set_relation
            where t.expires_at is null or t.expires_at > now()
        )
        select coalesce(bool_or(not forbid), false) and not coalesce(bool_or(forbid), false) from held
    );
end;
$$;

-- Ids come back sorted and distinct. Sorted matters for RLS: an
-- `id = any (array)` index scan sorts its keys first, which is close to free
-- for an already sorted array, so the work isn't done twice. The sort also
-- does the dedup and the forbid veto (distinct on, forbid rows first).
create function permissions._accessible(
    p_subject_type text, p_subject_id uuid, p_object_type text, p_name text, p_kind text default null
)
returns uuid[]
language plpgsql stable
set search_path = ''
as $$
declare
    v_rel  smallint;
    v_type smallint;
    v_st   smallint;
begin
    if p_subject_id is null then
        return '{}';
    end if;
    select r.id, r.type_id into v_rel, v_type
    from permissions.relations r join permissions.types t on t.id = r.type_id
    where t.name = p_object_type and r.name = p_name and (p_kind is null or r.kind = p_kind);
    if v_rel is null then
        return '{}';
    end if;
    select id into v_st from permissions.types where name = p_subject_type;
    return (
        with held as materialized (   -- objects where the subject holds a relation that satisfies or vetoes
            select t.object_type, t.object_id, s.via_parent, s.forbid
            from permissions.satisfies s join permissions.tuples t on t.relation = s.relation_id
            where s.grants_id = v_rel
              and t.subject_id = p_subject_id and t.subject_relation is null and t.subject_type = v_st
              and (t.expires_at is null or t.expires_at > now())
          union all
            select t.object_type, t.object_id, s.via_parent, s.forbid
            from permissions.satisfies s join permissions.tuples t on t.relation = s.relation_id
            where s.grants_id = v_rel
              and t.subject_id is null and t.subject_type = v_st
              and (t.expires_at is null or t.expires_at > now())
          union all
            select t.object_type, t.object_id, s.via_parent, s.forbid
            from permissions.memberships m
            join permissions.tuples t
              on t.subject_id = m.set_id and t.subject_relation = m.set_relation and t.subject_type = m.set_type
            join permissions.satisfies s on s.relation_id = t.relation and s.grants_id = v_rel
            where m.principal_id = p_subject_id
              and (t.expires_at is null or t.expires_at > now())
        ), reach as (
            select h.object_id, h.forbid from held h where not h.via_parent
          union all   -- containers of the target type under a held ancestor
            select a.object_id, h.forbid
            from held h
            join permissions.ancestors a on a.ancestor_id = h.object_id and a.ancestor_type = h.object_type
            where h.via_parent and a.object_type = v_type
          union all   -- objects of the target type whose parent is a held ancestor ...
            select p.object_id, h.forbid
            from held h
            join permissions.parents p on p.parent_id = h.object_id and p.parent_type = h.object_type
            where h.via_parent and p.object_type = v_type
          union all   -- ... or one of its container descendants
            select p.object_id, h.forbid
            from held h
            join permissions.ancestors a on a.ancestor_id = h.object_id and a.ancestor_type = h.object_type
            join permissions.parents p on p.parent_id = a.object_id and p.parent_type = a.object_type
            where h.via_parent and p.object_type = v_type
        )
        select array(   -- permitted and not vetoed
            select x.object_id
            from (select distinct on (r.object_id) r.object_id, r.forbid
                  from reach r order by r.object_id, r.forbid desc) x
            where not x.forbid
            order by x.object_id)
    );
end;
$$;

-- Principals holding the permission. A public grant (user:*) can't be
-- enumerated, so it is one null row: "every principal of the grant's type",
-- like A's ('user', '*') row from list_subjects. The null row is not net of
-- per-principal forbids (they can't be listed as exceptions); a public forbid
-- empties the whole list, null row included.
create function permissions._who_can(p_object_type text, p_object_id uuid, p_name text, p_kind text default null)
returns setof uuid
language sql stable
set search_path = ''
as $$
    with g as (
        select r.id, r.type_id
        from permissions.relations r join permissions.types t on t.id = r.type_id
        where t.name = p_object_type and r.name = p_name and (p_kind is null or r.kind = p_kind)
    ), objs as (
        select g.type_id as otype, p_object_id as oid, false as via_parent from g
      union all
        select p.parent_type, p.parent_id, true
        from g join permissions.parents p on p.object_id = p_object_id and p.object_type = g.type_id
      union all
        select a.ancestor_type, a.ancestor_id, true
        from g join permissions.parents p on p.object_id = p_object_id and p.object_type = g.type_id
        join permissions.ancestors a on a.object_id = p.parent_id and a.object_type = p.parent_type
    ), grants as (
        select t.*, s.forbid
        from objs o join g on true
        join permissions.satisfies s on s.grants_id = g.id and s.via_parent = o.via_parent
        join permissions.tuples t on t.object_id = o.oid and t.object_type = o.otype and t.relation = s.relation_id
        where t.expires_at is null or t.expires_at > now()
    ), holders as (
        select subject_id as principal_id, forbid from grants where subject_relation is null and subject_id is not null
      union all
        select m.principal_id, x.forbid
        from grants x join permissions.memberships m
          on m.set_id = x.subject_id and m.set_relation = x.subject_relation and m.set_type = x.subject_type
        where x.subject_relation is not null
      union all
        select null::uuid, forbid from grants where subject_relation is null and subject_id is null
    )
    select principal_id from holders where not forbid
    except
    select principal_id from holders where forbid
    except
    select principal_id from holders where exists (select 1 from grants where forbid and subject_id is null)
$$;

-- Public reads. The current-subject variants are for clients and RLS; the
-- *_for variants and who_can are admin-only (see Privileges).

create function permissions.can(p_object_type text, p_object_id uuid, p_permission text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions._can(permissions.current_subject_type(), permissions.current_subject_id(),
                            p_object_type, p_object_id, p_permission)
$$;

create function permissions.accessible(p_object_type text, p_permission text)
returns uuid[]
language sql stable security definer
set search_path = ''
as $$
    select permissions._accessible(permissions.current_subject_type(), permissions.current_subject_id(),
                                   p_object_type, p_permission)
$$;

create function permissions.can_for(
    p_subject_type text, p_subject_id uuid, p_object_type text, p_object_id uuid, p_permission text
)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions._can(p_subject_type, p_subject_id, p_object_type, p_object_id, p_permission)
$$;

create function permissions.accessible_for(
    p_subject_type text, p_subject_id uuid, p_object_type text, p_permission text
)
returns uuid[]
language sql stable security definer
set search_path = ''
as $$
    select permissions._accessible(p_subject_type, p_subject_id, p_object_type, p_permission)
$$;

create function permissions.who_can(p_object_type text, p_object_id uuid, p_permission text)
returns setof uuid
language sql stable security definer
set search_path = ''
as $$
    select permissions._who_can(p_object_type, p_object_id, p_permission)
$$;

-- ============================================================================
-- 6. Writes
-- ============================================================================

create function permissions._type_id(p_name text)
returns smallint
language plpgsql stable
set search_path = ''
as $$
declare
    v smallint;
begin
    select id into v from permissions.types where name = p_name;
    if v is null then
        raise exception 'unknown type %', p_name using errcode = '22023';
    end if;
    return v;
end;
$$;

create function permissions._relation_id(p_type smallint, p_type_name text, p_name text)
returns smallint
language plpgsql stable
set search_path = ''
as $$
declare
    v smallint;
    k text;
begin
    select id, kind into v, k from permissions.relations where type_id = p_type and name = p_name;
    if v is null then
        raise exception 'unknown relation %.%', p_type_name, p_name using errcode = '22023';
    elsif k <> 'relation' then
        raise exception '%.% is a permission; grant one of the relations that satisfy it', p_type_name, p_name
            using errcode = '22023';
    end if;
    return v;
end;
$$;

-- Grant a relation on an object to a principal, or to a userset
-- (subject_relation, e.g. team#member). Granting again updates expires_at.
create function permissions.grant(
    p_object_type text, p_object_id uuid, p_relation text,
    p_subject_type text, p_subject_id uuid, p_subject_relation text default null,
    p_expires_at timestamptz default null
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    v_ot  smallint := permissions._type_id(p_object_type);
    v_rel smallint := permissions._relation_id(v_ot, p_object_type, p_relation);
    v_st  smallint := permissions._type_id(p_subject_type);
    v_sr  smallint;
begin
    if p_object_id is null or p_subject_id is null then
        raise exception 'object_id and subject_id are required (use grant_public for public access)' using errcode = '22004';
    end if;
    if nullif(p_subject_relation, '') is not null then
        v_sr := permissions._relation_id(v_st, p_subject_type, p_subject_relation);
    end if;
    if not exists (select 1 from permissions.allowed_subjects
                   where relation_id = v_rel and subject_type = v_st
                     and subject_relation is not distinct from v_sr and not wildcard) then
        raise exception '%.% does not accept subjects of type %', p_object_type, p_relation,
            p_subject_type || coalesce('#' || nullif(p_subject_relation, ''), '') using errcode = '22023';
    end if;
    if p_expires_at is not null and (select feeds_userset from permissions.relations where id = v_rel) then
        raise exception 'grants of %.% change group membership and cannot expire', p_object_type, p_relation
            using errcode = '0A000';
    end if;
    insert into permissions.tuples (object_type, object_id, relation, subject_type, subject_id, subject_relation, expires_at)
    values (v_ot, p_object_id, v_rel, v_st, p_subject_id, v_sr, p_expires_at)
    on conflict on constraint tuples_key do update set expires_at = excluded.expires_at
    where tuples.expires_at is distinct from excluded.expires_at;
end;
$$;

-- Bulk load: grant one relation for many (object, subject) pairs, paired by
-- position, in one statement. The names are checked once, and the insert
-- trigger maintains memberships once for the whole batch (one delta over
-- every new tuple) instead of once per grant. Pairs that already exist are
-- left alone. No expiry: use grant() for expiring grants. Returns the number
-- of new tuples.
create function permissions.grant_many(
    p_object_type text, p_relation text, p_subject_type text,
    p_object_ids uuid[], p_subject_ids uuid[], p_subject_relation text default null
)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
    v_ot  smallint := permissions._type_id(p_object_type);
    v_rel smallint := permissions._relation_id(v_ot, p_object_type, p_relation);
    v_st  smallint := permissions._type_id(p_subject_type);
    v_sr  smallint;
    v_n   bigint;
begin
    if cardinality(p_object_ids) is distinct from cardinality(p_subject_ids)
       or array_position(p_object_ids, null) is not null or array_position(p_subject_ids, null) is not null then
        raise exception 'object_ids and subject_ids must be arrays of the same length without nulls'
            using errcode = '22004';
    end if;
    if nullif(p_subject_relation, '') is not null then
        v_sr := permissions._relation_id(v_st, p_subject_type, p_subject_relation);
    end if;
    if not exists (select 1 from permissions.allowed_subjects
                   where relation_id = v_rel and subject_type = v_st
                     and subject_relation is not distinct from v_sr and not wildcard) then
        raise exception '%.% does not accept subjects of type %', p_object_type, p_relation,
            p_subject_type || coalesce('#' || nullif(p_subject_relation, ''), '') using errcode = '22023';
    end if;
    insert into permissions.tuples (object_type, object_id, relation, subject_type, subject_id, subject_relation)
    select v_ot, o, v_rel, v_st, s, v_sr
    from unnest(p_object_ids, p_subject_ids) x(o, s)
    on conflict on constraint tuples_key do nothing;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

create function permissions.revoke(
    p_object_type text, p_object_id uuid, p_relation text,
    p_subject_type text, p_subject_id uuid, p_subject_relation text default null
)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
    v_ot  smallint := permissions._type_id(p_object_type);
    v_rel smallint := permissions._relation_id(v_ot, p_object_type, p_relation);
    v_st  smallint := permissions._type_id(p_subject_type);
    v_sr  smallint;
begin
    if nullif(p_subject_relation, '') is not null then
        v_sr := permissions._relation_id(v_st, p_subject_type, p_subject_relation);
    end if;
    delete from permissions.tuples
    where object_id = p_object_id and relation = v_rel and subject_type = v_st
      and subject_id = p_subject_id and subject_relation is not distinct from v_sr;
    return found;
end;
$$;

-- Public access: every principal of subject_type (default user) holds the
-- relation. The model must allow it ("viewer": ["user", "user:*"]).
create function permissions.grant_public(
    p_object_type text, p_object_id uuid, p_relation text, p_subject_type text default 'user'
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    v_ot  smallint := permissions._type_id(p_object_type);
    v_rel smallint := permissions._relation_id(v_ot, p_object_type, p_relation);
    v_st  smallint := permissions._type_id(p_subject_type);
begin
    if not exists (select 1 from permissions.allowed_subjects
                   where relation_id = v_rel and subject_type = v_st and wildcard) then
        raise exception '%.% does not accept %:*', p_object_type, p_relation, p_subject_type using errcode = '22023';
    end if;
    insert into permissions.tuples (object_type, object_id, relation, subject_type, subject_id)
    values (v_ot, p_object_id, v_rel, v_st, null)
    on conflict on constraint tuples_key do nothing;
end;
$$;

create function permissions.revoke_public(
    p_object_type text, p_object_id uuid, p_relation text, p_subject_type text default 'user'
)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
    v_ot  smallint := permissions._type_id(p_object_type);
    v_rel smallint := permissions._relation_id(v_ot, p_object_type, p_relation);
    v_st  smallint := permissions._type_id(p_subject_type);
begin
    delete from permissions.tuples
    where object_id = p_object_id and relation = v_rel and subject_type = v_st and subject_id is null;
    return found;
end;
$$;

-- Set (or move) an object's parent. Containers (types that can themselves be
-- parents) take the graph lock; cycles are rejected here, on write.
create function permissions.set_parent(
    p_object_type text, p_object_id uuid, p_parent_type text, p_parent_id uuid
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    v_ot  smallint := permissions._type_id(p_object_type);
    v_pt  smallint := permissions._type_id(p_parent_type);
    v_types smallint[];
    v_ids   uuid[];
begin
    if p_object_id is null or p_parent_id is null then
        raise exception 'object_id and parent_id are required (use unset_parent)' using errcode = '22004';
    end if;
    if not exists (select 1 from permissions.parent_types where type_id = v_ot and parent_type = v_pt) then
        raise exception 'a % cannot have a parent of type %', p_object_type, p_parent_type using errcode = '22023';
    end if;
    if (select container from permissions.types where id = v_ot) then
        perform permissions._lock_graph();
        select types, ids into v_types, v_ids from permissions._subtree(v_ot, p_object_id);
        if exists (select 1 from unnest(v_types, v_ids) s(t, i) where s.t = v_pt and s.i = p_parent_id) then
            raise exception 'parent cycle: % % is % % or one of its descendants',
                p_parent_type, p_parent_id, p_object_type, p_object_id using errcode = '23514';
        end if;
    end if;
    insert into permissions.parents (object_type, object_id, parent_type, parent_id)
    values (v_ot, p_object_id, v_pt, p_parent_id)
    on conflict (object_id, object_type) do update
    set parent_type = excluded.parent_type, parent_id = excluded.parent_id;
    if v_types is not null then
        perform permissions._recompute_ancestors(v_types, v_ids);
    end if;
end;
$$;

create function permissions.unset_parent(p_object_type text, p_object_id uuid)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
    v_ot    smallint := permissions._type_id(p_object_type);
    v_types smallint[];
    v_ids   uuid[];
begin
    if (select container from permissions.types where id = v_ot) then
        perform permissions._lock_graph();
        select types, ids into v_types, v_ids from permissions._subtree(v_ot, p_object_id);
    end if;
    delete from permissions.parents where object_id = p_object_id and object_type = v_ot;
    if not found then
        return false;
    end if;
    if v_types is not null then
        perform permissions._recompute_ancestors(v_types, v_ids);
    end if;
    return true;
end;
$$;

-- Cleanup (PLAN.md §3). forget_subject removes every grant to a principal;
-- forget_object removes every grant on an object, grants to its usersets,
-- and its parent links (children become roots).
create function permissions.forget_subject(p_subject_id uuid)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
    v_n bigint;
begin
    delete from permissions.tuples where subject_id = p_subject_id and subject_relation is null;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

create function permissions.forget_object(p_object_type text, p_object_id uuid)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
    v_ot    smallint := permissions._type_id(p_object_type);
    v_n     bigint;
    v_types smallint[];
    v_ids   uuid[];
begin
    delete from permissions.tuples
    where (object_type = v_ot and object_id = p_object_id)
       or (subject_type = v_ot and subject_id = p_object_id);
    get diagnostics v_n = row_count;
    if (select container from permissions.types where id = v_ot) then
        perform permissions._lock_graph();
        select types, ids into v_types, v_ids from permissions._subtree(v_ot, p_object_id);
        delete from permissions.parents
        where (object_id = p_object_id and object_type = v_ot) or (parent_id = p_object_id and parent_type = v_ot);
        perform permissions._recompute_ancestors(v_types, v_ids);
    else
        delete from permissions.parents where object_id = p_object_id and object_type = v_ot;
    end if;
    return v_n;
end;
$$;

-- Trigger functions the app attaches to its own tables (the extension has no
-- FKs to app tables). Columns are read through to_jsonb(old): no dynamic SQL.
--   create trigger ... after delete on public.profiles
--     for each row execute function permissions.on_subject_deleted('id');
--   create trigger ... after delete on public.documents
--     for each row execute function permissions.on_object_deleted('document', 'id');
create function permissions.on_subject_deleted()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
    perform permissions.forget_subject((to_jsonb(old) ->> tg_argv[0])::uuid);
    return old;
end;
$$;

create function permissions.on_object_deleted()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
    perform permissions.forget_object(tg_argv[0], (to_jsonb(old) ->> tg_argv[1])::uuid);
    return old;
end;
$$;

-- ============================================================================
-- 7. Drift detection and repair
-- ============================================================================

-- Recompute memberships and the ancestor closure from scratch and diff them
-- against the stored rows. No rows = no drift.
create function permissions.verify()
returns table (kind text, member_id uuid, set_key text, problem text)
language sql stable security definer
set search_path = ''
as $$
    with want as (select * from permissions._memberships_all()),
    diff as (
        select coalesce(w.principal_id, m.principal_id) as member_id,
               coalesce(w.set_type, m.set_type) as set_type,
               coalesce(w.set_id, m.set_id) as set_id,
               coalesce(w.set_relation, m.set_relation) as set_relation,
               case when m.principal_id is null then 'missing'
                    when w.principal_id is null then 'extra'
                    else format('depth %s, should be %s', m.depth, w.depth) end as problem
        from want w
        full join permissions.memberships m
          on m.principal_id = w.principal_id and m.set_id = w.set_id and m.set_relation = w.set_relation
        where m.principal_id is null or w.principal_id is null or m.depth <> w.depth or m.set_type <> w.set_type
    )
    select 'membership', d.member_id,
           format('%s:%s#%s', coalesce(t.name, d.set_type::text), d.set_id, coalesce(r.name, d.set_relation::text)),
           d.problem
    from diff d
    left join permissions.types t on t.id = d.set_type
    left join permissions.relations r on r.id = d.set_relation
  union all
    select 'ancestor', coalesce(w.object_id, a.object_id),
           format('%s:%s', coalesce(t.name, coalesce(w.ancestor_type, a.ancestor_type)::text), coalesce(w.ancestor_id, a.ancestor_id)),
           case when a.object_id is null then 'missing'
                when w.object_id is null then 'extra'
                else format('depth %s, should be %s', a.depth, w.depth) end
    from permissions._ancestors_for(null, null) w
    full join permissions.ancestors a
      on a.object_id = w.object_id and a.object_type = w.object_type
     and a.ancestor_id = w.ancestor_id and a.ancestor_type = w.ancestor_type
    left join permissions.types t on t.id = coalesce(w.ancestor_type, a.ancestor_type)
    where a.object_id is null or w.object_id is null or a.depth <> w.depth
$$;

-- Throw away and recompute all derived rows. Returns the number of rows written.
create function permissions.rebuild()
returns bigint
language sql security definer
set search_path = ''
as $$
    select permissions._rebuild_memberships() + permissions._rebuild_ancestors()
$$;

-- ============================================================================
-- 8. rbac preset (PLAN.md §6)
--
-- Roles live on two preset-owned types: `app` (one object, the nil uuid) for
-- app-wide roles, and `tenant` (one object per scope). Each role is a relation
-- on both, `inherits` compiles to `implies`, and each permission is a
-- permission on both. create_role / drop_role edit the active model and
-- recompile it. Signatures take text IDs exactly as in PLAN.md §6, so the
-- preset API is identical across designs; the IDs are uuids underneath.
-- ============================================================================

create function permissions._scope(p_scope text, out type_name text, out object_id uuid)
language sql immutable
set search_path = ''
as $$
    select case when p_scope is null then 'app' else 'tenant' end,
           case when p_scope is null then '00000000-0000-0000-0000-000000000000'::uuid
                else permissions._uuid(p_scope) end
$$;

-- The active (full) model, which the preset edits.
create function permissions._preset_model()
returns jsonb
language sql stable
set search_path = ''
as $$
    select definition from permissions.models order by version desc limit 1
$$;

create function permissions.create_role(p_role text, p_permissions text[], p_inherits text[] default '{}')
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    v_def jsonb := permissions._preset_model();
    v_t   text;
    v_p   text;
begin
    if v_def #> array['types', 'app', 'relations', p_role] is not null then
        raise exception 'role % already exists', p_role using errcode = '23505';
    end if;
    foreach v_t in array array['app', 'tenant'] loop
        v_def := jsonb_set(v_def, array['types', v_t, 'relations', p_role], '["user"]');
        if cardinality(p_inherits) > 0 then
            v_def := jsonb_set(v_def, array['types', v_t, 'implies', p_role], to_jsonb(p_inherits));
        end if;
        foreach v_p in array p_permissions loop
            v_def := jsonb_set(v_def, array['types', v_t, 'permissions', v_p],
                               coalesce(v_def #> array['types', v_t, 'permissions', v_p], '[]') || to_jsonb(p_role));
        end loop;
    end loop;
    perform permissions._apply_model(v_def, false, false);
end;
$$;

create function permissions.drop_role(p_role text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    v_def  jsonb := permissions._preset_model();
    v_t    text;
    v_heir text;
begin
    if v_def #> array['types', 'app', 'relations', p_role] is null then
        raise exception 'unknown role %', p_role using errcode = '22023';
    end if;
    select i.key into v_heir from jsonb_each(v_def #> '{types,app,implies}') i
    where i.value ? p_role limit 1;
    if v_heir is not null then
        raise exception 'role % is inherited by %', p_role, v_heir using errcode = '2BP01';
    end if;
    foreach v_t in array array['app', 'tenant'] loop
        v_def := v_def #- array['types', v_t, 'relations', p_role]
                       #- array['types', v_t, 'implies', p_role];
        v_def := jsonb_set(v_def, array['types', v_t, 'permissions'], coalesce((
            select jsonb_object_agg(p.key, p.value - p_role)
            from jsonb_each(v_def #> array['types', v_t, 'permissions']) p
            where p.value - p_role <> '[]'), '{}'));
    end loop;
    -- force: the role's assignments are deleted with it
    perform permissions._apply_model(v_def, false, true);
end;
$$;

create function permissions._role_exists(p_role text)
returns boolean
language sql stable
set search_path = ''
as $$
    select exists (select 1 from permissions.relations r join permissions.types t on t.id = r.type_id
                   where t.name = 'app' and r.name = p_role and r.kind = 'relation')
$$;

create function permissions.assign_role(p_user_id text, p_role text, p_scope text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    if not permissions._role_exists(p_role) then
        raise exception 'unknown role %', p_role using errcode = '22023';
    end if;
    perform permissions.grant(case when p_scope is null then 'app' else 'tenant' end,
                              coalesce(p_scope::uuid, '00000000-0000-0000-0000-000000000000'),
                              p_role, 'user', p_user_id::uuid);
end;
$$;

create function permissions.unassign_role(p_user_id text, p_role text, p_scope text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    if permissions._role_exists(p_role) then
        perform permissions.revoke(case when p_scope is null then 'app' else 'tenant' end,
                                   coalesce(p_scope::uuid, '00000000-0000-0000-0000-000000000000'),
                                   p_role, 'user', p_user_id::uuid);
    end if;
end;
$$;

create function permissions.has_permission(p_permission text, p_scope text default null)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions._can(permissions.current_subject_type(), permissions.current_subject_id(),
                            s.type_name, s.object_id, p_permission, 'permission')
    from permissions._scope(p_scope) s
$$;

-- uuid overload: lets RLS pass a uuid column without a cast.
create function permissions.has_permission(p_permission text, p_scope uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions._can(permissions.current_subject_type(), permissions.current_subject_id(),
                            'tenant', p_scope, p_permission, 'permission')
$$;

create function permissions.has_role(p_role text, p_scope text default null)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions._can(permissions.current_subject_type(), permissions.current_subject_id(),
                            s.type_name, s.object_id, p_role, 'relation')
    from permissions._scope(p_scope) s
$$;

create function permissions.has_role(p_role text, p_scope uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select permissions._can(permissions.current_subject_type(), permissions.current_subject_id(),
                            'tenant', p_scope, p_role, 'relation')
$$;

-- RLS fast path for tenant scoping. text[] as in PLAN.md §6; policies use
-- org_id = any (array(select unnest(permissions.scopes_with_permission(...))::uuid)).
--
-- STABLE, with a trailing argument whose default is a volatile function that
-- returns null (_unfolded_null). Inside array(select unnest(...)) the planner
-- estimates the unnest's row count by pre-evaluating a STABLE function whose
-- arguments are all constants, so the whole call ran at plan time and again at
-- execution. A volatile argument isn't a constant, so the call isn't folded.
-- (Marking the function VOLATILE also stops the folding, but under read
-- committed a volatile function takes a fresh snapshot per query, so the
-- grants would be read at a later instant than the rows the statement filters.)
-- p_unfold is ignored. accessible() stays as it is: the policy form
-- (select accessible(...))::uuid[] isn't pre-evaluated.
create function permissions._unfolded_null()
returns boolean
language plpgsql volatile
as $$
begin
    return null;
end;
$$;

create function permissions.scopes_with_permission(p_permission text,
                                                   p_unfold boolean default permissions._unfolded_null())
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select array(select x::text from unnest(permissions._accessible(
        permissions.current_subject_type(), permissions.current_subject_id(), 'tenant', p_permission, 'permission')) x)
$$;

create function permissions.user_permissions(p_user_id text, p_scope text default null)
returns text[]
language sql stable security definer
set search_path = ''
as $$
    select coalesce(array_agg(r.name order by r.name), '{}')
    from permissions._scope(p_scope) s
    join permissions.types t on t.name = s.type_name
    join permissions.relations r on r.type_id = t.id and r.kind = 'permission'
    where permissions._can('user', permissions._uuid(p_user_id), s.type_name, s.object_id, r.name, 'permission')
$$;

create function permissions.users_with_role(p_role text, p_scope text default null)
returns setof text
language sql stable security definer
set search_path = ''
as $$
    select w::text
    from permissions._scope(p_scope) s,
         permissions._who_can(s.type_name, s.object_id, p_role, 'relation') w
$$;

-- ============================================================================
-- Initial model: the principal type and the preset's (empty) role types
-- ============================================================================

select count(*) from permissions._apply_model('{
  "types": {
    "user":   {"principal": true},
    "app":    {"relations": {}, "implies": {}, "permissions": {}},
    "tenant": {"relations": {}, "implies": {}, "permissions": {}}
  }
}', false, false);

-- ============================================================================
-- Privileges
-- ============================================================================

-- RLS on with no policies: nothing is reachable except through the
-- security-definer functions (defence in depth on top of the revokes).
alter table permissions.models           enable row level security;
alter table permissions.types            enable row level security;
alter table permissions.relations        enable row level security;
alter table permissions.allowed_subjects enable row level security;
alter table permissions.parent_types     enable row level security;
alter table permissions.satisfies        enable row level security;
alter table permissions.tuples           enable row level security;
alter table permissions.parents          enable row level security;
alter table permissions.memberships      enable row level security;
alter table permissions.ancestors        enable row level security;

revoke all on all tables in schema permissions from public;
revoke all on all sequences in schema permissions from public;
revoke all on all functions in schema permissions from public;
grant usage on schema permissions to public;

-- Client-facing: current subject only.
grant execute on function
    permissions.current_subject_id(),
    permissions.current_subject_type(),
    permissions.can(text, uuid, text),
    permissions.accessible(text, text),
    permissions.has_permission(text, text),
    permissions.has_permission(text, uuid),
    permissions.has_role(text, text),
    permissions.has_role(text, uuid),
    permissions.scopes_with_permission(text, boolean),
    permissions._unfolded_null()
to public;

-- Everything else (model, grants, parents, explicit-subject reads, who_can,
-- verify/rebuild, role management) is for the owner and whichever trusted
-- roles the app grants, e.g. service_role.
