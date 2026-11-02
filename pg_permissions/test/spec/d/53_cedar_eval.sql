-- Goal: the Cedar evaluator follows Cedar's semantics on the cases the corpus
-- leaves thin (research/designs/e-cedar.md section 4.2): && and || evaluate
-- the right side only when the left does not decide, and an error on a side
-- that is evaluated counts; == never errs; Long arithmetic errs on i64
-- overflow; like's * and its escape, and SQL's % and _ taken literally; has,
-- . and the tag methods on missing entities and attributes; whole-element
-- set operations; reflexive and transitive in; is ... in; sets and records
-- compared as values; a condition that is not a Bool is an error. Each case
-- is one condition, evaluated for User::"alice" viewing Doc::"d1"
-- (cedar_t.eval): true, false, or an error with Cedar's error kind.
\ir ../../fixtures/d/cedar.sql

select permissions.cedar_put_entities(entities => $j$[
  {"uid": {"type": "User", "id": "alice"}, "attrs": {"dept": "Eng", "level": 3}, "parents": [{"type": "Group", "id": "eng"}],
   "tags": {"t": "v", "n": 1}},
  {"uid": {"type": "Group", "id": "eng"}, "attrs": {}, "parents": []},
  {"uid": {"type": "Doc", "id": "d1"},
   "attrs": {"owner": {"__entity": {"type": "User", "id": "alice"}}, "meta": {"level": 1}, "labels": ["b", "a"]},
   "parents": [{"type": "Folder", "id": "f1"}]},
  {"uid": {"type": "Folder", "id": "f1"}, "attrs": {}, "parents": [{"type": "Folder", "id": "root"}]},
  {"uid": {"type": "Folder", "id": "root"}, "attrs": {}, "parents": []}
]$j$);

