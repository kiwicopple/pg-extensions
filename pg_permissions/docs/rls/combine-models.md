# Combine permission models

Keep organization roles and add individual shares on the same table. Separate permissive policies grant access through either model. A restrictive policy can deny access across both.

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

Write the model as JSON. This JSON is the output of `fga model transform` for the model above:

```sql
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

```sql
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

```sql
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

## Next step

Continue with [Denies, row attributes, and trusted context](denies-and-context.md).
