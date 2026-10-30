-- Goal: a model's conditions are validated and compiled when the model is
-- written, as OpenFGA v1.22.1 does (designs/d-conditions.md sections 2, 3 and
-- 4; test/fga_abac/probe.sh answers P1 to P4 and P33 to P39). The request's
-- validation (names, expression size, parameter count, $expression) is 2000;
-- everything typesystem.NewAndValidate and the CEL compiler reject is 2056,
-- with a HINT. What pg_permissions' CEL leaves out (bytes, type(), dyn(),
-- type names as values, messages, optional syntax) is 2056 with a HINT saying
-- so. Also the compiled form: one restriction row and one edge per allowed
-- condition, and the `conditional` flag that keeps unconditioned relations on
-- their unconditioned statements.
\ir ../../fixtures/fga_suite.sql

-- a model with one condition on doc#viewer: [user with c]
create function pg_temp.with_cond(p_expr text, p_params jsonb, p_name text default 'c', p_key text default 'c')
returns text
language sql
as $$
    select fga_test.code_of(format('select permissions.fga_write_authorization_model(%L::jsonb)', jsonb_build_object(
        'schema_version', '1.1',
        'type_definitions', jsonb_build_array(
            jsonb_build_object('type', 'user'),
            jsonb_build_object('type', 'doc', 'relations', jsonb_build_object('viewer', jsonb_build_object('this', '{}'::jsonb)),
                               'metadata', jsonb_build_object('relations', jsonb_build_object('viewer', jsonb_build_object(
                                   'directly_related_user_types', jsonb_build_array(jsonb_build_object('type', 'user', 'condition', p_key))))))),
        'conditions', jsonb_build_object(p_key, jsonb_build_object('name', p_name, 'expression', p_expr, 'parameters', p_params)))))
$$;

-- the HINT of the error, or 'ok'
create function pg_temp.hint_of(p_expr text, p_params jsonb)
returns text
language plpgsql
as $$
declare
    e record;
begin
    select * into e from fga_test.error_of(format('select permissions.fga_write_authorization_model(%L::jsonb)', jsonb_build_object(
        'schema_version', '1.1',
        'type_definitions', jsonb_build_array(jsonb_build_object('type', 'user')),
        'conditions', jsonb_build_object('c', jsonb_build_object('name', 'c', 'expression', p_expr, 'parameters', p_params)))));
    return coalesce(e.hint, 'ok');
end;
$$;

select tap.plan(51);

-- accepted, and kept
select tap.is(pg_temp.with_cond('x < 100', '{"x": {"type_name": "TYPE_NAME_INT"}}') ~ '^openfga', false, 'a condition on a type restriction is accepted');
select tap.is(permissions.fga_read_authorization_model() #>> '{conditions,c,expression}', 'x < 100',
              'the model as read back has its conditions');
select tap.is((select c.parameters from permissions.fga_conditions c where c.name = 'c'
               and c.model_id = permissions.fga_read_authorization_model() ->> 'id'), '{"x": "int"}'::jsonb,
              'the parameters are stored as CEL types');
select tap.is((select c.ast ->> 't' from permissions.fga_conditions c where c.name = 'c'
               and c.model_id = permissions.fga_read_authorization_model() ->> 'id'), 'bool',
              'the expression is stored compiled (a typed tree whose type is bool)');
select tap.is(pg_temp.with_cond('l.exists(e, e in m) && t < timestamp("2030-01-01T00:00:00Z") && d > duration("1s") && ip.in_cidr(s) && u > 1u && f > 0.5 && b && a == 1',
                                '{"l": {"type_name": "TYPE_NAME_LIST", "generic_types": [{"type_name": "TYPE_NAME_STRING"}]},
                                  "m": {"type_name": "TYPE_NAME_MAP", "generic_types": [{"type_name": "TYPE_NAME_INT"}]},
                                  "t": {"type_name": "TYPE_NAME_TIMESTAMP"}, "d": {"type_name": "TYPE_NAME_DURATION"},
                                  "ip": {"type_name": "TYPE_NAME_IPADDRESS"}, "s": {"type_name": "TYPE_NAME_STRING"},
                                  "u": {"type_name": "TYPE_NAME_UINT"}, "f": {"type_name": "TYPE_NAME_DOUBLE"},
                                  "b": {"type_name": "TYPE_NAME_BOOL"}, "a": {"type_name": "TYPE_NAME_ANY"}}') ~ '^openfga', false,
              'every OpenFGA parameter type but bytes is accepted');
