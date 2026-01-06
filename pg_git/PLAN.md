# pg_git Development Plan

## Overview

This document outlines the development roadmap for pg_git, a PostgreSQL extension that brings git-like version control to database tables.

---

## Phase 1: Core Extension (v0.0.1) ✅ COMPLETE

The foundational PostgreSQL extension with basic git-like operations.

### Completed Features

- [x] Schema and table structure for objects, refs, repositories
- [x] Content-addressable storage (SHA-256 hashing)
- [x] Repository initialization (`pg_git.init()`)
- [x] Change tracking via triggers
- [x] Staging area for uncommitted changes
- [x] Commit creation with parent chain
- [x] Branch operations (create, list, delete, switch)
- [x] Tag operations (create, list, delete)
- [x] Checkout (restore table to specific commit/branch)
- [x] Diff between commits/branches
- [x] Merge with conflict detection
- [x] Commit history (log)
- [x] Basic garbage collection

---

## Phase 2: Remote Operations (v0.1.0)

Enable syncing pg_git repositories between PostgreSQL instances.

### Goals

- Push/pull commits between databases
- Clone repositories from remote instances
- Support for multiple remotes

### Implementation

```sql
-- Configure a remote PostgreSQL instance
SELECT pg_git.remote_add(
    'origin',
    'postgresql://user:pass@remote-host:5432/mydb'
);

-- Push commits to remote
SELECT pg_git.push('public.users', 'origin', 'main');

-- Pull commits from remote
SELECT pg_git.pull('public.users', 'origin', 'main');

-- Clone a repository from remote
SELECT pg_git.clone(
    'origin',
    'remote_schema.users',  -- source table on remote
    'public.users'          -- local table name
);

-- List remotes
SELECT * FROM pg_git.remotes('public.users');
```

### Technical Approach

1. Use `postgres_fdw` or `dblink` for cross-database communication
2. Transfer objects using COPY protocol for efficiency
3. Negotiate common ancestors to minimize data transfer
4. Handle authentication via connection strings or pg_service.conf

### New Tables

```sql
CREATE TABLE pg_git.remotes (
    repo_id     INTEGER REFERENCES pg_git.repositories(id),
    name        TEXT NOT NULL,
    url         TEXT NOT NULL,
    last_fetch  TIMESTAMPTZ,
    PRIMARY KEY(repo_id, name)
);

CREATE TABLE pg_git.remote_refs (
    repo_id     INTEGER,
    remote_name TEXT,
    ref_name    TEXT,
    commit_hash TEXT,
    FOREIGN KEY (repo_id, remote_name) REFERENCES pg_git.remotes(repo_id, name)
);
```

---

## Phase 3: CLI Tool (v0.2.0)

A command-line interface for easier interaction and Git interoperability.

### Why a CLI?

1. **Familiar UX**: Git users expect command-line workflows
2. **Scripting**: Enable CI/CD integration
3. **Git Bridge**: Import/export between Git and pg_git
4. **Bulk Operations**: Efficient handling of large datasets

### Installation

```bash
# Install via package manager (future)
brew install pg_git
apt install pg_git-cli

# Or via cargo (Rust-based CLI)
cargo install pg_git

# Or download binary
curl -L https://github.com/pg_git/releases/latest/pg_git-cli -o pg_git
chmod +x pg_git
```

### CLI Commands

```bash
# Configuration
pg_git config set database.url "postgresql://localhost/mydb"
pg_git config set user.name "Alice"
pg_git config set user.email "alice@example.com"

# Repository operations
pg_git init public.users --pk id
pg_git status public.users
pg_git log public.users
pg_git show <commit-hash>

# Commits
pg_git commit public.users -m "Update user records"
pg_git commit --all -m "Commit all tracked tables"

# Branches
pg_git branch public.users feature-x
pg_git checkout public.users feature-x
pg_git merge public.users feature-x

# Remotes
pg_git remote add origin postgresql://remote/db
pg_git push origin main
pg_git pull origin main
pg_git fetch origin

# Git interop (see Phase 4)
pg_git git-import ./my-repo public.git_files
pg_git git-export public.git_files ./exported-repo
```

