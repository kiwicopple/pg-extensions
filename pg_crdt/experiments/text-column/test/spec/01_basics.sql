-- Goal: the yseq_ API on small documents (research/text.md, "Required
-- behaviour"): empty, value, length, version, insert, delete, set; null
-- arguments; positions out of range; malformed replica keys; the domain's
-- envelope check; set() makes one delete and one insert.

select tap.plan(43);

-- empty
select tap.is(crdt.yseq_value(crdt.yseq_empty()), '', 'empty: value is the empty string');
select tap.is(crdt.yseq_length(crdt.yseq_empty()), 0, 'empty: length 0');
select tap.is(crdt.yseq_version(crdt.yseq_empty()), '{}'::jsonb, 'empty: version {}');
select tap.ok(crdt.yseq_is_valid(crdt.yseq_empty()), 'empty: valid');
select tap.is(crdt.yseq_value(null), null, 'value(null) is null');

-- insert, delete
select crdt.yseq_insert(crdt.yseq_empty(), 0, 'Hello', 'alice') as s1 \gset
select tap.is(crdt.yseq_value(:'s1'), 'Hello', 'insert into empty');
select tap.is(crdt.yseq_value(crdt.yseq_insert(:'s1', 5, ' world', 'alice')), 'Hello world', 'insert at the end');
select tap.is(crdt.yseq_value(crdt.yseq_insert(:'s1', 0, '>> ', 'bob')), '>> Hello', 'insert at the start');
select tap.is(crdt.yseq_value(crdt.yseq_insert(:'s1', 2, 'XY', 'bob')), 'HeXYllo', 'insert in the middle');
select tap.is(crdt.yseq_value(crdt.yseq_insert(null, 0, 'a', 'alice')), 'a', 'a null state counts as empty');
select tap.is(crdt.yseq_insert(:'s1', 2, '', 'bob')::jsonb, :'s1'::jsonb, 'inserting empty text is a no-op');
select tap.is(crdt.yseq_value(crdt.yseq_delete(:'s1', 1, 3, 'bob')), 'Ho', 'delete from the middle');
select tap.is(crdt.yseq_value(crdt.yseq_delete(:'s1', 0, 5, 'bob')), '', 'delete everything');
select tap.is(crdt.yseq_delete(:'s1', 2, 0, 'bob')::jsonb, :'s1'::jsonb, 'deleting 0 characters is a no-op');
select tap.is(crdt.yseq_length(crdt.yseq_delete(:'s1', 1, 3, 'bob')), 2, 'length counts visible characters');
select tap.is(crdt.yseq_version(crdt.yseq_insert(crdt.yseq_insert(:'s1', 2, 'XY', 'bob'), 0, 'z', 'carol:phone')),
              '{"alice": 5, "bob": 2, "carol:phone": 1}'::jsonb, 'version counts characters per replica key');
select tap.is(crdt.yseq_version(crdt.yseq_delete(:'s1', 1, 3, 'bob')), '{"alice": 5}'::jsonb, 'deletes do not change the version');

-- typing on extends one run; tombstones keep no text
select tap.is((select jsonb_array_length(s -> 'm') from (select crdt.yseq_insert(crdt.yseq_insert(crdt.yseq_insert(:'s1', 5, '!', 'alice'), 6, '!', 'alice'), 7, '?', 'alice') s) z),
              1, 'typing on at the end of one''s own run: still one chunk');
select tap.is((select s -> 'm' ->> 0 from (select crdt.yseq_insert(crdt.yseq_insert(:'s1', 5, '!', 'alice'), 6, '!', 'alice') s) z),
              '{1,1,7,0,0,0,0}', 'and one run of 7');
select tap.is((select s -> 's' from (select crdt.yseq_delete(:'s1', 1, 3, 'bob') s) z), '["Ho"]'::jsonb, 'tombstone text is not stored');

-- set
select tap.is(crdt.yseq_value(crdt.yseq_set(:'s1', 'Help!', 'bob')), 'Help!', 'set: new text');
select tap.is(crdt.yseq_set(:'s1', 'Hello', 'bob')::jsonb, :'s1'::jsonb, 'set to the same text is a no-op');
select tap.is(crdt.yseq_value(crdt.yseq_set(null, 'abc', 'bob')), 'abc', 'set on null');
select tap.is(crdt.yseq_value(crdt.yseq_set(:'s1', '', 'bob')), '', 'set to empty');
select tap.is(crdt.yseq_diff(:'s1', crdt.yseq_set(:'s1', 'Help!', 'bob')),
              '{"i": [["bob", 1, ["alice", 3], ["alice", 4], "p!"]], "d": [["alice", 4, 2]]}'::jsonb,
              'set Hello -> Help!: keeps the common prefix, one delete and one insert');
select tap.is(crdt.yseq_diff(:'s1', crdt.yseq_set(:'s1', 'Hello, Hello', 'bob')),
              '{"i": [["bob", 1, ["alice", 5], null, ", Hello"]], "d": []}'::jsonb,
              'set with only an append: one insert at the end');
select tap.is(crdt.yseq_diff(:'s1', crdt.yseq_set(:'s1', 'Jello', 'bob')),
              '{"i": [["bob", 1, null, ["alice", 1], "J"]], "d": [["alice", 1, 1]]}'::jsonb,
              'set replacing the first character');

-- set with base: the diff is taken against the text the editor loaded
select crdt.yseq_set(:'s1', 'Hello there', 'alice') as s1a \gset
select tap.is(crdt.yseq_set(:'s1', 'Help!', 'bob', base => :'s1')::jsonb, crdt.yseq_set(:'s1', 'Help!', 'bob')::jsonb,
              'set with base = state is plain set');
select tap.is(crdt.yseq_value(crdt.yseq_set(:'s1a', 'Jello', 'bob', base => :'s1')), 'Jello there',
              'set with an older base keeps the other writer''s change');
select tap.is(crdt.yseq_value(crdt.yseq_set(:'s1a', 'Hello', 'bob')), 'Hello',
              'without base the same save reverts it');
select tap.is(crdt.yseq_value(crdt.yseq_set(:'s1a', 'Hello!', 'alice', base => :'s1')), 'Hello there!',
              'the same replica saving twice from one base: the second save gets fresh ids');

-- errors
select tap.throws_ok($$select crdt.yseq_insert(crdt.yseq_empty(), 1, 'a', 'alice')$$, '22023', 'insert past the end: 22023');
select tap.throws_ok($$select crdt.yseq_insert(crdt.yseq_empty(), -1, 'a', 'alice')$$, '22023', 'negative position: 22023');
select tap.throws_ok(format('select crdt.yseq_delete(%L, 3, 3, %L)', :'s1', 'alice'), '22023', 'delete past the end: 22023');
select tap.throws_ok(format('select crdt.yseq_insert(%L, 0, %L, null)', :'s1', 'a'), '22004', 'null replica: 22004');
select tap.throws_ok(format('select crdt.yseq_insert(%L, null, %L, %L)', :'s1', 'a', 'alice'), '22004', 'null position: 22004');
select tap.throws_ok(format('select crdt.yseq_set(%L, null, %L)', :'s1', 'alice'), '22004', 'set to null: 22004');
select tap.throws_ok(format('select crdt.yseq_insert(%L, 0, %L, %L)', :'s1', 'a', 'al:'), '22023', 'malformed replica key ''al:'': 22023');
select tap.throws_ok(format('select crdt.yseq_set(%L, %L, %L)', :'s1', 'a', ''), '22023', 'empty replica key: 22023');

-- the domain checks the envelope
select tap.throws_ok($$select '{"t": "yseq", "v": 1}'::crdt.yseq$$, '23514', 'domain: missing keys rejected');
select tap.throws_ok($$select '{"t": "yseq", "v": 2, "r": [], "c": [], "n": [], "s": [], "m": [], "p": [], "x": []}'::crdt.yseq$$, '23514', 'domain: another version rejected');
select tap.throws_ok($$select '{"t": "yseq", "v": 1, "r": [], "c": [], "n": [], "s": "abc", "m": [], "p": [], "x": []}'::crdt.yseq$$, '23514', 'domain: s must be an array');
select tap.ok(not crdt.yseq_is_valid('{"t": "yseq", "v": 1, "r": ["a"], "c": [3], "n": [3], "s": ["abcd"], "m": ["{1,1,3,0,0,0,0}"], "p": [], "x": []}'),
              'yseq_is_valid: rejects chunk text that does not match its runs');
select * from tap.finish();
