-- Goal: Cedar policy templates and links (phase 4c of research/plan-cedar.md,
-- research/designs/e-cedar.md section 13). A template is put as Cedar text or
-- JSON with the slot ?principal, ?resource or both in its scope; a link fills
-- every slot and is a policy under its own policy_id, listed by
-- cedar_policies() with its template and slot values, and authorizing like a
-- static policy (the reason is the link's id). Replacing a template re-fills
-- its links; a template with links cannot be deleted or lose a slot its links
-- fill. Static policies, links and templates share one set of ids. Bad
-- slots, slot values and ids raise cedar:<code> errors with a hint, and
-- clients cannot call any of it. The corpus oracle for links is generated:
-- 76_cedar_oracle_templates (test/cedar/generate.py --phase 4c).
\ir ../../fixtures/d/cedar.sql

select tap.plan(49);

select permissions.cedar_put_entities(entities => '[
  {"uid": {"type": "User", "id": "alice"}, "parents": [{"type": "Team", "id": "eng"}]},
  {"uid": {"type": "User", "id": "bob"}},
  {"uid": {"type": "Doc", "id": "d1"}, "parents": [{"type": "Folder", "id": "docs"}]},
  {"uid": {"type": "Doc", "id": "d2"}},
  {"uid": {"type": "Note", "id": "n1"}, "parents": [{"type": "Folder", "id": "docs"}]}]');

-- ---------------------------------------------------------------------------
-- Templates: put and list
-- ---------------------------------------------------------------------------
select permissions.cedar_put_template(template_id => 'folder-view', template => $c$@doc("view a folder")
permit (principal in ?principal, action == Action::"view", resource is Doc in ?resource)
when { context.ok };$c$);
select tap.is((select t.template_id || ' ' || t.annotations::text from permissions.cedar_templates() t), 'folder-view {"doc": "view a folder"}',
              'cedar_templates() lists the template with its annotations');
select tap.is((select t.est -> 'principal' from permissions.cedar_templates() t), '{"op": "in", "slot": "?principal"}',
              'the EST keeps the slot in the principal scope');
select tap.is((select t.est -> 'resource' from permissions.cedar_templates() t), '{"op": "is", "entity_type": "Doc", "in": {"slot": "?resource"}}',
              'and under is ... in in the resource scope');
select tap.ok((select t.source like '@doc("view a folder")%' from permissions.cedar_templates() t), 'the text is kept as source');
select permissions.cedar_put_template(template_id => 'owner-edit', template_json => cedar_t.policy('permit', null,
    '{"op": "==", "slot": "?principal"}', '{"op": "==", "entity": {"type": "Action", "id": "edit"}}'));
select tap.is((select array_agg(t.template_id || ':' || (t.source is not null)::text) from permissions.cedar_templates() t),
              '{folder-view:true,owner-edit:false}', 'a template put as JSON has no source; the list is ordered by id');
select tap.is((select count(*)::int from permissions.cedar_policies()), 0, 'a template alone is not a policy');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"edit"', 'Doc::"d1"'), 'deny [] errors []', 'and does not authorize');

-- ---------------------------------------------------------------------------
-- Links
-- ---------------------------------------------------------------------------
select permissions.cedar_link_template(policy_id => 'eng-docs', template_id => 'folder-view',
                                       principal => 'Team::"eng"', resource => 'Folder::"docs"');
select permissions.cedar_link_template(policy_id => 'alice-edit', template_id => 'owner-edit', principal => 'User::"alice"');
select tap.is((select jsonb_agg(jsonb_build_object('id', p.policy_id, 'template', p.template_id, 'slots', p.slots) order by p.policy_id)
               from permissions.cedar_policies() p),
              '[{"id": "alice-edit", "template": "owner-edit", "slots": {"?principal": {"type": "User", "id": "alice"}}},
                {"id": "eng-docs", "template": "folder-view", "slots": {"?principal": {"type": "Team", "id": "eng"}, "?resource": {"type": "Folder", "id": "docs"}}}]',
              'cedar_policies() lists each link with its template and slot values');
select tap.is((select p.est from permissions.cedar_policies() p where p.policy_id = 'eng-docs') - 'conditions' - 'annotations',
              '{"effect": "permit", "principal": {"op": "in", "entity": {"type": "Team", "id": "eng"}},
                "action": {"op": "==", "entity": {"type": "Action", "id": "view"}},
                "resource": {"op": "is", "entity_type": "Doc", "in": {"entity": {"type": "Folder", "id": "docs"}}}}',
              'a link''s EST is the template''s with the slots filled in');
select tap.is((select coalesce(p.source, 'null') || ' ' || p.annotations::text from permissions.cedar_policies() p where p.policy_id = 'eng-docs'),
              'null {"doc": "view a folder"}', 'a link has no source and the template''s annotations');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"', '{"ok": true}'), 'allow [eng-docs] errors []',
              'a link authorizes through the hierarchy, and the reason is the link''s id');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"', '{"ok": false}'), 'deny [] errors []',
              'the template''s condition applies to the link');