### CLI Architecture

```
┌─────────────────────────────────────────────────────┐
│                    pg_git CLI                       │
├─────────────────────────────────────────────────────┤
│  Commands: init, commit, branch, checkout, merge    │
│            push, pull, clone, git-import, git-export│
├─────────────────────────────────────────────────────┤
│  Connection Layer (libpq / tokio-postgres)          │
├─────────────────────────────────────────────────────┤
│  PostgreSQL with pg_git extension                   │
└─────────────────────────────────────────────────────┘
```

### Technology Choice

**Recommended: Rust**
- Fast startup time
- Single binary distribution
- Excellent PostgreSQL support (tokio-postgres)
- Cross-platform compilation

**Alternative: Go**
- Also good for CLI tools
- pgx library for PostgreSQL

---

## Phase 4: Git Interoperability (v0.3.0)

Enable importing existing Git repositories and exporting pg_git data as Git repos.

### Use Cases

1. **Version control for config files stored in DB**: Import config repo, query with SQL
2. **Audit trail**: Export table history as Git repo for compliance
3. **Code review for data changes**: Use GitHub/GitLab PRs for data changes
4. **Backup**: Git-compatible backup format

### Approach 1: File-to-Row Mapping

Store Git repository contents in a PostgreSQL table:

```sql
-- Table structure for storing Git repo contents
CREATE TABLE git_files (
    id          SERIAL PRIMARY KEY,
    path        TEXT NOT NULL,           -- 'src/main.rs'
    content     TEXT,                    -- File contents (NULL for directories)
    mode        TEXT DEFAULT '100644',   -- Git file mode
    is_binary   BOOLEAN DEFAULT FALSE,
    size        INTEGER,
    UNIQUE(path)
);

-- Import a Git repo into pg_git
-- CLI command: pg_git git-import ./my-repo public.git_files

-- The import process:
-- 1. Walk the Git working tree
-- 2. INSERT each file as a row
-- 3. pg_git.init() on the table
-- 4. pg_git.commit() to create initial commit
-- 5. Optionally import Git history as pg_git commits
```

### Approach 2: Git Remote Helper

Create a Git remote helper that allows Git to push/pull directly to pg_git:

```bash
# Configure Git to use pg_git as a remote
git remote add pg postgresql://localhost/mydb/public.git_files

# Push to pg_git
git push pg main

# Pull from pg_git
git pull pg main
```

**Implementation**: A `git-remote-postgresql` helper script/binary that:
1. Translates Git pack protocol to pg_git SQL calls
2. Maps Git objects to pg_git objects
3. Handles refs synchronization

```bash
#!/bin/bash
# git-remote-postgresql (simplified concept)
# Git calls this with: git-remote-postgresql <remote> <url>

# Protocol commands Git sends:
# - capabilities
# - list
# - fetch <sha>
# - push <src>:<dst>

case "$1" in
    capabilities)
        echo "fetch"
        echo "push"
        ;;
    list)
        # Query pg_git.refs and return them
        psql -c "SELECT name, commit_hash FROM pg_git.refs WHERE ..."
        ;;
    fetch)
        # Download objects from pg_git
        ;;
    push)
        # Upload objects to pg_git
        ;;
esac
```

### Import Command Design

```bash
# Basic import - latest state only
pg_git git-import ./repo public.files

# Import with full history
pg_git git-import ./repo public.files --history

# Import specific branch
pg_git git-import ./repo public.files --branch feature-x

# Import with path filter
pg_git git-import ./repo public.files --path "src/**/*.rs"

# Dry run
pg_git git-import ./repo public.files --dry-run
```

### Export Command Design

```bash
# Export current state
pg_git git-export public.files ./output-repo

# Export with history
pg_git git-export public.files ./output-repo --history

# Export specific branch
pg_git git-export public.files ./output-repo --branch main

# Export to bare repo
pg_git git-export public.files ./output.git --bare
```

