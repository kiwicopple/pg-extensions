-- Goal: the SQL examples in docs/models/cedar/ (policies, templates,
-- entities, checks and extensions), docs/rls/ (the Cedar policies),
-- docs/integrations/privileges.md (Cedar functions) and the Cedar parts of
-- docs/reference/ (cedar.md, limits.md) work as written.
--
-- This file mirrors the pages in prerequisite order, so the state one page
-- builds (policies, entities) is what the next one uses. When you change an
-- example on a page, change it here, and the other way round. Statements
-- without a result are copied from the page. Queries that return something
-- appear as tap.is(<the same expression>, <the documented answer>), and
-- errors as cedar_t.err(<the statement>) or cedar_t.msg(<the statement>).
\ir ../../fixtures/d/cedar.sql

select tap.plan(97);

-- ============================================================================
-- policies.md
-- ============================================================================

select permissions.cedar_put_policy(
  policy_id => 'eng-view-reports',
  policy => 'permit (
  principal in Team::"eng",
  action == Action::"view",
  resource in Folder::"reports"
);'
);
select tap.is((select count(*)::int from permissions.cedar_policies()), 1,
              'policies: a text put stores the policy');

select tap.is(cedar_t.err($$
select permissions.cedar_put_policy(
  policy_id => 'broken',
  policy => 'permit (principal, action, resource) when {'
)
$$), '42601 cedar:parse_error line=1 column=44', 'policies: a syntax error gives the line and the column');
select tap.is((cedar_t.msg($$
select permissions.cedar_put_policy(
  policy_id => 'broken',
  policy => 'permit (principal, action, resource) when {'
)
$$)).message, 'unexpected end of input at line 1, column 44: expected an expression', 'policies: the message');
select tap.is((cedar_t.msg($$
select permissions.cedar_put_policy(
  policy_id => 'broken',
  policy => 'permit (principal, action, resource) when {'
)
$$)).hint, 'Check the policy against the Cedar grammar: https://docs.cedarpolicy.com/policies/syntax-grammar.html', 'policies: the hint');
select tap.ok(cedar_t.err($$
select permissions.cedar_put_policy(
  policy_id => 'two',
  policy => 'permit (principal, action, resource); forbid (principal, action, resource);'
)
$$) like '42601 cedar:parse_error%', 'policies: text with two policies is an error');

select permissions.cedar_put_policy(
  policy_id => 'owner-edit',
  policy => 'permit (
  principal,
  action == Action::"edit",
  resource
)
when { resource.owner == principal };'
);

select permissions.cedar_put_policy(
  policy_id => 'no-confidential',
  policy_json => '{
  "effect": "forbid",
  "principal": {"op": "All"},
  "action": {"op": "All"},
  "resource": {"op": "All"},
  "conditions": [
    {
      "kind": "when",
      "body": {
        "==": {
          "left": {
            ".": {
              "left": {"Var": "resource"},
              "attr": "level"
            }
          },
          "right": {"Value": "confidential"}
        }
      }
    }
  ]
}'
);
select tap.is(cedar_t.err($$
select permissions.cedar_put_policy(
  policy_id => 'x',
  policy => 'permit (principal, action, resource);',
  policy_json => '{}'
)
$$), '22023 cedar:invalid_argument argument=''policy''', 'policies: both policy and policy_json is invalid_argument');
select tap.is(cedar_t.err($$
select permissions.cedar_put_policy(policy_id => 'x')
$$), '22004 cedar:null_argument argument=''policy''', 'policies: neither is null_argument');

select permissions.cedar_put_policy(
  policy_id => 'notes',
  policy => '@id("old-name")
@advice("Ask the security team first.")
forbid (principal, action, resource)
when { context.maintenance };'
);
select tap.is((
select
  annotations
from permissions.cedar_policies()
where policy_id = 'notes'), '{"id": "old-name", "advice": "Ask the security team first."}',
              'policies: annotations are stored, and @id does not name the policy');
select tap.is((select array_agg(policy_id::text) from permissions.cedar_policies()),
              '{eng-view-reports,no-confidential,notes,owner-edit}'::text[], 'policies: cedar_policies lists the ids in order');
select tap.is((select array_agg(effect || ' ' || coalesce(template_id, '-')) from permissions.cedar_policies()),
              '{"permit -","forbid -","forbid -","permit -"}'::text[], 'policies: effect and no template');
select tap.is((select source is null from permissions.cedar_policies() where policy_id = 'no-confidential'), true,
              'policies: source is null for a JSON put');
