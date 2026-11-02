-- Goal: the Cedar extension types follow Cedar 4.14 (phases 4a and 4b of
-- research/plan-cedar.md; research/designs/e-cedar.md section 14), on the
-- edges the corpus leaves thin. Every constructor and method, with the
-- boundary values: decimal's 4 digits and i64 / 10^4 range, ip's prefixes,
-- leading zeros, embedded IPv4, zones and its 43-byte limit, datetime's
-- formats, offsets, years 0000 to 9999 and its i64 arithmetic, duration's
-- unit order and i64 range, and the truncation of the duration conversions.
-- < and the other operators compare two datetimes or two durations, not two
-- decimals; isInRange takes one range; a constructor checks its string only
-- when it is evaluated. Each expectation was checked against the Cedar 4.14
-- CLI (cedar evaluate). Then the {"__extn": ...} JSON form: entity data,
-- tags, the context and the overlay read it, cedar_read_entities writes it
-- back in a form Cedar reads, and a put of that output changes nothing.
\ir ../../fixtures/d/cedar.sql

create temp table cases (n serial, what text, cond text, want text);
insert into cases (what, cond, want) values
('decimal: the largest value', $c$decimal("922337203685477.5807").greaterThan(decimal("0.0"))$c$, 'true'),
('decimal: the smallest value', $c$decimal("-922337203685477.5808").lessThan(decimal("0.0"))$c$, 'true'),
('decimal: one past the largest', $c$decimal("922337203685477.5808") == decimal("0.0")$c$, 'error: extension_error%'),
('decimal: one past the smallest', $c$decimal("-922337203685477.5809") == decimal("0.0")$c$, 'error: extension_error%'),
('decimal: 4 fractional digits', $c$decimal("0.0001").greaterThan(decimal("0.0"))$c$, 'true'),
('decimal: 5 fractional digits', $c$decimal("0.00001") == decimal("0.0")$c$, 'error: extension_error%'),
('decimal: no digit after the point', $c$decimal("1.") == decimal("1.0")$c$, 'error: extension_error%'),
('decimal: no digit before the point', $c$decimal(".5") == decimal("0.5")$c$, 'error: extension_error%'),
('decimal: no point', $c$decimal("1") == decimal("1.0")$c$, 'error: extension_error%'),
('decimal: a plus sign', $c$decimal("+1.0") == decimal("1.0")$c$, 'error: extension_error%'),
('decimal: leading zeros', $c$decimal("007.50") == decimal("7.5")$c$, 'true'),
('decimal: trailing zeros are equal', $c$decimal("1.0") == decimal("1.0000")$c$, 'true'),
('decimal: -0.0 is 0.0', $c$decimal("-0.0") == decimal("0.0")$c$, 'true'),
('decimal: in a set', $c$[decimal("1.0"), decimal("1.00")] == [decimal("1.000")]$c$, 'true'),
('decimal: lessThan', $c$decimal("1.5").lessThan(decimal("1.50"))$c$, 'false'),
('decimal: lessThanOrEqual', $c$decimal("1.5").lessThanOrEqual(decimal("1.50"))$c$, 'true'),
('decimal: greaterThan negatives', $c$decimal("-1.5").greaterThan(decimal("-1.6"))$c$, 'true'),
('decimal: greaterThanOrEqual', $c$decimal("-1.5").greaterThanOrEqual(decimal("-1.4999"))$c$, 'false'),
('decimal: < does not compare decimals', $c$decimal("1.0") < decimal("2.0")$c$, 'error: type_error%'),
('decimal: a method on a Long', $c$decimal("1.0").lessThan(2)$c$, 'error: type_error%'),
('decimal: a method on a String', $c$decimal("1.0").lessThan("2.0")$c$, 'error: type_error%'),
('decimal: a constructor of a Long', $c$decimal(1) == decimal("1.0")$c$, 'error: type_error%'),
('decimal: == with a Long is false', $c$decimal("1.0") == 1$c$, 'false'),
('ip: IPv4', $c$ip("192.168.0.1").isIpv4() && !ip("192.168.0.1").isIpv6()$c$, 'true'),
('ip: IPv6', $c$ip("2001:db8::1").isIpv6() && !ip("2001:db8::1").isIpv4()$c$, 'true'),
('ip: /0', $c$ip("1.2.3.4/0").isInRange(ip("0.0.0.0/0"))$c$, 'true'),
('ip: /32 is the address', $c$ip("10.0.0.1/32") == ip("10.0.0.1")$c$, 'true'),
('ip: /33', $c$ip("10.0.0.1/33").isIpv4()$c$, 'error: extension_error%'),
('ip: /128 is the address', $c$ip("::1/128") == ip("::1")$c$, 'true'),
('ip: /129', $c$ip("::1/129").isIpv6()$c$, 'error: extension_error%'),
('ip: a leading zero in an octet', $c$ip("10.0.0.01").isIpv4()$c$, 'error: extension_error%'),
('ip: a leading zero in the prefix', $c$ip("10.0.0.0/08").isIpv4()$c$, 'error: extension_error%'),
('ip: an empty prefix', $c$ip("10.0.0.0/").isIpv4()$c$, 'error: extension_error%'),
('ip: an octet over 255', $c$ip("10.0.0.256").isIpv4()$c$, 'error: extension_error%'),
('ip: three octets', $c$ip("10.0.1").isIpv4()$c$, 'error: extension_error%'),
('ip: IPv4 embedded in IPv6', $c$ip("::ffff:10.0.0.1").isIpv6()$c$, 'error: extension_error%'),
('ip: an IPv4-mapped address in hex is IPv6', $c$ip("::ffff:a00:1").isIpv6() && ip("::ffff:a00:1") != ip("10.0.0.1")$c$, 'true'),
('ip: an IPv4-mapped loopback is not loopback', $c$ip("::ffff:7f00:1").isLoopback()$c$, 'false'),
('ip: a zone id', $c$ip("fe80::1%eth0").isIpv6()$c$, 'error: extension_error%'),
('ip: brackets', $c$ip("[::1]").isIpv6()$c$, 'error: extension_error%'),
('ip: two ::', $c$ip("1::2::3").isIpv6()$c$, 'error: extension_error%'),
('ip: :: for one group', $c$ip("1:2:3:4:5:6:7::") == ip("1:2:3:4:5:6:7:0")$c$, 'true'),
('ip: nine groups', $c$ip("1:2:3:4:5:6:7:8:9").isIpv6()$c$, 'error: extension_error%'),
('ip: 43 bytes', $c$ip("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/128").isIpv6()$c$, 'true'),
('ip: 44 bytes', $c$ip("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/0128").isIpv6()$c$, 'error: extension_error%'),
('ip: case-insensitive hex', $c$ip("ABCD::EF") == ip("abcd::ef")$c$, 'true'),
('ip: equality keeps the host bits', $c$ip("10.0.0.1/24") == ip("10.0.0.0/24")$c$, 'false'),
('ip: isInRange of a host', $c$ip("10.1.2.3").isInRange(ip("10.0.0.0/8"))$c$, 'true'),
('ip: isInRange of the range itself', $c$ip("10.0.0.0/8").isInRange(ip("10.0.0.0/8"))$c$, 'true'),
('ip: isInRange with host bits in the range', $c$ip("10.0.0.7").isInRange(ip("10.0.0.1/24"))$c$, 'true'),
('ip: isInRange of a wider range', $c$ip("10.0.0.0/7").isInRange(ip("10.0.0.0/8"))$c$, 'false'),
('ip: isInRange at the broadcast edge', $c$ip("10.255.255.255").isInRange(ip("10.0.0.0/8")) && !ip("11.0.0.0").isInRange(ip("10.0.0.0/8"))$c$, 'true'),
('ip: isInRange across families', $c$ip("10.0.0.1").isInRange(ip("::/0"))$c$, 'false'),
('ip: isInRange takes one range', $c$ip("10.0.0.1").isInRange(ip("11.0.0.0/8"), ip("10.0.0.0/8"))$c$, 'error: extension_error%'),
('ip: isInRange of a String', $c$ip("10.0.0.1").isInRange("10.0.0.0/8")$c$, 'error: type_error%'),
('ip: isLoopback /8', $c$ip("127.255.0.1/8").isLoopback()$c$, 'true'),
('ip: isLoopback /7', $c$ip("127.0.0.1/7").isLoopback()$c$, 'false'),
('ip: isLoopback ::1/127', $c$ip("::1/127").isLoopback()$c$, 'false'),
('ip: isMulticast /4', $c$ip("239.255.255.255/4").isMulticast()$c$, 'true'),
('ip: isMulticast /3', $c$ip("224.0.0.0/3").isMulticast()$c$, 'false'),
('ip: isMulticast IPv6', $c$ip("ff02::1").isMulticast() && !ip("ff00::/7").isMulticast()$c$, 'true'),
('datetime: a date', $c$datetime("2024-01-01") == datetime("2024-01-01T00:00:00Z")$c$, 'true'),
('datetime: milliseconds', $c$datetime("2024-01-01T00:00:00.001Z") > datetime("2024-01-01T00:00:00Z")$c$, 'true'),
('datetime: an offset', $c$datetime("2024-01-01T01:00:00+0100") == datetime("2024-01-01")$c$, 'true'),
('datetime: a negative offset with milliseconds', $c$datetime("2023-12-31T23:30:00.500-0030") == datetime("2024-01-01T00:00:00.500Z")$c$, 'true'),
('datetime: offset +2359', $c$datetime("2024-01-01T00:00:00+2359") < datetime("2024-01-01")$c$, 'true'),
('datetime: offset +2400', $c$datetime("2024-01-01T00:00:00+2400") == datetime("2024-01-01")$c$, 'error: extension_error%'),
('datetime: offset minutes 60', $c$datetime("2024-01-01T00:00:00+0060") == datetime("2024-01-01")$c$, 'error: extension_error%'),
('datetime: offset with a colon', $c$datetime("2024-01-01T00:00:00+01:00") == datetime("2024-01-01")$c$, 'error: extension_error%'),
('datetime: no Z', $c$datetime("2024-01-01T00:00:00") == datetime("2024-01-01")$c$, 'error: extension_error%'),
('datetime: two fraction digits', $c$datetime("2024-01-01T00:00:00.00Z") == datetime("2024-01-01")$c$, 'error: extension_error%'),
('datetime: hour 24', $c$datetime("2024-01-01T24:00:00Z") == datetime("2024-01-02")$c$, 'error: extension_error%'),
('datetime: a leap second', $c$datetime("2016-12-31T23:59:60Z") == datetime("2017-01-01")$c$, 'error: extension_error%'),
('datetime: 29 February of a leap year', $c$datetime("2024-02-29").offset(duration("1d")) == datetime("2024-03-01")$c$, 'true'),
('datetime: 29 February of 1900', $c$datetime("1900-02-29") == datetime("1900-03-01")$c$, 'error: extension_error%'),
('datetime: 29 February of 2000', $c$datetime("2000-02-29") < datetime("2000-03-01")$c$, 'true'),
('datetime: year 0000', $c$datetime("0000-01-01") < datetime("0001-01-01")$c$, 'true'),
('datetime: year 9999', $c$datetime("9999-12-31T23:59:59.999Z") > datetime("0000-01-01")$c$, 'true'),
('datetime: five-digit year', $c$datetime("10000-01-01") == datetime("0000-01-01")$c$, 'error: extension_error%'),
('datetime: lower-case t', $c$datetime("2024-01-01t00:00:00Z") == datetime("2024-01-01")$c$, 'error: extension_error%'),
('datetime: comparison operators', $c$datetime("2024-01-01") <= datetime("2024-01-01") && datetime("2024-01-02") >= datetime("2024-01-01")$c$, 'true'),
('datetime: < with a duration', $c$datetime("2024-01-01") < duration("1d")$c$, 'error: type_error%'),
('datetime: == with a duration is false', $c$datetime("1970-01-01") == duration("0ms")$c$, 'false'),
('datetime: offset', $c$datetime("2024-01-01").offset(duration("-1d")) == datetime("2023-12-31")$c$, 'true'),
('datetime: offset to the largest', $c$datetime("1970-01-01").offset(duration("9223372036854775807ms")) > datetime("9999-12-31")$c$, 'true'),
('datetime: offset past the largest', $c$datetime("1970-01-01").offset(duration("9223372036854775807ms")).offset(duration("1ms")) > datetime("1970-01-01")$c$, 'error: extension_error%'),
('datetime: offset with a datetime', $c$datetime("2024-01-01").offset(datetime("2024-01-01")) == datetime("2024-01-01")$c$, 'error: type_error%'),
('datetime: durationSince', $c$datetime("2024-03-01").durationSince(datetime("2024-02-01")) == duration("29d")$c$, 'true'),
('datetime: durationSince negative', $c$datetime("2024-01-01").durationSince(datetime("2024-01-02")) == duration("-1d")$c$, 'true'),
('datetime: durationSince overflows', $c$datetime("1970-01-01").offset(duration("-9223372036854775808ms")).durationSince(datetime("1970-01-01T00:00:00.001Z")) == duration("0ms")$c$, 'error: extension_error%'),
('datetime: toDate', $c$datetime("2024-10-15T11:35:00+0200").toDate() == datetime("2024-10-15")$c$, 'true'),
('datetime: toDate before 1970', $c$datetime("1969-12-31T23:59:59.999Z").toDate() == datetime("1969-12-31")$c$, 'true'),
('datetime: toDate of the smallest', $c$datetime("1970-01-01").offset(duration("-9223372036854775808ms")).toDate() == datetime("1970-01-01")$c$, 'error: extension_error%'),
('datetime: toTime', $c$datetime("2024-10-15T11:35:00Z").toTime() == duration("11h35m")$c$, 'true'),
('datetime: toTime before 1970', $c$datetime("1969-12-31T23:00:00Z").toTime() == duration("23h")$c$, 'true'),
('datetime: toTime of the smallest', $c$datetime("1970-01-01").offset(duration("-9223372036854775808ms")).toTime() == duration("16h47m4s192ms")$c$, 'true'),
('duration: every unit', $c$duration("1d2h3m4s5ms") == duration("93784005ms")$c$, 'true'),
('duration: negative', $c$duration("-1d1h") == duration("-25h")$c$, 'true'),
('duration: -0', $c$duration("-0ms") == duration("0d")$c$, 'true'),
('duration: units out of order', $c$duration("1h1d") == duration("25h")$c$, 'error: extension_error%'),
('duration: a repeated unit', $c$duration("1d1d") == duration("2d")$c$, 'error: extension_error%'),
('duration: no unit', $c$duration("0") == duration("0ms")$c$, 'error: extension_error%'),
('duration: empty', $c$duration("") == duration("0ms")$c$, 'error: extension_error%'),
('duration: a sign alone', $c$duration("-") == duration("0ms")$c$, 'error: extension_error%'),
('duration: a plus sign', $c$duration("+1d") == duration("1d")$c$, 'error: extension_error%'),
('duration: a fraction', $c$duration("1.5h") == duration("90m")$c$, 'error: extension_error%'),
('duration: upper-case unit', $c$duration("1D") == duration("1d")$c$, 'error: extension_error%'),
('duration: the largest', $c$duration("9223372036854775807ms") > duration("0ms")$c$, 'true'),
('duration: past the largest', $c$duration("9223372036854775808ms") > duration("0ms")$c$, 'error: extension_error%'),
('duration: the smallest', $c$duration("-9223372036854775808ms") < duration("0ms")$c$, 'true'),
('duration: past the smallest', $c$duration("-9223372036854775809ms") < duration("0ms")$c$, 'error: extension_error%'),
('duration: days past the largest', $c$duration("106751991168d") > duration("0ms")$c$, 'error: extension_error%'),
('duration: toMilliseconds', $c$duration("1s5ms").toMilliseconds() == 1005$c$, 'true'),
('duration: toSeconds truncates', $c$duration("1999ms").toSeconds() == 1 && duration("-1999ms").toSeconds() == -1$c$, 'true'),
('duration: toMinutes', $c$duration("119s").toMinutes() == 1 && duration("-119s").toMinutes() == -1$c$, 'true'),
('duration: toHours', $c$duration("90m").toHours() == 1 && duration("-90m").toHours() == -1$c$, 'true'),
('duration: toDays', $c$duration("-1d23h").toDays() == -1 && duration("-23h59m").toDays() == 0$c$, 'true'),
('duration: toDays of the smallest', $c$duration("-9223372036854775808ms").toDays() == -106751991167$c$, 'true'),
('duration: comparison operators', $c$duration("1d") > duration("23h") && duration("1d") >= duration("24h") && duration("-1ms") < duration("0ms")$c$, 'true'),
('duration: == across forms', $c$duration("1d") == duration("86400000ms")$c$, 'true'),
('duration: a method on a datetime', $c$datetime("2024-01-01").toDays() == 0$c$, 'error: type_error%'),
('calls: a wrong number of arguments', $c$datetime("2024-01-01").toDate(1) == datetime("2024-01-01")$c$, 'error: extension_error%'),
('calls: no argument', $c$ip("10.0.0.1").isInRange()$c$, 'error: extension_error%'),
('calls: an invalid literal errs when evaluated', $c$false && decimal("x") == decimal("1.0")$c$, 'false'),
('calls: an argument error comes first', $c$decimal(principal.nope) == decimal("1.0")$c$, 'error: entity_does_not_exist%'),
('calls: has on an extension value', $c$ip("10.0.0.1") has a$c$, 'error: type_error%'),
('calls: like on an extension value', $c$decimal("1.0") like "*"$c$, 'error: type_error%'),
('calls: a record of extension values', $c${a: ip("10.0.0.1"), b: decimal("1.0")} == {b: decimal("1.0000"), a: ip("10.0.0.1/32")}$c$, 'true'),
('calls: contains', $c$[datetime("2024-01-01"), duration("1h")].contains(datetime("2024-01-01T00:00:00Z"))$c$, 'true');

