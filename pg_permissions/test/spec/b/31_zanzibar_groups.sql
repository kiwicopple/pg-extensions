-- Goal: groups, nesting, cycles, revocation, expiry and cleanup (PLAN.md §2 Model 2, §3)
-- Design B's native API. Same scenario and assertions as a/31_zanzibar_groups.sql.
-- Group membership is a parents edge (user in team, team in team), kept as a
-- closure on write. Differences from A, both by design:
--   * B rejects a membership cycle when it is written, so evaluation never
--     sees one. Assertion 3 checks both halves (rejected, checks still answer).
--   * B has no usersets (team#lead). The nearest validation is that a policy
--     requiring an undeclared role is rejected (assertion 6).
\ir ../../fixtures/ids.sql

select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');
select permissions.permit('doc viewers view', '{select}', 'document', roles => '{viewer}');
select permissions.permit('doc editors edit', '{update}', 'document', roles => '{editor}');

-- dave in eng, eng nested in platform, platform can view the plan
select permissions.add_parent('user', :'dave', 'team', :'eng');
select permissions.add_parent('team', :'eng', 'team', :'platform');
select permissions.grant_role('team', :'platform', 'viewer', 'document', :'acme_plan');

-- true if the statement raises check_violation, B's cycle error (keeps it out of the TAP output)
create function pg_temp.rejects(p_sql text) returns boolean language plpgsql as $$
begin
    execute p_sql;
    return false;
exception when check_violation then
    return true;
end $$;

select tap.plan(11);

select tap.is(permissions.is_in('user', :'dave', 'team', :'platform'), true, 'members of a nested team are members of the parent');
select tap.is(permissions.can_for('user', :'dave', 'select', 'document', :'acme_plan'), true, 'access granted to the parent team reaches nested members');

-- cycles terminate (B: the cycle edge is rejected on write)
select tap.ok(
    pg_temp.rejects(format($$ select permissions.add_parent('team', %L, 'team', %L) $$, :'platform', :'eng'))
    and permissions.can_for('user', :'dave', 'select', 'document', :'acme_plan') is not null,
    'a membership cycle does not hang or error: the cycle edge is rejected on write and checks still answer');
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_plan'), false, 'a cycle does not grant access to outsiders');

-- validation
select tap.throws_ok(format($$ select permissions.grant_role('user', %L, 'owner', 'document', %L) $$, :'erin', :'acme_plan'), null, 'granting an undefined role fails');
select tap.throws_ok($$ select permissions.permit('team leads view', '{select}', 'document', roles => '{lead}') $$, null, 'a policy requiring an undefined role fails (B has no usersets)');

-- revocation
select permissions.remove_parent('user', :'dave', 'team', :'eng');
select tap.is(permissions.can_for('user', :'dave', 'select', 'document', :'acme_plan'), false, 'revoking team membership removes inherited access');

-- expiry
select permissions.grant_role('user', :'erin', 'editor', 'document', :'acme_readme', now() - interval '1 minute');
select tap.is(permissions.can_for('user', :'erin', 'update', 'document', :'acme_readme'), false, 'an expired grant gives no access');
select permissions.grant_role('user', :'erin', 'editor', 'document', :'acme_readme', now() + interval '1 hour');
select tap.is(permissions.can_for('user', :'erin', 'update', 'document', :'acme_readme'), true, 'an unexpired grant does');

-- cleanup (PLAN.md §3: apps remove a deleted user's permissions)
select permissions.grant_role('user', :'erin', 'editor', 'document', :'acme_plan');
select permissions.delete_entity('user', :'erin');
select tap.set_eq(permissions.ids_for('user', :'erin', 'select', 'document'), '{}', 'delete_entity removes all of a user''s access');
select permissions.delete_entity('document', :'acme_plan');
select tap.is(
    (select count(*)::int from permissions.who_can('select', 'document', :'acme_plan')), 0,
    'delete_entity removes all access to an object');

select * from tap.finish();
