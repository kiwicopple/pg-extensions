/*
 * pg_crdt experiment, shape A: yseq_, a YjsMod text sequence in a jsonb column.
 *
 * Contract: research/text.md (op wire format, integrate order, API).
 * Design, measurements and limits: experiments/text-column/NOTES.md.
 * Loads after pg_crdt--0.0.1.sql into the same `crdt` schema:
 *
 *   psql -f pg_crdt--0.0.1.sql -f experiments/text-column/impl.sql
 *
 * State (crdt.yseq, a jsonb domain):
 *
 *   {"t": "yseq", "v": 1,
 *    "r": ["alice", "bob"],   replica keys; runs refer to them by 1-based index
 *    "c": [12, 3],            characters integrated per replica (the version vector)
 *    "n": [40, 7],            per chunk: number of visible characters
 *    "s": ["...", "..."],     per chunk: the visible text
 *    "m": ["{...}", "{...}"], per chunk: the runs, an int[] literal, 7 ints per run
 *    "p": [],                 pending insert runs (wire format), origins not seen yet
 *    "x": []}                 pending deletes (wire format) of ids not seen yet
 *
 * A run is [rep, seq, len, olrep, olseq, orrep, orseq]: the characters
 * (r[rep], seq .. seq+|len|-1), visible when len > 0 and tombstones when
 * len < 0, with the origins of its first character (0, 0 for null). Character
 * k > 0 of a run has originLeft = (rep, seq+k-1) and the run's originRight.
 * Runs are in document order, chunk after chunk, and a chunk holds at most
 * crdt._yseq_cmax() (128) runs. Adjacent runs in a chunk are merged whenever
 * the result is a valid run (same replica, consecutive seqs, the second's
 * originLeft is the first's last character, same originRight, same
 * visibility).
 *
 * Trust: like pn_merge, yseq_merge and the internals accept any state; the
 * untrusted write path is yseq_apply, wrapped by the app in its own
 * SECURITY DEFINER function while writers have no UPDATE on the column.
 *
 * The text of tombstones is not stored (like Yjs's ContentDeleted): the
 * visible text is stored once, so yseq_value is a concatenation of the chunk
 * texts. yseq_ops_since sends U+FFFD for deleted characters, together with
 * the delete set that hides them.
 *
 * Positions and lengths count Unicode code points (length() on text).
 */

-- ============================================================================
-- yseq_: the domain
-- ============================================================================

-- Envelope only, like crdt.pn: an object with exactly these keys, t and v
-- fixed, and r, c, n, s, m, p, x arrays. Containment of an empty array checks
-- the type without walking the array. The chunks are checked by
-- crdt.yseq_is_valid.
create domain crdt.yseq as jsonb
    check (
        jsonb_typeof(value) = 'object'
        and value @> '{"t": "yseq", "v": 1, "r": [], "c": [], "n": [], "s": [], "m": [], "p": [], "x": []}'
        and (value - '{t,v,r,c,n,s,m,p,x}'::text[]) = '{}'::jsonb
    );

comment on domain crdt.yseq is
    'YjsMod text sequence state (experiment). See experiments/text-column/NOTES.md. Dropping the extension with CASCADE drops every column of this type.';

create function crdt.yseq_empty()
returns crdt.yseq
language sql immutable parallel safe
return '{"t": "yseq", "v": 1, "r": [], "c": [], "n": [], "s": [], "m": [], "p": [], "x": []}'::crdt.yseq;

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
return (select coalesce(sum(x::int), 0)::int from jsonb_array_elements_text(state -> 'n') x);

-- {replica: characters integrated}. Pending runs are not counted.
create function crdt.yseq_version(state crdt.yseq)
returns jsonb
language sql immutable parallel safe strict
return (select coalesce(jsonb_object_agg(k, c), '{}'::jsonb)
        from rows from (jsonb_array_elements_text(state -> 'r'), jsonb_array_elements(state -> 'c')) z(k, c));

-- ============================================================================
-- Internals
-- ============================================================================