select permissions.cedar_delete_policy(policy_id => 'notes');
select tap.is(cedar_t.err($$
select permissions.cedar_delete_policy(policy_id => 'notes')
$$), '22023 cedar:unknown_policy policy_id=''notes''', 'policies: deleting an unknown id is an error');
select tap.is((cedar_t.msg($$
select permissions.cedar_delete_policy(policy_id => 'notes')
$$)).hint, 'Policy ids: eng-view-reports, no-confidential, owner-edit.', 'policies: the hint lists the ids');

-- ============================================================================
-- entities.md
-- ============================================================================

select permissions.cedar_put_entities(
  entities => '[
    {"uid": {"type": "Team", "id": "eng"}},
    {
      "uid": {"type": "Team", "id": "design"},
      "parents": [{"type": "Team", "id": "eng"}]
    },
    {
      "uid": {"type": "user", "id": "alice"},
      "parents": [{"type": "Team", "id": "eng"}]
    },
    {"uid": {"type": "user", "id": "bob"}},
    {
      "uid": {"type": "user", "id": "carol"},
      "parents": [{"type": "Team", "id": "design"}]
    },
    {"uid": {"type": "Folder", "id": "reports"}},
    {
      "uid": {"type": "Document", "id": "q3"},
      "attrs": {
        "owner": {"__entity": {"type": "user", "id": "bob"}},
        "level": "internal"
      },
      "parents": [{"type": "Folder", "id": "reports"}],
      "tags": {"region": "eu"}
    },
    {
      "uid": {"type": "Document", "id": "salaries"},
      "attrs": {
        "owner": {"__entity": {"type": "user", "id": "alice"}},
        "level": "confidential"
      }
    }
  ]'
);
select tap.is(cedar_t.authz('user::"carol"', 'Action::"view"', 'Document::"q3"'),
              'allow [eng-view-reports] errors []', 'entities: carol is in design, design is in eng');

select tap.is(cedar_t.err($$
select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "Team", "id": "eng"},
      "parents": [{"type": "Team", "id": "design"}]
    }
  ]'
)
$$), '22023 cedar:invalid_entity uid=''Team::"design"''', 'entities: a cycle is invalid_entity');
select tap.is((cedar_t.msg($$
select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "Team", "id": "eng"},
      "parents": [{"type": "Team", "id": "design"}]
    }
  ]'
)
$$)).message, 'the entity hierarchy has a cycle through Team::"design"', 'entities: the message names the entity');
select tap.is(cedar_t.authz('user::"carol"', 'Action::"view"', 'Document::"q3"'),
              'allow [eng-view-reports] errors []', 'entities: the failed put changed nothing');

select tap.is(permissions.cedar_read_entities(
  type => 'Document',
  ids => '{q3}'
), '[{"uid": {"id": "q3", "type": "Document"}, "tags": {"region": "eu"}, "attrs": {"level": "internal", "owner": {"__entity": {"id": "bob", "type": "user"}}}, "parents": [{"id": "reports", "type": "Folder"}]}]',
              'entities: cedar_read_entities returns the entity as put');

select tap.is(permissions.cedar_delete_entities(
  uids => '[{"type": "Document", "id": "salaries"}]'
), 1::bigint, 'entities: cedar_delete_entities returns the count');
select tap.is(permissions.cedar_delete_entities(
  uids => '[{"type": "Document", "id": "salaries"}]'
), 0::bigint, 'entities: an unknown uid is not an error');

select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "Document", "id": "salaries"},
      "attrs": {
        "owner": {"__entity": {"type": "user", "id": "alice"}},
        "level": "confidential"
      }
    }
  ]'
);
select tap.is((select count(*)::int from jsonb_array_elements(permissions.cedar_read_entities(type => 'Document'))), 2,
              'entities: the entity is back');

-- ============================================================================
-- templates.md
-- ============================================================================

select permissions.cedar_put_template(
  template_id => 'share-view',
  template => 'permit (
  principal == ?principal,
  action == Action::"view",
  resource == ?resource
);'
);
select permissions.cedar_put_template(
  template_id => 'team-folder',
  template => '@advice("Team access to a folder.")
permit (
  principal in ?principal,
  action == Action::"view",
  resource in ?resource
);'
);

select permissions.cedar_link_template(
  policy_id => 'bob-q3',
  template_id => 'share-view',
  principal => 'user::"bob"',
  resource => 'Document::"q3"'
);
select permissions.cedar_link_template(
  policy_id => 'design-reports',
  template_id => 'team-folder',
  principal => 'Team::"design"',
  resource => 'Folder::"reports"'
);
select tap.is(cedar_t.authz('user::"bob"', 'Action::"view"', 'Document::"q3"'),
              'allow [bob-q3] errors []', 'templates: a link is a policy and a reason');
