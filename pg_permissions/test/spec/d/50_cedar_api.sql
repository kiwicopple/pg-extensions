-- Goal: the Cedar admin API and the authorizer behave as research/plan-cedar.md
-- ("API") and research/designs/e-cedar.md (sections 2, 4.4) describe:
-- policies put as Cedar's JSON format are stored as given, replaced by id and
-- deleted; annotations are metadata only; entities are upserted as a whole
-- and read back as Cedar entity JSON; cedar_is_authorized returns
-- {decision, reasons, errors} with Cedar's rules (forbid wins, default deny,
-- an erring policy is skipped and reported); scope ==, in, is and is ... in on
-- principal and resource, and action ==, in an entity and in a set (action
-- groups through parents); when and unless; and clients cannot call any of it.
\ir ../../fixtures/d/cedar.sql

select tap.plan(56);

-- policies: put, replace, list, delete
select permissions.cedar_put_policy(policy_id => 'p1', policy_json => cedar_t.policy('permit'));
select tap.is((select jsonb_agg(to_jsonb(p) order by p.policy_id) from permissions.cedar_policies() p),
              jsonb_build_array(jsonb_build_object('policy_id', 'p1', 'effect', 'permit', 'source', null,
                                                   'est', cedar_t.policy('permit'), 'annotations', '{}'::jsonb,
                                                   'template_id', null, 'slots', null)),
              'cedar_policies() returns the policy as put: id, effect, no Cedar text, the EST, no annotations, no template');
select permissions.cedar_put_policy(policy_id => 'p1', policy_json => cedar_t.policy('forbid') || '{"annotations": {"id": "x", "advice": null}}');
select tap.is((select p.effect || ' ' || p.annotations::text from permissions.cedar_policies() p), 'forbid {"id": "x", "advice": ""}',
              'a put with the same id replaces the policy; a null annotation is ""');
select tap.is((select p.est from permissions.cedar_policies() p),
              cedar_t.policy('forbid') || '{"annotations": {"id": "x", "advice": null}}', 'the EST is kept exactly as put');
select tap.is(cedar_t.authz('User::"a"', 'Action::"view"', 'Doc::"d"'), 'deny [p1] errors []',
              'the @id annotation does not rename the policy: the reason is its policy_id');
select permissions.cedar_put_policy(policy_id => 'p0', policy_json => cedar_t.policy('permit'));
select tap.is((select array_agg(p.policy_id) from permissions.cedar_policies() p), '{p0,p1}', 'cedar_policies() is ordered by id');
select permissions.cedar_delete_policy(policy_id => 'p1');
select permissions.cedar_delete_policy(policy_id => 'p0');
select tap.is((select count(*)::int from permissions.cedar_policies()), 0, 'cedar_delete_policy removes a policy');
select tap.is(cedar_t.authz('User::"a"', 'Action::"view"', 'Doc::"d"'), 'deny [] errors []', 'no policy: deny, no reasons');

-- entities: put, read, replace, delete
select permissions.cedar_put_entities(entities => $j$[
  {"uid": {"type": "User", "id": "alice"}, "attrs": {"dept": "Eng", "s": [3, 1, 1], "boss": {"__entity": {"type": "User", "id": "bob"}}},
   "parents": [{"type": "Group", "id": "staff"}, {"__entity": {"type": "Group", "id": "eng"}}], "tags": {"t": "v"}},
  {"uid": {"__entity": {"type": "App::User", "id": "x\"y"}}},
  {"uid": {"type": "Group", "id": "eng"}, "attrs": null, "parents": null, "tags": null}
]$j$);
select tap.is(permissions.cedar_read_entities(type => 'User'), $j$[
  {"uid": {"type": "User", "id": "alice"}, "attrs": {"dept": "Eng", "s": [1, 3], "boss": {"__entity": {"type": "User", "id": "bob"}}},
   "parents": [{"type": "Group", "id": "eng"}, {"type": "Group", "id": "staff"}], "tags": {"t": "v"}}]$j$::jsonb,
  'cedar_read_entities(type): Cedar entity JSON, sets canonical (sorted, no duplicates), parents sorted');