select tap.is(fga_test.code_of($$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}],
    "conditions": {"unused": {"name": "unused", "expression": "x < 1", "parameters": {"x": {"type_name": "TYPE_NAME_INT"}}}}}') $$), 'ok',
              'an unused condition is accepted (OpenFGA too; the language validator flags it)');
select tap.is(pg_temp.with_cond('size([1, "a"]) == x', '{"x": {"type_name": "TYPE_NAME_INT"}}') ~ '^openfga', false,
              'a list literal of mixed types is accepted (a list of dyn, as in OpenFGA, P36)');

-- 2056: the definition (P1 to P4)
select tap.ok(pg_temp.with_cond('size(b) > 0', '{"b": {"type_name": "TYPE_NAME_BYTES"}}')
              ~ '^openfga:2056 failed to compile expression on condition ''c'' - failed to decode parameter type for parameter ''b'': the bytes parameter type is not supported',
              'a bytes parameter is refused (2056, P1)');
select tap.ok(pg_temp.hint_of('size(b) > 0', '{"b": {"type_name": "TYPE_NAME_BYTES"}}') ~ 'bytes is not supported', '... with a hint');
select tap.ok(pg_temp.with_cond('x < 1', '{"x": {"type_name": "TYPE_NAME_INT"}}', 'other', 'c')
              ~ '^openfga:2056 failed to compile expression on condition ''c'' - the condition key ''c'' differs from its name ''other''',
              'a condition whose key differs from its name is refused (2056, P2)');
select tap.ok(pg_temp.with_cond('size(m) > 0', '{"m": {"type_name": "TYPE_NAME_MAP"}}')
              ~ '^openfga:2056 .*TYPE_NAME_MAP requires exactly one generic type', 'a map without its generic type is refused (2056, P3)');
select tap.ok(pg_temp.with_cond('x < 1', '{"x": {"type_name": "TYPE_NAME_NOPE"}}')
              ~ '^openfga:2056 .*unknown condition parameter type TYPE_NAME_NOPE', 'an unknown parameter type is refused (2056)');