select tap.plan((select count(*)::int from cases) + 16);

select tap.ok(r.got like c.want, format('%s: %s', c.what, left(r.got, 150)))
from cases c cross join lateral (select cedar_t.eval_text(c.cond) as got) r
order by c.n;

-- the messages
select tap.is(cedar_t.eval_text('decimal("1.23456") == decimal("1.0")'),
              'error: extension_error: decimal("1.23456") is not valid: a decimal has digits on both sides of the point, at most 4 after it, and lies within -922337203685477.5808 and 922337203685477.5807, like "12.34"',
              'an invalid constructor string names the string and the format');
select tap.is(cedar_t.eval_text('datetime("2024-01-01").offset(1) == datetime("2024-01-01")'),
              'error: type_error: offset: expected duration, got Long', 'a method''s type error names the types');

-- a constructor of a valid string literal is folded into its value when the
-- policy is put; an invalid one stays a call and errs when it is evaluated
select permissions.cedar_put_policy(policy_id => 'fold', policy => 'permit (principal, action, resource) when { context.d == decimal("1.50") && context.d != decimal("x") };');
select tap.is((select ast from permissions.cedar_policies where policy_id = 'fold'),
              '{"k": "and", "a": {"k": "eq", "a": {"k": "get", "a": {"k": "var", "n": "context"}, "f": "d"},
                                           "b": {"k": "lit", "v": {"__extn": {"fn": "decimal", "v": 15000}}}},
                            "b": {"k": "ne", "a": {"k": "get", "a": {"k": "var", "n": "context"}, "f": "d"},
                                           "b": {"k": "call", "f": "decimal", "a": [{"k": "lit", "v": "x"}]}}}'::jsonb,
              'decimal("1.50") is folded to its value; decimal("x") stays a call');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"', '{"d": {"__extn": {"fn": "decimal", "arg": "1.5"}}}'),
              'deny [] errors [fold]', 'the invalid literal errs when it is evaluated');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"', '{"d": {"__extn": {"fn": "decimal", "arg": "2.0"}}}'),
              'deny [] errors []', 'and && does not evaluate it when the left side is false');