select tap.is((
select
  jsonb_agg(jsonb_build_array(policy_id, template_id, slots) order by policy_id)
from permissions.cedar_policies()
where template_id is not null), '[["bob-q3", "share-view", {"?resource": {"id": "q3", "type": "Document"}, "?principal": {"id": "bob", "type": "user"}}], ["design-reports", "team-folder", {"?resource": {"id": "reports", "type": "Folder"}, "?principal": {"id": "design", "type": "Team"}}]]',
              'templates: cedar_policies shows the template and the slots of a link');
select tap.is(cedar_t.err($$
select permissions.cedar_link_template(
  policy_id => 'bob-all',
  template_id => 'share-view',
  principal => 'user::"bob"'
)
$$), '22023 cedar:invalid_link slot=''?resource''', 'templates: a missing slot is invalid_link');
select tap.is((cedar_t.msg($$
select permissions.cedar_link_template(
  policy_id => 'bob-all',
  template_id => 'share-view',
  principal => 'user::"bob"'
)
$$)).message, 'template ''share-view'' has the slot ?resource, and the link gives it no value', 'templates: the message');
select tap.is((
select
  jsonb_agg(jsonb_build_array(template_id, annotations) order by template_id)
from permissions.cedar_templates()), '[["share-view", {}], ["team-folder", {"advice": "Team access to a folder."}]]',
              'templates: cedar_templates lists the templates');

select permissions.cedar_delete_policy(policy_id => 'bob-q3');
select permissions.cedar_delete_template(template_id => 'share-view');
select tap.is(cedar_t.err($$
select permissions.cedar_delete_template(template_id => 'team-folder')
$$), '2BP01 cedar:template_in_use template_id=''team-folder''', 'templates: a template with links cannot be deleted');
select tap.is((cedar_t.msg($$
select permissions.cedar_delete_template(template_id => 'team-folder')
$$)).message, 'template ''team-folder'' has 1 link', 'templates: the message');
select tap.is((cedar_t.msg($$
select permissions.cedar_delete_template(template_id => 'team-folder')
$$)).hint, 'Delete its links first, with select permissions.cedar_delete_policy(policy_id => ...) for each: design-reports.', 'templates: the hint names the links');

-- ============================================================================
-- checks.md
-- ============================================================================

select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
), '{"errors": [], "reasons": ["eng-view-reports"], "decision": "allow"}', 'checks: alice views q3');
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"bob"',
  action => 'Action::"edit"',
  resource => 'Document::"q3"'
), '{"errors": [], "reasons": ["owner-edit"], "decision": "allow"}', 'checks: bob edits q3');
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"carol"',
  action => 'Action::"edit"',
  resource => 'Document::"q3"'
), '{"errors": [], "reasons": [], "decision": "deny"}', 'checks: the default is deny');
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"view"',
  resource => 'Document::"salaries"'
), '{"errors": [], "reasons": ["no-confidential"], "decision": "deny"}', 'checks: a forbid wins');

select permissions.cedar_put_policy(
  policy_id => 'approve-with-mfa',
  policy => 'permit (
  principal in Team::"eng",
  action == Action::"approve",
  resource
)
when { context.mfa };'
);
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"approve"',
  resource => 'Document::"q3"',
  context => '{"mfa": true}'
), '{"errors": [], "reasons": ["approve-with-mfa"], "decision": "allow"}', 'checks: the context');
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"approve"',
  resource => 'Document::"q3"'
), '{
  "errors": [
    {
      "message": "attribute_not_found: the record has no attribute \"mfa\"",
      "policy_id": "approve-with-mfa"
    }
  ],
  "reasons": [],
  "decision": "deny"
}', 'checks: a failed policy is reported and skipped');

select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"dave"',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
), '{"errors": [], "reasons": [], "decision": "deny"}', 'checks: dave has no entity');
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"dave"',
  action => 'Action::"view"',
  resource => 'Document::"q3"',
  entities => '[
    {
      "uid": {"type": "user", "id": "dave"},
      "parents": [{"type": "Team", "id": "eng"}]
    }
  ]'
), '{"errors": [], "reasons": ["eng-view-reports"], "decision": "allow"}', 'checks: the entities of one request');

select tap.is(cedar_t.err($$
select permissions.cedar_is_authorized(
  principal => 'user:alice',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
)
$$), '22023 cedar:invalid_uid value=''user:alice''', 'checks: a bad uid raises');
select tap.is((cedar_t.msg($$
select permissions.cedar_is_authorized(
  principal => 'user:alice',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
)
$$)).message, 'invalid entity uid for principal: user:alice: it is not Type::"id"', 'checks: the message');
select tap.is((cedar_t.msg($$
select permissions.cedar_is_authorized(
  principal => 'user:alice',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
)
$$)).hint, 'Write a uid as Cedar text, a type and a quoted id: principal => ''User::"alice"'' (a namespaced type: ''App::User::"alice"'').', 'checks: the hint');