-- The largest number of runs in a chunk. Edits by position parse and
-- rewrite one chunk; the chunk table ("n") grows as the chunks shrink.
-- Measured in NOTES.md.
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
create function crdt._yseq_integrate(state crdt.yseq, ins jsonb, dels jsonb)
returns crdt.yseq
language plpgsql immutable parallel safe
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
    ext boolean;
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
    -- output
    cm int[];
    ct text;
    cv int;
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
    cbh := cb[1 : nch];
    head := case when nr0 > 0 then 1 else -1 end;
    tail := case when nr0 > 0 then nr0 else -1 end;

    -- ---- inserts --------------------------------------------------------
    select array_agg(x ->> 0 order by o), array_agg((x ->> 1)::int order by o),
           array_agg(x -> 2 ->> 0 order by o), array_agg((x -> 2 ->> 1)::int order by o),
           array_agg(x -> 3 ->> 0 order by o), array_agg((x -> 3 ->> 1)::int order by o),
           array_agg(x ->> 4 order by o), array_agg(x order by o)
      into w_r, w_s, w_olk, w_ols, w_ork, w_ors, w_t, w_raw
    from (select x, o from jsonb_array_elements(state -> 'p') with ordinality a(x, o)
          union all
          select x, o + 4294967296 from jsonb_array_elements(coalesce(ins, '[]'::jsonb)) with ordinality b(x, o)) z;
    nw := coalesce(cardinality(w_r), 0);

    if nw > 0 then
        -- the original slots by first character key, for width_bucket
        select coalesce(array_agg(k order by k), '{}'), coalesce(array_agg(g order by k), '{}'), coalesce(array_agg(e order by k), '{}')
          into sk, sp, oe
        from (select g, (mm[7 * g - 6]::int8 << 32) | mm[7 * g - 5] k,
                     (mm[7 * g - 6]::int8 << 32) | (mm[7 * g - 5] + abs(mm[7 * g - 4]) - 1) e
              from generate_series(1, nr0) g) z;
        kready := true;
        w_done := array_fill(false, array[nw]);
        progress := true;
        while progress loop
            progress := false;
            wi := 1;
            while wi <= nw loop
                if w_done[wi] then
                    wi := wi + 1;
                    continue;
                end if;
                rk := w_r[wi];
                s := w_s[wi];
                tx := w_t[wi];
                ln := length(tx);
                ri := array_position(rr, rk);
                have := coalesce(cc[ri], 0);
                if s + ln - 1 <= have then
                    -- already integrated
                    w_done[wi] := true;
                    wi := wi + 1;
                    continue;
                end if;
                if s > have + 1 then
                    wi := wi + 1;
                    continue;
                end if;
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
                if olri is null or orri is null or (olri > 0 and ols > cc[olri]) or (orri > 0 and ors > cc[orri]) then
                    wi := wi + 1;
                    continue;
                end if;
                if ri is null then
                    rr := rr || rk;
                    cc := cc || 0;
                    ri := cardinality(rr);
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
                    while fk > ((mm[7 * i - 6]::int8 << 32) | (mm[7 * i - 5] + abs(mm[7 * i - 4]) - 1)) loop
                        i := sx[i];
                    end loop;
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
                    while fk > ((mm[7 * i - 6]::int8 << 32) | (mm[7 * i - 5] + abs(mm[7 * i - 4]) - 1)) loop
                        i := sx[i];
                    end loop;
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
                        while fk > ((mm[7 * p - 6]::int8 << 32) | (mm[7 * p - 5] + abs(mm[7 * p - 4]) - 1)) loop
                            p := sx[p];
                        end loop;
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
                            while fk > ((mm[7 * q - 6]::int8 << 32) | (mm[7 * q - 5] + abs(mm[7 * q - 4]) - 1)) loop
                                q := sx[q];
                            end loop;
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

                -- insert before dest (-1: at the end)
                pr := case when dest = -1 then tail when pv[dest] <> 0 then pv[dest] else dest - 1 end;
                if pr < 0 then
                    pr := 0;
                end if;
                ext := pr > 0 and mm[7 * pr - 6] = ri and mm[7 * pr - 4] > 0
                       and mm[7 * pr - 5] + mm[7 * pr - 4] = s
                       and olri = ri and ols = s - 1
                       and mm[7 * pr - 1] = orri and mm[7 * pr] = coalesce(ors, 0);
                if ext then
                    -- continues slot pr
                    mm[7 * pr - 4] := mm[7 * pr - 4] + ln;
                    jj := (case when pr <= nr0 then width_bucket(pr, cbh) else sca[pr - nr0] end);
                else
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
                end if;
                -- visible characters of chunk jj before the new text
                v := 0;
                if pr > 0 then
                    z := chh[jj];
                    loop
                        if mm[7 * z - 4] > 0 then v := v + mm[7 * z - 4]; end if;
                        exit when z = pr;
                        z := case when nx[z] <> 0 then nx[z] when z < nr0 then z + 1 else -1 end;
                    end loop;
                    if ext then v := v - ln; end if;
                end if;
                st[jj] := left(st[jj], v) || tx || substr(st[jj], v + 1);
                nv[jj] := nv[jj] + ln;
                -- the new ids, for lookups
                nne := nne + 1;
                nk1[nne] := (ri::int8 << 32) | s;
                nk2[nne] := (ri::int8 << 32) | (s + ln - 1);
                nsl[nne] := case when ext then pr else ns end;
                dirty[jj] := true;
                cc[ri] := s + ln - 1;
                changed := true;
                w_done[wi] := true;
                progress := true;
                wi := wi + 1;
            end loop;
        end loop;
        select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into pend_p
        from unnest(w_raw, w_done) u(x, d) where not d;
    end if;

    -- ---- deletes --------------------------------------------------------
    -- dm[ri]: the ids to delete that are present; the rest stays pending
    dm := array_fill(null::int8multirange, array[coalesce(cardinality(rr), 0)]);
    for dk, dmr in
        select x ->> 0, range_agg(int8range((x ->> 1)::int8, (x ->> 1)::int8 + (x ->> 2)::int8))
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
                        fk := (ri::int8 << 32) | dcur;
                        i := width_bucket(fk, sk);
                        if i > 0 and fk <= oe[i] then
                            i := sp[i];
                        else
                            i := nsl[coalesce(array_position(nk2, fk), array_position(nk1, fk),
                                         (select u.o::int from unnest(nk1, nk2) with ordinality u(a, b, o) where fk between u.a and u.b limit 1))];
                        end if;
                        while fk > ((mm[7 * i - 6]::int8 << 32) | (mm[7 * i - 5] + abs(mm[7 * i - 4]) - 1)) loop
                            i := sx[i];
                        end loop;
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
                            v := 0;
                            z := chh[jj];
                            while z <> i loop
                                if mm[7 * z - 4] > 0 then v := v + mm[7 * z - 4]; end if;
                                z := case when nx[z] <> 0 then nx[z] when z < nr0 then z + 1 else -1 end;
                            end loop;
                            mm[7 * i - 4] := -take;
                            st[jj] := left(st[jj], v) || substr(st[jj], v + take + 1);
                            nv[jj] := nv[jj] - take;
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

    if not changed and pend_p = state -> 'p' and pend_x = state -> 'x' then
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
            cm := '{}';
            m := 0;
            z := chh[j];
            while z <> -1 and (case when z <= nr0 then width_bucket(z, cbh) else sca[z - nr0] end) = j loop
                cm[7 * m + 1] := mm[7 * z - 6];
                cm[7 * m + 2] := mm[7 * z - 5];
                cm[7 * m + 3] := mm[7 * z - 4];
                cm[7 * m + 4] := mm[7 * z - 3];
                cm[7 * m + 5] := mm[7 * z - 2];
                cm[7 * m + 6] := mm[7 * z - 1];
                cm[7 * m + 7] := mm[7 * z];
                m := m + 1;
                z := case when nx[z] <> 0 then nx[z] when z < nr0 then z + 1 else -1 end;
            end loop;
            cm := crdt._yseq_compact(cm);
            ct := st[j];
            cv := nv[j];
            -- chunks of more than cmax runs go out as chunks of cmax / 2
            while cardinality(cm) > 7 * cmax loop
                vh := 0;
                h := 1;
                while h <= cmax / 2 loop
                    if cm[7 * h - 4] > 0 then vh := vh + cm[7 * h - 4]; end if;
                    h := h + 1;
                end loop;
                out_n := out_n || vh;
                out_s := out_s || left(ct, vh);
                out_m := out_m || cm[1 : 7 * (cmax / 2)]::text;
                cm := cm[7 * (cmax / 2) + 1 :];
                ct := substr(ct, vh + 1);
                cv := cv - vh;
            end loop;
            out_n := out_n || cv;
            out_s := out_s || ct;
            out_m := out_m || cm::text;
        end if;
        j := j + 1;
    end loop;

    return jsonb_build_object(
        't', 'yseq', 'v', 1,
        'r', to_jsonb(rr), 'c', to_jsonb(cc),
        'n', to_jsonb(out_n), 's', to_jsonb(out_s), 'm', to_jsonb(out_m),
        'p', pend_p, 'x', pend_x)::crdt.yseq;
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
                select x ->> 0, int8range((x ->> 1)::int8, (x ->> 1)::int8 + (x ->> 2)::int8)
                from jsonb_array_elements(state -> 'x') x) z
          group by k) y;
    return res;
