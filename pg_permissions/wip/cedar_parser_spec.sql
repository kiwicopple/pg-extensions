-- Goal: the Cedar text parser (wip/cedar_parser.sql, phase 3 of
-- research/plan-cedar.md) rejects invalid text with a precise, helpful error,
-- keeps its static limits, and reproduces the cedar-policy-cli 4.14.0 EST
-- quirks that the corpus does not exercise. The corpus oracle itself is
-- wip/check_parser.sh, which also runs this file.
--
-- Every parse error is SQLSTATE 42601 with DETAIL
-- 'cedar:parse_error line=<n> column=<n>' (research/designs/e-cedar.md
-- section 5), the position of the offending token, and a non-empty HINT.
-- pg_temp.parse_error returns '<sqlstate> <detail>', with ' (no hint)'
-- appended when the HINT is empty, so each assertion checks all three. The
-- positions and messages were checked by hand; every input is also rejected
-- by the CLI. Limits are SQLSTATE 54000 'cedar:limit_exceeded', and U+0000 is
-- 0A000 'cedar:unsupported'.
--
-- Run (until the parser moves into the install file): a database with
-- test/lib/tap.sql, pg_permissions--0.1.0.sql and wip/cedar_parser.sql, then
--   psql -X -q -tA -f wip/cedar_parser_spec.sql

select tap.plan(80);

create function pg_temp.parse_error(src text, single boolean default false)
returns text
language plpgsql
as $$
declare
    st text;
    det text;
    hnt text;
begin
    if single then
        perform permissions._cedar_parse_policy(src);
    else
        perform permissions._cedar_parse_policies(src);
    end if;
    return 'no error';
exception when others then
    get stacked diagnostics st = returned_sqlstate, det = pg_exception_detail, hnt = pg_exception_hint;
    return st || ' ' || det || case when coalesce(hnt, '') = '' then ' (no hint)' else '' end;
end;
$$;

create function pg_temp.parse_hint(src text)
returns text
language plpgsql
as $$
declare
    hnt text;
begin
    perform permissions._cedar_parse_policies(src);
    return null;
exception when others then
    get stacked diagnostics hnt = pg_exception_hint;
    return hnt;
end;
$$;

-- ---------------------------------------------------------------------------
-- Invalid text: SQLSTATE, line and column, and a HINT
-- ---------------------------------------------------------------------------
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) whn { true };$c$),
              '42601 cedar:parse_error line=1 column=38',
              'misspelt when');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource)
unles { false };$c$),
              '42601 cedar:parse_error line=2 column=1',
              'misspelt unless');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { true }$c$),
              '42601 cedar:parse_error line=1 column=51',
              'missing semicolon at the end');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource)
permit (principal, action, resource);$c$),
              '42601 cedar:parse_error line=2 column=1',
              'missing semicolon between policies');
select tap.is(pg_temp.parse_error($c$permti (principal, action, resource);$c$),
              '42601 cedar:parse_error line=1 column=1',
              'misspelt effect');
select tap.is(pg_temp.parse_error($c$allow (principal, action, resource);$c$),
              '42601 cedar:parse_error line=1 column=1',
              'effect not permit or forbid');
select tap.is(pg_temp.parse_error($c$permit (action, principal, resource);$c$),
              '42601 cedar:parse_error line=1 column=9',
              'scope variables out of order');
select tap.is(pg_temp.parse_error($c$permit (principal, acton, resource);$c$),
              '42601 cedar:parse_error line=1 column=20',
              'misspelt scope variable');
select tap.is(pg_temp.parse_error($c$permit (principal, action);$c$),
              '42601 cedar:parse_error line=1 column=26',
              'missing resource');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource, context);$c$),
              '42601 cedar:parse_error line=1 column=38',
              'extra scope element');
select tap.is(pg_temp.parse_error($c$permit (principal: User, action, resource);$c$),
              '42601 cedar:parse_error line=1 column=18',
              'type constraint with a colon');
select tap.is(pg_temp.parse_error($c$permit (principal == "alice", action, resource);$c$),
              '42601 cedar:parse_error line=1 column=22',
              'string where an entity is expected');
select tap.is(pg_temp.parse_error($c$permit (principal == User, action, resource);$c$),
              '42601 cedar:parse_error line=1 column=26',
              'entity type without an id');
select tap.is(pg_temp.parse_error($c$permit (principal in [Group::"a"], action, resource);$c$),
              '42601 cedar:parse_error line=1 column=22',
              'set in the principal scope');
select tap.is(pg_temp.parse_error($c$permit (principal == ?resource, action, resource);$c$),
              '42601 cedar:parse_error line=1 column=22',
              'wrong slot');