create temp table cases (n serial, what text, body jsonb, ctx jsonb, want text);
insert into cases (what, body, ctx, want) values
-- && and ||
('true', '{"Value": true}', null, 'true'),
('false && <error>: the right side is not evaluated', '{"&&": {"left": {"Value": false}, "right": {".": {"left": {"Var": "principal"}, "attr": "nope"}}}}', null, 'false'),
('true || <error>: the right side is not evaluated', '{"||": {"left": {"Value": true}, "right": {".": {"left": {"Var": "principal"}, "attr": "nope"}}}}', null, 'true'),
('false && 1: a right side that is not evaluated is not type-checked', '{"&&": {"left": {"Value": false}, "right": {"Value": 1}}}', null, 'false'),
('<error> && false: the left error counts', '{"&&": {"left": {".": {"left": {"Var": "principal"}, "attr": "nope"}}, "right": {"Value": false}}}', null, 'error: attribute_not_found%'),
('true && <error>', '{"&&": {"left": {"Value": true}, "right": {".": {"left": {"Var": "principal"}, "attr": "nope"}}}}', null, 'error: attribute_not_found%'),
('false || <error>', '{"||": {"left": {"Value": false}, "right": {".": {"left": {"Var": "principal"}, "attr": "nope"}}}}', null, 'error: attribute_not_found%'),
('1 && true: the left side must be a Bool', '{"&&": {"left": {"Value": 1}, "right": {"Value": true}}}', null, 'error: type_error%'),
('false || "x": the right side must be a Bool', '{"||": {"left": {"Value": false}, "right": {"Value": "x"}}}', null, 'error: type_error%'),
('!1', '{"!": {"arg": {"Value": 1}}}', null, 'error: type_error%'),
('!false', '{"!": {"arg": {"Value": false}}}', null, 'true'),
-- if-then-else
('if true then true else <error>', '{"if-then-else": {"if": {"Value": true}, "then": {"Value": true}, "else": {".": {"left": {"Var": "principal"}, "attr": "nope"}}}}', null, 'true'),
('if false then <error> else true', '{"if-then-else": {"if": {"Value": false}, "then": {".": {"left": {"Var": "principal"}, "attr": "nope"}}, "else": {"Value": true}}}', null, 'true'),
('if 1 then ...: the condition must be a Bool', '{"if-then-else": {"if": {"Value": 1}, "then": {"Value": true}, "else": {"Value": true}}}', null, 'error: type_error%'),
-- == and comparisons
('1 == "1" is false, not an error', '{"==": {"left": {"Value": 1}, "right": {"Value": "1"}}}', null, 'false'),
('1 != "1"', '{"!=": {"left": {"Value": 1}, "right": {"Value": "1"}}}', null, 'true'),
('principal == User::"alice"', '{"==": {"left": {"Var": "principal"}, "right": {"Value": {"__entity": {"type": "User", "id": "alice"}}}}}', null, 'true'),
('User::"alice" == Admin::"alice"', '{"==": {"left": {"Var": "principal"}, "right": {"Value": {"__entity": {"type": "Admin", "id": "alice"}}}}}', null, 'false'),
('[1, 2] == [2, 1, 1]: sets compare as sets', '{"==": {"left": {"Set": [{"Value": 1}, {"Value": 2}]}, "right": {"Set": [{"Value": 2}, {"Value": 1}, {"Value": 1}]}}}', null, 'true'),
('a computed set equals a literal one', '{"==": {"left": {"Set": [{".": {"left": {"Var": "principal"}, "attr": "level"}}, {"Value": 1}]}, "right": {"Value": [1, 3]}}}', null, 'true'),
('records compare as values', '{"==": {"left": {"Record": {"a": {"Value": 1}, "b": {"Set": [{"Value": 1}, {"Value": 2}]}}}, "right": {"Record": {"b": {"Set": [{"Value": 2}, {"Value": 1}]}, "a": {"Value": 1}}}}}', null, 'true'),
('an attribute set compares as a set', '{"==": {"left": {".": {"left": {"Var": "resource"}, "attr": "labels"}}, "right": {"Set": [{"Value": "a"}, {"Value": "b"}]}}}', null, 'true'),
('a context set compares as a set', '{"==": {"left": {".": {"left": {"Var": "context"}, "attr": "s"}}, "right": {"Set": [{"Value": 1}, {"Value": 3}]}}}', '{"s": [3, 1, 3]}', 'true'),
('1 < "2"', '{"<": {"left": {"Value": 1}, "right": {"Value": "2"}}}', null, 'error: type_error%'),
('"a" < "b": strings do not compare', '{"<": {"left": {"Value": "a"}, "right": {"Value": "b"}}}', null, 'error: type_error%'),
('-1 <= principal.level', '{"<=": {"left": {"Value": -1}, "right": {".": {"left": {"Var": "principal"}, "attr": "level"}}}}', null, 'true'),
-- Long arithmetic
('i64 max + 1 overflows', '{"+": {"left": {"Value": 9223372036854775807}, "right": {"Value": 1}}}', null, 'error: overflow%'),
('i64 min - 1 overflows', '{"-": {"left": {"Value": -9223372036854775808}, "right": {"Value": 1}}}', null, 'error: overflow%'),
('i64 max * 2 overflows', '{"*": {"left": {"Value": 9223372036854775807}, "right": {"Value": 2}}}', null, 'error: overflow%'),
('-(i64 min) overflows', '{"neg": {"arg": {"Value": -9223372036854775808}}}', null, 'error: overflow%'),
('-9223372036854775807 - 1 is i64 min', '{"==": {"left": {"-": {"left": {"Value": -9223372036854775807}, "right": {"Value": 1}}}, "right": {"Value": -9223372036854775808}}}', null, 'true'),
('an overflow in a branch not taken does not count', '{"if-then-else": {"if": {"Value": false}, "then": {"+": {"left": {"Value": 9223372036854775807}, "right": {"Value": 1}}}, "else": {"Value": true}}}', null, 'true'),
('"a" + 1', '{"+": {"left": {"Value": "a"}, "right": {"Value": 1}}}', null, 'error: type_error%'),
('-principal.level == -3', '{"==": {"left": {"neg": {"arg": {".": {"left": {"Var": "principal"}, "attr": "level"}}}}, "right": {"Value": -3}}}', null, 'true'),
-- like
('"a*b" like "a\*b": an escaped star is literal', '{"like": {"left": {"Value": "a*b"}, "pattern": [{"Literal": "a*b"}]}}', null, 'true'),
('"axb" like "a\*b"', '{"like": {"left": {"Value": "axb"}, "pattern": [{"Literal": "a*b"}]}}', null, 'false'),
('"axxb" like "a*b"', '{"like": {"left": {"Value": "axxb"}, "pattern": [{"Literal": "a"}, "Wildcard", {"Literal": "b"}]}}', null, 'true'),
('"1000" like "100%": % is literal', '{"like": {"left": {"Value": "1000"}, "pattern": [{"Literal": "100%"}]}}', null, 'false'),
('"100%" like "100%"', '{"like": {"left": {"Value": "100%"}, "pattern": [{"Literal": "100%"}]}}', null, 'true'),
('"abc" like "a_c": _ is literal', '{"like": {"left": {"Value": "abc"}, "pattern": [{"Literal": "a_c"}]}}', null, 'false'),
('"x\\y" like "*\\y": a backslash is literal', '{"like": {"left": {"Value": "x\\y"}, "pattern": ["Wildcard", {"Literal": "\\y"}]}}', null, 'true'),
('"a\nb" like "a*": * matches a newline', '{"like": {"left": {"Value": "a\nb"}, "pattern": [{"Literal": "a"}, "Wildcard"]}}', null, 'true'),
('"ABC" like "abc": case matters', '{"like": {"left": {"Value": "ABC"}, "pattern": [{"Literal": "abc"}]}}', null, 'false'),
('1 like "*"', '{"like": {"left": {"Value": 1}, "pattern": ["Wildcard"]}}', null, 'error: type_error%'),
-- has, . and tags
('principal has dept', '{"has": {"left": {"Var": "principal"}, "attr": "dept"}}', null, 'true'),
('principal has nope', '{"has": {"left": {"Var": "principal"}, "attr": "nope"}}', null, 'false'),
('User::"nobody" has dept: false, not an error', '{"has": {"left": {"Value": {"__entity": {"type": "User", "id": "nobody"}}}, "attr": "dept"}}', null, 'false'),
('User::"nobody".dept', '{".": {"left": {"Value": {"__entity": {"type": "User", "id": "nobody"}}}, "attr": "dept"}}', null, 'error: entity_does_not_exist%'),
('principal.nope', '{".": {"left": {"Var": "principal"}, "attr": "nope"}}', null, 'error: attribute_not_found%'),
('1 has a', '{"has": {"left": {"Value": 1}, "attr": "a"}}', null, 'error: type_error%'),
('{"a": 1} has a', '{"has": {"left": {"Record": {"a": {"Value": 1}}}, "attr": "a"}}', null, 'true'),
('{"a": 1}.b', '{".": {"left": {"Record": {"a": {"Value": 1}}}, "attr": "b"}}', null, 'error: attribute_not_found%'),
('resource has meta.level', '{"has": {"left": {"Var": "resource"}, "attr": ["meta", "level"]}}', null, 'true'),
('resource has meta.nope', '{"has": {"left": {"Var": "resource"}, "attr": ["meta", "nope"]}}', null, 'false'),
('resource has nope.x: false, the second step is not taken', '{"has": {"left": {"Var": "resource"}, "attr": ["nope", "x"]}}', null, 'false'),
('resource.owner.dept == "Eng"', '{"==": {"left": {".": {"left": {".": {"left": {"Var": "resource"}, "attr": "owner"}}, "attr": "dept"}}, "right": {"Value": "Eng"}}}', null, 'true'),
('principal.hasTag("t")', '{"hasTag": {"left": {"Var": "principal"}, "right": {"Value": "t"}}}', null, 'true'),
('principal.getTag("n") == 1', '{"==": {"left": {"getTag": {"left": {"Var": "principal"}, "right": {"Value": "n"}}}, "right": {"Value": 1}}}', null, 'true'),
('principal.getTag("x")', '{"getTag": {"left": {"Var": "principal"}, "right": {"Value": "x"}}}', null, 'error: tag_not_found%'),
('User::"nobody".hasTag("t")', '{"hasTag": {"left": {"Value": {"__entity": {"type": "User", "id": "nobody"}}}, "right": {"Value": "t"}}}', null, 'false'),
('User::"nobody".getTag("t")', '{"getTag": {"left": {"Value": {"__entity": {"type": "User", "id": "nobody"}}}, "right": {"Value": "t"}}}', null, 'error: entity_does_not_exist%'),
('principal.hasTag(1)', '{"hasTag": {"left": {"Var": "principal"}, "right": {"Value": 1}}}', null, 'error: type_error%'),
('resource.hasTag("t"): an entity without tags', '{"hasTag": {"left": {"Var": "resource"}, "right": {"Value": "t"}}}', null, 'false'),
('{"t": 1}.hasTag("t"): tags are on entities only', '{"hasTag": {"left": {"Record": {"t": {"Value": 1}}}, "right": {"Value": "t"}}}', null, 'error: type_error%'),
-- sets
('[1, 2].contains(1)', '{"contains": {"left": {"Value": [1, 2]}, "right": {"Value": 1}}}', null, 'true'),
('[{"a": 1, "b": 2}].contains({"a": 1}): whole elements only', '{"contains": {"left": {"Value": [{"a": 1, "b": 2}]}, "right": {"Value": {"a": 1}}}}', null, 'false'),
('[[1, 2]].contains([1])', '{"contains": {"left": {"Value": [[1, 2]]}, "right": {"Value": [1]}}}', null, 'false'),
('[[1, 2]].contains([2, 1])', '{"contains": {"left": {"Value": [[1, 2]]}, "right": {"Set": [{"Value": 2}, {"Value": 1}]}}}', null, 'true'),
('[1].containsAll([])', '{"containsAll": {"left": {"Value": [1]}, "right": {"Value": []}}}', null, 'true'),
('[1, 2].containsAll([2, 1])', '{"containsAll": {"left": {"Value": [1, 2]}, "right": {"Value": [2, 1]}}}', null, 'true'),
('[1].containsAll([1, 3])', '{"containsAll": {"left": {"Value": [1]}, "right": {"Value": [1, 3]}}}', null, 'false'),
('[1].containsAny([])', '{"containsAny": {"left": {"Value": [1]}, "right": {"Value": []}}}', null, 'false'),
('[1, 2].containsAny([3, 2])', '{"containsAny": {"left": {"Value": [1, 2]}, "right": {"Value": [3, 2]}}}', null, 'true'),
('1.contains(1)', '{"contains": {"left": {"Value": 1}, "right": {"Value": 1}}}', null, 'error: type_error%'),
('[1].containsAll(1)', '{"containsAll": {"left": {"Value": [1]}, "right": {"Value": 1}}}', null, 'error: type_error%'),
('[].isEmpty()', '{"isEmpty": {"arg": {"Value": []}}}', null, 'true'),
('"".isEmpty()', '{"isEmpty": {"arg": {"Value": ""}}}', null, 'error: type_error%'),
('[principal.nope]: an error in a set literal', '{"Set": [{".": {"left": {"Var": "principal"}, "attr": "nope"}}]}', null, 'error: attribute_not_found%'),
-- in and is
('principal in principal: in is reflexive', '{"in": {"left": {"Var": "principal"}, "right": {"Var": "principal"}}}', null, 'true'),
('resource in Folder::"root": transitive', '{"in": {"left": {"Var": "resource"}, "right": {"Value": {"__entity": {"type": "Folder", "id": "root"}}}}}', null, 'true'),
('resource.owner in Group::"eng": an attribute''s entity', '{"in": {"left": {".": {"left": {"Var": "resource"}, "attr": "owner"}}, "right": {"Value": {"__entity": {"type": "Group", "id": "eng"}}}}}', null, 'true'),
('resource in [Folder::"x", Folder::"root"]', '{"in": {"left": {"Var": "resource"}, "right": {"Set": [{"Value": {"__entity": {"type": "Folder", "id": "x"}}}, {"Value": {"__entity": {"type": "Folder", "id": "root"}}}]}}}', null, 'true'),
('resource in [Doc::"d1", 1]: every element must be an entity', '{"in": {"left": {"Var": "resource"}, "right": {"Set": [{"Var": "resource"}, {"Value": 1}]}}}', null, 'error: type_error%'),
('resource in []', '{"in": {"left": {"Var": "resource"}, "right": {"Value": []}}}', null, 'false'),
('1 in Folder::"root"', '{"in": {"left": {"Value": 1}, "right": {"Value": {"__entity": {"type": "Folder", "id": "root"}}}}}', null, 'error: type_error%'),
('resource in "root"', '{"in": {"left": {"Var": "resource"}, "right": {"Value": "root"}}}', null, 'error: type_error%'),
('User::"nobody" in User::"nobody": an entity that does not exist', '{"in": {"left": {"Value": {"__entity": {"type": "User", "id": "nobody"}}}, "right": {"Value": {"__entity": {"type": "User", "id": "nobody"}}}}}', null, 'true'),
('User::"nobody" in Group::"eng": no ancestors', '{"in": {"left": {"Value": {"__entity": {"type": "User", "id": "nobody"}}}, "right": {"Value": {"__entity": {"type": "Group", "id": "eng"}}}}}', null, 'false'),
('Folder::"root" in resource: in is not symmetric', '{"in": {"left": {"Value": {"__entity": {"type": "Folder", "id": "root"}}}, "right": {"Var": "resource"}}}', null, 'false'),
('resource is Doc', '{"is": {"left": {"Var": "resource"}, "entity_type": "Doc"}}', null, 'true'),
('resource is Folder', '{"is": {"left": {"Var": "resource"}, "entity_type": "Folder"}}', null, 'false'),
('1 is Doc', '{"is": {"left": {"Value": 1}, "entity_type": "Doc"}}', null, 'error: type_error%'),
('resource is Doc in Folder::"root"', '{"is": {"left": {"Var": "resource"}, "entity_type": "Doc", "in": {"Value": {"__entity": {"type": "Folder", "id": "root"}}}}}', null, 'true'),
('resource is Folder in <error>: the in part is not evaluated', '{"is": {"left": {"Var": "resource"}, "entity_type": "Folder", "in": {".": {"left": {"Var": "principal"}, "attr": "nope"}}}}', null, 'false'),
('resource is Doc in <error>', '{"is": {"left": {"Var": "resource"}, "entity_type": "Doc", "in": {".": {"left": {"Var": "principal"}, "attr": "nope"}}}}', null, 'error: attribute_not_found%'),
-- the condition itself
('a condition that is a Long', '{"Value": 1}', null, 'error: type_error: a condition must be Bool%'),
('context.mfa', '{".": {"left": {"Var": "context"}, "attr": "mfa"}}', '{"mfa": true}', 'true'),
('context.owner == principal: an entity in the context', '{"==": {"left": {".": {"left": {"Var": "context"}, "attr": "owner"}}, "right": {"Var": "principal"}}}', '{"owner": {"__entity": {"type": "User", "id": "alice"}}}', 'true'),
('context.nope', '{".": {"left": {"Var": "context"}, "attr": "nope"}}', '{}', 'error: attribute_not_found%');

select tap.plan((select count(*)::int from cases) + 4);

select tap.ok(r.got like c.want, format('%s: %s', c.what, r.got))
from cases c cross join lateral (select cedar_t.eval(c.body, c.ctx) as got) r
order by c.n;

-- the messages name the values
select tap.is(cedar_t.eval('{"+": {"left": {"Value": 9223372036854775807}, "right": {"Value": 1}}}'),
              'error: overflow: 9223372036854775807 + 1', 'an overflow names its operands');
select tap.is(cedar_t.eval('{".": {"left": {"Var": "principal"}, "attr": "nope"}}'),
              'error: attribute_not_found: User::"alice" has no attribute "nope"', 'a missing attribute names the entity and the attribute');
select tap.is(cedar_t.eval('{"<": {"left": {"Value": 1}, "right": {"Value": "2"}}}'),
              'error: type_error: <: expected two Longs, two datetimes or two durations, got Long and String', 'a type error names the types');
select tap.is(cedar_t.eval('{".": {"left": {"Value": {"__entity": {"type": "User", "id": "a\"b"}}}, "attr": "x"}}'),
              'error: entity_does_not_exist: User::"a\"b" (reading .x)', 'a uid in a message uses Cedar''s escapes');

select * from tap.finish();
