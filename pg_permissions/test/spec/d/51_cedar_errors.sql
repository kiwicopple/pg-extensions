-- Goal: bad input to the Cedar API raises a cedar:<code> error with the
-- offending value, before anything is stored (research/designs/e-cedar.md
-- sections 5 and 6): the JSON policy format is checked for its shape (unknown
-- keys, operators and expression kinds, slots in a static policy, an action
-- scope that is not an action, a record that would read as an escape), with
-- the nearest name for a misspelt extension function; the extension types and
-- Cedar text are refused until their phases; entity JSON and uids are checked
-- (Longs in the i64 range, no duplicate uids, no cycle, explicit escapes);
-- and the fixed limits hold. Messages and hints are spot-checked here; every
-- raise site has its own row in 35_error_hints.sql.
\ir ../../fixtures/d/cedar.sql

create temp table cases (n serial, what text, stmt text, want text);
insert into cases (what, stmt, want) values
-- policies: the JSON policy format
('a policy that is not an object', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => '[]') $$, '22023 cedar:invalid_policy path=''$'''),
('an unknown top-level key', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit') || '{"when": []}') $$, '22023 cedar:invalid_policy path=''$'''),
('no effect', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit') - 'effect') $$, '22023 cedar:invalid_policy path=''$.effect'''),
('no principal scope', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit') - 'principal') $$, '22023 cedar:invalid_policy path=''$.principal'''),
('an unknown scope op', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', null, '{"op": "like"}')) $$, '22023 cedar:invalid_policy path=''$.principal'''),
('a principal scope with a list', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', null, '{"op": "in", "entities": [{"type": "G", "id": "a"}]}')) $$, '22023 cedar:invalid_policy path=''$.principal'''),
('a bad entity type in the scope', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', null, '{"op": "==", "entity": {"type": "1User", "id": "a"}}')) $$, '22023 cedar:invalid_policy path=''$.principal'''),
('a slot in a static policy', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', null, '{"op": "==", "slot": "?principal"}')) $$, '22023 cedar:invalid_policy path=''$.principal'''),
('a slot in is ... in', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', null, '{"op": "All"}', '{"op": "All"}', '{"op": "is", "entity_type": "Doc", "in": {"slot": "?resource"}}')) $$, '22023 cedar:invalid_policy path=''$.resource'''),
('an action scope that is not an action', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', null, '{"op": "All"}', '{"op": "==", "entity": {"type": "User", "id": "view"}}')) $$, '22023 cedar:invalid_policy path=''$.action.entity'''),
('an action list with a non-action', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', null, '{"op": "All"}', '{"op": "in", "entities": [{"type": "Action", "id": "a"}, {"type": "Actions", "id": "b"}]}')) $$, '22023 cedar:invalid_policy path=''$.action.entities'''),
('action is ...', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', null, '{"op": "All"}', '{"op": "is", "entity_type": "Action"}')) $$, '22023 cedar:invalid_policy path=''$.action'''),
('a condition kind', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit') || '{"conditions": [{"kind": "if", "body": {"Value": true}}]}') $$, '22023 cedar:invalid_policy path=''$.conditions'''),
('a non-string annotation', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit') || '{"annotations": {"a": 1}}') $$, '22023 cedar:invalid_policy path=''$.annotations'''),
('an expression with two keys', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"Value": true, "Var": "context"}')) $$, '22023 cedar:invalid_policy path=''$.conditions[0].body'''),
('an unknown variable', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"Var": "user"}')) $$, '22023 cedar:invalid_policy path=''$.conditions[0].body.Var'''),
('a binary operator without right', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"&&": {"left": {"Value": true}}}')) $$, '22023 cedar:invalid_policy path=''$.conditions[0].body."&&"'''),
('a slot in a condition', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"==": {"left": {"Var": "principal"}, "right": {"Slot": "?principal"}}}')) $$, '22023 cedar:invalid_policy path=''$.conditions[0].body."==".Slot'''),
('a like pattern as a string', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"like": {"left": {"Value": "a"}, "pattern": "a*"}}')) $$, '22023 cedar:invalid_policy path=''$.conditions[0].body.like'''),
('a Long beyond i64', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"==": {"left": {"Value": 9223372036854775808}, "right": {"Value": 1}}}')) $$, '22023 cedar:invalid_policy path=''$.conditions[0].body."==".Value'''),
('a decimal number', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"==": {"left": {"Value": 1.5}, "right": {"Value": 1}}}')) $$, '22023 cedar:invalid_policy path=''$.conditions[0].body."==".Value'''),
('null', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"Value": null}')) $$, '22023 cedar:invalid_policy path=''$.conditions[0].body.Value'''),
('an unknown expression kind', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"Valu": true}')) $$, '22023 cedar:invalid_policy path=''$.conditions[0].body.Valu'''),
('an unknown extension function', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"isInRang": [{"Value": 1}]}')) $$, '22023 cedar:invalid_policy path=''$.conditions[0].body.isInRang'''),
('Unknown (partial evaluation)', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"Unknown": {"name": "x"}}')) $$, '0A000 cedar:unsupported feature=''Unknown is for partial evaluation, which is not supported'''),
('an extension function (phase 4)', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"decimal": [{"Value": "1.5"}]}')) $$, '0A000 cedar:unsupported feature=''decimal'''),
('an extension method (phase 4)', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"isInRange": [{"Var": "context"}, {"Var": "context"}]}')) $$, '0A000 cedar:unsupported feature=''ipaddr'''),
('an extension value literal (phase 4)', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"Value": {"__extn": {"fn": "datetime", "arg": "2024-01-01"}}}')) $$, '0A000 cedar:unsupported%'),
('a record literal with the key __entity', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"Record": {"__entity": {"Value": 1}}}')) $$, '0A000 cedar:unsupported%'),
('a record value with the key __entity and others', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"Value": {"__entity": {"type": "A", "id": "a"}, "x": 1}}')) $$, '22023 cedar:invalid_policy path=''$.conditions[0].body.Value'''),
-- entities
('entities that are not an array', $$ select permissions.cedar_put_entities(entities => '{}') $$, '22023 cedar:invalid_entity index=0'),
('a duplicate uid', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}}, {"uid": {"type": "U", "id": "b"}}, {"uid": {"__entity": {"type": "U", "id": "a"}}}]') $$, '22023 cedar:invalid_entity index=2'),
('an unknown entity key', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "attributes": {}}]') $$, '22023 cedar:invalid_entity index=0'),
('a uid without id', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U"}}]') $$, '22023 cedar:invalid_entity index=0'),
('a uid with a bad type', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U::", "id": "a"}}]') $$, '22023 cedar:invalid_entity index=0'),
('a uid with an extra key', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a", "x": 1}}]') $$, '22023 cedar:invalid_entity index=0'),
('a parent that is not a uid', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "parents": ["G::\"g\""]}]') $$, '22023 cedar:invalid_entity index=0'),
('attrs that are not an object', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "attrs": []}]') $$, '22023 cedar:invalid_entity index=0'),
('a Long beyond i64 in attrs', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "attrs": {"n": -9223372036854775809}}]') $$, '22023 cedar:invalid_entity index=0'),
('1.0 is not a Long', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "tags": {"n": 1.0}}]') $$, '22023 cedar:invalid_entity index=0'),
('a null attribute', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "attrs": {"n": null}}]') $$, '22023 cedar:invalid_entity index=0'),
('a bad entity reference in attrs', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "attrs": {"boss": {"__entity": {"type": "U"}}}}]') $$, '22023 cedar:invalid_entity index=0'),
('an extension value (phase 4)', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "attrs": {"ip": {"__extn": {"fn": "ip", "arg": "10.0.0.1"}}}}]') $$, '0A000 cedar:unsupported index=0'),
('an unknown extension function in data', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "attrs": {"x": {"__extn": {"fn": "money", "arg": "1"}}}}]') $$, '22023 cedar:invalid_entity index=0'),
('an entity that is its own parent', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "G", "id": "a"}, "parents": [{"type": "G", "id": "a"}]}]') $$, '22023 cedar:invalid_entity uid=''G::"a"'''),
('a cycle within one put', $$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "G", "id": "a"}, "parents": [{"type": "G", "id": "b"}]}, {"uid": {"type": "G", "id": "b"}, "parents": [{"type": "G", "id": "c"}]}, {"uid": {"type": "G", "id": "c"}, "parents": [{"type": "G", "id": "a"}]}]') $$, '22023 cedar:invalid_entity uid=%'),
-- uids
('a uid without quotes', $$ select permissions.cedar_is_authorized(principal => 'User::alice', action => 'Action::"view"', resource => 'Doc::"d"') $$, '22023 cedar:invalid_uid value=''User::alice'''),
('a uid with a bad escape', $$ select permissions.cedar_is_authorized(principal => 'User::"a\qb"', action => 'Action::"view"', resource => 'Doc::"d"') $$, '22023 cedar:invalid_uid value=%'),
('a uid with \0', $$ select permissions.cedar_is_authorized(principal => 'User::"a\0"', action => 'Action::"view"', resource => 'Doc::"d"') $$, '22023 cedar:invalid_uid value=%'),
('a uid with \u{0}', $$ select permissions.cedar_is_authorized(principal => 'User::"a\u{0}"', action => 'Action::"view"', resource => 'Doc::"d"') $$, '22023 cedar:invalid_uid value=%'),
('a uid with an unescaped quote', $$ select permissions.cedar_is_authorized(principal => 'User::"a"b"', action => 'Action::"view"', resource => 'Doc::"d"') $$, '22023 cedar:invalid_uid value=''User::"a"b"'''),
('an action uid', $$ select permissions.cedar_is_authorized(principal => 'User::"a"', action => 'view', resource => 'Doc::"d"') $$, '22023 cedar:invalid_uid value=''view'''),
('a null resource', $$ select permissions.cedar_is_authorized(principal => 'User::"a"', action => 'Action::"view"', resource => null) $$, '22004 cedar:null_argument argument=''resource'''),
('a Cedar text uid in cedar_delete_entities', $$ select permissions.cedar_delete_entities(uids => '["User::alice"]') $$, '22023 cedar:invalid_uid value=''User::alice'''),
-- context and overlay
('a context that is a string', $$ select permissions.cedar_is_authorized(principal => 'User::"a"', action => 'Action::"view"', resource => 'Doc::"d"', context => '"x"') $$, '22023 cedar:invalid_context'),
('a context with a float', $$ select permissions.cedar_is_authorized(principal => 'User::"a"', action => 'Action::"view"', resource => 'Doc::"d"', context => '{"x": 0.5}') $$, '22023 cedar:invalid_context'),
('a context with an extension value (phase 4)', $$ select permissions.cedar_is_authorized(principal => 'User::"a"', action => 'Action::"view"', resource => 'Doc::"d"', context => '{"x": {"__extn": {"fn": "decimal", "arg": "1.0"}}}') $$, '0A000 cedar:unsupported feature=''extension value'''),
('an overlay with a duplicate', $$ select permissions.cedar_is_authorized(principal => 'User::"a"', action => 'Action::"view"', resource => 'Doc::"d"', entities => '[{"uid": {"type": "U", "id": "a"}}, {"uid": {"type": "U", "id": "a"}}]') $$, '22023 cedar:invalid_entity index=1'),
-- the other functions
('cedar_put_policy without a policy', $$ select permissions.cedar_put_policy(policy_id => 'p') $$, '22004 cedar:null_argument argument=''policy_json'''),
('cedar_delete_policy(null)', $$ select permissions.cedar_delete_policy(policy_id => null) $$, '22004 cedar:null_argument argument=''policy_id'''),
('cedar_delete_entities(null)', $$ select permissions.cedar_delete_entities(uids => null) $$, '22004 cedar:null_argument argument=''uids'''),
-- limits (e-cedar.md section 6)
('a policy over 64 KiB', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit') || jsonb_build_object('annotations', jsonb_build_object('big', repeat('x', 66000)))) $$, '54000 cedar:limit_exceeded limit=''policy_bytes'''),
('expressions nested 65 deep', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', (select ('{"Value": true}'::jsonb) from generate_series(1, 1)) )) $$, ''),
('more than 4,096 expression nodes', $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', jsonb_build_object('Set', (select jsonb_agg('{"Value": 1}'::jsonb) from generate_series(1, 4100))))) $$, '54000 cedar:limit_exceeded limit=''policy_nodes'''),
('values nested 33 deep', $$ select permissions.cedar_put_entities(entities => jsonb_build_array(jsonb_build_object('uid', '{"type": "U", "id": "a"}'::jsonb, 'attrs', jsonb_build_object('x', (repeat('[', 33) || repeat(']', 33))::jsonb)))) $$, '54000 cedar:limit_exceeded index=0'),
('more than 10,000 entities in one put', $$ select permissions.cedar_put_entities(entities => (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'U', 'id', g::text))) from generate_series(1, 10001) g)) $$, '54000 cedar:limit_exceeded index=0'),
('more than 1,000 entities in an overlay', $$ select permissions.cedar_is_authorized(principal => 'User::"a"', action => 'Action::"view"', resource => 'Doc::"d"', entities => (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'U', 'id', g::text))) from generate_series(1, 1001) g)) $$, '54000 cedar:limit_exceeded index=0'),
('a context nested 33 deep', $$ select permissions.cedar_is_authorized(principal => 'User::"a"', action => 'Action::"view"', resource => 'Doc::"d"', context => jsonb_build_object('x', (repeat('[', 33) || repeat(']', 33))::jsonb)) $$, '54000 cedar:limit_exceeded limit=''value_depth''');

