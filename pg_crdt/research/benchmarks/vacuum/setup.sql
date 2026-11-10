-- Shared setup for the vacuum and WAL benchmarks (research/benchmarks/vacuum).
-- Loaded into the template database after pg_crdt--0.0.1.sql (ydoc_, pn_) and
-- experiments/text-column/impl.sql (yseq_), as bench/text-compare.sh does.
--
-- The text generator and the edit plans follow bench/text-compare.sh (the same
-- 4,000-word pseudo-vocabulary with Zipf-like frequencies, sentences of 8 to 17
-- words, paragraphs of 3 to 6 sentences; edits: 70% insert of 1 to 5 words,
-- 30% delete of 5 to 40 characters, by alice, bob and carol). The vocabulary is
-- read once per call instead of once per sentence, so 100 documents of 100 kB
-- generate in seconds.

create extension if not exists pgstattuple;
create extension if not exists pg_freespacemap;

create schema bench;

create table bench.vocab (i int primary key, w text not null);
insert into bench.vocab
select row_number() over (order by w), w from (
    select distinct (select string_agg(
               substr('bcdfghjklmnprstvwz', 1 + ('x' || substr(md5(g || ':c' || k), 1, 6))::bit(24)::int % 18, 1) ||
               substr('aeiou', 1 + ('x' || substr(md5(g || ':v' || k), 1, 6))::bit(24)::int % 5, 1), '')
           from generate_series(1, 1 + ('x' || substr(md5(g::text), 1, 4))::bit(16)::int % 4) k) as w
    from generate_series(1, 4000) g) s
where w is not null;
create table bench.vocab_arr as select array_agg(w order by i) as v from bench.vocab;

create function bench.words(v text[], n int) returns text language sql volatile as $$
    select array_to_string(array(select v[1 + floor(power(random(), 3) * cardinality(v))::int]
                                 from generate_series(1, n)), ' ') $$;

create function bench.gen_text(n int) returns text language plpgsql volatile as $$
declare
    v text[];
    t text := '';
    para text;
    sent text;
begin
    select a.v into v from bench.vocab_arr a;
    while length(t) < n loop
        para := null;
        for s in 1..(3 + floor(random() * 4))::int loop
            sent := bench.words(v, 8 + floor(random() * 10)::int);
            sent := upper(left(sent, 1)) || substr(sent, 2) || '.';
            para := coalesce(para || ' ', '') || sent;
        end loop;
        t := t || case when t = '' then '' else E'\n\n' end || para;
    end loop;
    return left(t, n);
end;
$$;

-- plan0: the first text of each document (typed by alice in one insert);
-- plan: the edit history replayed on top of it, as fractions of the current
-- length so every shape replays it the same way.
create table bench.plan0 (size int, doc int, t text not null, primary key (size, doc));
create table bench.plan (size int, doc int, step int, kind text, frac float8, n int, txt text, replica text,
                         primary key (size, doc, step));

create function bench.make_plans(sizes int[], ndocs int, nedits int) returns void language plpgsql as $$
declare
    v text[];
    sz int;
begin
    select a.v into v from bench.vocab_arr a;
    perform setseed(0.42);
    foreach sz in array sizes loop
        insert into bench.plan0 select sz, d, bench.gen_text(sz) from generate_series(1, ndocs) d;
        insert into bench.plan
        select sz, d, s, case when random() < 0.7 then 'i' else 'd' end, random(), 5 + floor(random() * 36)::int,
               bench.words(v, 1 + floor(random() * 5)::int) || ' ',
               (array['alice', 'bob', 'carol'])[1 + floor(random() * 3)::int]
        from generate_series(1, ndocs) d, generate_series(1, nedits) s;
    end loop;
end;
$$;

create function bench.build_plain(sz int, pid int) returns text language plpgsql as $$
declare
    s text;
    r record;
    len int;
begin
    s := (select t from bench.plan0 where size = sz and doc = pid);
    for r in select * from bench.plan where size = sz and doc = pid order by step loop
        len := length(s);
        if r.kind = 'i' then
            s := overlay(s placing r.txt from floor(r.frac * (len + 1))::int + 1 for 0);
        else
            s := overlay(s placing '' from floor(r.frac * (len - r.n))::int + 1 for r.n);
        end if;
    end loop;
    return s;
