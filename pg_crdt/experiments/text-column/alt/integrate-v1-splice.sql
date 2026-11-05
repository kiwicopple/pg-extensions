-- Variant 1 of crdt._yseq_integrate (superseded): one flat run array, spliced
-- with slices on every split and insert (O(document) per integrated run).
-- Kept for the measurements in NOTES.md. Load after impl.sql to compare.
-- create or replace replaces the current engine in that database.
-- Integrate remote insert runs and deletes (wire format, already checked)
-- into a state, with the state's pending runs and deletes. The trusted core
-- of yseq_apply and yseq_merge.
--
-- Inserts are integrated with YjsMod (research/text.md) as whole runs, in
-- rounds: a run is ready when the same replica's previous character and both
-- origins are present. Ready runs are integrated in input order; the rest
-- wait for the next round, and stay pending when a round makes no progress.
-- Deletes run after the inserts. A delete of ids not seen yet stays pending.
create or replace function crdt._yseq_integrate(state crdt.yseq, ins jsonb, dels jsonb)
returns crdt.yseq
language plpgsql immutable parallel safe
as $$
declare
    rr text[];
    cc int[];
    nv int[];
    st text[];
    ms text[];
    dirty boolean[];
    cb int[];
    mm int[];
    k1 int8[] := '{}';
    k2 int8[] := '{}';
    nr int;
    nch int;
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
    scanning boolean;
    i int;
    p int;
    q int;
    u int;
    ocl int;
    ocr int;
    jj int;
    j int;
    v int;
    run int[];
    -- deletes
    dk text;
    dmr int8multirange;
    dm int8multirange[];
    pend_x jsonb := '[]';
    pend_p jsonb;
    anydel boolean := false;
    affected boolean;
    rg int8range;
    cm int[];
    ct text;
    cv int;
    nm int[];
    doff int[];
    dlen int[];
    nd int;
    ii int;
    a int8;
    bnd int8;
    vis int;
    -- output
    out_n int[] := '{}';
    out_s text[] := '{}';
    out_m text[] := '{}';
    h int;
    vh int;
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
    dirty := array_fill(false, array[nch]);
    cb := array_fill(1, array[nch + 1]);
    j := 1;
    while j <= nch loop
        cb[j + 1] := cb[j] + (length(ms[j]) - length(replace(ms[j], ',', '')) + 1) / 7;
        j := j + 1;
    end loop;
    nr := cb[nch + 1] - 1;
    mm := case when nch > 0 then ('{' || translate(array_to_string(ms, ','), '{}', '') || '}')::int[] else '{}'::int[] end;

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
        if nr > 0 then
            k1 := array(select (mm[7 * g - 6]::int8 << 32) | mm[7 * g - 5] from generate_series(1, nr) g);
            k2 := array(select (mm[7 * g - 6]::int8 << 32) | (mm[7 * g - 5] + abs(mm[7 * g - 4]) - 1) from generate_series(1, nr) g);
        end if;
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

                -- left: the run that ends with originLeft (split if needed)
                if olri = 0 then
                    lft := 0;
                else
                    i := crdt._yseq_find(k1, k2, (olri::int8 << 32) | ols);
                    u := ols - mm[7 * i - 5];
                    if u < abs(mm[7 * i - 4]) - 1 then
                        run := mm[7 * i - 6 : 7 * i];
                        mm := mm[1 : 7 * i - 7]
                            || crdt._yseq_piece(run, 0, u + 1, run[3] < 0)
                            || crdt._yseq_piece(run, u + 1, abs(run[3]) - u - 1, run[3] < 0)
                            || mm[7 * i + 1 :];
                        k1 := k1[1 : i] || ((run[1]::int8 << 32) | (run[2] + u + 1)) || k1[i + 1 :];
                        k2 := k2[1 : i - 1] || ((run[1]::int8 << 32) | (run[2] + u)) || k2[i :];
                        nr := nr + 1;
                        jj := 1;
                        while cb[jj + 1] <= i loop jj := jj + 1; end loop;
                        dirty[jj] := true;
                        j := jj + 1;
                        while j <= nch + 1 loop cb[j] := cb[j] + 1; j := j + 1; end loop;
                    end if;
                    lft := i;
                end if;
                -- right: the run that starts with originRight (split if needed)
                if orri = 0 then
                    rgt := nr + 1;
                else
                    i := crdt._yseq_find(k1, k2, (orri::int8 << 32) | ors);
                    u := ors - mm[7 * i - 5];
                    if u > 0 then
                        run := mm[7 * i - 6 : 7 * i];
                        mm := mm[1 : 7 * i - 7]
                            || crdt._yseq_piece(run, 0, u, run[3] < 0)
                            || crdt._yseq_piece(run, u, abs(run[3]) - u, run[3] < 0)
                            || mm[7 * i + 1 :];
                        k1 := k1[1 : i] || ((run[1]::int8 << 32) | (run[2] + u)) || k1[i + 1 :];
                        k2 := k2[1 : i - 1] || ((run[1]::int8 << 32) | (run[2] + u - 1)) || k2[i :];
                        nr := nr + 1;
                        jj := 1;
                        while cb[jj + 1] <= i loop jj := jj + 1; end loop;
                        dirty[jj] := true;
                        j := jj + 1;
                        while j <= nch + 1 loop cb[j] := cb[j] + 1; j := j + 1; end loop;
                        i := i + 1;
                    end if;
                    rgt := i;
                end if;

                -- YjsMod scan, one run at a time (see research/text.md)
                lastoff := case when lft > 0 then abs(mm[7 * lft - 4]) - 1 end;
                dest := lft + 1;
                scanning := false;
                i := lft + 1;
                loop
                    if not scanning then
                        dest := i;
                    end if;
                    exit when i > nr or i = rgt;
                    if mm[7 * i - 3] = 0 then
                        ocl := case when lft = 0 then 0 else -1 end;
                    elsif lft = 0 then
                        ocl := 1;
                    else
                        p := crdt._yseq_find(k1, k2, (mm[7 * i - 3]::int8 << 32) | mm[7 * i - 2]);
                        if p < lft then
                            ocl := -1;
                        elsif p = lft then
                            ocl := case when mm[7 * i - 2] - mm[7 * p - 5] = lastoff then 0 else -1 end;
                        else
                            ocl := 1;
                        end if;
                    end if;
                    exit when ocl < 0;
                    if ocl = 0 then
                        if mm[7 * i - 1] = 0 then
                            ocr := case when rgt = nr + 1 then 0 else 1 end;
                        else
                            q := crdt._yseq_find(k1, k2, (mm[7 * i - 1]::int8 << 32) | mm[7 * i]);
                            if q < rgt then
                                ocr := -1;
                            elsif q = rgt and mm[7 * i] = mm[7 * q - 5] then
                                ocr := 0;
                            else
                                ocr := 1;
                            end if;
                        end if;
                        if ocr < 0 then
                            scanning := true;
                        elsif ocr = 0 then
                            exit when rk < rr[mm[7 * i - 6]] collate "C";
                            scanning := false;
                        else
                            scanning := false;
                        end if;
                    end if;
                    i := i + 1;
                end loop;

                -- insert before run dest, in the chunk of run dest-1
                if nch = 0 then
                    nch := 1;
                    nv := array[0];
                    st := array[''];
                    ms := array['{}'];
                    dirty := array[true];
                    cb := array[1, 1];
                    jj := 1;
                elsif dest = 1 then
                    jj := 1;
                else
                    jj := 1;
                    while cb[jj + 1] <= dest - 1 loop jj := jj + 1; end loop;
                end if;
                v := 0;
                i := cb[jj];
                while i < dest loop
                    if mm[7 * i - 4] > 0 then v := v + mm[7 * i - 4]; end if;
                    i := i + 1;
                end loop;
                if dest > 1 and mm[7 * dest - 13] = ri and mm[7 * dest - 11] > 0
                   and mm[7 * dest - 12] + mm[7 * dest - 11] = s
                   and olri = ri and ols = s - 1
                   and mm[7 * dest - 8] = orri and mm[7 * dest - 7] = coalesce(ors, 0) then
                    -- continues run dest-1
                    mm[7 * dest - 11] := mm[7 * dest - 11] + ln;
                    k2[dest - 1] := (ri::int8 << 32) | (s + ln - 1);
                else
                    mm := mm[1 : 7 * dest - 7]
                        || array[ri, s, ln, olri, coalesce(ols, 0), orri, coalesce(ors, 0)]
                        || mm[7 * dest - 6 :];
                    k1 := k1[1 : dest - 1] || ((ri::int8 << 32) | s) || k1[dest :];
                    k2 := k2[1 : dest - 1] || ((ri::int8 << 32) | (s + ln - 1)) || k2[dest :];
                    nr := nr + 1;
                    j := jj + 1;
                    while j <= nch + 1 loop cb[j] := cb[j] + 1; j := j + 1; end loop;
                end if;
                st[jj] := left(st[jj], v) || tx || substr(st[jj], v + 1);
                nv[jj] := nv[jj] + ln;
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
    else
        pend_p := '[]'::jsonb;
    end if;

    -- ---- deletes --------------------------------------------------------
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
                anydel := true;
            end if;
            dmr := dmr - int8multirange(int8range(1, cc[ri] + 1));
        end if;
        select pend_x || coalesce(jsonb_agg(jsonb_build_array(dk, lower(g), upper(g) - lower(g)) order by lower(g)), '[]'::jsonb)
          into pend_x
        from unnest(dmr) g;
    end loop;

    -- ---- output ---------------------------------------------------------
    j := 1;
    while j <= nch loop
        cm := null;
        if anydel then
            -- does a delete hit a visible run of this chunk?
            affected := false;
            i := cb[j];
            while i < cb[j + 1] loop
                if mm[7 * i - 4] > 0 and dm[mm[7 * i - 6]] is not null
                   and dm[mm[7 * i - 6]] && int8range(mm[7 * i - 5], mm[7 * i - 5] + mm[7 * i - 4]) then
                    affected := true;
                    exit;
                end if;
                i := i + 1;
            end loop;
            if affected then
                nm := '{}';
                nd := 0;
                doff := '{}';
                dlen := '{}';
                vis := 0;
                i := cb[j];
                while i < cb[j + 1] loop
                    run := mm[7 * i - 6 : 7 * i];
                    if run[3] > 0 and dm[run[1]] is not null
                       and dm[run[1]] && int8range(run[2], run[2] + run[3]) then
                        a := run[2];
                        for rg in select g from unnest(dm[run[1]] * int8multirange(int8range(run[2], run[2] + run[3]))) g loop
                            if lower(rg) > a then
                                nm := nm || crdt._yseq_piece(run, (a - run[2])::int, (lower(rg) - a)::int, false);
                            end if;
                            nm := nm || crdt._yseq_piece(run, (lower(rg) - run[2])::int, (upper(rg) - lower(rg))::int, true);
                            nd := nd + 1;
                            doff[nd] := vis + (lower(rg) - run[2])::int;
                            dlen[nd] := (upper(rg) - lower(rg))::int;
                            a := upper(rg);
                        end loop;
                        bnd := run[2] + run[3];
                        if a < bnd then
                            nm := nm || crdt._yseq_piece(run, (a - run[2])::int, (bnd - a)::int, false);
                        end if;
                        vis := vis + run[3];
                    else
                        nm := nm || run;
                        if run[3] > 0 then vis := vis + run[3]; end if;
                    end if;
                    i := i + 1;
                end loop;
                ct := st[j];
                cv := nv[j];
                ii := nd;
                while ii >= 1 loop
                    ct := left(ct, doff[ii]) || substr(ct, doff[ii] + dlen[ii] + 1);
                    cv := cv - dlen[ii];
                    ii := ii - 1;
                end loop;
                cm := crdt._yseq_compact(nm);
                changed := true;
            end if;
        end if;
        if cm is null and dirty[j] then
            cm := crdt._yseq_compact(mm[7 * cb[j] - 6 : 7 * cb[j + 1] - 7]);
            ct := st[j];
            cv := nv[j];
        end if;
        if cm is null then
            out_n := out_n || nv[j];
            out_s := out_s || st[j];
            out_m := out_m || ms[j];
        else
            -- split chunks of more than 128 runs into chunks of 64
            while cardinality(cm) > 7 * 128 loop
                vh := 0;
                h := 1;
                while h <= 64 loop
                    if cm[7 * h - 4] > 0 then vh := vh + cm[7 * h - 4]; end if;
                    h := h + 1;
                end loop;
                out_n := out_n || vh;
                out_s := out_s || left(ct, vh);
                out_m := out_m || cm[1 : 7 * 64]::text;
                cm := cm[7 * 64 + 1 :];
                ct := substr(ct, vh + 1);
                cv := cv - vh;
            end loop;
            out_n := out_n || cv;
            out_s := out_s || ct;
            out_m := out_m || cm::text;
        end if;
        j := j + 1;
    end loop;

    if not changed and pend_p = state -> 'p' and pend_x = state -> 'x' then
        return state;
    end if;
    return jsonb_build_object(
        't', 'yseq', 'v', 1,
        'r', to_jsonb(rr), 'c', to_jsonb(cc),
        'n', to_jsonb(out_n), 's', to_jsonb(out_s), 'm', to_jsonb(out_m),
        'p', pend_p, 'x', pend_x)::crdt.yseq;
end;
$$;
