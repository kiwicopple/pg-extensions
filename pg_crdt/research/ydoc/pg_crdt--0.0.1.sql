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
 *   yseq_* Collaborative text in a column (experimental): a sequence CRDT
 *          (YjsMod order) whose whole state is one jsonb value.
 *   ydoc_* Collaborative text in tables: the same algorithm, stored in
 *          tables of this schema, one row per run of characters; the app's
 *          table holds a document id.
 *
 * PN-Counter and yseq_ states are jsonb with a versioned envelope, typed by
 * a domain:
 *
 *   crdt.pn   {"t": "pn", "v": 1, "p": {replica: count}, "n": {replica: count}}
 *   crdt.yseq {"t": "yseq", "v": 1, ...}  (the yseq_ section)
 *
 * Safe write: one statement that merges in the SET clause,
 *
 *   update t set s = crdt.pn_merge(s, $1) where id = $2;
 *
 * never a read in the client followed by a write of the merged value. A
 * crdt.yseq column is written the same way (set body = crdt.yseq_insert(body,
 * ...)); a ydoc_ document through the ydoc_ functions, which lock its row.
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
-- and stops a SQL function from being inlined. Every yseq_ and ydoc_ PL/pgSQL
-- function pins it all the same (their bodies are long and full of
-- operators), and every yseq_ and ydoc_ SQL function has a SQL-standard body.

-- ============================================================================
-- Shared: the caller's replica id
-- ============================================================================

-- Replica ids are any non-empty text without ":". An entry key is a replica id,
-- or <replica id>:<device> with a non-empty device suffix (which may contain
-- more ":"), so one writer identity can own several replicas (a phone and a
-- laptop). The owner of a key is the part before the first ":".
--
-- The default identity of a writer, for pn_apply_delta's replica argument.
-- Nothing here is specific to one platform:
--
--   1. A JWT claim from request.jwt.claims, the setting PostgREST (and
--      PostgREST-style APIs, Supabase among them) fills from a verified token.
--      The claim is `sub` unless the setting crdt.replica_id_claim names
--      another (email, user_id, ...). A numeric claim is read as text.
--   2. Else the setting crdt.replica_id, which an app server sets per
--      transaction (set local crdt.replica_id = '...').
--   3. Else null: pn_apply_delta then rejects the write.
--
-- The same order as pg_permissions' current_subject_id() (JWT sub, then a
-- setting). Settings are only as trustworthy as whoever sets them: any role
-- can set custom settings, so a client with direct SQL access can claim any
-- id. Wrappers for such clients pass session_user (or their own lookup) to
-- pn_apply_delta explicitly instead.
create function crdt.current_replica_id()
returns text
language plpgsql stable
set search_path = pg_catalog, pg_temp
as $$
begin
    return coalesce(
        nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb
               ->> coalesce(nullif(current_setting('crdt.replica_id_claim', true), ''), 'sub'), ''),
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

-- Adds `amount` to the replica's entry in p. `replica` is a replica key (an
-- id, or <id>:<device>); trusted code supplies it. A null state counts as
-- empty. The amount must be zero or more (0 is a no-op). pn_merge does not
-- check keys: it must accept whatever states other replicas send.
create function crdt.pn_increment(state crdt.pn, replica text, amount bigint default 1)
returns crdt.pn
language plpgsql immutable parallel safe
as $$
begin
    if replica is null or amount is null then
        raise exception 'crdt.pn_increment: replica and amount must not be null'
            using errcode = '22004';
    end if;
    if replica !~ '^[^:]+(:.+)?$' then
        raise exception 'crdt.pn_increment: % is not a replica key', pg_catalog.quote_literal(replica)
            using errcode = '22023',
                  hint = 'A replica key is a non-empty id without ":", optionally followed by ":<device>".';
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
    if replica !~ '^[^:]+(:.+)?$' then
        raise exception 'crdt.pn_decrement: % is not a replica key', pg_catalog.quote_literal(replica)
            using errcode = '22023',
                  hint = 'A replica key is a non-empty id without ":", optionally followed by ":<device>".';
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

-- The write path for untrusted writers: pn_merge for a delta from a writer
-- whose identity is `replica`, by default crdt.current_replica_id(). The app
-- wraps it in its own SECURITY DEFINER function, denies writers UPDATE on the
-- column, and passes whatever identity it trusts (the default resolver,
-- session_user, a lookup in its own users table):
--
--   update posts set likes = crdt.pn_apply_delta(likes, delta) where id = $1;
--   update posts set likes = crdt.pn_apply_delta(likes, delta, session_user::text) where id = $1;
--
-- Every key of the delta must be a well-formed replica key owned by
-- `replica`: the id itself, or <id>:<device>. Entries lower than the current
-- ones are ignored, as by pn_merge: a retry or a replayed older delta
-- succeeds and changes nothing. (A writer that lost its state must read its
-- entries back first, or use a new device id; see docs/guides/replicas-and-identity.md.)
--
-- IMMUTABLE: the result depends on the arguments only; the default argument
-- is evaluated by the caller. Errors: 42501 no replica (null), or an entry
-- owned by another replica; 22023 a replica that is empty or contains ":", a
-- malformed key, or a count that is not an integer from 0 to the bigint
-- maximum; 23514 (from the domain) a delta that is not a crdt.pn envelope.
create function crdt.pn_apply_delta(state crdt.pn, delta crdt.pn, replica text default crdt.current_replica_id())
returns crdt.pn
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    bad record;
begin
    if replica is null then
        raise exception 'crdt.pn_apply_delta: the writer has no replica id'
            using errcode = '42501',
                  hint = 'Pass the writer''s identity as the replica argument, or set it up for crdt.current_replica_id() (a JWT claim in request.jwt.claims, or the crdt.replica_id setting).';
    end if;
    if replica !~ '^[^:]+$' then
        raise exception 'crdt.pn_apply_delta: % is not a replica id', quote_literal(replica)
            using errcode = '22023',
                  hint = 'A replica id is non-empty and has no ":" (":" separates a replica id from a device suffix).';
    end if;
    if delta is null then
        return state;
    end if;
    if not crdt.pn_is_valid(delta) then
        raise exception 'crdt.pn_apply_delta: the delta has an entry that is not an integer from 0 to 9223372036854775807'
            using errcode = '22023';
    end if;

    select m.map, e.key into bad
    from (values ('p'), ('n')) m(map), jsonb_each(delta -> m.map) e
    where e.key !~ '^[^:]+(:.+)?$'
    limit 1;
    if found then
        raise exception 'crdt.pn_apply_delta: entry %.% is not a replica key', bad.map, quote_literal(bad.key)
            using errcode = '22023',
                  hint = 'A replica key is a non-empty id without ":", optionally followed by ":<device>".';
    end if;

    select m.map, e.key into bad
    from (values ('p'), ('n')) m(map), jsonb_each(delta -> m.map) e
    where split_part(e.key, ':', 1) <> replica
    limit 1;
    if found then
        raise exception 'crdt.pn_apply_delta: replica % cannot write entry %.% of another replica', quote_literal(replica), bad.map, quote_literal(bad.key)
            using errcode = '42501',
                  hint = 'A delta may only contain the writer''s own entries: its replica id, or <replica id>:<device>.';
    end if;

    return crdt.pn_merge(coalesce(state, crdt.pn_empty()), delta);
end;
$$;

-- ============================================================================
-- yseq_: collaborative text in a jsonb column (experimental)
-- ============================================================================