end;
$$;

create function bench.build_a(sz int, pid int) returns crdt.yseq language plpgsql as $$
declare
    s crdt.yseq;
    r record;
    len int;
begin
    s := crdt.yseq_insert(crdt.yseq_empty(), 0, (select t from bench.plan0 where size = sz and doc = pid), 'alice');
    for r in select * from bench.plan where size = sz and doc = pid order by step loop
        len := crdt.yseq_length(s);
        if r.kind = 'i' then
            s := crdt.yseq_insert(s, floor(r.frac * (len + 1))::int, r.txt, r.replica);
        else
            s := crdt.yseq_delete(s, floor(r.frac * (len - r.n))::int, r.n, r.replica);
        end if;
    end loop;
    return s;
end;
$$;

create function bench.build_b(sz int, pid int) returns text language plpgsql as $$
declare
    d text := crdt.ydoc_create();
    r record;
    len int;
begin
    perform crdt.ydoc_insert(d, 0, (select t from bench.plan0 where size = sz and doc = pid), 'alice');
    for r in select * from bench.plan where size = sz and doc = pid order by step loop
        len := crdt.ydoc_length(d);
        if r.kind = 'i' then
            perform crdt.ydoc_insert(d, floor(r.frac * (len + 1))::int, r.txt, r.replica);
        else
            perform crdt.ydoc_delete(d, floor(r.frac * (len - r.n))::int, r.n, r.replica);
        end if;
    end loop;
    return d;
end;
$$;

-- A documents table of one shape:
--   plain       body text compression lz4        (the baseline)
--   plain_pglz  body text                        (default TOAST compression)
--   a           body crdt.yseq compression lz4   (yseq_, as documented)
--   a_pglz      body crdt.yseq                   (default TOAST compression)
--   b           body_doc text -> crdt.ydoc_docs  (ydoc_)
-- Every shape has the app columns title and updated_at, so the HOT runs can
-- index another column.
create function bench.load(tbl text, shape text, sz int, ndocs int) returns void language plpgsql as $$
begin
    case shape
    when 'plain' then
        execute format('create table %I (id int primary key, title text not null, updated_at timestamptz not null default now(), body text compression lz4 not null)', tbl);
        execute format('insert into %I (id, title, body) select d, ''Doc '' || d, bench.build_plain(%s, d) from generate_series(1, %s) d', tbl, sz, ndocs);
    when 'plain_pglz' then
        execute format('create table %I (id int primary key, title text not null, updated_at timestamptz not null default now(), body text not null)', tbl);
        execute format('insert into %I (id, title, body) select d, ''Doc '' || d, bench.build_plain(%s, d) from generate_series(1, %s) d', tbl, sz, ndocs);
    when 'a' then
        execute format('create table %I (id int primary key, title text not null, updated_at timestamptz not null default now(), body crdt.yseq compression lz4 not null)', tbl);
        execute format('insert into %I (id, title, body) select d, ''Doc '' || d, bench.build_a(%s, d) from generate_series(1, %s) d', tbl, sz, ndocs);
    when 'a_pglz' then
        execute format('create table %I (id int primary key, title text not null, updated_at timestamptz not null default now(), body crdt.yseq not null)', tbl);
        execute format('insert into %I (id, title, body) select d, ''Doc '' || d, bench.build_a(%s, d) from generate_series(1, %s) d', tbl, sz, ndocs);
    when 'b' then
        execute format('create table %I (id int primary key, title text not null, updated_at timestamptz not null default now(), body_doc text not null references crdt.ydoc_docs (uid))', tbl);
        execute format('insert into %I (id, title, body_doc) select d, ''Doc '' || d, bench.build_b(%s, d) from generate_series(1, %s) d', tbl, sz, ndocs);
    else
        raise exception 'unknown shape %', shape;
    end case;
end;
$$;

-- The relations a shape writes to: the documents table, and for ydoc_ every
-- crdt.ydoc_* table.
create function bench.rels(tbl text, shape text) returns regclass[] language sql stable as $$
    select case when shape like 'b%' then
        array[tbl::regclass] || (select array_agg(c.oid::regclass order by c.relname)
                                 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                                 where n.nspname = 'crdt' and c.relkind = 'r' and c.relname like 'ydoc\_%')
    else array[tbl::regclass] end $$;

