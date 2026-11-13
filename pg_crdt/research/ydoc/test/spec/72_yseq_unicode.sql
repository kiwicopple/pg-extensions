-- Goal: positions and lengths count code points, not bytes or UTF-16 units
-- (research/text.md, "Ops"). Non-BMP characters, combining marks and ZWJ
-- sequences are several code points; set() never splits a code point even
-- when old and new share leading UTF-8 bytes; ops carry text unchanged.

select tap.plan(13);

select crdt.yseq_insert(crdt.yseq_empty(), 0, 'a😀b', 'alice') as s1 \gset
select tap.is(crdt.yseq_length(:'s1'), 3, 'a😀b has length 3 (code points; UTF-16 would be 4)');
select tap.is(crdt.yseq_value(crdt.yseq_insert(:'s1', 2, '日', 'bob')), 'a😀日b', 'insert after a non-BMP character');
select tap.is(crdt.yseq_value(crdt.yseq_delete(:'s1', 1, 1, 'bob')), 'ab', 'delete one non-BMP character');

select crdt.yseq_insert(crdt.yseq_empty(), 0, 'e' || U&'\0301' || 'x', 'alice') as s2 \gset
select tap.is(crdt.yseq_length(:'s2'), 3, 'e + combining acute is 2 code points');
select tap.is(crdt.yseq_value(crdt.yseq_delete(:'s2', 1, 1, 'bob')), 'ex', 'deleting the combining mark alone leaves the base letter');

select tap.is(crdt.yseq_length(crdt.yseq_insert(crdt.yseq_empty(), 0, '👨' || U&'\200D' || '👩', 'a')), 3, 'a ZWJ sequence is 3 code points');

-- set across characters with a common lead byte: é (C3 A9) -> è (C3 A8)
select tap.is(crdt.yseq_diff(crdt.yseq_insert(crdt.yseq_empty(), 0, 'café!', 'a'), crdt.yseq_set(crdt.yseq_insert(crdt.yseq_empty(), 0, 'café!', 'a'), 'cafè!', 'b')),
              '{"v": {"a": 4}, "i": [["b", 1, ["a", 3], ["a", 4], "è"]], "d": [["a", 4, 1]]}'::jsonb,
              'set é -> è: replaces the whole code point, not a byte');
-- common trailing bytes: 😀 (F0 9F 98 80) -> 🙀 (F0 9F 99 80)
select tap.is(crdt.yseq_value(crdt.yseq_set(crdt.yseq_insert(crdt.yseq_empty(), 0, 'x😀y', 'a'), 'x🙀y', 'b')), 'x🙀y',
              'set 😀 -> 🙀 (shared first and last bytes)');
select tap.is(crdt.yseq_diff(crdt.yseq_insert(crdt.yseq_empty(), 0, 'x😀y', 'a'), crdt.yseq_set(crdt.yseq_insert(crdt.yseq_empty(), 0, 'x😀y', 'a'), 'x🙀y', 'b')) -> 'd',
              '[["a", 2, 1]]'::jsonb, 'and deletes exactly that one code point');
select tap.is(crdt.yseq_value(crdt.yseq_set(crdt.yseq_insert(crdt.yseq_empty(), 0, '日本語', 'a'), '日本', 'b')), '日本', 'set: drop a trailing CJK character');

-- ops carry the text; replica ids are any text without ":" (non-ASCII too)
select tap.is(crdt.yseq_ops_since(crdt.yseq_insert(crdt.yseq_empty(), 0, 'é😀', U&'\+01F600')) -> 'i',
              jsonb_build_array(jsonb_build_array(U&'\+01F600', 1, null, null, 'é😀')), 'a non-BMP replica id and text round-trip in ops');
select tap.is(crdt.yseq_value(crdt.yseq_apply(crdt.yseq_empty(),
              jsonb_build_object('v', '{}'::jsonb, 'i', jsonb_build_array(jsonb_build_array('ü', 1, null, null, 'a😀' || U&'\0301'))), 'ü')),
              'a😀' || U&'\0301', 'apply: unicode run text and replica id');
select tap.is(crdt.yseq_ops_since(crdt.yseq_delete(crdt.yseq_insert(crdt.yseq_empty(), 0, 'a😀b', 'r'), 1, 1, 'r')) -> 'i' -> 0 ->> 4,
              'a' || U&'\FFFD' || 'b', 'ops_since sends U+FFFD for a deleted character (one code point each)');
select * from tap.finish();