select tap.ok(pg_temp.with_cond('x < ', '{"x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2056 .*Syntax error: unexpected end of expression', 'a syntax error is refused (2056, P4)');
select tap.ok(pg_temp.with_cond('x < 1 &', '{"x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2056 .*Syntax error: unexpected character ''&'' at column 7', '... with its column');
select tap.ok(pg_temp.with_cond('y < 1', '{"x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2056 .*undeclared reference to ''y''', 'an undeclared identifier is refused (2056, P4)');
select tap.ok(pg_temp.hint_of('y < 1', '{"x": {"type_name": "TYPE_NAME_INT"}}') ~ 'Parameters: x\.', '... with the parameters in the hint');
select tap.ok(pg_temp.with_cond('x + 1', '{"x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2056 .*expected a bool condition expression output, but got ''int''', 'a non-bool expression is refused (2056, P4)');
select tap.ok(pg_temp.with_cond('a', '{"a": {"type_name": "TYPE_NAME_ANY"}}')
              ~ '^openfga:2056 .*expected a bool condition expression output, but got ''dyn''', 'an any parameter alone is not a bool (2056, P35)');
select tap.ok(pg_temp.with_cond('x < "a"', '{"x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2056 .*found no matching overload for ''_<_'' applied to ''\(int, string\)''', 'int < string is refused (2056, P4)');
select tap.ok(pg_temp.with_cond('x < 1.5', '{"x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2056 .*found no matching overload for ''_<_'' applied to ''\(int, double\)''', 'int < double is refused: no implicit conversion (2056, P4)');
select tap.ok(pg_temp.hint_of('x < 1.5', '{"x": {"type_name": "TYPE_NAME_INT"}}') ~ 'no implicit conversions', '... with a hint');
select tap.ok(pg_temp.with_cond('(x > 1 ? 1 : "a") == 1', '{"x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2056 .*found no matching overload for ''_\?_:_'' applied to ''\(bool, int, string\)''', 'a conditional with branches of two types is refused (2056, P34)');
select tap.ok(pg_temp.with_cond('x.foo == 1', '{"x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2056 .*type ''int'' does not support field selection', 'a field of an int is refused (2056)');
select tap.ok(pg_temp.with_cond('x.nope()', '{"x": {"type_name": "TYPE_NAME_STRING"}}')
              ~ '^openfga:2056 .*found no matching overload for ''nope''', 'an unknown method is refused (2056)');
select tap.ok(pg_temp.with_cond('nope(x)', '{"x": {"type_name": "TYPE_NAME_STRING"}}')
              ~ '^openfga:2056 .*undeclared reference to ''nope''', 'an unknown function is refused (2056)');
select tap.ok(pg_temp.with_cond('x < 9223372036854775808', '{"x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2056 .*integer literal 9223372036854775808 is out of range', 'an int literal out of range is refused (2056)');
select tap.ok(pg_temp.with_cond('x == "\q"', '{"x": {"type_name": "TYPE_NAME_STRING"}}')
              ~ '^openfga:2056 .*invalid escape sequence', 'an invalid escape is refused (2056)');
select tap.ok(pg_temp.with_cond('if < 1', '{"x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2056 .*reserved identifier ''if''', 'a reserved word is refused (2056)');

-- 2056: what pg_permissions' CEL leaves out (tier 3), with a hint that says so
select tap.ok(pg_temp.with_cond('b"abc" == b"abc"', '{}') ~ '^openfga:2056 .*bytes literals are not supported', 'bytes literals are refused (2056)');
select tap.ok(pg_temp.with_cond('type(x) == int', '{"x": {"type_name": "TYPE_NAME_INT"}}') ~ '^openfga:2056 .*type\(\) is not supported', 'type() is refused (2056)');
select tap.ok(pg_temp.with_cond('dyn(x) < 1.5', '{"x": {"type_name": "TYPE_NAME_INT"}}') ~ '^openfga:2056 .*dyn\(\) is not supported', 'dyn() is refused (2056; OpenFGA accepts it, P37)');
select tap.ok(pg_temp.hint_of('dyn(x) < 1.5', '{"x": {"type_name": "TYPE_NAME_INT"}}') ~ 'leaves out bytes, type\(\), dyn\(\)', '... with a hint naming what is left out');
select tap.ok(pg_temp.with_cond('x == int', '{"x": {"type_name": "TYPE_NAME_INT"}}') ~ '^openfga:2056 .*type names used as values are not supported', 'a type name as a value is refused (2056)');
select tap.ok(pg_temp.with_cond('Foo{a: 1}.a == x', '{"x": {"type_name": "TYPE_NAME_INT"}}') ~ '^openfga:2056 .*message construction', 'message construction is refused (2056)');
select tap.ok(pg_temp.with_cond('m.?a == x', '{"m": {"type_name": "TYPE_NAME_MAP", "generic_types": [{"type_name": "TYPE_NAME_INT"}]}, "x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2056 .*optional field selection', 'optional syntax is refused (2056)');

-- 2056: a type restriction naming an undefined condition (fga_lang too)
select tap.ok(fga_test.code_of($$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"},
    {"type": "doc", "relations": {"viewer": {"this": {}}}, "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user", "condition": "nope"}]}}}}]}') $$)
              ~ '^openfga:2056 condition nope is undefined for relation viewer', 'a restriction naming an undefined condition is refused (2056)');

-- 2000: the request's validation (P33)
select tap.ok(pg_temp.with_cond('x < 1', '{"x": {"type_name": "TYPE_NAME_INT"}}', 'a:b', 'a:b')
              ~ '^openfga:2000 invalid Condition\.Name ''a:b''', 'a condition name with '':'' is refused (2000)');
select tap.ok(pg_temp.with_cond(repeat('x == 1 || ', 52) || 'x == 2', '{"x": {"type_name": "TYPE_NAME_INT"}}')
              ~ '^openfga:2000 invalid Condition\.Expression .*at most 512 bytes', 'an expression over 512 bytes is refused (2000)');
select tap.ok(pg_temp.with_cond('p1 < 1', (select jsonb_object_agg('p' || g, '{"type_name": "TYPE_NAME_INT"}'::jsonb) from generate_series(1, 26) g))
              ~ '^openfga:2000 invalid Condition\.Parameters .*no more than 25', '26 parameters are refused (2000)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"},
    {"type": "doc", "relations": {"viewer": {"this": {}}}, "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user", "condition": "$expression"}]}}}}]}') $$)
              ~ '^openfga:2000 \$expression requires the "inline_expressions" experimental feature flag', 'an inline expression is refused (2000, as the default server; out of scope)');