select tap.is((select jsonb_agg(e -> 'uid') from jsonb_array_elements(permissions.cedar_read_entities()) e),
              '[{"type": "App::User", "id": "x\"y"}, {"type": "Group", "id": "eng"}, {"type": "User", "id": "alice"}]',
              'cedar_read_entities(): every entity, by type and id; missing attrs, parents and tags are empty');
select tap.is(jsonb_array_length(permissions.cedar_read_entities(type => 'User', ids => '{alice,nobody}')), 1,
              'cedar_read_entities(type, ids): the ids that exist');
select tap.is(permissions.cedar_read_entities(type => 'Nothing'), '[]', 'a type with no entities reads as []');
select permissions.cedar_put_entities(entities => '[{"uid": {"type": "User", "id": "alice"}, "attrs": {"dept": "Ops"}, "parents": [{"type": "Group", "id": "ops"}]}]');
select tap.is(permissions.cedar_read_entities(type => 'User') -> 0, '{"uid": {"type": "User", "id": "alice"}, "attrs": {"dept": "Ops"}, "parents": [{"type": "Group", "id": "ops"}], "tags": {}}',
              'a put replaces attrs, parents and tags as a whole');
select tap.is(permissions.cedar_delete_entities(uids => '[{"type": "User", "id": "alice"}, "App::User::\"x\\\"y\"", {"type": "User", "id": "nobody"}]'), 2::bigint,
              'cedar_delete_entities takes uid objects and Cedar text uids, and counts what it deleted');
select tap.is((select jsonb_agg(e -> 'uid') from jsonb_array_elements(permissions.cedar_read_entities()) e),
              '[{"type": "Group", "id": "eng"}]', 'the deleted entities are gone');
select tap.is(permissions.cedar_delete_entities(uids => '[]'), 0::bigint, 'deleting nothing deletes nothing');

-- the authorizer: the result's shape and Cedar's decision rules
select permissions.cedar_put_entities(entities => $j$[
  {"uid": {"type": "User", "id": "alice"}, "attrs": {"level": 3}, "parents": [{"type": "Group", "id": "eng"}]},
  {"uid": {"type": "User", "id": "bob"}, "attrs": {"level": 1}, "parents": []},
  {"uid": {"type": "Doc", "id": "d1"}, "attrs": {"public": false}, "parents": [{"type": "Folder", "id": "f1"}]},
  {"uid": {"type": "Doc", "id": "d2"}, "attrs": {"public": true}, "parents": []},
  {"uid": {"type": "Action", "id": "view"}, "parents": [{"type": "Action", "id": "read"}]},
  {"uid": {"type": "Action", "id": "edit"}, "parents": [{"type": "Action", "id": "write"}]},
  {"uid": {"type": "Action", "id": "read"}, "parents": [{"type": "Action", "id": "any"}]}
]$j$);
select permissions.cedar_put_policy(policy_id => 'b-public', policy_json => cedar_t.policy('permit',
    '{".": {"left": {"Var": "resource"}, "attr": "public"}}'));
select permissions.cedar_put_policy(policy_id => 'a-eng', policy_json => cedar_t.policy('permit', null,
    '{"op": "in", "entity": {"type": "Group", "id": "eng"}}'));
select tap.is(permissions.cedar_is_authorized(principal => 'User::"alice"', action => 'Action::"view"', resource => 'Doc::"d2"'),
              '{"decision": "allow", "reasons": ["a-eng", "b-public"], "errors": []}',
              'every satisfied permit is a reason, sorted by id');
select tap.is(cedar_t.authz('User::"bob"', 'Action::"view"', 'Doc::"d1"'), 'deny [] errors []', 'no satisfied policy: deny');
select permissions.cedar_put_policy(policy_id => 'c-forbid-low', policy_json => cedar_t.policy('forbid',
    '{"<": {"left": {".": {"left": {"Var": "principal"}, "attr": "level"}}, "right": {"Value": 2}}}'));
select tap.is(cedar_t.authz('User::"bob"', 'Action::"view"', 'Doc::"d2"'), 'deny [c-forbid-low] errors []',
              'a satisfied forbid overrides a permit, and only the forbids are reasons');
select tap.is(cedar_t.authz('User::"carol"', 'Action::"view"', 'Doc::"d2"'), 'allow [b-public] errors [c-forbid-low]',
              'a forbid that errs (User::"carol" does not exist) is skipped and reported: the permit still allows');
