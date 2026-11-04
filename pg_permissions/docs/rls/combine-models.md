# Combine permission models

Keep organization roles and add individual shares on the same table. Separate permissive policies grant access through either model. A restrictive policy can deny access across both.

This guide covers the optional RLS integration. To combine model results in a backend without table policies, see [Combine model decisions](../integrations/checks.md#combine-model-decisions).

First complete [Read and write policies](policies.md), including its setup. Continue in the same psql session as the extension owner. This page defines the model, document data, and policies used by the next two pages.

## Write the models

The model has teams, organizations and documents. The relation `banned` will be a deny across both models. The relations `published` and `reader` are for [row attributes](denies-and-context.md#row-attributes-that-only-rls-sees). The condition `non_expired_grant` is for [conditions in policies](denies-and-context.md#conditions-in-policies).

```text
model
  schema 1.1

type user

type team
  relations
    define member: [user]

type org
  relations
    define banned: [user]

type document
  relations
    define owner: [user]
    define editor: [user] or owner
    define viewer: [user, user with non_expired_grant, team#member] or editor
    define published: [user:*]
    define reader: (viewer and published) or editor

condition non_expired_grant(
  current_time: timestamp,
  grant_time: timestamp,
  grant_duration: duration
) {
  current_time < grant_time + grant_duration
}
```

Both APIs accept the JSON representation of this model. To load it from JavaScript, save the DSL above as `model.fga` and run `fga model transform --file model.fga > model.json`.

```js tab="JavaScript"
import { readFile } from 'node:fs/promises'

const model = JSON.parse(await readFile('model.json', 'utf8'))
await permissions.fga.admin.writeAuthorizationModel(model)
```

```sql tab="SQL"
select permissions.fga_write_authorization_model(
  model => $json$
    {
      "schema_version": "1.1",
      "type_definitions": [
        {"type": "user"},
        {
          "type": "team",
          "relations": {"member": {"this": {}}},
          "metadata": {
            "relations": {
              "member": {
                "directly_related_user_types": [{"type": "user"}]
              }
            }
          }
        },
        {
          "type": "org",
          "relations": {"banned": {"this": {}}},
          "metadata": {
            "relations": {
              "banned": {
                "directly_related_user_types": [{"type": "user"}]
              }
            }
          }
        },
        {
          "type": "document",
          "relations": {
            "editor": {
              "union": {
                "child": [
                  {"this": {}},
                  {"computedUserset": {"relation": "owner"}}
                ]
              }
            },
            "owner": {"this": {}},
            "published": {"this": {}},
            "reader": {
              "union": {
                "child": [
                  {
                    "intersection": {
                      "child": [
                        {"computedUserset": {"relation": "viewer"}},
                        {"computedUserset": {"relation": "published"}}
                      ]
                    }
                  },
                  {"computedUserset": {"relation": "editor"}}
                ]
              }
            },
            "viewer": {
              "union": {
                "child": [
                  {"this": {}},
                  {"computedUserset": {"relation": "editor"}}
                ]
              }
            }
          },
          "metadata": {
            "relations": {
              "editor": {
                "directly_related_user_types": [{"type": "user"}]
              },
              "owner": {
                "directly_related_user_types": [{"type": "user"}]
              },
              "published": {
                "directly_related_user_types": [
                  {"type": "user", "wildcard": {}}
                ]
              },
              "reader": {},
              "viewer": {
                "directly_related_user_types": [
                  {"type": "user"},
                  {"condition": "non_expired_grant", "type": "user"},
                  {"relation": "member", "type": "team"}
                ]
              }
            }
          }
        }
      ],
      "conditions": {
        "non_expired_grant": {
          "expression": "current_time < grant_time + grant_duration",
          "name": "non_expired_grant",
          "parameters": {
            "current_time": {"type_name": "TYPE_NAME_TIMESTAMP"},
            "grant_duration": {"type_name": "TYPE_NAME_DURATION"},
            "grant_time": {"type_name": "TYPE_NAME_TIMESTAMP"}
          }
        }
      }
    }
  $json$::jsonb
);
```

## Create the table and the data

The table has an `org_id` column. The value is null for a personal document:

```sql
create table public.documents (
    id     uuid primary key,
    org_id uuid,                 -- null: a personal document
    status text not null default 'published',
    title  text not null
);
create index on public.documents (org_id);
insert into public.documents (id, org_id, status, title) values
    (:'plan',   :'acme',   'published', 'acme plan'),
    (:'readme', :'acme',   'published', 'acme readme'),
    (:'notes',  :'globex', 'published', 'globex notes'),
    (:'draft',  :'globex', 'draft',     'globex draft'),
    (:'diary',  null,      'published', 'dave''s diary');
alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;
```

Now add the roles and the tuples. The IDs in tuples are text. A UUID goes in as `'document:' || id`:

```js tab="JavaScript"
const ids = {
  alice: '11111111-1111-1111-1111-111111111111',
  bob: '22222222-2222-2222-2222-222222222222',
  carol: '33333333-3333-3333-3333-333333333333',
  dave: '44444444-4444-4444-4444-444444444444',
  eng: 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
  acme: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  readme: 'd0000000-0000-0000-0000-000000000002',
  notes: 'd0000000-0000-0000-0000-000000000003',
  draft: 'd0000000-0000-0000-0000-000000000004',
  diary: 'd0000000-0000-0000-0000-000000000005',
}

for (const [userId, role] of [
  [ids.alice, 'viewer'], [ids.carol, 'editor'], [ids.dave, 'viewer'],
]) {
  await permissions.rbac.admin.assignRole({ userId, role, scope: ids.acme })
}

const team = 'team:' + ids.eng
const bobUser = 'user:' + ids.bob
const daveUser = 'user:' + ids.dave
await permissions.fga.admin.write({
  writes: [
    { user: bobUser, relation: 'member', object: team },
    { user: team + '#member', relation: 'viewer', object: 'document:' + ids.notes },
    { user: team + '#member', relation: 'viewer', object: 'document:' + ids.draft },
    { user: bobUser, relation: 'editor', object: 'document:' + ids.readme },
    { user: daveUser, relation: 'owner', object: 'document:' + ids.diary },
    { user: daveUser, relation: 'viewer', object: 'document:' + ids.notes },
    { user: daveUser, relation: 'banned', object: 'org:' + ids.acme },
  ],
})
```

```sql tab="SQL"
-- RBAC: Alice reads acme, Carol edits acme, Dave reads acme
select permissions.rbac_assign_role(
  user_id => :'alice',
  role => 'viewer',
  scope => :'acme'
);
select permissions.rbac_assign_role(
  user_id => :'carol',
  role => 'editor',
  scope => :'acme'
);
select permissions.rbac_assign_role(
  user_id => :'dave',
  role => 'viewer',
  scope => :'acme'
);
-- FGA: team eng (Bob) views the globex notes and the draft, Bob
-- edits the acme readme, Dave owns his diary, views the globex notes
-- and is banned from acme
select permissions.fga_write(
  writes => jsonb_build_array(
    jsonb_build_object(
      'user', 'user:' || :'bob',
      'relation', 'member',
      'object', 'team:' || :'eng'
    ),
    jsonb_build_object(
      'user', 'team:' || :'eng' || '#member',
      'relation', 'viewer',
      'object', 'document:' || :'notes'
    ),
    jsonb_build_object(
      'user', 'team:' || :'eng' || '#member',
      'relation', 'viewer',
      'object', 'document:' || :'draft'
    ),
    jsonb_build_object(
      'user', 'user:' || :'bob',
      'relation', 'editor',
      'object', 'document:' || :'readme'
    ),
    jsonb_build_object(
      'user', 'user:' || :'dave',
      'relation', 'owner',
      'object', 'document:' || :'diary'
    ),
    jsonb_build_object(
      'user', 'user:' || :'dave',
      'relation', 'viewer',
      'object', 'document:' || :'notes'
    ),
    jsonb_build_object(
      'user', 'user:' || :'dave',
      'relation', 'banned',
      'object', 'org:' || :'acme'
    )
  )
);
```

## Current-subject functions

Clients and policies cannot call `fga_check`, because it takes the user as an argument. It is admin-only. Clients call these functions instead. They ask for the current subject, `user:<current_subject_id()>`. The type is `current_subject_type()`, which is `user` by default. See [Identity](../integrations/identity.md#identity).

| Function | Returns | Use it for |
| --- | --- | --- |
| `fga_check_current(relation, object)` | `boolean` | one row: update, delete and insert policies |
| `fga_list_object_ids_current(type, relation)` | `setof text`, bare IDs | read policies: `id = any (array(select ...::uuid))` |
| `fga_list_objects_current(type, relation)` | `setof text`, as `type:id` | clients that want the form of OpenFGA |

The [function reference](../reference.md) has the full signatures. This example runs as Bob:

```js tab="JavaScript"
const bob = permissions.as({ id: ids.bob })
const { data: canEdit } = await bob.fga.check({
  relation: 'editor', object: 'document:' + ids.readme,
})
// true
const { data: documentIds } = await bob.fga.listObjects({
  type: 'document', relation: 'viewer', idsOnly: true,
})
const { data: objects } = await bob.fga.listObjects({
  type: 'document', relation: 'viewer',
})
// documentIds contains the three UUIDs. objects contains the same IDs prefixed with 'document:'.
```

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', :'bob', true);
select permissions.fga_check_current(
  relation => 'editor',
  object => 'document:' || :'readme'
);
-- true
select permissions.fga_list_object_ids_current(
  type => 'document',
  relation => 'viewer'
);
-- the IDs of the readme, notes and draft
select permissions.fga_list_objects_current(
  type => 'document',
  relation => 'viewer'
);
-- the same, as document:<id>
commit;
```

These functions return false or no rows in three cases. There is no subject, there is no model yet, or the model does not define the subject type. A policy then denies access and does not fail.

The list functions have no limit of 1,000 rows. `fga_list_objects` has that limit. A limit in a policy would hide rows without an error.

## Write the policies

```sql
-- reads: permissive policies combine with OR
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
create policy documents_select_fga
  on public.documents
  for select
  to authenticated
  using (
    id = any (
      array(
        select permissions.fga_list_object_ids_current(
          type => 'document',
          relation => 'viewer'
        )::uuid
      )
    )
  );
-- a restrictive policy combines with AND: nobody sees the documents
-- of an org that bans them
create policy documents_not_banned
  on public.documents
  as restrictive
  for select
  to authenticated
  using (
    org_id is null
    or org_id <> all (
      array(
        select permissions.fga_list_object_ids_current(
          type => 'org',
          relation => 'banned'
        )::uuid
      )
    )
  );
-- writes: check the row
create policy documents_update_rbac
  on public.documents
  for update
  to authenticated
  using (
    permissions.rbac_has_permission(
      permission => 'documents.edit',
      scope => org_id::text
    )
  );
create policy documents_update_fga
  on public.documents
  for update
  to authenticated
  using (
    permissions.fga_check_current(
      relation => 'editor',
      object => 'document:' || id
    )
  );
```

This table shows what each user sees:

| User | Holds | Sees | Updates |
| --- | --- | --- | --- |
| Alice | `viewer` in acme | acme plan, acme readme | none |
| Bob | no role; team eng; editor of the acme readme | acme readme, globex notes, globex draft | acme readme |
| Carol | `editor` in acme | acme plan, acme readme | both acme documents |
| Dave | `viewer` in acme; banned from acme; owner of his diary; viewer of the globex notes | globex notes, diary of Dave | diary of Dave |
| Erin | nothing | nothing | none |

The ban overrides the acme role of Dave. The restrictive policy applies to each row, whatever the permissive policies said. This is how a deny works across models.

Inside the OpenFGA model, a deny is `but not`. It holds wherever the model uses that relation. But a `but not` on `document#viewer` does not stop an RBAC policy that gives access to the same row. Only a restrictive policy stops it. A second read arm for a parent, such as `folder_id = any (...)`, also does not see a `but not` on the document. List the relation that holds the deny.

To check the table, run a count as each user:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);
select title from public.documents order by title;
-- dave's diary, globex notes
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'carol', true);
select title from public.documents order by title;
-- acme plan, acme readme
update public.documents set title = title;           -- UPDATE 2
commit;
```

In a restrictive policy on a nullable column, write `org_id is null or`. A comparison with null gives null, and RLS treats null as false. Without it, Dave would lose his personal diary. An org bans him, and the diary does not belong to that org:

```sql
select null::uuid <> all (array[:'acme'::uuid]);   -- null, not true
```

## Add Cedar as a third model

Cedar fits into the same pattern. A list policy is another permissive arm, and a Cedar check can be a restrictive gate. This section is separate. The next pages do not use it. Run it in a copy of the database, or after you finish the walkthrough.

Cedar holds its own data (see [Policies (Cedar)](../models/cedar/overview.md)). A policy of Cedar does not see the roles of RBAC or the tuples of OpenFGA. The three Cedar policies below let the group `auditors` read every document, and they let a Cedar forbid block a group of users everywhere:

```js tab="JavaScript"
await permissions.cedar.admin.putPolicy({
  policyId: 'auditors-view',
  policy: `permit (
    principal in Team::"auditors", action == Action::"view", resource is Document
  );`,
})
await permissions.cedar.admin.putPolicy({
  policyId: 'access-open',
  policy: 'permit (principal, action == Action::"access", resource);',
})
await permissions.cedar.admin.putPolicy({
  policyId: 'suspended',
  policy: `forbid (
    principal in Team::"suspended", action == Action::"access", resource
  );`,
})
```

```sql tab="SQL"
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
```

Store the documents as entities, for the list, and put Erin in `auditors` and Dave in `suspended`. The ids of the entities are the ids of the rows:

```js tab="JavaScript"
const { rows: documents } = await pool.query('select id from public.documents')
await permissions.cedar.admin.putEntities(
  documents.map(({ id }) => ({ uid: { type: 'Document', id } })),
)
await permissions.cedar.admin.putEntities([
  {
    uid: { type: 'user', id: '55555555-5555-5555-5555-555555555555' },
    parents: [{ type: 'Team', id: 'auditors' }],
  },
  {
    uid: { type: 'user', id: ids.dave },
    parents: [{ type: 'Team', id: 'suspended' }],
  },
])
```

```sql tab="SQL"
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
```

Add the two policies to the table. The first policy is a third permissive arm. It combines with the RBAC arm and the OpenFGA arm with OR. The second policy is restrictive. It combines with AND. It checks the Cedar action `access`, which every user has unless a Cedar `forbid` applies:

```sql
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
```

Now Erin sees every document through `auditors-view`. She holds no role and no tuple. Dave sees nothing, although his RBAC role and his tuples give him documents. The Cedar `forbid` applies to every row, and the restrictive policy requires the Cedar answer:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'erin', true);
select count(*) from public.documents;
-- 5
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);
select count(*) from public.documents;
-- 0
commit;
```

Some points to keep in mind:

- A Cedar `forbid` blocks only through a Cedar check. It does not stop an RBAC arm or an OpenFGA arm. Use a restrictive policy with an action like `access` when a Cedar rule must deny across models. The restrictive policy needs a Cedar `permit` for that action, because the default of Cedar is deny.
- The restrictive policy checks each row. A row check is cheap when no `forbid` applies to the user, and it costs more for a user that a `forbid` applies to. See [Performance](performance.md#cedar-policies).
- For a deny that you can express as a list, a restrictive policy on `fga_list_object_ids_current`, as above, does its work once for each query.
- With no subject, the gate is `false`. The other arms are `false` as well.

## Next step

Continue with [Denies, row attributes, and trusted context](denies-and-context.md).
