/*
 * pg_crdt
 *
 * Copyright (c) 2026 Paul Copplestone: https://github.com/kiwicopple/pg-extensions/
 *
 * CRDTs (conflict-free replicated data types) for Postgres, in SQL and
 * PL/pgSQL only. Design: research/architecture.md. One schema, `crdt`, with a
 * name prefix per algorithm variant; internals start with `_`.
 *
 *   pn_*   PN-Counter: per-replica grow-only totals of increments (p) and
 *          decrements (n); value = sum(p) - sum(n); merge = per-key max.
 *
 * State is jsonb with a versioned envelope, typed by a domain per variant:
 *
 *   crdt.pn   {"t": "pn", "v": 1, "p": {replica: count}, "n": {replica: count}}
 *
 * Safe write: one statement that merges in the SET clause,
 *
 *   update t set s = crdt.pn_merge(s, $1) where id = $2;
 *
 * never a read in the client followed by a write of the merged value.
 *
 * Installs with CREATE EXTENSION (pg_tle, or pg_crdt.control in the extension
 * directory) or as a plain script (psql -f). Version 0.0.1.
 *
 *   ./test/run.sh
 */

-- With CREATE EXTENSION (the control file's schema = crdt, or pg_tle's
-- install_extension(..., schema => 'crdt')), the schema already exists. A
-- plain install (psql -f) creates it here. No "if not exists": in an
-- extension script, that form errors on a schema the extension does not own.
do $$
begin
    if pg_catalog.to_regnamespace('crdt') is null then
        create schema crdt;
    end if;
end;
$$;

-- A schema that already exists must be the installer's. Its owner, and any
-- role with CREATE on it, could drop or replace the functions below, and with
-- them the domain check and the identity check of pn_apply_delta. A
-- superuser's schema is trusted.
do $$
declare
    s record;
begin
    select n.nspowner, n.nspacl, r.rolname, r.rolsuper into s
    from pg_catalog.pg_namespace n join pg_catalog.pg_roles r on r.oid = n.nspowner
    where n.nspname = 'crdt';
    if s.rolname <> current_user and not s.rolsuper then
        raise exception 'schema crdt is owned by role %, not by the installing role %', s.rolname, current_user
            using errcode = '42501',
                  hint = 'Drop the schema, or install as its owner. Another owner could replace the CRDT functions.';
    end if;
    if exists (select 1 from pg_catalog.aclexplode(s.nspacl) a
               where a.privilege_type = 'CREATE' and a.grantee <> s.nspowner) then
        raise exception 'another role has CREATE on schema crdt'
            using errcode = '42501',
                  hint = 'Revoke CREATE on schema crdt from every role but its owner, then install again.';
    end if;
end;
$$;

-- Names inside function bodies. The SQL functions use SQL-standard bodies
-- (RETURN): Postgres parses them once, here, and stores
-- references to the objects, so a caller's search_path cannot change what they
-- call, and they still inline. The PL/pgSQL functions name crdt objects with
-- the schema and use only pg_catalog otherwise, so they work under the
-- search_path = pg_catalog, pg_temp that maintenance commands (VACUUM,
-- REINDEX) use for index expressions and generated columns on Postgres 17+.
-- Functions that decide on the caller's identity also pin search_path; the
-- pure ones do not, because a SET clause costs a GUC save and restore per call
-- and stops a SQL function from being inlined.

-- ============================================================================
-- Shared: the caller's replica id
-- ============================================================================

-- The JWT `sub` claim (PostgREST, Supabase) wins; the crdt.replica_id session
-- setting is the fallback for plain Postgres, tests and server-side jobs. The
-- same rule as pg_permissions' current_subject_id(). Both settings are only as
-- trustworthy as whoever sets them: PostgREST sets request.jwt.claims from a
-- verified JWT, but a role with direct SQL access can set either one itself.
create function crdt.current_replica_id()
returns text
language plpgsql stable
set search_path = pg_catalog, pg_temp
as $$
begin
    return coalesce(
        nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', ''),
        nullif(current_setting('crdt.replica_id', true), '')
    );
end;
$$;

-- ============================================================================
-- pn_: PN-Counter
-- ============================================================================