### Import/Export Functions (SQL)

```sql
-- Import Git repo (requires CLI to prepare data)
CREATE OR REPLACE FUNCTION pg_git.import_git_tree(
    p_table TEXT,
    p_tree_data JSONB  -- [{path, content, mode}, ...]
)
RETURNS TEXT;

-- Export to Git-compatible format
CREATE OR REPLACE FUNCTION pg_git.export_git_tree(
    p_table TEXT,
    p_commit TEXT DEFAULT NULL
)
RETURNS TABLE (
    path TEXT,
    content TEXT,
    mode TEXT,
    hash TEXT
);
```

---

## Phase 5: Advanced Features (v0.4.0+)

### Time Travel Queries

```sql
-- Query table as it was at a specific commit
SELECT * FROM pg_git.at('public.users', 'abc123');

-- Query table as it was at a specific time
SELECT * FROM pg_git.at('public.users', '2024-01-15 10:30:00');

-- Query with time travel JOIN
SELECT u.*, o.total
FROM pg_git.at('public.users', 'v1.0') u
JOIN pg_git.at('public.orders', 'v1.0') o ON u.id = o.user_id;
```

### Blame

```sql
-- Show which commit last modified each row
SELECT * FROM pg_git.blame('public.users');

-- Output:
-- | pk_data    | commit_hash | author | timestamp  | message         |
-- |------------|-------------|--------|------------|-----------------|
-- | {"id": 1}  | abc123      | alice  | 2024-01-15 | Add user Alice  |
-- | {"id": 2}  | def456      | bob    | 2024-01-16 | Add user Bob    |
```

### Bisect

```sql
-- Find which commit introduced a bug
SELECT pg_git.bisect_start('public.users', 'abc123', 'def456');
SELECT pg_git.bisect_good();  -- Current commit is good
SELECT pg_git.bisect_bad();   -- Current commit is bad
SELECT pg_git.bisect_result(); -- Returns the culprit commit
```

### Stash

```sql
-- Save uncommitted changes temporarily
SELECT pg_git.stash('public.users', 'WIP: feature work');

-- List stashes
SELECT * FROM pg_git.stash_list('public.users');

-- Apply stash
SELECT pg_git.stash_pop('public.users');
SELECT pg_git.stash_apply('public.users', 'stash@{0}');
```

### Rebase

```sql
-- Rebase current branch onto main
SELECT pg_git.rebase('public.users', 'main');

-- Interactive rebase (via CLI)
pg_git rebase public.users main --interactive
```

### Hooks

```sql
-- Register a pre-commit hook
CREATE FUNCTION my_pre_commit(repo_id INT, message TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    -- Validate commit message format
    IF message !~ '^(feat|fix|docs|refactor):' THEN
        RAISE EXCEPTION 'Commit message must start with type prefix';
    END IF;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

SELECT pg_git.add_hook('public.users', 'pre-commit', 'my_pre_commit');

-- Available hooks:
-- pre-commit, post-commit, pre-merge, post-merge, pre-checkout
```

### Sparse Checkout

```sql
-- Only track rows matching a condition
SELECT pg_git.init('public.orders',
    p_primary_key => ARRAY['id'],
    p_filter => 'status = ''active'''
);
```

### Submodules

```sql
-- Reference another versioned table
SELECT pg_git.submodule_add(
    'public.orders',           -- parent table
    'public.order_items',      -- submodule table
    'items'                    -- submodule name
);
```

---

## Phase 6: Ecosystem & Integrations (v1.0.0)

### Web UI

A web-based interface for browsing pg_git repositories:

- Commit history visualization
- Diff viewer with syntax highlighting
- Branch graph
- Merge request workflow

### GitHub/GitLab Integration

```bash
# Mirror pg_git to GitHub
pg_git mirror setup github https://github.com/org/repo

# Sync on every commit
pg_git mirror sync
```