select tap.is(pg_temp.parse_error($c$permit (principal, action == ?action, resource);$c$),
              '42601 cedar:parse_error line=1 column=30',
              'slot in the action scope');
select tap.is(pg_temp.parse_error($c$permit (principal, action == Photo::"view", resource);$c$),
              '42601 cedar:parse_error line=1 column=30',
              'action of a non-Action type');
select tap.is(pg_temp.parse_error($c$permit (principal, action is Action, resource);$c$),
              '42601 cedar:parse_error line=1 column=27',
              'is in the action scope');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource)
when { principal == ?principal };$c$),
              '42601 cedar:parse_error line=2 column=21',
              'slot in a condition');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { };$c$),
              '42601 cedar:parse_error line=1 column=38',
              'empty condition');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { (1 + 2 };$c$),
              '42601 cedar:parse_error line=1 column=52',
              'unclosed parenthesis');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { [1 2].contains(1) };$c$),
              '42601 cedar:parse_error line=1 column=48',
              'missing comma in a set');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { {a 1} == {} };$c$),
              '42601 cedar:parse_error line=1 column=48',
              'missing colon in a record');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { {a: 1, "a": 2} == {} };$c$),
              '42601 cedar:parse_error line=1 column=52',
              'duplicate record key');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { 1 < 2 < 3 };$c$),
              '42601 cedar:parse_error line=1 column=51',
              'chained relational operators');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context has a == true };$c$),
              '42601 cedar:parse_error line=1 column=59',
              'has then ==');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { !!!!!context.ok };$c$),
              '42601 cedar:parse_error line=1 column=45',
              'too many unary operators');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { !-context.n };$c$),
              '42601 cedar:parse_error line=1 column=46',
              'mixed unary operators');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context.n < 9223372036854775808 };$c$),
              '42601 cedar:parse_error line=1 column=57',
              'integer literal too large');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { ipaddr("10.0.0.1") };$c$),
              '42601 cedar:parse_error line=1 column=45',
              'unknown function');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { lessThan(1, 2) };$c$),
              '42601 cedar:parse_error line=1 column=45',
              'method called as a function');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { "10.0.0.1".ip() };$c$),
              '42601 cedar:parse_error line=1 column=56',
              'function called as a method');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context.tags.contain("a") };$c$),
              '42601 cedar:parse_error line=1 column=58',
              'unknown method');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context.tags.contains("a", "b") };$c$),
              '42601 cedar:parse_error line=1 column=58',
              'wrong argument count');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { princpal.age > 3 };$c$),
              '42601 cedar:parse_error line=1 column=45',
              'unknown variable');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context.if };$c$),
              '42601 cedar:parse_error line=1 column=53',
              'reserved word as an attribute');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context[0] };$c$),
              '42601 cedar:parse_error line=1 column=53',
              'non-string index');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context.name like 1 };$c$),
              '42601 cedar:parse_error line=1 column=63',
              'like with a non-string pattern');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { principal is "User" };$c$),
              '42601 cedar:parse_error line=1 column=58',
              'is with a quoted type');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context has a + 1 };$c$),
              '42601 cedar:parse_error line=1 column=59',
              'invalid has right side');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { if context.a then 1 };$c$),
              '42601 cedar:parse_error line=1 column=65',
              'if without else');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { true && if context.a then true else false };$c$),
              '42601 cedar:parse_error line=1 column=53',
              'if as an operand');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context.s == "a\qb" };$c$),
              '42601 cedar:parse_error line=1 column=58',
              'invalid escape');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context.s == "\*" };$c$),
              '42601 cedar:parse_error line=1 column=58',
              'star escape outside like');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context.s == "\u{D800}" };$c$),
              '42601 cedar:parse_error line=1 column=58',
              'surrogate escape');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when {
  context.s == "abc\
};$c$),
              '42601 cedar:parse_error line=2 column=16',
              'unterminated string');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context.a = 1 };$c$),
              '42601 cedar:parse_error line=1 column=55',
              'single equals');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context.a == 'x' };$c$),
              '42601 cedar:parse_error line=1 column=58',
              'single quotes');
select tap.is(pg_temp.parse_error($c$@id("a")
@id("b")
permit (principal, action, resource);$c$),
              '42601 cedar:parse_error line=2 column=1',
              'duplicate annotation');
select tap.is(pg_temp.parse_error($c$@doc(x) permit (principal, action, resource);$c$),
              '42601 cedar:parse_error line=1 column=6',
              'annotation without a string');