-- A text CRDT (YjsMod order, the contract in research/text.md) whose whole
-- state is one jsonb value, typed by the domain crdt.yseq: a column of the
-- app's own table, like crdt.pn. Experimental: every edit rewrites the whole
-- value, so its cost grows with the document (WAL, TOAST churn); tombstones
-- are never collected. ydoc_ below keeps a document in tables instead.
-- Design, measurements and the review history: experiments/text-column/NOTES.md.
-- User docs: docs/types/collaborative-text.md, docs/reference/yseq.md.
--
-- State (crdt.yseq):
--
--   {"t": "yseq", "v": 1,
--    "r": ["alice", "bob"],   replica keys; runs refer to them by 1-based index
--    "c": [12, 3],            characters integrated per replica (the version vector)
--    "n": [40, 7],            per chunk: number of visible characters
--    "s": ["...", "..."],     per chunk: the visible text
--    "m": ["{...}", "{...}"], per chunk: the runs, an int[] literal, 7 ints per run
--    "p": [],                 pending insert runs (wire format), origins not seen yet
--    "x": [],                 pending deletes (wire format) of ids not seen yet
--    "q": []}                 validated ops waiting for v: [[writer, op], ...]
--
-- plus "o", an optional document id (yseq_new).
--
-- A run is [rep, seq, len, olrep, olseq, orrep, orseq]: the characters
-- (r[rep], seq .. seq+|len|-1), visible when len > 0 and tombstones when
-- len < 0, with the origins of its first character (0, 0 for null). Character
-- k > 0 of a run has originLeft = (rep, seq+k-1) and the run's originRight.
-- Runs are in document order, chunk after chunk, and a chunk holds at most
-- crdt._yseq_cmax() (128) runs. Adjacent runs in a chunk are merged whenever
-- the result is a valid run (same replica, consecutive seqs, the second's
-- originLeft is the first's last character, same originRight, same
-- visibility).
--
-- Trust: like pn_merge, yseq_merge and the internals accept any state; the
-- untrusted write path is yseq_apply, wrapped by the app in its own
-- SECURITY DEFINER function while writers have no UPDATE on the column.
--
-- The text of tombstones is not stored (like Yjs's ContentDeleted): the
-- visible text is stored once, so yseq_value is a concatenation of the chunk
-- texts. yseq_ops_since sends U+FFFD for deleted characters, together with
-- the delete set that hides them.
--
-- Positions and lengths count Unicode code points (length() on text). Every
-- function is IMMUTABLE except yseq_new (a random document id), so
-- yseq_value can back a stored generated column or an index. Every yseq_
-- PL/pgSQL function pins search_path; every yseq_ SQL function has a
-- SQL-standard body.

-- ============================================================================
-- yseq_: the domain
-- ============================================================================

-- The envelope, like crdt.pn: an object with exactly these keys, t and v
-- fixed, and r, c, n, s, m, p, x arrays (containment of an empty array checks
-- the type without walking the array). Plus what is cheap to check without
-- reading the chunks: matching array lengths, replica keys that are strings,
-- counts that are integers, chunk lengths that are numbers, pending entries
-- of the right shape. Measured on the 100k-character trace state (157
-- chunks): about 13 us per value, against 1 us for the envelope alone; the
-- scan of "n" is most of it. Chunk contents and pending entries are checked
-- by crdt.yseq_merge at its boundary (crdt._yseq_check) and in full by
-- crdt.yseq_is_valid.
create domain crdt.yseq as jsonb
    check (
        jsonb_typeof(value) = 'object'
        and value @> '{"t": "yseq", "v": 1, "r": [], "c": [], "n": [], "s": [], "m": [], "p": [], "x": [], "q": []}'
        and (value - '{t,v,r,c,n,s,m,p,x,q,o}'::text[]) = '{}'::jsonb
        and value @@ 'strict $.r.size() == $.c.size() && $.n.size() == $.s.size() && $.n.size() == $.m.size()'
        and not value @? 'strict $.r[*] ? (@.type() != "string")'
        and not value @? 'strict $.c[*] ? (@.type() != "number" || @ < 1 || @ > 2147483647 || @.floor() != @)'
        and not value @? 'strict $.n[*] ? (@.type() != "number")'
        and not value @? 'strict $.p[*] ? (@.type() != "array" || @.size() != 5)'
        and not value @? 'strict $.x[*] ? (@.type() != "array" || @.size() != 3)'
        and not value @? 'strict $.q[*] ? (@.type() != "array" || @.size() != 2)'
        and not value @? '$.o ? (@.type() != "string")'
    );

comment on domain crdt.yseq is
    'Collaborative text state (experimental): a YjsMod sequence. See docs/reference/yseq.md. Dropping the extension with CASCADE drops every column of this type.';

create function crdt.yseq_empty()
returns crdt.yseq
language sql immutable parallel safe
return '{"t": "yseq", "v": 1, "r": [], "c": [], "n": [], "s": [], "m": [], "p": [], "x": [], "q": []}'::crdt.yseq;

-- An empty document with a document id ("o", a random UUID), for a column
-- default: `body crdt.yseq not null default crdt.yseq_new()`. yseq_merge
-- refuses to merge states of different ids, and yseq_set refuses a base of
-- another id (22023). VOLATILE; yseq_empty() makes a state without an id.
create function crdt.yseq_new()
returns crdt.yseq
language sql volatile parallel safe
return (crdt.yseq_empty()::jsonb || jsonb_build_object('o', gen_random_uuid()::text))::crdt.yseq;

-- The text. IMMUTABLE, so it can back a stored generated column, an
-- expression index or a full-text index. One chunk: the string itself.
create function crdt.yseq_value(state crdt.yseq)
returns text
language sql immutable parallel safe strict
return case jsonb_array_length(state -> 's')
    when 0 then ''
    when 1 then state -> 's' ->> 0
    else array_to_string(array(select jsonb_array_elements_text(state -> 's')), '')
end;

create function crdt.yseq_length(state crdt.yseq)
returns int
language sql immutable parallel safe strict
return (select coalesce(sum(x::numeric), 0)::int from jsonb_array_elements_text(state -> 'n') x);

-- {replica: characters integrated}. Pending runs are not counted.
create function crdt.yseq_version(state crdt.yseq)
returns jsonb
language sql immutable parallel safe strict
return (select coalesce(jsonb_object_agg(k, c), '{}'::jsonb)
        from rows from (jsonb_array_elements_text(state -> 'r'), jsonb_array_elements(state -> 'c')) z(k, c));

-- ============================================================================
-- yseq_: internals
-- ============================================================================

-- The largest number of runs in a chunk. Edits by position parse and
-- rewrite one chunk; the chunk table ("n") grows as the chunks shrink.
-- Measured in experiments/text-column/NOTES.md.
create function crdt._yseq_cmax()
returns int
language sql immutable parallel safe
return 128;

-- Part of a run: `len` characters from offset `off`, visible or deleted.
create function crdt._yseq_piece(run int[], off int, len int, deleted boolean)
returns int[]
language sql immutable parallel safe
return array[run[1], run[2] + off, case when deleted then -len else len end,
             case when off = 0 then run[4] else run[1] end,
             case when off = 0 then run[5] else run[2] + off - 1 end,
             run[6], run[7]];

-- Merge adjacent runs that form one valid run (the canonical form).
create function crdt._yseq_compact(a int[])
returns int[]
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    o int[] := '{}';
    n int := coalesce(cardinality(a), 0) / 7;
    k int := 1;
    m int := 0;
    pl int;
    ql int;
begin
    while k <= n loop
        if m > 0 then
            pl := o[7 * m - 4];
            ql := a[7 * k - 4];
            if a[7 * k - 6] = o[7 * m - 6] and (pl > 0) = (ql > 0)
               and a[7 * k - 5] = o[7 * m - 5] + abs(pl)
               and a[7 * k - 3] = o[7 * m - 6] and a[7 * k - 2] = a[7 * k - 5] - 1
               and a[7 * k - 1] = o[7 * m - 1] and a[7 * k] = o[7 * m] then
                o[7 * m - 4] := pl + ql;
                k := k + 1;
                continue;
            end if;
        end if;
        o[7 * m + 1] := a[7 * k - 6];
        o[7 * m + 2] := a[7 * k - 5];
        o[7 * m + 3] := a[7 * k - 4];
        o[7 * m + 4] := a[7 * k - 3];
        o[7 * m + 5] := a[7 * k - 2];
        o[7 * m + 6] := a[7 * k - 1];
        o[7 * m + 7] := a[7 * k];
        m := m + 1;
        k := k + 1;
    end loop;
    return o;
end;
$$;

-- Store chunk j (runs mm, text t; nv[j] already updated) into the state,
-- splitting it in two when it has more than crdt._yseq_cmax() runs, and
-- the keys of hdr (r, c). Each jsonb_set or || copies the whole state (about
-- 45 us for a 450 kB state), so this makes three copies: m, s, and the
-- small keys in one ||.
create function crdt._yseq_put(state jsonb, nv int[], j int, mm int[], t text, hdr jsonb default '{}')
returns jsonb
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    nr int := cardinality(mm) / 7;
    h int;
    vh int := 0;
    k int := 1;
begin
    if nr <= crdt._yseq_cmax() then
        return jsonb_set(jsonb_set(state,
            array['m', (j - 1)::text], to_jsonb(mm::text)),
            array['s', (j - 1)::text], to_jsonb(t))
            || (jsonb_build_object('n', nv) || hdr);
    end if;
    h := nr / 2;
    while k <= h loop
        if mm[7 * k - 4] > 0 then vh := vh + mm[7 * k - 4]; end if;
        k := k + 1;
    end loop;
    nv := nv[1 : j - 1] || array[vh, nv[j] - vh] || nv[j + 1 :];
    state := jsonb_set(state, array['m', (j - 1)::text], to_jsonb(mm[1 : 7 * h]::text));
    state := jsonb_insert(state, array['m', (j - 1)::text], to_jsonb(mm[7 * h + 1 :]::text), true);
    state := jsonb_set(state, array['s', (j - 1)::text], to_jsonb(left(t, vh)));
    state := jsonb_insert(state, array['s', (j - 1)::text], to_jsonb(substr(t, vh + 1)), true);
    return state || (jsonb_build_object('n', nv) || hdr);
end;
$$;

-- A local edit by position: delete `dlen` characters at `pos`, then insert
-- `ins` at `pos` as `replica`. Touches only the chunks that hold the edit.
-- Arguments are checked by the callers.
create function crdt._yseq_splice(state crdt.yseq, pos int, dlen int, ins text, replica text)
returns crdt.yseq
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    il int := coalesce(length(ins), 0);
    nv int[];
    nch int;
    total int;
    j int;
    jb int;
    lp int;
    take int;
    rem int;
    mm int[];
    t text;
    nr int;
    k int;
    v int;
    ln int;
    o int;
    a int;
    b int;
    k1 int;
    k2 int;
    o1 int;
    o2 int;
    reg int[];
    rr text[];
    cc int[];
    ri int;
    sq int;
    orr int;
    ors int;
    nm text;
    hdr jsonb;
begin
    if state is null then
        state := crdt.yseq_empty();
    end if;
    nv := translate((state -> 'n')::text, '[]', '{}')::int[];
    total := coalesce((select sum(x) from unnest(nv) x), 0);
    if pos < 0 or dlen < 0 or pos > total or dlen > total - pos then
        raise exception 'crdt.yseq: range at position % of length % is outside the text (length %)', pos, dlen, total
            using errcode = '22023';
    end if;

    rem := dlen;
    while rem > 0 loop
        -- the chunk that holds visible character pos
        j := 1;
        jb := 0;
        while jb + nv[j] <= pos loop
            jb := jb + nv[j];
            j := j + 1;
        end loop;
        lp := pos - jb;
        take := least(rem, nv[j] - lp);
        mm := (state #>> array['m', (j - 1)::text])::int[];
        t := state #>> array['s', (j - 1)::text];
        nr := cardinality(mm) / 7;
        -- runs k1 and k2 hold the first and last deleted characters
        v := 0;
        k1 := 0;
        k := 1;
        while k <= nr loop
            ln := mm[7 * k - 4];
            if ln > 0 then
                if k1 = 0 and v + ln > lp then
                    k1 := k;
                    o1 := lp - v;
                end if;
                if v + ln >= lp + take then
                    k2 := k;
                    o2 := lp + take - 1 - v;
                    exit;
                end if;
                v := v + ln;
            end if;
            k := k + 1;
        end loop;
        -- rebuild runs k1-1 .. k2+1, so new tombstones merge with old ones
        reg := case when k1 > 1 then mm[7 * k1 - 13 : 7 * k1 - 7] else '{}'::int[] end;
        k := k1;
        while k <= k2 loop
            ln := mm[7 * k - 4];
            if ln < 0 then
                reg := reg || mm[7 * k - 6 : 7 * k];
            else
                a := case when k = k1 then o1 else 0 end;
                b := case when k = k2 then o2 else ln - 1 end;
                if a > 0 then
                    reg := reg || crdt._yseq_piece(mm[7 * k - 6 : 7 * k], 0, a, false);
                end if;
                reg := reg || crdt._yseq_piece(mm[7 * k - 6 : 7 * k], a, b - a + 1, true);
                if b < ln - 1 then
                    reg := reg || crdt._yseq_piece(mm[7 * k - 6 : 7 * k], b + 1, ln - 1 - b, false);
                end if;
            end if;
            k := k + 1;
        end loop;
        if k2 < nr then
            reg := reg || mm[7 * k2 + 1 : 7 * k2 + 7];
        end if;
        mm := mm[1 : 7 * greatest(k1 - 2, 0)] || crdt._yseq_compact(reg) || mm[7 * least(k2 + 1, nr) + 1 :];
        t := left(t, lp) || substr(t, lp + take + 1);
        nv[j] := nv[j] - take;
        rem := rem - take;
        state := crdt._yseq_put(state, nv, j, mm, t);
        nv := translate((state -> 'n')::text, '[]', '{}')::int[];
    end loop;

    if il = 0 then
        return state;
    end if;

    rr := array(select jsonb_array_elements_text(state -> 'r'));
    cc := translate((state -> 'c')::text, '[]', '{}')::int[];
    ri := array_position(rr, replica);
    hdr := '{}';
    if ri is null then
        rr := rr || replica;
        cc := cc || 0;
        ri := cardinality(rr);
        hdr := jsonb_build_object('r', rr);
    end if;
    sq := cc[ri] + 1;
    if sq > 2147483648 - il then
        raise exception 'crdt.yseq: replica % has used up its sequence numbers', quote_literal(replica)
            using errcode = '22003', hint = 'Use a new device key (<replica id>:<device>).';
    end if;
    cc[ri] := sq + il - 1;
    hdr := hdr || jsonb_build_object('c', cc);
    nch := coalesce(cardinality(nv), 0);

    if nch = 0 then
        return state || (hdr || jsonb_build_object(
            'n', jsonb_build_array(il),
            's', jsonb_build_array(ins),
            'm', jsonb_build_array(array[ri, sq, il, 0, 0, 0, 0]::text)));
    end if;

    if pos = 0 then
        -- at the start: originLeft null, originRight the first item
        j := 1;
        mm := (state #>> '{m,0}')::int[];
        t := state #>> '{s,0}';
        mm := array[ri, sq, il, 0, 0, mm[1], mm[2]] || mm;
        t := ins || t;
    else
        -- the chunk that holds visible character pos-1, the new originLeft
        j := 1;
        jb := 0;
        while jb + nv[j] < pos loop
            jb := jb + nv[j];
            j := j + 1;
        end loop;
        lp := pos - jb;
        mm := (state #>> array['m', (j - 1)::text])::int[];
        t := state #>> array['s', (j - 1)::text];
        nr := cardinality(mm) / 7;
        v := 0;
        k := 1;
        loop
            ln := mm[7 * k - 4];
            exit when ln > 0 and v + ln >= lp;
            if ln > 0 then
                v := v + ln;
            end if;
            k := k + 1;
        end loop;
        o := lp - 1 - v;
        if o < ln - 1 then
            -- inside run k: split it, originRight is the next character of k
            reg := crdt._yseq_piece(mm[7 * k - 6 : 7 * k], 0, o + 1, false)
                || array[ri, sq, il, mm[7 * k - 6], mm[7 * k - 5] + o, mm[7 * k - 6], mm[7 * k - 5] + o + 1]
                || crdt._yseq_piece(mm[7 * k - 6 : 7 * k], o + 1, ln - o - 1, false);
        else
            -- after run k: originRight is the next item, tombstones included
            if k < nr then
                orr := mm[7 * k + 1];
                ors := mm[7 * k + 2];
            elsif j < nch then
                nm := state #>> array['m', j::text];
                orr := split_part(substr(nm, 2), ',', 1)::int;
                ors := split_part(nm, ',', 2)::int;
            else
                orr := 0;
                ors := 0;
            end if;
            -- typing on at the end of one's own run extends it
            reg := crdt._yseq_compact(mm[7 * k - 6 : 7 * k] || array[ri, sq, il, mm[7 * k - 6], mm[7 * k - 5] + o, orr, ors]);
        end if;
        mm := mm[1 : 7 * k - 7] || reg || mm[7 * k + 1 :];
        t := left(t, lp) || ins || substr(t, lp + 1);
    end if;
    nv[j] := nv[j] + il;
    return crdt._yseq_put(state, nv, j, mm, t, hdr);
end;
$$;

-- The most a writer may have waiting in the state (ops whose v names
-- characters the document does not have yet): insert runs plus deletes,
-- and bytes of op JSON. yseq_apply raises 54000 above either.
create function crdt._yseq_quota(kind text)
returns int
language sql immutable parallel safe
return case kind when 'runs' then 256 when 'bytes' then 65536 end;

-- Integrate remote insert runs and deletes (wire format, already checked)
-- into a state, with the state's pending runs and deletes. The trusted core
-- of yseq_apply and yseq_merge.
--
-- Inserts are integrated with YjsMod (research/text.md) as whole runs, in
-- rounds: a run is ready when the same replica's previous character and both
-- origins are present. Ready runs are integrated in input order; the rest
-- wait for the next round, and stay pending when a round makes no progress.
-- Deletes run after the inserts. A delete of ids not seen yet stays pending.
--
-- In memory the runs are "slots": the state's runs keep their positions
-- 1 .. nr0, and runs made by splits and inserts are appended. Document order
-- is a doubly linked list (nx, pv; 0 means "the next/previous original
-- slot"), so a split or an insert costs O(1) instead of a copy of every
-- run. YjsMod compares positions only inside the scanned stretch, which the
-- scan marks as it goes. A character is found by its key (rep << 32 | seq):
-- width_bucket over the original slots sorted by first key (a binary search
-- in C), or the list of runs integrated in this call, then along sx, the
-- chain of right halves left by splits. Only changed chunks are rebuilt.
create function crdt._yseq_integrate(state crdt.yseq, ins jsonb, dels jsonb, vops jsonb default null)
returns crdt.yseq
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    rr text[];
    cc int[];
    nv int[];
    st text[];
    ms text[];
    nch int;
    cb int[];
    chh int[];
    dirty boolean[];
    mm int[];
    nr0 int;
    ns int;
    nx int[];
    pv int[];
    sca int[] := '{}';
    mark int[];
    head int;
    tail int;
    sk int8[];
    sp int[];
    oe int8[];
    kready boolean := false;
    nk1 int8[] := '{}';
    nk2 int8[] := '{}';
    nsl int[] := '{}';
    nne int := 0;
    sx int[];
    fk int8;
    cbh int[];
    gen int := 0;
    changed boolean := false;
    -- work list
    w_r text[];
    w_s int[];
    w_olk text[];
    w_ols int[];
    w_ork text[];
    w_ors int[];
    w_t text[];
    w_raw jsonb[];
    w_done boolean[];
    nw int;
    wi int;
    progress boolean;
    -- the run being integrated
    rk text;
    s int;
    ln int;
    tx text;
    olk text;
    ols int;
    ork text;
    ors int;
    ri int;
    olri int;
    orri int;
    have int;
    off int;
    lft int;
    rgt int;
    lastoff int;
    dest int;
    cur int;
    scanning boolean;
    i int;
    p int;
    q int;
    z int;
    u int;
    a int;
    sg int;
    pr int;
    nxt int;
    ocl int;
    ocr int;
    jj int;
    j int;
    v int;
    nt text[] := '{}';
    nd boolean[];
    fhead int := 0;
    fslot int := 0;
    fh int;
    nwalk int := 0;
    chars text[];
    rc int[];
    rt text[];
    oc int[];
    oa int[];
    ob int[];
    ot text[];
    mo int;
    pl int;
    ql int;
    kq int;
    lo int;
    piece text;
    pa int[];
    plen int[];
    nold int;
    buf text[];
    nb int;
    cm int[];
    -- deletes
    dk text;
    dmr int8multirange;
    dm int8multirange[];
    ndr int := 0;
    tomb record;
    rg int8range;
    dcur int8;
    take int;
    pend_x jsonb := '[]';
    pend_p jsonb := '[]';
    -- validated ops
    vo_w text[];
    vo_op jsonb[];
    vo_inc boolean[];
    vo_st int[];
    vo_why text[];
    nvo int;
    vi int;
    act int;
    wfound boolean;
    covered boolean;
    vk text;
    vn int;
    vadv int[];
    lag boolean;
    op_r text[];
    op_s int[];
    op_olk text[];
    op_ols int[];
    op_ork text[];
    op_ors int[];
    op_t text[];
    op_n int;
    op_k int;
    il int;
    ul int;
    ir int;
    ur int;
    bad text;
    prev_ok boolean;
    acc_dels jsonb := '[]';
    pend_q jsonb := '[]';
    lim_runs bigint;
    lim_bytes bigint;
    s_mm int[]; s_nx int[]; s_pv int[]; s_sca int[]; s_mark int[]; s_sx int[];
    s_nd boolean[]; s_nt text[]; s_ns int; s_head int; s_tail int; s_cc int[];
    s_rr text[]; s_dirty boolean[]; s_chh int[]; s_nch int; s_nv int[]; s_st text[];
    s_ms text[]; s_nk1 int8[]; s_nk2 int8[]; s_nsl int[]; s_nne int;
    s_sk int8[]; s_sp int[]; s_oe int8[]; s_changed boolean;
    -- output
    m int;
    h int;
    vh int;
    out_n int[] := '{}';
    out_s text[] := '{}';
    out_m text[] := '{}';
    cmax int := crdt._yseq_cmax();
begin
    if state is null then
        state := crdt.yseq_empty();
    end if;
    rr := array(select jsonb_array_elements_text(state -> 'r'));
    cc := translate((state -> 'c')::text, '[]', '{}')::int[];
    nv := translate((state -> 'n')::text, '[]', '{}')::int[];
    st := array(select jsonb_array_elements_text(state -> 's'));
    ms := array(select jsonb_array_elements_text(state -> 'm'));
    nch := coalesce(cardinality(nv), 0);
    cb := array_fill(1, array[nch + 1]);
    j := 1;
    while j <= nch loop
        cb[j + 1] := cb[j] + (length(ms[j]) - length(replace(ms[j], ',', '')) + 1) / 7;
        j := j + 1;
    end loop;
    nr0 := cb[nch + 1] - 1;
    ns := nr0;
    mm := case when nch > 0 then replace(array_to_string(ms, ','), '},{', ',')::int[] else '{}'::int[] end;
    chh := cb[1 : nch];
    dirty := array_fill(false, array[nch]);
    nx := array_fill(0, array[nr0]);
    pv := array_fill(0, array[nr0]);
    mark := array_fill(0, array[nr0]);
    sx := array_fill(0, array[nr0]);
    nd := array_fill(false, array[nr0]);
    cbh := cb[1 : nch];
    head := case when nr0 > 0 then 1 else -1 end;
    tail := case when nr0 > 0 then nr0 else -1 end;

    -- ---- inserts --------------------------------------------------------
    -- Two sources. Trusted runs (state p, then ins) are integrated in
    -- rounds, each run once its own replica's previous character and its
    -- origins are present. Validated ops (state q, then vops; each
    -- [writer, op] with op.v, statically checked by yseq_apply: V0, V1, V2,
    -- V6) wait until the document covers v (V7), are checked against the
    -- document (V3, V4, V5) and are integrated whole or not at all.
    select array_agg(x ->> 0 order by o), array_agg((x ->> 1)::numeric::int order by o),
           array_agg(x -> 2 ->> 0 order by o), array_agg((x -> 2 ->> 1)::numeric::int order by o),
           array_agg(x -> 3 ->> 0 order by o), array_agg((x -> 3 ->> 1)::numeric::int order by o),
           array_agg(x ->> 4 order by o), array_agg(x order by o)
      into w_r, w_s, w_olk, w_ols, w_ork, w_ors, w_t, w_raw
    from (select x, o from jsonb_array_elements(state -> 'p') with ordinality a(x, o)
          union all
          select x, o + 4294967296 from jsonb_array_elements(coalesce(ins, '[]'::jsonb)) with ordinality b(x, o)) z;
    nw := coalesce(cardinality(w_r), 0);
    -- waiting ops are checked again as they load: they may come from another
    -- state (yseq_merge); one that fails is dropped, never raised
    select array_agg(x -> 0 ->> 0 order by o), array_agg(x -> 1 order by o), array_agg(o > 4294967296 order by o)
      into vo_w, vo_op, vo_inc
    from (select x, o from jsonb_array_elements(state -> 'q') with ordinality a(x, o)
          where case when jsonb_typeof(x -> 0) = 'string' and crdt._yseq_op_static(x -> 1) is null
                     then not exists (select 1 from jsonb_array_elements(coalesce(x -> 1 -> 'i', '[]'::jsonb)) y
                                      where split_part(y ->> 0, ':', 1) <> x ->> 0)
                     else false end
          union all
          select x, o + 4294967296 from jsonb_array_elements(coalesce(vops, '[]'::jsonb)) with ordinality b(x, o)) z;
    nvo := coalesce(cardinality(vo_w), 0);
    if nvo > 0 then
        vo_st := array_fill(0, array[nvo]);
        vo_why := array_fill(null::text, array[nvo]);
    end if;

    if nw > 0 or nvo > 0 then
        -- the original slots by first character key, for width_bucket
        select coalesce(array_agg(k order by k), '{}'), coalesce(array_agg(g order by k), '{}'), coalesce(array_agg(e order by k), '{}')
          into sk, sp, oe
        from (select g, (mm[7 * g - 6]::int8 << 32) | mm[7 * g - 5] k,
                     (mm[7 * g - 6]::int8 << 32) | (mm[7 * g - 5] + abs(mm[7 * g - 4]) - 1) e
              from generate_series(1, nr0) g) z;
        kready := true;
        w_done := array_fill(false, array[nw]);
        wi := 1;
        progress := false;
        act := 0;
        loop
            -- chains of split halves got long (splits in random order): re-index
            -- every slot, so that walks start short again (amortized O(log n) lookups)
            if nwalk > 2 * ns + 256 then
                select coalesce(array_agg(k order by k), '{}'), coalesce(array_agg(g order by k), '{}'), coalesce(array_agg(e order by k), '{}')
                  into sk, sp, oe
                from (select g, (mm[7 * g - 6]::int8 << 32) | mm[7 * g - 5] k,
                             (mm[7 * g - 6]::int8 << 32) | (mm[7 * g - 5] + abs(mm[7 * g - 4]) - 1) e
                      from generate_series(1, ns) g) z;
                nk1 := '{}';
                nk2 := '{}';
                nsl := '{}';
                nne := 0;
                fhead := 0;
                fslot := 0;
                nwalk := 0;
            end if;

            if act = 0 then
                -- the next trusted run that is ready
                wfound := false;
                while wi <= nw loop
                    if not w_done[wi] then
                        rk := w_r[wi];
                        s := w_s[wi];
                        tx := w_t[wi];
                        ln := length(tx);
                        ri := array_position(rr, rk);
                        have := coalesce(cc[ri], 0);
                        if s::int8 + ln - 1 <= have then
                            -- already integrated
                            w_done[wi] := true;
                        elsif s::int8 <= have::int8 + 1 then
                            olk := w_olk[wi];
                            ols := w_ols[wi];
                            off := have + 1 - s;
                            if off > 0 then
                                s := have + 1;
                                tx := substr(tx, off + 1);
                                ln := ln - off;
                                olk := rk;
                                ols := have;
                            end if;
                            ork := w_ork[wi];
                            ors := w_ors[wi];
                            olri := case when olk is null then 0 else array_position(rr, olk) end;
                            orri := case when ork is null then 0 else array_position(rr, ork) end;
                            if not (olri is null or orri is null or (olri > 0 and ols > cc[olri]) or (orri > 0 and ors > cc[orri])) then
                                wfound := true;
                                exit;
                            end if;
                        end if;
                    end if;
                    wi := wi + 1;
                end loop;
                if not wfound then
                    -- no trusted run is ready: a validated op whose v the document covers (V7)
                    vi := 1;
                    while vi <= nvo loop
                        if vo_st[vi] = 0 then
                            covered := true;
                            for vk, vn in select key, (value #>> '{}')::numeric::int from jsonb_each(vo_op[vi] -> 'v') loop
                                if coalesce(cc[array_position(rr, vk)], 0) < vn then
                                    covered := false;
                                    exit;
                                end if;
                            end loop;
                            exit when covered;
                        end if;
                        vi := vi + 1;
                    end loop;
                    if vi > nvo then
                        exit when not progress;
                        -- something changed this round: try the waiting runs again
                        wi := 1;
                        progress := false;
                        continue;
                    end if;
                    act := vi;
                    progress := true;
                    -- vadv: v by replica index, advanced run by run below
                    vadv := array_fill(0, array[coalesce(cardinality(rr), 0)]);
                    for vk, vn in select key, (value #>> '{}')::numeric::int from jsonb_each(vo_op[act] -> 'v') loop
                        vadv[array_position(rr, vk)] := vn;
                    end loop;
                    -- V3: v is causally closed. Only replicas the sender lags on can
                    -- hold a dependency beyond v; then one scan of the runs, whose
                    -- first characters carry every cross-replica origin.
                    lag := false;
                    i := 1;
                    while i <= coalesce(cardinality(rr), 0) loop
                        if vadv[i] < cc[i] then lag := true; exit; end if;
                        i := i + 1;
                    end loop;
                    if lag and exists (
                        select 1 from generate_series(1, ns) g
                        where mm[7 * g - 5] <= vadv[mm[7 * g - 6]]
                          and ((mm[7 * g - 3] > 0 and mm[7 * g - 3] <> mm[7 * g - 6] and mm[7 * g - 2] > vadv[mm[7 * g - 3]])
                            or (mm[7 * g - 1] > 0 and mm[7 * g - 1] <> mm[7 * g - 6] and mm[7 * g] > vadv[mm[7 * g - 1]]))) then
                        vo_st[act] := 2;
                        vo_why[act] := 'V3: v is not causally closed';
                        act := 0;
                        continue;
                    end if;
                    select array_agg(x ->> 0 order by o), array_agg((x ->> 1)::numeric::int order by o),
                           array_agg(x -> 2 ->> 0 order by o), array_agg((x -> 2 ->> 1)::numeric::int order by o),
                           array_agg(x -> 3 ->> 0 order by o), array_agg((x -> 3 ->> 1)::numeric::int order by o),
                           array_agg(x ->> 4 order by o)
                      into op_r, op_s, op_olk, op_ols, op_ork, op_ors, op_t
                    from jsonb_array_elements(coalesce(vo_op[act] -> 'i', '[]'::jsonb)) with ordinality a(x, o);
                    op_n := coalesce(cardinality(op_r), 0);
                    op_k := 0;
                    prev_ok := false;
                    if op_n > 1 then
                        -- a later run can still be rejected: keep what to restore
                        s_mm := mm; s_nx := nx; s_pv := pv; s_sca := sca; s_mark := mark; s_sx := sx;
                        s_nd := nd; s_nt := nt; s_ns := ns; s_head := head; s_tail := tail; s_cc := cc;
                        s_rr := rr; s_dirty := dirty; s_chh := chh; s_nch := nch; s_nv := nv; s_st := st;
                        s_ms := ms; s_nk1 := nk1; s_nk2 := nk2; s_nsl := nsl; s_nne := nne;
                        s_sk := sk; s_sp := sp; s_oe := oe; s_changed := changed;
                    end if;
                    continue;
                end if;
            else
                -- the next run of the active validated op
                op_k := op_k + 1;
                if op_k > op_n then
                    vo_st[act] := 1;
                    acc_dels := acc_dels || coalesce(vo_op[act] -> 'd', '[]'::jsonb);
                    act := 0;
                    continue;
                end if;
                rk := op_r[op_k];
                s := op_s[op_k];
                tx := op_t[op_k];
                ln := length(tx);
                ri := array_position(rr, rk);
                have := coalesce(cc[ri], 0);
                bad := null;
                if s::int8 + ln - 1 <= have then
                    -- a duplicate of integrated ids
                    vadv[ri] := greatest(vadv[ri], s + ln - 1);
                    prev_ok := false;
                    continue;
                elsif s <= have or s > have + 1 then
                    bad := 'the run overlaps integrated ids';
                else
                    olk := op_olk[op_k];
                    ols := op_ols[op_k];
                    ork := op_ork[op_k];
                    ors := op_ors[op_k];
                    olri := case when olk is null then 0 else array_position(rr, olk) end;
                    orri := case when ork is null then 0 else array_position(rr, ork) end;
                    if olri is null or orri is null or (olri > 0 and ols > cc[olri]) or (orri > 0 and ors > cc[orri]) then
                        bad := 'an origin is missing';
                    end if;
                end if;
                -- a run that continues the previous run of this op (just
                -- integrated): its origins lie inside the previous run's range,
                -- which held nothing covered, and v only grew by that run's own
                -- ids, so V4 and V5 hold. Skipping the walk keeps chained runs
                -- (keystrokes sent one run each) O(1) apiece.
                if bad is null and op_k > 1 and prev_ok and rk = op_r[op_k - 1]
                   and s = op_s[op_k - 1] + length(op_t[op_k - 1])
                   and olk = rk and ols = s - 1
                   and ork is not distinct from op_ork[op_k - 1] and ors is not distinct from op_ors[op_k - 1] then
                    null;
                elsif bad is null then
                    -- V4, V5: originLeft before originRight, and nothing covered by
                    -- vadv strictly between them (tombstones included)
                    if olri = 0 then
                        il := 0;
                        ul := -1;
                    else
                        fk := (olri::int8 << 32) | ols;
                        il := width_bucket(fk, sk);
                        if il > 0 and fk <= oe[il] then
                            il := sp[il];
                        else
                            il := nsl[coalesce(array_position(nk2, fk), array_position(nk1, fk),
                                          (select u.o::int from unnest(nk1, nk2) with ordinality u(a, b, o) where fk between u.a and u.b limit 1))];
                        end if;
                        while fk > ((mm[7 * il - 6]::int8 << 32) | (mm[7 * il - 5] + abs(mm[7 * il - 4]) - 1)) loop
                            il := sx[il];
                            nwalk := nwalk + 1;
                        end loop;
                        ul := ols - mm[7 * il - 5];
                    end if;
                    if orri = 0 then
                        ir := -1;
                        ur := 0;
                    else
                        fk := (orri::int8 << 32) | ors;
                        ir := width_bucket(fk, sk);
                        if ir > 0 and fk <= oe[ir] then
                            ir := sp[ir];
                        else
                            ir := nsl[coalesce(array_position(nk2, fk), array_position(nk1, fk),
                                          (select u.o::int from unnest(nk1, nk2) with ordinality u(a, b, o) where fk between u.a and u.b limit 1))];
                        end if;
                        while fk > ((mm[7 * ir - 6]::int8 << 32) | (mm[7 * ir - 5] + abs(mm[7 * ir - 4]) - 1)) loop
                            ir := sx[ir];
                            nwalk := nwalk + 1;
                        end loop;
                        ur := ors - mm[7 * ir - 5];
                    end if;
                    if il > 0 and il = ir then
                        if ul >= ur then
                            bad := 'V4: originLeft is not before originRight';
                        elsif ur - ul > 1 and mm[7 * il - 5] + ul + 1 <= coalesce(vadv[mm[7 * il - 6]], 0) then
                            bad := 'V5: an item covered by v lies between the origins';
                        end if;
                    else
                        if il > 0 and ul < abs(mm[7 * il - 4]) - 1 and mm[7 * il - 5] + ul + 1 <= coalesce(vadv[mm[7 * il - 6]], 0) then
                            bad := 'V5: an item covered by v lies between the origins';
                        end if;
                        if bad is null then
                            z := case when il = 0 then head when nx[il] <> 0 then nx[il] when il < nr0 then il + 1 else -1 end;
                            loop
                                exit when z = ir;
                                if z = -1 then
                                    bad := 'V4: originLeft is not before originRight';
                                    exit;
                                end if;
                                if mm[7 * z - 5] <= coalesce(vadv[mm[7 * z - 6]], 0) then
                                    bad := 'V5: an item covered by v lies between the origins';
                                    exit;
                                end if;
                                z := case when nx[z] <> 0 then nx[z] when z < nr0 then z + 1 else -1 end;
                            end loop;
                        end if;
                        if bad is null and ir > 0 and ur > 0 and mm[7 * ir - 5] <= coalesce(vadv[mm[7 * ir - 6]], 0) then
                            bad := 'V5: an item covered by v lies between the origins';
                        end if;
                    end if;
                end if;
                if bad is not null then
                    -- reject the whole op: undo its earlier runs
                    if op_n > 1 then
                        mm := s_mm; nx := s_nx; pv := s_pv; sca := s_sca; mark := s_mark; sx := s_sx;
                        nd := s_nd; nt := s_nt; ns := s_ns; head := s_head; tail := s_tail; cc := s_cc;
                        rr := s_rr; dirty := s_dirty; chh := s_chh; nch := s_nch; nv := s_nv; st := s_st;
                        ms := s_ms; nk1 := s_nk1; nk2 := s_nk2; nsl := s_nsl; nne := s_nne;
                        sk := s_sk; sp := s_sp; oe := s_oe; changed := s_changed;
                        fhead := 0;
                        fslot := 0;
                    end if;
                    vo_st[act] := 2;
                    vo_why[act] := bad;
                    act := 0;
                    continue;
                end if;
            end if;
            if ri is null then
                rr := rr || rk;
                cc := cc || 0;
                ri := cardinality(rr);
                if act > 0 then vadv[ri] := 0; end if;
            end if;
            -- left: the slot that ends with originLeft (split if needed)
            if olri = 0 then
                lft := 0;
            else
                fk := (olri::int8 << 32) | ols;
                i := width_bucket(fk, sk);
                if i > 0 and fk <= oe[i] then
                    i := sp[i];
                else
                    i := nsl[coalesce(array_position(nk2, fk), array_position(nk1, fk),
                                 (select u.o::int from unnest(nk1, nk2) with ordinality u(a, b, o) where fk between u.a and u.b limit 1))];
                end if;
                -- walk the chain of right halves; resume from the last hit when it is
                -- on the same chain and not past the key (ascending lookups stay linear)
                fh := i;
                if i = fhead and fk >= ((mm[7 * fslot - 6]::int8 << 32) | mm[7 * fslot - 5]) then
                    i := fslot;
                end if;
                while fk > ((mm[7 * i - 6]::int8 << 32) | (mm[7 * i - 5] + abs(mm[7 * i - 4]) - 1)) loop
                    i := sx[i];
                    nwalk := nwalk + 1;
                end loop;
                fhead := fh;
                fslot := i;
                a := ols - mm[7 * i - 5] + 1;
                if a < abs(mm[7 * i - 4]) then
                    -- split slot i after a characters
                    sg := case when mm[7 * i - 4] < 0 then -1 else 1 end;
                    ns := ns + 1;
                    mm[7 * ns - 6] := mm[7 * i - 6];
                    mm[7 * ns - 5] := mm[7 * i - 5] + a;
                    mm[7 * ns - 4] := sg * (abs(mm[7 * i - 4]) - a);
                    mm[7 * ns - 3] := mm[7 * i - 6];
                    mm[7 * ns - 2] := mm[7 * i - 5] + a - 1;
                    mm[7 * ns - 1] := mm[7 * i - 1];
                    mm[7 * ns] := mm[7 * i];
                    mm[7 * i - 4] := sg * a;
                    sx[ns] := sx[i];
                    sx[i] := ns;
                    nd[ns] := false;
                    if i > nr0 and nt[i - nr0] is not null then
                        nt[ns - nr0] := substr(nt[i - nr0], a + 1);
                        nt[i - nr0] := left(nt[i - nr0], a);
                    else
                        nt[ns - nr0] := null;
                    end if;
                    nxt := case when nx[i] <> 0 then nx[i] when i < nr0 then i + 1 else -1 end;
                    nx[ns] := nxt;
                    pv[ns] := i;
                    mark[ns] := 0;
                    sca[ns - nr0] := (case when i <= nr0 then width_bucket(i, cbh) else sca[i - nr0] end);
                    nx[i] := ns;
                    if nxt > 0 then pv[nxt] := ns; else tail := ns; end if;
                    dirty[(case when i <= nr0 then width_bucket(i, cbh) else sca[i - nr0] end)] := true;
                end if;
                lft := i;
            end if;
            -- right: the slot that starts with originRight (split if needed)
            if orri = 0 then
                rgt := -1;
            else
                fk := (orri::int8 << 32) | ors;
                i := width_bucket(fk, sk);
                if i > 0 and fk <= oe[i] then
                    i := sp[i];
                else
                    i := nsl[coalesce(array_position(nk2, fk), array_position(nk1, fk),
                                 (select u.o::int from unnest(nk1, nk2) with ordinality u(a, b, o) where fk between u.a and u.b limit 1))];
                end if;
                -- walk the chain of right halves; resume from the last hit when it is
                -- on the same chain and not past the key (ascending lookups stay linear)
                fh := i;
                if i = fhead and fk >= ((mm[7 * fslot - 6]::int8 << 32) | mm[7 * fslot - 5]) then
                    i := fslot;
                end if;
                while fk > ((mm[7 * i - 6]::int8 << 32) | (mm[7 * i - 5] + abs(mm[7 * i - 4]) - 1)) loop
                    i := sx[i];
                    nwalk := nwalk + 1;
                end loop;
                fhead := fh;
                fslot := i;
                a := ors - mm[7 * i - 5];
                if a > 0 then
                    sg := case when mm[7 * i - 4] < 0 then -1 else 1 end;
                    ns := ns + 1;
                    mm[7 * ns - 6] := mm[7 * i - 6];
                    mm[7 * ns - 5] := mm[7 * i - 5] + a;
                    mm[7 * ns - 4] := sg * (abs(mm[7 * i - 4]) - a);
                    mm[7 * ns - 3] := mm[7 * i - 6];
                    mm[7 * ns - 2] := mm[7 * i - 5] + a - 1;
                    mm[7 * ns - 1] := mm[7 * i - 1];
                    mm[7 * ns] := mm[7 * i];
                    mm[7 * i - 4] := sg * a;
                    sx[ns] := sx[i];
                    sx[i] := ns;
                    nd[ns] := false;
                    if i > nr0 and nt[i - nr0] is not null then
                        nt[ns - nr0] := substr(nt[i - nr0], a + 1);
                        nt[i - nr0] := left(nt[i - nr0], a);
                    else
                        nt[ns - nr0] := null;
                    end if;
                    nxt := case when nx[i] <> 0 then nx[i] when i < nr0 then i + 1 else -1 end;
                    nx[ns] := nxt;
                    pv[ns] := i;
                    mark[ns] := 0;
                    sca[ns - nr0] := (case when i <= nr0 then width_bucket(i, cbh) else sca[i - nr0] end);
                    nx[i] := ns;
                    if nxt > 0 then pv[nxt] := ns; else tail := ns; end if;
                    dirty[(case when i <= nr0 then width_bucket(i, cbh) else sca[i - nr0] end)] := true;
                    i := ns;
                end if;
                rgt := i;
            end if;

            -- YjsMod scan, one slot at a time (see research/text.md)
            gen := gen + 1;
            lastoff := case when lft > 0 then abs(mm[7 * lft - 4]) - 1 end;
            cur := case when lft = 0 then head
                        when nx[lft] <> 0 then nx[lft] when lft < nr0 then lft + 1 else -1 end;
            dest := cur;
            scanning := false;
            loop
                if not scanning then
                    dest := cur;
                end if;
                exit when cur = -1 or cur = rgt;
                mark[cur] := gen;
                -- originLeft of cur against ours
                if mm[7 * cur - 3] = 0 then
                    ocl := case when lft = 0 then 0 else -1 end;
                elsif lft = 0 then
                    ocl := 1;
                else
                    fk := (mm[7 * cur - 3]::int8 << 32) | mm[7 * cur - 2];
                    p := width_bucket(fk, sk);
                    if p > 0 and fk <= oe[p] then
                        p := sp[p];
                    else
                        p := nsl[coalesce(array_position(nk2, fk), array_position(nk1, fk),
                                     (select u.o::int from unnest(nk1, nk2) with ordinality u(a, b, o) where fk between u.a and u.b limit 1))];
                    end if;
                    -- walk the chain of right halves; resume from the last hit when it is
                    -- on the same chain and not past the key (ascending lookups stay linear)
                    fh := p;
                    if p = fhead and fk >= ((mm[7 * fslot - 6]::int8 << 32) | mm[7 * fslot - 5]) then
                        p := fslot;
                    end if;
                    while fk > ((mm[7 * p - 6]::int8 << 32) | (mm[7 * p - 5] + abs(mm[7 * p - 4]) - 1)) loop
                        p := sx[p];
                        nwalk := nwalk + 1;
                    end loop;
                    fhead := fh;
                    fslot := p;
                    if p = lft then
                        ocl := case when mm[7 * cur - 2] - mm[7 * p - 5] = lastoff then 0 else -1 end;
                    elsif mark[p] = gen then
                        ocl := 1;
                    else
                        ocl := -1;
                    end if;
                end if;
                exit when ocl < 0;
                if ocl = 0 then
                    -- originRight of cur against ours
                    if mm[7 * cur - 1] = 0 then
                        ocr := case when rgt = -1 then 0 else 1 end;
                    elsif rgt = -1 then
                        ocr := -1;
                    else
                        fk := (mm[7 * cur - 1]::int8 << 32) | mm[7 * cur];
                        q := width_bucket(fk, sk);
                        if q > 0 and fk <= oe[q] then
                            q := sp[q];
                        else
                            q := nsl[coalesce(array_position(nk2, fk), array_position(nk1, fk),
                                         (select u.o::int from unnest(nk1, nk2) with ordinality u(a, b, o) where fk between u.a and u.b limit 1))];
                        end if;
                        -- walk the chain of right halves; resume from the last hit when it is
                        -- on the same chain and not past the key (ascending lookups stay linear)
                        fh := q;
                        if q = fhead and fk >= ((mm[7 * fslot - 6]::int8 << 32) | mm[7 * fslot - 5]) then
                            q := fslot;
                        end if;
                        while fk > ((mm[7 * q - 6]::int8 << 32) | (mm[7 * q - 5] + abs(mm[7 * q - 4]) - 1)) loop
                            q := sx[q];
                            nwalk := nwalk + 1;
                        end loop;
                        fhead := fh;
                        fslot := q;
                        if q = rgt then
                            ocr := case when mm[7 * cur] = mm[7 * q - 5] then 0 else 1 end;
                        else
                            -- which comes first after cur: q or rgt?
                            z := cur;
                            loop
                                z := case when nx[z] <> 0 then nx[z] when z < nr0 then z + 1 else -1 end;
                                exit when z = q or z = rgt or z = -1;
                            end loop;
                            ocr := case when z = q then -1 else 1 end;
                        end if;
                    end if;
                    if ocr < 0 then
                        scanning := true;
                    elsif ocr = 0 then
                        exit when rk < rr[mm[7 * cur - 6]] collate "C";
                        scanning := false;
                    else
                        scanning := false;
                    end if;
                end if;
                cur := case when nx[cur] <> 0 then nx[cur] when cur < nr0 then cur + 1 else -1 end;
            end loop;

            -- insert before dest (-1: at the end), as a new slot that carries
            -- its text; the chunk text is rebuilt once at the end
            pr := case when dest = -1 then tail when pv[dest] <> 0 then pv[dest] else dest - 1 end;
            if pr < 0 then
                pr := 0;
            end if;
            ns := ns + 1;
            mm[7 * ns - 6] := ri;
            mm[7 * ns - 5] := s;
            mm[7 * ns - 4] := ln;
            mm[7 * ns - 3] := olri;
            mm[7 * ns - 2] := coalesce(ols, 0);
            mm[7 * ns - 1] := orri;
            mm[7 * ns] := coalesce(ors, 0);
            nx[ns] := dest;
            pv[ns] := case when pr = 0 then -1 else pr end;
            mark[ns] := 0;
            sx[ns] := 0;
            nd[ns] := false;
            nt[ns - nr0] := tx;
            if pr = 0 then head := ns; else nx[pr] := ns; end if;
            if dest = -1 then tail := ns; else pv[dest] := ns; end if;
            if nch = 0 then
                nch := 1;
                nv := array[0];
                st := array[''];
                ms := array['{}'];
                dirty := array[true];
                chh := array[ns];
                jj := 1;
            elsif pr = 0 then
                jj := 1;
                chh[1] := ns;
            else
                jj := (case when pr <= nr0 then width_bucket(pr, cbh) else sca[pr - nr0] end);
            end if;
            sca[ns - nr0] := jj;
            -- the new ids, for lookups
            nne := nne + 1;
            nk1[nne] := (ri::int8 << 32) | s;
            nk2[nne] := (ri::int8 << 32) | (s + ln - 1);
            nsl[nne] := ns;
            dirty[jj] := true;
            cc[ri] := s + ln - 1;
            changed := true;
            progress := true;
            if act = 0 then
                w_done[wi] := true;
                wi := wi + 1;
            else
                vadv[ri] := s + ln - 1;
                prev_ok := true;
            end if;
        end loop;
        select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into pend_p
        from unnest(w_raw, w_done) u(x, d) where not d;
    end if;
    -- validated ops: the incoming ones must not be rejected; the waiting ones
    -- stay in q, within the writer's quota
    vi := 1;
    while vi <= nvo loop
        if vo_inc[vi] and vo_st[vi] = 2 then
            raise exception 'crdt.yseq_apply: op rejected (%)', vo_why[vi]
                using errcode = '22023',
                      hint = 'The op breaks a causal rule of research/text.md, Amendment 1 (experiments/text-ref/README.md, V0 to V7).';
        end if;
        vi := vi + 1;
    end loop;
    select coalesce(jsonb_agg(distinct jsonb_build_array(qw, qop)), '[]'::jsonb) into pend_q
    from unnest(vo_w, vo_op, vo_st) u(qw, qop, qst) where qst = 0;
    if exists (select 1 from unnest(vo_w, vo_inc, vo_st) u(qw, qinc, qst) where qinc and qst = 0) then
        select qw, sum(jsonb_array_length(coalesce(qop -> 'i', '[]')) + jsonb_array_length(coalesce(qop -> 'd', '[]'))), sum(octet_length(qop::text))
          into vk, lim_runs, lim_bytes
        from (select x ->> 0 qw, x -> 1 qop from jsonb_array_elements(pend_q) x) z
        where qw in (select qw from unnest(vo_w, vo_inc, vo_st) u(qw, qinc, qst) where qinc and qst = 0)
        group by qw
        having sum(jsonb_array_length(coalesce(qop -> 'i', '[]')) + jsonb_array_length(coalesce(qop -> 'd', '[]'))) > crdt._yseq_quota('runs')
            or sum(octet_length(qop::text)) > crdt._yseq_quota('bytes')
        limit 1;
        if found then
            raise exception 'crdt.yseq_apply: writer % has too much waiting (% runs and deletes, % bytes)', quote_literal(vk), lim_runs, lim_bytes
                using errcode = '54000',
                      hint = format('An op waits until the document has every character its v names. At most %s runs and deletes, and %s bytes, may wait per writer.',
                                    crdt._yseq_quota('runs'), crdt._yseq_quota('bytes'));
        end if;
    end if;
    if pend_q <> state -> 'q' then
        changed := true;
    end if;
    dels := coalesce(dels, '[]'::jsonb) || acc_dels;

    -- ---- deletes --------------------------------------------------------
    -- dm[ri]: the ids to delete that are present; the rest stays pending
    dm := array_fill(null::int8multirange, array[coalesce(cardinality(rr), 0)]);
    for dk, dmr in
        select x ->> 0, range_agg(int8range((x ->> 1)::numeric::int8, (x ->> 1)::numeric::int8 + (x ->> 2)::numeric::int8))
        from (select x from jsonb_array_elements(state -> 'x') x
              union all
              select x from jsonb_array_elements(coalesce(dels, '[]'::jsonb)) x) z
        group by 1
        order by (x ->> 0) collate "C"
    loop
        ri := array_position(rr, dk);
        if ri is not null then
            if not isempty(dmr * int8multirange(int8range(1, cc[ri] + 1))) then
                dm[ri] := dmr * int8multirange(int8range(1, cc[ri] + 1));
                ndr := ndr + (select count(*) from unnest(dm[ri]))::int;
            end if;
            dmr := dmr - int8multirange(int8range(1, cc[ri] + 1));
        end if;
        select pend_x || coalesce(jsonb_agg(jsonb_build_array(dk, lower(g), upper(g) - lower(g)) order by lower(g)), '[]'::jsonb)
          into pend_x
        from unnest(dmr) g;
    end loop;
    if ndr > 64 then
        -- many ranges (a full-state merge sends the whole delete set): drop
        -- the ids that are tombstones already
        for tomb in
            select mm[7 * g - 6] as rep, range_agg(int8range(mm[7 * g - 5], mm[7 * g - 5] - mm[7 * g - 4])) as mr
            from generate_series(1, ns) g
            where mm[7 * g - 4] < 0
            group by 1
        loop
            if dm[tomb.rep] is not null then
                dm[tomb.rep] := dm[tomb.rep] - tomb.mr;
                if isempty(dm[tomb.rep]) then dm[tomb.rep] := null; end if;
            end if;
        end loop;
        ndr := (select count(*) from unnest(dm) d, unnest(d) r where d is not null);
    end if;
    if ndr > 0 then
        if not kready then
            select coalesce(array_agg(k order by k), '{}'), coalesce(array_agg(g order by k), '{}'), coalesce(array_agg(e order by k), '{}')
              into sk, sp, oe
            from (select g, (mm[7 * g - 6]::int8 << 32) | mm[7 * g - 5] k,
                         (mm[7 * g - 6]::int8 << 32) | (mm[7 * g - 5] + abs(mm[7 * g - 4]) - 1) e
                  from generate_series(1, nr0) g) z;
            kready := true;
        end if;
        ri := 1;
        while ri <= coalesce(cardinality(dm), 0) loop
            if dm[ri] is not null then
                for rg in select x from unnest(dm[ri]) x loop
                    dcur := lower(rg);
                    while dcur < upper(rg) loop
                        -- chains of split halves got long (splits in random order): re-index
                        -- every slot, so that walks start short again (amortized O(log n) lookups)
                        if nwalk > 2 * ns + 256 then
                            select coalesce(array_agg(k order by k), '{}'), coalesce(array_agg(g order by k), '{}'), coalesce(array_agg(e order by k), '{}')
                              into sk, sp, oe
                            from (select g, (mm[7 * g - 6]::int8 << 32) | mm[7 * g - 5] k,
                                         (mm[7 * g - 6]::int8 << 32) | (mm[7 * g - 5] + abs(mm[7 * g - 4]) - 1) e
                                  from generate_series(1, ns) g) z;
                            nk1 := '{}';
                            nk2 := '{}';
                            nsl := '{}';
                            nne := 0;
                            fhead := 0;
                            fslot := 0;
                            nwalk := 0;
                        end if;
                        fk := (ri::int8 << 32) | dcur;
                        i := width_bucket(fk, sk);
                        if i > 0 and fk <= oe[i] then
                            i := sp[i];
                        else
                            i := nsl[coalesce(array_position(nk2, fk), array_position(nk1, fk),
                                         (select u.o::int from unnest(nk1, nk2) with ordinality u(a, b, o) where fk between u.a and u.b limit 1))];
                        end if;
                        -- walk the chain of right halves; resume from the last hit when it is
                        -- on the same chain and not past the key (ascending lookups stay linear)
                        fh := i;
                        if i = fhead and fk >= ((mm[7 * fslot - 6]::int8 << 32) | mm[7 * fslot - 5]) then
                            i := fslot;
                        end if;
                        while fk > ((mm[7 * i - 6]::int8 << 32) | (mm[7 * i - 5] + abs(mm[7 * i - 4]) - 1)) loop
                            i := sx[i];
                            nwalk := nwalk + 1;
                        end loop;
                        fhead := fh;
                        fslot := i;
                        u := (dcur - mm[7 * i - 5])::int;
                        take := least(upper(rg) - dcur, abs(mm[7 * i - 4]) - u)::int;
                        if mm[7 * i - 4] > 0 then
                            -- isolate the piece u .. u+take-1 of slot i, then mark it
                            a := u;
                            for pass in 1..2 loop
                                if a > 0 and a < mm[7 * i - 4] then
                                    ns := ns + 1;
                                    mm[7 * ns - 6] := mm[7 * i - 6];
                                    mm[7 * ns - 5] := mm[7 * i - 5] + a;
                                    mm[7 * ns - 4] := mm[7 * i - 4] - a;
                                    mm[7 * ns - 3] := mm[7 * i - 6];
                                    mm[7 * ns - 2] := mm[7 * i - 5] + a - 1;
                                    mm[7 * ns - 1] := mm[7 * i - 1];
                                    mm[7 * ns] := mm[7 * i];
                                    mm[7 * i - 4] := a;
                                    sx[ns] := sx[i];
                                    sx[i] := ns;
                                    nd[ns] := false;
                                    if i > nr0 and nt[i - nr0] is not null then
                                        nt[ns - nr0] := substr(nt[i - nr0], a + 1);
                                        nt[i - nr0] := left(nt[i - nr0], a);
                                    else
                                        nt[ns - nr0] := null;
                                    end if;
                                    nxt := case when nx[i] <> 0 then nx[i] when i < nr0 then i + 1 else -1 end;
                                    nx[ns] := nxt;
                                    pv[ns] := i;
                                    mark[ns] := 0;
                                    sca[ns - nr0] := (case when i <= nr0 then width_bucket(i, cbh) else sca[i - nr0] end);
                                    nx[i] := ns;
                                    if nxt > 0 then pv[nxt] := ns; else tail := ns; end if;
                                    if pass = 1 then
                                        i := ns;
                                    end if;
                                end if;
                                a := take;
                            end loop;
                            jj := (case when i <= nr0 then width_bucket(i, cbh) else sca[i - nr0] end);
                            mm[7 * i - 4] := -take;
                            if i <= nr0 or nt[i - nr0] is null then
                                -- its text is in the old chunk text
                                nd[i] := true;
                            end if;
                            dirty[jj] := true;
                            changed := true;
                        end if;
                        dcur := dcur + take;
                    end loop;
                end loop;
            end if;
            ri := ri + 1;
        end loop;
    end if;

    if not changed and pend_p = state -> 'p' and pend_x = state -> 'x' and pend_q = state -> 'q' then
        return state;
    end if;

    -- ---- output: rebuild the changed chunks -------------------------------
    j := 1;
    while j <= nch loop
        if not dirty[j] then
            out_n := out_n || nv[j];
            out_s := out_s || st[j];
            out_m := out_m || ms[j];
        else
            -- one pass over the chunk's slots: runs, and each run's visible
            -- text (from the old chunk text for runs that were there, from
            -- the slot for runs integrated in this call)
            v := 0;
            rc := '{}';
            rt := '{}';
            pa := '{}';
            plen := '{}';
            nold := 0;
            m := 0;
            z := chh[j];
            while z <> -1 and (case when z <= nr0 then width_bucket(z, cbh) else sca[z - nr0] end) = j loop
                ln := abs(mm[7 * z - 4]);
                pa[m + 1] := 0;
                plen[m + 1] := 0;
                piece := '';
                if z <= nr0 or nt[z - nr0] is null then
                    if mm[7 * z - 4] > 0 then
                        -- characters v+1 .. v+ln of the old chunk text
                        pa[m + 1] := v + 1;
                        plen[m + 1] := ln;
                        nold := nold + 1;
                        v := v + ln;
                    elsif nd[z] then
                        v := v + ln;
                    end if;
                elsif mm[7 * z - 4] > 0 then
                    piece := nt[z - nr0];
                end if;
                rc[7 * m + 1] := mm[7 * z - 6];
                rc[7 * m + 2] := mm[7 * z - 5];
                rc[7 * m + 3] := mm[7 * z - 4];
                rc[7 * m + 4] := mm[7 * z - 3];
                rc[7 * m + 5] := mm[7 * z - 2];
                rc[7 * m + 6] := mm[7 * z - 1];
                rc[7 * m + 7] := mm[7 * z];
                m := m + 1;
                rt[m] := piece;
                z := case when nx[z] <> 0 then nx[z] when z < nr0 then z + 1 else -1 end;
            end loop;
            -- the old text of the pieces that keep it: substr walks from the
            -- start of the text, so with many pieces split the text into
            -- characters once instead (element access is O(1), slices are not)
            if nold > 0 and nold <= 100 then
                kq := 1;
                while kq <= m loop
                    if plen[kq] > 0 then rt[kq] := substr(st[j], pa[kq], plen[kq]); end if;
                    kq := kq + 1;
                end loop;
            elsif nold > 100 then
                chars := string_to_array(st[j], null);
                kq := 1;
                while kq <= m loop
                    if plen[kq] > 0 then
                        buf := '{}';
                        nb := 0;
                        while nb < plen[kq] loop
                            buf[nb + 1] := chars[pa[kq] + nb];
                            nb := nb + 1;
                        end loop;
                        rt[kq] := array_to_string(buf, '');
                    end if;
                    kq := kq + 1;
                end loop;
            end if;
            -- merge adjacent runs (as crdt._yseq_compact), remembering which
            -- raw runs each merged run covers
            oc := '{}';
            oa := '{}';
            ob := '{}';
            mo := 0;
            kq := 1;
            while kq <= m loop
                if mo > 0 then
                    pl := oc[7 * mo - 4];
                    ql := rc[7 * kq - 4];
                    if rc[7 * kq - 6] = oc[7 * mo - 6] and (pl > 0) = (ql > 0)
                       and rc[7 * kq - 5] = oc[7 * mo - 5] + abs(pl)
                       and rc[7 * kq - 3] = oc[7 * mo - 6] and rc[7 * kq - 2] = rc[7 * kq - 5] - 1
                       and rc[7 * kq - 1] = oc[7 * mo - 1] and rc[7 * kq] = oc[7 * mo] then
                        oc[7 * mo - 4] := pl + ql;
                        ob[mo] := kq;
                        kq := kq + 1;
                        continue;
                    end if;
                end if;
                oc[7 * mo + 1] := rc[7 * kq - 6];
                oc[7 * mo + 2] := rc[7 * kq - 5];
                oc[7 * mo + 3] := rc[7 * kq - 4];
                oc[7 * mo + 4] := rc[7 * kq - 3];
                oc[7 * mo + 5] := rc[7 * kq - 2];
                oc[7 * mo + 6] := rc[7 * kq - 1];
                oc[7 * mo + 7] := rc[7 * kq];
                mo := mo + 1;
                oa[mo] := kq;
                ob[mo] := kq;
                kq := kq + 1;
            end loop;
            ot := '{}';
            kq := 1;
            while kq <= mo loop
                if oa[kq] = ob[kq] then
                    ot[kq] := rt[oa[kq]];
                else
                    buf := '{}';
                    nb := 0;
                    while oa[kq] + nb <= ob[kq] loop
                        buf[nb + 1] := rt[oa[kq] + nb];
                        nb := nb + 1;
                    end loop;
                    ot[kq] := array_to_string(buf, '');
                end if;
                kq := kq + 1;
            end loop;
            -- out as one chunk, or as chunks of cmax / 2 runs when too big
            h := case when mo <= cmax then greatest(mo, 1) else cmax / 2 end;
            lo := 1;
            while lo <= mo loop
                kq := least(lo + h - 1, mo);
                vh := 0;
                i := lo;
                while i <= kq loop
                    if oc[7 * i - 4] > 0 then vh := vh + oc[7 * i - 4]; end if;
                    i := i + 1;
                end loop;
                buf := '{}';
                cm := '{}';
                i := lo;
                while i <= kq loop
                    buf[i - lo + 1] := ot[i];
                    nb := 7 * (i - lo);
                    cm[nb + 1] := oc[7 * i - 6];
                    cm[nb + 2] := oc[7 * i - 5];
                    cm[nb + 3] := oc[7 * i - 4];
                    cm[nb + 4] := oc[7 * i - 3];
                    cm[nb + 5] := oc[7 * i - 2];
                    cm[nb + 6] := oc[7 * i - 1];
                    cm[nb + 7] := oc[7 * i];
                    i := i + 1;
                end loop;
                out_n := out_n || vh;
                out_s := out_s || array_to_string(buf, '');
                out_m := out_m || cm::text;
                lo := kq + 1;
            end loop;
        end if;
        j := j + 1;
    end loop;

    return (jsonb_build_object(
        't', 'yseq', 'v', 1,
        'r', to_jsonb(rr), 'c', to_jsonb(cc),
        'n', to_jsonb(out_n), 's', to_jsonb(out_s), 'm', to_jsonb(out_m),
        'p', pend_p, 'x', pend_x, 'q', pend_q)
        || case when state ? 'o' then jsonb_build_object('o', state -> 'o') else '{}'::jsonb end)::crdt.yseq;
end;
$$;


-- An origin id on the wire: null, or [replica key, seq].
create function crdt._yseq_valid_id(id jsonb)
returns boolean
language sql immutable parallel safe
return case
    when id is null or id = 'null'::jsonb then true
    when jsonb_typeof(id) <> 'array' or jsonb_array_length(id) <> 2 then false
    when jsonb_typeof(id -> 0) <> 'string' or jsonb_typeof(id -> 1) <> 'number' then false
    when (id ->> 0) !~ '^[^:]+(:.+)?$' then false
    else (id ->> 1)::numeric between 1 and 2147483647 and (id ->> 1)::numeric = floor((id ->> 1)::numeric)
end;

-- An insert run on the wire: [replica key, seq, originLeft, originRight, text].
create function crdt._yseq_valid_run(x jsonb)
returns boolean
language sql immutable parallel safe
return case
    when jsonb_typeof(x) <> 'array' or jsonb_array_length(x) <> 5 then false
    when jsonb_typeof(x -> 0) <> 'string' or jsonb_typeof(x -> 1) <> 'number' or jsonb_typeof(x -> 4) <> 'string' then false
    when (x ->> 0) !~ '^[^:]+(:.+)?$' or (x ->> 4) = '' then false
    when not ((x ->> 1)::numeric between 1 and 2147483647 and (x ->> 1)::numeric = floor((x ->> 1)::numeric)) then false
    when (x ->> 1)::numeric + length(x ->> 4) - 1 > 2147483647 then false
    else crdt._yseq_valid_id(x -> 2) and crdt._yseq_valid_id(x -> 3)
end;

-- A delete on the wire: [replica key, seq, len].
create function crdt._yseq_valid_del(x jsonb)
returns boolean
language sql immutable parallel safe
return case
    when jsonb_typeof(x) <> 'array' or jsonb_array_length(x) <> 3 then false
    when jsonb_typeof(x -> 0) <> 'string' or jsonb_typeof(x -> 1) <> 'number' or jsonb_typeof(x -> 2) <> 'number' then false
    when (x ->> 0) !~ '^[^:]+(:.+)?$' then false
    when not ((x ->> 1)::numeric between 1 and 2147483647 and (x ->> 1)::numeric = floor((x ->> 1)::numeric)) then false
    when not ((x ->> 2)::numeric between 1 and 2147483647 and (x ->> 2)::numeric = floor((x ->> 2)::numeric)) then false
    else (x ->> 1)::numeric + (x ->> 2)::numeric - 1 <= 2147483647
end;

-- The delete set: every tombstone, plus the pending deletes, as
-- [[replica key, seq, len], ...] in replica (collate "C") and seq order.
create function crdt._yseq_delete_set(state crdt.yseq)
returns jsonb
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    rr text[] := array(select jsonb_array_elements_text(state -> 'r'));
    mm int[];
    res jsonb;
begin
    if jsonb_array_length(state -> 'm') > 0 then
        mm := replace(array_to_string(array(select jsonb_array_elements_text(state -> 'm')), ','), '},{', ',')::int[];
    else
        mm := '{}';
    end if;
    select coalesce(jsonb_agg(jsonb_build_array(k, lower(g), upper(g) - lower(g)) order by k collate "C", lower(g)), '[]'::jsonb)
      into res
    from (select k, unnest(range_agg(rg)) g
          from (select rr[mm[7 * i - 6]] k, int8range(mm[7 * i - 5], mm[7 * i - 5] - mm[7 * i - 4]) rg
                from generate_series(1, cardinality(mm) / 7) i
                where mm[7 * i - 4] < 0
                union all
                select x ->> 0, int8range((x ->> 1)::numeric::int8, (x ->> 1)::numeric::int8 + (x ->> 2)::numeric::int8)
                from jsonb_array_elements(state -> 'x') x) z
          group by k) y;
    return res;
end;
$$;

-- ============================================================================
-- yseq_: local edits
-- ============================================================================

create function crdt._yseq_check_replica(fn text, replica text)
returns void
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
begin
    if replica is null then
        raise exception 'crdt.%: replica must not be null', fn using errcode = '22004';
    end if;
    if replica !~ '^[^:]+(:.+)?$' or octet_length(replica) > crdt._yseq_limit('key_bytes') then
        raise exception 'crdt.%: % is not a replica key', fn, quote_literal(left(replica, 64))
            using errcode = '22023',
                  hint = 'A replica key is a non-empty id without ":", optionally followed by ":<device>".';
    end if;
end;
$$;

-- Insert `content` before position `pos` (0 .. length, in code points) as
-- `replica` (a replica key). A null state counts as empty; empty content is
-- a no-op. The new characters' op: yseq_ops_since(new, yseq_version(old)),
-- or yseq_diff(old, new).
create function crdt.yseq_insert(state crdt.yseq, pos int, content text, replica text)
returns crdt.yseq
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
begin
    perform crdt._yseq_check_replica('yseq_insert', replica);
    if pos is null or content is null then
        raise exception 'crdt.yseq_insert: pos and content must not be null' using errcode = '22004';
    end if;
    return crdt._yseq_splice(state, pos, 0, content, replica);
end;
$$;

-- Delete `len` characters from position `pos`. Deletes may hit anyone's
-- characters; `replica` is checked for symmetry and is not recorded.
create function crdt.yseq_delete(state crdt.yseq, pos int, len int, replica text)
returns crdt.yseq
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
begin
    perform crdt._yseq_check_replica('yseq_delete', replica);
    if pos is null or len is null then
        raise exception 'crdt.yseq_delete: pos and len must not be null' using errcode = '22004';
    end if;
    return crdt._yseq_splice(state, pos, len, null, replica);
end;
$$;

-- Make the text equal to `content`: keep the longest common prefix and
-- suffix (in code points), delete the middle of the old text and insert the
-- middle of the new one.
--
-- Without base (null): the diff is against the current text, so the result
-- is exactly `content`. That is last-writer-wins for the whole text: edits
-- other writers saved since this editor loaded the text are reverted.
--
-- With base, the state the editor loaded (the column value it read): a
-- three-way merge. The writer's own characters newer than the base count as
-- base (a second save from one base replaces the first). The diff is taken
-- against that text, the resulting op is numbered after the replica's last
-- character in either state, and it is integrated into `state`, so
-- concurrent edits to other parts of the text survive (test/spec/75_yseq_sync.sql,
-- 76_yseq_concurrency.sql, 79_yseq_review.sql). The base must be a version of the same
-- document. The base is the whole
-- state, not a version vector: the text at a version needs the tombstones
-- that came later, with their text, and the state keeps neither (experiments/text-column/NOTES.md,
-- "set() and concurrent saves"). The save path for a form or an ORM:
--
--   update posts set body = crdt.yseq_set(body, $1, $2, base => $3) where id = $4;
create function crdt.yseq_set(state crdt.yseq, content text, replica text, base crdt.yseq default null)
returns crdt.yseq
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    old text;
    b0 jsonb;
    b1 crdt.yseq;
    ops jsonb;
    ri int;
    cs int;
    bs int;
    ob bytea;
    nb bytea;
    la int;
    lb int;
    mn int;
    lo int;
    hi int;
    mid int;
    p int;
    q int;
    pc int;
    qc int;
begin
    perform crdt._yseq_check_replica('yseq_set', replica);
    if content is null then
        raise exception 'crdt.yseq_set: content must not be null' using errcode = '22004';
    end if;
    if state is null then
        state := crdt.yseq_empty();
    end if;
    if base is not null then
        -- 0. The base must be a version of this document: the same document
        --    id (when the states have one, from yseq_new), and no character
        --    the state lacks
        if base -> 'o' is distinct from state -> 'o' then
            raise exception 'crdt.yseq_set: the base belongs to another document (id % against %)', coalesce(base ->> 'o', 'none'), coalesce(state ->> 'o', 'none')
                using errcode = '22023';
        end if;
        if exists (select 1 from jsonb_each_text(crdt.yseq_version(base)) e
                   where e.value::int > coalesce((crdt.yseq_version(state) ->> e.key)::int, 0)) then
            raise exception 'crdt.yseq_set: the base has characters the state lacks, so it is not a version of this document'
                using errcode = '22023',
                      hint = 'Pass as base the value of the column the editor loaded.';
        end if;
        -- 1. The writer's own characters that the state has and the base
        --    has not (an earlier save from the same base, an autosave) count
        --    as part of the base, so saving again does not insert them twice.
        --    Their deletes come along; deletes by others since the base do
        --    not (they would be resurrected by the diff otherwise).
        bs := coalesce((crdt.yseq_version(base) ->> replica)::int, 0);
        cs := coalesce((crdt.yseq_version(state) ->> replica)::int, 0);
        b0 := base;
        if cs > bs then
            ops := crdt.yseq_ops_since(state, crdt.yseq_version(state) || jsonb_build_object(replica, bs));
            b0 := crdt._yseq_integrate(base, ops -> 'i',
                (select coalesce(jsonb_agg(jsonb_build_array(x ->> 0, greatest((x ->> 1)::int, bs + 1),
                                                             (x ->> 1)::int + (x ->> 2)::int - greatest((x ->> 1)::int, bs + 1))), '[]'::jsonb)
                 from jsonb_array_elements(ops -> 'd') x
                 where x ->> 0 = replica and (x ->> 1)::int + (x ->> 2)::int - 1 > bs));
        end if;
        -- 2. The edit as an op on that base, numbered after the replica's
        --    last character in either state, then integrated into the state.
        cs := greatest(cs, coalesce((crdt.yseq_version(b0::crdt.yseq) ->> replica)::int, 0));
        ri := array_position(array(select jsonb_array_elements_text(b0 -> 'r')), replica);
        if ri is null then
            if cs > 0 then
                b0 := jsonb_set(jsonb_set(b0, '{r}', (b0 -> 'r') || to_jsonb(replica)), '{c}', (b0 -> 'c') || to_jsonb(cs));
            end if;
        else
            b0 := jsonb_set(b0, array['c', (ri - 1)::text], to_jsonb(cs));
        end if;
        b1 := crdt.yseq_set(b0::crdt.yseq, content, replica);
        if b1::jsonb = b0 then
            return state;
        end if;
        ops := crdt.yseq_diff(b0::crdt.yseq, b1);
        return crdt._yseq_integrate(state, ops -> 'i', ops -> 'd');
    end if;
    old := crdt.yseq_value(state);
    if old = content then
        return state;
    end if;
    -- common prefix and suffix in UTF-8 bytes (binary search, comparing only
    -- the untested half), then back to character boundaries
    ob := convert_to(old, 'UTF8');
    nb := convert_to(content, 'UTF8');
    la := length(ob);
    lb := length(nb);
    mn := least(la, lb);
    lo := 0;
    hi := mn;
    while lo < hi loop
        mid := (lo + hi + 1) / 2;
        if substring(ob from lo + 1 for mid - lo) = substring(nb from lo + 1 for mid - lo) then
            lo := mid;
        else
            hi := mid - 1;
        end if;
    end loop;
    p := lo;
    while p > 0 and p < la and (get_byte(ob, p) & 192) = 128 loop
        p := p - 1;
    end loop;
    lo := 0;
    hi := mn - p;
    while lo < hi loop
        mid := (lo + hi + 1) / 2;
        if substring(ob from la - mid + 1 for mid - lo) = substring(nb from lb - mid + 1 for mid - lo) then
            lo := mid;
        else
            hi := mid - 1;
        end if;
    end loop;
    q := lo;
    while q > 0 and (get_byte(ob, la - q) & 192) = 128 loop
        q := q - 1;
    end loop;
    pc := length(convert_from(substring(ob from 1 for p), 'UTF8'));
    qc := length(convert_from(substring(ob from la - q + 1 for q), 'UTF8'));
    return crdt._yseq_splice(state, pc, length(old) - pc - qc,
                             convert_from(substring(nb from p + 1 for lb - p - q), 'UTF8'), replica);
end;
$$;

-- ============================================================================
-- yseq_: sync
-- ============================================================================

-- The ops a replica that has `vv` ({replica: count}, default {}) lacks:
-- {"i": insert runs with seq > vv[replica], in a causal order, "d": the whole
-- delete set}. Deleted characters are sent as U+FFFD; the delete set hides
-- them. Pending runs are not sent. Runs are coalesced as typing makes them.
create function crdt.yseq_ops_since(state crdt.yseq, vv jsonb default '{}')
returns jsonb
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    rr text[];
    nv int[];
    st text[];
    ms text[];
    cb int[];
    mm int[];
    nch int;
    known int[];
    e_ri int[] := '{}';
    e_s int[] := '{}';
    e_l int[] := '{}';
    e_olr int[] := '{}';
    e_ols int[] := '{}';
    e_orr int[] := '{}';
    e_ors int[] := '{}';
    e_t text[] := '{}';
    ne int := 0;
    ord int[];
    c_ri int[] := '{}';
    c_s int[] := '{}';
    c_l int[] := '{}';
    c_olr int[] := '{}';
    c_ols int[] := '{}';
    c_orr int[] := '{}';
    c_ors int[] := '{}';
    c_t text[] := '{}';
    nc int := 0;
    seg_lo int[];
    seg_hi int[];
    nrep int;
    out jsonb[] := '{}';
    nout int := 0;
    progress boolean;
    j int;
    i int;
    k int;
    v int;
    ln int;
    ri int;
    s int;
    off int;
begin
    if vv is null or vv = 'null'::jsonb then
        vv := '{}';
    end if;
    if jsonb_typeof(vv) <> 'object' or vv @? '$.* ? (@.type() != "number" || @ < 0 || @.floor() != @)' then
        raise exception 'crdt.yseq_ops_since: a version vector is an object of non-negative integers, got %', left(vv::text, 200)
            using errcode = '22023';
    end if;
    rr := array(select jsonb_array_elements_text(state -> 'r'));
    nrep := coalesce(cardinality(rr), 0);
    nv := translate((state -> 'n')::text, '[]', '{}')::int[];
    st := array(select jsonb_array_elements_text(state -> 's'));
    ms := array(select jsonb_array_elements_text(state -> 'm'));
    nch := coalesce(cardinality(nv), 0);
    cb := array_fill(1, array[nch + 1]);
    j := 1;
    while j <= nch loop
        cb[j + 1] := cb[j] + (length(ms[j]) - length(replace(ms[j], ',', '')) + 1) / 7;
        j := j + 1;
    end loop;
    mm := case when nch > 0 then replace(array_to_string(ms, ','), '},{', ',')::int[] else '{}'::int[] end;
    known := array(select least(coalesce((vv ->> x)::numeric, 0), 2147483647)::int from unnest(rr) x);

    -- runs (or their ends) the receiver lacks, with their text
    j := 1;
    while j <= nch loop
        v := 0;
        i := cb[j];
        while i < cb[j + 1] loop
            ln := mm[7 * i - 4];
            ri := mm[7 * i - 6];
            s := mm[7 * i - 5];
            if s + abs(ln) - 1 > known[ri] then
                off := greatest(known[ri] + 1 - s, 0);
                ne := ne + 1;
                e_ri[ne] := ri;
                e_s[ne] := s + off;
                e_l[ne] := abs(ln) - off;
                if off = 0 then
                    e_olr[ne] := mm[7 * i - 3];
                    e_ols[ne] := mm[7 * i - 2];
                else
                    e_olr[ne] := ri;
                    e_ols[ne] := s + off - 1;
                end if;
                e_orr[ne] := mm[7 * i - 1];
                e_ors[ne] := mm[7 * i];
                e_t[ne] := case when ln > 0 then substr(st[j], v + off + 1, ln - off)
                                -- U+FFFD; chr(), not a U& literal, so the function
                                -- also installs in a database that is not UTF8
                                else repeat(chr(65533), abs(ln) - off) end;
            end if;
            if ln > 0 then
                v := v + ln;
            end if;
            i := i + 1;
        end loop;
        j := j + 1;
    end loop;

    if ne > 0 then
        -- by replica and seq, coalescing what typing would have made one run
        ord := array(select u.o::int from unnest(e_ri, e_s) with ordinality u(ri, s, o) order by u.ri, u.s);
        seg_lo := array_fill(0, array[nrep]);
        seg_hi := array_fill(-1, array[nrep]);
        foreach k in array ord loop
            if nc > 0 and c_ri[nc] = e_ri[k] and c_s[nc] + c_l[nc] = e_s[k]
               and e_olr[k] = e_ri[k] and e_ols[k] = e_s[k] - 1
               and c_orr[nc] = e_orr[k] and c_ors[nc] = e_ors[k] then
                c_l[nc] := c_l[nc] + e_l[k];
                c_t[nc] := c_t[nc] || e_t[k];
            else
                nc := nc + 1;
                c_ri[nc] := e_ri[k];
                c_s[nc] := e_s[k];
                c_l[nc] := e_l[k];
                c_olr[nc] := e_olr[k];
                c_ols[nc] := e_ols[k];
                c_orr[nc] := e_orr[k];
                c_ors[nc] := e_ors[k];
                c_t[nc] := e_t[k];
                if seg_lo[e_ri[k]] = 0 then
                    seg_lo[e_ri[k]] := nc;
                end if;
                seg_hi[e_ri[k]] := nc;
            end if;
        end loop;
        -- causal order: per replica in seq order, a run once its origins are
        -- known to the receiver (sent before, or in vv)
        progress := true;
        while nout < nc loop
            progress := false;
            ri := 1;
            while ri <= nrep loop
                while seg_lo[ri] between 1 and seg_hi[ri] loop
                    k := seg_lo[ri];
                    exit when (c_olr[k] > 0 and c_ols[k] > known[c_olr[k]])
                           or (c_orr[k] > 0 and c_ors[k] > known[c_orr[k]]);
                    nout := nout + 1;
                    out[nout] := jsonb_build_array(rr[c_ri[k]], c_s[k],
                        case when c_olr[k] = 0 then null else jsonb_build_array(rr[c_olr[k]], c_ols[k]) end,
                        case when c_orr[k] = 0 then null else jsonb_build_array(rr[c_orr[k]], c_ors[k]) end,
                        c_t[k]);
                    known[ri] := greatest(known[ri], c_s[k] + c_l[k] - 1);
                    seg_lo[ri] := k + 1;
                    progress := true;
                end loop;
                ri := ri + 1;
            end loop;
            if not progress then
                raise exception 'crdt.yseq_ops_since: the state has runs whose origins are missing'
                    using errcode = 'XX000';
            end if;
        end loop;
    end if;

    return jsonb_build_object('i', to_jsonb(out), 'd', crdt._yseq_delete_set(state));
end;
$$;

-- The causal closure of `seed` ({replica: seq}) in `state`: the smallest
-- version vector that covers seed and every origin of every character it
-- covers. A run's cross-replica origins are on its first character, so each
-- round is one scan of the runs; rounds repeat until nothing grows.
create function crdt._yseq_closure(state crdt.yseq, seed jsonb)
returns jsonb
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    rr text[] := array(select jsonb_array_elements_text(state -> 'r'));
    mm int[];
    vv int[];
    nv int[];
begin
    if coalesce(cardinality(rr), 0) = 0 then
        return '{}'::jsonb;
    end if;
    mm := replace(array_to_string(array(select jsonb_array_elements_text(state -> 'm')), ','), '},{', ',')::int[];
    vv := array(select coalesce((seed ->> x)::numeric::int, 0) from unnest(rr) x);
    loop
        select array_agg(greatest(vv[g], coalesce(d.m, 0)) order by g) into nv
        from generate_series(1, cardinality(rr)) g
        left join (select t, max(sq) m
                   from (select mm[7 * i - 3] t, mm[7 * i - 2] sq from generate_series(1, cardinality(mm) / 7) i
                         where mm[7 * i - 3] > 0 and mm[7 * i - 3] <> mm[7 * i - 6] and mm[7 * i - 5] <= vv[mm[7 * i - 6]]
                         union all
                         select mm[7 * i - 1], mm[7 * i] from generate_series(1, cardinality(mm) / 7) i
                         where mm[7 * i - 1] > 0 and mm[7 * i - 1] <> mm[7 * i - 6] and mm[7 * i - 5] <= vv[mm[7 * i - 6]]) z
                   group by t) d on d.t = g;
        exit when nv = vv;
        vv := nv;
    end loop;
    return (select coalesce(jsonb_object_agg(rr[g], vv[g]), '{}'::jsonb) from generate_series(1, cardinality(rr)) g where vv[g] > 0);
end;
$$;

-- The op that takes `old` to `new` (a later version of the same document):
-- the inserts new has beyond old's version, only the deletes old lacks, and
-- v, for yseq_apply: the causal closure in old of what the op depends on
-- (its origins, each replica's previous character, its delete targets).
-- That is the smallest v the rules accept, and it is valid for any honest
-- local edit, including yseq_set with base (whose origins were adjacent in
-- the base, not necessarily in old). For a local edit,
-- `yseq_diff(s, crdt.yseq_insert(s, ...))` is exactly the op it generated.
create function crdt.yseq_diff(old crdt.yseq, new crdt.yseq)
returns jsonb
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    ov jsonb;
    i jsonb;
    d jsonb;
begin
    old := coalesce(old, crdt.yseq_empty());
    ov := crdt.yseq_version(old);
    i := crdt.yseq_ops_since(new, ov) -> 'i';
    d := (select coalesce(jsonb_agg(jsonb_build_array(k, lower(g), upper(g) - lower(g)) order by k collate "C", lower(g)), '[]'::jsonb)
          from (select n.k, unnest(n.mr - coalesce(o.mr, '{}'::int8multirange)) g
                from (select x ->> 0 k, range_agg(int8range((x ->> 1)::numeric::int8, (x ->> 1)::numeric::int8 + (x ->> 2)::numeric::int8)) mr
                      from jsonb_array_elements(crdt._yseq_delete_set(new)) x group by 1) n
                left join (select x ->> 0 k, range_agg(int8range((x ->> 1)::numeric::int8, (x ->> 1)::numeric::int8 + (x ->> 2)::numeric::int8)) mr
                           from jsonb_array_elements(crdt._yseq_delete_set(coalesce(old, crdt.yseq_empty()))) x group by 1) o
                  on o.k = n.k) z);
    return jsonb_build_object('v', crdt._yseq_closure(old, (
        select coalesce(jsonb_object_agg(k, m), '{}'::jsonb)
        from (select k, max(t) m
              from (select x -> 2 ->> 0 k, (x -> 2 ->> 1)::int t from jsonb_array_elements(i) x where x -> 2 <> 'null'::jsonb
                    union all
                    select x -> 3 ->> 0, (x -> 3 ->> 1)::int from jsonb_array_elements(i) x where x -> 3 <> 'null'::jsonb
                    union all
                    select x ->> 0, (x ->> 1)::int - 1 from jsonb_array_elements(i) x
                    union all
                    select y ->> 0, (y ->> 1)::int + (y ->> 2)::int - 1 from jsonb_array_elements(d) y) z
              where t > 0 and t <= coalesce((ov ->> k)::int, 0)
              group by k) w)),
        'i', i, 'd', d);
end;
$$;

-- What yseq_merge needs of a state beyond the domain, which it cannot check
-- cheaply: chunk lengths that are integers, chunk texts that are strings,
-- chunk runs that are int[] literals of 7 ints per run, and well-formed
-- pending entries. Raises 22023 naming the function
-- and the argument. A regular expression over the runs: about 2 ms for the
-- 100k-character trace state, where the merge costs 40 ms or more.
create function crdt._yseq_check(state crdt.yseq, what text)
returns void
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
begin
    if state is null then
        return;
    end if;
    if state @? 'strict $.n[*] ? (@ < 0 || @ > 2147483647 || @.floor() != @)'
       or state @? 'strict $.s[*] ? (@.type() != "string")'
       or state @? 'strict $.m[*] ? (@.type() != "string")'
       or exists (select 1 from jsonb_array_elements_text(state -> 'm') x
                  where x !~ '^\{[0-9]+,[0-9]+,-?[0-9]+,[0-9]+,[0-9]+,[0-9]+,[0-9]+(,[0-9]+,[0-9]+,-?[0-9]+,[0-9]+,[0-9]+,[0-9]+,[0-9]+)*\}$')
       or exists (select 1 from jsonb_array_elements(state -> 'p') x where not crdt._yseq_valid_run(x))
       or exists (select 1 from jsonb_array_elements(state -> 'x') x where not crdt._yseq_valid_del(x)) then
        raise exception 'crdt.%: not a well-formed crdt.yseq state', what
            using errcode = '22023', hint = 'crdt.yseq_is_valid checks a state in full.';
    end if;
end;
$$;

-- Full-state merge: commutative, associative and idempotent on the
-- document (the items, the delete set and the pending ops). The chunk layout
-- of the result can differ with the argument order; crdt._yseq_normalize
-- gives the canonical form. merge(x, null) = merge(null, x) = x.
create function crdt.yseq_merge(a crdt.yseq, b crdt.yseq)
returns crdt.yseq
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    ops jsonb;
begin
    if a is null then
        return b;
    end if;
    if b is null then
        return a;
    end if;
    perform crdt._yseq_check(a, 'yseq_merge: argument a');
    perform crdt._yseq_check(b, 'yseq_merge: argument b');
    if a -> 'o' is distinct from b -> 'o' and a ? 'o' and b ? 'o' then
        raise exception 'crdt.yseq_merge: the states belong to different documents (ids % and %)', a ->> 'o', b ->> 'o'
            using errcode = '22023';
    end if;
    if b ? 'o' and not a ? 'o' then
        a := (a::jsonb || jsonb_build_object('o', b -> 'o'))::crdt.yseq;
    end if;
    ops := crdt.yseq_ops_since(b, crdt.yseq_version(a));
    if jsonb_array_length(b -> 'q') > 0 then
        -- b's waiting validated ops wait in the result too (or run now)
        a := jsonb_set(a, '{q}', (a -> 'q') || (b -> 'q'));
    end if;
    return crdt._yseq_integrate(a, (ops -> 'i') || (b -> 'p'), (ops -> 'd') || (b -> 'x'));
end;
$$;

create aggregate crdt.yseq_merge_agg(crdt.yseq) (
    sfunc = crdt.yseq_merge,
    stype = crdt.yseq,
    combinefunc = crdt.yseq_merge,
    parallel = safe
);

-- Limits on what one untrusted op may carry: replica keys (ids, devices,
-- origins, v keys) of at most 256 bytes, at most 128 insert runs after
-- joining runs that continue each other (4,096 before), and at most 32
-- replica keys (devices) per writer in a state.
-- They bound the cost of the causal checks (V5 walks between the origins of
-- each run) and the size that keys add to every later v and to the state.
create function crdt._yseq_limit(kind text)
returns int
language sql immutable parallel safe
return case kind when 'key_bytes' then 256 when 'runs' then 128 when 'devices' then 32 end;

-- Join runs of an op that continue each other (same replica, consecutive
-- seqs, originLeft the previous character, same originRight): one run, as
-- typing them would have made. Used to count runs against the limit; the
-- engine keeps the runs as sent (a run that repeats integrated ids is
-- skipped, a joined one would overlap them) and skips the V4/V5 walk for a
-- run that continues the previous one, which cannot fail where that one
-- passed.
create function crdt._yseq_coalesce(op jsonb)
returns jsonb
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    out jsonb[] := '{}';
    n int := 0;
    x jsonb;
    lst jsonb;
begin
    if jsonb_typeof(op -> 'i') is distinct from 'array' or jsonb_array_length(op -> 'i') < 2 then
        return op;
    end if;
    for x in select y from jsonb_array_elements(op -> 'i') y loop
        if n > 0 then
            lst := out[n];
            if jsonb_typeof(x) = 'array' and jsonb_typeof(lst) = 'array'
               and x -> 0 = lst -> 0 and jsonb_typeof(x -> 1) = 'number' and jsonb_typeof(lst -> 1) = 'number'
               and jsonb_typeof(x -> 4) = 'string' and jsonb_typeof(lst -> 4) = 'string'
               and (x ->> 1)::numeric = (lst ->> 1)::numeric + length(lst ->> 4)
               and x -> 2 = jsonb_build_array(lst -> 0, (lst ->> 1)::numeric + length(lst ->> 4) - 1)
               and x -> 3 = lst -> 3 then
                out[n] := jsonb_set(lst, '{4}', to_jsonb((lst ->> 4) || (x ->> 4)));
                continue;
            end if;
        end if;
        n := n + 1;
        out[n] := x;
    end loop;
    return jsonb_set(op, '{i}', to_jsonb(out));
end;
$$;

-- The causal rules that read only the op (V0, V1, V2, V6), its shape and the
-- limits: null when the op passes, else the reason. Used by yseq_apply on
-- arrival and again by crdt._yseq_integrate for waiting ops it loads (which
-- may come from another state through yseq_merge).
create function crdt._yseq_op_static(op jsonb)
returns text
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    vadv jsonb;
    x jsonb;
begin
    if jsonb_typeof(op) is distinct from 'object'
       or (op - '{i,d,v}'::text[]) <> '{}'::jsonb
       or coalesce(jsonb_typeof(op -> 'i'), 'null') not in ('array', 'null')
       or coalesce(jsonb_typeof(op -> 'd'), 'null') not in ('array', 'null') then
        return 'malformed op';
    end if;
    if exists (select 1 from jsonb_array_elements(coalesce(op -> 'i', '[]'::jsonb)) y where not crdt._yseq_valid_run(y)) then
        return 'malformed insert run';
    end if;
    if exists (select 1 from jsonb_array_elements(coalesce(op -> 'd', '[]'::jsonb)) y where not crdt._yseq_valid_del(y)) then
        return 'malformed delete';
    end if;
    if jsonb_array_length(coalesce(op -> 'i', '[]'::jsonb)) > 32 * crdt._yseq_limit('runs')
       or jsonb_array_length(coalesce(crdt._yseq_coalesce(op) -> 'i', '[]'::jsonb)) > crdt._yseq_limit('runs') then
        return format('more than %s insert runs in one op (after joining runs that continue each other), or more than %s before',
                      crdt._yseq_limit('runs'), 32 * crdt._yseq_limit('runs'));
    end if;
    if jsonb_typeof(op -> 'v') is distinct from 'object'
       or exists (select 1 from jsonb_each(op -> 'v') e
                  where e.key !~ '^[^:]+(:.+)?$' or jsonb_typeof(e.value) <> 'number'
                     or (e.value #>> '{}')::numeric not between 1 and 2147483647
                     or (e.value #>> '{}')::numeric <> floor((e.value #>> '{}')::numeric)) then
        return 'V0: the op has no version vector v of replica keys and counts from 1';
    end if;
    if exists (select 1 from jsonb_object_keys(op -> 'v') k where octet_length(k) > crdt._yseq_limit('key_bytes'))
       or exists (select 1 from jsonb_array_elements(coalesce(op -> 'i', '[]'::jsonb)) y
                  where octet_length(y ->> 0) > crdt._yseq_limit('key_bytes')
                     or octet_length(y -> 2 ->> 0) > crdt._yseq_limit('key_bytes')
                     or octet_length(y -> 3 ->> 0) > crdt._yseq_limit('key_bytes'))
       or exists (select 1 from jsonb_array_elements(coalesce(op -> 'd', '[]'::jsonb)) y
                  where octet_length(y ->> 0) > crdt._yseq_limit('key_bytes')) then
        return format('a replica key is longer than %s bytes', crdt._yseq_limit('key_bytes'));
    end if;
    vadv := op -> 'v';
    for x in select y from jsonb_array_elements(coalesce(op -> 'i', '[]'::jsonb)) y loop
        if (x -> 2 <> 'null'::jsonb and (x -> 2 ->> 1)::numeric > coalesce((vadv ->> (x -> 2 ->> 0))::numeric, 0))
           or (x -> 3 <> 'null'::jsonb and (x -> 3 ->> 1)::numeric > coalesce((vadv ->> (x -> 3 ->> 0))::numeric, 0)) then
            return 'V1: an origin is not covered by v';
        end if;
        if coalesce((vadv ->> (x ->> 0))::numeric, 0) <> (x ->> 1)::numeric - 1 then
            return 'V2: a run does not start at v[replica] + 1';
        end if;
        vadv := vadv || jsonb_build_object(x ->> 0, (x ->> 1)::numeric + length(x ->> 4) - 1);
    end loop;
    if exists (select 1 from jsonb_array_elements(coalesce(op -> 'd', '[]'::jsonb)) y
               where (y ->> 1)::numeric + (y ->> 2)::numeric - 1 > coalesce((vadv ->> (y ->> 0))::numeric, 0)) then
        return 'V6: a delete target is not covered by v';
    end if;
    return null;
end;
$$;

-- The write path for untrusted writers: ops from a writer whose identity is
-- `replica` (default crdt.current_replica_id()). `ops` is one op
-- {"v": {...}, "i": [...], "d": [...]} or an array of them; v is the
-- sender's version vector before the op (research/text.md, Amendment 1).
-- Every insert run must belong to `replica` (its key is the id or
-- <id>:<device>); deletes may target anyone's characters. Each op is
-- accepted or rejected whole, by the causal rules V0 to V7
-- (experiments/text-ref/README.md): V0, V1, V2 and V6 here, on arrival; V7
-- (wait until the document has everything v names), V3, V4 and V5 in
-- crdt._yseq_integrate. A waiting op is kept in the state ("q") within a
-- quota per writer (crdt._yseq_quota). Re-applying an op is a no-op. Ops
-- from yseq_ops_since carry no v: they are for trusted catch-up
-- (yseq_merge or crdt._yseq_integrate), not for this function.
--
-- Errors: 42501 no replica (null), or an insert run of another replica;
-- 22023 a replica that is empty or contains ":", a malformed op, or an op
-- rejected by a causal rule (when it arrives, or when it stops waiting in
-- this call); 54000 the writer's waiting ops exceed the quota.
create function crdt.yseq_apply(state crdt.yseq, ops jsonb, replica text default crdt.current_replica_id())
returns crdt.yseq
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    ins jsonb;
    dels jsonb;
    bad jsonb;
    op1 jsonb;
    run1 jsonb;
    vadv jsonb;
    why text;
begin
    if replica is null then
        raise exception 'crdt.yseq_apply: the writer has no replica id'
            using errcode = '42501',
                  hint = 'Pass the writer''s identity as the replica argument, or set it up for crdt.current_replica_id() (a JWT claim in request.jwt.claims, or the crdt.replica_id setting).';
    end if;
    if replica !~ '^[^:]+$' or octet_length(replica) > crdt._yseq_limit('key_bytes') then
        raise exception 'crdt.yseq_apply: % is not a replica id', quote_literal(left(replica, 64))
            using errcode = '22023',
                  hint = 'A replica id is non-empty, at most 256 bytes, and has no ":" (":" separates a replica id from a device suffix).';
    end if;
    if ops is null then
        return state;
    end if;
    if jsonb_typeof(ops) = 'object' then
        ops := jsonb_build_array(ops);
    end if;
    if jsonb_typeof(ops) <> 'array' then
        raise exception 'crdt.yseq_apply: ops must be an op object or an array of them'
            using errcode = '22023';
    end if;
    select o into bad
    from jsonb_array_elements(ops) o
    where jsonb_typeof(o) <> 'object'
       or (o - '{i,d,v}'::text[]) <> '{}'::jsonb
       or coalesce(jsonb_typeof(o -> 'i'), 'null') not in ('array', 'null')
       or coalesce(jsonb_typeof(o -> 'd'), 'null') not in ('array', 'null')
    limit 1;
    if found then
        raise exception 'crdt.yseq_apply: malformed op %', left(bad::text, 200)
            using errcode = '22023', hint = 'An op is {"i": [insert runs], "d": [deletes]}.';
    end if;
    select coalesce(jsonb_agg(x order by a.o, b.o), '[]'::jsonb) into ins
    from jsonb_array_elements(ops) with ordinality a(op, o),
         jsonb_array_elements(case jsonb_typeof(a.op -> 'i') when 'array' then a.op -> 'i' else '[]'::jsonb end) with ordinality b(x, o);
    select coalesce(jsonb_agg(x order by a.o, b.o), '[]'::jsonb) into dels
    from jsonb_array_elements(ops) with ordinality a(op, o),
         jsonb_array_elements(case jsonb_typeof(a.op -> 'd') when 'array' then a.op -> 'd' else '[]'::jsonb end) with ordinality b(x, o);

    select x into bad from jsonb_array_elements(ins) x where not crdt._yseq_valid_run(x) limit 1;
    if found then
        raise exception 'crdt.yseq_apply: malformed insert run %', left(bad::text, 200)
            using errcode = '22023',
                  hint = 'An insert run is [replica key, seq, originLeft, originRight, text], with origins null or [replica key, seq], seq from 1 to 2147483647 and non-empty text.';
    end if;
    select x into bad from jsonb_array_elements(dels) x where not crdt._yseq_valid_del(x) limit 1;
    if found then
        raise exception 'crdt.yseq_apply: malformed delete %', left(bad::text, 200)
            using errcode = '22023', hint = 'A delete is [replica key, seq, len], seq and len from 1 to 2147483647.';
    end if;
    select x into bad from jsonb_array_elements(ins) x where split_part(x ->> 0, ':', 1) <> replica limit 1;
    if found then
        raise exception 'crdt.yseq_apply: replica % cannot insert characters of replica %', quote_literal(replica), quote_literal(bad ->> 0)
            using errcode = '42501',
                  hint = 'Insert runs may only carry the writer''s own replica id, or <replica id>:<device>.';
    end if;
    -- the static causal rules and limits, op by op
    -- (experiments/text-ref/README.md): V0 v is a version vector, V1 origins
    -- covered by v advanced run by run, V2 a run's first seq is v[replica] +
    -- 1, V6 delete targets covered
    for op1 in select y from jsonb_array_elements(ops) y loop
        why := crdt._yseq_op_static(op1);
        if why is not null then
            raise exception 'crdt.yseq_apply: op rejected (%)', why
                using errcode = '22023',
                      hint = 'The op breaks a causal rule of research/text.md, Amendment 1 (experiments/text-ref/README.md, V0 to V7), or a limit (crdt._yseq_limit).';
        end if;
    end loop;
    -- at most crdt._yseq_limit('devices') replica keys per writer
    if (select count(distinct k) from (
            select jsonb_array_elements_text(coalesce(state, crdt.yseq_empty()) -> 'r') k
            union
            select x ->> 0 from jsonb_array_elements(ins) x) z
        where split_part(k, ':', 1) = replica) > crdt._yseq_limit('devices') then
        raise exception 'crdt.yseq_apply: writer % would have more than % replica keys (devices)', quote_literal(replica), crdt._yseq_limit('devices')
            using errcode = '54000';
    end if;
    if jsonb_array_length(ins) = 0 and jsonb_array_length(dels) = 0 then
        return coalesce(state, crdt.yseq_empty());
    end if;
    return crdt._yseq_integrate(coalesce(state, crdt.yseq_empty()), '[]', '[]',
        (select jsonb_agg(jsonb_build_array(replica, y) order by o) from jsonb_array_elements(ops) with ordinality a(y, o)));
end;
$$;

-- ============================================================================
-- yseq_: validation and the canonical form
-- ============================================================================

-- The full validator: the envelope, every chunk (text length, run layout),
-- every run (replica indexes, origins present), the version vector (each
-- replica's runs cover 1 .. c exactly), origins on the correct side, and
-- the pending ops. Expensive (it sorts the runs); for tests and for a table
-- CHECK where states come from outside. Null for null.
create function crdt.yseq_is_valid(state jsonb)
returns boolean
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    rr text[];
    cc int[];
    nv int[];
    st text[];
    ms text[];
    mm int[];
    nr int;
    j int;
    cm int[];
    ok boolean;
begin
    if state is null then
        return null;
    end if;
    if not coalesce(jsonb_typeof(state) = 'object'
        and state @> '{"t": "yseq", "v": 1, "r": [], "c": [], "n": [], "s": [], "m": [], "p": [], "x": [], "q": []}'
        and (state - '{t,v,r,c,n,s,m,p,x,q,o}'::text[]) = '{}'::jsonb, false) then
        return false;
    end if;
    if state @? '$.r[*] ? (@.type() != "string")'
       or state @? '$.c[*] ? (@.type() != "number" || @ < 1 || @ > 2147483647 || @.floor() != @)'
       or state @? '$.n[*] ? (@.type() != "number" || @ < 0 || @.floor() != @)'
       or state @? '$.s[*] ? (@.type() != "string")'
       or state @? '$.m[*] ? (@.type() != "string" || !(@ like_regex "^\\{-?[0-9]+(,-?[0-9]+)*\\}$"))' then
        return false;
    end if;
    rr := array(select jsonb_array_elements_text(state -> 'r'));
    cc := translate((state -> 'c')::text, '[]', '{}')::int[];
    nv := translate((state -> 'n')::text, '[]', '{}')::int[];
    st := array(select jsonb_array_elements_text(state -> 's'));
    ms := array(select jsonb_array_elements_text(state -> 'm'));
    if coalesce(cardinality(rr), 0) <> coalesce(cardinality(cc), 0)
       or exists (select 1 from unnest(rr) x where x !~ '^[^:]+(:.+)?$')
       or (select count(distinct x) from unnest(rr) x) <> coalesce(cardinality(rr), 0)
       or coalesce(cardinality(nv), 0) <> coalesce(cardinality(st), 0)
       or coalesce(cardinality(nv), 0) <> coalesce(cardinality(ms), 0) then
        return false;
    end if;
    j := 1;
    while j <= coalesce(cardinality(ms), 0) loop
        cm := ms[j]::int[];
        if cardinality(cm) % 7 <> 0 or cardinality(cm) > 7 * crdt._yseq_cmax()
           or length(st[j]) <> nv[j]
           or nv[j] <> (select coalesce(sum(cm[7 * i - 4]), 0) from generate_series(1, cardinality(cm) / 7) i where cm[7 * i - 4] > 0) then
            return false;
        end if;
        j := j + 1;
    end loop;
    mm := case when cardinality(ms) > 0 then replace(array_to_string(ms, ','), '},{', ',')::int[] else '{}'::int[] end;
    nr := cardinality(mm) / 7;
    with runs as (
        select i, mm[7 * i - 6] rep, mm[7 * i - 5] seq, abs(mm[7 * i - 4]) len, mm[7 * i - 4] slen,
               mm[7 * i - 3] olr, mm[7 * i - 2] ols, mm[7 * i - 1] orr, mm[7 * i] ors
        from generate_series(1, nr) i
    ),
    shape as (
        select bool_and(rep between 1 and cardinality(rr) and seq >= 1 and slen <> 0
                        and seq + len - 1 <= cc[rep]
                        and ((olr = 0 and ols = 0) or (olr between 1 and cardinality(rr) and ols between 1 and cc[olr]))
                        and ((orr = 0 and ors = 0) or (orr between 1 and cardinality(rr) and ors between 1 and cc[orr]))) ok
        from runs
    ),
    cover as (
        -- each replica's runs, by seq, are 1 .. c without gaps or overlaps
        select bool_and(seq = coalesce(prev_end, 0) + 1) ok
        from (select rep, seq, lag(seq + len - 1) over (partition by rep order by seq) prev_end from runs) z
    ),
    counts as (
        select bool_and(coalesce(t.total, 0) = cc[g]) ok
        from generate_series(1, cardinality(rr)) g
        left join (select rep, sum(len) total from runs group by rep) t on t.rep = g
    ),
    sides as (
        -- originLeft is before the run, originRight after it
        select bool_and(coalesce(l.i < r.i, true) and coalesce(o.i > r.i, true)) ok
        from runs r
        left join runs l on r.olr > 0 and l.rep = r.olr and r.ols between l.seq and l.seq + l.len - 1
        left join runs o on r.orr > 0 and o.rep = r.orr and r.ors between o.seq and o.seq + o.len - 1
    )
    select coalesce(shape.ok, true) and coalesce(cover.ok, true) and coalesce(counts.ok, true) and coalesce(sides.ok, true)
      into ok
    from shape, cover, counts, sides;
    if not ok then
        return false;
    end if;
    -- pending entries: well formed, and really pending (a pending delete
    -- names only ids not present; a pending run is neither wholly present
    -- nor ready to integrate, which the integration never leaves behind)
    return not exists (select 1 from jsonb_array_elements(state -> 'p') x where not crdt._yseq_valid_run(x))
       and not exists (select 1 from jsonb_array_elements(state -> 'x') x where not crdt._yseq_valid_del(x))
       and not exists (select 1 from jsonb_array_elements(state -> 'x') x
                       where (x ->> 1)::numeric <= coalesce(cc[array_position(rr, x ->> 0)], 0))
       and not exists (select 1 from jsonb_array_elements(state -> 'p') x
                       where (x ->> 1)::numeric + length(x ->> 4) - 1 <= coalesce(cc[array_position(rr, x ->> 0)], 0))
       and not exists (select 1 from jsonb_array_elements(state -> 'p') x
                       where (x ->> 1)::numeric <= coalesce(cc[array_position(rr, x ->> 0)], 0) + 1
                         and (x -> 2 = 'null'::jsonb or (x -> 2 ->> 1)::numeric <= coalesce(cc[array_position(rr, x -> 2 ->> 0)], 0))
                         and (x -> 3 = 'null'::jsonb or (x -> 3 ->> 1)::numeric <= coalesce(cc[array_position(rr, x -> 3 ->> 0)], 0)));
end;
$$;

-- The canonical form of a state: replicas sorted (collate "C"), runs merged
-- across chunk boundaries, chunks of cmax / 2 runs from the start, pending ops
-- sorted. Two states hold the same document exactly when their canonical
-- forms are equal. For tests and comparisons; costs a rebuild.
create function crdt._yseq_normalize(state crdt.yseq)
returns crdt.yseq
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    rr text[];
    sr text[];
    cc int[];
    map int[];
    nv int[];
    st text[];
    ms text[];
    mm int[];
    nr int;
    txt text;
    o int[] := '{}';
    m int := 0;
    i int;
    pl int;
    out_n int[] := '{}';
    out_s text[] := '{}';
    out_m text[] := '{}';
    vis int;
    pos int := 0;
    cnt int;
begin
    if state is null then
        return null;
    end if;
    rr := array(select jsonb_array_elements_text(state -> 'r'));
    cc := translate((state -> 'c')::text, '[]', '{}')::int[];
    sr := array(select x from unnest(rr) x order by x collate "C");
    map := array(select array_position(sr, x) from unnest(rr) x);
    ms := array(select jsonb_array_elements_text(state -> 'm'));
    mm := case when cardinality(ms) > 0 then replace(array_to_string(ms, ','), '},{', ',')::int[] else '{}'::int[] end;
    nr := cardinality(mm) / 7;
    txt := crdt.yseq_value(state);
    i := 1;
    while i <= nr loop
        mm[7 * i - 6] := map[mm[7 * i - 6]];
        if mm[7 * i - 3] > 0 then mm[7 * i - 3] := map[mm[7 * i - 3]]; end if;
        if mm[7 * i - 1] > 0 then mm[7 * i - 1] := map[mm[7 * i - 1]]; end if;
        i := i + 1;
    end loop;
    o := crdt._yseq_compact(mm);
    nr := cardinality(o) / 7;
    i := 1;
    while i <= nr loop
        cnt := least(crdt._yseq_cmax() / 2, nr - i + 1);
        vis := (select coalesce(sum(o[7 * g - 4]), 0) from generate_series(i, i + cnt - 1) g where o[7 * g - 4] > 0);
        out_n := out_n || vis;
        out_s := out_s || substr(txt, pos + 1, vis);
        out_m := out_m || o[7 * i - 6 : 7 * (i + cnt - 1)]::text;
        pos := pos + vis;
        i := i + cnt;
    end loop;
    return (jsonb_build_object(
        't', 'yseq', 'v', 1,
        'r', to_jsonb(coalesce(sr, '{}')),
        'c', to_jsonb(coalesce(array(select cc[array_position(rr, x)] from unnest(sr) x), '{}')),
        'n', to_jsonb(out_n), 's', to_jsonb(out_s), 'm', to_jsonb(out_m),
        'p', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements(state -> 'p') x),
        'q', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements(state -> 'q') x),

        'x', (select coalesce(jsonb_agg(jsonb_build_array(k, lower(g), upper(g) - lower(g)) order by k collate "C", lower(g)), '[]'::jsonb)
              from (select k, unnest(range_agg(rg)) g
                    from (select x ->> 0 k, int8range((x ->> 1)::numeric::int8, (x ->> 1)::numeric::int8 + (x ->> 2)::numeric::int8) rg
                          from jsonb_array_elements(state -> 'x') x) z group by k) y))
        || case when state ? 'o' then jsonb_build_object('o', state -> 'o') else '{}'::jsonb end)::crdt.yseq;
end;
$$;


-- ============================================================================
-- ydoc_: collaborative text, one document in tables
-- ============================================================================

-- A text CRDT (YjsMod order, the contract in research/text.md) whose state
-- lives in the tables below, one row per run of characters, not in a column.
-- An app's table holds a document id (posts.body_doc text references
-- crdt.ydoc_docs (uid)); every function takes that id, a text the client may
-- choose (ydoc_create). Design, measurements
-- and the review history: experiments/text-table/NOTES.md. User docs:
-- docs/types/collaborative-text.md, docs/reference/ydoc.md.
--
--   ydoc_docs     one row per document: public id (uid, text), visible length,
--                 write counter (gen); `id`, a bigint, is the internal id
--   ydoc_replicas replica ids (entry keys), interned: rows hold an integer
--   ydoc_items    one row per run of characters: id (replica, seq), length,
--                 origins of its first character, content, tombstone (del_gen),
--                 and `ord`, a server-local order label (bigint)
--   ydoc_blocks   a positional index: per label range, visible length and rows
--   ydoc_pending  inserts waiting for their origins (causal buffering)
--   ydoc_pending_deletes  deletes of ids not seen yet
--   ydoc_deps, ydoc_pending_ops, ydoc_rejected  the untrusted path (ydoc_apply)
--
-- The public document id is text (uid) and the tables below it use the
-- internal bigint (id): 45 columns name a document, and 8 bytes keep their
-- rows and indexes small. Every public function resolves uid to id once, in
-- the probe that also locks the document row (_ydoc_lock); the internals
-- take the id.
--
-- The order label is a cache of the YjsMod order, local to this database; it
-- is not part of the wire format. Every write locks the document row first,
-- so writes to one document are serialized and each incoming run is
-- integrated against a stable sequence: the YjsMod scan between originLeft
-- and originRight is an index range scan on (doc, ord), and render is
-- string_agg(content order by ord).
--
-- Labels are list labeling (order maintenance): a new row takes the midpoint
-- of its neighbours' labels; when there is no integer between them, a window
-- of rows around the spot is relabelled evenly. Labels stay 8 bytes. (Byte
-- string fractional keys, the first version, grew to 288 bytes on the
-- automerge-paper trace; see experiments/text-table/NOTES.md.)
--
-- The tables belong to the extension: drop extension drops them, and every
-- document with them. Nobody but their owner has privileges on them (the
-- privileges section). The functions are SECURITY INVOKER, so a call runs
-- with the caller's table privileges: the app grants the tables to the role
-- that owns its own SECURITY DEFINER wrappers (docs/guides/collaborative-text.md).

-- ============================================================================
-- ydoc_: tables
-- ============================================================================

-- A public document id: non-empty, at most 256 bytes, no control characters
-- (C0, DEL, C1). Immutable, so a CHECK constraint can use it.
create function crdt._ydoc_uid_valid(p_uid text)
returns boolean
language sql immutable parallel safe
return p_uid is not null and p_uid <> '' and pg_catalog.octet_length(p_uid) <= 256
       and p_uid !~ E'[\\x01-\\x1f\\x7f-\\x9f]';

create table crdt.ydoc_docs (
    id  bigint generated always as identity primary key,
    uid text collate "C" not null,    -- the public id, chosen by the client or a uuid
    len integer not null default 0,   -- visible code points
    gen bigint not null default 0,    -- +1 per write call; stamps deletes
    horizon bigint not null default 0, -- ydoc_compact: deletes at or before it may be merged
    constraint ydoc_docs_uid_key unique (uid),
    constraint ydoc_docs_uid_valid check (crdt._ydoc_uid_valid(uid))
);

-- Integration order of rows. Writes to one document are serialized, so per
-- document this is the order in which runs were integrated: causal.
create sequence crdt.ydoc_ins;

-- Column order: the columns that change in place (del_gen, len, content) come
-- last, so a same-page update logs only them. ord is unique per document by
-- construction; the index is not unique so that a relabel can rewrite a
-- window of labels in one statement.
-- Replica ids (entry keys: `id` or `id:device`), interned per document. A
-- row names its replica and its origins' replicas with these integers, so an
-- id costs 4 bytes per use however long it is (UUIDs are 36 chars). The
-- integer is local to the document and never leaves the database: ops in and
-- out carry names, and the YjsMod tie-break compares names (collate "C"),
-- never these integers. Per document, not global: interning happens under
-- the document's lock (no cross-document lock waits or deadlocks, which a
-- global unique name index had), ids are dense (max + 1), and ydoc_drop
-- removes them.
create table crdt.ydoc_replicas (
    doc  bigint not null,
    id   integer not null,
    name text collate "C" not null,
    primary key (doc, id),
    unique (doc, name)
);

create table crdt.ydoc_items (
    doc        bigint not null,
    ord        bigint not null,
    ins        bigint not null default nextval('crdt.ydoc_ins'),  -- integration order (causal), for ops_since
    seq        integer not null,
    replica    integer not null,      -- crdt.ydoc_replicas.id
    ol_seq     integer,
    ol_replica integer,
    or_seq     integer,
    or_replica integer,
    del_gen    bigint,                -- null: visible; else the gen of the delete
    len        integer not null,
    content    text not null,
    primary key (doc, replica, seq)
) with (fillfactor = 90);
create index ydoc_items_ord on crdt.ydoc_items (doc, ord);

-- Block b covers the labels from b.lo up to the next block's lo. The first
-- block of a document has lo = the smallest bigint. Positions are found with
-- a running sum over the blocks, then over the rows of one block.
create table crdt.ydoc_blocks (
    doc bigint not null,
    lo  bigint not null,
    vis integer not null default 0,
    n   integer not null default 0,
    primary key (doc, lo)
) with (fillfactor = 50);

-- The buffers keep replica names: they hold input that may never become
-- ready (forged or far-ahead ids), which should not grow ydoc_replicas.
create table crdt.ydoc_pending (
    doc        bigint not null,
    replica    text collate "C" not null,
    seq        integer not null,
    ol_replica text collate "C",
    ol_seq     integer,
    or_replica text collate "C",
    or_seq     integer,
    content    text not null,
    primary key (doc, replica, seq)
);
create index ydoc_pending_ol on crdt.ydoc_pending (doc, ol_replica, ol_seq);
create index ydoc_pending_or on crdt.ydoc_pending (doc, or_replica, or_seq);

create table crdt.ydoc_pending_deletes (
    doc     bigint not null,
    replica text collate "C" not null,
    seq     integer not null,
    len     integer not null,
    primary key (doc, replica, seq)
);

-- Rule V3 of the untrusted path (research/text.md, experiments/text-ref/README.md): the
-- cumulative dependencies of a replica's items, {replica id: highest origin
-- seq} over its items 1..seq, other replicas only. Constant along a run (its
-- later chars' originLeft is the same replica, their originRight the run's),
-- so it is stored only where it changes: at the first seq of a run whose
-- origins raise it. dp(r, n) is the row with the highest seq <= n. A
-- document written by one replica has no rows here.
create table crdt.ydoc_deps (
    doc     bigint not null,
    replica integer not null,
    seq     integer not null,
    dp      jsonb not null,
    primary key (doc, replica, seq)
);

-- Untrusted ops (ydoc_apply) whose version vector names ids this document
-- does not have yet (rule V7). Bounded per writer and document.
create table crdt.ydoc_pending_ops (
    doc     bigint not null,
    id      bigint generated always as identity,
    writer  text not null,
    op      jsonb not null,
    bytes   integer not null,
    primary key (doc, id)
);
create index ydoc_pending_ops_writer on crdt.ydoc_pending_ops (doc, writer);

-- Waiting ops that were rejected when they were finally decided, during a
-- later call (an op rejected on arrival raises instead). For the app to tell
-- its writers; nothing reads it, and the app may delete from it. The last
-- _ydoc_rejected_max() per writer and document are kept.
create table crdt.ydoc_rejected (
    id     bigint generated always as identity,
    doc    bigint not null,
    writer text not null,
    op     jsonb not null,
    reason text not null,
    at     timestamptz not null default pg_catalog.now()
);
create index ydoc_rejected_doc on crdt.ydoc_rejected (doc, writer, id);

-- pg_dump skips the contents of an extension's tables unless they are marked,
-- and restores an extension's sequences at their start values unless they
-- are marked too: a restored database would then hand out document ids that
-- exist, and integration-order numbers (ins) lower than the restored rows'.
-- So the user-data tables and the four sequences are marked. Only possible
-- inside CREATE EXTENSION (pg_tle, or the control file): in a plain install
-- (psql -f) pg_extension_config_dump raises feature_not_supported, and the
-- objects are ordinary ones that pg_dump dumps with their data anyway.
do $$
begin
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_docs', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_replicas', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_items', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_blocks', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_pending', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_pending_deletes', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_deps', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_pending_ops', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_rejected', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_ins', '');
    perform pg_catalog.pg_extension_config_dump(pg_catalog.pg_get_serial_sequence('crdt.ydoc_docs', 'id')::regclass, '');
    perform pg_catalog.pg_extension_config_dump(pg_catalog.pg_get_serial_sequence('crdt.ydoc_pending_ops', 'id')::regclass, '');
    perform pg_catalog.pg_extension_config_dump(pg_catalog.pg_get_serial_sequence('crdt.ydoc_rejected', 'id')::regclass, '');
exception when feature_not_supported then
    null;
end;
$$;

-- ============================================================================
-- ydoc_: internals
-- ============================================================================

-- Tuning constants (functions so variants can replace them).
-- Longest run kept in one row: bounds the WAL of a split or an append.
create function crdt._ydoc_run_cap() returns integer
language sql immutable parallel safe return 256;
-- A block splits in two when it holds more rows than this.
create function crdt._ydoc_block_max() returns integer
language sql immutable parallel safe return 512;
-- Labels live in [-2^60, 2^60]; appends step by 2^30; a relabel spreads
-- rows at least 2^20 apart (20 more halvings at the same spot).
create function crdt._ydoc_label_bound() returns bigint
language sql immutable parallel safe return 1152921504606846976;
create function crdt._ydoc_label_step() returns bigint
language sql immutable parallel safe return 1073741824;
create function crdt._ydoc_label_gap() returns bigint
language sql immutable parallel safe return 1048576;
-- Longest replica key (id or id:device), in bytes.
create function crdt._ydoc_key_max() returns integer
language sql immutable parallel safe return 256;
-- Untrusted path: device keys per owner and document; runs per op (after
-- joining runs that continue each other); rows an op may scan (rule V5 and
-- the YjsMod scan, all runs together); rejected ops logged per writer.
create function crdt._ydoc_devices_max() returns integer
language sql immutable parallel safe return 16;
create function crdt._ydoc_runs_max() returns integer
language sql immutable parallel safe return 256;
create function crdt._ydoc_scan_max() returns bigint
language sql immutable parallel safe return 250000;
create function crdt._ydoc_rejected_max() returns integer
language sql immutable parallel safe return 100;
-- Quota of waiting untrusted ops (rule V7) per writer and document.
create function crdt._ydoc_pending_max_ops() returns integer
language sql immutable parallel safe return 100;
create function crdt._ydoc_pending_max_bytes() returns integer
language sql immutable parallel safe return 262144;

-- A label strictly between lo and hi (null: unbounded), or null if there is
-- none: the midpoint, or a step past the last (first) label.
create function crdt._ydoc_label(lo bigint, hi bigint)
returns bigint
language sql immutable parallel safe
return case
    when lo is null and hi is null then 0
    when hi is null then case when lo <= crdt._ydoc_label_bound() - crdt._ydoc_label_step() then lo + crdt._ydoc_label_step()
                              when crdt._ydoc_label_bound() - lo >= 2 then lo + (crdt._ydoc_label_bound() - lo) / 2 end
    when lo is null then case when hi >= crdt._ydoc_label_step() - crdt._ydoc_label_bound() then hi - crdt._ydoc_label_step()
                              when hi + crdt._ydoc_label_bound() >= 2 then hi - (hi + crdt._ydoc_label_bound()) / 2 end
    when hi - lo >= 2 then lo + (hi - lo) / 2
end;

-- Makes room between the rows labelled p_prev and p_next (adjacent rows; one
-- may be null for the start or the end). Takes k rows on each side, doubling
-- k until the labels around the window leave at least label_gap per row (or
-- the window is the whole document), and spreads the window evenly, with a
-- double gap between the two sides. Blocks follow their first row. Returns
-- the new labels of the two rows.
create function crdt._ydoc_relabel(p_doc bigint, p_prev bigint, p_next bigint,
    out new_prev bigint, out new_next bigint)
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    k integer := 8;
    la bigint[];
    ra bigint[];
    lo bigint;
    hi bigint;
    nl integer;
    nr integer;
    sp bigint;
    olds bigint[];
    news bigint[];
    bound bigint := crdt._ydoc_label_bound();
begin
    loop
        la := '{}';
        ra := '{}';
        if p_prev is not null then
            select coalesce(array_agg(x.ord order by x.ord), '{}') into la from (
                select i.ord from crdt.ydoc_items i where i.doc = p_doc and i.ord <= p_prev
                order by i.ord desc limit k) x;
        end if;
        if p_next is not null then
            select coalesce(array_agg(x.ord order by x.ord), '{}') into ra from (
                select i.ord from crdt.ydoc_items i where i.doc = p_doc and i.ord >= p_next
                order by i.ord limit k) x;
        end if;
        nl := pg_catalog.cardinality(la);
        nr := pg_catalog.cardinality(ra);
        lo := -bound - 1;
        hi := bound + 1;
        if nl > 0 then
            select i.ord into lo from crdt.ydoc_items i where i.doc = p_doc and i.ord < la[1]
            order by i.ord desc limit 1;
            lo := coalesce(lo, -bound - 1);
        elsif p_prev is not null then
            raise exception 'crdt._ydoc_relabel: no row labelled %', p_prev using errcode = 'XX000';
        end if;
        if nr > 0 then
            select i.ord into hi from crdt.ydoc_items i where i.doc = p_doc and i.ord > ra[nr]
            order by i.ord limit 1;
            hi := coalesce(hi, bound + 1);
        end if;
        sp := (hi - lo) / (nl + nr + 2);
        exit when sp >= crdt._ydoc_label_gap() or (lo = -bound - 1 and hi = bound + 1);
        k := k * 2;
    end loop;
    if sp < 2 then
        raise exception 'crdt._ydoc_relabel: document % has too many rows', p_doc using errcode = '54000';
    end if;
    olds := la || ra;
    select array_agg(case when g.n <= nl then lo + g.n * sp else lo + (g.n + 1) * sp end order by g.n)
    into news from generate_series(1, nl + nr) g(n);
    update crdt.ydoc_items i set ord = m.new
    from unnest(olds, news) m(old, new)
    where i.doc = p_doc and i.ord = m.old;
    -- (doc, lo) is a primary key, checked row by row: move the blocks out of
    -- the label range first (labels are within +-2^60), then onto their labels.
    update crdt.ydoc_blocks b set lo = b.lo - 4611686018427387904
    from unnest(olds) m(old)
    where b.doc = p_doc and b.lo = m.old;
    update crdt.ydoc_blocks b set lo = m.new
    from unnest(olds, news) m(old, new)
    where b.doc = p_doc and b.lo = m.old - 4611686018427387904;
    new_prev := case when nl > 0 then news[nl] end;
    new_next := case when nr > 0 then news[nl + 1] end;
end;
$$;

-- A label for a new row between the rows labelled lo and hi; relabels when
-- needed. o_lo and o_hi return the (possibly new) labels of the neighbours.
create function crdt._ydoc_new_label(p_doc bigint, p_lo bigint, p_hi bigint,
    out label bigint, out o_lo bigint, out o_hi bigint)
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
begin
    o_lo := p_lo;
    o_hi := p_hi;
    label := crdt._ydoc_label(p_lo, p_hi);
    if label is null then
        select r.new_prev, r.new_next into o_lo, o_hi from crdt._ydoc_relabel(p_doc, p_lo, p_hi) r;
        label := crdt._ydoc_label(o_lo, o_hi);
    end if;
end;
$$;

-- Highest integrated seq of a replica in a document (0 for none). Integrated
-- ids have no gaps (an insert waits for seq-1), so this is the version vector
-- entry, and (replica, s) is integrated iff s <= clock.
create function crdt._ydoc_clock(p_doc bigint, p_replica integer)
returns integer
language sql stable parallel safe
return coalesce((select i.seq + i.len - 1 from crdt.ydoc_items i
                 where i.doc = p_doc and i.replica = p_replica
                 order by i.seq desc limit 1), 0);

-- Replica name <-> interned integer (per document).
create function crdt._ydoc_rid(p_doc bigint, p_name text)
returns integer
language sql stable parallel safe
return (select r.id from crdt.ydoc_replicas r where r.doc = p_doc and r.name = p_name);

create function crdt._ydoc_rname(p_doc bigint, p_id integer)
returns text
language sql stable parallel safe
return (select r.name from crdt.ydoc_replicas r where r.doc = p_doc and r.id = p_id);

-- Interns a name (lock held: ids are assigned as max + 1).
create function crdt._ydoc_rid_make(p_doc bigint, p_name text)
returns integer
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    r integer := crdt._ydoc_rid(p_doc, p_name);
begin
    if r is null then
        insert into crdt.ydoc_replicas (doc, id, name)
        values (p_doc, coalesce((select max(x.id) from crdt.ydoc_replicas x where x.doc = p_doc), 0) + 1, p_name)
        returning id into r;
    end if;
    return r;
end;
$$;

-- The clock of a replica given by name (0 if it has never been seen).
create function crdt._ydoc_clock_name(p_doc bigint, p_name text)
returns integer
language sql stable parallel safe
return crdt._ydoc_clock(p_doc, crdt._ydoc_rid(p_doc, p_name));

-- Adds to the counters of the block that holds label p_ord; splits it when full.
create function crdt._ydoc_blk(p_doc bigint, p_ord bigint, p_dvis integer, p_dn integer)
returns void
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    b record;
    hi bigint;
    mid bigint;
    c integer;
    v integer;
begin
    update crdt.ydoc_blocks k set vis = k.vis + p_dvis, n = k.n + p_dn
    where k.doc = p_doc
      and k.lo = (select x.lo from crdt.ydoc_blocks x where x.doc = p_doc and x.lo <= p_ord order by x.lo desc limit 1)
    returning k.lo, k.n into b;
    if b.n <= crdt._ydoc_block_max() then
        return;
    end if;
    -- Split at the middle row.
    select x.lo into hi from crdt.ydoc_blocks x where x.doc = p_doc and x.lo > b.lo order by x.lo limit 1;
    hi := coalesce(hi, 9223372036854775807);
    select i.ord into mid from crdt.ydoc_items i
    where i.doc = p_doc and i.ord >= b.lo and i.ord < hi order by i.ord offset b.n / 2 limit 1;
    select count(*), coalesce(sum(i.len) filter (where i.del_gen is null), 0) into c, v
    from crdt.ydoc_items i where i.doc = p_doc and i.ord >= mid and i.ord < hi;
    update crdt.ydoc_blocks k set vis = k.vis - v, n = k.n - c where k.doc = p_doc and k.lo = b.lo;
    insert into crdt.ydoc_blocks (doc, lo, vis, n) values (p_doc, mid, v, c);
end;
$$;

-- Splits the row that holds char (p_r, p_at) so that it starts a row. The
-- left part keeps its label; returns the label of the right part. The right
-- part's first char has originLeft = its predecessor in the run and the
-- run's originRight, exactly as if the run had been sent as two. A relabel
-- may change other rows' labels: callers re-read labels after a split.
create function crdt._ydoc_split(p_doc bigint, p_r integer, p_at integer)
returns bigint
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    r record;
    k integer;
    nxt bigint;
    nl record;
begin
    select * into r from crdt.ydoc_items i
    where i.doc = p_doc and i.replica = p_r and i.seq <= p_at order by i.seq desc limit 1;
    k := p_at - r.seq;
    if k <= 0 or k >= r.len then
        raise exception 'crdt._ydoc_split: % is not inside the run', p_at using errcode = 'XX000';
    end if;
    select i.ord into nxt from crdt.ydoc_items i
    where i.doc = p_doc and i.ord > r.ord order by i.ord limit 1;
    select * into nl from crdt._ydoc_new_label(p_doc, r.ord, nxt);
    update crdt.ydoc_items i set len = k, content = pg_catalog.left(r.content, k)
    where i.doc = p_doc and i.replica = p_r and i.seq = r.seq;
    insert into crdt.ydoc_items (doc, ord, ins, seq, ol_seq, or_seq, replica, ol_replica, or_replica, del_gen, len, content)
    values (p_doc, nl.label, r.ins, p_at, p_at - 1, r.or_seq, r.replica, r.replica, r.or_replica, r.del_gen,
            r.len - k, pg_catalog.substr(r.content, k + 1));
    perform crdt._ydoc_blk(p_doc, nl.label, 0, 1);
    return nl.label;
end;
$$;

-- Position of char (replica, seq) in the order: (row label, offset in the row).
create function crdt._ydoc_pos(p_doc bigint, p_replica integer, p_seq integer, out ord bigint, out off integer)
language sql stable
begin atomic
    select i.ord, p_seq - i.seq from crdt.ydoc_items i
    where i.doc = p_doc and i.replica = p_replica and i.seq <= p_seq
    order by i.seq desc limit 1;
end;

-- Integrates one run whose origins and predecessor (replica, s-1) are
-- integrated and whose ids are new. YjsMod (research/text.md), on rows: after
-- splitting so that originLeft ends a row and originRight starts one, every
-- candidate destination is a row boundary, and only the first char of a row
-- can change the scan state (the others have originLeft = their predecessor,
-- which is > left). Returns the visible chars added. Replicas are interned
-- integers; p_rname is the inserting replica's name, for the tie-break.
-- p_vadv (untrusted path only): the op's version vector advanced to this
-- run, keyed by interned id, for rules V4 and V5.
create function crdt._ydoc_integrate(
    p_doc bigint, p_gen bigint, p_r integer, p_rname text, p_s integer,
    p_olr integer, p_ols integer, p_orr integer, p_ors integer, p_text text,
    p_vadv jsonb default null)
returns integer
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    x record;
    o record;
    cur refcursor;
    l_ord bigint;
    l_off integer := -1;
    r_ord bigint;
    prev_ord bigint;
    dest_prev bigint;
    dest_next bigint;
    scanning boolean := false;
    broke boolean := false;
    cl integer;
    cr integer;
    y_ord bigint;
    y_off integer;
    n integer := pg_catalog.length(p_text);
    cap integer := crdt._ydoc_run_cap();
    nl record;
    ci integer;
    part text;
    dp0 jsonb;
    dp1 jsonb;
    budget bigint;
    n5 bigint;
    cov5 boolean;
begin
    -- Split so that originLeft ends a row and originRight starts one; then
    -- read the labels (a split can relabel).
    if p_olr is not null then
        select i.seq, i.len into x from crdt.ydoc_items i
        where i.doc = p_doc and i.replica = p_olr and i.seq <= p_ols order by i.seq desc limit 1;
        if p_ols < x.seq + x.len - 1 then
            perform crdt._ydoc_split(p_doc, p_olr, p_ols + 1);
        end if;
    end if;
    if p_orr is not null then
        select i.seq into y_off from crdt.ydoc_items i
        where i.doc = p_doc and i.replica = p_orr and i.seq <= p_ors order by i.seq desc limit 1;
        if y_off < p_ors then
            perform crdt._ydoc_split(p_doc, p_orr, p_ors);
        end if;
        select i.ord into r_ord from crdt.ydoc_items i
        where i.doc = p_doc and i.replica = p_orr and i.seq = p_ors;
    end if;
    if p_olr is not null then
        select i.ord, i.seq, i.len, i.del_gen, i.or_replica, i.or_seq into x from crdt.ydoc_items i
        where i.doc = p_doc and i.replica = p_olr and i.seq <= p_ols order by i.seq desc limit 1;
        l_ord := x.ord;
        l_off := p_ols - x.seq;
        if r_ord is not null and r_ord <= l_ord then
            raise exception 'crdt.ydoc: V4: insert %:% has originRight before originLeft', p_rname, p_s
                using errcode = '22023';
        end if;
    end if;

    -- V5 (untrusted path): no row strictly between the origins may hold an id
    -- the op's version vector covers: the origins must have been adjacent for
    -- the writer. (A row is covered if its first id is.)
    -- The rows read count against the op's budget (crdt.ydoc_scan_left, set
    -- by _ydoc_vapply): an op whose origins are far apart, all uncovered,
    -- would otherwise read the document once per run.
    if p_vadv is not null then
        budget := pg_catalog.current_setting('crdt.ydoc_scan_left')::bigint;
        if r_ord is null then
            select count(*), coalesce(bool_or(z.cov), false) into n5, cov5 from (
                select i.seq <= coalesce((p_vadv ->> i.replica::text)::integer, 0) as cov
                from crdt.ydoc_items i
                where i.doc = p_doc and i.ord > coalesce(l_ord, -9223372036854775808)
                order by i.ord limit budget + 1) z;
        else
            select count(*), coalesce(bool_or(z.cov), false) into n5, cov5 from (
                select i.seq <= coalesce((p_vadv ->> i.replica::text)::integer, 0) as cov
                from crdt.ydoc_items i
                where i.doc = p_doc and i.ord > coalesce(l_ord, -9223372036854775808) and i.ord < r_ord
                order by i.ord limit budget + 1) z;
        end if;
        if cov5 then
            raise exception 'crdt.ydoc: V5: insert %:% has a character it has seen between its origins', p_rname, p_s
                using errcode = '22023';
        end if;
        -- the YjsMod scan below reads at most the same rows again
        budget := budget - 2 * n5;
        if budget < 0 then
            raise exception 'crdt.ydoc_apply: the op''s origins are too far apart (more than % rows to read)', crdt._ydoc_scan_max()
                using errcode = '54000';
        end if;
        perform pg_catalog.set_config('crdt.ydoc_scan_left', budget::text, true);
    end if;

    -- V3 bookkeeping (all paths): origins on other replicas may raise this
    -- replica's cumulative dependencies.
    if (p_olr is not null and p_olr <> p_r) or (p_orr is not null and p_orr <> p_r) then
        select d.dp into dp0 from crdt.ydoc_deps d
        where d.doc = p_doc and d.replica = p_r and d.seq < p_s order by d.seq desc limit 1;
        dp0 := coalesce(dp0, '{}');
        dp1 := dp0;
        if p_olr is not null and p_olr <> p_r and coalesce((dp1 ->> p_olr::text)::integer, 0) < p_ols then
            dp1 := dp1 || pg_catalog.jsonb_build_object(p_olr::text, p_ols);
        end if;
        if p_orr is not null and p_orr <> p_r and coalesce((dp1 ->> p_orr::text)::integer, 0) < p_ors then
            dp1 := dp1 || pg_catalog.jsonb_build_object(p_orr::text, p_ors);
        end if;
        if dp1 <> dp0 then
            insert into crdt.ydoc_deps (doc, replica, seq, dp) values (p_doc, p_r, p_s, dp1);
        end if;
    end if;

    -- The rows strictly between the origins. An explicit cursor, bounded on
    -- both sides when it can be, so the plan is an ordered index range scan
    -- that stops early (a FOR loop over a query got a sort of the document).
    -- This range (l_ord, r_ord) is also where a causal check of an op that
    -- carries its author's version vector belongs: a row here whose ids that
    -- vector covers means the origins were not adjacent for the author.
    prev_ord := l_ord;
    dest_prev := l_ord;
    dest_next := r_ord;
    if r_ord is null then
        open cur for
            select i.ord, i.replica, i.ol_replica, i.ol_seq, i.or_replica, i.or_seq
            from crdt.ydoc_items i
            where i.doc = p_doc and i.ord > coalesce(l_ord, -9223372036854775808)
            order by i.ord;
    else
        open cur for
            select i.ord, i.replica, i.ol_replica, i.ol_seq, i.or_replica, i.or_seq
            from crdt.ydoc_items i
            where i.doc = p_doc and i.ord > coalesce(l_ord, -9223372036854775808) and i.ord < r_ord
            order by i.ord;
    end if;
    loop
        fetch cur into o;
        exit when not found;
        if not scanning then
            dest_prev := prev_ord;
            dest_next := o.ord;
        end if;
        -- o's originLeft against ours
        if o.ol_replica is null then
            cl := case when p_olr is null then 0 else -1 end;
        elsif p_olr is null then
            cl := 1;
        elsif o.ol_replica = p_olr and o.ol_seq = p_ols then
            cl := 0;
        else
            select p.ord, p.off into y_ord, y_off from crdt._ydoc_pos(p_doc, o.ol_replica, o.ol_seq) p;
            cl := case when y_ord < l_ord then -1 when y_ord > l_ord then 1
                       else pg_catalog.sign(y_off - l_off)::integer end;
        end if;
        if cl < 0 then
            broke := true;
            exit;
        end if;
        if cl = 0 then
            -- o's originRight against ours
            if o.or_replica is null then
                cr := case when p_orr is null then 0 else 1 end;
            elsif p_orr is null then
                cr := -1;
            elsif o.or_replica = p_orr and o.or_seq = p_ors then
                cr := 0;
            else
                select p.ord, p.off into y_ord, y_off from crdt._ydoc_pos(p_doc, o.or_replica, o.or_seq) p;
                cr := case when y_ord < r_ord then -1 when y_ord > r_ord then 1
                           else pg_catalog.sign(y_off)::integer end;
            end if;
            if cr < 0 then
                scanning := true;
            elsif cr = 0 then
                -- names, collate "C" (never the interned integers)
                if p_rname collate "C" < crdt._ydoc_rname(p_doc, o.replica) collate "C" then
                    broke := true;
                    exit;
                end if;
                scanning := false;
            else
                scanning := false;
            end if;
        end if;
        prev_ord := o.ord;
    end loop;
    close cur;
    if not broke and not scanning then
        dest_prev := prev_ord;
        dest_next := r_ord;
    end if;

    -- Typing on: append to the run of the predecessor when it ends just
    -- before us, has our originRight, is visible, and has room.
    if p_olr is not null and p_olr = p_r and p_ols = p_s - 1 and dest_prev = l_ord then
        if x.del_gen is null and x.or_replica is not distinct from p_orr
           and x.or_seq is not distinct from p_ors and x.len + n <= cap then
            update crdt.ydoc_items i set len = i.len + n, content = i.content || p_text
            where i.doc = p_doc and i.replica = p_r and i.seq = x.seq;
            perform crdt._ydoc_blk(p_doc, l_ord, n, 0);
            return n;
        end if;
    end if;

    ci := 0;
    while ci < n loop
        part := pg_catalog.substr(p_text, ci + 1, cap);
        select * into nl from crdt._ydoc_new_label(p_doc, dest_prev, dest_next);
        dest_next := nl.o_hi;
        insert into crdt.ydoc_items (doc, ord, seq, ol_seq, or_seq, replica, ol_replica, or_replica, del_gen, len, content)
        values (p_doc, nl.label, p_s + ci,
                case when ci = 0 then p_ols else p_s + ci - 1 end, p_ors,
                p_r, case when ci = 0 then p_olr else p_r end, p_orr,
                null, pg_catalog.length(part), part);
        perform crdt._ydoc_blk(p_doc, nl.label, pg_catalog.length(part), 1);
        dest_prev := nl.label;
        ci := ci + cap;
    end loop;
    return n;
end;
$$;

-- Tombstones ids (replica, s .. s+n-1). Ids not integrated yet are kept in
-- ydoc_pending_deletes. Already deleted chars keep their first del_gen.
-- Returns the visible chars removed. Rows are addressed by id, not by label,
-- because a split can relabel. p_r is the interned replica (null if never
-- seen); p_rname its name, needed only to buffer (looked up if null).
create function crdt._ydoc_delete_range(p_doc bigint, p_gen bigint, p_r integer, p_rname text, p_s integer, p_n integer)
returns integer
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    c integer := crdt._ydoc_clock(p_doc, p_r);
    e integer := p_s + p_n - 1;
    first_seq integer;
    x record;
    a integer;
    b integer;
    k bigint;
    removed integer := 0;
begin
    if e > c then
        insert into crdt.ydoc_pending_deletes as pd (doc, replica, seq, len)
        values (p_doc, coalesce(p_rname, crdt._ydoc_rname(p_doc, p_r)), greatest(p_s, c + 1), e - greatest(p_s, c + 1) + 1)
        on conflict (doc, replica, seq) do update set len = greatest(pd.len, excluded.len);
        e := c;
    end if;
    if e < p_s then
        return 0;
    end if;
    select i.seq into first_seq from crdt.ydoc_items i
    where i.doc = p_doc and i.replica = p_r and i.seq <= p_s order by i.seq desc limit 1;
    for x in
        select i.seq, i.len from crdt.ydoc_items i
        where i.doc = p_doc and i.replica = p_r and i.seq >= coalesce(first_seq, p_s) and i.seq <= e
          and i.del_gen is null
        order by i.seq
    loop
        a := greatest(p_s, x.seq);
        b := least(e, x.seq + x.len - 1);
        continue when a > b;
        if a > x.seq then
            perform crdt._ydoc_split(p_doc, p_r, a);
        end if;
        if b < x.seq + x.len - 1 then
            perform crdt._ydoc_split(p_doc, p_r, b + 1);
        end if;
        update crdt.ydoc_items i set del_gen = p_gen
        where i.doc = p_doc and i.replica = p_r and i.seq = a
        returning i.ord into k;
        perform crdt._ydoc_blk(p_doc, k, -(b - a + 1), 0);
        removed := removed + b - a + 1;
    end loop;
    return removed;
end;
$$;

-- Integrates a ready run, then the pending deletes it satisfies. Returns the
-- change in visible length.
create function crdt._ydoc_settle(
    p_doc bigint, p_gen bigint, p_rname text, p_r integer, p_s integer,
    p_olr integer, p_ols integer, p_orr integer, p_ors integer, p_text text,
    p_vadv jsonb default null)
returns integer
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    added integer;
    e integer := p_s + pg_catalog.length(p_text) - 1;
    pd record;
begin
    added := crdt._ydoc_integrate(p_doc, p_gen, p_r, p_rname, p_s, p_olr, p_ols, p_orr, p_ors, p_text, p_vadv);
    for pd in
        delete from crdt.ydoc_pending_deletes x
        where x.doc = p_doc and x.replica = p_rname and x.seq <= e
        returning x.seq, x.len
    loop
        added := added - crdt._ydoc_delete_range(p_doc, p_gen, p_r, p_rname, pd.seq, pd.len);
    end loop;
    return added;
end;
$$;

-- Is the run (p_r, p_s, origins, p_text) what is stored for those ids? Its
-- first char's origins, every later char's (originLeft = predecessor, the
-- run's originRight), and the text. A re-sent op passes; an op that reuses
-- ids with other content or other origins (equivocation) does not.
create function crdt._ydoc_same(p_doc bigint, p_r integer, p_s integer,
    p_olr integer, p_ols integer, p_orr integer, p_ors integer, p_text text)
returns boolean
language plpgsql stable
set search_path = pg_catalog, pg_temp
as $$
declare
    x record;
    k integer := pg_catalog.length(p_text);
    stored text;
begin
    select i.seq, i.ol_replica, i.ol_seq, i.or_replica, i.or_seq into x from crdt.ydoc_items i
    where i.doc = p_doc and i.replica = p_r and i.seq <= p_s order by i.seq desc limit 1;
    if not found then
        return false;
    end if;
    if x.seq = p_s then
        if x.ol_replica is distinct from p_olr or x.ol_seq is distinct from p_ols then
            return false;
        end if;
    elsif p_olr is distinct from p_r or p_ols is distinct from p_s - 1 then
        return false;
    end if;
    if x.or_replica is distinct from p_orr or x.or_seq is distinct from p_ors then
        return false;
    end if;
    if exists (select 1 from crdt.ydoc_items i
               where i.doc = p_doc and i.replica = p_r and i.seq > p_s and i.seq < p_s + k
                 and (i.ol_replica is distinct from p_r or i.ol_seq is distinct from i.seq - 1
                      or i.or_replica is distinct from p_orr or i.or_seq is distinct from p_ors)) then
        return false;
    end if;
    select string_agg(pg_catalog.substr(i.content, greatest(p_s - i.seq, 0) + 1,
                                        least(i.seq + i.len, p_s + k) - greatest(i.seq, p_s)), '' order by i.seq)
    into stored
    from crdt.ydoc_items i
    where i.doc = p_doc and i.replica = p_r and i.seq < p_s + k and i.seq + i.len > p_s;
    return stored is not distinct from p_text;
end;
$$;

-- Integrates a run if it is ready: trims ids already integrated, then checks
-- that (replica, seq-1) and both origins are integrated. Returns the change in
-- visible length, or null when the run is not ready (the caller buffers it).
-- On success, o_s is the first new seq (after trimming), or null if the run
-- was a duplicate.
create function crdt._ydoc_try(
    p_doc bigint, p_gen bigint, p_r text, p_s integer,
    p_olr text, p_ols integer, p_orr text, p_ors integer, p_text text,
    out added integer, out o_s integer)
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    c integer := crdt._ydoc_clock_name(p_doc, p_r);
    n integer := pg_catalog.length(p_text);
    rid integer;
begin
    if p_s <= c then
        -- ids already here: the overlap must be what is stored (first arrival
        -- wins; a different run under the same ids is refused, not dropped)
        if not crdt._ydoc_same(p_doc, crdt._ydoc_rid(p_doc, p_r), p_s, crdt._ydoc_rid(p_doc, p_olr), p_ols,
                               crdt._ydoc_rid(p_doc, p_orr), p_ors, pg_catalog.left(p_text, least(n, c - p_s + 1))) then
            raise exception 'crdt.ydoc: insert %:% reuses ids with other content or origins', p_r, p_s
                using errcode = '22023', hint = 'Two different runs under one id (equivocation): one writer per replica id.';
        end if;
    end if;
    if p_s + n - 1 <= c then
        added := 0;
        return;
    end if;
    if p_s <= c then
        p_text := pg_catalog.substr(p_text, c - p_s + 2);
        p_olr := p_r;
        p_ols := c;
        p_s := c + 1;
    end if;
    if p_s > c + 1
       or (p_olr is not null and p_olr <> p_r and crdt._ydoc_clock_name(p_doc, p_olr) < p_ols)
       or (p_orr is not null and crdt._ydoc_clock_name(p_doc, p_orr) < p_ors) then
        return;
    end if;
    rid := crdt._ydoc_rid_make(p_doc, p_r);
    added := crdt._ydoc_settle(p_doc, p_gen, p_r, rid, p_s, crdt._ydoc_rid(p_doc, p_olr), p_ols,
                               crdt._ydoc_rid(p_doc, p_orr), p_ors, p_text);
    o_s := p_s;
end;
$$;

-- After ids (replica, s .. e) were integrated: integrate every buffered run
-- that became ready, transitively. An explicit stack, not recursion.
create function crdt._ydoc_drain(p_doc bigint, p_gen bigint, p_r text, p_s integer, p_e integer)
returns integer
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    st_r text[] := array[p_r];
    st_s integer[] := array[p_s];
    st_e integer[] := array[p_e];
    top integer;
    cr text;
    cs integer;
    ce integer;
    c record;
    t record;
    total integer := 0;
begin
    while pg_catalog.cardinality(st_r) > 0 loop
        top := pg_catalog.cardinality(st_r);
        cr := st_r[top]; cs := st_s[top]; ce := st_e[top];
        st_r := st_r[1:top - 1]; st_s := st_s[1:top - 1]; st_e := st_e[1:top - 1];
        for c in
            select p.* from crdt.ydoc_pending p
            where p.doc = p_doc
              and ((p.replica = cr and p.seq <= ce + 1)
                   or (p.ol_replica = cr and p.ol_seq between cs and ce)
                   or (p.or_replica = cr and p.or_seq between cs and ce))
            order by p.replica, p.seq
        loop
            select * into t from crdt._ydoc_try(p_doc, p_gen, c.replica, c.seq, c.ol_replica, c.ol_seq,
                                                c.or_replica, c.or_seq, c.content);
            continue when t.added is null;
            delete from crdt.ydoc_pending p where p.doc = p_doc and p.replica = c.replica and p.seq = c.seq;
            total := total + t.added;
            if t.o_s is not null then
                st_r := st_r || c.replica;
                st_s := st_s || t.o_s;
                st_e := st_e || (c.seq + pg_catalog.length(c.content) - 1);
            end if;
        end loop;
    end loop;
    return total;
end;
$$;

-- Resolves the public id and locks the document row in one probe; returns
-- the internal id, gen and length. Every write starts here.
create function crdt._ydoc_lock(p_uid text, p_fn text, out id bigint, out gen bigint, out len integer)
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
begin
    select d.id, d.gen, d.len into id, gen, len from crdt.ydoc_docs d where d.uid = p_uid for no key update;
    if not found then
        raise exception 'crdt.%: document % does not exist', p_fn, pg_catalog.quote_literal(pg_catalog.left(p_uid, 256))
            using errcode = 'P0002', hint = 'Create documents with crdt.ydoc_create().';
    end if;
end;
$$;

-- The row holding the visible char at index p_pos (0-based): one running sum
-- over the blocks, one over the rows of the block that holds it. Both bounds
-- of the block go into the row query, so that whatever plan the planner
-- picks (a generic plan cannot see that the running sum stops early), it
-- reads one block, not the rest of the document.
create function crdt._ydoc_visible_at(p_doc bigint, p_pos integer,
    out ord bigint, out replica integer, out seq integer, out len integer, out off integer)
language plpgsql stable
set search_path = pg_catalog, pg_temp
as $$
declare
    blo bigint;
    bhi bigint;
    base integer;
begin
    select b.lo, b.hi, b.cum - b.vis into blo, bhi, base from (
        select k.lo, k.vis, sum(k.vis) over (order by k.lo rows unbounded preceding) as cum,
               lead(k.lo) over (order by k.lo) as hi
        from crdt.ydoc_blocks k where k.doc = p_doc
    ) b where b.cum > p_pos order by b.lo limit 1;
    if bhi is null then
        select z.ord, z.replica, z.seq, z.len, p_pos - (z.cum - z.len) into ord, replica, seq, len, off from (
            select i.ord, i.replica, i.seq, i.len, i.del_gen,
                   base + sum(case when i.del_gen is null then i.len else 0 end)
                          over (order by i.ord rows unbounded preceding) as cum
            from crdt.ydoc_items i where i.doc = p_doc and i.ord >= blo
        ) z where z.del_gen is null and z.cum > p_pos order by z.ord limit 1;
    else
        select z.ord, z.replica, z.seq, z.len, p_pos - (z.cum - z.len) into ord, replica, seq, len, off from (
            select i.ord, i.replica, i.seq, i.len, i.del_gen,
                   base + sum(case when i.del_gen is null then i.len else 0 end)
                          over (order by i.ord rows unbounded preceding) as cum
            from crdt.ydoc_items i where i.doc = p_doc and i.ord >= blo and i.ord < bhi
        ) z where z.del_gen is null and z.cum > p_pos order by z.ord limit 1;
    end if;
end;
$$;

create function crdt._ydoc_id(r text, s integer)
returns jsonb
language sql immutable parallel safe
return case when r is null then 'null'::jsonb else pg_catalog.jsonb_build_array(r, s) end;

-- Local insert at visible position p_pos (lock held). The reference
-- convention: originLeft is the visible char at p_pos-1, originRight the next
-- item in the sequence, tombstones included.
create function crdt._ydoc_insert_at(p_doc bigint, p_gen bigint, p_pos integer, p_text text, p_r text,
    out op jsonb, out added integer)
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v record;
    olr integer;
    ols integer;
    orr integer;
    ors integer;
    s integer;
    rid integer := crdt._ydoc_rid_make(p_doc, p_r);
begin
    if p_pos = 0 then
        select i.replica, i.seq into orr, ors from crdt.ydoc_items i
        where i.doc = p_doc order by i.ord limit 1;
    else
        select * into v from crdt._ydoc_visible_at(p_doc, p_pos - 1);
        olr := v.replica;
        ols := v.seq + v.off;
        if v.off < v.len - 1 then
            orr := v.replica;
            ors := ols + 1;
        else
            select i.replica, i.seq into orr, ors from crdt.ydoc_items i
            where i.doc = p_doc and i.ord > v.ord order by i.ord limit 1;
        end if;
    end if;
    s := crdt._ydoc_clock(p_doc, rid) + 1;
    added := crdt._ydoc_settle(p_doc, p_gen, p_r, rid, s, olr, ols, orr, ors, p_text);
    if exists (select 1 from crdt.ydoc_pending p where p.doc = p_doc) then
        added := added + crdt._ydoc_drain(p_doc, p_gen, p_r, s, s + pg_catalog.length(p_text) - 1);
    end if;
    -- names for the op; the common case (typing on) is the writer's own id
    op := pg_catalog.jsonb_build_array(p_r, s,
        crdt._ydoc_id(case when olr = rid then p_r else crdt._ydoc_rname(p_doc, olr) end, ols),
        crdt._ydoc_id(case when orr = rid then p_r else crdt._ydoc_rname(p_doc, orr) end, ors), p_text);
end;
$$;

-- Local delete of visible positions [p_pos, p_pos + p_n) (lock held).
-- Returns the delete ops, adjacent ids coalesced.
create function crdt._ydoc_delete_at(p_doc bigint, p_gen bigint, p_pos integer, p_n integer)
returns jsonb
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    blo bigint;
    bhi bigint;
    base integer;
    cur refcursor;
    z record;
    a integer;
    b integer;
    rs integer[] := '{}';
    ss integer[] := '{}';
    ns integer[] := '{}';
    m integer := 0;
    ops jsonb := '[]';
begin
    -- the block that holds the first char, and the end of the block that
    -- holds the last one (null: the last block)
    select q.lo, q.cum - q.vis into blo, base from (
        select k.lo, k.vis, sum(k.vis) over (order by k.lo rows unbounded preceding) as cum
        from crdt.ydoc_blocks k where k.doc = p_doc
    ) q where q.cum > p_pos order by q.lo limit 1;
    select q.hi into bhi from (
        select k.lo, sum(k.vis) over (order by k.lo rows unbounded preceding) as cum,
               lead(k.lo) over (order by k.lo) as hi
        from crdt.ydoc_blocks k where k.doc = p_doc
    ) q where q.cum >= p_pos + p_n order by q.lo limit 1;
    if bhi is null then
        open cur for
            select y.replica, y.seq, y.len, y.cum from (
                select i.ord, i.replica, i.seq, i.len, i.del_gen,
                       base + sum(case when i.del_gen is null then i.len else 0 end)
                              over (order by i.ord rows unbounded preceding) as cum
                from crdt.ydoc_items i where i.doc = p_doc and i.ord >= blo
            ) y where y.del_gen is null and y.cum > p_pos order by y.ord;
    else
        open cur for
            select y.replica, y.seq, y.len, y.cum from (
                select i.ord, i.replica, i.seq, i.len, i.del_gen,
                       base + sum(case when i.del_gen is null then i.len else 0 end)
                              over (order by i.ord rows unbounded preceding) as cum
                from crdt.ydoc_items i where i.doc = p_doc and i.ord >= blo and i.ord < bhi
            ) y where y.del_gen is null and y.cum > p_pos order by y.ord;
    end if;
    loop
        fetch cur into z;
        exit when not found;
        a := greatest(p_pos, z.cum - z.len);
        exit when a >= p_pos + p_n;
        b := least(p_pos + p_n, z.cum);
        if m > 0 and rs[m] = z.replica and ss[m] + ns[m] = z.seq + (a - (z.cum - z.len)) then
            ns[m] := ns[m] + (b - a);
        else
            m := m + 1;
            rs[m] := z.replica;
            ss[m] := z.seq + (a - (z.cum - z.len));
            ns[m] := b - a;
        end if;
    end loop;
    close cur;
    for j in 1 .. m loop
        perform crdt._ydoc_delete_range(p_doc, p_gen, rs[j], null, ss[j], ns[j]);
        ops := ops || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_array(crdt._ydoc_rname(p_doc, rs[j]), ss[j], ns[j]));
    end loop;
    return ops;
end;
$$;

-- Common prefix and suffix of two texts, in code points. A binary search on
-- the UTF-8 bytes (bytea comparisons are memcmp; left() on text walks the
-- characters, which made the diff of a 100k-char text cost 9 ms), then the
-- byte boundaries are moved back to character starts and counted.
create function crdt._ydoc_diff(a text, b text, out p integer, out q integer)
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    x bytea := pg_catalog.convert_to(a, 'UTF8');
    y bytea := pg_catalog.convert_to(b, 'UTF8');
    lx integer := pg_catalog.length(x);
    ly integer := pg_catalog.length(y);
    lo integer;
    hi integer;
    mid integer;
    pb integer;
    qb integer;
begin
    lo := 0;
    hi := least(lx, ly);
    while lo < hi loop
        mid := (lo + hi + 1) / 2;
        if pg_catalog.substr(x, 1, mid) = pg_catalog.substr(y, 1, mid) then lo := mid; else hi := mid - 1; end if;
    end loop;
    pb := lo;
    -- back to a character start: the byte after the prefix must not be a
    -- continuation byte (10xxxxxx) in either text
    while pb > 0 and ((pb < lx and pg_catalog.get_byte(x, pb) & 192 = 128)
                      or (pb < ly and pg_catalog.get_byte(y, pb) & 192 = 128)) loop
        pb := pb - 1;
    end loop;
    lo := 0;
    hi := least(lx, ly) - pb;
    while lo < hi loop
        mid := (lo + hi + 1) / 2;
        if pg_catalog.substr(x, lx - mid + 1) = pg_catalog.substr(y, ly - mid + 1) then lo := mid; else hi := mid - 1; end if;
    end loop;
    qb := lo;
    -- forward to a character start: the first byte of the suffix must not be
    -- a continuation byte
    while qb > 0 and pg_catalog.get_byte(x, lx - qb) & 192 = 128 loop
        qb := qb - 1;
    end loop;
    p := pg_catalog.length(pg_catalog.convert_from(pg_catalog.substr(x, 1, pb), 'UTF8'));
    q := pg_catalog.length(pg_catalog.convert_from(pg_catalog.substr(x, lx - qb + 1), 'UTF8'));
end;
$$;

-- A whole number in [lo, hi], written as digits (1.0 and 1e0 are refused:
-- they would pass a numeric check and then fail a cast with 22P02).
create function crdt._ydoc_is_int(j jsonb, lo bigint, hi bigint)
returns boolean
language sql immutable parallel safe
return case when pg_catalog.jsonb_typeof(j) is distinct from 'number' then false
            when j::text !~ '^-?[0-9]{1,19}$' then false
            else j::numeric between lo and hi end;

-- A replica key: a non-empty id without ":", optionally ":<device>", at most
-- _ydoc_key_max() bytes.
create function crdt._ydoc_is_key(k text)
returns boolean
language sql immutable parallel safe
return k ~ '^[^:]+(:.+)?$' and pg_catalog.octet_length(k) <= crdt._ydoc_key_max();

-- An id [replica key, seq] on the wire.
create function crdt._ydoc_is_id(j jsonb)
returns boolean
language sql immutable parallel safe
return case when pg_catalog.jsonb_typeof(j) is distinct from 'array' then false
            when pg_catalog.jsonb_array_length(j) <> 2 then false
            when pg_catalog.jsonb_typeof(j -> 0) <> 'string' then false
            when not crdt._ydoc_is_key(j ->> 0) then false
            else crdt._ydoc_is_int(j -> 1, 1, 2147483647) end;

create function crdt._ydoc_is_insert(v jsonb)
returns boolean
language sql immutable parallel safe
return case when pg_catalog.jsonb_typeof(v) is distinct from 'array' then false
            when pg_catalog.jsonb_array_length(v) <> 5 then false
            when pg_catalog.jsonb_typeof(v -> 0) <> 'string' then false
            when not crdt._ydoc_is_key(v ->> 0) then false
            when not crdt._ydoc_is_int(v -> 1, 1, 2147483647) then false
            when pg_catalog.jsonb_typeof(v -> 2) <> 'null' and not crdt._ydoc_is_id(v -> 2) then false
            when pg_catalog.jsonb_typeof(v -> 3) <> 'null' and not crdt._ydoc_is_id(v -> 3) then false
            when pg_catalog.jsonb_typeof(v -> 4) <> 'string' then false
            when pg_catalog.length(v ->> 4) = 0 then false
            when (v ->> 1)::bigint + pg_catalog.length(v ->> 4) - 1 > 2147483647 then false
            -- an origin of the run's own replica must come before the run
            when pg_catalog.jsonb_typeof(v -> 2) = 'array' and (v -> 2 ->> 0) = (v ->> 0)
                 and (v -> 2 ->> 1)::integer >= (v ->> 1)::integer then false
            when pg_catalog.jsonb_typeof(v -> 3) = 'array' and (v -> 3 ->> 0) = (v ->> 0)
                 and (v -> 3 ->> 1)::integer >= (v ->> 1)::integer then false
            -- originLeft = originRight is not refused here: as in the reference,
            -- the untrusted path decides it later (V4), so every server
            -- decides it the same way (an op that names unseen ids waits)
            else true end;

create function crdt._ydoc_is_delete(v jsonb)
returns boolean
language sql immutable parallel safe
return case when pg_catalog.jsonb_typeof(v) is distinct from 'array' then false
            when pg_catalog.jsonb_array_length(v) <> 3 then false
            when pg_catalog.jsonb_typeof(v -> 0) <> 'string' then false
            when not crdt._ydoc_is_key(v ->> 0) then false
            when not crdt._ydoc_is_int(v -> 1, 1, 2147483647) then false
            when not crdt._ydoc_is_int(v -> 2, 1, 2147483647) then false
            else (v ->> 1)::bigint + (v ->> 2)::bigint - 1 <= 2147483647 end;

-- The shape of ops (both paths): {"i": [...], "d": [...], "v": {...}}, each
-- insert and delete well formed. 22023 otherwise.
create function crdt._ydoc_check_ops(p_ops jsonb, p_fn text)
returns void
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    bad integer;
begin
    if pg_catalog.jsonb_typeof(p_ops) <> 'object' or (p_ops - '{i,d,v}'::text[]) <> '{}'::jsonb
       or coalesce(pg_catalog.jsonb_typeof(p_ops -> 'i'), 'array') <> 'array'
       or coalesce(pg_catalog.jsonb_typeof(p_ops -> 'd'), 'array') <> 'array'
       or coalesce(pg_catalog.jsonb_typeof(p_ops -> 'v'), 'object') <> 'object' then
        raise exception 'crdt.%: ops must be an object {"v": {...}, "i": [...], "d": [...]}', p_fn
            using errcode = '22023';
    end if;
    select e.n into bad from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'i', '[]')) with ordinality e(v, n)
    where not crdt._ydoc_is_insert(e.v) limit 1;
    if found then
        raise exception 'crdt.%: insert % is malformed', p_fn, bad - 1
            using errcode = '22023',
                  hint = 'An insert is [replica, seq, originLeft, originRight, text]: seq >= 1, origins null or [replica, seq], text not empty.';
    end if;
    select e.n into bad from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'd', '[]')) with ordinality e(v, n)
    where not crdt._ydoc_is_delete(e.v) limit 1;
    if found then
        raise exception 'crdt.%: delete % is malformed', p_fn, bad - 1
            using errcode = '22023', hint = 'A delete is [replica, seq, len] with seq >= 1 and len >= 1.';
    end if;
end;
$$;

-- The trusted path (ydoc_merge): integrates inserts in array order
-- (buffering those that are not ready), then deletes. "v" is ignored.
create function crdt._ydoc_apply(p_uid text, p_ops jsonb, p_fn text)
returns void
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    p_doc bigint;
    lk record;
    g bigint;
    has_pending boolean;
    v jsonb;
    t record;
    delta integer := 0;
    r text;
    s integer;
    txt text;
begin
    if p_ops is null then
        return;
    end if;
    perform crdt._ydoc_check_ops(p_ops, p_fn);

    select * into lk from crdt._ydoc_lock(p_uid, p_fn);
    p_doc := lk.id;
    g := lk.gen + 1;
    has_pending := exists (select 1 from crdt.ydoc_pending p where p.doc = p_doc);

    for v in select e.v from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'i', '[]')) e(v) loop
        r := v ->> 0;
        s := (v ->> 1)::integer;
        txt := v ->> 4;
        select * into t from crdt._ydoc_try(p_doc, g, r, s, v -> 2 ->> 0, (v -> 2 ->> 1)::integer,
                                            v -> 3 ->> 0, (v -> 3 ->> 1)::integer, txt);
        if t.added is null then
            insert into crdt.ydoc_pending as p (doc, replica, seq, ol_replica, ol_seq, or_replica, or_seq, content)
            values (p_doc, r, s, v -> 2 ->> 0, (v -> 2 ->> 1)::integer, v -> 3 ->> 0, (v -> 3 ->> 1)::integer, txt)
            on conflict (doc, replica, seq) do update set content = excluded.content
                where pg_catalog.length(excluded.content) > pg_catalog.length(p.content);
            has_pending := true;
        else
            delta := delta + t.added;
            if has_pending and t.o_s is not null then
                delta := delta + crdt._ydoc_drain(p_doc, g, r, t.o_s, s + pg_catalog.length(txt) - 1);
            end if;
        end if;
    end loop;

    for v in select e.v from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'd', '[]')) e(v) loop
        delta := delta - crdt._ydoc_delete_range(p_doc, g, crdt._ydoc_rid(p_doc, v ->> 0), v ->> 0,
                                                  (v ->> 1)::integer, (v ->> 2)::integer);
    end loop;
    delta := delta + crdt._ydoc_drain_ops(p_doc, g);

    update crdt.ydoc_docs d set gen = g, len = d.len + delta where d.id = p_doc;
