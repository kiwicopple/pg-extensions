# Zanzibar PostgreSQL Extension Plan

## Overview

Create a Zanzibar-compatible PostgreSQL extension (`pg_zanzibar`) that enables relationship-based access control (ReBAC) directly in PostgreSQL. The extension will provide tables for storing relationship tuples and functions that work inside RLS (Row-Level Security) policies.

## Background: What is Zanzibar?

Google Zanzibar is a relationship-based access control system that models permissions as relationships between objects and users. Key concepts:

- **Tuples**: `(object_type:object_id, relation, subject_type:subject_id)`
  - Example: `(document:readme, viewer, user:alice)` means "Alice is a viewer of document readme"
- **Relations**: Named relationships like `owner`, `editor`, `viewer`, `member`
- **Usersets**: Groups of subjects (e.g., all members of a team)
- **Computed Relations**: Relations derived from other relations via inheritance rules

## Extension Structure

```
pg_zanzibar/
├── pg_zanzibar.control
├── pg_zanzibar--0.0.1.sql
└── README.md
```

## Schema Design

All tables and functions will live in a dedicated `zanzibar` schema for clean namespacing:

```sql
CREATE SCHEMA IF NOT EXISTS zanzibar;
```

### Core Tables

#### 1. `zanzibar.tuples` - Relationship Storage
```sql
CREATE TABLE zanzibar.tuples (
    id BIGSERIAL PRIMARY KEY,

    -- Object (resource being accessed)
    object_type TEXT NOT NULL,
    object_id TEXT NOT NULL,

    -- Relation (permission/relationship type)
    relation TEXT NOT NULL,

    -- Subject (user or userset)
    subject_type TEXT NOT NULL,
    subject_id TEXT NOT NULL,
    subject_relation TEXT,  -- For userset references (e.g., group:eng#member)

    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),

    -- Constraints
    UNIQUE (object_type, object_id, relation, subject_type, subject_id, subject_relation)
);
```

#### 2. `zanzibar.relation_configs` - Relation Inheritance Rules
```sql
CREATE TABLE zanzibar.relation_configs (
    id BIGSERIAL PRIMARY KEY,

    -- The object type this config applies to
    object_type TEXT NOT NULL,

    -- The relation being defined
    relation TEXT NOT NULL,

    -- Relations that imply this relation (inheritance)
    -- e.g., 'owner' implies 'editor', 'editor' implies 'viewer'
    implied_by TEXT[],

    -- Whether this relation can reference usersets from other object types
    -- e.g., viewer can be "group:engineering#member"
    allows_userset_subjects BOOLEAN DEFAULT TRUE,

    UNIQUE (object_type, relation)
);
```

### Indexes for Performance

```sql
-- Fast lookups by object
CREATE INDEX idx_tuples_object ON zanzibar.tuples (object_type, object_id);

-- Fast lookups by subject (for reverse queries)
CREATE INDEX idx_tuples_subject ON zanzibar.tuples (subject_type, subject_id);

-- Fast relation checks
CREATE INDEX idx_tuples_check ON zanzibar.tuples (object_type, object_id, relation, subject_type, subject_id);

-- Fast userset expansion
CREATE INDEX idx_tuples_userset ON zanzibar.tuples (subject_type, subject_id, subject_relation)
    WHERE subject_relation IS NOT NULL;
```

## Core Functions

### 1. Check Functions (for RLS policies)

#### `zanzibar.check` - Primary Permission Check
```sql
-- Check if a subject has a specific relation to an object
-- Returns TRUE if the relationship exists (directly or through inheritance)
CREATE FUNCTION zanzibar.check(
    p_object_type TEXT,
    p_object_id TEXT,
    p_relation TEXT,
    p_subject_type TEXT,
    p_subject_id TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER  -- Critical for RLS
STABLE            -- Can be used in indexes
AS $$ ... $$;
```

#### `zanzibar.check_any` - Check Multiple Relations
```sql
-- Check if subject has ANY of the specified relations
CREATE FUNCTION zanzibar.check_any(
    p_object_type TEXT,
    p_object_id TEXT,
    p_relations TEXT[],
    p_subject_type TEXT,
    p_subject_id TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$ ... $$;
```

#### `zanzibar.check_with_context` - Check Using Session Context
```sql
-- Check using current session's user context (set via set_config)
-- Useful for RLS policies where you want to use session-level auth
CREATE FUNCTION zanzibar.check_with_context(
    p_object_type TEXT,
    p_object_id TEXT,
    p_relation TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$ ... $$;
```

### 2. Tuple Management Functions

