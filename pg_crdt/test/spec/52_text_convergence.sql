-- Goal: convergence. Documents X and Y (two servers) edit concurrently with
-- local positional edits by several replicas, then exchange ops through
-- ydoc_ops_since(their version), with shuffled and duplicated delivery, and
-- end with the same text. Also: the ops a document returns, applied in a
-- random order to a fresh document, give the same text; and concurrent runs
-- typed at one place do not interleave.
\i :ext_dir/test/lib/text-helpers.sql

create temp table trial (n int, x text, y text, z text, ok_xy boolean, ok_z boolean);

select setseed(0.42);
do $$
declare
    x text; y text; z text;
    d text; rep text; len int; pos int; k int;
    opsx jsonb; opsy jsonb; o jsonb;
    allops jsonb;
    op jsonb;
begin
    for t in 1..30 loop
        x := crdt.ydoc_create(); y := crdt.ydoc_create();
        allops := '[]';
        -- a shared start
        op := crdt.ydoc_set(x, 'shared start text', 'base');
        allops := allops || jsonb_build_array(op);
        perform crdt.ydoc_merge(y, op);
        for round in 1..3 loop
            -- concurrent edits
            for e in 1..(5 + floor(random() * 20))::int loop
                if random() < 0.5 then d := x; rep := (array['ann', 'Bob', 'cy'])[1 + floor(random() * 3)::int];
                else d := y; rep := (array['dee', 'ann:tab', '😀'])[1 + floor(random() * 3)::int]; end if;
                len := crdt.ydoc_length(d);
                if len > 0 and random() < 0.35 then
                    pos := floor(random() * len)::int;
                    k := least(len - pos, 1 + floor(random() * 4)::int);
                    op := crdt.ydoc_delete(d, pos, k, rep);
                else
                    pos := floor(random() * (len + 1))::int;
                    op := crdt.ydoc_insert(d, pos, substr('abcdefgh€😀ij', 1 + floor(random() * 10)::int, 1 + floor(random() * 3)::int), rep);
                end if;
                allops := allops || jsonb_build_array(op);
            end loop;
            -- exchange: split each side's ops_since into single-run ops, shuffle, duplicate
            opsx := crdt.ydoc_ops_since(x, crdt.ydoc_version(y));
            opsy := crdt.ydoc_ops_since(y, crdt.ydoc_version(x));
            for o in
                select v from (
                    select jsonb_build_object('i', jsonb_build_array(e), 'd', '[]'::jsonb) v from jsonb_array_elements(opsx -> 'i') e
                    union all select jsonb_build_object('i', '[]'::jsonb, 'd', jsonb_build_array(e)) from jsonb_array_elements(opsx -> 'd') e
                ) s, generate_series(1, 1 + (random() < 0.3)::int) dup order by random()
            loop
                perform crdt.ydoc_merge(y, o);
            end loop;
            for o in
                select v from (
                    select jsonb_build_object('i', jsonb_build_array(e), 'd', '[]'::jsonb) v from jsonb_array_elements(opsy -> 'i') e
                    union all select jsonb_build_object('i', '[]'::jsonb, 'd', jsonb_build_array(e)) from jsonb_array_elements(opsy -> 'd') e
                ) s, generate_series(1, 1 + (random() < 0.3)::int) dup order by random()
            loop
                perform crdt.ydoc_merge(x, o);
            end loop;
        end loop;
        -- every op ever returned, shuffled with duplicates, into a fresh doc
        z := crdt.ydoc_create();
        for o in select v from jsonb_array_elements(allops) v, generate_series(1, 1 + (random() < 0.2)::int) order by random() loop
            perform crdt.ydoc_merge(z, o);
        end loop;
        insert into trial values (t, x, y, z,
            crdt.ydoc_value(x) = crdt.ydoc_value(y) and crdt.ydoc_version(x) = crdt.ydoc_version(y),
            crdt.ydoc_value(z) = crdt.ydoc_value(x));
    end loop;
end;
$$;

-- Non-interleaving: three replicas type a word each at the same place,
-- char by char, on three servers, then merge all ways.
create temp table ni (doc text, who text);
do $$
declare
    docs text[] := array[crdt.ydoc_create(), crdt.ydoc_create(), crdt.ydoc_create()];
    who text[] := array['bob', 'alice', 'carol'];
    w text[] := array['BBBB', 'aaaa', 'cccc'];
    op jsonb;
begin
    op := crdt.ydoc_insert(docs[1], 0, '[]', 'base');
    perform crdt.ydoc_merge(docs[2], op);
    perform crdt.ydoc_merge(docs[3], op);
    for i in 1..3 loop
        for c in 1..4 loop
            perform crdt.ydoc_insert(docs[i], c, substr(w[i], c, 1), who[i]);
        end loop;
    end loop;
    for i in 1..3 loop
        for j in 1..3 loop
            perform crdt.ydoc_merge(docs[i], crdt.ydoc_ops_since(docs[j], crdt.ydoc_version(docs[i])));
        end loop;
        insert into ni values (docs[i], who[i]);
    end loop;
end;
$$;

select tap.plan(6);
select tap.is((select count(*)::int from trial where ok_xy), 30, '30 trials: X and Y converge (text and version vector) after shuffled, duplicated exchange');
select tap.is((select count(*)::int from trial where ok_z), 30, 'every op, shuffled and duplicated, into a fresh doc gives the same text');
select tap.is((select count(*)::int from crdt.ydoc_pending), 0, 'nothing left buffered');
select tap.is((select string_agg(n::text, ',') from trial where pg_temp.ydoc_check(x) || pg_temp.ydoc_check(y) || pg_temp.ydoc_check(z) <> ''), null, 'invariants hold');
select tap.is((select array_agg(distinct crdt.ydoc_value(doc)) from ni), array['[aaaaBBBBcccc]'], 'concurrent words typed at one place: not interleaved, same on all servers');
select tap.ok((select bool_and(length(crdt.ydoc_value(x)) > 0) from trial), 'documents are non-trivial');

select * from tap.finish();
