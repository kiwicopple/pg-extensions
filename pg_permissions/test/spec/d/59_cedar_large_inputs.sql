-- Goal: the Cedar functions take time linear (or n log n) in the size of
-- their input, so one large id, set or policy cannot hold a backend for
-- minutes (research/designs/e-cedar.md section 17). Before the phase 9
-- fixes, on a laptop, the id of 100,000 characters below took 42 s per row,
-- a set of 20,000 values in resource_attrs 3.1 s (200,000: more than 2
-- minutes), a like pattern of 20,000 \* escapes 71 s, and containsAll and
-- containsAny compared every pair of elements. Each case below has 100,000
-- elements, or about the most a 64 KiB policy holds. statement_timeout
-- guards each statement; the bound on the elapsed time is loose, for slow
-- CI machines.
select tap.plan(16);

select permissions.cedar_put_entities(entities => '[{"uid": {"type": "user", "id": "u"}}]');
select permissions.cedar_put_policy(policy_id => 'view',
    policy => 'permit (principal, action == Action::"view", resource is Doc);');
select permissions.cedar_put_policy(policy_id => 'tagged',
    policy => 'permit (principal, action == Action::"tagged", resource is Doc) when { resource.tags.contains(99999) };');
select permissions.cedar_put_policy(policy_id => 'all',
    policy => 'permit (principal, action == Action::"all", resource is Doc) when { resource.big.containsAll(resource.small) };');
select permissions.cedar_put_policy(policy_id => 'any',
    policy => 'permit (principal, action == Action::"any", resource is Doc) when { resource.big.containsAny(resource.other) };');
set permissions.subject_id = 'u';
set statement_timeout = '20s';

-- an id of 100,000 characters, half of them escaped quotes
select clock_timestamp() as t0 \gset
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"' || repeat('a\"', 50000) || '"'), true,
              'an id of 100,000 characters with 50,000 escaped quotes parses');
select tap.ok(clock_timestamp() - :'t0'::timestamptz < interval '2 s', 'in linear time (42 s before)');
select clock_timestamp() as t0 \gset
select tap.is((select id from permissions._cedar_uid(permissions.cedar_uid('Doc', repeat('"\', 50000)), 'resource')) = repeat('"\', 50000), true,
              'cedar_uid and the parser round-trip an id of 100,000 quotes and backslashes');
select tap.ok(clock_timestamp() - :'t0'::timestamptz < interval '2 s', 'in linear time');

-- sets of 100,000 values in resource_attrs
select clock_timestamp() as t0 \gset
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"tagged"', resource => 'Doc::"d"',
                  resource_attrs => jsonb_build_object('tags', (select jsonb_agg(i) from generate_series(100000, 1, -1) i))), true,
              'a set of 100,000 Longs in resource_attrs');
select tap.ok(clock_timestamp() - :'t0'::timestamptz < interval '2 s', 'is built once, not one element at a time');
select clock_timestamp() as t0 \gset
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"tagged"', resource => 'Doc::"d"',
                  resource_attrs => jsonb_build_object('tags', (select jsonb_agg(jsonb_build_array(i)) from generate_series(1, 20000) i))), false,
              'a set of 20,000 sets (each converted) in resource_attrs');
select tap.ok(clock_timestamp() - :'t0'::timestamptz < interval '3 s', 'is built once too');
select tap.is((permissions._cedar_value_in(jsonb_build_object('a', '[3, 1, 2, 1]'::jsonb, 'b', 'x', 'c', '[[2], [1]]'::jsonb), 'v', 1)).val,
              '{"a": [1, 2, 3], "b": "x", "c": [[1], [2]]}'::jsonb, 'sets are still sorted and without duplicates');

-- containsAll and containsAny on 100,000 elements each
select clock_timestamp() as t0 \gset
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"all"', resource => 'Doc::"d"',
                  resource_attrs => jsonb_build_object('big', (select jsonb_agg(i) from generate_series(1, 100000) i),
                                                       'small', (select jsonb_agg(i) from generate_series(1, 100000, 2) i))), true,
              'containsAll of 50,000 in 100,000');
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"any"', resource => 'Doc::"d"',
                  resource_attrs => jsonb_build_object('big', (select jsonb_agg(i) from generate_series(1, 100000) i),
                                                       'other', (select jsonb_agg(i) from generate_series(100001, 200000) i))), false,
              'containsAny of 100,000 disjoint from 100,000');
select tap.ok(clock_timestamp() - :'t0'::timestamptz < interval '3 s', 'both as set operations');
select tap.is(permissions.cedar_is_authorized(principal => 'user::"u"', action => 'Action::"any"', resource => 'Doc::"d"',
                  entities => '[{"uid": {"type": "Doc", "id": "d"}, "attrs": {"big": [{"r": 1, "s": 2}], "other": [{"r": 1}]}}]') ->> 'decision',
              'deny', 'containsAny compares records with ==, not jsonb containment');

-- the policy parser at its 64 KiB limit
select clock_timestamp() as t0 \gset
select tap.lives_ok($$ select permissions.cedar_put_policy(policy_id => 'like',
    policy => 'permit (principal, action, resource) when { "a" like "' || repeat('a\*', 20000) || '" };') $$,
    'a like pattern of 20,000 escaped stars');
select tap.lives_ok($$ select permissions.cedar_put_policy(policy_id => 'rec',
    policy => 'permit (principal, action, resource) when { {' || (select string_agg(format('a%s: [1, 2]', i), ', ') from generate_series(1, 1300) i) || '}.a1 == [1, 2] };') $$,
    'a record literal of 1,300 keys');
select tap.ok(clock_timestamp() - :'t0'::timestamptz < interval '3 s', 'parse in linear time');

reset statement_timeout;
select * from tap.finish();