#### `zanzibar.add_tuple` - Add Relationship
```sql
CREATE FUNCTION zanzibar.add_tuple(
    p_object_type TEXT,
    p_object_id TEXT,
    p_relation TEXT,
    p_subject_type TEXT,
    p_subject_id TEXT,
    p_subject_relation TEXT DEFAULT NULL
) RETURNS BIGINT  -- Returns tuple ID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$ ... $$;
```

#### `zanzibar.remove_tuple` - Remove Relationship
```sql
CREATE FUNCTION zanzibar.remove_tuple(
    p_object_type TEXT,
    p_object_id TEXT,
    p_relation TEXT,
    p_subject_type TEXT,
    p_subject_id TEXT,
    p_subject_relation TEXT DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$ ... $$;
```

### 3. Query Functions

#### `zanzibar.list_objects` - List Accessible Objects
```sql
-- List all objects of a type that a subject can access with a given relation
CREATE FUNCTION zanzibar.list_objects(
    p_object_type TEXT,
    p_relation TEXT,
    p_subject_type TEXT,
    p_subject_id TEXT
) RETURNS TABLE (object_id TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$ ... $$;
```

#### `zanzibar.list_subjects` - List Subjects with Access
```sql
-- List all subjects that have a given relation to an object
CREATE FUNCTION zanzibar.list_subjects(
    p_object_type TEXT,
    p_object_id TEXT,
    p_relation TEXT
) RETURNS TABLE (subject_type TEXT, subject_id TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$ ... $$;
```

#### `zanzibar.list_object_ids` - RLS-Optimized List (⭐ Recommended for RLS)
```sql
-- Returns array of object IDs the current user can access
-- Uses auth.uid() or session context internally - no parameters needed for user
-- Designed for fast RLS policies: id = ANY((SELECT zanzibar.list_object_ids(...)))
CREATE FUNCTION zanzibar.list_object_ids(
    p_object_type TEXT,
    p_relation TEXT
) RETURNS TEXT[]
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$ ... $$;
```

### 4. Utility Functions

#### `zanzibar.set_user_context` - Set Session User
```sql
-- Set the current user context for RLS checks
CREATE FUNCTION zanzibar.set_user_context(
    p_subject_type TEXT,
    p_subject_id TEXT
) RETURNS VOID
LANGUAGE plpgsql
AS $$ ... $$;
```

#### `zanzibar.get_user_context` - Get Session User
```sql
-- Get the current user context
CREATE FUNCTION zanzibar.get_user_context()
RETURNS TABLE (subject_type TEXT, subject_id TEXT)
LANGUAGE plpgsql
STABLE
AS $$ ... $$;
```

## RLS Integration Examples

### ⚠️ CRITICAL: RLS Performance Considerations

**The Problem**: When using a per-row check function in RLS policies, the function executes **for every row** in the table:

```sql
-- ❌ SLOW: Function runs once PER ROW (N function calls for N rows)
CREATE POLICY documents_select ON documents
    FOR SELECT
    USING (
        zanzibar.check('document', id::TEXT, 'viewer', 'user', auth.uid()::TEXT)
    );
```

If your table has 1 million rows, that's 1 million function calls—even with indexes, this is slow.

**The Solution**: Return a list of accessible IDs once, then compare:

```sql
-- ✅ FAST: Function runs ONCE, returns all valid IDs
CREATE POLICY documents_select ON documents
    FOR SELECT
    USING (
        id::TEXT = ANY((SELECT zanzibar.list_object_ids('document', 'viewer')))
    );
```

**Key Points**:
1. Use `zanzibar.list_object_ids()` which returns all object IDs the current user can access
2. The `(SELECT ...)` wrapper is **critical** for performance—it forces the subquery to evaluate once
3. The function should use `auth.uid()` internally (Supabase) or session context, not accept it as a parameter