select permissions.cedar_delete_policy(policy_id => 'fold');

-- {"__extn": ...} in entity data and tags: Cedar's {"fn", "arg"} and
-- {"fn", "args"} (Cedar writes a datetime as offset(datetime, duration))
select permissions.cedar_put_entities(entities => $j$[
  {"uid": {"type": "User", "id": "alice"}, "parents": [],
   "attrs": {"limit": {"__extn": {"fn": "decimal", "arg": "12.5"}},
             "ip": {"__extn": {"fn": "ip", "arg": "10.0.0.1"}},
             "net": {"__extn": {"fn": "ip", "arg": "::FFFF:A00:0/104"}},
             "since": {"__extn": {"fn": "datetime", "arg": "2024-10-15T11:35:00+0200"}},
             "ttl": {"__extn": {"fn": "duration", "arg": "1h30m"}},
             "late": {"__extn": {"fn": "datetime", "arg": "9999-12-31T23:59:59.999-2359"}},
             "epoch": {"__extn": {"fn": "offset", "args": [{"__extn": {"fn": "datetime", "arg": "1970-01-01"}}, {"__extn": {"fn": "duration", "arg": "-1ms"}}]}},
             "many": [{"__extn": {"fn": "decimal", "arg": "1.0"}}, {"__extn": {"fn": "decimal", "arg": "1.00"}}, {"__extn": {"fn": "ip", "args": ["10.0.0.1"]}}]},
   "tags": {"t": {"__extn": {"fn": "duration", "arg": "-1d"}}}}
]$j$);