begin;
select set_config('permissions.subject_id', 'alice', true);
select tap.is(permissions.cedar_is_authorized_current(
  action => 'Action::"view"',
  resource => 'Document::"q3"'
), true, 'checks: current subject, allowed');
select tap.is(permissions.cedar_is_authorized_current(
  action => 'Action::"view"',
  resource => 'Document::"salaries"'
), false, 'checks: current subject, forbidden');
select tap.is(array(select permissions.cedar_list_resources_current(
  action => 'Action::"view"',
  resource_type => 'Document'
)), '{q3}'::text[], 'checks: the list');
commit;
select tap.is(permissions.cedar_is_authorized_current(
  action => 'Action::"view"',
  resource => 'Document::"q3"'
), false, 'checks: no subject, no access');

-- ============================================================================
-- extensions.md
-- ============================================================================

select permissions.cedar_put_policy(
  policy_id => 'ip-office',
  policy => 'permit (
  principal,
  action == Action::"download",
  resource
)
when { context.ip.isInRange(ip("10.0.0.0/8")) };'
);
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"download"',
  resource => 'Document::"q3"',
  context => '{
    "ip": {"__extn": {"fn": "ip", "arg": "10.1.2.3"}}
  }'
), '{"errors": [], "reasons": ["ip-office"], "decision": "allow"}', 'extensions: ip inside the range');
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"download"',
  resource => 'Document::"q3"',
  context => '{
    "ip": {"__extn": {"fn": "ip", "arg": "192.168.1.1"}}
  }'
), '{"errors": [], "reasons": [], "decision": "deny"}', 'extensions: ip outside the range');

select permissions.cedar_put_policy(
  policy_id => 'score',
  policy => 'permit (
  principal,
  action == Action::"rate",
  resource
)
when { context.score.greaterThanOrEqual(decimal("2.50")) };'
);
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"rate"',
  resource => 'Document::"q3"',
  context => '{
    "score": {"__extn": {"fn": "decimal", "arg": "3.2"}}
  }'
), '{"errors": [], "reasons": ["score"], "decision": "allow"}', 'extensions: decimal');

select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "Document", "id": "launch"},
      "attrs": {
        "level": "internal",
        "publish_at": {
          "__extn": {"fn": "datetime", "arg": "2026-12-01"}
        }
      }
    }
  ]'
);
select permissions.cedar_put_policy(
  policy_id => 'first-week',
  policy => 'permit (
  principal,
  action == Action::"open",
  resource
)
when {
  context.now >= resource.publish_at &&
  context.now.durationSince(resource.publish_at) < duration("7d")
};'
);
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"open"',
  resource => 'Document::"launch"',
  context => '{
    "now": {
      "__extn": {"fn": "datetime", "arg": "2026-12-03T10:00:00Z"}
    }
  }'
), '{"errors": [], "reasons": ["first-week"], "decision": "allow"}', 'extensions: datetime and duration, inside the week');
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"open"',
  resource => 'Document::"launch"',
  context => '{
    "now": {
      "__extn": {"fn": "datetime", "arg": "2026-12-09T00:00:00Z"}
    }
  }'
), '{"errors": [], "reasons": [], "decision": "deny"}', 'extensions: after the week');
select tap.is(permissions.cedar_read_entities(type => 'Document', ids => '{launch}') #>> '{0,attrs,publish_at,__extn,arg}',
              '2026-12-01T00:00:00.000Z', 'extensions: read gives the canonical datetime text');

