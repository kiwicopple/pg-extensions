-- Goal: `in` follows the entity hierarchy when only direct parents are stored
-- (research/designs/e-cedar.md sections 1.3 and 4.5; the corpus lists every
-- ancestor, so it cannot catch a broken walk). in is reflexive and
-- transitive, through any depth (the corpus reaches 117) and through
-- several parents; a parent need not be a stored entity; deleting or
-- re-parenting an entity changes the answers at once (there is no closure to
-- go stale); action groups work the same way; and a put that would make a
-- cycle is refused.
\ir ../../fixtures/d/cedar.sql

select tap.plan(25);

-- a chain of 120 groups, each with only its direct parent: User::"u" -> Group::"g1" -> ... -> Group::"g120"
select permissions.cedar_put_entities(entities => (
    select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Group', 'id', 'g' || g),
                                        'parents', case when g < 120 then jsonb_build_array(jsonb_build_object('type', 'Group', 'id', 'g' || (g + 1)))
                                                        else '[]'::jsonb end))
    from generate_series(1, 120) g));
select permissions.cedar_put_entities(entities => '[{"uid": {"type": "User", "id": "u"}, "parents": [{"type": "Group", "id": "g1"}]}]');

select tap.is(cedar_t.eval('{"in": {"left": {"Var": "principal"}, "right": {"Value": {"__entity": {"type": "Group", "id": "g1"}}}}}', p_principal => 'User::"u"'),
              'true', 'principal in its direct parent');
select tap.is(cedar_t.eval('{"in": {"left": {"Var": "principal"}, "right": {"Value": {"__entity": {"type": "Group", "id": "g117"}}}}}', p_principal => 'User::"u"'),
              'true', 'principal in an ancestor 117 levels up');
select tap.is(cedar_t.eval('{"in": {"left": {"Var": "principal"}, "right": {"Value": {"__entity": {"type": "Group", "id": "g120"}}}}}', p_principal => 'User::"u"'),
              'true', 'principal in the root, 120 levels up');
select tap.is(cedar_t.eval('{"in": {"left": {"Value": {"__entity": {"type": "Group", "id": "g60"}}}, "right": {"Value": {"__entity": {"type": "Group", "id": "g120"}}}}}'),
              'true', 'an entity that is not in the request: g60 in g120');
select tap.is(cedar_t.eval('{"in": {"left": {"Value": {"__entity": {"type": "Group", "id": "g120"}}}, "right": {"Value": {"__entity": {"type": "Group", "id": "g60"}}}}}'),
              'false', 'not downwards: g120 in g60');
select tap.is(cedar_t.eval('{"in": {"left": {"Var": "principal"}, "right": {"Set": [{"Value": {"__entity": {"type": "Group", "id": "x"}}}, {"Value": {"__entity": {"type": "Group", "id": "g99"}}}]}}}', p_principal => 'User::"u"'),
              'true', 'in a set: any element, at any depth');

-- the scope walks the same way
select permissions.cedar_put_policy(policy_id => 'root', policy_json => cedar_t.policy('permit', null, '{"op": "in", "entity": {"type": "Group", "id": "g120"}}'));
select tap.is(cedar_t.authz('User::"u"', 'Action::"view"', 'Doc::"d"'), 'allow [root] errors []', 'scope principal in the root, 120 levels up');
select tap.is(cedar_t.authz('Group::"g120"', 'Action::"view"', 'Doc::"d"'), 'allow [root] errors []', 'scope principal in itself');
select tap.is(cedar_t.authz('User::"v"', 'Action::"view"', 'Doc::"d"'), 'deny [] errors []', 'an entity that is not stored has no ancestors');

-- deleting a link in the middle cuts every chain through it
select permissions.cedar_delete_entities(uids => '[{"type": "Group", "id": "g60"}]');
select tap.is(cedar_t.authz('User::"u"', 'Action::"view"', 'Doc::"d"'), 'deny [] errors []', 'g60 deleted: u is no longer in the root');
select tap.is(cedar_t.eval('{"in": {"left": {"Var": "principal"}, "right": {"Value": {"__entity": {"type": "Group", "id": "g60"}}}}}', p_principal => 'User::"u"'),
              'true', 'but still in g60: g59 names it as a parent, and a parent need not exist');
select tap.is(cedar_t.eval('{"in": {"left": {"Var": "principal"}, "right": {"Value": {"__entity": {"type": "Group", "id": "g61"}}}}}', p_principal => 'User::"u"'),
              'false', 'and not in g61, which only the deleted g60 named');
select permissions.cedar_put_entities(entities => '[{"uid": {"type": "Group", "id": "g60"}, "parents": [{"type": "Group", "id": "g61"}]}]');
select tap.is(cedar_t.authz('User::"u"', 'Action::"view"', 'Doc::"d"'), 'allow [root] errors []', 'g60 put back: the chain is whole again');

