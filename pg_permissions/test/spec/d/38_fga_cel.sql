-- Goal: the CEL language a condition can use (designs/d-conditions.md section
-- 4, tiers 1 and 2) evaluates as OpenFGA v1.22.1 (cel-go v0.31) does, through
-- the API: each row writes a model whose doc#viewer is [user with cond], the
-- tuple doc:1#viewer@user:u with that condition (and the row's stored
-- context, if any), and checks it with the row's request context. Expected:
-- true, false, 2000 (an evaluation error, which OpenFGA reports as
-- validation_error), or 2056 (the model is refused). Rows marked Pn are the
-- server's answers from test/fga_abac/probe.sh; the abac oracle
-- (63_fga_abac_*) covers tier 1 through the walks. Deviations are noted
-- where they apply (designs/d-conditions.md section 6, Precision).
\ir ../../fixtures/fga_suite.sql

-- 'int', 'list<string>', 'map<int>', 'any', ... as an OpenFGA parameter type
create function pg_temp.ptype(t text)
returns jsonb
language plpgsql
as $$
begin
    if t like 'list<%>' then
        return jsonb_build_object('type_name', 'TYPE_NAME_LIST', 'generic_types', jsonb_build_array(pg_temp.ptype(substr(t, 6, length(t) - 6))));
    elsif t like 'map<%>' then
        return jsonb_build_object('type_name', 'TYPE_NAME_MAP', 'generic_types', jsonb_build_array(pg_temp.ptype(substr(t, 5, length(t) - 5))));
    end if;
    return jsonb_build_object('type_name', 'TYPE_NAME_' || upper(t));
end;
$$;

-- true, false, or the error's 'openfga:<code> <message>'
create function pg_temp.cel(p_expr text, p_params jsonb, p_ctx jsonb, p_tctx jsonb default null)
returns text
language plpgsql
as $$
declare
    m text;
    got boolean;
    det text;
    msg text;
begin
    perform permissions.fga_delete_store();
    begin
        m := permissions.fga_write_authorization_model(jsonb_build_object(
            'schema_version', '1.1',
            'type_definitions', jsonb_build_array(
                jsonb_build_object('type', 'user'),
                jsonb_build_object('type', 'doc', 'relations', jsonb_build_object('viewer', jsonb_build_object('this', '{}'::jsonb)),
                                   'metadata', jsonb_build_object('relations', jsonb_build_object('viewer', jsonb_build_object(
                                       'directly_related_user_types', jsonb_build_array(jsonb_build_object('type', 'user', 'condition', 'cond'))))))),
            'conditions', jsonb_build_object('cond', jsonb_build_object(
                'name', 'cond', 'expression', p_expr,
                'parameters', (select coalesce(jsonb_object_agg(e.key, pg_temp.ptype(e.value)), '{}') from jsonb_each_text(p_params) e)))));
        perform permissions.fga_write(jsonb_build_array(jsonb_build_object(
            'user', 'user:u', 'relation', 'viewer', 'object', 'doc:1',
            'condition', jsonb_build_object('name', 'cond') || case when p_tctx is null then '{}' else jsonb_build_object('context', p_tctx) end)));
        got := permissions.fga_check('user:u', 'viewer', 'doc:1', context => p_ctx);
    exception when others then
        get stacked diagnostics det = pg_exception_detail, msg = message_text;
        return split_part(coalesce(det, 'sqlstate'), ' ', 1) || ' ' || msg;
    end;
    return got::text;
end;
$$;

