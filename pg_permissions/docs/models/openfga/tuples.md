# Share objects and manage tuples

A tuple records a relationship, such as a user viewing a document or belonging to a team.

First [write the model](models.md). Keep its model variables and server client in scope. Run the examples below in order as an admin; the next page checks the access they grant.

## Write tuples

A tuple says that a subject has a relation to an object. This is a tuple key in JSON: `{"user": "user:bob", "relation": "member", "object": "team:eng"}`. In a tuple key, the `user` field holds the subject.

Write tuples with `fga_write`:

```sql tab="SQL"
select permissions.fga_write(
  writes => '[
    {
      "user": "user:bob",
      "relation": "member",
      "object": "team:eng"
    },
    {
      "user": "team:design#member",
      "relation": "member",
      "object": "team:eng"
    },
    {
      "user": "user:carl",
      "relation": "member",
      "object": "team:design"
    },
    {
      "user": "user:anne",
      "relation": "owner",
      "object": "folder:projects"
    },
    {
      "user": "team:eng#member",
      "relation": "viewer",
      "object": "folder:projects"
    },
    {
      "user": "folder:projects",
      "relation": "parent",
      "object": "folder:roadmaps"
    },
    {
      "user": "folder:roadmaps",
      "relation": "parent",
      "object": "document:roadmap"
    },
    {
      "user": "user:dana",
      "relation": "editor",
      "object": "document:roadmap"
    },
    {
      "user": "user:carl",
      "relation": "blocked",
      "object": "document:roadmap"
    },
    {
      "user": "user:*",
      "relation": "viewer",
      "object": "document:handbook"
    }
  ]'
);
```

```ts tab="JavaScript"
const writes = [
  {
    user: 'user:bob',
    relation: 'member',
    object: 'team:eng',
  },
  {
    user: 'team:design#member',
    relation: 'member',
    object: 'team:eng',
  },
  {
    user: 'user:carl',
    relation: 'member',
    object: 'team:design',
  },
  {
    user: 'user:anne',
    relation: 'owner',
    object: 'folder:projects',
  },
  {
    user: 'team:eng#member',
    relation: 'viewer',
    object: 'folder:projects',
  },
  {
    user: 'folder:projects',
    relation: 'parent',
    object: 'folder:roadmaps',
  },
  {
    user: 'folder:roadmaps',
    relation: 'parent',
    object: 'document:roadmap',
  },
  {
    user: 'user:dana',
    relation: 'editor',
    object: 'document:roadmap',
  },
  {
    user: 'user:carl',
    relation: 'blocked',
    object: 'document:roadmap',
  },
  {
    user: 'user:*',
    relation: 'viewer',
    object: 'document:handbook',
  },
]
await permissions.fga.admin.write({ writes })
```

The tuples grant the following relationships:

- Bob is in team `eng`. Everyone in team `design` is also in team `eng`. Carl is in team `design`.
- Anne owns the `projects` folder. Team `eng` views it.
- The `roadmaps` folder is inside `projects`. The roadmap document is inside `roadmaps`.
- Dana edits the roadmap. Carl has the `blocked` relation to the roadmap.
- Everyone views the handbook.

To write or delete one tuple, use `fga_write_tuple` or `fga_delete_tuple`. These functions do not fail when the tuple is already there or already gone:

```sql tab="SQL"
select permissions.fga_write_tuple(
  subject => 'user:erin',
  relation => 'owner',
  object => 'document:notes'
);
select permissions.fga_write_tuple(
  subject => 'user:erin',
  relation => 'owner',
  object => 'document:notes'
);
-- no error: already there
select permissions.fga_delete_tuple(
  subject => 'user:erin',
  relation => 'owner',
  object => 'document:notes'
);
```

```ts tab="JavaScript"
const tuple = {
  user: 'user:erin',
  relation: 'owner',
  object: 'document:notes',
}
await permissions.fga.admin.writeTuple(tuple)
await permissions.fga.admin.writeTuple(tuple)
// no error: already there
await permissions.fga.admin.deleteTuple(tuple)
```

`fga_write` takes writes and deletes together, in one transaction. Each side is an array of tuple keys. Each side can also be an object `{"tuple_keys": [...]}` with an option. The option `"on_duplicate": "ignore"` applies to writes. The option `"on_missing": "ignore"` applies to deletes. In JavaScript, pass `onDuplicate` and `onMissing` in the request:

```sql tab="SQL"
select permissions.fga_write(
  writes => '[
    {
      "user": "user:erin",
      "relation": "editor",
      "object": "document:notes"
    }
  ]',
  deletes => '{
    "tuple_keys": [
      {
        "user": "user:zed",
        "relation": "editor",
        "object": "document:notes"
      }
    ],
    "on_missing": "ignore"
  }'
);
```

```ts tab="JavaScript"
const writes = [
  {
    user: 'user:erin',
    relation: 'editor',
    object: 'document:notes',
  },
]
const deletes = [
  {
    user: 'user:zed',
    relation: 'editor',
    object: 'document:notes',
  },
]
await permissions.fga.admin.write({
  writes,
  deletes,
  onMissing: 'ignore',
})
```

Without an option, `fga_write` raises an error when you write a tuple that exists. It also raises an error when you delete a tuple that does not exist. This is the OpenFGA behavior.

```sql tab="SQL"
select permissions.fga_write(
  writes => '[
    {
      "user": "user:erin",
      "relation": "editor",
      "object": "document:notes"
    }
  ]'
);
-- ERROR:  cannot write a tuple which already exists: document:notes#editor@user:erin
-- DETAIL:  openfga:2017 write_failed_due_to_invalid_input
-- HINT:  Pass writes as {"tuple_keys": [...], "on_duplicate": "ignore"} to skip tuples that already exist.
```

```ts tab="JavaScript"
const writes = [
  {
    user: 'user:erin',
    relation: 'editor',
    object: 'document:notes',
  },
]
const duplicate = await permissions.fga.admin.write({ writes })
// duplicate.error.message:
//   cannot write a tuple which already exists: ...
// duplicate.error.details:
//   openfga:2017 write_failed_due_to_invalid_input
// To skip the duplicate, pass onDuplicate: 'ignore'.
```

The extension checks each tuple against the type restrictions of the model. The relation `editor` is `[user, team#member]`, so a wildcard is not valid:

```sql tab="SQL"
select permissions.fga_write(
  writes => '[
    {
      "user": "user:*",
      "relation": "editor",
      "object": "document:notes"
    }
  ]'
);
-- ERROR:  Invalid tuple 'document:notes#editor@user:*'. Reason: the typed wildcard 'user:*' is not an allowed type restriction for 'document#editor'
-- DETAIL:  openfga:2027 invalid_tuple
-- HINT:  'document#editor' allows users of type: team#member, user.
```

```ts tab="JavaScript"
const writes = [
  {
    user: 'user:*',
    relation: 'editor',
    object: 'document:notes',
  },
]
const invalid = await permissions.fga.admin.write({ writes })
// invalid.error.message:
//   Invalid tuple 'document:notes#editor@user:*'. Reason: ...
// invalid.error.details: openfga:2027 invalid_tuple
// invalid.error.hint:
//   'document#editor' allows users of type: team#member, user.
```

`fga_write` accepts at most 100 tuple keys in each call. See [Errors and limits](../../reference/limits.md#limits).

## Next step

Continue with [Check and list access](checks.md).