select tap.is(cedar_t.authz('User::"bob"', 'Action::"view"', 'Doc::"d1"', '{"ok": true}'), 'deny [] errors []',
              'the filled principal scope applies');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Note::"n1"', '{"ok": true}'), 'deny [] errors []',
              'the is of is ... in ?resource applies');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d2"', '{"ok": true}'), 'deny [] errors []',
              'the filled resource scope applies');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"view"', 'Doc::"d1"'), 'deny [] errors [eng-docs]',
              'an evaluation error is reported under the link''s id');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"edit"', 'Doc::"d2"'), 'allow [alice-edit] errors []',
              'a template with one slot links with one value');
select permissions.cedar_link_template(policy_id => 'alice-edit', template_id => 'owner-edit', principal => 'User::"bob"');
select tap.is(cedar_t.authz('User::"alice"', 'Action::"edit"', 'Doc::"d2"') || ', ' || cedar_t.authz('User::"bob"', 'Action::"edit"', 'Doc::"d2"'),
              'deny [] errors [], allow [alice-edit] errors []', 'linking an existing link id again replaces the link');

-- replacing a template re-fills its links
select permissions.cedar_put_template(template_id => 'owner-edit', template => 'forbid (principal == ?principal, action == Action::"edit", resource);');
select permissions.cedar_put_policy(policy_id => 'all', policy => 'permit (principal, action, resource);');
select tap.is(cedar_t.authz('User::"bob"', 'Action::"edit"', 'Doc::"d2"'), 'deny [alice-edit] errors []',
              'a replaced template changes its links: the link now forbids');
select tap.is((select p.est ->> 'effect' from permissions.cedar_policies() p where p.policy_id = 'alice-edit'), 'forbid',
              'and the link''s EST follows the template');
select tap.is(cedar_t.err($$ select permissions.cedar_put_template(template_id => 'owner-edit', template => 'forbid (principal, action, resource == ?resource);') $$),
              '2BP01 cedar:template_in_use template_id=''owner-edit''', 'a replacement must keep the slots its links fill');
select tap.ok((cedar_t.msg($$ select permissions.cedar_put_template(template_id => 'owner-edit', template => 'forbid (principal, action, resource == ?resource);') $$)).message
              like '%alice-edit (?principal)%', 'the message names the links and their slots');
select permissions.cedar_delete_policy(policy_id => 'all');

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------
select tap.is(cedar_t.err($$ select permissions.cedar_link_template(policy_id => 'x', template_id => 'folder-view', principal => 'User::"bob"') $$),
              '22023 cedar:invalid_link slot=''?resource''', 'a slot without a value');
select tap.ok((cedar_t.msg($$ select permissions.cedar_link_template(policy_id => 'x', template_id => 'folder-view', principal => 'User::"bob"') $$)).hint
              like 'Template ''folder-view'' has the slots ?principal and ?resource: %resource => %', 'the hint lists the slots and shows the call');
select tap.is(cedar_t.err($$ select permissions.cedar_link_template(policy_id => 'x', template_id => 'owner-edit', principal => 'User::"bob"', resource => 'Doc::"d1"') $$),
              '22023 cedar:invalid_link slot=''?resource''', 'a value without a slot');
select tap.is(cedar_t.err($$ select permissions.cedar_link_template(policy_id => 'x', template_id => 'owner-edit') $$),
              '22023 cedar:invalid_link slot=''?principal''', 'no values at all');
select tap.is(cedar_t.err($$ select permissions.cedar_link_template(policy_id => 'x', template_id => 'owner-edit', principal => 'bob') $$),
              '22023 cedar:invalid_uid value=''bob''', 'a slot value that is not a uid');
select tap.is(cedar_t.err($$ select permissions.cedar_link_template(policy_id => 'x', template_id => 'owner-edt', principal => 'User::"bob"') $$),
              '22023 cedar:unknown_template template_id=''owner-edt''', 'an unknown template');
select tap.is((cedar_t.msg($$ select permissions.cedar_link_template(policy_id => 'x', template_id => 'owner-edt', principal => 'User::"bob"') $$)).hint,
              'Did you mean ''owner-edit''? Template ids: folder-view, owner-edit.', 'the hint suggests the nearest template id');
select tap.is(cedar_t.err($$ select permissions.cedar_link_template(policy_id => null, template_id => 'owner-edit', principal => 'User::"bob"') $$),
              '22004 cedar:null_argument argument=''policy_id''', 'a link needs a policy_id');
select tap.is(cedar_t.err($$ select permissions.cedar_put_template(template_id => 't') $$),
              '22004 cedar:null_argument argument=''template''', 'a template needs its text or JSON');
