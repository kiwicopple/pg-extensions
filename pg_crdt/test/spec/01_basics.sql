-- Goal: the PN-Counter basics. Empty, increment, decrement, value, the
-- defaults, a negative amount rejected, and the crdt.pn domain rejecting
-- anything that is not a valid envelope (architecture.md sections 2 and 3).

select tap.plan(47);

-- empty
select tap.is(crdt.pn_empty()::jsonb, '{"t": "pn", "v": 1, "p": {}, "n": {}}'::jsonb,
              'pn_empty() is the empty envelope');
select tap.is(crdt.pn_value(crdt.pn_empty()), 0::bigint, 'the empty counter is 0');
select tap.is(pg_typeof(crdt.pn_empty())::text, 'crdt.pn', 'pn_empty() returns the crdt.pn domain');

-- increment
select tap.is(crdt.pn_increment(crdt.pn_empty(), 'a')::jsonb,
              '{"t": "pn", "v": 1, "p": {"a": 1}, "n": {}}'::jsonb,
              'pn_increment defaults to an amount of 1');
select tap.is(crdt.pn_increment(crdt.pn_empty(), 'a', 5)::jsonb,
              '{"t": "pn", "v": 1, "p": {"a": 5}, "n": {}}'::jsonb,
              'pn_increment by 5 sets p.a to 5');
select tap.is(crdt.pn_increment(crdt.pn_increment(crdt.pn_empty(), 'a', 5), 'a', 2)::jsonb,
              '{"t": "pn", "v": 1, "p": {"a": 7}, "n": {}}'::jsonb,
              'increments of one replica add up in its own entry');
select tap.is(crdt.pn_increment(crdt.pn_increment(crdt.pn_empty(), 'a', 5), 'b', 2)::jsonb,
              '{"t": "pn", "v": 1, "p": {"a": 5, "b": 2}, "n": {}}'::jsonb,
              'each replica has its own entry');
select tap.is(crdt.pn_increment(crdt.pn_empty(), 'a', 0)::jsonb, crdt.pn_empty()::jsonb,
              'an increment by 0 returns the state unchanged (no zero entry)');
select tap.is(crdt.pn_increment(null, 'a', 3)::jsonb,
              '{"t": "pn", "v": 1, "p": {"a": 3}, "n": {}}'::jsonb,
              'a null state counts as empty');
select tap.is(crdt.pn_increment(state => crdt.pn_empty(), replica => 'a', amount => 4)::jsonb,
              '{"t": "pn", "v": 1, "p": {"a": 4}, "n": {}}'::jsonb,
              'named arguments: state, replica, amount');

-- decrement
select tap.is(crdt.pn_decrement(crdt.pn_empty(), 'a')::jsonb,
              '{"t": "pn", "v": 1, "p": {}, "n": {"a": 1}}'::jsonb,
              'pn_decrement defaults to an amount of 1 and counts in n');
select tap.is(crdt.pn_decrement(crdt.pn_decrement(crdt.pn_empty(), 'a', 3), 'a', 4)::jsonb,
              '{"t": "pn", "v": 1, "p": {}, "n": {"a": 7}}'::jsonb,
              'decrements of one replica add up in its own n entry');
select tap.is(crdt.pn_decrement(null, 'a', 2)::jsonb,
              '{"t": "pn", "v": 1, "p": {}, "n": {"a": 2}}'::jsonb,
              'pn_decrement: a null state counts as empty');
select tap.is(crdt.pn_decrement(crdt.pn_empty(), 'a', 0)::jsonb, crdt.pn_empty()::jsonb,
              'a decrement by 0 returns the state unchanged');

-- value
select tap.is(crdt.pn_value('{"t": "pn", "v": 1, "p": {"a": 2, "b": 3}, "n": {"a": 1}}'), 4::bigint,
              'value is sum(p) - sum(n)');
select tap.is(crdt.pn_value(crdt.pn_decrement(crdt.pn_increment(crdt.pn_empty(), 'a', 2), 'b', 5)), -3::bigint,
              'value can be negative');
select tap.is(crdt.pn_value(null), null::bigint, 'pn_value(null) is null');
select tap.is(crdt.pn_value(crdt.pn_increment(crdt.pn_empty(), 'a', 9223372036854775806)), 9223372036854775806::bigint,
              'value is exact near the bigint limit');

-- errors: amounts and replicas
select tap.throws_ok($$ select crdt.pn_increment(crdt.pn_empty(), 'a', -1) $$, '22023',
                     'pn_increment rejects a negative amount');
select tap.throws_ok($$ select crdt.pn_decrement(crdt.pn_empty(), 'a', -1) $$, '22023',
                     'pn_decrement rejects a negative amount');
select tap.throws_ok($$ select crdt.pn_increment(crdt.pn_empty(), 'a', null) $$, '22004',
                     'pn_increment rejects a null amount');
select tap.throws_ok($$ select crdt.pn_increment(crdt.pn_empty(), null, 1) $$, '22004',
                     'pn_increment rejects a null replica');
select tap.throws_ok($$ select crdt.pn_increment(crdt.pn_empty(), '', 1) $$, '22023',
                     'pn_increment rejects an empty replica id');
select tap.throws_ok($$ select crdt.pn_decrement(crdt.pn_empty(), '', 1) $$, '22023',
                     'pn_decrement rejects an empty replica id');