select tap.is(pg_temp.parse_error($c$@id("p") permit (principal, action, resource);
@id("p") forbid (principal, action, resource);$c$),
              '42601 cedar:parse_error line=2 column=1',
              'duplicate policy id');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { principal is __cedar::User };$c$),
              '42601 cedar:parse_error line=1 column=58',
              'reserved name in an entity type');

-- exactly one policy for _cedar_parse_policy
select tap.is(pg_temp.parse_error($c$// only a comment$c$, true),
              '42601 cedar:parse_error line=1 column=18',
              'one policy: no policy');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource);
forbid (principal, action, resource);$c$, true),
              '42601 cedar:parse_error line=2 column=1',
              'one policy: a second policy');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource); )$c$, true),
              '42601 cedar:parse_error line=1 column=39',
              'one policy: text after the policy');

-- ---------------------------------------------------------------------------
-- HINT content
-- ---------------------------------------------------------------------------
select tap.ok(strpos(pg_temp.parse_hint($c$permit (principal, action, resource) whn { true };$c$), 'Did you mean ''when''?') > 0,
              'misspelt when: the hint says Did you mean ''when''?');
select tap.ok(strpos(pg_temp.parse_hint($c$permit (principal, action, resource)
unles { false };$c$), 'Did you mean ''unless''?') > 0,
              'misspelt unless: the hint says Did you mean ''unless''?');
select tap.ok(strpos(pg_temp.parse_hint($c$permit (principal, action, resource) when { true }$c$), 'End each policy with '';''.') > 0,
              'missing semicolon at the end: the hint says End each policy with '';''.');
select tap.ok(strpos(pg_temp.parse_hint($c$permit (principal, action, resource)
permit (principal, action, resource);$c$), 'end the previous policy with '';''') > 0,
              'missing semicolon between policies: the hint says end the previous policy with '';''');
select tap.ok(strpos(pg_temp.parse_hint($c$permti (principal, action, resource);$c$), 'Did you mean ''permit''?') > 0,
              'misspelt effect: the hint says Did you mean ''permit''?');
select tap.ok(strpos(pg_temp.parse_hint($c$permit (principal, acton, resource);$c$), 'Did you mean ''action''?') > 0,
              'misspelt scope variable: the hint says Did you mean ''action''?');
select tap.ok(strpos(pg_temp.parse_hint($c$permit (principal, action, resource) when { context.tags.contain("a") };$c$), 'Did you mean ''contains''?') > 0,
              'unknown method: the hint says Did you mean ''contains''?');
select tap.ok(strpos(pg_temp.parse_hint($c$permit (principal, action, resource) when { princpal.age > 3 };$c$), 'Did you mean ''principal''?') > 0,
              'unknown variable: the hint says Did you mean ''principal''?');
select tap.ok(strpos(pg_temp.parse_hint($c$permit (principal, action, resource) when { principal is "User" };$c$), 'Remove the quotes: is User.') > 0,
              'is with a quoted type: the hint says Remove the quotes: is User.');
select tap.ok(strpos(pg_temp.parse_hint($c$permit (principal, action, resource) when { context.a = 1 };$c$), 'use ''==''') > 0,
              'single equals: the hint says use ''==''');

-- ---------------------------------------------------------------------------
-- Limits and U+0000
-- ---------------------------------------------------------------------------
select tap.is(pg_temp.parse_error('permit (principal, action, resource) when { "' || repeat('a', 70000) || '" };', true),
              '54000 cedar:limit_exceeded limit=''policy_text''',
              'limit: a policy text over 64 KiB');
select tap.is(pg_temp.parse_error('permit (principal, action, resource);' || E'\n'
                                  || 'permit (principal, action, resource) when { "' || repeat('a', 70000) || '" };'),
              '54000 cedar:limit_exceeded limit=''policy_text''',
              'limit: one policy of a set over 64 KiB');
select tap.is(pg_temp.parse_error('permit (principal, action, resource) when { ' || repeat('(', 65) || '1' || repeat(')', 65) || ' };'),
              '54000 cedar:limit_exceeded limit=''expression_depth''',
              'limit: brackets nested more than 64 deep');
select tap.is(pg_temp.parse_error('permit (principal, action, resource) when { 1' || repeat(' + 1', 64) || ' == 1 };'),
              '54000 cedar:limit_exceeded limit=''expression_depth''',
              'limit: an EST deeper than 64');
select tap.is(pg_temp.parse_error('permit (principal, action, resource) when { [' || repeat('1, ', 4096) || '1].isEmpty() };'),
              '54000 cedar:limit_exceeded limit=''policy_nodes''',
              'limit: more than 4,096 expression nodes');
