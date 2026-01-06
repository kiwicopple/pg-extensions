# pg_git: Git-like Version Control for PostgreSQL Data

## Overview

`pg_git` is a PostgreSQL extension that brings git-like versioning capabilities to database tables. Inspired by [s3git](https://github.com/s3git/s3git), it provides content-addressable storage, commits, branches, and diffs for your relational data.

## Core Concepts

### Content-Addressable Storage (CAS)

Like git and s3git, pg_git uses content-addressable storage where data is stored and retrieved based on its content hash (SHA-256). This enables:

- **Automatic deduplication**: Identical data is stored only once
- **Data integrity**: Hash verification ensures data hasn't been corrupted
- **Efficient storage**: Only changed data consumes additional space

### Object Model

pg_git uses a hierarchical object model similar to git:

```
commit
  └── tree (table snapshot)
        └── blob (row data)
```

| Object | Description |
|--------|-------------|
| **Blob** | Content-addressable storage of row data (serialized as JSONB) |
| **Tree** | Snapshot of a table at a point in time (list of blob references) |
| **Commit** | A versioned snapshot with metadata (message, author, timestamp, parent) |

### Branches and Refs

- **Branch**: A named, movable pointer to a commit
- **Tag**: A named, immutable pointer to a commit
- **HEAD**: The current branch/commit being worked on

## Architecture

### Schema: `pg_git`

All pg_git metadata is stored in a dedicated schema.

```sql
-- Content-addressable object storage
CREATE TABLE pg_git.objects (
    hash        TEXT PRIMARY KEY,      -- SHA-256 hash of content
    type        TEXT NOT NULL,         -- 'blob', 'tree', 'commit'
    content     BYTEA NOT NULL,        -- Compressed object data
    size        BIGINT NOT NULL,       -- Uncompressed size
    created_at  TIMESTAMPTZ DEFAULT now()
);

-- Repository tracking (which tables are versioned)
CREATE TABLE pg_git.repositories (
    id          SERIAL PRIMARY KEY,
    schema_name TEXT NOT NULL,
    table_name  TEXT NOT NULL,
    primary_key TEXT[] NOT NULL,       -- PK columns for row identification
    tracked_columns TEXT[],            -- NULL = all columns
    created_at  TIMESTAMPTZ DEFAULT now(),
    UNIQUE(schema_name, table_name)
);

-- Branch and tag references
CREATE TABLE pg_git.refs (
    repo_id     INTEGER REFERENCES pg_git.repositories(id),
    name        TEXT NOT NULL,         -- 'main', 'feature-x', 'v1.0'
    type        TEXT NOT NULL,         -- 'branch', 'tag'
    commit_hash TEXT NOT NULL,
    PRIMARY KEY(repo_id, name)
);

-- HEAD tracking per repository
CREATE TABLE pg_git.head (
    repo_id     INTEGER PRIMARY KEY REFERENCES pg_git.repositories(id),
    ref_name    TEXT,                  -- Branch name (NULL if detached)
    commit_hash TEXT                   -- Direct commit (for detached HEAD)
);

-- Staging area for uncommitted changes
CREATE TABLE pg_git.staging (
    repo_id     INTEGER REFERENCES pg_git.repositories(id),
    operation   TEXT NOT NULL,         -- 'INSERT', 'UPDATE', 'DELETE'
    row_hash    TEXT NOT NULL,         -- Hash of the row
    row_data    JSONB,                 -- The actual row data
    old_hash    TEXT,                  -- Previous hash (for UPDATE/DELETE)
    staged_at   TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY(repo_id, row_hash)
);
```

### Object Formats

#### Blob Object
```json
{
  "type": "blob",
  "table": "public.users",
  "pk": {"id": 1},
  "data": {"id": 1, "name": "Alice", "email": "alice@example.com"}
}
```

#### Tree Object
```json
{
  "type": "tree",
  "table": "public.users",
  "row_count": 3,
  "blobs": [
    {"pk": {"id": 1}, "hash": "abc123..."},
    {"pk": {"id": 2}, "hash": "def456..."},
    {"pk": {"id": 3}, "hash": "789ghi..."}
  ]
}
```

#### Commit Object
```json
{
  "type": "commit",
  "tree": "sha256-of-tree",
  "parent": "sha256-of-parent-commit",
  "author": "user@example.com",
  "timestamp": "2024-01-15T10:30:00Z",
  "message": "Add new user Alice"
}
```

## API Functions

### Repository Management

```sql
-- Initialize version control on a table
SELECT pg_git.init(
    'public.users',           -- table name
    ARRAY['id'],              -- primary key columns
    ARRAY['name', 'email']    -- columns to track (NULL = all)
);

-- Remove version control from a table
SELECT pg_git.uninit('public.users');

-- List versioned tables
SELECT * FROM pg_git.list_repos();
```

### Staging Changes

```sql
-- Stage all changes in a table
SELECT pg_git.add('public.users');

-- Stage specific rows
SELECT pg_git.add('public.users', 'id = 1');

-- Unstage changes
SELECT pg_git.reset('public.users');

-- View staged changes
SELECT * FROM pg_git.status('public.users');
```

### Commits

```sql
-- Create a commit
SELECT pg_git.commit('Add new users', 'author@example.com');

-- Create a commit for specific table
SELECT pg_git.commit(
    'public.users',
    'Update user emails',
    'author@example.com'
);

-- View commit history
SELECT * FROM pg_git.log('public.users');
SELECT * FROM pg_git.log('public.users', 10);  -- limit to 10

-- Show commit details
SELECT * FROM pg_git.show('abc123...');
```

### Branches

```sql
-- Create a branch
SELECT pg_git.branch('feature-x');
SELECT pg_git.branch('feature-x', 'abc123');  -- from specific commit

-- List branches
SELECT * FROM pg_git.branches('public.users');

-- Switch branch
SELECT pg_git.checkout('public.users', 'feature-x');

-- Delete branch
SELECT pg_git.branch_delete('feature-x');
```

### Checkout and Restore

```sql
-- Checkout a branch (updates table data)
SELECT pg_git.checkout('public.users', 'main');

-- Checkout a specific commit (detached HEAD)
SELECT pg_git.checkout('public.users', 'abc123...');

-- Restore specific rows from a commit
SELECT pg_git.restore('public.users', 'abc123', 'id = 1');
```

### Diff and Compare

```sql
-- Diff between commits
SELECT * FROM pg_git.diff('public.users', 'abc123', 'def456');

-- Diff between branches
SELECT * FROM pg_git.diff('public.users', 'main', 'feature-x');

-- Diff working copy vs HEAD
SELECT * FROM pg_git.diff('public.users');

-- Diff output format:
-- | operation | pk      | old_value           | new_value           |
-- |-----------|---------|---------------------|---------------------|
-- | UPDATE    | {"id":1}| {"name": "Bob"}     | {"name": "Robert"}  |
-- | INSERT    | {"id":4}| NULL                | {"name": "Dave"}    |
-- | DELETE    | {"id":2}| {"name": "Carol"}   | NULL                |
```

### Merge

```sql
-- Merge branch into current branch
SELECT pg_git.merge('public.users', 'feature-x');

-- Merge with strategy
SELECT pg_git.merge('public.users', 'feature-x', 'ours');    -- keep ours on conflict
SELECT pg_git.merge('public.users', 'feature-x', 'theirs');  -- keep theirs on conflict

-- View merge conflicts (if any)
SELECT * FROM pg_git.conflicts('public.users');

-- Resolve conflicts
SELECT pg_git.resolve('public.users', '{"id": 1}', 'ours');
SELECT pg_git.resolve('public.users', '{"id": 1}', 'theirs');
SELECT pg_git.resolve('public.users', '{"id": 1}', '{"custom": "value"}');
```

### Tags

```sql
-- Create a tag
SELECT pg_git.tag('v1.0', 'Release version 1.0');
SELECT pg_git.tag('v1.0', 'Release version 1.0', 'abc123');  -- at specific commit

-- List tags
SELECT * FROM pg_git.tags('public.users');

-- Delete tag
SELECT pg_git.tag_delete('v1.0');
```

### Utility Functions

```sql
-- Get current HEAD
SELECT pg_git.head('public.users');

-- Get object by hash
SELECT * FROM pg_git.cat_object('abc123...');

-- Garbage collection (remove unreferenced objects)
SELECT pg_git.gc();

-- Repository statistics
SELECT * FROM pg_git.stats('public.users');
```

## Change Tracking

pg_git uses triggers to track changes to versioned tables:

```sql
-- Automatically created when pg_git.init() is called
CREATE TRIGGER pg_git_track_changes
    AFTER INSERT OR UPDATE OR DELETE ON public.users
    FOR EACH ROW EXECUTE FUNCTION pg_git.track_change();
```

The trigger records changes to a shadow table for efficient diffing:

```sql
CREATE TABLE pg_git.changes_<repo_id> (
    id          BIGSERIAL PRIMARY KEY,
    operation   TEXT NOT NULL,
    pk_values   JSONB NOT NULL,
    old_data    JSONB,
    new_data    JSONB,
    changed_at  TIMESTAMPTZ DEFAULT now()
);
```

## Deduplication

Content-addressable storage enables automatic deduplication:

```
Table: users (1000 rows)
Commit 1: 1000 blobs stored
Commit 2: Only 5 rows changed → Only 5 new blobs stored
Commit 3: Only 2 rows changed → Only 2 new blobs stored

Total storage: 1007 blobs (not 3000)
```

## Example Workflow

```sql
-- 1. Initialize version control
SELECT pg_git.init('public.products', ARRAY['id']);

-- 2. Create initial commit
SELECT pg_git.add('public.products');
SELECT pg_git.commit('Initial product catalog');

-- 3. Create a feature branch
SELECT pg_git.branch('price-update');
SELECT pg_git.checkout('public.products', 'price-update');

-- 4. Make changes to the table
UPDATE public.products SET price = price * 1.1 WHERE category = 'electronics';

-- 5. Stage and commit
SELECT pg_git.add('public.products');
SELECT pg_git.commit('Increase electronics prices by 10%');

-- 6. View changes
SELECT * FROM pg_git.diff('public.products', 'main', 'price-update');

-- 7. Switch back to main and merge
SELECT pg_git.checkout('public.products', 'main');
SELECT pg_git.merge('public.products', 'price-update');

-- 8. View history
SELECT * FROM pg_git.log('public.products');
```

## Advanced Features

### Hooks

```sql
-- Pre-commit hook
CREATE FUNCTION my_pre_commit_hook(repo_id INT, message TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    -- Custom validation logic
    IF message IS NULL OR message = '' THEN
        RAISE EXCEPTION 'Commit message required';
    END IF;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

SELECT pg_git.set_hook('public.users', 'pre-commit', 'my_pre_commit_hook');
```

### Clone/Push/Pull (Remote Repositories)

```sql
-- Configure remote
SELECT pg_git.remote_add('origin', 'postgresql://remote-host/db');

-- Push to remote
SELECT pg_git.push('public.users', 'origin', 'main');

-- Pull from remote
SELECT pg_git.pull('public.users', 'origin', 'main');

-- Clone from remote
SELECT pg_git.clone('origin', 'public.users');
```

### Time Travel Queries

```sql
-- Query table as of a specific commit
SELECT * FROM pg_git.at('public.users', 'abc123...');

-- Query table as of a specific time
SELECT * FROM pg_git.at('public.users', '2024-01-15 10:30:00');
```

## Performance Considerations

1. **Compression**: All objects are compressed using pglz
2. **Indexing**: Hash-based lookups on objects table
3. **Batch Operations**: Add/commit operations batch multiple rows
4. **Lazy Loading**: Tree objects reference blobs by hash, loaded on demand
5. **Partial Clones**: Only fetch objects needed for requested commits

## Limitations

1. **Large Binary Data**: Not optimized for BYTEA columns with large data
2. **Schema Changes**: ALTER TABLE operations require special handling
3. **Foreign Keys**: Cross-table referential integrity during checkout
4. **Concurrent Writes**: Branch checkout locks the table

## Comparison with Alternatives

| Feature | pg_git | Temporal Tables | pgaudit |
|---------|--------|-----------------|---------|
| Branching | Yes | No | No |
| Content Deduplication | Yes | No | No |
| Diff/Merge | Yes | Limited | No |
| Point-in-time Queries | Yes | Yes | No |
| Space Efficient | Yes | No | Yes |
| Standard SQL | Yes | Yes | N/A |

## Future Enhancements

1. **Sparse Checkout**: Only track subset of rows
2. **Submodules**: Reference other versioned tables
3. **Blame**: Track which commit changed each row
4. **Bisect**: Binary search to find when a bug was introduced
5. **Stash**: Temporarily save uncommitted changes
6. **Rebase**: Reapply commits on top of another branch