end;
$$;

-- ============================================================================
-- Local edits
-- ============================================================================

create function crdt._yseq_check_replica(fn text, replica text)
returns void
language plpgsql immutable parallel safe
as $$
begin
    if replica is null then
        raise exception 'crdt.%: replica must not be null', fn using errcode = '22004';
    end if;
    if replica !~ '^[^:]+(:.+)?$' then
        raise exception 'crdt.%: % is not a replica key', fn, quote_literal(replica)
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
-- three-way merge. The diff is taken against the base text, the resulting
-- op is numbered after the replica's last character in either state, and it
-- is integrated into `state`, so concurrent edits to other parts of the text
-- survive (test/spec/12_sync.sql, 20_concurrency.sql). The base is the whole
-- state, not a version vector: the text at a version needs the tombstones
-- that came later, with their text, and the state keeps neither (NOTES.md,
-- "set() and concurrent saves"). The save path for a form or an ORM:
--
--   update posts set body = crdt.yseq_set(body, $1, $2, base => $3) where id = $4;
create function crdt.yseq_set(state crdt.yseq, content text, replica text, base crdt.yseq default null)
returns crdt.yseq
language plpgsql immutable parallel safe
as $$
declare
    old text;
    b0 jsonb;
    b1 crdt.yseq;
    ops jsonb;
    ri int;
    cs int;
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
        -- the edit as an op on the base, numbered after the replica's last
        -- character in either state, then integrated into the current state
        b0 := base;
        cs := greatest(coalesce((crdt.yseq_version(state) ->> replica)::int, 0),
                       coalesce((crdt.yseq_version(base) ->> replica)::int, 0));
        ri := array_position(array(select jsonb_array_elements_text(base -> 'r')), replica);
        if ri is null then
            b0 := jsonb_set(jsonb_set(b0, '{r}', (b0 -> 'r') || to_jsonb(replica)), '{c}', (b0 -> 'c') || to_jsonb(cs));
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
-- Sync
-- ============================================================================