-- the nesting limit: 64 levels pass, 65 do not
create function pg_temp.nest(p_depth int) returns jsonb language plpgsql as $$
declare e jsonb := '{"Value": true}';
begin
    for i in 2 .. p_depth loop
        e := jsonb_build_object('!', jsonb_build_object('arg', e));
    end loop;
    return e;
end $$;
update cases set stmt = $$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', pg_temp.nest(65))) $$,
                 want = '54000 cedar:limit_exceeded limit=''policy_depth'''
where what = 'expressions nested 65 deep';

select tap.plan((select count(*)::int from cases) + 13);

select tap.ok(cedar_t.err(c.stmt) like c.want, format('%s: %s', c.what, cedar_t.err(c.stmt))) from cases c order by c.n;

select tap.is((select count(*)::int from permissions.cedar_policies()), 0, 'no failed put stored a policy');
select tap.is(permissions.cedar_read_entities(), '[]', 'no failed put stored an entity');

-- at the limits, not over them
select tap.lives_ok($$ select permissions.cedar_put_policy(policy_id => 'deep', policy_json => cedar_t.policy('permit', pg_temp.nest(64))) $$,
                    'expressions nested 64 deep are accepted');
select tap.is(cedar_t.authz('User::"a"', 'Action::"view"', 'Doc::"d"'), 'deny [] errors []', 'and evaluate (63 negations of true)');
select permissions.cedar_delete_policy(policy_id => 'deep');
select tap.lives_ok($$ select permissions.cedar_put_entities(entities => (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'U', 'id', g::text))) from generate_series(1, 10000) g)) $$,
                    '10,000 entities in one put are accepted');
