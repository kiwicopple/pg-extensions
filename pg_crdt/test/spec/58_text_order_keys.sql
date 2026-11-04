-- Goal: the order labels (a server-local cache of the YjsMod order) stay
-- correct. _ydoc_label returns a label strictly between its bounds or null.
-- Edit patterns that exhaust the gaps between labels at one spot (typing
-- backward and forward at a fixed place by alternating replicas, so runs
-- never extend; deleting a run char by char from either end; prepending)
-- force relabels, and the text still equals a plain-text model, with unique
-- labels and correct blocks. Thousands of random edits match the model at
-- every check, and the same ops replayed shuffled give the same text.
\i :ext_dir/test/lib/text-helpers.sql

-- 1. _ydoc_label
create temp table lb (lo bigint, hi bigint, k bigint);
select setseed(0.7);
insert into lb (lo, hi)
select least(a, b), greatest(a, b) from (
    select (random() * 2 - 1) * crdt._ydoc_label_bound() a, (random() * 2 - 1) * crdt._ydoc_label_bound() b
    from generate_series(1, 2000)) x where a <> b;
insert into lb (lo, hi) values (null, null), (5, null), (null, 5), (5, 6), (5, 7), (crdt._ydoc_label_bound() - 1, null),
    (crdt._ydoc_label_bound(), null), (null, -crdt._ydoc_label_bound()), (-crdt._ydoc_label_bound(), crdt._ydoc_label_bound());
update lb set k = crdt._ydoc_label(lo, hi);

-- 2. adversarial patterns against a model
create temp table pat (name text, doc bigint, model text);
create function pg_temp.run(name text, n int) returns void language plpgsql as $$
declare
    d bigint := crdt.ydoc_create();
    model text := '';
    p int;
begin
    if name = 'backward at a fixed spot' then
        perform crdt.ydoc_insert(d, 0, '[]', 'base'); model := '[]';
        for i in 1..n loop
            perform crdt.ydoc_insert(d, 1, chr(97 + i % 26), 'r' || i % 2);
            model := '[' || chr(97 + i % 26) || substr(model, 2);
        end loop;
    elsif name = 'forward at a fixed spot' then
        perform crdt.ydoc_insert(d, 0, '[]', 'base'); model := '[]';
        for i in 1..n loop
            perform crdt.ydoc_insert(d, i, chr(97 + i % 26), 'r' || i % 2);
            model := left(model, i) || chr(97 + i % 26) || substr(model, i + 1);
        end loop;
    elsif name = 'prepend' then
        for i in 1..n loop
            perform crdt.ydoc_insert(d, 0, chr(97 + i % 26), 'r' || i % 2);
            model := chr(97 + i % 26) || model;
        end loop;
    elsif name = 'delete from the left, retype' then
        for i in 1..n / 20 loop
            p := floor(random() * (length(model) + 1))::int;
            perform crdt.ydoc_insert(d, p, repeat('x', 20), 'r');
            model := left(model, p) || repeat('x', 20) || substr(model, p + 1);
            for j in 1..19 loop
                perform crdt.ydoc_delete(d, p, 1, 'r');
                model := left(model, p) || substr(model, p + 2);
                perform crdt.ydoc_insert(d, p, 'y', 'q' || j % 2);
                model := left(model, p) || 'y' || substr(model, p + 1);
            end loop;
        end loop;
    elsif name = 'backspace, retype' then
        perform crdt.ydoc_insert(d, 0, 'start', 'r'); model := 'start';
        for i in 1..n / 4 loop
            perform crdt.ydoc_insert(d, length(model), 'abc', 'r');
            perform crdt.ydoc_delete(d, length(model) + 1, 2, 'r');
            perform crdt.ydoc_insert(d, length(model) + 1, 'z', 'q' || i % 2);
            model := model || 'az';
        end loop;
    end if;
    insert into pat values (name, d, model);
end;
$$;
select pg_temp.run(n, 2000) from unnest(array['backward at a fixed spot', 'forward at a fixed spot', 'prepend',
                                              'delete from the left, retype', 'backspace, retype']) n;

-- 3. random edits against a model
create temp table model_run (step int, ok boolean, msg text);
create temp table gen_ops (n serial, op jsonb);
select setseed(0.3);
do $$
declare
    d bigint := crdt.ydoc_create();
    model text := '';
    rep text;
    pos int;
    k int;
    s text;
    op jsonb;
begin
    perform set_config('ydoc.test_doc', d::text, false);
    for step in 1..4000 loop
        rep := (array['r1', 'r2', 'r3', 'r4'])[1 + floor(random() * 4)::int];
        if length(model) > 0 and random() < 0.4 then
            pos := floor(random() * length(model))::int;
            k := least(length(model) - pos, 1 + floor(random() * 3)::int);
            op := crdt.ydoc_delete(d, pos, k, rep);
            model := left(model, pos) || substr(model, pos + k + 1);
        else
            pos := floor(random() * (length(model) + 1))::int;
            s := substr('qwertyuiop😀€é', 1 + floor(random() * 12)::int, 1 + floor(random() * 2)::int);
            op := crdt.ydoc_insert(d, pos, s, rep);
            model := left(model, pos) || s || substr(model, pos + 1);
        end if;
        insert into gen_ops (op) values (op);
        if step % 50 = 0 then
            insert into model_run values (step, crdt.ydoc_value(d) = model, pg_temp.ydoc_check(d));
        end if;
    end loop;
    insert into model_run values (-1, crdt.ydoc_value(d) = model and crdt.ydoc_length(d) = length(model), pg_temp.ydoc_check(d));
end;
$$;
select current_setting('ydoc.test_doc')::bigint as d \gset
select crdt.ydoc_create() as z \gset
select pg_temp.merge_all(:z, (select jsonb_agg(op order by random()) from gen_ops)) \g /dev/null

select tap.plan(10);
select tap.is((select count(*)::int from lb where not ((lo is null or lo < k) and (hi is null or k < hi))), 0,
              '_ydoc_label: lo < label < hi for 2,000 random pairs and edge cases');
select tap.is((select count(*)::int from lb where k is null), 4, 'null exactly when there is no room (adjacent, at the bounds)');
select tap.is((select string_agg(name, ', ') from pat where crdt.ydoc_value(doc) is distinct from model), null,
              'adversarial patterns (2,000 edits each): text equals the model');
select tap.is((select string_agg(name || ': ' || pg_temp.ydoc_check(doc), '; ') from pat where pg_temp.ydoc_check(doc) <> ''), null,
              'adversarial patterns: unique labels, blocks and counters correct');
select tap.ok((select bool_and(ord between -crdt._ydoc_label_bound() and crdt._ydoc_label_bound()) from crdt.ydoc_items), 'labels within bounds');
select tap.is((select count(*)::int from model_run where not ok or msg <> ''), 0, '4,000 random edits: text equals the model and invariants hold at every check');
select tap.ok((select count(*) from crdt.ydoc_items where doc = :d) > 1500, 'many rows (run splits)');
select tap.ok((select count(*) from crdt.ydoc_blocks where doc = :d) > 3, 'several blocks (block splits)');
select tap.is(crdt.ydoc_value(:z), crdt.ydoc_value(:d), 'the generated ops replayed in a shuffled order give the same text');
select tap.is(pg_temp.ydoc_check(:z), '', 'invariants hold in the replay');

select * from tap.finish();
