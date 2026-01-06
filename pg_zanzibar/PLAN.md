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

### Core Tables

#### 1. `zanzibar_tuples` - Relationship Storage
```sql
CREATE TABLE zanzibar_tuples (
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

#### 2. `zanzibar_relation_configs` - Relation Inheritance Rules
```sql
CREATE TABLE zanzibar_relation_configs (
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
CREATE INDEX idx_tuples_object ON zanzibar_tuples (object_type, object_id);

-- Fast lookups by subject (for reverse queries)
CREATE INDEX idx_tuples_subject ON zanzibar_tuples (subject_type, subject_id);

-- Fast relation checks
CREATE INDEX idx_tuples_check ON zanzibar_tuples (object_type, object_id, relation, subject_type, subject_id);

-- Fast userset expansion
CREATE INDEX idx_tuples_userset ON zanzibar_tuples (subject_type, subject_id, subject_relation)
    WHERE subject_relation IS NOT NULL;
```

## Core Functions

### 1. Check Functions (for RLS policies)

#### `zanzibar_check` - Primary Permission Check
```sql
-- Check if a subject has a specific relation to an object
-- Returns TRUE if the relationship exists (directly or through inheritance)
CREATE FUNCTION zanzibar_check(
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

#### `zanzibar_check_any` - Check Multiple Relations
```sql
-- Check if subject has ANY of the specified relations
CREATE FUNCTION zanzibar_check_any(
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

#### `zanzibar_check_with_context` - Check Using Session Context
```sql
-- Check using current session's user context (set via set_config)
-- Useful for RLS policies where you want to use session-level auth
CREATE FUNCTION zanzibar_check_with_context(
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

#### `zanzibar_add_tuple` - Add Relationship
```sql
CREATE FUNCTION zanzibar_add_tuple(
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

#### `zanzibar_remove_tuple` - Remove Relationship
```sql
CREATE FUNCTION zanzibar_remove_tuple(
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

#### `zanzibar_list_objects` - List Accessible Objects
```sql
-- List all objects of a type that a subject can access with a given relation
CREATE FUNCTION zanzibar_list_objects(
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

#### `zanzibar_list_subjects` - List Subjects with Access
```sql
-- List all subjects that have a given relation to an object
CREATE FUNCTION zanzibar_list_subjects(
    p_object_type TEXT,
    p_object_id TEXT,
    p_relation TEXT
) RETURNS TABLE (subject_type TEXT, subject_id TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$ ... $$;
```

### 4. Utility Functions

#### `zanzibar_set_user_context` - Set Session User
```sql
-- Set the current user context for RLS checks
CREATE FUNCTION zanzibar_set_user_context(
    p_subject_type TEXT,
    p_subject_id TEXT
) RETURNS VOID
LANGUAGE plpgsql
AS $$ ... $$;
```

#### `zanzibar_get_user_context` - Get Session User
```sql
-- Get the current user context
CREATE FUNCTION zanzibar_get_user_context()
RETURNS TABLE (subject_type TEXT, subject_id TEXT)
LANGUAGE plpgsql
STABLE
AS $$ ... $$;
```

## RLS Integration Examples

### Example 1: Simple Document Access
```sql
-- Documents table
CREATE TABLE documents (
    id UUID PRIMARY KEY,
    title TEXT,
    content TEXT
);

-- RLS Policy using Zanzibar
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY documents_select ON documents
    FOR SELECT
    USING (
        zanzibar_check_with_context('document', id::TEXT, 'viewer')
    );

CREATE POLICY documents_update ON documents
    FOR UPDATE
    USING (
        zanzibar_check_with_context('document', id::TEXT, 'editor')
    );

CREATE POLICY documents_delete ON documents
    FOR DELETE
    USING (
        zanzibar_check_with_context('document', id::TEXT, 'owner')
    );
```

### Example 2: Using auth.uid() (Supabase Compatible)
```sql
-- For Supabase projects, integrate with auth.uid()
CREATE POLICY documents_viewer ON documents
    FOR SELECT
    USING (
        zanzibar_check(
            'document',
            id::TEXT,
            'viewer',
            'user',
            auth.uid()::TEXT
        )
    );
```

## Implementation Phases

### Phase 1: Core Foundation
1. Create extension control file
2. Create `zanzibar_tuples` table
3. Implement `zanzibar_add_tuple` and `zanzibar_remove_tuple`
4. Implement basic `zanzibar_check` (direct relationships only)

### Phase 2: Inheritance Support
1. Create `zanzibar_relation_configs` table
2. Enhance `zanzibar_check` to support relation inheritance
3. Implement userset expansion (group membership)

### Phase 3: Query Functions
1. Implement `zanzibar_list_objects`
2. Implement `zanzibar_list_subjects`
3. Implement `zanzibar_check_any`

### Phase 4: RLS Integration
1. Implement `zanzibar_set_user_context` and `zanzibar_get_user_context`
2. Implement `zanzibar_check_with_context`
3. Add helper functions for common patterns

### Phase 5: Performance & Polish
1. Add comprehensive indexes
2. Add caching considerations (where applicable)
3. Write documentation with examples
4. Add sample RLS policies

## Key Design Decisions

### 1. SECURITY DEFINER Functions
All check functions must use `SECURITY DEFINER` to:
- Allow RLS policies to query the zanzibar_tuples table
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

## Configuration Constants

```sql
-- Maximum recursion depth for userset expansion
CREATE FUNCTION zanzibar_max_depth() RETURNS INT
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