select tap.is(pg_temp.parse_error($c$permit (principal, action, resource) when { context.s == "a\0" };$c$),
              '0A000 cedar:unsupported feature=''U+0000''',
              'U+0000 in a string literal is unsupported');
select tap.is(pg_temp.parse_error('permit (principal, action, resource) when { 1' || repeat(' + 1', 62) || ' == 1 };'),
              'no error',
              'limit: an EST 64 deep parses');

-- ---------------------------------------------------------------------------
-- CLI EST quirks (expected values are cedar-policy-cli 4.14.0 output)
-- ---------------------------------------------------------------------------
select tap.is(permissions._cedar_parse_policy($c$permit (principal, action, resource) when { context has a.b.c };$c$) -> 'conditions',
              '[{"kind":"when","body":{"has":{"left":{"Var":"context"},"attr":["a","b","c"]}}}]'::jsonb,
              'has with an attribute path: attr is an array');
select tap.is(permissions._cedar_parse_policy($c$permit (principal, action in [Action::"view"], resource);$c$) -> 'action',
              '{"op":"in","entity":{"type":"Action","id":"view"}}'::jsonb,
              'action in a one-entity list is the entity form');
select tap.is(permissions._cedar_parse_policy($c$permit (principal, action, resource) when { -9223372036854775808 < --5 };$c$) -> 'conditions',
              '[{"kind":"when","body":{"<":{"left":{"Value":-9223372036854775808},"right":{"neg":{"arg":{"Value":-5}}}}}}]'::jsonb,
              'a negative literal folds into Value, one minus only');
select tap.is(permissions._cedar_parse_policy($c$permit (principal, action, resource) when { context.s like "a\*\u{2a}" };$c$) -> 'conditions',
              '[{"kind":"when","body":{"like":{"left":{".":{"left":{"Var":"context"},"attr":"s"}},"pattern":[{"Literal":"a"},{"Literal":"*"},"Wildcard"]}}}]'::jsonb,
              'like: \* is a literal star, \u{2a} a wildcard');
select tap.is(permissions._cedar_parse_policies($c$@id("first") @doc permit (principal, action, resource);
forbid (principal in ?principal, action, resource is Doc in ?resource);$c$),
              '{"templates":{"policy1":{"effect":"forbid","principal":{"op":"in","slot":"?principal"},"action":{"op":"All"},"resource":{"op":"is","entity_type":"Doc","in":{"slot":"?resource"}},"conditions":[]}},"staticPolicies":{"first":{"effect":"permit","principal":{"op":"All"},"action":{"op":"All"},"resource":{"op":"All"},"conditions":[],"annotations":{"doc":null,"id":"first"}}},"templateLinks":[]}'::jsonb,
              'policy set: @id names a policy, others are policy<position>, templates apart, bare annotation null');
select tap.is(permissions._cedar_parse_policy($c$permit (principal, action in [Action::"a", Action::"b",], resource,) when { [1,] == [1] && {a: 1,} has a };$c$),
              '{"effect":"permit","principal":{"op":"All"},"action":{"op":"in","entities":[{"type":"Action","id":"a"},{"type":"Action","id":"b"}]},"resource":{"op":"All"},"conditions":[{"kind":"when","body":{"&&":{"left":{"==":{"left":{"Set":[{"Value":1}]},"right":{"Set":[{"Value":1}]}}},"right":{"has":{"left":{"Record":{"a":{"Value":1}}},"attr":"a"}}}}}]}'::jsonb,
              'trailing commas in lists, records and the scope');
select tap.is(permissions._cedar_parse_policy($c$permit (principal, action, resource) when { ip("10.0.0.1").isInRange(ip("10.0.0.0/8")) && context.d.lessThan(decimal("1.5")) && datetime("2024-01-01").offset(duration("1h")) < context.t };$c$) -> 'conditions',
              '[{"kind":"when","body":{"&&":{"left":{"&&":{"left":{"isInRange":[{"ip":[{"Value":"10.0.0.1"}]},{"ip":[{"Value":"10.0.0.0/8"}]}]},"right":{"lessThan":[{".":{"left":{"Var":"context"},"attr":"d"}},{"decimal":[{"Value":"1.5"}]}]}}},"right":{"<":{"left":{"offset":[{"datetime":[{"Value":"2024-01-01"}]},{"duration":[{"Value":"1h"}]}]},"right":{".":{"left":{"Var":"context"},"attr":"t"}}}}}}}]'::jsonb,
              'extension functions and methods are nodes named after them');
select tap.is(permissions._cedar_parse_policies(''),
              '{"staticPolicies":{},"templates":{},"templateLinks":[]}'::jsonb,
              'an empty policy set');

select * from tap.finish();