-- the table of surprises: one condition, one value
create function pg_temp.probe(p_cond text) returns text language plpgsql as $$
declare r jsonb;
begin
  perform permissions.cedar_put_policy(policy_id => 'probe', policy => 'permit (principal, action == Action::"probe", resource) when { ' || p_cond || ' };');
  r := permissions.cedar_is_authorized(principal => 'user::"alice"', action => 'Action::"probe"', resource => 'Document::"q3"');
  perform permissions.cedar_delete_policy(policy_id => 'probe');
  return case when jsonb_array_length(r -> 'errors') > 0 then split_part(r #>> '{errors,0,message}', ':', 1)
              when r ->> 'decision' = 'allow' then 'true' else 'false' end;
end $$;
select tap.is(pg_temp.probe('decimal("1.0") < decimal("2.0")'), 'type_error', 'surprises: < on decimals');
select tap.is(pg_temp.probe('decimal("1.50") == decimal("1.5")'), 'true', 'surprises: decimal equality');
select tap.is(pg_temp.probe('decimal("1.23456") == decimal("1.0")'), 'extension_error', 'surprises: five digits');
select tap.is(pg_temp.probe('ip("10.0.0.1/24") == ip("10.0.0.2/24")'), 'false', 'surprises: host bits');
select tap.is(pg_temp.probe('ip("10.0.0.1/24").isInRange(ip("10.0.0.0/24"))'), 'true', 'surprises: isInRange');
select tap.is(pg_temp.probe('ip("10.0.0.1").isInRange(ip("10.0.0.0/8"), ip("11.0.0.0/8"))'), 'extension_error', 'surprises: two ranges');
select tap.is(pg_temp.probe('ip("::ffff:a00:1") == ip("10.0.0.1")'), 'false', 'surprises: mapped IPv6');
select tap.is(pg_temp.probe('ip("::ffff:1.2.3.4") == ip("::1")'), 'extension_error', 'surprises: dotted IPv4 in IPv6');
select tap.is(pg_temp.probe('ip("127.0.0.1/7").isLoopback()'), 'false', 'surprises: short prefix');
select tap.is(pg_temp.probe('datetime("2026-01-01T00:00:00+0100") < datetime("2026-01-01T00:00:00Z")'), 'true', 'surprises: +hhmm');
select tap.is(pg_temp.probe('datetime("2026-01-01T00:00:00+01:00") < datetime("2026-01-01T00:00:00Z")'), 'extension_error', 'surprises: +hh:mm');
select tap.is(pg_temp.probe('duration("1h30m") == duration("90m")'), 'true', 'surprises: duration equality');
select tap.is(pg_temp.probe('duration("1m1h") == duration("61m")'), 'extension_error', 'surprises: unit order');
select tap.is(pg_temp.probe('duration("-1999ms").toSeconds() == -1'), 'true', 'surprises: toward zero');
select tap.is(pg_temp.probe('datetime("1969-12-31T23:00:00Z").toTime() == duration("23h")'), 'true', 'surprises: toTime');
select tap.is(pg_temp.probe('true || decimal("x") == decimal("1.0")'), 'true', 'surprises: lazy constructor');
select tap.is(pg_temp.probe('decimal("x") == decimal("1.0")'), 'extension_error', 'surprises: evaluated constructor');
select tap.is(cedar_t.err($$
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"download"',
  resource => 'Document::"q3"',
  context => '{"ip": {"__extn": {"fn": "ip", "arg": "10.1.2.300"}}}'
)
$$), '22023 cedar:invalid_context', 'extensions: a bad value in the context raises invalid_context');

-- ============================================================================
-- rls/policies.md: Policies for Cedar
-- ============================================================================

select permissions.cedar_put_policy(
  policy_id => 'owner-view',
  policy => 'permit (
  principal,
  action == Action::"view",
  resource
)
when { resource.owner == principal };'
);

select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "Document", "id": "draft"},
      "attrs": {
        "owner": {"__entity": {"type": "user", "id": "alice"}},
        "level": "internal"
      }
    }
  ]'
);

create table public.documents (
  id text primary key,
  title text not null,
  owner_id text not null,
  level text not null
);
insert into public.documents (id, title, owner_id, level)
values
  ('q3', 'Q3 report', 'bob', 'internal'),
  ('salaries', 'Salaries', 'alice', 'confidential'),
  ('draft', 'Draft', 'alice', 'internal');
grant select, update on public.documents to authenticated;
alter table public.documents enable row level security;

create policy documents_select
  on public.documents
  for select
  to authenticated
  using (
    id = any (
      array(
        select permissions.cedar_list_resources_current(
          action => 'Action::"view"',
          resource_type => 'Document'
        )
      )
    )
  );

create policy documents_update
  on public.documents
  for update
  to authenticated
  using (
    permissions.cedar_is_authorized_current(
      action => 'Action::"edit"',
      resource => permissions.cedar_uid('Document', id),
      resource_attrs => jsonb_build_object(
        'owner', jsonb_build_object(
          '__entity', jsonb_build_object(
            'type', 'user',
            'id', owner_id
          )
        ),
        'level', level
      )
    )
  );