-- The domain's CHECK is the envelope only: a JSON object with exactly the
-- keys t, v, p and n, t = "pn", v = 1, p and n objects. It runs on every
-- crdt.pn made from jsonb, including every merge and increment result
-- (test/spec/40_open_questions.sql), so it must not walk the entries.
-- Containment (@>) reads the binary value in place, and `- text[]` copies
-- the nested maps as opaque blobs; `value -> 'p'` or jsonpath's keyvalue()
-- would copy or re-encode the maps. Measured on a 10,000-replica state: about
-- 10 us, where checking every entry takes about 4 ms, more than a merge
-- (research/benchmarks/pn-counter.md).
--
-- The entries are not checked by the domain. Merge does not need them to be
-- valid to converge: it takes the larger entry under jsonb's total order,
-- which is a semilattice for any values (test/spec/10_merge_laws.sql). Entry
-- validation is crdt.pn_is_valid, which pn_apply_delta (the path for
-- untrusted input) enforces, and which a table can add as a CHECK.
--
-- Not a function call: a CHECK passes on null, and every part of this
-- expression is non-null for a non-null value, so it needs no coalesce.
create domain crdt.pn as jsonb
    check (
        jsonb_typeof(value) = 'object'
        and value @> '{"t": "pn", "v": 1, "p": {}, "n": {}}'
        and (value - '{t,v,p,n}'::text[]) = '{}'::jsonb
    );

comment on domain crdt.pn is
    'PN-Counter state: {"t": "pn", "v": 1, "p": {replica: count}, "n": {replica: count}}. Dropping the extension with CASCADE drops every column of this type.';

-- The full validator: the envelope (as the domain) and every entry an integer
-- from 0 to the bigint maximum. One jsonpath scan per map, in C, without
-- building rows. Null for null. Use it where states come from outside:
-- pn_apply_delta calls it, and a table can add check (crdt.pn_is_valid(s)).
create function crdt.pn_is_valid(state jsonb)
returns boolean
language sql immutable parallel safe
return case when state is null then null else coalesce(
    jsonb_typeof(state) = 'object'
    and state @> '{"t": "pn", "v": 1, "p": {}, "n": {}}'
    and (state - '{t,v,p,n}'::text[]) = '{}'::jsonb
    and not state @? '$.p.* ? (@.type() != "number" || @ < 0 || @ > 9223372036854775807 || @.floor() != @)'
    and not state @? '$.n.* ? (@.type() != "number" || @ < 0 || @ > 9223372036854775807 || @.floor() != @)',
    false)
end;

create function crdt.pn_empty()
returns crdt.pn
language sql immutable parallel safe
return '{"t": "pn", "v": 1, "p": {}, "n": {}}'::crdt.pn;

-- Adds `amount` to the caller-supplied replica's entry in p. A null state
-- counts as empty. The amount must be zero or more (0 is a no-op).
create function crdt.pn_increment(state crdt.pn, replica text, amount bigint default 1)
returns crdt.pn
language plpgsql immutable parallel safe
as $$
begin
    if replica is null or amount is null then
        raise exception 'crdt.pn_increment: replica and amount must not be null'
            using errcode = '22004';
    end if;
    if replica = '' then
        raise exception 'crdt.pn_increment: replica must not be empty' using errcode = '22023';
    end if;
    if amount < 0 then
        raise exception 'crdt.pn_increment: amount must be zero or more, got %', amount
            using errcode = '22023', hint = 'Use crdt.pn_decrement to count down.';
    end if;
    if state is null then
        state := crdt.pn_empty();
    end if;
    if amount = 0 then
        return state;
    end if;
    return jsonb_set(state, array['p', replica],
                     to_jsonb(coalesce((state -> 'p' -> replica)::bigint, 0) + amount));
end;
$$;