-- replica keys: any non-empty text; `:` separates an owner from a device
-- suffix (<owner>:<device>), so neither side may be empty
select tap.throws_ok($$ select crdt.pn_increment(crdt.pn_empty(), 'abc:', 1) $$, '22023',
                     'pn_increment rejects a key with an empty device suffix (abc:)');
select tap.throws_ok($$ select crdt.pn_increment(crdt.pn_empty(), ':x', 1) $$, '22023',
                     'pn_increment rejects a key with an empty owner (:x)');
select tap.throws_ok($$ select crdt.pn_decrement(crdt.pn_empty(), ':', 1) $$, '22023',
                     'pn_decrement rejects the key :');
select tap.is(crdt.pn_decrement(crdt.pn_increment(crdt.pn_increment(crdt.pn_increment(crdt.pn_increment(
                  crdt.pn_empty(), 'abc:phone'), 'abc:phone:2'), 'ada@example.com'), '42'), 'Ünïcode name')::jsonb,
              '{"t": "pn", "v": 1, "p": {"abc:phone": 1, "abc:phone:2": 1, "ada@example.com": 1, "42": 1}, "n": {"Ünïcode name": 1}}'::jsonb,
              'replica keys are generic text: devices (abc:phone, abc:phone:2), emails, integers as text, any characters');
select tap.throws_ok($$ select crdt.pn_increment(crdt.pn_increment(crdt.pn_empty(), 'a', 9223372036854775807), 'a', 1) $$,
                     '22003', 'an entry that would pass the bigint limit raises numeric_value_out_of_range');

-- the domain accepts valid envelopes
select tap.is('{"t": "pn", "v": 1, "p": {"a": 1}, "n": {"b": 2}}'::crdt.pn::jsonb,
              '{"t": "pn", "v": 1, "p": {"a": 1}, "n": {"b": 2}}'::jsonb, 'the domain accepts a valid envelope');
select tap.is(null::crdt.pn, null::crdt.pn, 'the domain accepts null (a nullable column)');
select tap.is(crdt.pn_is_valid('{"t": "pn", "v": 1, "p": {"a": 0, "b": 9223372036854775807}, "n": {}}'), true,
              'pn_is_valid: zero and the bigint maximum are valid counts');
select tap.is(crdt.pn_is_valid(null), null::boolean, 'pn_is_valid(null) is null');

-- the domain (the envelope) rejects these with check_violation; pn_is_valid is false
create temp table bad_envelopes (label text, value jsonb);
insert into bad_envelopes values
    ('a JSON array',                  '[]'),
    ('a JSON string',                 '"pn"'),
    ('a wrong type tag',              '{"t": "awset", "v": 1, "p": {}, "n": {}}'),
    ('a type tag inside an array',    '{"t": ["pn"], "v": 1, "p": {}, "n": {}}'),
    ('a missing type tag',            '{"v": 1, "p": {}, "n": {}}'),
    ('an unknown version',            '{"t": "pn", "v": 2, "p": {}, "n": {}}'),
    ('a missing n map',               '{"t": "pn", "v": 1, "p": {}}'),
    ('p as an array',                 '{"t": "pn", "v": 1, "p": [], "n": {}}'),
    ('an unknown top-level key',      '{"t": "pn", "v": 1, "p": {}, "n": {}, "x": 1}');

select tap.throws_ok(format('select %L::crdt.pn', value), '23514', 'the domain rejects ' || label)
from bad_envelopes order by label;
select tap.is((select count(*)::int from bad_envelopes where crdt.pn_is_valid(value)), 0,
              'pn_is_valid is false for every envelope the domain rejects');

-- entries: the domain does not check them (it must stay O(1) in the number of
-- replicas); pn_is_valid does, and pn_apply_delta enforces it (30_apply_delta)
create temp table bad_entries (label text, value jsonb);
insert into bad_entries values
    ('a count that is a string',      '{"t": "pn", "v": 1, "p": {"a": "1"}, "n": {}}'),
    ('a negative count',              '{"t": "pn", "v": 1, "p": {}, "n": {"a": -1}}'),
    ('a fractional count',            '{"t": "pn", "v": 1, "p": {"a": 1.5}, "n": {}}'),
    ('a count past the bigint limit', '{"t": "pn", "v": 1, "p": {"a": 9223372036854775808}, "n": {}}'),
    ('a null count',                  '{"t": "pn", "v": 1, "p": {"a": null}, "n": {}}');
select tap.is((select count(*)::int from bad_entries where not crdt.pn_is_valid(value)), 5,
              'pn_is_valid is false for a string, negative, fractional, too large or null count');
select tap.is((select count(*)::int from bad_entries where value::crdt.pn is not null), 5,
              'the domain accepts them (it checks the envelope only)');
select tap.throws_ok($$ select crdt.pn_value('{"t": "pn", "v": 1, "p": {"a": "1"}, "n": {}}') $$, null,
                     'pn_value raises on a count that is not a number');
select tap.throws_ok($$ select crdt.pn_increment('{"t": "pn", "v": 1, "p": {"a": "x"}, "n": {}}', 'a') $$, null,
                     'pn_increment raises on a count that is not a number');

select * from tap.finish();
