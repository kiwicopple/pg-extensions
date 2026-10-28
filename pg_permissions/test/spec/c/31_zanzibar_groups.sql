-- Goal: groups, nesting, cycles, revocation, expiry and cleanup (PLAN.md §2 Model 2, §3)
-- Design C's native API. Same scenario and assertions as a/31_zanzibar_groups.sql.
\ir ../../fixtures/ids.sql

select count(*) from permissions.apply_model($json$
{
  "types": {
    "team":     { "relations": { "member": ["user", "team#member"] } },
    "document": {
      "relations": { "editor": ["user", "team#member"], "viewer": ["user", "team#member"] },
      "implies":   { "editor": ["viewer"] }
    }
  }
}
$json$);

-- dave in eng, eng nested in platform, platform can view the plan
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'platform', 'member');

select tap.plan(11);

select tap.is(permissions.can_for('user', :'dave', 'team', :'platform', 'member'), true, 'members of a nested team are members of the parent');
select tap.is(permissions.can_for('user', :'dave', 'document', :'acme_plan', 'viewer'), true, 'access granted to the parent team reaches nested members');

-- cycles terminate (C: the membership walk stops on revisits when the cycle is written)
select permissions.grant('team', :'eng', 'member', 'team', :'platform', 'member');
select tap.lives_ok(format($$ select permissions.can_for('user', %L, 'document', %L, 'viewer') $$, :'dave', :'acme_plan'), 'a membership cycle does not hang or error');
select tap.is(permissions.can_for('user', :'erin', 'document', :'acme_plan', 'viewer'), false, 'a cycle does not grant access to outsiders');

-- validation
select tap.throws_ok(format($$ select permissions.grant('document', %L, 'owner', 'user', %L) $$, :'acme_plan', :'erin'), null, 'granting an undefined relation fails');
select tap.throws_ok(format($$ select permissions.grant('document', %L, 'viewer', 'team', %L, 'lead') $$, :'acme_plan', :'eng'), null, 'granting to an undefined userset fails');

-- revocation (the cycle above is still in place: eng and platform contain each other)
select permissions.revoke('team', :'eng', 'member', 'user', :'dave');
select tap.is(permissions.can_for('user', :'dave', 'document', :'acme_plan', 'viewer'), false, 'revoking team membership removes inherited access');

-- expiry
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'erin', null, now() - interval '1 minute');
select tap.is(permissions.can_for('user', :'erin', 'document', :'acme_readme', 'editor'), false, 'an expired grant gives no access');
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'erin', null, now() + interval '1 hour');
select tap.is(permissions.can_for('user', :'erin', 'document', :'acme_readme', 'editor'), true, 'an unexpired grant does');

-- cleanup (PLAN.md §3: apps remove a deleted user's permissions)
select permissions.grant('document', :'acme_plan', 'editor', 'user', :'erin');
select permissions.forget_subject(:'erin');
select tap.set_eq(permissions.accessible_for('user', :'erin', 'document', 'viewer'), '{}', 'forget_subject removes all of a user''s access');
select permissions.forget_object('document', :'acme_plan');
select tap.is(
    (select count(*)::int from permissions.who_can('document', :'acme_plan', 'viewer')), 0,
    'forget_object removes all access to an object');

select * from tap.finish();
