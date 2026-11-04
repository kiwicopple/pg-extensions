# Share objects and manage tuples

A tuple records a relationship, such as a user viewing a document or belonging to a team.

First [write the model](models.md). Keep its model variables and server client in scope. Run the examples below in order as an admin; the next page checks the access they grant.

## Write tuples

A tuple says that a subject has a relation to an object. This is a tuple key in JSON: `{"user": "user:bob", "relation": "member", "object": "team:eng"}`. In a tuple key, the `user` field holds the subject.

Write tuples with `fga_write`:

```js tab="JavaScript"
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
const shared = await permissions.fga.admin.write({ writes })
if (shared.error) throw shared.error
```

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

The tuples grant the following relationships:

- Bob is in team `eng`. Everyone in team `design` is also in team `eng`. Carl is in team `design`.
- Anne owns the `projects` folder. Team `eng` views it.
- The `roadmaps` folder is inside `projects`. The roadmap document is inside `roadmaps`.
- Dana edits the roadmap. Carl has the `blocked` relation to the roadmap.
- Everyone views the handbook.

Use `writeTuple` and `deleteTuple` for a single unconditional relationship. You can repeat either call safely.

```js tab="JavaScript"
const tuple = {
  user: 'user:erin',
  relation: 'owner',
  object: 'document:notes',
}
const addedOwner = await permissions.fga.admin.writeTuple(tuple)
if (addedOwner.error) throw addedOwner.error
const sameOwner = await permissions.fga.admin.writeTuple(tuple)
if (sameOwner.error) throw sameOwner.error
// no error: already there
const removedOwner = await permissions.fga.admin.deleteTuple(tuple)
if (removedOwner.error) throw removedOwner.error
```

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

Use `admin.write` to apply several tuple changes in one transaction. Pass arrays in `writes` and `deletes`. To skip existing grants or missing deletions, set `onDuplicate` or `onMissing` to `"ignore"`. In SQL, wrap the corresponding array in an object with `tuple_keys` and `on_duplicate` or `on_missing`.

```js tab="JavaScript"
const additions = [
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
const changedTuples = await permissions.fga.admin.write({
  writes: additions,
  deletes,
  onMissing: 'ignore',
})
if (changedTuples.error) throw changedTuples.error
```

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

Without an option, `fga_write` raises an error when you write a tuple that exists. It also raises an error when you delete a tuple that does not exist. This is the OpenFGA behavior.

```js tab="JavaScript"
const repeatedGrant = [
  {
    user: 'user:erin',
    relation: 'editor',
    object: 'document:notes',
  },
]
const duplicate = await permissions.fga.admin.write({ writes: repeatedGrant })
// duplicate.error.message:
//   cannot write a tuple which already exists: ...
// duplicate.error.details:
//   openfga:2017 write_failed_due_to_invalid_input
// To skip the duplicate, pass onDuplicate: 'ignore'.
```

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

The extension checks each tuple against the type restrictions of the model. The relation `editor` is `[user, team#member]`, so a wildcard is not valid:

```js tab="JavaScript"
const invalidGrant = [
  {
    user: 'user:*',
    relation: 'editor',
    object: 'document:notes',
  },
]
const invalid = await permissions.fga.admin.write({ writes: invalidGrant })
// invalid.error.message:
//   Invalid tuple 'document:notes#editor@user:*'. Reason: ...
// invalid.error.details: openfga:2027 invalid_tuple
// invalid.error.hint:
//   'document#editor' allows users of type: team#member, user.
```

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

`fga_write` accepts at most 100 tuple keys in each call. See [Errors and limits](../../reference/limits.md#limits).

## Next step

Continue with [Check and list access](checks.md).