select tap.is(cedar_t.err($$ select permissions.cedar_put_template(template_id => 't', template => 'permit (principal, action, resource);') $$),
              '22023 cedar:invalid_policy path=''$''', 'a template without a slot');
select tap.is(cedar_t.err($$ select permissions.cedar_put_template(template_id => 't', template_json => cedar_t.policy('permit', null, '{"op": "==", "slot": "?resource"}')) $$),
              '22023 cedar:invalid_policy path=''$.principal''', 'the ?resource slot in the principal scope');
select tap.is(cedar_t.err($$ select permissions.cedar_put_template(template_id => 't', template_json => cedar_t.policy('permit', null, '{"op": "All"}', '{"op": "==", "slot": "?action"}')) $$),
              '22023 cedar:invalid_policy path=''$.action''', 'a slot in the action scope');
select tap.is(cedar_t.err($$ select permissions.cedar_put_template(template_id => 't', template_json => cedar_t.policy('permit', '{"==": {"left": {"Var": "principal"}, "right": {"Slot": "?principal"}}}', '{"op": "==", "slot": "?principal"}')) $$),
              '22023 cedar:invalid_policy path=''$.conditions[0].body."==".Slot''', 'a slot in a condition (Cedar allows slots in the scope only)');

-- one set of ids
select permissions.cedar_put_policy(policy_id => 'static', policy => 'permit (principal, action, resource);');
select tap.is(cedar_t.err($$ select permissions.cedar_link_template(policy_id => 'static', template_id => 'owner-edit', principal => 'User::"bob"') $$),
              '23505 cedar:id_in_use id=''static''', 'a link cannot take a static policy''s id');
select tap.is(cedar_t.err($$ select permissions.cedar_put_policy(policy_id => 'alice-edit', policy => 'permit (principal, action, resource);') $$),
              '23505 cedar:id_in_use id=''alice-edit''', 'a static policy cannot take a link''s id');
select tap.is(cedar_t.err($$ select permissions.cedar_put_policy(policy_id => 'owner-edit', policy => 'permit (principal, action, resource);') $$),
              '23505 cedar:id_in_use id=''owner-edit''', 'a static policy cannot take a template''s id');
select tap.is(cedar_t.err($$ select permissions.cedar_put_template(template_id => 'static', template => 'permit (principal == ?principal, action, resource);') $$),
              '23505 cedar:id_in_use id=''static''', 'a template cannot take a policy''s id');
select tap.is(cedar_t.err($$ select permissions.cedar_link_template(policy_id => 'folder-view', template_id => 'owner-edit', principal => 'User::"bob"') $$),
              '23505 cedar:id_in_use id=''folder-view''', 'a link cannot take a template''s id');
select permissions.cedar_delete_policy(policy_id => 'static');

-- ---------------------------------------------------------------------------
-- Deleting
-- ---------------------------------------------------------------------------
select tap.is(cedar_t.err($$ select permissions.cedar_delete_template(template_id => 'folder-view') $$),
              '2BP01 cedar:template_in_use template_id=''folder-view''', 'a template with links cannot be deleted');
select tap.ok((cedar_t.msg($$ select permissions.cedar_delete_template(template_id => 'folder-view') $$)).hint like '%cedar_delete_policy%: eng-docs.',
              'the hint names the links to delete first');
select tap.is((cedar_t.msg($$ select permissions.cedar_delete_policy(policy_id => 'folder-view') $$)).hint,
              '''folder-view'' is a template: delete it with select permissions.cedar_delete_template(template_id => ''folder-view'').',
              'cedar_delete_policy on a template id points to cedar_delete_template');
select permissions.cedar_delete_policy(policy_id => 'eng-docs');
select permissions.cedar_delete_policy(policy_id => 'alice-edit');
select tap.lives_ok($$ select permissions.cedar_delete_template(template_id => 'folder-view') $$, 'cedar_delete_policy deletes links, then the template goes');
select tap.is(cedar_t.err($$ select permissions.cedar_delete_template(template_id => 'folder-view') $$),
              '22023 cedar:unknown_template template_id=''folder-view''', 'deleting an unknown template');

-- clients cannot call any of it
set role authenticated;
select tap.throws_ok($$ select permissions.cedar_put_template(template_id => 'c', template => 'permit (principal == ?principal, action, resource);') $$,
                     '42501', 'clients cannot put templates');
select tap.throws_ok($$ select permissions.cedar_link_template(policy_id => 'c', template_id => 'owner-edit', principal => 'User::"bob"') $$,
                     '42501', 'clients cannot link templates');
select tap.throws_ok($$ select permissions.cedar_delete_template(template_id => 'owner-edit') $$, '42501', 'clients cannot delete templates');
select tap.throws_ok($$ select * from permissions.cedar_templates() $$, '42501', 'clients cannot list templates');
reset role;

select * from tap.finish();