end;
$$;

-- ---------------------------------------------------------------------------
-- The untrusted path: rules V0-V7 of experiments/text-ref/README.md (research/text.md).
-- ---------------------------------------------------------------------------

-- Static rules, on the op alone: V0 ("v" present, entry keys, counts >= 1),
-- V1 (both origins covered by v advanced run by run), V2 (a run starts at
-- v[replica] + 1), V6 (delete targets covered by the advanced v). 22023.
create function crdt._ydoc_vstatic(p_ops jsonb)
returns void
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    vadv jsonb := p_ops -> 'v';
    x jsonb;
begin
    if pg_catalog.jsonb_typeof(vadv) is distinct from 'object' then
        raise exception 'crdt.ydoc_apply: V0: ops carry no version vector "v"'
            using errcode = '22023', hint = '"v" is the writer''s version vector before the op: {replica: highest seq integrated}.';
    end if;
    if exists (select 1 from pg_catalog.jsonb_each(vadv) e
               where not crdt._ydoc_is_key(e.key) or not crdt._ydoc_is_int(e.value, 1, 2147483647)) then
        raise exception 'crdt.ydoc_apply: V0: "v" must map replica keys (at most 256 bytes) to whole numbers >= 1' using errcode = '22023';
    end if;
    for x in select e.v from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'i', '[]')) e(v) loop
        if (pg_catalog.jsonb_typeof(x -> 2) = 'array' and coalesce((vadv ->> (x -> 2 ->> 0))::integer, 0) < (x -> 2 ->> 1)::integer)
           or (pg_catalog.jsonb_typeof(x -> 3) = 'array' and coalesce((vadv ->> (x -> 3 ->> 0))::integer, 0) < (x -> 3 ->> 1)::integer) then
            raise exception 'crdt.ydoc_apply: V1: insert %:% names an origin that "v" does not cover', x ->> 0, x ->> 1
                using errcode = '22023';
        end if;
        if coalesce((vadv ->> (x ->> 0))::integer, 0) <> (x ->> 1)::integer - 1 then
            raise exception 'crdt.ydoc_apply: V2: insert %:% does not follow "v" (expected seq %)', x ->> 0, x ->> 1,
                coalesce((vadv ->> (x ->> 0))::integer, 0) + 1
                using errcode = '22023';
        end if;
        vadv := vadv || pg_catalog.jsonb_build_object(x ->> 0, (x ->> 1)::integer + pg_catalog.length(x ->> 4) - 1);
    end loop;
    for x in select e.v from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'd', '[]')) e(v) loop
        if coalesce((vadv ->> (x ->> 0))::integer, 0) < (x ->> 1)::integer + (x ->> 2)::integer - 1 then
            raise exception 'crdt.ydoc_apply: V6: delete %:%+% targets ids that "v" does not cover', x ->> 0, x ->> 1, x ->> 2
                using errcode = '22023';
        end if;
    end loop;