-- cedar_read_entities writes the canonical text (the Cedar 4.14 CLI reads it
-- back to the same values); a datetime past 9999 in Cedar's offset form
select tap.is(permissions.cedar_read_entities(type => 'User'), $j$[
  {"uid": {"type": "User", "id": "alice"}, "parents": [],
   "attrs": {"limit": {"__extn": {"fn": "decimal", "arg": "12.5000"}},
             "ip": {"__extn": {"fn": "ip", "arg": "10.0.0.1/32"}},
             "net": {"__extn": {"fn": "ip", "arg": "::ffff:a00:0/104"}},
             "since": {"__extn": {"fn": "datetime", "arg": "2024-10-15T09:35:00.000Z"}},
             "ttl": {"__extn": {"fn": "duration", "arg": "5400000ms"}},
             "late": {"__extn": {"fn": "offset", "args": [{"__extn": {"fn": "datetime", "arg": "1970-01-01"}}, {"__extn": {"fn": "duration", "arg": "253402387139999ms"}}]}},
             "epoch": {"__extn": {"fn": "datetime", "arg": "1969-12-31T23:59:59.999Z"}},
             "many": [{"__extn": {"fn": "ip", "arg": "10.0.0.1/32"}}, {"__extn": {"fn": "decimal", "arg": "1.0000"}}]},
   "tags": {"t": {"__extn": {"fn": "duration", "arg": "-86400000ms"}}}}
]$j$::jsonb, 'cedar_read_entities writes each extension value as {"__extn": {"fn", "arg"}} with its canonical text');