-- Sizes and counters of a set of relations, summed. 'heap' is the main fork
-- plus FSM and VM; 'toast' is the TOAST relation with its index; 'idx' is the
-- table's own indexes. The *_live, *_dead and *_free columns are pgstattuple's
-- tuple_len, dead_tuple_len and free_space (a full scan; deep => false skips
-- them and the free space map). n_* are pg_stat_all_tables counters of the
-- tables, toast_* of their TOAST relations.
create function bench.measure(rels regclass[], deep boolean default true)
returns table (heap bigint, toast bigint, idx bigint, total bigint,
               heap_live bigint, heap_dead bigint, heap_free bigint,
               toast_live bigint, toast_dead bigint, toast_free bigint, fsm bigint,
               n_live bigint, n_dead bigint, toast_n_dead bigint, n_upd bigint, n_hot bigint,
               n_ins bigint, toast_n_ins bigint, av_heap bigint, av_toast bigint)
language plpgsql volatile as $$
declare
    r regclass;
    t oid;
    st record;
    tt record;
    p record;
begin
    perform pg_stat_clear_snapshot();
    heap := 0; toast := 0; idx := 0; total := 0;
    heap_live := 0; heap_dead := 0; heap_free := 0; toast_live := 0; toast_dead := 0; toast_free := 0; fsm := 0;
    n_live := 0; n_dead := 0; toast_n_dead := 0; n_upd := 0; n_hot := 0; n_ins := 0; toast_n_ins := 0; av_heap := 0; av_toast := 0;
    foreach r in array rels loop
        select c.reltoastrelid into t from pg_class c where c.oid = r;
        total := total + pg_total_relation_size(r);
        idx := idx + pg_indexes_size(r);
        if t <> 0 then toast := toast + pg_total_relation_size(t); end if;
        select * into st from pg_stat_all_tables s where s.relid = r;
        n_live := n_live + coalesce(st.n_live_tup, 0);
        n_dead := n_dead + coalesce(st.n_dead_tup, 0);
        n_upd := n_upd + coalesce(st.n_tup_upd, 0);
        n_hot := n_hot + coalesce(st.n_tup_hot_upd, 0);
        n_ins := n_ins + coalesce(st.n_tup_ins, 0);
        av_heap := av_heap + coalesce(st.autovacuum_count, 0);
        if t <> 0 then
            select * into tt from pg_stat_all_tables s where s.relid = t;
            toast_n_dead := toast_n_dead + coalesce(tt.n_dead_tup, 0);
            toast_n_ins := toast_n_ins + coalesce(tt.n_tup_ins, 0);
            av_toast := av_toast + coalesce(tt.autovacuum_count, 0);
        end if;
        if deep then
            select * into p from pgstattuple(r);
            heap_live := heap_live + p.tuple_len; heap_dead := heap_dead + p.dead_tuple_len; heap_free := heap_free + p.free_space;
            fsm := fsm + coalesce((select sum(avail) from pg_freespace(r)), 0);
            if t <> 0 then
                select * into p from pgstattuple(t);
                toast_live := toast_live + p.tuple_len; toast_dead := toast_dead + p.dead_tuple_len; toast_free := toast_free + p.free_space;
                fsm := fsm + coalesce((select sum(avail) from pg_freespace(t::regclass)), 0);
            end if;
        end if;
    end loop;
    heap := total - toast - idx;
    return next;
end;
$$;

-- PN-Counter helpers. A state with n replicas (ids user-000001 ...), a third
-- of them also in n, counts up to cmax.
create function bench.pn_state(n int, cmax bigint default 1000000) returns crdt.pn language sql volatile as $$
    select jsonb_build_object('t', 'pn', 'v', 1,
        'p', coalesce((select jsonb_object_agg('user-' || lpad(i::text, 6, '0'), 1 + floor(random() * cmax)::bigint)
                       from generate_series(1, n) i), '{}'::jsonb),
        'n', coalesce((select jsonb_object_agg('user-' || lpad(i::text, 6, '0'), 1 + floor(random() * cmax)::bigint)
                       from generate_series(1, n) i where i % 3 = 0), '{}'::jsonb))::crdt.pn $$;
