-- Goal: local edits by position behave exactly like edits of a plain string,
-- over long random sessions that grow documents past one chunk (128 runs),
-- and every intermediate state passes the full validator.
--   1. 40 sessions of 150 random inserts, deletes and sets from 3 replicas
--      (unicode text pool), checked against a plain text model at each step.
--   2. One long session (3,000 single-character edits, as an editor sends
--      them) ends with many chunks; text, length and validity hold.
--   3. yseq_diff of every edit is exactly the op: applying it to the old
--      state gives the new state's document.

select setseed(0.42);

create function pg_temp.rnd_text(n int) returns text language sql volatile as $$
    select coalesce(string_agg((array['a','b','c',' ','é','日','😀','e' || U&'\0301','👨' || U&'\200D' || '👩','x','y','\n'])[1 + floor(random() * 12)::int], ''), '')
    from generate_series(1, n)
$$;

-- one random edit: returns (state, model) after it
create function pg_temp.step(s crdt.yseq, m text, out s2 crdt.yseq, out m2 text) language plpgsql volatile as $$
declare
    len int := length(m);
    r text := (array['alice', 'bob', 'carol:phone'])[1 + floor(random() * 3)::int];
    k float := random();
    pos int;
    n int;
    t text;
begin
    if len = 0 or k < 0.5 then
        pos := floor(random() * (len + 1))::int;
        t := pg_temp.rnd_text(1 + floor(random() * 4)::int);
        s2 := crdt.yseq_insert(s, pos, t, r);
        m2 := left(m, pos) || t || substr(m, pos + 1);
    elsif k < 0.85 then
        pos := floor(random() * len)::int;
        n := 1 + floor(random() * least(5, len - pos))::int;
        s2 := crdt.yseq_delete(s, pos, n, r);
        m2 := left(m, pos) || substr(m, pos + n + 1);
    else
        pos := floor(random() * (len + 1))::int;
        n := floor(random() * least(6, len - pos + 1))::int;
        t := left(m, pos) || pg_temp.rnd_text(floor(random() * 4)::int) || substr(m, pos + n + 1);
        s2 := crdt.yseq_set(s, t, r);
        m2 := t;
    end if;
end;
$$;

create table results (name text, ok boolean, detail text);

do $$
declare
    s crdt.yseq;
    m text;
    s2 crdt.yseq;
    m2 text;
    bad text := null;
    nvalid int := 0;
    ndiff int := 0;
    d jsonb;
begin
    for sess in 1..40 loop
        s := crdt.yseq_empty();
        m := '';
        for i in 1..150 loop
            select * into s2, m2 from pg_temp.step(s, m);
            if crdt.yseq_value(s2) is distinct from m2 or crdt.yseq_length(s2) <> length(m2) then
                bad := coalesce(bad, format('session %s step %s: got %L want %L', sess, i, crdt.yseq_value(s2), m2));
            end if;
            if i % 10 = 0 then
                if not crdt.yseq_is_valid(s2) then
                    bad := coalesce(bad, format('session %s step %s: invalid state %s', sess, i, s2));
                end if;
                nvalid := nvalid + 1;
                -- the diff is the op
                d := crdt.yseq_diff(s, s2);
                if crdt._yseq_normalize(crdt._yseq_integrate(s, d -> 'i', d -> 'd')) <> crdt._yseq_normalize(s2) then
                    ndiff := ndiff + 1;
                end if;
            end if;
            s := s2;
            m := m2;
        end loop;
    end loop;
    insert into results values ('model', bad is null, bad), ('valid', nvalid = 600, nvalid::text), ('diff', ndiff = 0, ndiff::text);
end;
$$;

-- an editor's keystrokes: mostly typing on, some backspace, some cursor jumps
do $$
declare
    s crdt.yseq := crdt.yseq_empty();
    m text := '';
    cur int := 0;
    k float;
    t text;
begin
    for i in 1..3000 loop
        k := random();
        if k < 0.05 then
            cur := floor(random() * (length(m) + 1))::int;
        elsif k < 0.2 and cur > 0 then
            s := crdt.yseq_delete(s, cur - 1, 1, 'alice');
            m := left(m, cur - 1) || substr(m, cur + 1);
            cur := cur - 1;
        else
            t := pg_temp.rnd_text(1);
            s := crdt.yseq_insert(s, cur, t, case when i % 500 < 250 then 'alice' else 'bob' end);
            m := left(m, cur) || t || substr(m, cur + 1);
            cur := cur + 1;
        end if;
    end loop;
    insert into results values
        ('long text', crdt.yseq_value(s) = m, null),
        ('long length', crdt.yseq_length(s) = length(m), null),
        ('long valid', crdt.yseq_is_valid(s), null),
        ('long chunks', jsonb_array_length(s -> 'm') > 1, jsonb_array_length(s -> 'm')::text),
        ('long normalize keeps text', crdt.yseq_value(crdt._yseq_normalize(s)) = m and crdt.yseq_is_valid(crdt._yseq_normalize(s)), null);
end;
$$;

select tap.plan(8);
select tap.ok(ok, '40 random sessions of 150 edits match a plain text model' || coalesce(': ' || detail, '')) from results where name = 'model';
select tap.ok(ok, 'every 10th intermediate state passes yseq_is_valid (' || detail || ' states)') from results where name = 'valid';
select tap.ok(ok, 'yseq_diff(old, new) applied to old gives new, for every checked edit (' || detail || ' mismatches)') from results where name = 'diff';
select tap.ok(ok, '3,000 editor keystrokes: the text matches the model') from results where name = 'long text';
select tap.ok(ok, 'and the length') from results where name = 'long length';
select tap.ok(ok, 'and the state is valid') from results where name = 'long valid';
select tap.ok(ok, 'and it has several chunks (' || detail || ')') from results where name = 'long chunks';
select tap.ok(ok, 'the canonical form keeps the text and is valid') from results where name = 'long normalize keeps text';
select * from tap.finish();