select tap.is((permissions.cedar_is_authorized(principal => 'User::"carol"', action => 'Action::"view"', resource => 'Doc::"d2"') -> 'errors'),
              '[{"policy_id": "c-forbid-low", "message": "entity_does_not_exist: User::\"carol\" (reading .level)"}]',
              'errors are {policy_id, message}');
select tap.is(cedar_t.authz('User::"carol"', 'Action::"view"', 'Doc::"d9"'), 'deny [] errors [b-public, c-forbid-low]',
              'errors are sorted by policy id');
select permissions.cedar_delete_policy(policy_id => 'a-eng');
select permissions.cedar_delete_policy(policy_id => 'b-public');
select permissions.cedar_delete_policy(policy_id => 'c-forbid-low');

-- when and unless: the conditions in order, unless as not
select permissions.cedar_put_policy(policy_id => 'wu', policy_json => '{
  "effect": "permit", "principal": {"op": "All"}, "action": {"op": "All"}, "resource": {"op": "All"},
  "conditions": [{"kind": "when", "body": {">=": {"left": {".": {"left": {"Var": "principal"}, "attr": "level"}}, "right": {"Value": 2}}}},
                 {"kind": "unless", "body": {".": {"left": {"Var": "resource"}, "attr": "public"}}}]}');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"'), 'allow [wu] errors []', 'when holds and unless does not');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d2"'), 'deny [] errors []', 'unless holds');
select tap.is(cedar_t.authz('User::"bob"', 'Action::"view"', 'Doc::"d1"'), 'deny [] errors []', 'when does not hold');
select tap.is(cedar_t.authz('User::"bob"', 'Action::"view"', 'Doc::"nope"'), 'deny [] errors []',
              'a failed when stops the chain: the unless that would err is not evaluated');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"nope"'), 'deny [] errors [wu]', 'an erring unless is an error');
select permissions.cedar_delete_policy(policy_id => 'wu');

