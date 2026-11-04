-- Goal: replicas that edit concurrently and exchange ops in any order, with
-- duplicates, converge to the same document (research/text.md,
-- "Convergence").
--   40 trials. 2 to 5 replicas edit their own copies (insert, delete, set),
--   and now and then sync from another replica (full-state merge, or apply of
--   a random sample of the ops log). Every local edit's op (yseq_diff) goes
--   into the log. At the end:
--   1. a fresh state that applies the whole log shuffled, with duplicates,
--      one op per call (pending inserts wait), has the same text as
--   2. the same log applied in one call, and as
--   3. the merge of all replicas after each one received the whole log;
--   and the canonical forms are equal, nothing stays pending, and every
--   final state passes yseq_is_valid.

select setseed(0.11);

create function pg_temp.rnd_text(n int) returns text language sql volatile as $$
    select coalesce(string_agg((array['a','b','c',' ','é','日','😀','x','y','z'])[1 + floor(random() * 10)::int], ''), '')
    from generate_series(1, n)
$$;

create function pg_temp.edit(s crdt.yseq, r text) returns crdt.yseq language plpgsql volatile as $$
declare
    m text := crdt.yseq_value(s);
    len int := length(m);
    k float := random();
    pos int;
    n int;
begin
    if len = 0 or k < 0.55 then
        return crdt.yseq_insert(s, floor(random() * (len + 1))::int, pg_temp.rnd_text(1 + floor(random() * 3)::int), r);
    elsif k < 0.85 then
        pos := floor(random() * len)::int;
        return crdt.yseq_delete(s, pos, 1 + floor(random() * least(3, len - pos))::int, r);
    else
        pos := floor(random() * (len + 1))::int;
        n := floor(random() * least(4, len - pos + 1))::int;
        return crdt.yseq_set(s, left(m, pos) || pg_temp.rnd_text(floor(random() * 3)::int) || substr(m, pos + n + 1), r);
    end if;
end;
$$;

create table log (trial int, n serial, owner text, op jsonb);
create table results (trial int, ok_shuffled boolean, ok_batch boolean, ok_merge boolean, ok_canon boolean,
                      ok_pending boolean, ok_valid boolean, nops int, detail text);

do $$
declare
    nrep int;
    keys text[];
    st crdt.yseq[];
    old crdt.yseq;
    a int;
    b int;
    t1 crdt.yseq;
    t2 crdt.yseq;
    t3 crdt.yseq;
    o record;
begin
    for tr in 1..40 loop
        nrep := 2 + floor(random() * 4)::int;
        keys := (array['alice', 'bob', 'carol:laptop', 'carol:phone', 'dave', U&'\FFFD', U&'\+01F600', 'B'])[1:nrep];
        if tr % 3 = 0 then
            keys := array(select (array['B', 'a', 'b', 'A', U&'\FFFD', U&'\+01F600'])[g] from generate_series(1, nrep) g);
        end if;
        st := array_fill(crdt.yseq_empty(), array[nrep]);
        for step in 1..50 loop
            a := 1 + floor(random() * nrep)::int;
            if random() < 0.8 then
                old := st[a];
                st[a] := pg_temp.edit(st[a], keys[a]);
                insert into log (trial, owner, op) values (tr, split_part(keys[a], ':', 1), crdt.yseq_diff(old, st[a]));
            else
                b := 1 + floor(random() * nrep)::int;
                if random() < 0.5 then
                    st[a] := crdt.yseq_merge(st[a], st[b]);
                else
                    for o in select * from log l where l.trial = tr and random() < 0.3 order by random() loop
                        st[a] := crdt.yseq_apply(st[a], o.op, o.owner);
                    end loop;
                end if;
            end if;
        end loop;

        -- 1. shuffled, with duplicates, one op per call
        t1 := crdt.yseq_empty();
        for o in select l.* from log l, generate_series(1, 2) d
                 where l.trial = tr and (d = 1 or random() < 0.3) order by random() loop
            t1 := crdt.yseq_apply(t1, o.op, o.owner);
        end loop;
        -- 2. the whole log in one call (deletes as a trusted batch)
        t2 := crdt._yseq_integrate(crdt.yseq_empty(),
                (select coalesce(jsonb_agg(x order by random()), '[]') from log l, jsonb_array_elements(l.op -> 'i') x where l.trial = tr),
                (select coalesce(jsonb_agg(x), '[]') from log l, jsonb_array_elements(l.op -> 'd') x where l.trial = tr));
        -- 3. every replica gets the whole log, then all are merged
        for i in 1..nrep loop
            for o in select * from log l where l.trial = tr order by random() loop
                st[i] := crdt.yseq_apply(st[i], o.op, o.owner);
            end loop;
        end loop;
        t3 := (select crdt.yseq_merge_agg(x order by random()) from unnest(st) x);

        insert into results values (tr,
            crdt.yseq_value(t1) = crdt.yseq_value(t3),
            crdt.yseq_value(t2) = crdt.yseq_value(t3),
            (select bool_and(crdt.yseq_value(x) = crdt.yseq_value(t3)) from unnest(st) x),
            crdt._yseq_normalize(t1) = crdt._yseq_normalize(t3) and crdt._yseq_normalize(t2) = crdt._yseq_normalize(t3)
                and (select bool_and(crdt._yseq_normalize(x) = crdt._yseq_normalize(t3)) from unnest(st) x),
            jsonb_array_length(t1 -> 'p') = 0 and jsonb_array_length(t1 -> 'x') = 0 and jsonb_array_length(t3 -> 'p') = 0,
            crdt.yseq_is_valid(t1) and crdt.yseq_is_valid(t2) and crdt.yseq_is_valid(t3),
            (select count(*) from log l where l.trial = tr),
            format('t1=%L t3=%L', crdt.yseq_value(t1), crdt.yseq_value(t3)));
    end loop;
end;
$$;

select tap.plan(7);
select tap.is((select count(*) from results), 40::bigint, '40 trials ran');
select tap.ok(bool_and(ok_shuffled), 'the whole log, shuffled with duplicates, one op per call, converges'
              || coalesce(' (first failure: trial ' || min(trial) filter (where not ok_shuffled) || ')', '')) from results;
select tap.ok(bool_and(ok_batch), 'the whole log in one call gives the same text') from results;
select tap.ok(bool_and(ok_merge), 'every replica, after receiving the log, has the same text as the merge of all') from results;
select tap.ok(bool_and(ok_canon), 'and the same canonical state') from results;
select tap.ok(bool_and(ok_pending), 'nothing stays pending once the whole log is in') from results;
select tap.ok(bool_and(ok_valid), 'every final state passes yseq_is_valid') from results;
select '# ' || detail from results where not (ok_shuffled and ok_batch and ok_merge and ok_canon) limit 3;
select * from tap.finish();