end;
$$;

-- Joins consecutive runs of an op that continue each other (same replica,
-- consecutive seqs, originLeft the previous run's last char, the same
-- originRight): one run, as if typed at once. Checking and integrating the
-- joined run is equivalent and costs one scan instead of one per char.
create function crdt._ydoc_coalesce(p_ins jsonb)
returns jsonb
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    out jsonb := '[]';
    cur jsonb;
    x jsonb;
begin
    for x in select e.v from jsonb_array_elements(coalesce(p_ins, '[]')) e(v) loop
        if cur is not null and x ->> 0 = cur ->> 0
           and (x ->> 1)::bigint = (cur ->> 1)::bigint + length(cur ->> 4)
           and x -> 2 = jsonb_build_array(cur -> 0, (cur ->> 1)::bigint + length(cur ->> 4) - 1)
           and x -> 3 = cur -> 3 then
            cur := jsonb_set(cur, '{4}', to_jsonb((cur ->> 4) || (x ->> 4)));
        else
            if cur is not null then
                out := out || jsonb_build_array(cur);
            end if;
            cur := x;
        end if;
    end loop;
    if cur is not null then
        out := out || jsonb_build_array(cur);
    end if;
    return out;
end;
$$;

-- V7: does the document have every id that v names?
create function crdt._ydoc_covers(p_doc bigint, p_v jsonb)
returns boolean
language sql stable
return not exists (select 1 from pg_catalog.jsonb_each_text(p_v) e
                   where crdt._ydoc_clock_name(p_doc, e.key) < e.value::integer);