-- Adds `amount` to the replica's entry in n.
create function crdt.pn_decrement(state crdt.pn, replica text, amount bigint default 1)
returns crdt.pn
language plpgsql immutable parallel safe
as $$
begin
    if replica is null or amount is null then
        raise exception 'crdt.pn_decrement: replica and amount must not be null'
            using errcode = '22004';
    end if;
    if replica = '' then
        raise exception 'crdt.pn_decrement: replica must not be empty' using errcode = '22023';
    end if;
    if amount < 0 then
        raise exception 'crdt.pn_decrement: amount must be zero or more, got %', amount
            using errcode = '22023', hint = 'Use crdt.pn_increment to count up.';
    end if;
    if state is null then
        state := crdt.pn_empty();
    end if;
    if amount = 0 then
        return state;
    end if;
    return jsonb_set(state, array['n', replica],
                     to_jsonb(coalesce((state -> 'n' -> replica)::bigint, 0) + amount));
end;
$$;

-- sum(p) - sum(n). Needs a scan of both maps, so it cannot be inlined (it
-- has sub-selects); IMMUTABLE, so it can back a generated column or an
-- expression index.
create function crdt.pn_value(state crdt.pn)
returns bigint
language sql immutable parallel safe strict
return ((select coalesce(sum(e.value::numeric), 0) from jsonb_each(state -> 'p') e)
      - (select coalesce(sum(e.value::numeric), 0) from jsonb_each(state -> 'n') e))::bigint;

-- Per-key max on p and on n. merge(x, null) = merge(null, x) = x.
--
-- Written as an overlay: a's map, with the entries of b that are larger than
-- a's (or absent from a) written over it. Row-level work is over b only. So
-- merging a small delta into a large state, the common write (update ... set
-- s = pn_merge(s, $1)), costs a copy of the state plus a lookup per delta
-- entry, not a join of two maps. Measured choices
-- (research/benchmarks/pn-counter.md):
--
--   - The maps are taken out of a and b once, in the `offset 0` sub-select.
--     Written inline as `a -> 'p' -> e.key`, the lookup detoasted a and
--     copied its map for every entry of b: a merge of two 10,000-replica
--     states took 1.9 s instead of about 13 ms.
--   - No changed entry: the map is reused as is. One changed entry (a
--     replica's own delta): jsonb_set, which replaces an existing key in
--     place. More: ||, which re-sorts every key of the map, about 3 times
--     slower than jsonb_set at 10,000 replicas.
--   - `is null or >` (not a coalesce to a sentinel) keeps the merge
--     commutative for any jsonb entries, valid or not
--     (test/spec/10_merge_laws.sql).
create function crdt.pn_merge(a crdt.pn, b crdt.pn)
returns crdt.pn
language sql immutable parallel safe
return case
    when a is null then b
    when b is null then a
    else (
        select jsonb_build_object(
            't', 'pn',
            'v', 1,
            'p', case cp.changed when 0 then m.ap
                                 when 1 then jsonb_set(m.ap, array[cp.k], cp.entries -> cp.k)
                                 else m.ap || cp.entries end,
            'n', case cn.changed when 0 then m.an
                                 when 1 then jsonb_set(m.an, array[cn.k], cn.entries -> cn.k)
                                 else m.an || cn.entries end
        )::crdt.pn
        from (select a -> 'p' as ap, a -> 'n' as an, b -> 'p' as bp, b -> 'n' as bn offset 0) m,
             lateral (select count(*) as changed, min(e.key) as k, jsonb_object_agg(e.key, e.value) as entries
                      from jsonb_each(m.bp) e
                      where (m.ap -> e.key) is null or e.value > (m.ap -> e.key)) cp,
             lateral (select count(*) as changed, min(e.key) as k, jsonb_object_agg(e.key, e.value) as entries
                      from jsonb_each(m.bn) e
                      where (m.an -> e.key) is null or e.value > (m.an -> e.key)) cn
    )
end;

-- Merge every state in a group, e.g. the rows of an insert-only delta table.
-- No initial state: a strict-like start from the first non-null input, and
-- null for no rows (like sum). The combine function is pn_merge itself, so
-- partial aggregates from parallel workers merge in any grouping and order.
create aggregate crdt.pn_merge_agg(crdt.pn) (
    sfunc = crdt.pn_merge,
    stype = crdt.pn,
    combinefunc = crdt.pn_merge,
    parallel = safe
);

-- The RLS-safe write path: pn_merge for a delta from an untrusted client.
-- The caller's replica id comes from crdt.current_replica_id() (JWT sub, else
-- the crdt.replica_id setting), never from the input. Every entry of the
-- delta must belong to that id: the id itself, or `<id>:<device>` for a user
-- with several devices, each a replica of its own. No entry may be lower than
-- the current one: max-merge would ignore it, but a lower total means a
-- replica that lost its state or shares its id, and silently ignoring it
-- would also swallow its next increments.
--
-- Use it inside the app's own SECURITY DEFINER function, with the client
-- denied UPDATE on the column:
--
--   update posts set likes = crdt.pn_apply_delta(likes, delta) where id = $1;
--
-- Errors: 42501 no replica id, or an entry of another replica; 22023 an
-- entry that is not a valid count, or a count lower than the current one;
-- 23514 (from the domain) a delta that is not a crdt.pn envelope.
create function crdt.pn_apply_delta(state crdt.pn, delta crdt.pn)
returns crdt.pn
language plpgsql stable
set search_path = pg_catalog, pg_temp
as $$
declare
    me text := crdt.current_replica_id();
    bad record;
