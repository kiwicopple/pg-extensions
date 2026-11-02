-- Goal: the `entities` argument of cedar_is_authorized overlays the stored
-- entities for that request only (research/plan-cedar.md, "API"): an overlay
-- entity replaces the stored entity with the same uid as a whole (attrs,
-- tags and parents); entities the overlay does not name come from storage,
-- and `in` walks across both; nothing is written; and the overlay is checked
-- like cedar_put_entities' input.
\ir ../../fixtures/d/cedar.sql

select tap.plan(14);

select permissions.cedar_put_entities(entities => $j$[
  {"uid": {"type": "User", "id": "alice"}, "attrs": {"level": 1}, "parents": [{"type": "Group", "id": "staff"}], "tags": {"t": "stored"}},
  {"uid": {"type": "Group", "id": "staff"}, "parents": [{"type": "Group", "id": "all"}]},
  {"uid": {"type": "Group", "id": "admins"}, "parents": [{"type": "Group", "id": "root"}]},
  {"uid": {"type": "Doc", "id": "d1"}, "attrs": {"public": false}}
]$j$);
select permissions.cedar_put_policy(policy_id => 'level', policy_json => cedar_t.policy('permit',
    '{">=": {"left": {".": {"left": {"Var": "principal"}, "attr": "level"}}, "right": {"Value": 2}}}'));
select permissions.cedar_put_policy(policy_id => 'root', policy_json => cedar_t.policy('permit', null,
    '{"op": "in", "entity": {"type": "Group", "id": "root"}}'));

select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"'), 'deny [] errors []', 'stored: level 1, not under root');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"', null,
                            '[{"uid": {"type": "User", "id": "alice"}, "attrs": {"level": 5}}]'),
              'allow [level] errors []', 'the overlay''s attrs replace the stored ones');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"'), 'deny [] errors []', 'for that request only');
select tap.is(permissions.cedar_read_entities(type => 'User') #> '{0,attrs}', '{"level": 1}', 'nothing was stored');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"', null,
                            '[{"uid": {"type": "User", "id": "alice"}, "attrs": {}}]'),
              'deny [] errors [level]', 'an overlay entity replaces the whole entity: no level attribute now');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"', null,
                            '[{"uid": {"type": "User", "id": "alice"}, "attrs": {"level": 1}, "parents": [{"type": "Group", "id": "admins"}]}]'),
              'allow [root] errors []', 'overlay parents replace the stored ones, and the walk continues in storage (admins -> root)');
select tap.is(cedar_t.authz('User::"bob"', 'Action::"view"', 'Doc::"d1"', null, $j$[
                  {"uid": {"type": "User", "id": "bob"}, "attrs": {"level": 0}, "parents": [{"type": "Team", "id": "t"}]},
                  {"uid": {"type": "Team", "id": "t"}, "parents": [{"type": "Group", "id": "staff"}]},
                  {"uid": {"type": "Group", "id": "staff"}, "parents": [{"type": "Group", "id": "admins"}]}]$j$),
              'allow [root] errors []', 'an entity only in the overlay, through an overlay group that replaces a stored one');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"', null,
                            '[{"uid": {"type": "Group", "id": "staff"}, "parents": [{"type": "Group", "id": "root"}]}]'),
              'allow [root] errors []', 'a stored principal under an overlay group: the walk enters the overlay');
select permissions.cedar_delete_policy(policy_id => 'level');
select permissions.cedar_delete_policy(policy_id => 'root');

-- attributes and tags of other entities come from the overlay too
select tap.is(cedar_t.eval('{"==": {"left": {".": {"left": {"Var": "resource"}, "attr": "public"}}, "right": {"Value": true}}}',
                           p_entities => '[{"uid": {"type": "Doc", "id": "d1"}, "attrs": {"public": true}}]'),
              'true', 'the resource''s attrs from the overlay');
select tap.is(cedar_t.eval('{"==": {"left": {"getTag": {"left": {"Var": "principal"}, "right": {"Value": "t"}}}, "right": {"Value": "overlay"}}}',
                           p_entities => '[{"uid": {"type": "User", "id": "alice"}, "tags": {"t": "overlay"}}]'),
              'true', 'tags from the overlay');
select tap.is(cedar_t.eval('{"hasTag": {"left": {"Var": "principal"}, "right": {"Value": "t"}}}',
                           p_entities => '[{"uid": {"type": "User", "id": "alice"}}]'),
              'false', 'an overlay entity without tags has none');
select tap.is(cedar_t.eval('{".": {"left": {"Value": {"__entity": {"type": "Doc", "id": "d2"}}}, "attr": "public"}}',
                           p_entities => '[{"uid": {"type": "Doc", "id": "d2"}, "attrs": {"public": true}}]'),
              'true', 'an entity that is neither principal nor resource');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"', null, '[]'), 'deny [] errors []', 'an empty overlay changes nothing');
select tap.ok(cedar_t.err($$ select permissions.cedar_is_authorized(principal => 'User::"a"', action => 'Action::"view"', resource => 'Doc::"d"',
                                                                    entities => '[{"uid": {"type": "U", "id": "a"}, "attrs": {"x": 1.5}}]') $$)
              like '22023 cedar:invalid_entity index=0', 'the overlay is checked like a put');

select * from tap.finish();
