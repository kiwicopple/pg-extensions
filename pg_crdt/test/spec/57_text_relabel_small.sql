-- Goal: regression for the adversarial review of 2026-11-05 (t6): with
-- shrunk tuning constants (run cap 3, blocks of 4 rows, labels within 2^16,
-- step 16, gap 2) relabels happen all the time, and moving block labels
-- must never collide on the (doc, lo) primary key. Random edits against a
-- text model, with compactions. The constants are redefined before anything
-- else runs in this database (cached plans would keep the old ones).
\i :ext_dir/test/lib/text-helpers.sql
create or replace function crdt._ydoc_run_cap() returns integer language sql immutable parallel safe return 3;
create or replace function crdt._ydoc_block_max() returns integer language sql immutable parallel safe return 4;
create or replace function crdt._ydoc_label_bound() returns bigint language sql immutable parallel safe return 65536;
create or replace function crdt._ydoc_label_step() returns bigint language sql immutable parallel safe return 16;
create or replace function crdt._ydoc_label_gap() returns bigint language sql immutable parallel safe return 2;
select crdt.ydoc_create() as rl \gset
select set_config('ydoc.rl', :'rl', false) \g /dev/null
create temp table rlres (ok boolean, msg text);
do $$
declare d bigint := current_setting('ydoc.rl')::bigint; model text := ''; p int; n int;
begin
    perform setseed(0.42);
    for i in 1 .. 1500 loop
        if random() < 0.7 or length(model) = 0 then
            p := case when random() < 0.6 then length(model) / 2 else floor(random() * (length(model) + 1))::int end;
            perform crdt.ydoc_insert(d, p, 'xy', 'r' || (i % 3));
            model := left(model, p) || 'xy' || substr(model, p + 1);
        else
            p := floor(random() * length(model))::int; n := least(3, length(model) - p);
            perform crdt.ydoc_delete(d, p, n, 'r');
            model := left(model, p) || substr(model, p + n + 1);
        end if;
        if i % 97 = 0 then perform crdt.ydoc_compact(d); end if;
    end loop;
    insert into rlres values (crdt.ydoc_value(d) = model, pg_temp.ydoc_check(d));
exception when others then
    insert into rlres values (false, sqlstate || ' ' || sqlerrm);
end $$;

select tap.plan(1);
select tap.is((select ok::text || msg from rlres), 'true', 'relabels with shrunk constants never collide on block labels; text equals the model; invariants hold');
select * from tap.finish();