-- The ops a replica that has `vv` ({replica: count}, default {}) lacks:
-- {"i": insert runs with seq > vv[replica], in a causal order, "d": the whole
-- delete set}. Deleted characters are sent as U+FFFD; the delete set hides
-- them. Pending runs are not sent. Runs are coalesced as typing makes them.
create function crdt.yseq_ops_since(state crdt.yseq, vv jsonb default '{}')
returns jsonb
language plpgsql immutable parallel safe
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
                                else repeat(U&'\FFFD', abs(ln) - off) end;
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

-- The ops that take `old` to `new` (a later version of the same document):
-- the inserts new has beyond old's version, and the deletes new has that old
-- has not. For a local edit, `yseq_diff(s, crdt.yseq_insert(s, ...))` is
-- exactly the op it generated.
create function crdt.yseq_diff(old crdt.yseq, new crdt.yseq)
returns jsonb
language sql immutable parallel safe
return jsonb_build_object(
    'i', crdt.yseq_ops_since(new, crdt.yseq_version(coalesce(old, crdt.yseq_empty()))) -> 'i',
    'd', (select coalesce(jsonb_agg(jsonb_build_array(k, lower(g), upper(g) - lower(g)) order by k collate "C", lower(g)), '[]'::jsonb)
          from (select n.k, unnest(n.mr - coalesce(o.mr, '{}'::int8multirange)) g
                from (select x ->> 0 k, range_agg(int8range((x ->> 1)::int8, (x ->> 1)::int8 + (x ->> 2)::int8)) mr
                      from jsonb_array_elements(crdt._yseq_delete_set(new)) x group by 1) n
                left join (select x ->> 0 k, range_agg(int8range((x ->> 1)::int8, (x ->> 1)::int8 + (x ->> 2)::int8)) mr
                           from jsonb_array_elements(crdt._yseq_delete_set(coalesce(old, crdt.yseq_empty()))) x group by 1) o
                  on o.k = n.k) z));

-- Full-state merge: commutative, associative and idempotent on the
-- document (the items, the delete set and the pending ops). The chunk layout
-- of the result can differ with the argument order; crdt._yseq_normalize
-- gives the canonical form. merge(x, null) = merge(null, x) = x.
create function crdt.yseq_merge(a crdt.yseq, b crdt.yseq)
returns crdt.yseq
language plpgsql immutable parallel safe
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
    ops := crdt.yseq_ops_since(b, crdt.yseq_version(a));
    return crdt._yseq_integrate(a, (ops -> 'i') || (b -> 'p'), (ops -> 'd') || (b -> 'x'));
end;
$$;

create aggregate crdt.yseq_merge_agg(crdt.yseq) (
    sfunc = crdt.yseq_merge,
    stype = crdt.yseq,
    combinefunc = crdt.yseq_merge,
    parallel = safe
);

