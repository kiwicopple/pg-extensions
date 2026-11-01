-- Goal: who_can reports public (user:*) grants without enumerating users (research/plan.md §10, G11)
-- Design C: a public grant is a tuple with a null subject_id, so who_can
-- returns one null row for it: "every principal of the grant's type". It is
-- the counterpart of A's ('user', '*') row from list_subjects. Like A's row it
-- is not net of per-principal forbids (those principals can't be listed as
-- exceptions); a public forbid still empties the whole list.
\ir ../../fixtures/ids.sql
\set frank        '00000000-0000-0000-0001-000000000006'
\set announcement '00000000-0000-0000-0003-000000000005'
\set handbook     '00000000-0000-0000-0003-000000000006'

select count(*) from permissions.apply_model($json$
{
  "types": {
    "org": {
      "relations":   { "member": ["user", "user:*"] },
      "permissions": { "view": ["member"] }
    },
    "document": {
      "parent":      ["org"],
      "relations":   { "editor": ["user"], "viewer": ["user", "user:*"], "blocked": ["user", "user:*"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": {
        "edit": ["editor"],
        "view": { "any": ["viewer", "parent->view"], "but_not": ["blocked"] }
      }
    }
  }
}
$json$);

select permissions.grant('document', :'announcement', 'editor', 'user', :'bob');
select permissions.grant_public('document', :'announcement', 'viewer');
-- unrelated data, so "every user" would be a visibly larger list
select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'carol');
select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank');

select tap.plan(8);

select tap.set_eq(array(select permissions.who_can('document', :'announcement', 'view')),
                  array[null, :'bob']::uuid[],
                  'public view: who_can lists Bob and one null (public) row');
select tap.is((select count(*)::int from permissions.who_can('document', :'announcement', 'view') w where w is null), 1,
              'exactly one public row; users are not enumerated');
select tap.set_eq(array(select permissions.who_can('document', :'announcement', 'edit')), array[:'bob']::uuid[],
                  'edit has no public grant: no null row');
select tap.set_eq(array(select permissions.who_can('document', :'acme_readme', 'view')), array[:'carol', :'frank']::uuid[],
                  'a document without a public grant has no null row');

-- a per-user forbid removes that user, not the public row
select permissions.grant('document', :'announcement', 'blocked', 'user', :'bob');
select tap.set_eq(array(select permissions.who_can('document', :'announcement', 'view')), array[null]::uuid[],
                  'Bob blocked: only the public row remains');

-- a public forbid empties the list, public row included
select permissions.grant_public('document', :'announcement', 'blocked');
select tap.is((select count(*)::int from permissions.who_can('document', :'announcement', 'view')), 0,
              'a public forbid empties the list');

-- public on the parent reaches the child
select permissions.set_parent('document', :'handbook', 'org', :'acme');
select permissions.grant_public('org', :'acme', 'member');
select tap.set_eq(array(select permissions.who_can('document', :'handbook', 'view')), array[null]::uuid[],
                  'public membership of the parent org gives the document a public row');

select permissions.revoke_public('org', :'acme', 'member');
select tap.is((select count(*)::int from permissions.who_can('document', :'handbook', 'view')), 0,
              'after revoking it, no row');

select * from tap.finish();