### CI/CD Integration

```yaml
# GitHub Actions example
- name: Check data changes
  uses: pg_git/action@v1
  with:
    database_url: ${{ secrets.DATABASE_URL }}
    table: public.config

- name: Apply migrations
  run: pg_git checkout public.config ${{ github.sha }}
```

### Language SDKs

```python
# Python SDK
from pg_git import Repository

repo = Repository("postgresql://localhost/db", "public.users")
repo.commit("Update users", author="alice@example.com")

for commit in repo.log(limit=10):
    print(f"{commit.short_hash} {commit.message}")
```

```typescript
// TypeScript SDK
import { PgGit } from 'pg_git';

const repo = new PgGit('public.users', connectionString);
await repo.commit('Update users');

const diff = await repo.diff('main', 'feature-x');
```

---

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                         Applications                              │
├──────────────┬──────────────┬──────────────┬────────────────────┤
│   Web UI     │   CLI Tool   │  Git Remote  │   Language SDKs    │
│              │              │   Helper     │   (Python, TS)     │
├──────────────┴──────────────┴──────────────┴────────────────────┤
│                        HTTP API (optional)                       │
├─────────────────────────────────────────────────────────────────┤
│                     PostgreSQL Connection                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│                     pg_git Extension                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │
│  │  Objects    │  │    Refs     │  │   Functions             │ │
│  │  (CAS)      │  │  (branches) │  │   - init, commit        │ │
│  │             │  │  (tags)     │  │   - branch, checkout    │ │
│  │  - blobs    │  │             │  │   - diff, merge         │ │
│  │  - trees    │  │             │  │   - push, pull          │ │
│  │  - commits  │  │             │  │   - git-import/export   │ │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘ │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                      PostgreSQL Database                         │
│                    (with tracked tables)                         │
└─────────────────────────────────────────────────────────────────┘
```

---

## Timeline Estimate

| Phase | Version | Status |
|-------|---------|--------|
| Phase 1: Core Extension | v0.0.1 | ✅ Complete |
| Phase 2: Remote Operations | v0.1.0 | Planned |
| Phase 3: CLI Tool | v0.2.0 | Planned |
| Phase 4: Git Interop | v0.3.0 | Planned |
| Phase 5: Advanced Features | v0.4.0 | Planned |
| Phase 6: Ecosystem | v1.0.0 | Planned |

---

## Contributing

Areas where contributions are welcome:

1. **Testing**: Unit tests, integration tests, performance benchmarks
2. **Documentation**: Tutorials, examples, API docs
3. **CLI Development**: Rust/Go implementation
4. **Git Remote Helper**: Protocol implementation
5. **Web UI**: React/Vue dashboard
6. **Language SDKs**: Python, TypeScript, Go, Ruby

---

## Open Questions

1. **Large Binary Data**: How to handle BYTEA columns efficiently?
   - Option A: Store externally, keep hash reference
   - Option B: Chunk large blobs
   - Option C: Exclude from versioning by default

2. **Schema Evolution**: How to handle ALTER TABLE?
   - Option A: Fail commits if schema changed
   - Option B: Store schema version in commits
   - Option C: Migration tracking integration

3. **Performance**: How to handle tables with millions of rows?
   - Option A: Incremental tree updates
   - Option B: Chunked trees (like Git packfiles)
   - Option C: Bloom filters for quick lookups

4. **Concurrent Access**: How to handle concurrent commits?
   - Option A: Optimistic locking with retry
   - Option B: Advisory locks during commit
   - Option C: MVCC-style conflict resolution

---

## References

- [s3git](https://github.com/s3git/s3git) - Inspiration for content-addressable approach
- [Git Internals](https://git-scm.com/book/en/v2/Git-Internals-Git-Objects) - Object model reference
- [Dolt](https://github.com/dolthub/dolt) - SQL database with Git semantics (different approach)
- [Git Remote Helpers](https://git-scm.com/docs/gitremote-helpers) - Protocol for custom remotes