create temp table before as select permissions.cedar_read_entities(type => 'User') as e;
select permissions.cedar_put_entities(entities => (select e from before));
select tap.is(permissions.cedar_read_entities(type => 'User'), (select e from before), 'a put of cedar_read_entities'' output changes nothing');

-- the stored values evaluate as their constructors do
select tap.is(cedar_t.eval_text($c$principal.ip.isInRange(ip("10.0.0.0/8")) && principal.net == ip("::ffff:a00:0/104")
                                 && principal.limit.greaterThan(decimal("12.4999")) && principal.since == datetime("2024-10-15T09:35:00Z")
                                 && principal.ttl == duration("90m") && principal.late > datetime("9999-12-31T23:59:59.999Z")
                                 && principal.epoch < datetime("1970-01-01") && principal.many.contains(decimal("1.0"))
                                 && principal.getTag("t").toDays() == -1$c$),
              'true', 'stored extension values in attrs and tags');

-- the context and the overlay read the same form
select tap.is(cedar_t.eval_text('context.now.durationSince(context.at) == duration("1d") && context.ip.isLoopback()',
                                '{"now": {"__extn": {"fn": "datetime", "arg": "2024-01-02"}}, "at": {"__extn": {"fn": "datetime", "arg": "2024-01-01"}},
                                  "ip": {"__extn": {"fn": "ip", "arg": "127.0.0.1"}}}'),
              'true', 'extension values in the context');