-- the compiled form
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "group", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user"}, {"type": "user", "condition": "cx"}]}}}},
    {"type": "folder", "relations": {"viewer": {"this": {}}, "plain": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]},
                                "plain": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "doc",
     "relations": {
       "parent": {"this": {}},
       "owner": {"this": {}},
       "viewer": {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}},
       "plain_viewer": {"tupleToUserset": {"tupleset": {"relation": "owner"}, "computedUserset": {"relation": "plain"}}},
       "member_view": {"this": {}},
       "banned": {"this": {}},
       "open": {"difference": {"base": {"computedUserset": {"relation": "owner"}}, "subtract": {"computedUserset": {"relation": "member_view"}}}},
       "editor": {"this": {}}},
     "metadata": {"relations": {
       "parent": {"directly_related_user_types": [{"type": "folder", "condition": "cx"}]},
       "owner": {"directly_related_user_types": [{"type": "folder"}]},
       "member_view": {"directly_related_user_types": [{"type": "group", "relation": "member"}]},
       "banned": {"directly_related_user_types": [{"type": "user"}]},
       "editor": {"directly_related_user_types": [{"type": "user"}]}}}}],
  "conditions": {"cx": {"name": "cx", "expression": "x < 100", "parameters": {"x": {"type_name": "TYPE_NAME_INT"}}}}}$m$::jsonb) as m \gset

select tap.is((select array_agg(tr.condition order by tr.condition) from permissions.fga_type_restrictions tr
               where tr.model_id = :'m' and tr.type = 'group' and tr.relation = 'member'), '{"",cx}'::text[],
              '[user, user with c] is two restriction rows');
select tap.is((select array_agg(e.condition order by e.condition) from permissions.fga_edges e
               where e.model_id = :'m' and e.kind = 'd' and e.dst_type = 'group' and e.dst_relation = 'member'), '{"",cx}'::text[],
              '... and two edges, one per condition');
select tap.is((select array_agg(e.condition) from permissions.fga_edges e
               where e.model_id = :'m' and e.kind = 't' and e.dst_type = 'doc' and e.dst_relation = 'viewer'), '{cx}'::text[],
              'a tupleToUserset edge carries its tupleset restriction''s condition');
select tap.is((select array_agg(distinct s.condition) from permissions.fga_walk_steps s
               where s.model_id = :'m' and s.target_type = 'doc' and s.target_relation = 'viewer' and s.kind = 't'), '{cx}'::text[],
              'so do the walk steps');
select tap.is((select array_agg(r.type || '#' || r.relation order by r.type, r.relation) from permissions.fga_relations r
               where r.model_id = :'m' and r.conditional),
              '{doc#member_view,doc#open,doc#parent,doc#viewer,group#member}'::text[],
              'conditional: the relations a conditioned restriction is reachable from, through any operand (a subtract too, a tupleset)');
select tap.is((select array_agg(r.type || '#' || r.relation order by r.type, r.relation) from permissions.fga_relations r
               where r.model_id = :'m' and not r.conditional),
              '{doc#banned,doc#editor,doc#owner,doc#plain_viewer,folder#plain,folder#viewer}'::text[],
              '... and every other relation takes the unconditioned statements');

-- the unconditioned fast path still ignores a tuple whose condition the model doesn't allow
select permissions.fga_write('[{"user": "user:ann", "relation": "member", "object": "group:g", "condition": {"name": "cx", "context": {"x": 1}}},
                               {"user": "group:g#member", "relation": "member_view", "object": "doc:1"},
                               {"user": "folder:f", "relation": "owner", "object": "doc:1"},
                               {"user": "user:ann", "relation": "plain", "object": "folder:f"}]');
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "group", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "doc", "relations": {"member_view": {"this": {}}},
     "metadata": {"relations": {"member_view": {"directly_related_user_types": [{"type": "group", "relation": "member"}]}}}}]}$m$::jsonb) as m2 \gset
select tap.is((select bool_or(r.conditional) from permissions.fga_relations r where r.model_id = :'m2'), false, 'a model without conditions has no conditional relation');
select tap.is(permissions.fga_check('user:ann', 'member_view', 'doc:1'), false,
              'a stored tuple with a condition the new model does not allow is ignored on the unconditioned path');
select tap.is(array(select permissions.fga_list_objects('user:ann', 'doc', 'member_view')), '{}'::text[], '... by ListObjects too');
select tap.is(array(select permissions.fga_list_users('doc:1', 'member_view', '{user}')), '{}'::text[], '... and ListUsers');
select tap.is(permissions.fga_check('user:ann', 'plain_viewer', 'doc:1', model_id => :'m'), true,
              'an unconditioned relation of the first model answers as before');

select * from tap.finish();
