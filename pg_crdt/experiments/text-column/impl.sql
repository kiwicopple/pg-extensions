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
 *    "x": [],                 pending deletes (wire format) of ids not seen yet
 *    "q": []}                 validated ops waiting for v: [[writer, op], ...]
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
    'YjsMod text sequence state (experiment). See experiments/text-column/NOTES.md. Dropping the extension with CASCADE drops every column of this type.';

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
-- Local edits
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
-- concurrent edits to other parts of the text survive (test/spec/12_sync.sql,
-- 20_concurrency.sql, 32_review.sql). The base must be a version of the same
-- document. The base is the whole
-- state, not a version vector: the text at a version needs the tombstones
-- that came later, with their text, and the state keeps neither (NOTES.md,
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
-- Sync
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