-- The dynamic rules, once the document covers v (lock held): V3 (v is
-- causally closed), then per run V4 and V5 (in _ydoc_integrate), then the
-- deletes. A run whose ids are all present must be exactly what is stored
-- (a re-send); a partial overlap is refused. Raises 22023 on any rule, which
-- undoes the whole op (the caller's statement, or the subtransaction in
-- _ydoc_drain_ops). Returns the change in visible length.
create function crdt._ydoc_vapply(p_doc bigint, p_gen bigint, p_ops jsonb)
returns integer
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    vid jsonb;
    e record;
    dp jsonb;
    x jsonb;
    rid integer;
    s integer;
    n integer;
    txt text;
    have integer;
    olr integer;
    orr integer;
    delta integer := 0;
    ins jsonb := crdt._ydoc_coalesce(p_ops -> 'i');
    owner text;
begin
    if pg_catalog.jsonb_array_length(ins) > crdt._ydoc_runs_max() then
        raise exception 'crdt.ydoc_apply: an op may hold at most % runs (after joining runs that continue each other)',
            crdt._ydoc_runs_max() using errcode = '54000';
    end if;
    -- rows the op may scan, all runs together (rule V5 and the YjsMod scan)
    perform pg_catalog.set_config('crdt.ydoc_scan_left', crdt._ydoc_scan_max()::text, true);
    select coalesce(pg_catalog.jsonb_object_agg(crdt._ydoc_rid(p_doc, y.key)::text, y.value), '{}') into vid
    from pg_catalog.jsonb_each(p_ops -> 'v') y;
    -- V3: the dependencies of the last item of each replica in v are in v
    for e in select y.key::integer as rid, (y.value #>> '{}')::integer as n from pg_catalog.jsonb_each(vid) y loop
        select d.dp into dp from crdt.ydoc_deps d
        where d.doc = p_doc and d.replica = e.rid and d.seq <= e.n order by d.seq desc limit 1;
        if dp is not null and exists (select 1 from pg_catalog.jsonb_each_text(dp) z
                                      where z.value::integer > coalesce((vid ->> z.key)::integer, 0)) then
            raise exception 'crdt.ydoc_apply: V3: "v" is not causally closed' using errcode = '22023';
        end if;
        dp := null;
    end loop;
    for x in select y.v from pg_catalog.jsonb_array_elements(ins) y(v) loop
        txt := x ->> 4;
        n := pg_catalog.length(txt);
        s := (x ->> 1)::integer;
        rid := crdt._ydoc_rid(p_doc, x ->> 0);
        if rid is null and pg_catalog.strpos(x ->> 0, ':') > 0 then
            -- a new device key: at most _ydoc_devices_max() per owner
            owner := pg_catalog.split_part(x ->> 0, ':', 1);
            if (select count(*) from crdt.ydoc_replicas k
                where k.doc = p_doc and pg_catalog.left(k.name, pg_catalog.length(owner) + 1) = owner || ':')
               >= crdt._ydoc_devices_max() then
                raise exception 'crdt.ydoc_apply: replica % has too many device keys in document %',
                    pg_catalog.quote_literal(owner), p_doc using errcode = '54000';
            end if;
        end if;
        rid := crdt._ydoc_rid_make(p_doc, x ->> 0);
        olr := crdt._ydoc_rid(p_doc, x -> 2 ->> 0);
        orr := crdt._ydoc_rid(p_doc, x -> 3 ->> 0);
        have := crdt._ydoc_clock(p_doc, rid);
        if have >= s then
            if have < s + n - 1 then
                raise exception 'crdt.ydoc_apply: insert %:% overlaps ids already here', x ->> 0, s using errcode = '22023';
            end if;
            if not crdt._ydoc_same(p_doc, rid, s, olr, (x -> 2 ->> 1)::integer, orr, (x -> 3 ->> 1)::integer, txt) then
                raise exception 'crdt.ydoc_apply: insert %:% reuses ids with other content or origins', x ->> 0, s
                    using errcode = '22023', hint = 'Two different runs under one id (equivocation).';
            end if;
        else
            delta := delta + crdt._ydoc_settle(p_doc, p_gen, x ->> 0, rid, s, olr, (x -> 2 ->> 1)::integer,
                                               orr, (x -> 3 ->> 1)::integer, txt, vid);
            -- runs buffered on the trusted path may wait on these ids
            if exists (select 1 from crdt.ydoc_pending p where p.doc = p_doc) then
                delta := delta + crdt._ydoc_drain(p_doc, p_gen, x ->> 0, s, s + n - 1);
            end if;
        end if;
        vid := vid || pg_catalog.jsonb_build_object(rid::text, s + n - 1);
    end loop;
    for x in select y.v from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'd', '[]')) y(v) loop
        delta := delta - crdt._ydoc_delete_range(p_doc, p_gen, crdt._ydoc_rid(p_doc, x ->> 0), x ->> 0,
                                                  (x ->> 1)::integer, (x ->> 2)::integer);
    end loop;
    return delta;