Credit: [Gary Austin's custom-properties repo](https://github.com/GaryAustin1/custom-properties)

### Optimized Functions for RLS

#### `zanzibar.list_object_ids` - Fast RLS Helper
```sql
-- Returns all object IDs the current user can access for a given relation
-- Uses auth.uid() internally for Supabase compatibility
CREATE FUNCTION zanzibar.list_object_ids(
    p_object_type TEXT,
    p_relation TEXT
) RETURNS TEXT[]
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_user_id TEXT;
    v_result TEXT[];
BEGIN
    -- Get current user from Supabase auth or session context
    v_user_id := COALESCE(
        auth.uid()::TEXT,
        current_setting('zanzibar.subject_id', true)
    );

    -- Return array of all accessible object IDs
    SELECT ARRAY_AGG(DISTINCT object_id) INTO v_result
    FROM zanzibar.tuples
    WHERE object_type = p_object_type
      AND relation = p_relation
      AND subject_type = 'user'
      AND subject_id = v_user_id;

    RETURN COALESCE(v_result, ARRAY[]::TEXT[]);
END;
$$;
```

### Example 1: Optimized Document Access (Recommended)
```sql
-- Documents table
CREATE TABLE documents (
    id UUID PRIMARY KEY,
    title TEXT,
    content TEXT
);

-- RLS Policy using Zanzibar (FAST - function runs once)
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY documents_select ON documents
    FOR SELECT
    USING (
        id::TEXT = ANY((SELECT zanzibar.list_object_ids('document', 'viewer')))
    );

CREATE POLICY documents_update ON documents
    FOR UPDATE
    USING (
        id::TEXT = ANY((SELECT zanzibar.list_object_ids('document', 'editor')))
    );

CREATE POLICY documents_delete ON documents
    FOR DELETE
    USING (
        id::TEXT = ANY((SELECT zanzibar.list_object_ids('document', 'owner')))
    );
```

### Example 2: Per-Row Check (Use Sparingly)
```sql
-- ⚠️ Only use this pattern when:
-- 1. Tables have < 1000 rows, OR
-- 2. Query has a WHERE clause that limits rows first, OR
-- 3. Checking a single specific row (e.g., UPDATE/DELETE by ID)

CREATE POLICY documents_select ON documents
    FOR SELECT
    USING (
        zanzibar.check_with_context('document', id::TEXT, 'viewer')
    );
```

### Example 3: Single-Row Operations (Per-Row OK)
```sql
-- For UPDATE/DELETE by specific ID, per-row check is fine
-- because only one row is being checked

CREATE POLICY documents_update ON documents
    FOR UPDATE
    USING (
        zanzibar.check(
            'document',
            id::TEXT,
            'editor',
            'user',
            auth.uid()::TEXT
        )
    );

-- The slow path only happens if someone does:
--   UPDATE documents SET title = 'x';  -- checks ALL rows
-- But this is fast:
--   UPDATE documents SET title = 'x' WHERE id = '123';  -- checks 1 row
```

## Implementation Phases

### Phase 1: Core Foundation
1. Create extension control file
2. Create `zanzibar` schema and `zanzibar.tuples` table
3. Implement `zanzibar.add_tuple` and `zanzibar.remove_tuple`
4. Implement basic `zanzibar.check` (direct relationships only)

### Phase 2: Inheritance Support
1. Create `zanzibar.relation_configs` table
2. Enhance `zanzibar.check` to support relation inheritance
3. Implement userset expansion (group membership)

### Phase 3: Query Functions
1. Implement `zanzibar.list_objects`
2. Implement `zanzibar.list_subjects`
3. Implement `zanzibar.check_any`
4. Implement `zanzibar.list_object_ids` (RLS-optimized, returns array)

### Phase 4: RLS Integration
1. Implement `zanzibar.set_user_context` and `zanzibar.get_user_context`
2. Implement `zanzibar.check_with_context`
3. Document RLS performance patterns (per-row vs list-based)
4. Provide example policies using optimized `list_object_ids` pattern

### Phase 5: Performance & Polish
1. Add comprehensive indexes
2. Add caching considerations (where applicable)
3. Write documentation with examples
4. Add sample RLS policies

## Key Design Decisions

### 1. SECURITY DEFINER Functions
All check functions must use `SECURITY DEFINER` to:
- Allow RLS policies to query the `zanzibar.tuples` table
- Prevent users from directly modifying authorization data
- Work correctly when invoked from RLS policy context

### 2. STABLE Functions
Check functions should be marked `STABLE` to:
- Allow PostgreSQL to cache results within a statement
- Enable use in index expressions if needed
- Improve performance in RLS contexts

### 3. Session Context via set_config/current_setting
Use PostgreSQL's session variables for user context:
```sql
-- Setting context
SELECT set_config('zanzibar.subject_type', 'user', false);
SELECT set_config('zanzibar.subject_id', '123', false);

-- Reading context
SELECT current_setting('zanzibar.subject_type', true);
SELECT current_setting('zanzibar.subject_id', true);
```

### 4. Recursive Userset Expansion
Support group-of-groups patterns:
- `(team:backend, member, user:alice)`
- `(org:acme, member, team:backend#member)` - All backend team members are org members
- Limit recursion depth to prevent infinite loops (default: 10)

### 5. No External Dependencies
Like other extensions in this repo:
- Pure PL/pgSQL implementation
- No pgcrypto or other extension requirements
- Maximum portability across PostgreSQL environments

## Distributed Deployment & Consistency (Future)

### The Problem

Google's Zanzibar uses "zookies" (Zanzibar cookies) - opaque tokens that encode a snapshot timestamp to ensure causal consistency. This matters in distributed deployments:

1. User writes a permission tuple to the primary
2. User immediately checks permission (request may hit a replica)
3. Replica hasn't received the write yet → check incorrectly fails

### Options

| Approach | Description | Tradeoff |
|----------|-------------|----------|
| **Single-primary only** | All reads/writes go to primary | Simple, works for most use cases. No consistency issues. |
| **Zookie support (LSN-based)** | Use PostgreSQL's WAL LSN as consistency token | Enables read replicas while maintaining consistency |
| **Require primary for checks** | Force all `check()` calls to primary | Consistent but higher primary load |

### Recommended Approach

**Phase 1 (v0.0.1):** Single-primary assumption. Document the limitation.

**Phase 2 (Future):** Add optional zookie support using PostgreSQL's LSN:

```sql
-- Write returns a zookie (LSN-based token)
SELECT * FROM zanzibar.add_tuple_with_token(...);
-- Returns: (tuple_id, zookie)

-- Check with zookie ensures consistency
SELECT zanzibar.check(
    'document', '123', 'viewer', 'user', 'alice',
    p_zookie := '0/1A2B3C4D'  -- Optional: ensures read-your-writes
);
```

#### Implementation Details

```sql
-- Get current WAL position (for writes)
SELECT pg_current_wal_lsn();  -- Returns something like '0/1A2B3C4D'

-- On replica: wait for LSN before reading (or return stale warning)
SELECT pg_last_wal_replay_lsn();  -- What the replica has applied

-- Check if replica is caught up to a specific LSN
SELECT pg_last_wal_replay_lsn() >= '0/1A2B3C4D'::pg_lsn;
```

#### Zookie Functions (Future)

```sql
-- Generate zookie after write
CREATE FUNCTION zanzibar.current_zookie() RETURNS TEXT
LANGUAGE SQL STABLE AS $$
    SELECT pg_current_wal_lsn()::TEXT;
$$;

-- Check with optional zookie
CREATE FUNCTION zanzibar.check(
    p_object_type TEXT,
    p_object_id TEXT,
    p_relation TEXT,
    p_subject_type TEXT,
    p_subject_id TEXT,
    p_zookie TEXT DEFAULT NULL  -- Optional consistency token
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_is_caught_up BOOLEAN;
BEGIN
    -- If zookie provided and we're on a replica, check if caught up
    IF p_zookie IS NOT NULL AND pg_is_in_recovery() THEN
        SELECT pg_last_wal_replay_lsn() >= p_zookie::pg_lsn INTO v_is_caught_up;
        IF NOT v_is_caught_up THEN
            -- Option 1: Raise warning and continue (eventual consistency)
            -- Option 2: Raise exception (strict consistency)
            RAISE WARNING 'Replica not yet caught up to zookie %', p_zookie;
        END IF;
    END IF;

    -- Perform the actual check...
    RETURN /* ... */;
END;
$$;
```

### Limitations to Document

1. **v0.0.1**: Designed for single-primary PostgreSQL deployments
2. **Read replicas**: May see stale permissions briefly (replication lag)
3. **Multi-region**: Not suitable for globally distributed authorization (use SpiceDB/OpenFGA instead)

## Configuration Constants

```sql
-- Maximum recursion depth for userset expansion
CREATE FUNCTION zanzibar.max_depth() RETURNS INT
LANGUAGE SQL IMMUTABLE AS $$ SELECT 10 $$;
```

## Success Criteria

1. ✅ Extension installs cleanly via `CREATE EXTENSION pg_zanzibar`
2. ✅ All check functions work correctly inside RLS policies
3. ✅ Supports direct relationships and userset expansion
4. ✅ Supports relation inheritance (owner → editor → viewer)
5. ✅ Provides clear documentation with RLS examples
6. ✅ Compatible with Supabase (non-superuser, no external deps)

## File Deliverables

1. `/pg_zanzibar/pg_zanzibar.control` - Extension metadata
2. `/pg_zanzibar/pg_zanzibar--0.0.1.sql` - Complete extension SQL
3. `/pg_zanzibar/README.md` - Documentation with examples
4. Update root `Makefile` to include pg_zanzibar