select tap.is(cedar_t.eval_text('resource.price.lessThan(decimal("10.00"))', null,
                                '[{"uid": {"type": "Doc", "id": "d1"}, "attrs": {"price": {"__extn": {"fn": "decimal", "arg": "9.99"}}}}]'),
              'true', 'extension values in the request overlay');

-- Cedar applies any extension function in data, a method too
select permissions.cedar_put_entities(entities => $j$[{"uid": {"type": "Doc", "id": "d1"}, "attrs": {
  "day": {"__extn": {"fn": "toDate", "arg": {"__extn": {"fn": "datetime", "arg": "2024-01-01T10:00:00Z"}}}},
  "v4": {"__extn": {"fn": "isIpv4", "arg": {"__extn": {"fn": "ip", "arg": "10.0.0.1"}}}}}}]$j$);
select tap.is(cedar_t.eval_text('resource.day == datetime("2024-01-01") && resource.v4 == true'), 'true',
              'toDate and isIpv4 in entity data hold their results');

-- in a policy, an extension value Cedar cannot build errs when it is
-- evaluated, as a call of its constructor would
select tap.is(cedar_t.eval('{"||": {"left": {"Value": true}, "right": {"==": {"left": {"Value": {"__extn": {"fn": "decimal", "arg": "1.23456"}}}, "right": {"Value": 1}}}}}'),
              'true', 'an invalid extension value in a policy is not an error until it is evaluated');