-- The write path for untrusted writers: ops from a writer whose identity is
-- `replica` (default crdt.current_replica_id()). `ops` is one op
-- {"i": [...], "d": [...]} or an array of them. Every insert run must belong
-- to `replica` (its key is the id or <id>:<device>); deletes may target
-- anyone's characters. Ops already applied are skipped, so a retry is a
-- no-op. Inserts whose origins are missing wait in the state.
--
-- Errors: 42501 no replica (null), or an insert run of another replica;
-- 22023 a replica that is empty or contains ":", or a malformed op.
create function crdt.yseq_apply(state crdt.yseq, ops jsonb, replica text default crdt.current_replica_id())
returns crdt.yseq
language plpgsql immutable parallel safe
set search_path = pg_catalog, pg_temp
as $$
declare
    ins jsonb;
    dels jsonb;
    bad jsonb;
begin
    if replica is null then
        raise exception 'crdt.yseq_apply: the writer has no replica id'
            using errcode = '42501',
                  hint = 'Pass the writer''s identity as the replica argument, or set it up for crdt.current_replica_id() (a JWT claim in request.jwt.claims, or the crdt.replica_id setting).';
    end if;
    if replica !~ '^[^:]+$' then
        raise exception 'crdt.yseq_apply: % is not a replica id', quote_literal(replica)
            using errcode = '22023',
                  hint = 'A replica id is non-empty and has no ":" (":" separates a replica id from a device suffix).';
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
       or (o - '{i,d}'::text[]) <> '{}'::jsonb
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
    if jsonb_array_length(ins) = 0 and jsonb_array_length(dels) = 0 then
        return coalesce(state, crdt.yseq_empty());
    end if;
    return crdt._yseq_integrate(coalesce(state, crdt.yseq_empty()), ins, dels);
end;
$$;

-- ============================================================================
-- Validation and the canonical form
-- ============================================================================

-- The full validator: the envelope, every chunk (text length, run layout),
-- every run (replica indexes, origins present), the version vector (each
-- replica's runs cover 1 .. c exactly), origins on the correct side, and
-- the pending ops. Expensive (it sorts the runs); for tests and for a table
-- CHECK where states come from outside. Null for null.
create function crdt.yseq_is_valid(state jsonb)
returns boolean
language plpgsql immutable parallel safe
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
        and state @> '{"t": "yseq", "v": 1, "r": [], "c": [], "n": [], "s": [], "m": [], "p": [], "x": []}'
        and (state - '{t,v,r,c,n,s,m,p,x}'::text[]) = '{}'::jsonb, false) then
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
    return not exists (select 1 from jsonb_array_elements(state -> 'p') x where not crdt._yseq_valid_run(x))
       and not exists (select 1 from jsonb_array_elements(state -> 'x') x where not crdt._yseq_valid_del(x));
end;
$$;

-- The canonical form of a state: replicas sorted (collate "C"), runs merged
-- across chunk boundaries, chunks of cmax / 2 runs from the start, pending ops
-- sorted. Two states hold the same document exactly when their canonical
-- forms are equal. For tests and comparisons; costs a rebuild.
create function crdt._yseq_normalize(state crdt.yseq)
returns crdt.yseq
language plpgsql immutable parallel safe
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
    return jsonb_build_object(
        't', 'yseq', 'v', 1,
        'r', to_jsonb(coalesce(sr, '{}')),
        'c', to_jsonb(coalesce(array(select cc[array_position(rr, x)] from unnest(sr) x), '{}')),
        'n', to_jsonb(out_n), 's', to_jsonb(out_s), 'm', to_jsonb(out_m),
        'p', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements(state -> 'p') x),
        'x', (select coalesce(jsonb_agg(jsonb_build_array(k, lower(g), upper(g) - lower(g)) order by k collate "C", lower(g)), '[]'::jsonb)
              from (select k, unnest(range_agg(rg)) g
                    from (select x ->> 0 k, int8range((x ->> 1)::int8, (x ->> 1)::int8 + (x ->> 2)::int8) rg
                          from jsonb_array_elements(state -> 'x') x) z group by k) y))::crdt.yseq;
end;
$$;

-- ============================================================================
-- Privileges
-- ============================================================================

-- Same pattern as the extension file: nothing for public by default, then
-- the whole API (pure functions; the internals are called by them).
do $$
declare
    f record;
begin
    for f in
        select p.oid::regprocedure::text as obj
        from pg_catalog.pg_proc p
        where p.pronamespace = 'crdt'::regnamespace and p.proname ~ '^_?yseq_'
    loop
        execute format('revoke all on function %s from public', f.obj);
        execute format('grant execute on function %s to public', f.obj);
    end loop;
end;
$$;
