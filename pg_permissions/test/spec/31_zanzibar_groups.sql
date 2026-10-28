-- Goal: groups, nesting, cycles, revocation, expiry and cleanup (PLAN.md §2 Model 2, §3)
-- PROVISIONAL: uses Design A's zanzibar-level API. See 30_zanzibar_reference.sql.
\ir ../fixtures/ids.sql

select permissions.define_type('user');
select permissions.define_type('team');
select permissions.define_type('document');
select permissions.define_relation('team', 'member');
select permissions.define_relation('document', 'editor');
select permissions.define_relation('document', 'viewer', '{editor}');

-- dave in eng, eng nested in platform, platform can view the plan
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'platform', 'member');

select tap.plan(11);

select tap.is(permissions.check_for('user', :'dave', 'team', :'platform', 'member'), true, 'members of a nested team are members of the parent');
select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_plan', 'viewer'), true, 'access granted to the parent team reaches nested members');

-- cycles terminate
select permissions.grant('team', :'eng', 'member', 'team', :'platform', 'member');
select tap.lives_ok(format($$ select permissions.check_for('user', %L, 'document', %L, 'viewer') $$, :'dave', :'acme_plan'), 'a membership cycle does not hang or error');
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_plan', 'viewer'), false, 'a cycle does not grant access to outsiders');

-- validation
select tap.throws_ok(format($$ select permissions.grant('document', %L, 'owner', 'user', %L) $$, :'acme_plan', :'erin'), null, 'granting an undefined relation fails');
select tap.throws_ok(format($$ select permissions.grant('document', %L, 'viewer', 'team', %L, 'lead') $$, :'acme_plan', :'eng'), null, 'granting to an undefined userset fails');

-- revocation
select permissions.revoke('team', :'eng', 'member', 'user', :'dave');
select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_plan', 'viewer'), false, 'revoking team membership removes inherited access');

-- expiry
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'erin', '', now() - interval '1 minute');
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_readme', 'editor'), false, 'an expired grant gives no access');
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'erin', '', now() + interval '1 hour');
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_readme', 'editor'), true, 'an unexpired grant does');

-- cleanup (PLAN.md §3: apps remove a deleted user's permissions)
select permissions.grant('document', :'acme_plan', 'editor', 'user', :'erin');
select permissions.delete_subject('user', :'erin');
select tap.set_eq(permissions.list_objects_for('user', :'erin', 'document', 'viewer'), '{}', 'delete_subject removes all of a user''s access');
select permissions.delete_object('document', :'acme_plan');
select tap.is(
    (select count(*)::int from permissions.list_subjects('document', :'acme_plan', 'viewer')), 0,
    'delete_object removes all access to an object');

select * from tap.finish();