select tap.is(permissions.cedar_delete_entities(uids => (select jsonb_agg(jsonb_build_object('type', 'U', 'id', g::text)) from generate_series(1, 10000) g)), 10000::bigint,
              'and deleted');

-- messages and hints
select tap.is((cedar_t.msg($$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"isInRang": [{"Value": 1}]}')) $$)).hint,
              'Did you mean ''isInRange''? Extension functions: datetime, decimal, duration, durationSince, greaterThan, greaterThanOrEqual, ip, isInRange, isIpv4, isIpv6, isLoopback, isMulticast, lessThan, lessThanOrEqual, offset, toDate, toDays, toHours, toMilliseconds, toMinutes and 2 more.',
              'a misspelt extension function: the nearest one');
select tap.is((cedar_t.msg($$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"Valu": true}')) $$)).message,
              'invalid policy ''p'' at $.conditions[0].body.Valu: unknown expression kind ''Valu''', 'an unknown expression kind: the message has the path');
select tap.ok((cedar_t.msg($$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', '{"Valu": true}')) $$)).hint
              like 'Did you mean ''Value''? Expression kinds: %', 'and the nearest kind');
select tap.is((cedar_t.msg($$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}}, {"uid": {"type": "U", "id": "a"}}]') $$)).message,
              'invalid entity at index 1 of entities: duplicate entity U::"a"', 'a duplicate entity: its index and uid');
select tap.is((cedar_t.msg($$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "attrs": {"r": {"n": 1.5}}}]') $$)).message,
              'invalid entity at index 0 of entities: U::"a": attrs.r.n: 1.5 is not a Long (an integer from -9223372036854775808 to 9223372036854775807)',
              'a bad value: the entity and the path');
select tap.is((cedar_t.msg($$ select permissions.cedar_is_authorized(principal => 'User::"a\qb"', action => 'Action::"view"', resource => 'Doc::"d"') $$)).message,
              'invalid entity uid for principal: User::"a\qb": the escape \q is not valid in a Cedar string (U+0000 is not supported)',
              'a bad escape in a uid');
select tap.is((cedar_t.msg($$ select permissions.cedar_put_policy(policy_id => 'p', policy_json => cedar_t.policy('permit', null, '{"op": "All"}', '{"op": "==", "entity": {"type": "User", "id": "view"}}')) $$)).message,
              'invalid policy ''p'' at $.action.entity: the action scope names User::"view", which is not an action (an action''s type is Action or Namespace::Action)',
              'an action scope that is not an action');

select * from tap.finish();