create temp table cases (n serial, expr text, params jsonb, ctx jsonb, want text, label text, tctx jsonb);
insert into cases (expr, params, ctx, want, label) values
-- tier 1: what the abac cases use
('x < 100', '{"x": "int"}', '{"x": 10}', 'true', 'int <'),
('x < 100', '{"x": "int"}', '{"x": 200}', 'false', 'int <, false'),
('x == 10', '{"x": "int"}', '{"x": 10}', 'true', 'int =='),
('s == "hello"', '{"s": "string"}', '{"s": "hello"}', 'true', 'string == with a double-quoted literal'),
($$s == 'hello'$$, '{"s": "string"}', '{"s": "hello"}', 'true', 'a single-quoted literal'),
('ok', '{"ok": "bool"}', '{"ok": true}', 'true', 'a bool parameter as the expression'),
('x > 0.0', '{"x": "double"}', '{"x": 0.5}', 'true', 'double >'),
('ts < timestamp("2023-10-11T10:00:00.000Z")', '{"ts": "timestamp"}', '{"ts": "2023-10-11T09:59:59Z"}', 'true', 'timestamp < timestamp("...")'),
('ts < timestamp("2023-10-11T10:00:00.000Z")', '{"ts": "timestamp"}', '{"ts": "2023-10-11T10:00:00Z"}', 'false', '... the same instant is not before'),
('user_ip.in_cidr(cidr)', '{"user_ip": "ipaddress", "cidr": "string"}', '{"user_ip": "192.168.0.1", "cidr": "192.168.0.0/24"}', 'true', 'in_cidr'),
('user_ip.in_cidr(cidr)', '{"user_ip": "ipaddress", "cidr": "string"}', '{"user_ip": "10.0.0.1", "cidr": "192.168.0.0/24"}', 'false', 'in_cidr, outside'),
('x < 100 || y < 50', '{"x": "int", "y": "int"}', '{"x": 200, "y": 10}', 'true', '||'),
('x < 100 || y < 50', '{"x": "int", "y": "int"}', '{"x": 200, "y": 60}', 'false', '||, both false'),
-- literals
('u == 5u', '{"u": "uint"}', '{"u": 5}', 'true', 'uint literal'),
('x == 0x10 && u == 0x10u', '{"x": "int", "u": "uint"}', '{"x": 16, "u": 16}', 'true', 'hex literals'),
('d == 1e3 && f == 1.5e-1 && g == .5', '{"d": "double", "f": "double", "g": "double"}', '{"d": 1000, "f": 0.15, "g": 0.5}', 'true', 'exponent and leading-dot doubles'),
('x == -9223372036854775808', '{"x": "int"}', '{"x": -9223372036854775808}', 'true', 'the smallest int literal'),
($$s == r"a\d"$$, '{"s": "string"}', '{"s": "a\\d"}', 'true', 'a raw string keeps its backslash'),
($$s == """a"b"""$$, '{"s": "string"}', '{"s": "a\"b"}', 'true', 'a triple-quoted string'),
($$s == "\x41é\101\n"$$, '{"s": "string"}', '{"s": "AéA\n"}', 'true', 'escapes: hex, unicode, octal, newline'),
('x > 0 && null == null', '{"x": "int"}', '{"x": 1}', 'true', 'null'),
('l == [1, 2, 3]', '{"l": "list<int>"}', '{"l": [1, 2, 3]}', 'true', 'a list literal'),
('{"a": 1}.a == x && {1: "a"}[x] == "a" && {true: 1}[true] == x', '{"x": "int"}', '{"x": 1}', 'true', 'map literals: string, int and bool keys'),
('{"a": 1, "a": 2}.a == x', '{"x": "int"}', '{"x": 1}', '2000', 'a map literal with a repeated key is an evaluation error'),
('size([1, "a"]) == x && "a" in [1, "a"]', '{"x": "int"}', '{"x": 2}', 'true', 'a list of mixed types (P36)'),
-- operators
('!b', '{"b": "bool"}', '{"b": false}', 'true', '!'),
('x != 1 && x <= 2 && x >= 2 && x > 1', '{"x": "int"}', '{"x": 2}', 'true', '!= <= >= >'),
('x + 1 == 3 && x - 1 == 1 && x * 3 == 6 && x / 2 == 1 && x % 2 == 0 && -x == -2', '{"x": "int"}', '{"x": 2}', 'true', 'int arithmetic'),
('-7 / 2 == -3 && -7 % 2 == -1 && x == 1', '{"x": "int"}', '{"x": 1}', 'true', 'int division truncates toward zero'),
('u + 1u == 3u && u * 2u == 4u && u % 2u == 0u && u / 2u == 1u', '{"u": "uint"}', '{"u": 2}', 'true', 'uint arithmetic'),
('d / 2.0 == 0.75 && d * 2.0 == 3.0 && d - 0.5 == 1.0 && -d < 0.0', '{"d": "double"}', '{"d": 1.5}', 'true', 'double arithmetic'),
('x / 0 == 1', '{"x": "int"}', '{"x": 1}', '2000', 'division by zero is an error'),
('x % 0 == 1', '{"x": "int"}', '{"x": 1}', '2000', 'modulus by zero is an error'),
('x + 1 > 0', '{"x": "int"}', '{"x": 9223372036854775807}', '2000', 'int overflow is an error'),
('-x < 0', '{"x": "int"}', '{"x": -9223372036854775808}', '2000', 'negating the smallest int is an overflow'),
('u - 2u > 0u', '{"u": "uint"}', '{"u": 1}', '2000', 'uint underflow is an error'),
('x > 5 ? s == "a" : s == "b"', '{"x": "int", "s": "string"}', '{"x": 1, "s": "b"}', 'true', '? :'),
('x > 5 ? 10 / y == 1 : true', '{"x": "int", "y": "int"}', '{"x": 1, "y": 0}', 'true', '? : evaluates only the branch it takes'),
('x in [1, 2]', '{"x": "int"}', '{"x": 2}', 'true', 'in a list'),
('x in [1, 2]', '{"x": "int"}', '{"x": 3}', 'false', 'in a list, absent'),
('"a" in m && !("b" in m)', '{"m": "map<int>"}', '{"m": {"a": 1}}', 'true', 'in a map tests the keys'),
('l[1] == "b"', '{"l": "list<string>"}', '{"l": ["a", "b"]}', 'true', 'list index'),
('l[5] == "b"', '{"l": "list<string>"}', '{"l": ["a", "b"]}', '2000', 'an index out of range is an error'),
('m["a"] == 1 && m.a == 1', '{"m": "map<int>"}', '{"m": {"a": 1}}', 'true', 'map index and field'),
('m.a == 1', '{"m": "map<int>"}', '{"m": {"b": 1}}', '2000', 'a missing map key is an error (P23)'),
('has(m.a) && !has(m.z)', '{"m": "map<int>"}', '{"m": {"a": 1}}', 'true', 'has()'),
-- strings
('size(s) == 3 && s.size() == 3', '{"s": "string"}', '{"s": "héé"}', 'true', 'size counts code points'),
('s.contains("bc") && s.startsWith("ab") && s.endsWith("cd") && !s.contains("x")', '{"s": "string"}', '{"s": "abcd"}', 'true', 'contains, startsWith, endsWith'),
('s.matches("^[a-c]+$") && matches(s, "b")', '{"s": "string"}', '{"s": "abc"}', 'true', 'matches, as a method and a function'),
('s.matches("^[a-c]+$")', '{"s": "string"}', '{"s": "abd"}', 'false', 'matches, no match'),
('s.matches("(")', '{"s": "string"}', '{"s": "abc"}', '2000', 'an invalid regular expression is an error'),
('s + "x" == "ax"', '{"s": "string"}', '{"s": "a"}', 'true', 'string concatenation'),
('s < "b" && "B" < "a"', '{"s": "string"}', '{"s": "a"}', 'true', 'strings compare by code point'),
('l + ["b"] == ["a", "b"]', '{"l": "list<string>"}', '{"l": ["a"]}', 'true', 'list concatenation'),
-- conversions
('int(s) == 12 && int(d) == 1 && int(-1.9) == -1 && int(u) == 3', '{"s": "string", "d": "double", "u": "uint"}', '{"s": "12", "d": 1.9, "u": 3}', 'true', 'int()'),
('int(s) == 1', '{"s": "string"}', '{"s": "1.5"}', '2000', 'int() of a non-integer string is an error'),
('int(t) == 10', '{"t": "timestamp"}', '{"t": "1970-01-01T00:00:10Z"}', 'true', 'int() of a timestamp is Unix seconds'),
('uint(x) == 5u', '{"x": "int"}', '{"x": 5}', 'true', 'uint()'),
('uint(x) == 5u', '{"x": "int"}', '{"x": -1}', '2000', 'uint() of a negative is an error'),
('double(x) == 2.0 && double(s) == 2.5', '{"x": "int", "s": "string"}', '{"x": 2, "s": "2.5"}', 'true', 'double()'),
('string(x) == "5" && string(d) == "1.5" && string(b) == "true" && string(u) == "7"', '{"x": "int", "d": "double", "b": "bool", "u": "uint"}', '{"x": 5, "d": 1.5, "b": true, "u": 7}', 'true', 'string() of numbers and bools'),
('string(t) == "2023-01-01T00:00:00.5Z" && string(du) == "5400s"', '{"t": "timestamp", "du": "duration"}', '{"t": "2023-01-01T00:00:00.500Z", "du": "1h30m"}', 'true', 'string() of a timestamp and a duration'),
('bool(s)', '{"s": "string"}', '{"s": "true"}', 'true', 'bool()'),
('bool(s)', '{"s": "string"}', '{"s": "nope"}', '2000', 'bool() of anything else is an error'),
('timestamp(s) == timestamp("2023-01-01T00:00:00Z") && timestamp(x) == timestamp("1970-01-01T00:00:10Z")', '{"s": "string", "x": "int"}', '{"s": "2023-01-01T02:00:00+02:00", "x": 10}', 'true', 'timestamp() of a string and of Unix seconds'),
('timestamp(s) < timestamp("2030-01-01T00:00:00Z")', '{"s": "string"}', '{"s": "yesterday"}', '2000', 'timestamp() of a bad string is an error'),
('duration(s) == duration("90m")', '{"s": "string"}', '{"s": "1h30m"}', 'true', 'duration()'),
('timestamp("bad") < t', '{"t": "timestamp"}', '{"t": "2023-01-01T00:00:00Z"}', '2000', 'an invalid literal timestamp is accepted at write and fails at evaluation, as cel-go'),
-- timestamps and durations
('t + d > timestamp("2023-01-01T00:00:00Z")', '{"t": "timestamp", "d": "duration"}', '{"t": "2022-12-31T23:30:00Z", "d": "1h"}', 'true', 'timestamp + duration (P21)'),
('t + d > timestamp("2023-01-01T00:00:00Z")', '{"t": "timestamp", "d": "duration"}', '{"t": "2022-12-31T22:45:00Z", "d": "1h30m"}', 'true', '... "1h30m" (P21)'),
('t + d > timestamp("2023-01-01T00:00:00Z")', '{"t": "timestamp", "d": "duration"}', '{"t": "2023-01-01T01:30:00+02:00", "d": "1h"}', 'true', '... with an offset (P21)'),
('d + t == timestamp("2023-01-01T01:00:00Z") && t - d == timestamp("2022-12-31T23:00:00Z")', '{"t": "timestamp", "d": "duration"}', '{"t": "2023-01-01T00:00:00Z", "d": "1h"}', 'true', 'duration + timestamp, timestamp - duration'),
('t2 - t1 == duration("24h") && t1 - t2 < duration("0s")', '{"t1": "timestamp", "t2": "timestamp"}', '{"t1": "2022-12-31T00:00:00Z", "t2": "2023-01-01T00:00:00Z"}', 'true', 'timestamp - timestamp is a duration'),
('d1 + d2 == duration("2h") && d1 - d2 == duration("0s") && d1 > duration("59m")', '{"d1": "duration", "d2": "duration"}', '{"d1": "1h", "d2": "60m"}', 'true', 'duration arithmetic and comparison'),
('t < t2', '{"t": "timestamp", "t2": "timestamp"}', '{"t": "2023-01-01T01:00:00+02:00", "t2": "2023-01-01T00:00:00Z"}', 'true', 'timestamps compare as instants'),
('t.getFullYear() == 2024 && t.getMonth() == 1 && t.getDate() == 29 && t.getDayOfMonth() == 28 && t.getDayOfYear() == 59 && t.getDayOfWeek() == 4', '{"t": "timestamp"}', '{"t": "2024-02-29T23:59:59.123Z"}', 'true', 'timestamp date getters (months, days of month and year 0-based, getDate 1-based)'),
('t.getHours() == 23 && t.getMinutes() == 59 && t.getSeconds() == 59 && t.getMilliseconds() == 123', '{"t": "timestamp"}', '{"t": "2024-02-29T23:59:59.123456789Z"}', 'true', 'timestamp time getters'),
('t.getHours("Europe/Paris") == 12 && t.getHours("+02:00") == 12 && t.getHours("-01:00") == 9 && t.getDayOfWeek() == 0', '{"t": "timestamp"}', '{"t": "2024-07-07T10:00:00Z"}', 'true', 'getters in a time zone or at an offset (P40)'),
('t.getHours("Nowhere/Nope") == 1', '{"t": "timestamp"}', '{"t": "2024-07-07T10:00:00Z"}', '2000', 'an unknown time zone is an error'),
('d.getHours() == 1 && d.getMinutes() == 90 && d.getSeconds() == 5400 && d.getMilliseconds() == 5400000', '{"d": "duration"}', '{"d": "1h30m"}', 'true', 'duration getters (totals)'),
('t + d > t', '{"t": "timestamp", "d": "duration"}', '{"t": "9999-12-31T23:00:00Z", "d": "2h"}', '2000', 'a timestamp past year 9999 is an error'),
-- macros
('l.all(e, e > 0)', '{"l": "list<int>"}', '{"l": [1, 2]}', 'true', 'all'),
('l.all(e, e > 0)', '{"l": "list<int>"}', '{"l": [1, -1]}', 'false', 'all, one false'),
('l.exists(e, e > 1)', '{"l": "list<int>"}', '{"l": [1, 2]}', 'true', 'exists'),
('l.exists_one(e, e == 1)', '{"l": "list<int>"}', '{"l": [1, 2]}', 'true', 'exists_one'),
('l.exists_one(e, e == 1)', '{"l": "list<int>"}', '{"l": [1, 1]}', 'false', 'exists_one, two'),
('l.map(e, e * 2) == [2, 4] && l.map(e, e > 1, e * 10) == [20] && l.filter(e, e > 1) == [2]', '{"l": "list<int>"}', '{"l": [1, 2]}', 'true', 'map and filter'),
('m.all(k, k.startsWith("a")) && m.exists(k, m[k] == 2)', '{"m": "map<int>"}', '{"m": {"ab": 1, "ac": 2}}', 'true', 'a macro over a map ranges over its keys'),
('l.exists(e, 10 / e == 5)', '{"l": "list<int>"}', '{"l": [0, 2]}', 'true', 'exists absorbs an error when another element is true'),
('l.exists(e, 10 / e == 5)', '{"l": "list<int>"}', '{"l": [0, 3]}', '2000', 'exists with an error and no true element is an error'),
('l.all(e, 10 / e == 5)', '{"l": "list<int>"}', '{"l": [0, 3]}', 'false', 'all absorbs an error when another element is false'),
('l.all(e, 10 / e == 5)', '{"l": "list<int>"}', '{"l": [0, 2]}', '2000', 'all with an error and no false element is an error'),
-- ip addresses
('ipaddress("10.0.0.1").in_cidr("10.0.0.0/8") && ip == ipaddress("2001:db8::1")', '{"ip": "ipaddress"}', '{"ip": "2001:db8::1"}', 'true', 'ipaddress() and ipaddress equality'),
('ip.in_cidr("2001:db8::/32")', '{"ip": "ipaddress"}', '{"ip": "2001:db8::1"}', 'true', 'in_cidr, IPv6'),
('ip.in_cidr("10.0.0.0/8")', '{"ip": "ipaddress"}', '{"ip": "::ffff:10.1.2.3"}', 'true', 'an IPv4-mapped IPv6 address is its IPv4 address'),
('ip.in_cidr("::ffff:10.0.0.0/104")', '{"ip": "ipaddress"}', '{"ip": "10.0.0.5"}', 'true', 'an IPv4-mapped prefix matches IPv4 addresses'),
('ip.in_cidr("10.0.0.0/8")', '{"ip": "ipaddress"}', '{"ip": "2001:db8::1"}', 'false', 'an IPv6 address is not in an IPv4 prefix'),
('ip.in_cidr("10.0.0.0/33")', '{"ip": "ipaddress"}', '{"ip": "10.0.0.1"}', '2000', 'a malformed CIDR is an error'),
('ip.in_cidr("10.0.0.0/8")', '{"ip": "ipaddress"}', '{"ip": "10.0.0.256"}', '2000', 'a malformed address in the context is an error'),
('ip.in_cidr("fe80::/10")', '{"ip": "ipaddress"}', '{"ip": "fe80::1%eth0"}', '2000', 'an IPv6 zone is not accepted (deviation: OpenFGA keeps zones)'),
-- || and && absorb errors, commutatively (P17, P18)
('x < 100 || 10 / y == 1', '{"x": "int", "y": "int"}', '{"x": 10, "y": 0}', 'true', 'true || error is true (P17)'),
('10 / y == 1 || x < 100', '{"x": "int", "y": "int"}', '{"x": 10, "y": 0}', 'true', 'error || true is true (P17)'),
('10 / y == 1 || x < 100', '{"x": "int", "y": "int"}', '{"x": 200, "y": 0}', '2000', 'error || false is an error (P18)'),
('x > 100 && 10 / y == 1', '{"x": "int", "y": "int"}', '{"x": 10, "y": 0}', 'false', 'false && error is false'),
('10 / y == 1 && x > 100', '{"x": "int", "y": "int"}', '{"x": 10, "y": 0}', 'false', 'error && false is false'),
('!(10 / y == 1)', '{"y": "int"}', '{"y": 0}', '2000', '! of an error is an error'),
-- context values, as OpenFGA converts them (P10, P11, P20, P22, P24, P31, P32)
('x == 10', '{"x": "int"}', '{"x": "10"}', 'true', 'int given a numeric string (P10)'),
('x == 10', '{"x": "int"}', '{"x": 10.0}', 'true', 'int given 10.0 (P10)'),
('x == 10', '{"x": "int"}', '{"x": "1e1"}', 'true', 'int given "1e1" (P10)'),
('x == -5', '{"x": "int"}', '{"x": -5}', 'true', 'int given -5 (P10)'),
('x < 100', '{"x": "int"}', '{"x": 1e30}', 'false', 'int given 1e30 is clamped to the largest int (P10)'),
('x < 100', '{"x": "int"}', '{"x": 10.5}', '2000', 'int given 10.5 is an error (P11)'),
('x < 100', '{"x": "int"}', '{"x": true}', '2000', 'int given true is an error (P11)'),
('x < 100', '{"x": "int"}', '{"x": "0x10"}', '2000', 'int given "0x10" is an error (P11)'),
('x < 100', '{"x": "int"}', '{"x": null}', '2000', 'int given null is an error (P11)'),
('u > 0u', '{"u": "uint"}', '{"u": -1}', '2000', 'uint given -1 is an error (P31)'),
('u == 9223372036854775807u', '{"u": "uint"}', '{"u": 1e19}', 'true', 'uint given 1e19 is clamped to the largest int (P31)'),
('d > 0.0', '{"d": "double"}', '{"d": 0.1}', 'true', 'double given the number 0.1 (P32)'),
('d > 0.0', '{"d": "double"}', '{"d": "1.5"}', 'true', 'double given the string "1.5", exactly a float64 (P32)'),
('d > 0.0', '{"d": "double"}', '{"d": "0.1"}', '2000', 'double given the string "0.1", not exactly a float64 (P32)'),
('d > 0.0', '{"d": "double"}', '{"d": "1e400"}', '2000', 'double given "1e400" (P32)'),
('l.size() > 0', '{"l": "list<string>"}', '{"l": ["a", 1]}', '2000', 'a list<string> given a number element (P20)'),
('d > duration("0s")', '{"d": "duration"}', '{"d": "1d"}', '2000', 'a duration "1d" (not a Go duration) is an error (P22)'),
('t > timestamp("2000-01-01T00:00:00Z")', '{"t": "timestamp"}', '{"t": "2023-10-11T11:00.000Z"}', '2000', 'a timestamp without seconds is an error (P22)'),
('t > timestamp("2000-01-01T00:00:00Z")', '{"t": "timestamp"}', '{"t": "2023-01-01t01:30:00z"}', '2000', 'a timestamp with lower-case t and z is an error (P22)'),
('a == 1', '{"a": "any"}', '{"a": 1}', 'true', 'any == 1 given 1 (P24)'),
('a == 1', '{"a": "any"}', '{"a": "1"}', 'false', 'any == 1 given "1" is false, not an error (P24)'),
('a < 5', '{"a": "any"}', '{"a": 3}', 'true', 'any < int compares numbers (P41)'),
('a.b == "x" && a.n == 2.0', '{"a": "any"}', '{"a": {"b": "x", "n": 2}}', 'true', 'fields of an any map; its numbers are doubles'),
('a + 1 == 2', '{"a": "any"}', '{"a": 1}', '2000', 'an any number is a double: + int has no overload'),
('l.exists(e, e == "zzz")', '{"l": "list<string>"}', '{"l": ["a", "b", "zzz"]}', 'true', 'exists over 3 strings (P19)'),
('l.exists(e, e == "zzz")', '{"l": "list<string>"}', '{"l": ["a", "a", "a", "a", "a", "a", "a", "a", "a", "a"]}', 'false', 'exists over 10 strings is within the cost limit (P38)'),
('l.exists(e, e == "zzz")', '{"l": "list<string>"}', (select jsonb_build_object('l', jsonb_agg('a'::text)) from generate_series(1, 20)), '2000', 'exists over 20 strings exceeds the cost limit (P38)'),
('l.exists(e, e == "zzz")', '{"l": "list<string>"}', (select jsonb_build_object('l', jsonb_agg('a'::text)) from generate_series(1, 50)), '2000', 'exists over 50 strings exceeds the cost limit (P19)'),
((select string_agg('x == ' || g, ' || ') from generate_series(1, 35) g), '{"x": "int"}', '{"x": 99}', 'false', 'a 35-term || chain is within the cost limit (P38)'),
-- parameters
('x < 100 || y < 50', '{"x": "int", "y": "int"}', '{"x": 10}', '2000', 'a missing parameter is an error even when || is already true'),
('x < 100', '{"x": "int"}', '{"x": 10, "zz": "ignored"}', 'true', 'a request key no parameter has is ignored (P13)'),
('true', '{}', '{}', 'true', 'a condition with no parameters'),
('true', '{}', '{"z": 1}', '2000', 'a condition with no parameters and a non-empty context is an error (P39)');

insert into cases (expr, params, ctx, want, label, tctx) values
('x < 100', '{"x": "int"}', '{"x": 200}', 'true', 'the tuple''s context wins over the request''s (P5)', '{"x": 10}'),
('x < 100 && y == 1', '{"x": "int", "y": "int"}', '{"x": 200, "y": 1}', 'true', 'the request supplies what the tuple''s context lacks', '{"x": 10}'),
('l.size() == 2', '{"l": "list<string>"}', null, 'true', 'a list in a stored context', '{"l": ["a", "b"]}');

select tap.plan((select count(*)::int from cases));
select tap.is(case when g like 'openfga:2000 %' then '2000' when g like 'openfga:2056 %' then '2056' else g end,
              c.want, format('%s: %s', c.label, c.expr))
from cases c cross join lateral (select pg_temp.cel(c.expr, c.params, c.ctx, c.tctx) as g) r
order by c.n;

select * from tap.finish();