-- the scope
create temp table scopes (n serial, what text, principal jsonb, action jsonb, resource jsonb, req text[], want text);
insert into scopes (what, principal, action, resource, req, want) values
('principal == User::"alice"', '{"op": "==", "entity": {"type": "User", "id": "alice"}}', null, null, array['User::"alice"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('principal == User::"alice", for bob', '{"op": "==", "entity": {"type": "User", "id": "alice"}}', null, null, array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'deny'),
('principal in Group::"eng"', '{"op": "in", "entity": {"type": "Group", "id": "eng"}}', null, null, array['User::"alice"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('principal in User::"alice": in is reflexive', '{"op": "in", "entity": {"type": "User", "id": "alice"}}', null, null, array['User::"alice"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('principal is User', '{"op": "is", "entity_type": "User"}', null, null, array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('principal is Admin', '{"op": "is", "entity_type": "Admin"}', null, null, array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'deny'),
('principal is User in Group::"eng"', '{"op": "is", "entity_type": "User", "in": {"entity": {"type": "Group", "id": "eng"}}}', null, null, array['User::"alice"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('principal is User in Group::"eng", for bob', '{"op": "is", "entity_type": "User", "in": {"entity": {"type": "Group", "id": "eng"}}}', null, null, array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'deny'),
('principal is Group in Group::"eng": the type must match too', '{"op": "is", "entity_type": "Group", "in": {"entity": {"type": "Group", "id": "eng"}}}', null, null, array['Group::"eng"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('principal is Group in Group::"eng", for a user', '{"op": "is", "entity_type": "Group", "in": {"entity": {"type": "Group", "id": "eng"}}}', null, null, array['User::"alice"', 'Action::"view"', 'Doc::"d1"'], 'deny'),
('resource in Folder::"f1"', null, null, '{"op": "in", "entity": {"type": "Folder", "id": "f1"}}', array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('resource in Folder::"f1", for d2', null, null, '{"op": "in", "entity": {"type": "Folder", "id": "f1"}}', array['User::"bob"', 'Action::"view"', 'Doc::"d2"'], 'deny'),
('resource == Doc::"d2"', null, null, '{"op": "==", "entity": {"type": "Doc", "id": "d2"}}', array['User::"bob"', 'Action::"view"', 'Doc::"d2"'], 'allow'),
('resource is Doc in Folder::"f1"', null, null, '{"op": "is", "entity_type": "Doc", "in": {"entity": {"type": "Folder", "id": "f1"}}}', array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('action == Action::"view"', null, '{"op": "==", "entity": {"type": "Action", "id": "view"}}', null, array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('action == Action::"read" does not match its member view', null, '{"op": "==", "entity": {"type": "Action", "id": "read"}}', null, array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'deny'),
('action in Action::"read": an action group', null, '{"op": "in", "entity": {"type": "Action", "id": "read"}}', null, array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('action in Action::"any": a group of a group', null, '{"op": "in", "entity": {"type": "Action", "id": "any"}}', null, array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('action in [Action::"write", Action::"any"]', null, '{"op": "in", "entities": [{"type": "Action", "id": "write"}, {"type": "Action", "id": "any"}]}', null, array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'allow'),
('action in [Action::"write"], for view', null, '{"op": "in", "entities": [{"type": "Action", "id": "write"}]}', null, array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'deny'),
('action in [Action::"edit"]: a listed action itself', null, '{"op": "in", "entities": [{"type": "Action", "id": "edit"}]}', null, array['User::"bob"', 'Action::"edit"', 'Doc::"d1"'], 'allow'),
('action in [], matches nothing', null, '{"op": "in", "entities": []}', null, array['User::"bob"', 'Action::"view"', 'Doc::"d1"'], 'deny'),
('a namespaced action type', null, '{"op": "==", "entity": {"type": "App::Action", "id": "view"}}', null, array['User::"bob"', 'App::Action::"view"', 'Doc::"d1"'], 'allow');
-- (a function, so that each request sees the policy put just before it)
create function pg_temp.scope_case(p_principal jsonb, p_action jsonb, p_resource jsonb, p_req text[])
returns text
language plpgsql
as $$
begin
    perform permissions.cedar_put_policy(policy_id => 'scope',
        policy_json => cedar_t.policy('permit', null, coalesce(p_principal, '{"op": "All"}'),
                                      coalesce(p_action, '{"op": "All"}'), coalesce(p_resource, '{"op": "All"}')));
    return permissions.cedar_is_authorized(principal => p_req[1], action => p_req[2], resource => p_req[3]) ->> 'decision';
end;
$$;
select tap.is(pg_temp.scope_case(s.principal, s.action, s.resource, s.req), s.want, s.what)
from scopes s
order by s.n;
select permissions.cedar_delete_policy(policy_id => 'scope');

-- uids in Cedar text, with Cedar's string escapes
select permissions.cedar_put_policy(policy_id => 'odd', policy_json => cedar_t.policy('permit', null,
    '{"op": "==", "entity": {"type": "A::B", "id": "q\"b\\s\nné"}}'));
select tap.is(cedar_t.authz('A::B::"q\"b\\s\nn\u{e9}"', 'Action::"view"', 'Doc::"d1"'), 'allow [odd] errors []',
              'a uid''s id takes Cedar''s escapes: \" \\ \n \u{..}');
select tap.is(cedar_t.authz('A::B::"q\"b\\s\x0an\u{e9}"', 'Action::"view"', 'Doc::"d1"'), 'allow [odd] errors []', 'and \xHH');
select permissions.cedar_delete_policy(policy_id => 'odd');

-- clients
set role authenticated;
select tap.throws_ok($$ select permissions.cedar_is_authorized(principal => 'User::"a"', action => 'Action::"view"', resource => 'Doc::"d1"') $$,
                     '42501', 'clients cannot call cedar_is_authorized');
select tap.throws_ok($$ select permissions.cedar_put_policy(policy_id => 'x', policy_json => '{}') $$, '42501', 'clients cannot put policies');
select tap.throws_ok($$ select permissions.cedar_put_entities(entities => '[]') $$, '42501', 'clients cannot put entities');
select tap.throws_ok($$ select permissions.cedar_read_entities() $$, '42501', 'clients cannot read entities');
reset role;
select tap.is((select array_agg(p.proname::text order by p.proname) from pg_proc p where p.pronamespace = 'permissions'::regnamespace
                 and p.proname ~ '^_?cedar_' and has_function_privilege('authenticated', p.oid, 'execute')),
              '{cedar_is_authorized_current,cedar_list_resources_current,cedar_uid}',
              'clients can execute only the two current-subject cedar_* helpers and cedar_uid (granted to PUBLIC)');

select * from tap.finish();