end;
$$;

-- Decides waiting untrusted ops whose v the document now covers, until no
-- more progress. Each in a subtransaction: a rejected op is undone and
-- logged in ydoc_rejected, and does not fail the caller. Lock held.
create function crdt._ydoc_drain_ops(p_doc bigint, p_gen bigint)
returns integer
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    w record;
    progress boolean := true;
    delta integer := 0;
begin
    if not exists (select 1 from crdt.ydoc_pending_ops w0 where w0.doc = p_doc) then
        return 0;
    end if;
    while progress loop
        progress := false;
        for w in select * from crdt.ydoc_pending_ops w1 where w1.doc = p_doc order by w1.id loop
            continue when not crdt._ydoc_covers(p_doc, w.op -> 'v');
            begin
                delta := delta + crdt._ydoc_vapply(p_doc, p_gen, w.op);
            exception when others then
                -- any error, not only a rule (22023): a parked op must never
                -- fail the write that made it decidable
                insert into crdt.ydoc_rejected (doc, writer, op, reason)
                values (p_doc, w.writer, w.op, sqlstate || ' ' || sqlerrm);
                delete from crdt.ydoc_rejected x
                where x.doc = p_doc and x.writer = w.writer
                  and x.id <= (select y.id from crdt.ydoc_rejected y where y.doc = p_doc and y.writer = w.writer
                               order by y.id desc offset crdt._ydoc_rejected_max() limit 1);
            end;
            delete from crdt.ydoc_pending_ops w2 where w2.doc = p_doc and w2.id = w.id;
            progress := true;
        end loop;
    end loop;
    return delta;