begin;
set local role authenticated;
select set_config('permissions.subject_id', 'alice', true);
select tap.is(array(select id from public.documents order by id), '{draft,q3}'::text[], 'rls: alice reads q3 and draft');
commit;
begin;
set local role authenticated;
select set_config('permissions.subject_id', 'bob', true);
select tap.is(array(select id from public.documents order by id), '{q3}'::text[], 'rls: bob reads q3');
commit;
begin;
set local role authenticated;
select set_config('permissions.subject_id', 'carol', true);
select tap.is(array(select id from public.documents order by id), '{q3}'::text[], 'rls: carol reads q3');
commit;
begin;
set local role authenticated;
select set_config('permissions.subject_id', 'nobody', true);
select tap.is(array(select id from public.documents order by id), '{}'::text[], 'rls: a subject with no access reads nothing');
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', 'alice', true);
with changed as (
  update public.documents set title = title || '!' returning id
)
select tap.is(array(select id from changed), '{draft}'::text[], 'rls: alice updates draft only');
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', 'bob', true);
with changed as (
  update public.documents set title = title || '!' returning id
)
select tap.is(array(select id from changed), '{q3}'::text[], 'rls: bob updates q3 only');
commit;

select permissions.cedar_put_policy(
  policy_id => 'block-flagged',
  policy => 'forbid (principal, action, resource)
when { resource.flagged };'
);
begin;
set local role authenticated;
select set_config('permissions.subject_id', 'alice', true);
select tap.is(array(select id from public.documents order by id), '{}'::text[], 'rls: a forbid that errors denies every row');
commit;
select tap.is(permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
) #>> '{errors,0,policy_id}', 'block-flagged', 'rls: cedar_is_authorized names the failing policy');

select permissions.cedar_put_policy(
  policy_id => 'block-flagged',
  policy => 'forbid (principal, action, resource)
when { resource has flagged && resource.flagged };'
);
begin;
set local role authenticated;
select set_config('permissions.subject_id', 'alice', true);
select tap.is(array(select id from public.documents order by id), '{draft,q3}'::text[], 'rls: with has, the rows are back');
commit;

-- ids with " and \ and a line break: cedar_uid, and the raw concatenation
insert into public.documents (id, title, owner_id, level)
values ('say "hi"', 'Quoted', 'bob', 'internal'), ('a\nb', 'Backslash n', 'bob', 'internal');
select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "Document", "id": "say \"hi\""},
      "attrs": {"owner": {"__entity": {"type": "user", "id": "bob"}}}
    },
    {
      "uid": {"type": "Document", "id": "a\\nb"},
      "attrs": {"owner": {"__entity": {"type": "user", "id": "bob"}}}
    }
  ]'
);
select tap.is(
  (select array_agg(permissions.cedar_is_authorized(
     principal => 'user::"bob"',
     action => 'Action::"view"',
     resource => permissions.cedar_uid('Document', id)
   ) ->> 'decision' order by id) from public.documents where id like 'say%' or id like 'a\\%'),
  array['allow', 'allow'], 'rls: cedar_uid gives the id that the policies name');
select tap.is(permissions.cedar_is_authorized_current(
  action => 'Action::"view"',
  resource => 'Document::"' || 'say "hi"' || '"'
), false, 'rls: a raw concatenation with a " is false, without an error');
delete from public.documents where id in ('say "hi"', 'a\nb');
select permissions.cedar_delete_entities(
  uids => '[{"type": "Document", "id": "say \"hi\""}, {"type": "Document", "id": "a\\nb"}]'
);

-- ============================================================================
-- integrations/privileges.md: Cedar functions
-- ============================================================================

set role authenticated;
select tap.throws_ok($$
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
)
$$, '42501', 'privileges: a client cannot call cedar_is_authorized');
select tap.throws_ok($$
select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "user", "id": "mallory"},
      "parents": [{"type": "Team", "id": "eng"}]
    }
  ]'
)
$$, '42501', 'privileges: a client cannot call cedar_put_entities');
select tap.lives_ok($$
select permissions.cedar_is_authorized_current(
  action => 'Action::"view"',
  resource => permissions.cedar_uid('Document', 'q3')
)
$$, 'privileges: a client can call the current-subject function and cedar_uid');
reset role;

grant execute on function
    permissions.cedar_put_policy(text, text, jsonb),
    permissions.cedar_delete_policy(text),
    permissions.cedar_policies(),
    permissions.cedar_put_template(text, text, jsonb),
    permissions.cedar_link_template(text, text, text, text),
    permissions.cedar_delete_template(text),
    permissions.cedar_templates(),
    permissions.cedar_put_entities(jsonb),
    permissions.cedar_delete_entities(jsonb),
    permissions.cedar_read_entities(text, text[]),
    permissions.cedar_is_authorized(text, text, text, jsonb, jsonb)
to service_role;
select tap.ok(has_function_privilege('service_role', 'permissions.cedar_is_authorized(text,text,text,jsonb,jsonb)', 'execute'),
              'privileges: the grant works');
