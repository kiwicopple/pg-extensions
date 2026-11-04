-- Goal: ydoc_compact merges rows without changing anything a reader or a
-- peer can see. Two documents receive the same random edits (local
-- inserts and deletes, several replicas, backspace bursts); one is
-- compacted every 200 edits with horizon = now, the other never. They keep
-- the same text, version and ops_since text, the compacted one has far fewer
-- rows and valid invariants, and edits after compaction (which split merged
-- rows) still match a model. Three-way ydoc_set: a base at or after the
-- horizon gives the same result as on the uncompacted twin; an older base is
-- refused (22023). A horizon keeps newer tombstones apart.
\i :exp_dir/test/lib/helpers.sql

select crdt.ydoc_create() as c, crdt.ydoc_create() as t \gset
select set_config('ydoc.c', :'c', false), set_config('ydoc.t', :'t', false) \g /dev/null
create temp table chk (step int, same boolean, inv text);
create temp table cnt (removed int);
select setseed(0.11);
do $$
declare
    c bigint := current_setting('ydoc.c')::bigint;
    t bigint := current_setting('ydoc.t')::bigint;
    model text := '';
    pos int; k int; s text; rep text;
begin
    for step in 1..3000 loop
        rep := (array['ann', 'bo', 'cy'])[1 + floor(random() * 3)::int];
        if length(model) > 10 and random() < 0.3 then
            -- a burst of backspaces at one place
            pos := 1 + floor(random() * (length(model) - 1))::int;
            for b in 1..least(pos, 1 + floor(random() * 5)::int) loop
                perform crdt.ydoc_delete(c, pos - 1, 1, rep);
                perform crdt.ydoc_delete(t, pos - 1, 1, rep);
                model := left(model, pos - 1) || substr(model, pos + 1);
                pos := pos - 1;
            end loop;
        else
            pos := floor(random() * (length(model) + 1))::int;
            s := substr('typing😀 text€ ', 1 + floor(random() * 10)::int, 1 + floor(random() * 4)::int);
            perform crdt.ydoc_insert(c, pos, s, rep);
            perform crdt.ydoc_insert(t, pos, s, rep);
            model := left(model, pos) || s || substr(model, pos + 1);
        end if;
        if step % 200 = 0 then
            insert into cnt select crdt.ydoc_compact(c);
            insert into chk values (step, crdt.ydoc_value(c) = model and crdt.ydoc_value(t) = model, pg_temp.ydoc_check(c));
        end if;
    end loop;
end $$;

-- ops_since text of the compacted doc rebuilds the same text in a fresh doc
select crdt.ydoc_create() as f \gset
select crdt.ydoc_merge(:f, crdt.ydoc_ops_since(:c, '{}')) \g /dev/null
select crdt.ydoc_value(:c) as text_at_f, crdt.ydoc_version(:c) = crdt.ydoc_version(:t) as same_vv,
       (select count(*) from crdt.ydoc_items where doc = :c) as rows_c, (select count(*) from crdt.ydoc_items where doc = :t) as rows_t \gset

-- three-way set across a compaction
select crdt.ydoc_base(:c) as base_c, crdt.ydoc_base(:t) as base_t, crdt.ydoc_value(:c) as text0 \gset
select crdt.ydoc_compact(:c) \g /dev/null
select crdt.ydoc_base(:c) as base_c2, crdt.ydoc_base(:t) as base_t2 \gset
select crdt.ydoc_insert(:c, 0, 'HEAD ', 'zed') \g /dev/null
select crdt.ydoc_insert(:t, 0, 'HEAD ', 'zed') \g /dev/null
select crdt.ydoc_delete(:c, 5, 3, 'zed') \g /dev/null
select crdt.ydoc_delete(:t, 5, 3, 'zed') \g /dev/null
-- compact again with the horizon at base_c2: base_c2 stays usable
select crdt.ydoc_compact(:c, (:'base_c2'::jsonb ->> 'g')::bigint) \g /dev/null
select crdt.ydoc_set(:c, :'text0' || ' TAIL', 'ann', :'base_c2') \g /dev/null
select crdt.ydoc_set(:t, :'text0' || ' TAIL', 'ann', :'base_t2') \g /dev/null

-- horizon: tombstones stamped after it stay apart
select crdt.ydoc_create() as h \gset
select crdt.ydoc_insert(:h, 0, 'abcdef', 'r') \g /dev/null
select crdt.ydoc_base(:h) as hbase0 \gset
select crdt.ydoc_delete(:h, 5, 1, 'r') \g /dev/null
select crdt.ydoc_delete(:h, 4, 1, 'r') \g /dev/null
select (crdt.ydoc_base(:h) ->> 'g')::bigint as hg \gset
select crdt.ydoc_delete(:h, 3, 1, 'r') \g /dev/null
select crdt.ydoc_delete(:h, 2, 1, 'r') \g /dev/null
select crdt.ydoc_compact(:h, :hg) as removed_h \gset

select tap.plan(13);
select tap.is((select count(*)::int from chk where not same or inv <> ''), 0, '3,000 edits, compacted every 200: text equals the model and the twin, invariants hold');
select tap.ok(:'same_vv'::boolean, 'same version vector as the uncompacted twin');
select tap.ok((select sum(removed) from cnt) > 0, 'compaction removed rows');
select tap.ok(:rows_c < :rows_t, format('compacted doc has fewer rows than its twin (%s against %s)', :rows_c, :rows_t));
select tap.is((select count(*)::int from crdt.ydoc_items where doc = :c and del_gen is not null) <
              (select count(*)::int from crdt.ydoc_items where doc = :t and del_gen is not null), true, 'fewer tombstone rows');
select tap.is(crdt.ydoc_value(:f), :'text_at_f'::text, 'ops_since of the compacted doc rebuilds the text');
select tap.is(crdt.ydoc_value(:c), crdt.ydoc_value(:t), 'three-way set with a base at the horizon (after edits and another compaction): same result as the twin');
select tap.is(pg_temp.ydoc_check(:c), '', 'invariants hold after edits and a set on merged rows');
select tap.throws_ok(format('select crdt.ydoc_set(%s, %L, %L, %L)', :h, 'x', 'ann', :'hbase0'), '22023', 'a base older than the last compaction is refused');
select tap.lives_ok(format('select crdt.ydoc_set(%s, %L, %L)', :c, crdt.ydoc_value(:c::bigint) || '!', 'ann'), 'two-way set still works');
select tap.is(:removed_h, 1, 'horizon: the two tombstones stamped at or before it merge, the two after it do not');
select tap.is((select count(*)::int from crdt.ydoc_items where doc = :h), 4, 'rows: abc, e+f, d, c');
select tap.throws_ok(format('select crdt.ydoc_compact(%s, %s)', :h, 999), '22023', 'a horizon past the write counter is refused');

select * from tap.finish();