end;
$$;

create function crdt._ydoc_check_replica(p_replica text, p_fn text)
returns void
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
begin
    if p_replica is null then
        raise exception 'crdt.%: replica must not be null', p_fn using errcode = '22004';
    end if;
    if not crdt._ydoc_is_key(p_replica) then
        raise exception 'crdt.%: % is not a replica key', p_fn, pg_catalog.quote_literal(p_replica)
            using errcode = '22023',
                  hint = 'A replica key is a non-empty id without ":", optionally followed by ":<device>", at most 256 bytes.';
    end if;
end;
$$;

-- ============================================================================
-- ydoc_: API
-- ============================================================================

-- Creates a document and returns its id: the id given, or a random UUID (as
-- text). The id is the client's to choose (a UUID, a UUIDv7, a ULID, a room
-- name, an app key), non-empty, at most 256 bytes, no control characters
-- (22023). An id that exists raises 23505 and never returns the existing
-- document: creating is not idempotent, so that nobody can take over a
-- document by creating its predictable id first. The default is evaluated in
-- the caller's context, hence the qualified name.
create function crdt.ydoc_create(id text default pg_catalog.gen_random_uuid()::text)
returns text
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    d bigint;
begin
    if not crdt._ydoc_uid_valid(id) then
        raise exception 'crdt.ydoc_create: % is not a document id', pg_catalog.quote_literal(pg_catalog.left(id, 256))
            using errcode = '22023',
                  hint = 'A document id is non-empty text of at most 256 bytes without control characters. Omit it for a random UUID.';
    end if;
    -- on conflict waits for a concurrent creator of the same id: if that one
    -- commits there is no row to return and we raise, if it rolls back we insert.
    insert into crdt.ydoc_docs as t (uid) values (id) on conflict (uid) do nothing returning t.id into d;
    if not found then
        raise exception 'crdt.ydoc_create: document % already exists', pg_catalog.quote_literal(id)
            using errcode = '23505',
                  hint = 'Documents are not created idempotently. If you chose this id, check in your app that you own the document.';
    end if;
    insert into crdt.ydoc_blocks (doc, lo) values (d, -9223372036854775808);
    return id;
end;
$$;

-- The plain text of the document with internal id p_doc.
create function crdt._ydoc_value(p_doc bigint)
returns text
language sql stable parallel safe
return coalesce((select string_agg(i.content, '' order by i.ord) from crdt.ydoc_items i
                 where i.doc = p_doc and i.del_gen is null), '');

-- The plain text, or null for a document that does not exist.
create function crdt.ydoc_value(doc text)
returns text
language sql stable parallel safe
return (select crdt._ydoc_value(d.id) from crdt.ydoc_docs d where d.uid = ydoc_value.doc);

-- Visible length in code points, or null for a document that does not exist.
create function crdt.ydoc_length(doc text)
returns integer
language sql stable parallel safe
return (select d.len from crdt.ydoc_docs d where d.uid = ydoc_length.doc);

-- The version vector {replica: highest seq}. A loose index scan, backwards
-- on the primary key (doc, replica, seq): each probe returns the last row of
-- the next replica, so one probe per replica. (A recursive CTE with a clock
-- lookup per replica took 134 us for three replicas; this takes 23.) Local
-- edits call it for the "v" of their op.
create function crdt._ydoc_version(p_doc bigint)
returns jsonb
language plpgsql stable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    r integer := 2147483647;
    rr integer;
    mx integer;
    ids integer[] := '{}';
    mxs integer[] := '{}';
begin
    loop
        select i.replica, i.seq + i.len - 1 into rr, mx from crdt.ydoc_items i
        where i.doc = p_doc and i.replica < r order by i.replica desc, i.seq desc limit 1;
        exit when not found;
        ids := ids || rr;
        mxs := mxs || mx;
        r := rr;
    end loop;
    return (select coalesce(pg_catalog.jsonb_object_agg(n.name, m.mx), '{}'::jsonb)
            from unnest(ids, mxs) m(id, mx) join crdt.ydoc_replicas n on n.doc = p_doc and n.id = m.id);
end;
$$;

-- The version vector of a document ('{}' for an empty one). P0002 for a
-- document that does not exist, like the writers: '{}' would say "nothing
-- yet", and a peer would then ask for the whole history of a typo.
create function crdt.ydoc_version(doc text)
returns jsonb
language plpgsql stable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint;
begin
    select d.id into v_doc from crdt.ydoc_docs d where d.uid = ydoc_version.doc;
    if not found then
        raise exception 'crdt.ydoc_version: document % does not exist', pg_catalog.quote_literal(pg_catalog.left(ydoc_version.doc, 256))
            using errcode = 'P0002', hint = 'Create documents with crdt.ydoc_create().';
    end if;
    return crdt._ydoc_version(v_doc);
end;
$$;

-- The version an editor starts from, for ydoc_set's base argument: the
-- document, the write counter and the version vector. Read it in the same statement as the text:
--   select crdt.ydoc_value(d), crdt.ydoc_base(d)
create function crdt.ydoc_base(doc text)
returns jsonb
language sql stable parallel safe
return (select jsonb_build_object('d', d.uid, 'g', d.gen, 'v', crdt._ydoc_version(d.id))
        from crdt.ydoc_docs d where d.uid = ydoc_base.doc);

create function crdt.ydoc_insert(doc text, pos integer, chars text, replica text)
returns jsonb
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint;
    lk record;
    g bigint;
    res record;
    vv jsonb;
begin
    perform crdt._ydoc_check_replica(replica, 'ydoc_insert');
    if pos is null or chars is null then
        raise exception 'crdt.ydoc_insert: pos and chars must not be null' using errcode = '22004';
    end if;
    select * into lk from crdt._ydoc_lock(ydoc_insert.doc, 'ydoc_insert');
    v_doc := lk.id;
    if pos < 0 or pos > lk.len then
        raise exception 'crdt.ydoc_insert: position % is outside the document (length %)', pos, lk.len
            using errcode = '22023';
    end if;
    vv := crdt._ydoc_version(v_doc);
    if chars = '' then
        return jsonb_build_object('v', vv, 'i', '[]'::jsonb, 'd', '[]'::jsonb);
    end if;
    g := lk.gen + 1;
    select * into res from crdt._ydoc_insert_at(v_doc, g, pos, chars, replica);
    update crdt.ydoc_docs d set gen = g, len = d.len + res.added + crdt._ydoc_drain_ops(v_doc, g) where d.id = v_doc;
    return jsonb_build_object('v', vv, 'i', jsonb_build_array(res.op), 'd', '[]'::jsonb);
end;
$$;

-- `replica` is accepted for symmetry with ydoc_insert; a delete op does not
-- name its writer.
create function crdt.ydoc_delete(doc text, pos integer, len integer, replica text)
returns jsonb
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint;
    lk record;
    g bigint;
    ops jsonb;
    vv jsonb;
begin
    perform crdt._ydoc_check_replica(replica, 'ydoc_delete');
    if pos is null or len is null then
        raise exception 'crdt.ydoc_delete: pos and len must not be null' using errcode = '22004';
    end if;
    select * into lk from crdt._ydoc_lock(ydoc_delete.doc, 'ydoc_delete');
    v_doc := lk.id;
    if pos < 0 or len < 0 or pos::bigint + len > lk.len then
        raise exception 'crdt.ydoc_delete: range % + % is outside the document (length %)', pos, len, lk.len
            using errcode = '22023';
    end if;
    vv := crdt._ydoc_version(v_doc);
    if len = 0 then
        return jsonb_build_object('v', vv, 'i', '[]'::jsonb, 'd', '[]'::jsonb);
    end if;
    g := lk.gen + 1;
    ops := crdt._ydoc_delete_at(v_doc, g, pos, len);
    update crdt.ydoc_docs d set gen = g, len = d.len - ydoc_delete.len + crdt._ydoc_drain_ops(v_doc, g) where d.id = v_doc;
    return jsonb_build_object('v', vv, 'i', '[]'::jsonb, 'd', ops);