revoke execute on function
    permissions.cedar_put_policy(text, text, jsonb),
    permissions.cedar_delete_policy(text),
    permissions.cedar_policies(),
    permissions.cedar_put_template(text, text, jsonb),
    permissions.cedar_link_template(text, text, text, text),
    permissions.cedar_delete_template(text),
    permissions.cedar_templates(),
    permissions.cedar_put_entities(jsonb),
    permissions.cedar_delete_entities(jsonb),
    permissions.cedar_read_entities(text, text[]),
    permissions.cedar_is_authorized(text, text, text, jsonb, jsonb)
from service_role;

-- ============================================================================
-- reference/limits.md: Cedar limits
-- ============================================================================

begin;
select permissions.cedar_put_entities(
  entities => (
    select jsonb_agg(
      jsonb_build_object(
        'uid', jsonb_build_object(
          'type', 'Item',
          'id', 'i' || g
        )
      )
    )
    from generate_series(1, 10000) g
  )
);
select permissions.cedar_put_entities(
  entities => (
    select jsonb_agg(
      jsonb_build_object(
        'uid', jsonb_build_object(
          'type', 'Item',
          'id', 'i' || g
        )
      )
    )
    from generate_series(10001, 20000) g
  )
);
commit;
select tap.is(jsonb_array_length(permissions.cedar_read_entities(type => 'Item')), 20000, 'limits: two batches of 10,000 entities');

select tap.is(cedar_t.err($$
select permissions.cedar_put_entities(
  entities => (
    select jsonb_agg(
      jsonb_build_object(
        'uid', jsonb_build_object(
          'type', 'Big',
          'id', 'b' || g
        )
      )
    )
    from generate_series(1, 10001) g
  )
)
$$), '54000 cedar:limit_exceeded limit=''put_entities''', 'limits: 10,001 entities is limit_exceeded');
select tap.is((cedar_t.msg($$
select permissions.cedar_put_entities(
  entities => (
    select jsonb_agg(
      jsonb_build_object(
        'uid', jsonb_build_object(
          'type', 'Big',
          'id', 'b' || g
        )
      )
    )
    from generate_series(1, 10001) g
  )
)
$$)).message, 'too many entities in entities: 10001 (the limit is 10000)', 'limits: the message');
select tap.is((cedar_t.msg($$
select permissions.cedar_put_entities(
  entities => (
    select jsonb_agg(
      jsonb_build_object(
        'uid', jsonb_build_object(
          'type', 'Big',
          'id', 'b' || g
        )
      )
    )
    from generate_series(1, 10001) g
  )
)
$$)).hint, 'An argument holds at most 10000 entities: put them in batches.', 'limits: the hint');
select permissions.cedar_delete_entities(
  uids => (select jsonb_agg(e -> 'uid') from jsonb_array_elements(permissions.cedar_read_entities(type => 'Item')) e)
);

-- ============================================================================
-- reference/cedar.md
-- ============================================================================

select tap.is(permissions.cedar_uid('Document', 'say "hi"'), 'Document::"say \"hi\""', 'reference: cedar_uid');
select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "user", "id": "zoe"},
      "parents": [{"type": "Team", "id": "eng"}]
    }
  ]'
);
select tap.is(permissions.cedar_delete_entities(
  uids => '[{"type": "user", "id": "zoe"}]'
), 1::bigint, 'reference: cedar_delete_entities');
select permissions.cedar_put_policy(
  policy_id => 'owner-edit',
  policy => 'permit (
  principal,
  action == Action::"edit",
  resource
)
when { resource.owner == principal };'
);
select permissions.cedar_delete_policy(
  policy_id => 'owner-edit'
);
select tap.is(cedar_t.err($$
select permissions.cedar_put_policy(policy_id => 'x', policy => 'permit (principal, action, resource == ?resource);')
$$), '22023 cedar:invalid_policy path=''$.resource''', 'reference: a slot in a static policy is invalid_policy');
select tap.is(cedar_t.err($$
select permissions.cedar_list_resources_current(action => 'Action::"view"', resource_type => 'Doc"x')
$$), '22023 cedar:invalid_argument value=''Doc"x''', 'reference: a bad resource_type is invalid_argument');

-- the listing queries of the pages, as written (they need policies and templates,
-- so they run before the combine section removes them)
create temp table listing_1 as
select
  policy_id,
  annotations
from permissions.cedar_policies()
where policy_id = 'notes';
create temp table listing_2 as
select
  policy_id,
  effect,
  template_id
from permissions.cedar_policies();
create temp table listing_3 as
select
  policy_id,
  template_id,
  slots
from permissions.cedar_policies()
where template_id is not null;
create temp table listing_4 as
select
  template_id,
  annotations
from permissions.cedar_templates();
create temp table listing_5 as
select
  policy_id,
  effect