select tap.ok(cedar_t.eval('{"==": {"left": {"Value": [{"__extn": {"fn": "datetime", "arg": "2024-13-01"}}]}, "right": {"Value": 1}}}')
              like 'error: extension_error: datetime("2024-13-01") is not valid%', 'and errs when it is');

-- bad extension values are argument errors: they raise, with a hint
select tap.is(cedar_t.err($$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "attrs": {"x": {"__extn": {"fn": "lessThan", "arg": "1.0"}}}}]') $$),
              '22023 cedar:invalid_entity index=0', 'a method with the wrong arguments in data');
select tap.is(cedar_t.err($$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "attrs": {"x": {"__extn": {"fn": "offset", "args": [{"__extn": {"fn": "decimal", "arg": "1.0"}}, {"__extn": {"fn": "duration", "arg": "1h"}}]}}}}]') $$),
              '22023 cedar:invalid_entity index=0', 'offset in data takes a datetime and a duration');
select tap.ok((m).message like 'invalid entity at index 0 of entities: U::"a": attrs.d: extension_error: datetime("2024-02-30") is not valid: a datetime is %'
              and (m).hint like 'Write an extension value as {"__extn": {"fn": "decimal", "arg": "12.34"}}%',
              'an invalid extension value names the attribute and the format, and the hint shows the form')
from (select cedar_t.msg($$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "U", "id": "a"}, "attrs": {"d": {"__extn": {"fn": "datetime", "arg": "2024-02-30"}}}}]') $$) as m) x;

select * from tap.finish();
