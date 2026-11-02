-- Goal: delete_subject forgets a subject in the Cedar model too
-- (research/plan-cedar.md, phase 6). For delete_subject(subject_type,
-- subject_id) it deletes the entity <subject_type>::"<subject_id>", its
-- parent edges, the edges that name it as a parent, and the template links
-- whose ?principal or ?resource slot names it; static policies, templates
-- and references in other entities' attrs stay. The result counts every
-- deleted row, rbac_* and fga_* ones included. Ids need no escaping, and a
-- current-subject check in the same transaction sees the deletion.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/d/rbac_roles.sql

select permissions.rbac_assign_role(user_id => :'alice', role => 'viewer');

select permissions.cedar_put_entities(entities => jsonb_build_array(
    jsonb_build_object('uid', jsonb_build_object('type', 'Org', 'id', 'acme')),
    jsonb_build_object('uid', jsonb_build_object('type', 'Team', 'id', 'eng'), 'parents', '[{"type": "Org", "id": "acme"}]'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', :'alice'), 'parents', '[{"type": "Team", "id": "eng"}]'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', :'bob'), 'parents', '[{"type": "Team", "id": "eng"}]'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', 'q"x\'), 'parents', '[{"type": "Team", "id": "eng"}]'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'd1'),
                       'attrs', jsonb_build_object('owner', jsonb_build_object('__entity', jsonb_build_object('type', 'user', 'id', :'alice')))),
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'd2'))));

select permissions.cedar_put_template(template_id => 'owner',
    template => 'permit (principal == ?principal, action == Action::"view", resource == ?resource);');
select permissions.cedar_put_template(template_id => 'team',
    template => 'permit (principal in ?principal, action == Action::"read", resource == ?resource);');
select permissions.cedar_link_template(policy_id => 'alice-d1', template_id => 'owner', principal => format('user::"%s"', :'alice'), resource => 'Doc::"d1"');
select permissions.cedar_link_template(policy_id => 'bob-d1', template_id => 'owner', principal => format('user::"%s"', :'bob'), resource => 'Doc::"d1"');
select permissions.cedar_link_template(policy_id => 'bob-d2', template_id => 'owner', principal => format('user::"%s"', :'bob'), resource => 'Doc::"d2"');
select permissions.cedar_link_template(policy_id => 'quoted-d1', template_id => 'owner', principal => 'user::"q\"x\\"', resource => 'Doc::"d1"');
select permissions.cedar_link_template(policy_id => 'eng-d1', template_id => 'team', principal => 'Team::"eng"', resource => 'Doc::"d1"');
select permissions.cedar_put_policy(policy_id => 'alice-edit',
    policy => format('permit (principal == user::"%s", action == Action::"edit", resource);', :'alice'));

create function pg_temp.allowed(p_principal text, p_action text, p_resource text) returns boolean
language sql as $$
    select permissions.cedar_is_authorized(principal => p_principal, action => p_action, resource => p_resource) ->> 'decision' = 'allow'
$$;

select tap.plan(17);

-- the current subject sees the link, then loses it in the same transaction
begin;
select set_config('permissions.subject_id', :'alice', true);
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"d1"'), true,
              'before: alice may view d1 through her link');
-- alice: 1 role assignment; her link, her parent edge and her entity
select tap.is(permissions.delete_subject(subject_type => 'user', subject_id => :'alice'), 4::bigint,
              'delete_subject(user, alice) counts her assignment, her link, her parent edge and her entity');
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"d1"'), false,
              'after, in the same transaction: the cached statement filter is not reused');
commit;

select tap.is(permissions.cedar_read_entities(type => 'user', ids => array[:'alice']), '[]'::jsonb, 'her entity is gone');
select tap.is((select array_agg(p.policy_id order by p.policy_id) from permissions.cedar_policies() p),
              '{alice-edit,bob-d1,bob-d2,eng-d1,quoted-d1}', 'only her link is gone: static policies and other links stay');
select tap.is((select array_agg(t.template_id order by t.template_id) from permissions.cedar_templates() t), '{owner,team}',
              'templates stay');
select tap.is(permissions.cedar_read_entities(type => 'Doc', ids => '{d1}') #>> '{0,attrs,owner,__entity,id}', :'alice'::text,
              'a reference to her in another entity''s attrs stays');
select tap.is(pg_temp.allowed(format('user::"%s"', :'alice'), 'Action::"edit"', 'Doc::"d2"'), true,
              'a static policy that names her still applies to a reused id');
select tap.is(permissions.rbac_user_permissions(user_id => :'alice'), '{}'::text[], 'her role assignment is gone');

-- a group: the edges that name it as a parent go, so nothing stays in it
select tap.is(pg_temp.allowed(format('user::"%s"', :'bob'), 'Action::"read"', 'Doc::"d1"'), true,
              'before: bob may read d1 as a member of Team::"eng"');
-- the team link, bob's and q"x\'s edges to it, its own edge to Org::"acme", and the entity
select tap.is(permissions.delete_subject(subject_type => 'Team', subject_id => 'eng'), 5::bigint,
              'delete_subject(Team, eng) counts its link, two member edges, its own parent edge and its entity');
select tap.is(pg_temp.allowed(format('user::"%s"', :'bob'), 'Action::"read"', 'Doc::"d1"'), false,
              'after: bob is no longer in Team::"eng"');
select tap.is(permissions.cedar_read_entities(type => 'user', ids => array[:'bob']) #> '{0,parents}', '[]'::jsonb,
              'bob stays, without the parent edge');

-- a resource slot names the subject too
select tap.is(permissions.delete_subject(subject_type => 'Doc', subject_id => 'd2'), 2::bigint,
              'delete_subject(Doc, d2) deletes the link whose ?resource names it, and the entity');

-- ids with " and \ need no escaping
select tap.is(permissions.delete_subject(subject_type => 'user', subject_id => 'q"x\'), 2::bigint,
              'an id with " and \: its link and its entity');
select tap.is((select array_agg(p.policy_id order by p.policy_id) from permissions.cedar_policies() p),
              '{alice-edit,bob-d1}', 'the links left');

select tap.is(permissions.delete_subject(subject_type => 'user', subject_id => :'alice'), 0::bigint,
              'a second call deletes nothing');

select * from tap.finish();
