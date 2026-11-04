-- Goal: a state survives jsonb text -> crdt.pn -> text and the paths clients
-- use (a table column, json, a text parameter) with its meaning intact, and
-- the text form is canonical: equal states print the same text, whatever the
-- key order or spacing of the input.
\ir ../fixtures/gen.sql

select setseed(0.31);
create temp table cases as
select i, spec.rand_pn() as a, spec.rand_pn() as b from generate_series(1, 500) i;

create table stored (id int primary key, s crdt.pn);
insert into stored select i, a::text::crdt.pn from cases;

select tap.plan(9);

select tap.is((select count(*)::int from cases where a::text::crdt.pn::jsonb is distinct from a::jsonb), 0,
              'text -> crdt.pn -> jsonb is the same jsonb, 500 cases');
select tap.is((select count(*)::int from cases where crdt.pn_value(a::text::crdt.pn) is distinct from crdt.pn_value(a)), 0,
              'text -> crdt.pn keeps the value, 500 cases');
select tap.is((select count(*)::int from cases where a::json::jsonb::crdt.pn::jsonb is distinct from a::jsonb), 0,
              'crdt.pn -> json -> jsonb -> crdt.pn is the same jsonb, 500 cases');
select tap.is((select count(*)::int from cases c join stored s on s.id = c.i where s.s::text <> c.a::text), 0,
              'a crdt.pn column returns the text it was given, 500 cases');
select tap.is((select count(*)::int from cases where crdt.pn_merge(a, b)::text <> crdt.pn_merge(b, a)::text), 0,
              'the text of merge(a, b) and merge(b, a) is byte-identical (jsonb output is canonical), 500 cases');

select tap.is(
    '{ "n": {"a": 2},
       "p": {"b": 1, "a": 5},
       "v": 1, "t": "pn" }'::crdt.pn::text,
    '{"n": {"a": 2}, "p": {"a": 5, "b": 1}, "t": "pn", "v": 1}',
    'key order and whitespace of the input do not change the text output');
select tap.is(crdt.pn_value('{"t": "pn", "v": 1, "p": {"a": 9223372036854775807}, "n": {"a": 9223372036854775807}}'::text::crdt.pn),
              0::bigint, 'counts at the bigint maximum round-trip exactly (jsonb numbers are numeric)');
select tap.is(crdt.pn_value('{"t": "pn", "v": 1, "p": {"été \"x\"": 3}, "n": {}}'::text::crdt.pn), 3::bigint,
              'replica ids with escapes and non-ASCII characters round-trip');
select tap.is(
    (select crdt.pn_increment(s, 'été "x"', 1)::text from (select '{"t": "pn", "v": 1, "p": {"été \"x\"": 3}, "n": {}}'::text::crdt.pn s) x),
    '{"n": {}, "p": {"été \"x\"": 4}, "t": "pn", "v": 1}',
    'increment finds the entry of an escaped replica id');

select * from tap.finish();