begin
    if delta is null then
        return state;
    end if;
    if not crdt.pn_is_valid(delta) then
        raise exception 'crdt.pn_apply_delta: the delta has an entry that is not an integer from 0 to 9223372036854775807'
            using errcode = '22023';
    end if;
    if me is null then
        raise exception 'crdt.pn_apply_delta: the caller has no replica id'
            using errcode = '42501',
                  hint = 'Call with a JWT that has a sub claim, or set crdt.replica_id.';
    end if;

    select m.map, e.key into bad
    from (values ('p'), ('n')) m(map), jsonb_each(delta -> m.map) e
    where e.key <> me and not starts_with(e.key, me || ':')
    limit 1;
    if found then
        raise exception 'crdt.pn_apply_delta: replica % cannot write entry %.% of another replica', me, bad.map, bad.key
            using errcode = '42501',
                  hint = 'A delta may only contain the caller''s own entries: its replica id, or <replica id>:<device>.';
    end if;

    select m.map, e.key, e.value, state -> m.map -> e.key as cur into bad
    from (values ('p'), ('n')) m(map), jsonb_each(delta -> m.map) e
    where e.value < (state -> m.map -> e.key)
    limit 1;
    if found then
        raise exception 'crdt.pn_apply_delta: the delta lowers %.% from % to %', bad.map, bad.key, bad.cur, bad.value
            using errcode = '22023',
                  hint = 'Counts only grow. The replica may have lost its state or share its id with another writer.';
    end if;

    return crdt.pn_merge(coalesce(state, crdt.pn_empty()), delta);
end;
$$;

-- ============================================================================
-- Privileges
-- ============================================================================

-- A fresh install owns every object in this reserved schema. Strip the default
-- grants (and any grant to another role) from its functions before exposing
-- the client API. Do not change defaults for the installer's other schemas.
revoke all on all functions in schema crdt from public;
do $$
declare
    a record;
begin
    for a in
        select distinct p.oid::regprocedure::text as obj, x.grantee
        from pg_catalog.pg_proc p
        cross join lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) x
        where p.pronamespace = 'crdt'::regnamespace and x.grantee <> p.proowner
    loop
        execute format('revoke all on function %s from %s', a.obj,
            case when a.grantee = 0 then 'public' else quote_ident(pg_catalog.pg_get_userbyid(a.grantee)) end);
    end loop;
end;
$$;
grant usage on schema crdt to public;

-- Client-facing: the whole PN-Counter API. Every function is pure or reads
-- only the caller's own identity; none needs privileges of its own. Apps
-- decide who may write which rows (RLS, column privileges, their own
-- SECURITY DEFINER functions around pn_apply_delta).
grant execute on function
    crdt.current_replica_id(),
    crdt.pn_is_valid(jsonb),
    crdt.pn_empty(),
    crdt.pn_increment(crdt.pn, text, bigint),
    crdt.pn_decrement(crdt.pn, text, bigint),
    crdt.pn_value(crdt.pn),
    crdt.pn_merge(crdt.pn, crdt.pn),
    crdt.pn_merge_agg(crdt.pn),
    crdt.pn_apply_delta(crdt.pn, crdt.pn)
to public;