-- several parents, and re-parenting
select permissions.cedar_put_entities(entities => $j$[
  {"uid": {"type": "User", "id": "w"}, "parents": [{"type": "Team", "id": "a"}, {"type": "Team", "id": "b"}]},
  {"uid": {"type": "Team", "id": "a"}, "parents": [{"type": "Org", "id": "x"}]},
  {"uid": {"type": "Team", "id": "b"}, "parents": [{"type": "Org", "id": "y"}]},
  {"uid": {"type": "Org", "id": "y"}, "parents": [{"type": "Group", "id": "g120"}]}
]$j$);
select tap.is(cedar_t.eval('{"in": {"left": {"Var": "principal"}, "right": {"Value": {"__entity": {"type": "Org", "id": "x"}}}}}', p_principal => 'User::"w"'),
              'true', 'two parents: through the first');
select tap.is(cedar_t.authz('User::"w"', 'Action::"view"', 'Doc::"d"'), 'allow [root] errors []', 'two parents: through the second, to the root');
select permissions.cedar_put_entities(entities => '[{"uid": {"type": "Team", "id": "b"}, "parents": [{"type": "Org", "id": "x"}]}]');
select tap.is(cedar_t.authz('User::"w"', 'Action::"view"', 'Doc::"d"'), 'deny [] errors []', 'Team::"b" moved under Org::"x": w is no longer in the root');
select tap.is(cedar_t.eval('{"in": {"left": {"Var": "principal"}, "right": {"Value": {"__entity": {"type": "Org", "id": "y"}}}}}', p_principal => 'User::"w"'),
              'false', 'nor in Org::"y"');
select permissions.cedar_delete_policy(policy_id => 'root');

-- resource hierarchies and attributes that are entities
select permissions.cedar_put_entities(entities => $j$[
  {"uid": {"type": "Doc", "id": "d"}, "attrs": {"owner": {"__entity": {"type": "User", "id": "u"}}}, "parents": [{"type": "Folder", "id": "f3"}]},
  {"uid": {"type": "Folder", "id": "f3"}, "parents": [{"type": "Folder", "id": "f2"}]},
  {"uid": {"type": "Folder", "id": "f2"}, "parents": [{"type": "Folder", "id": "f1"}]}
]$j$);
select tap.is(cedar_t.eval('{"in": {"left": {"Var": "resource"}, "right": {"Value": {"__entity": {"type": "Folder", "id": "f1"}}}}}', p_resource => 'Doc::"d"'),
              'true', 'resource in its grandparent folder, which is not a stored entity');
select tap.is(cedar_t.eval('{"in": {"left": {".": {"left": {"Var": "resource"}, "attr": "owner"}}, "right": {"Value": {"__entity": {"type": "Group", "id": "g100"}}}}}', p_resource => 'Doc::"d"'),
              'true', 'resource.owner in a group 100 levels above the owner');
select tap.is(cedar_t.eval('{"is": {"left": {"Var": "resource"}, "entity_type": "Doc", "in": {"Value": {"__entity": {"type": "Folder", "id": "f1"}}}}}', p_resource => 'Doc::"d"'),
              'true', 'resource is Doc in Folder::"f1"');

-- action groups: an action's parents
select permissions.cedar_put_entities(entities => $j$[
  {"uid": {"type": "Action", "id": "view"}, "parents": [{"type": "Action", "id": "readOnly"}]},
  {"uid": {"type": "Action", "id": "readOnly"}, "parents": [{"type": "Action", "id": "all"}]}
]$j$);
select permissions.cedar_put_policy(policy_id => 'all', policy_json => cedar_t.policy('permit', null, '{"op": "All"}', '{"op": "in", "entity": {"type": "Action", "id": "all"}}'));
select tap.is(cedar_t.authz('User::"u"', 'Action::"view"', 'Doc::"d"'), 'allow [all] errors []', 'action in a group of a group');
select tap.is(cedar_t.eval('{"in": {"left": {"Var": "action"}, "right": {"Value": {"__entity": {"type": "Action", "id": "readOnly"}}}}}'),
              'true', 'action in its group, in a condition');
select permissions.cedar_delete_policy(policy_id => 'all');

-- cycles
select tap.ok(cedar_t.err($$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "Group", "id": "g120"}, "parents": [{"type": "User", "id": "u"}]}]') $$)
              like '22023 cedar:invalid_entity uid=%', 'a link from the root down to the bottom of the chain would close a cycle of 121: refused');
select tap.is(cedar_t.authz('Group::"g120"', 'Action::"view"', 'Doc::"d"'), 'deny [] errors []', 'and nothing of it was stored');
select tap.ok(cedar_t.err($$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "Org", "id": "y"}, "parents": [{"type": "Team", "id": "b"}]}]') $$)
              = '', 'a link that closes no cycle is accepted (Team::"b" is no longer under Org::"y")');

select * from tap.finish();