from permissions.cedar_policies();
create temp table listing_6 as
select template_id from permissions.cedar_templates();
select tap.is((select count(*)::int from listing_2), (select count(*)::int from listing_5), 'listings: the queries of the pages run');

-- ============================================================================
-- rls/combine-models.md: Add Cedar as a third model
-- (the table and the RBAC arm are those of that page, without OpenFGA)
-- ============================================================================

drop table public.documents;
-- this page runs in another database: remove the policies and the entities of the other pages
select permissions.cedar_delete_policy(policy_id => policy_id) from permissions.cedar_policies();
select permissions.cedar_delete_entities(
  uids => (select jsonb_agg(e -> 'uid') from jsonb_array_elements(permissions.cedar_read_entities(type => 'Document')) e)
);
\ir ../../fixtures/ids.sql
\set draft '00000000-0000-0000-0003-000000000004'
\set diary '00000000-0000-0000-0003-000000000005'
select permissions.rbac_create_role(role => 'viewer', permissions => '{documents.read}');
create table public.documents (
    id     uuid primary key,
    org_id uuid,                 -- null: a personal document
    status text not null default 'published',
    title  text not null
);
create index on public.documents (org_id);
insert into public.documents (id, org_id, status, title) values
    (:'acme_plan',   :'acme',   'published', 'acme plan'),
    (:'acme_readme', :'acme',   'published', 'acme readme'),
    (:'globex_notes',  :'globex', 'published', 'globex notes'),
    (:'draft', :'globex', 'draft',     'globex draft'),
    (:'diary', null,      'published', 'dave''s diary');
alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;
select permissions.rbac_assign_role(user_id => :'alice', role => 'viewer', scope => :'acme');
select permissions.rbac_assign_role(user_id => :'dave', role => 'viewer', scope => :'acme');
create policy documents_select_rbac
  on public.documents
  for select
  to authenticated
  using (
    org_id = any (
      array(
        select unnest(
          permissions.rbac_scopes_with_permission(
            permission => 'documents.read'
          )
        )::uuid
      )
    )
  );
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);
select tap.is((select count(*) from public.documents), 2::bigint, 'combine: before Cedar, dave sees the acme documents');
commit;

select permissions.cedar_put_policy(
  policy_id => 'auditors-view',
  policy => 'permit (
  principal in Team::"auditors",
  action == Action::"view",
  resource is Document
);'
);
select permissions.cedar_put_policy(
  policy_id => 'access-open',
  policy => 'permit (
  principal,
  action == Action::"access",
  resource
);'
);
select permissions.cedar_put_policy(
  policy_id => 'suspended',
  policy => 'forbid (
  principal in Team::"suspended",
  action == Action::"access",
  resource
);'
);

select permissions.cedar_put_entities(
  entities => (
    select jsonb_agg(
      jsonb_build_object(
        'uid', jsonb_build_object(
          'type', 'Document',
          'id', id::text
        )
      )
    )
    from public.documents
  )
);
select permissions.cedar_put_entities(
  entities => jsonb_build_array(
    jsonb_build_object(
      'uid', jsonb_build_object(
        'type', 'user',
        'id', :'erin'
      ),
      'parents', jsonb_build_array(
        jsonb_build_object(
          'type', 'Team',
          'id', 'auditors'
        )
      )
    ),
    jsonb_build_object(
      'uid', jsonb_build_object(
        'type', 'user',
        'id', :'dave'
      ),
      'parents', jsonb_build_array(
        jsonb_build_object(
          'type', 'Team',
          'id', 'suspended'
        )
      )
    )
  )
);

create policy documents_select_cedar
  on public.documents
  for select
  to authenticated
  using (
    id = any (
      array(
        select permissions.cedar_list_resources_current(
          action => 'Action::"view"',
          resource_type => 'Document'
        )::uuid
      )
    )
  );
create policy documents_cedar_gate
  on public.documents
  as restrictive
  for select
  to authenticated
  using (
    permissions.cedar_is_authorized_current(
      action => 'Action::"access"',
      resource => permissions.cedar_uid(
        'Document',
        id::text
      )
    )
  );

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'erin', true);
select tap.is((select count(*) from public.documents), 5::bigint, 'combine: erin, an auditor, sees every document');
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);
select tap.is((select count(*) from public.documents), 0::bigint, 'combine: dave is suspended in Cedar and sees nothing');
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'alice', true);
select tap.is((select count(*) from public.documents), 2::bigint, 'combine: alice keeps her RBAC documents');
commit;

begin;
set local role authenticated;
select tap.is((select count(*) from public.documents), 0::bigint, 'combine: no subject, no rows');
commit;


select * from tap.finish();
