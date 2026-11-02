# Store entities

Store the users, teams, folders and documents that your policies talk about. An entity has a type, an id, attributes, parents and tags.

First complete [Write policies](policies.md). The checks on the next pages use the policies and the entities from this page. An admin role runs these calls.

## Put entities

`cedar_put_entities` takes a JSON array of entities. This is Cedar's [entity JSON format](https://docs.cedarpolicy.com/auth/entities-syntax.html), with `uid` as an object. An entity has these keys:

| Key | Content |
| --- | --- |
| `uid` | `{"type": "Document", "id": "q3"}`. The type is a name such as `User` or `App::User`. The id is any string. |
| `attrs` | The attributes, a JSON object. The default is `{}`. |
| `parents` | The direct parents, an array of uids. The default is `[]`. |
| `tags` | The tags, a JSON object. The default is `{}`. |

This call stores two teams, three users, a folder and two documents. The team `design` is in the team `eng`. Carol is in `design`. Alice is in `eng`:

```sql tab="SQL"
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
```

```ts tab="JavaScript"
const entities = [
  { uid: { type: 'Team', id: 'eng' } },
  {
    uid: { type: 'Team', id: 'design' },
    parents: [{ type: 'Team', id: 'eng' }],
  },
  {
    uid: { type: 'user', id: 'alice' },
    parents: [{ type: 'Team', id: 'eng' }],
  },
  { uid: { type: 'user', id: 'bob' } },
  {
    uid: { type: 'user', id: 'carol' },
    parents: [{ type: 'Team', id: 'design' }],
  },
  { uid: { type: 'Folder', id: 'reports' } },
  {
    uid: { type: 'Document', id: 'q3' },
    attrs: {
      owner: { __entity: { type: 'user', id: 'bob' } },
      level: 'internal',
    },
    parents: [{ type: 'Folder', id: 'reports' }],
    tags: { region: 'eu' },
  },
  {
    uid: { type: 'Document', id: 'salaries' },
    attrs: {
      owner: { __entity: { type: 'user', id: 'alice' } },
      level: 'confidential',
    },
  },
]
await permissions.cedar.admin.putEntities(entities)
```

Each supplied entity replaces the stored entity with the same uid, including its attributes, parents and tags. Entities omitted from the array stay unchanged. A call stores up to 10,000 entities in one transaction.

Subjects are entities of the subject type. The user `alice` above is the entity `user::"alice"`. This is the principal when the current subject is `alice` (see [the overview](overview.md#the-subject-is-the-principal)). A user does not need a stored entity to be a principal. A policy that tests `principal in Team::"eng"` or `principal.level` needs the stored entity.

## Attribute values

An attribute value is a Cedar value in JSON:

| Cedar type | JSON |
| --- | --- |
| Boolean | `true` |
| Long | An integer from -2^63 to 2^63-1. A value such as `1.5` is an error. |
| String | `"text"` |
| Set | An array, `["a", "b"]` |
| Record | An object, `{"city": "Oslo"}` |
| Entity | `{"__entity": {"type": "user", "id": "bob"}}` |
| Extension value | `{"__extn": {"fn": "decimal", "arg": "12.34"}}` |

The key `__entity` marks an entity reference. The key `__extn` marks a value of an extension type. See [Extension types](extensions.md). A record that has only the key `__entity` or the key `__extn` is read as an entity or an extension value. Cedar's JSON has the same rule.

The extension reads no Cedar schema. For this reason, write `__entity` and `__extn` in every place that needs them. A bare string is a string.

A value that is not valid is the error `cedar:invalid_entity`, with the index of the entity in the array. Sets and records can have at most 32 levels of depth.

## The hierarchy

Store direct parents in `parents`; the evaluator follows the hierarchy. The expression `a in b` is true when `a` equals `b` or `b` is an ancestor of `a`. Carol belongs to `design`, which belongs to `eng`, so `user::"carol" in Team::"eng"` is true and `eng-view-reports` applies to her.

- A parent does not need to be a stored entity. An entity that does not exist has no parents, and it is not an error.
- The hierarchy cannot have a cycle. A put that makes an entity its own ancestor raises `cedar:invalid_entity`. Cedar rejects cycles too.
- Parents are for `in`. Use an attribute that holds an entity for other relations, such as the `owner` of a document.

This put makes a cycle, and it fails:

```sql
select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "Team", "id": "eng"},
      "parents": [{"type": "Team", "id": "design"}]
    }
  ]'
);
-- ERROR:  the entity hierarchy has a cycle through Team::"design"
-- DETAIL:  cedar:invalid_entity uid='Team::"design"'
-- HINT:  An entity cannot be its own ancestor (Cedar rejects cycles): remove one of the parent links of the cycle.
```

Two puts that run at the same time can make a cycle that neither put sees, because the extension takes no global lock. A check still ends in this case. Do not depend on this: write the entities of one hierarchy from one place.

## Read entities

`cedar_read_entities` returns the stored entities as a JSON array, in the same format as a put. Pass `type` to read one type, and `ids` to read some of its entities. `ids` needs `type`:

```sql tab="SQL"
select permissions.cedar_read_entities(
  type => 'Document',
  ids => '{q3}'
);
-- [
--   {
--     "uid": {"id": "q3", "type": "Document"},
--     "tags": {"region": "eu"},
--     "attrs": {
--       "level": "internal",
--       "owner": {"__entity": {"id": "bob", "type": "user"}}
--     },
--     "parents": [{"id": "reports", "type": "Folder"}]
--   }
-- ]
```

```ts tab="JavaScript"
const { data: docs } = await permissions.cedar.admin.readEntities({
  type: 'Document',
  ids: ['q3'],
})
// docs[0].parents: [{ type: 'Folder', id: 'reports' }]
```

An extension value comes back in its canonical text, which can differ from the text that you put (`"1.5"` comes back as `"1.5000"`). A put of the output changes nothing.

## Delete entities

`cedar_delete_entities` takes an array of uids and returns the number of entities that it deleted. An unknown uid is not an error:

```sql tab="SQL"
select permissions.cedar_delete_entities(
  uids => '[{"type": "Document", "id": "salaries"}]'
);
-- 1
```

```ts tab="JavaScript"
const { data: deleted } = await permissions.cedar.admin.deleteEntities([
  { type: 'Document', id: 'salaries' },
])
// deleted: 1
```

A delete removes the entity and its own parent links. It keeps the links of other entities that name it as a parent, as Cedar allows a parent that does not exist. To forget a user in every model, use [`delete_subject`](../../integrations/cleanup.md). It also removes the links that name the user as a parent.

Put the entity again to restore it for the next pages:

```sql
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
```

## Keep entities in sync

Update entities when users join a team or documents move. Write the entity changes and the corresponding application changes in the same transaction so they become visible together.

A row of your own tables does not have to be an entity. For a check in an RLS policy, the policy can pass the columns of the row as attributes. See [Cedar in RLS](../../rls/policies.md#policies-for-cedar). Store an entity when a policy uses its parents, or when you list resources with `cedar_list_resources_current`. The list function returns stored entities only.

## Next step

Continue with [Use policy templates](templates.md), then [Check access](checks.md).