end;
$$;

-- Replace the text with new_text: common prefix and suffix, then one delete
-- and one insert in the middle. Without base, the diff is against the current
-- text: a save from an editor who started before another editor's save
-- reverts that save in the region between its first and last change. With
-- base (crdt.ydoc_base, read with the text), the diff is against the text at
-- base, and the insert's origins are taken in that version, so concurrent
-- saves to different places both survive (the CRDT merges them).
create function crdt.ydoc_set(doc text, new_text text, replica text, base jsonb default null)
returns jsonb
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint;
    lk record;
    g bigint;
    cur text;
    df record;
    dlen integer;
    ins text;
    dops jsonb := '[]';
    iops jsonb := '[]';
    res record;
    bg bigint;
    bv jsonb;
    z record;
    a integer;
    b integer;
    rs integer[] := '{}';
    ss integer[] := '{}';
    ns integer[] := '{}';
    m integer := 0;
    removed integer := 0;
    olr integer;
    ols integer;
    orr integer;
    ors integer;
    rid integer;
    s integer;
    added integer;
    vv jsonb;
    z_ext jsonb;
begin
    perform crdt._ydoc_check_replica(replica, 'ydoc_set');
    if new_text is null then
        raise exception 'crdt.ydoc_set: new_text must not be null' using errcode = '22004';
    end if;
    select * into lk from crdt._ydoc_lock(ydoc_set.doc, 'ydoc_set');
    v_doc := lk.id;
    g := lk.gen + 1;

    if base is null then
        vv := crdt._ydoc_version(v_doc);
        cur := crdt._ydoc_value(v_doc);
        if cur = new_text then
            return jsonb_build_object('v', vv, 'i', '[]'::jsonb, 'd', '[]'::jsonb);
        end if;
        df := crdt._ydoc_diff(cur, new_text);
        dlen := length(cur) - df.p - df.q;
        ins := substr(new_text, df.p + 1, length(new_text) - df.p - df.q);
        if dlen > 0 then
            dops := crdt._ydoc_delete_at(v_doc, g, df.p, dlen);
        end if;
        if ins <> '' then
            select * into res from crdt._ydoc_insert_at(v_doc, g, df.p, ins, replica);
            iops := jsonb_build_array(res.op);
            added := res.added;
        end if;
        update crdt.ydoc_docs d set gen = g, len = d.len - dlen + coalesce(added, 0) + crdt._ydoc_drain_ops(v_doc, g)
        where d.id = v_doc;
        return jsonb_build_object('v', vv, 'i', iops, 'd', dops);
    end if;

    -- Three-way: diff against the text at base.
    if jsonb_typeof(base) is distinct from 'object' or not crdt._ydoc_is_int(base -> 'g', 0, 9223372036854775807)
       or jsonb_typeof(base -> 'd') is distinct from 'string' or (base ->> 'd') <> ydoc_set.doc
       or jsonb_typeof(base -> 'v') is distinct from 'object'
       or exists (select 1 from jsonb_each(base -> 'v') e
                  where not crdt._ydoc_is_int(e.value, 0, 2147483647)
                     or (e.value)::integer > crdt._ydoc_clock_name(v_doc, e.key))
       or (base ->> 'g')::bigint > lk.gen then
        raise exception 'crdt.ydoc_set: base is not a version of document %', pg_catalog.quote_literal(ydoc_set.doc)
            using errcode = '22023', hint = 'Pass the value of crdt.ydoc_base(doc), read together with the text.';
    end if;
    bg := (base ->> 'g')::bigint;
    -- The version the save is relative to: the base, plus the writer's own
    -- items (an earlier save from the same base must not be inserted again),
    -- plus their causal closure (what those items depend on). It is causally
    -- closed and covers the writer's clock, so it is also the op's "v": peers
    -- accept the op (V2, V3), and its origins are adjacent in it (V5).
    vv := base -> 'v';
    if crdt._ydoc_clock_name(v_doc, replica) > 0 then
        vv := vv || jsonb_build_object(replica, crdt._ydoc_clock_name(v_doc, replica));
    end if;
    loop
        select coalesce(jsonb_object_agg(q.name, q.m), '{}') into z_ext from (
            select n.name, max(dd.value::integer) as m
            from jsonb_each_text(vv) e
            cross join lateral (select d.dp from crdt.ydoc_deps d
                                where d.doc = v_doc and d.replica = crdt._ydoc_rid(v_doc, e.key) and d.seq <= e.value::integer
                                order by d.seq desc limit 1) x
            cross join lateral jsonb_each_text(x.dp) dd
            join crdt.ydoc_replicas n on n.doc = v_doc and n.id = dd.key::integer
            group by n.name
        ) q where q.m > coalesce((vv ->> q.name)::integer, 0);
        exit when z_ext = '{}'::jsonb;
        vv := vv || z_ext;
    end loop;
    -- the version keyed by interned id
    bv := (select coalesce(jsonb_object_agg(r.id::text, e.value), '{}') from jsonb_each(vv) e
           join crdt.ydoc_replicas r on r.doc = v_doc and r.name = e.key);
    -- Compaction merged tombstones stamped at or before the horizon, so the
    -- text at an older base cannot be rebuilt. Refuse rather than guess: a
    -- wrong base text widens the diff and reverts or duplicates text.
    if bg < (select d.horizon from crdt.ydoc_docs d where d.id = v_doc) then
        raise exception 'crdt.ydoc_set: base % of document % is older than its last compaction', bg, pg_catalog.quote_literal(ydoc_set.doc)
            using errcode = '22023',
                  hint = 'Read the text and crdt.ydoc_base(doc) again, or call ydoc_set without base (a two-way diff against the current text).';
    end if;
    cur := coalesce((
        select string_agg(left(i.content, least(i.len, (bv ->> i.replica::text)::integer - i.seq + 1)), '' order by i.ord)
        from crdt.ydoc_items i
        where i.doc = v_doc and (bv ->> i.replica::text)::integer >= i.seq and (i.del_gen is null or i.del_gen > bg)), '');
    if cur = new_text then
        return jsonb_build_object('v', vv, 'i', '[]'::jsonb, 'd', '[]'::jsonb);
    end if;
    df := crdt._ydoc_diff(cur, new_text);
    dlen := length(cur) - df.p - df.q;
    ins := substr(new_text, df.p + 1, length(new_text) - df.p - df.q);

    -- The chars visible at base, with a running count: deletes for
    -- [p, p + dlen), and the visible char at p - 1 for the insert.
    for z in
        select y.ord, y.replica, y.seq, y.bl, y.cum from (
            select i.ord, i.replica, i.seq, x.bl,
                   sum(x.bl) over (order by i.ord rows unbounded preceding) as cum
            from crdt.ydoc_items i
            cross join lateral (select least(i.len, (bv ->> i.replica::text)::integer - i.seq + 1) as bl) x
            where i.doc = v_doc and (bv ->> i.replica::text)::integer >= i.seq and (i.del_gen is null or i.del_gen > bg)
        ) y where y.cum >= df.p order by y.ord
    loop
        if df.p > 0 and olr is null and z.cum >= df.p then
            -- visible char at p - 1
            olr := z.replica;
            ols := z.seq + (df.p - 1 - (z.cum - z.bl));
            if ols < z.seq + z.bl - 1 then
                orr := z.replica;
                ors := ols + 1;
            else
                select i.replica, i.seq into orr, ors from crdt.ydoc_items i
                where i.doc = v_doc and i.ord > z.ord and (bv ->> i.replica::text)::integer >= i.seq
                order by i.ord limit 1;
            end if;
        end if;
        a := greatest(df.p, z.cum - z.bl);
        exit when a >= df.p + dlen;
        b := least(df.p + dlen, z.cum);
        continue when b <= a;
        m := m + 1;
        rs[m] := z.replica;
        ss[m] := z.seq + (a - (z.cum - z.bl));
        ns[m] := b - a;
    end loop;
    if df.p = 0 then
        select i.replica, i.seq into orr, ors from crdt.ydoc_items i
        where i.doc = v_doc and (bv ->> i.replica::text)::integer >= i.seq order by i.ord limit 1;
    end if;

    for j in 1 .. m loop
        removed := removed + crdt._ydoc_delete_range(v_doc, g, rs[j], null, ss[j], ns[j]);
        dops := dops || jsonb_build_array(jsonb_build_array(crdt._ydoc_rname(v_doc, rs[j]), ss[j], ns[j]));
    end loop;
    if ins <> '' then
        rid := crdt._ydoc_rid_make(v_doc, replica);
        s := crdt._ydoc_clock(v_doc, rid) + 1;
        added := crdt._ydoc_settle(v_doc, g, replica, rid, s, olr, ols, orr, ors, ins);
        if exists (select 1 from crdt.ydoc_pending p where p.doc = v_doc) then
            added := added + crdt._ydoc_drain(v_doc, g, replica, s, s + length(ins) - 1);
        end if;
        iops := jsonb_build_array(jsonb_build_array(replica, s, crdt._ydoc_id(crdt._ydoc_rname(v_doc, olr), ols),
                                                    crdt._ydoc_id(crdt._ydoc_rname(v_doc, orr), ors), ins));
    end if;
    update crdt.ydoc_docs d set gen = g, len = d.len - removed + coalesce(added, 0) + crdt._ydoc_drain_ops(v_doc, g)
    where d.id = v_doc;
    return jsonb_build_object('v', vv, 'i', iops, 'd', dops);
end;
$$;

-- The write path for untrusted writers, like pn_apply_delta. Inserts must
-- carry the writer's own ids (`replica`, or <replica>:<device>); deletes may
-- target any character the writer has seen. The op must carry "v", its
-- writer's version vector before the op, and pass the causal rules V0-V7
-- (research/text.md, experiments/text-ref/README.md), which stop a writer from choosing
-- origins that make replicas diverge. The op is applied or rejected as a
-- whole: 22023 on any rule. An op whose v names ids this document does not
-- have yet waits (V7) and is decided by a later write; returns 'accepted'
-- or 'pending'. At most _ydoc_pending_max_ops() waiting ops (and
-- _ydoc_pending_max_bytes()) per writer and document: 54000 beyond.
create function crdt.ydoc_apply(doc text, ops jsonb, replica text default crdt.current_replica_id())
returns text
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint;
    r text;
    lk record;
    g bigint;
    delta integer;
    x jsonb;
    c integer;
    b bigint;
begin
    if replica is null then
        raise exception 'crdt.ydoc_apply: the writer has no replica id'
            using errcode = '42501',
                  hint = 'Pass the writer''s identity as the replica argument, or set it up for crdt.current_replica_id() (a JWT claim in request.jwt.claims, or the crdt.replica_id setting).';
    end if;
    if replica !~ '^[^:]+$' or octet_length(replica) > crdt._ydoc_key_max() then
        raise exception 'crdt.ydoc_apply: % is not a replica id', quote_literal(replica)
            using errcode = '22023',
                  hint = 'A replica id is non-empty and has no ":" (":" separates a replica id from a device suffix).';
    end if;
    if ops is null then
        return null;
    end if;
    perform crdt._ydoc_check_ops(ops, 'ydoc_apply');
    select e.v ->> 0 into r from jsonb_array_elements(coalesce(ops -> 'i', '[]')) e(v)
    where split_part(e.v ->> 0, ':', 1) <> replica limit 1;
    if found then
        raise exception 'crdt.ydoc_apply: replica % cannot insert characters of replica %',
            quote_literal(replica), quote_literal(r)
            using errcode = '42501',
                  hint = 'Inserts may only carry the writer''s own ids: its replica id, or <replica id>:<device>. Deletes may target any character.';
    end if;
    perform crdt._ydoc_vstatic(ops);
    if jsonb_array_length(crdt._ydoc_coalesce(ops -> 'i')) > crdt._ydoc_runs_max() then
        raise exception 'crdt.ydoc_apply: an op may hold at most % runs (after joining runs that continue each other)',
            crdt._ydoc_runs_max() using errcode = '54000';
    end if;

    select * into lk from crdt._ydoc_lock(ydoc_apply.doc, 'ydoc_apply');
    v_doc := lk.id;
    if not crdt._ydoc_covers(v_doc, ops -> 'v') then
        select count(*), coalesce(sum(w.bytes), 0) into c, b from crdt.ydoc_pending_ops w
        where w.doc = v_doc and w.writer = replica;
        if c + 1 > crdt._ydoc_pending_max_ops() or b + octet_length(ops::text) > crdt._ydoc_pending_max_bytes() then
            raise exception 'crdt.ydoc_apply: replica % has too many ops waiting in document %', quote_literal(replica), quote_literal(ydoc_apply.doc)
                using errcode = '54000',
                      hint = 'Ops wait while their "v" names ids this document does not have. Send the missing ops first.';
        end if;
        insert into crdt.ydoc_pending_ops (doc, writer, op, bytes) values (v_doc, replica, ops, octet_length(ops::text));
        return 'pending';
    end if;
    g := lk.gen + 1;
    delta := crdt._ydoc_vapply(v_doc, g, ops);
    delta := delta + crdt._ydoc_drain_ops(v_doc, g);
    update crdt.ydoc_docs d set gen = g, len = d.len + delta where d.id = v_doc;
    return 'accepted';
end;
$$;

-- The trusted write path: ops from any replica (another server's
-- ydoc_ops_since, a sync job, a replay). Shape checks only: "v" is ignored,
-- the causal rules are not applied, and runs whose origins are missing are
-- buffered. Not safe against a byzantine writer. Ids already present must
-- carry the same content and origins (first arrival wins; a different run
-- under the same ids raises 22023 instead of being dropped).
create function crdt.ydoc_merge(doc text, ops jsonb)
returns void
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
begin
    perform crdt._ydoc_apply(ydoc_merge.doc, ops, 'ydoc_merge');
end;
$$;

-- The ops a peer with version vector vv lacks: integrated inserts above vv,
-- in integration order (causal, so the peer applies them without buffering),
-- and every delete this document knows (deletes carry no clock; they are
-- idempotent).
create function crdt.ydoc_ops_since(doc text, vv jsonb default '{}')
returns jsonb
language plpgsql stable
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint;
    ins jsonb;
    dels jsonb;
begin
    select d.id into v_doc from crdt.ydoc_docs d where d.uid = ydoc_ops_since.doc;
    if not found then
        raise exception 'crdt.ydoc_ops_since: document % does not exist', pg_catalog.quote_literal(pg_catalog.left(ydoc_ops_since.doc, 256))
            using errcode = 'P0002', hint = 'Create documents with crdt.ydoc_create().';
    end if;
    vv := coalesce(vv, '{}');
    if jsonb_typeof(vv) <> 'object'
       or exists (select 1 from jsonb_each(vv) e where not crdt._ydoc_is_int(e.value, 0, 2147483647)) then
        raise exception 'crdt.ydoc_ops_since: vv must be an object {replica: seq} with whole numbers >= 0'
            using errcode = '22023';
    end if;
    -- Rows above vv (a row half above it is cut), in integration order, then
    -- consecutive rows that continue one run (split by deletes or the row
    -- cap) joined back into one insert.
    select coalesce(jsonb_agg(jsonb_build_array(g.replica, g.s, crdt._ydoc_id(g.olr, g.ols),
                                                crdt._ydoc_id(g.orr, g.ors), g.txt) order by g.grp), '[]')
    into ins
    from (
        select c.grp, (array_agg(c.replica order by c.ins, c.seq))[1] as replica,
               min(c.s) as s, (array_agg(c.olr order by c.ins, c.seq))[1] as olr,
               (array_agg(c.ols order by c.ins, c.seq))[1] as ols,
               (array_agg(c.orr order by c.ins, c.seq))[1] as orr,
               (array_agg(c.ors order by c.ins, c.seq))[1] as ors,
               string_agg(c.txt, '' order by c.ins, c.seq) as txt
        from (
            select b.*, sum(case when b.replica = b.p_replica and b.s = b.p_end and b.olr = b.replica and b.ols = b.s - 1
                                      and b.orr is not distinct from b.p_orr and b.ors is not distinct from b.p_ors
                                 then 0 else 1 end) over (order by b.ins, b.replica, b.seq) as grp
            from (
                select a.*, lag(a.replica) over w as p_replica, lag(a.s + length(a.txt)) over w as p_end,
                       lag(a.orr) over w as p_orr, lag(a.ors) over w as p_ors
                from (
                    select i.ins, r0.name as replica, i.seq,
                           greatest(i.seq, h.have + 1) as s,
                           case when i.seq > h.have then r1.name else r0.name end as olr,
                           case when i.seq > h.have then i.ol_seq else h.have end as ols,
                           r2.name as orr, i.or_seq as ors,
                           case when i.seq > h.have then i.content else substr(i.content, h.have - i.seq + 2) end as txt
                    from crdt.ydoc_items i
                    join crdt.ydoc_replicas r0 on r0.doc = v_doc and r0.id = i.replica
                    left join crdt.ydoc_replicas r1 on r1.doc = v_doc and r1.id = i.ol_replica
                    left join crdt.ydoc_replicas r2 on r2.doc = v_doc and r2.id = i.or_replica
                    cross join lateral (select coalesce((vv ->> r0.name)::integer, 0) as have) h
                    where i.doc = v_doc and i.seq + i.len - 1 > h.have
                ) a
                window w as (order by a.ins, a.replica, a.seq)
            ) b
        ) c
        group by c.grp
    ) g;

    select coalesce(jsonb_agg(jsonb_build_array(u.replica, u.s, u.n) order by u.replica, u.s), '[]')
    into dels
    from (
        select (select r.name from crdt.ydoc_replicas r where r.doc = v_doc and r.id = z.replica) as replica, min(z.seq) as s, sum(z.len)::integer as n
        from (select i.replica, i.seq, i.len,
                     i.seq - coalesce(sum(i.len) over (partition by i.replica order by i.seq
                                                       rows between unbounded preceding and 1 preceding), 0) as grp
              from crdt.ydoc_items i where i.doc = v_doc and i.del_gen is not null) z
        group by z.replica, z.grp
        union all
        select p.replica, p.seq, p.len from crdt.ydoc_pending_deletes p where p.doc = v_doc
    ) u;
    return jsonb_build_object('i', ins, 'd', dels);
end;
$$;

-- Maintenance: merges adjacent rows that continue one run (consecutive ids
-- of one replica, the right row's originLeft the left row's last char, the
-- same originRight) and have the same visibility: both visible, or both
-- deleted with equal stamps, or both deleted at or before `horizon` (default:
-- now). Backspacing leaves one tombstone row per char; this is what folds
-- them. A merged tombstone keeps the latest of the stamps, so the text at a
-- base is exact for bases at or after the horizon; ydoc_set refuses older
-- bases (22023). Rows do not merge across a block boundary, and a merged row
-- holds at most about twice the run cap. Returns the number of rows removed.
-- The text, the ids and ops_since's text are unchanged.
create function crdt.ydoc_compact(doc text, horizon bigint default null)
returns integer
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint;
    lk record;
    h bigint;
    removed integer;
    cap integer := crdt._ydoc_run_cap();
begin
    select * into lk from crdt._ydoc_lock(ydoc_compact.doc, 'ydoc_compact');
    v_doc := lk.id;
    h := coalesce(horizon, lk.gen);
    if h < 0 or h > lk.gen then
        raise exception 'crdt.ydoc_compact: horizon % is outside 0 .. % (the document''s write counter)', h, lk.gen
            using errcode = '22023';
    end if;
    update crdt.ydoc_docs d set horizon = greatest(d.horizon, h) where d.id = v_doc;

    with r as (
        select i.replica, i.seq, i.ord, i.len, i.del_gen, i.ins, i.content,
               i.ol_replica, i.ol_seq, i.or_replica, i.or_seq,
               lag(i.replica) over w as p_r, lag(i.seq + i.len) over w as p_end,
               lag(i.or_replica) over w as p_orr, lag(i.or_seq) over w as p_ors,
               lag(i.del_gen) over w as p_del,
               b.lo is not null as blk_lo
        from crdt.ydoc_items i
        left join crdt.ydoc_blocks b on b.doc = v_doc and b.lo = i.ord
        where i.doc = v_doc
        window w as (order by i.ord)
    ), g as (
        select r.*, sum(case when r.p_r = r.replica and r.p_end = r.seq
                                  and r.ol_replica = r.replica and r.ol_seq = r.seq - 1
                                  and r.or_replica is not distinct from r.p_orr and r.or_seq is not distinct from r.p_ors
                                  and not r.blk_lo
                                  and ((r.del_gen is null and r.p_del is null)
                                       or r.del_gen = r.p_del
                                       or (r.del_gen <= h and r.p_del <= h))
                             then 0 else 1 end) over (order by r.ord) as grp
        from r
    ), gs as (
        -- cut long groups so a merged row stays under about twice the cap
        select g.*, (sum(g.len) over (partition by g.grp order by g.ord) - g.len) / cap as sub
        from g
    ), a as (
        select (array_agg(gs.replica order by gs.ord))[1] as r, min(gs.seq) as s, sum(gs.len)::integer as len,
               string_agg(gs.content, '' order by gs.ord) as content, max(gs.del_gen) as del_gen, min(gs.ins) as ins,
               (array_agg(gs.seq order by gs.ord))[2:] as rest, min(gs.ord) as first_ord
        from gs group by gs.grp, gs.sub having count(*) > 1
    ), u as (
        update crdt.ydoc_items i set len = a.len, content = a.content, del_gen = a.del_gen, ins = a.ins
        from a where i.doc = v_doc and i.replica = a.r and i.seq = a.s
        returning 1
    ), dl as (
        delete from crdt.ydoc_items i
        using (select a.r, unnest(a.rest) as s from a) x
        where i.doc = v_doc and i.replica = x.r and i.seq = x.s
        returning 1
    ), bk as (
        update crdt.ydoc_blocks k set n = k.n - c.cnt
        from (select bl.lo, sum(pg_catalog.cardinality(a.rest))::integer as cnt
              from a cross join lateral (select x.lo from crdt.ydoc_blocks x where x.doc = v_doc and x.lo <= a.first_ord
                                         order by x.lo desc limit 1) bl
              group by bl.lo) c
        where k.doc = v_doc and k.lo = c.lo
        returning 1
    )
    select count(*) into removed from dl;
    return removed;
end;
$$;

-- Deletes the rows of the rejection log (ydoc_rejected) of a document, for one
-- writer or, with a null writer, for all; returns the number of rows deleted.
-- The log keeps the last _ydoc_rejected_max() per writer and document by
-- itself; this is for apps that read it and want to empty it. Takes the
-- document's lock, like a write, so it does not run alongside the call that
-- decides a waiting op. Nothing else of the document changes.
create function crdt.ydoc_rejected_purge(doc text, writer text default null)
returns integer
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint;
    removed integer;
begin
    if doc is null then
        raise exception 'crdt.ydoc_rejected_purge: doc must not be null' using errcode = '22004';
    end if;
    v_doc := (crdt._ydoc_lock(ydoc_rejected_purge.doc, 'ydoc_rejected_purge')).id;
    with dl as (
        delete from crdt.ydoc_rejected r
        where r.doc = v_doc and (ydoc_rejected_purge.writer is null or r.writer = ydoc_rejected_purge.writer)
        returning 1
    )
    select count(*) into removed from dl;
    return removed;
end;
$$;

create function crdt.ydoc_drop(doc text)
returns void
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint;
begin
    v_doc := (crdt._ydoc_lock(ydoc_drop.doc, 'ydoc_drop')).id;
    delete from crdt.ydoc_items i where i.doc = v_doc;
    delete from crdt.ydoc_blocks b where b.doc = v_doc;
    delete from crdt.ydoc_pending p where p.doc = v_doc;
    delete from crdt.ydoc_pending_deletes p where p.doc = v_doc;
    delete from crdt.ydoc_deps p where p.doc = v_doc;
    delete from crdt.ydoc_replicas p where p.doc = v_doc;
    delete from crdt.ydoc_pending_ops p where p.doc = v_doc;
    delete from crdt.ydoc_rejected p where p.doc = v_doc;
    delete from crdt.ydoc_docs d where d.id = v_doc;
end;
$$;

-- ============================================================================
-- Privileges
-- ============================================================================

-- A fresh install owns every object in this reserved schema. Strip the default
-- grants (and any grant to another role, such as the installer's default
-- privileges) from its functions, tables and sequences before exposing the
-- client API. Do not change defaults for the installer's other schemas.
revoke all on all functions in schema crdt from public;
revoke all on all tables in schema crdt from public;
revoke all on all sequences in schema crdt from public;
do $$
declare
    a record;
begin
    for a in
        select distinct 'function' as kind, p.oid::regprocedure::text as obj, x.grantee
        from pg_catalog.pg_proc p
        cross join lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) x
        where p.pronamespace = 'crdt'::regnamespace and x.grantee <> p.proowner
        union
        select distinct case c.relkind when 'S' then 'sequence' else 'table' end, c.oid::regclass::text, x.grantee
        from pg_catalog.pg_class c
        cross join lateral pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault(
            case c.relkind when 'S' then 's' else 'r' end::"char", c.relowner))) x
        where c.relnamespace = 'crdt'::regnamespace and c.relkind in ('r', 'S', 'p') and x.grantee <> c.relowner
    loop
        execute format('revoke all on %s %s from %s', a.kind, a.obj,
            case when a.grantee = 0 then 'public' else quote_ident(pg_catalog.pg_get_userbyid(a.grantee)) end);
    end loop;
end;
$$;
grant usage on schema crdt to public;

-- Granted to public: the whole PN-Counter API. Every function is pure or
-- reads only the caller's own settings; none needs privileges of its own.
-- Apps decide who may write which rows (row-level security, column
-- privileges, their own SECURITY DEFINER functions around pn_apply_delta,
-- granted to their own roles).
grant execute on function
    crdt.current_replica_id(),
    crdt.pn_is_valid(jsonb),
    crdt.pn_empty(),
    crdt.pn_increment(crdt.pn, text, bigint),
    crdt.pn_decrement(crdt.pn, text, bigint),
    crdt.pn_value(crdt.pn),
    crdt.pn_merge(crdt.pn, crdt.pn),
    crdt.pn_merge_agg(crdt.pn),
    crdt.pn_apply_delta(crdt.pn, crdt.pn, text)
to public;

-- Granted to public: the yseq_ API and its internals, which the API calls.
-- Every function is pure (yseq_new draws a random id); the state is a column
-- of the app's table, so the app's own privileges on that table and column
-- decide who may write it (yseq_apply wrapped in its own SECURITY DEFINER
-- function for untrusted writers).
do $$
declare
    f record;
begin
    for f in
        select p.oid::regprocedure::text as sig from pg_catalog.pg_proc p
        where p.pronamespace = 'crdt'::regnamespace and (p.proname like 'yseq\_%' or p.proname like '\_yseq\_%')
    loop
        execute format('grant execute on function %s to public', f.sig);
    end loop;
end;
$$;

-- Granted to public: the ydoc_ API and its internals, which the API calls
-- with the caller's privileges (SECURITY INVOKER). The gate is the tables:
-- no role but their owner has privileges on them, so a call by any other
-- role fails with 42501 until the app grants the tables and sequences to a
-- role it trusts, normally the owner of its SECURITY DEFINER wrappers
-- (docs/guides/collaborative-text.md):
--
--   grant select, insert, update, delete on crdt.ydoc_docs, crdt.ydoc_replicas,
--       crdt.ydoc_items, crdt.ydoc_blocks, crdt.ydoc_pending, crdt.ydoc_pending_deletes,
--       crdt.ydoc_deps, crdt.ydoc_pending_ops, crdt.ydoc_rejected to app_owner;
--   grant references on crdt.ydoc_docs to app_owner;  -- posts.body_doc references ydoc_docs (uid)
--   grant usage on all sequences in schema crdt to app_owner;
do $$
declare
    f record;
begin
    for f in
        select p.oid::regprocedure::text as sig from pg_catalog.pg_proc p
        where p.pronamespace = 'crdt'::regnamespace and (p.proname like 'ydoc\_%' or p.proname like '\_ydoc\_%')
    loop
        execute format('grant execute on function %s to public', f.sig);
    end loop;
end;
$$;
