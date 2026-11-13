-- Goal: replica keys. The same cases as the JS reference
-- (experiments/text-ref/test.mjs) read test/fixtures/replica-keys.json: a key
-- is an id without ":" or <id>:<device> with a non-empty device (which may
-- contain ":"), at most 256 bytes. Every case is checked on the local edit
-- (ydoc_insert), the trusted merge (ydoc_merge) and the untrusted path
-- (ydoc_apply, as the owner of the key): accepted exactly when the fixture
-- says so, and refused with 22023 otherwise.
\i :ext_dir/test/lib/text-helpers.sql
\set keys_json `cat :ext_dir/test/fixtures/replica-keys.json`

create temp table cases as
select n, k.key, c.value ->> 'ok' = 'true' as ok, c.value ->> 'why' as why
from jsonb_array_elements(:'keys_json'::jsonb -> 'cases') with ordinality c(value, n),
     lateral (select case jsonb_typeof(c.value -> 'key')
                       when 'string' then c.value ->> 'key'
                       else (c.value -> 'key' ->> 'prefix') || repeat(c.value -> 'key' ->> 'repeat', (c.value -> 'key' ->> 'times')::int)
                     end as key) k;

create temp table outcome (n int, path text, state text);
do $$
declare
    c record;
    d text;
    st text;
begin
    for c in select * from cases order by n loop
        -- local edit
        d := crdt.ydoc_create();
        begin
            perform crdt.ydoc_insert(d, 0, 'x', c.key);
            st := 'ok';
        exception when others then st := sqlstate;
        end;
        insert into outcome values (c.n, 'insert', st);
        if st = 'ok' and crdt.ydoc_version(d) <> jsonb_build_object(c.key, 1) then
            update outcome set state = 'wrong version' where n = c.n and path = 'insert';
        end if;

        -- trusted merge of an op that names the key
        d := crdt.ydoc_create();
        begin
            perform crdt.ydoc_merge(d, jsonb_build_object('i', jsonb_build_array(jsonb_build_array(c.key, 1, null, null, 'x')), 'd', '[]'::jsonb));
            st := 'ok';
        exception when others then st := sqlstate;
        end;
        insert into outcome values (c.n, 'merge', st);
        if st = 'ok' and crdt.ydoc_value(d) <> 'x' then
            update outcome set state = 'wrong text' where n = c.n and path = 'merge';
        end if;

        -- untrusted path, as the owner of the key (the part before the first ":")
        d := crdt.ydoc_create();
        begin
            perform crdt.ydoc_apply(d, jsonb_build_object('v', '{}'::jsonb, 'd', '[]'::jsonb,
                       'i', jsonb_build_array(jsonb_build_array(c.key, 1, null, null, 'x'))), split_part(c.key, ':', 1));
            st := 'ok';
        exception when others then st := sqlstate;
        end;
        insert into outcome values (c.n, 'apply', st);
        if st = 'ok' and crdt.ydoc_value(d) <> 'x' then
            update outcome set state = 'wrong text' where n = c.n and path = 'apply';
        end if;
    end loop;
end;
$$;

select tap.plan(8);
select tap.ok((select count(*) from cases where ok) >= 10 and (select count(*) from cases where not ok) >= 6, 'the fixture has accepted and refused keys');
select tap.is((select string_agg(o.n || ' ' || o.state, ', ' order by o.n) from outcome o join cases c using (n) where o.path = 'insert' and c.ok and o.state <> 'ok'),
              null, 'ydoc_insert accepts every valid key');
select tap.is((select string_agg(o.n || ' ' || o.state, ', ' order by o.n) from outcome o join cases c using (n) where o.path = 'insert' and not c.ok and o.state <> '22023'),
              null, 'ydoc_insert refuses every invalid key with 22023');
select tap.is((select string_agg(o.n || ' ' || o.state, ', ' order by o.n) from outcome o join cases c using (n) where o.path = 'merge' and c.ok and o.state <> 'ok'),
              null, 'ydoc_merge accepts every valid key');
select tap.is((select string_agg(o.n || ' ' || o.state, ', ' order by o.n) from outcome o join cases c using (n) where o.path = 'merge' and not c.ok and o.state <> '22023'),
              null, 'ydoc_merge refuses every invalid key with 22023');
select tap.is((select string_agg(o.n || ' ' || o.state, ', ' order by o.n) from outcome o join cases c using (n) where o.path = 'apply' and c.ok and o.state <> 'ok'),
              null, 'ydoc_apply accepts every valid key as its owner');
select tap.is((select string_agg(o.n || ' ' || o.state, ', ' order by o.n) from outcome o join cases c using (n) where o.path = 'apply' and not c.ok and o.state <> '22023'),
              null, 'ydoc_apply refuses every invalid key with 22023');
select tap.is((select count(*)::int from outcome), (select count(*)::int * 3 from cases), 'every case ran on every path');
select * from tap.finish();
