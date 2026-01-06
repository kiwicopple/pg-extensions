# pg_cedar

Cedar-compatible authorization for PostgreSQL with Row-Level Security (RLS) support.

## Overview

`pg_cedar` brings [Cedar](https://www.cedarpolicy.com/)-style authorization to PostgreSQL. Cedar is Amazon's open-source policy language for implementing fine-grained access control.

This extension provides:
- **Entity management** - Users, Roles, Groups, and Resources with hierarchical relationships
- **Policy-based authorization** - Permit/forbid policies with conditions
- **RLS-compatible functions** - Functions designed to work efficiently inside Row-Level Security policies
- **Flexible conditions** - JSONB-based conditions for attribute-based access control

## Installation

```sql
CREATE EXTENSION pg_cedar;
```

## Quick Start

### 1. Set up users and groups

```sql
-- Add users with roles
SELECT cedar_add_user('alice', 'Alice Smith', ARRAY['admin'], ARRAY['engineering']);
SELECT cedar_add_user('bob', 'Bob Jones', ARRAY['viewer'], ARRAY['marketing']);

-- Or add entities manually
SELECT cedar_add_entity('User', 'charlie', 'Charlie Brown');
SELECT cedar_add_parent('User', 'charlie', 'Group', 'engineering');
```

### 2. Create policies

```sql
-- Admins can do anything
SELECT cedar_permit_in('Role', 'admin', NULL, NULL, NULL, '{}', 'Admins have full access');

-- Viewers can only read
SELECT cedar_permit_in('Role', 'viewer', 'read', NULL, NULL, '{}', 'Viewers can read');

-- Engineering team can write to Project resources
SELECT cedar_permit_in('Group', 'engineering', 'write', 'Project', NULL, '{}', 'Engineering can write projects');

-- Forbid deleting archived resources
SELECT cedar_forbid(NULL, NULL, 'delete', NULL, NULL, '{"resource.status": "archived"}', 'Cannot delete archived');
```

### 3. Check authorization

```sql
-- Set the current user for the session
SELECT cedar_set_user('alice');

-- Check if user can perform action
SELECT cedar_check('read', 'Document', 'doc-123');  -- true
SELECT cedar_check('delete', 'Document', 'doc-123'); -- depends on policies
```

### 4. Use with RLS policies

```sql
-- Create a table with owner
CREATE TABLE documents (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id text NOT NULL,
    title text,
    content text
);

-- Enable RLS
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

-- Policy: Users can see documents they have 'read' permission for
CREATE POLICY documents_select ON documents
    FOR SELECT
    USING (cedar_check_owner('read', 'Document', id::text, owner_id));

-- Policy: Users can update documents they have 'write' permission for
CREATE POLICY documents_update ON documents
    FOR UPDATE
    USING (cedar_check_owner('write', 'Document', id::text, owner_id));

-- Policy: Users can delete documents they have 'delete' permission for
CREATE POLICY documents_delete ON documents
    FOR DELETE
    USING (cedar_check_owner('delete', 'Document', id::text, owner_id));
```

## Core Concepts

### Entities

Entities represent principals (users, roles, groups) and resources in your system.

```sql
-- Add an entity type
INSERT INTO cedar_entity_types (name, description)
VALUES ('Project', 'Project resources');

-- Add entities
SELECT cedar_add_entity('Project', 'proj-1', 'My Project', '{"status": "active"}');
```

### Entity Hierarchy

Entities can have parent-child relationships (e.g., User in Group, Resource in Folder).

```sql
-- Add user to group
SELECT cedar_add_parent('User', 'alice', 'Group', 'engineering');

-- Check membership (transitive)
SELECT cedar_entity_in('User', 'alice', 'Group', 'engineering');  -- true

-- Get all ancestors
SELECT * FROM cedar_get_ancestors('User', 'alice');
```

### Policies

Policies define who can do what on which resources.

```sql
-- Structure of a policy:
-- Effect: permit or forbid
-- Principal: who (User::alice, or "in Role::admin")
-- Action: what (read, write, delete, etc.)
-- Resource: on what (Document::doc-1, or "in Folder::shared")
-- Conditions: additional requirements (JSONB)
```

### Policy Evaluation

Policies are evaluated in priority order:
1. Lower priority number = higher precedence
2. At the same priority, `forbid` takes precedence over `permit`
3. Default deny if no matching `permit` policy

```sql
-- High priority admin override (priority 10)
SELECT cedar_permit_in('Role', 'super-admin', NULL, NULL, NULL, '{}',
    'Super admin override', 10);

-- Normal policies (priority 100)
SELECT cedar_forbid(NULL, NULL, 'delete', NULL, NULL,
    '{"resource.status": "locked"}', 'Cannot delete locked', 100);
```

## API Reference

### Session Functions

| Function | Description |
|----------|-------------|
| `cedar_set_user(user_id)` | Set current user for session |
| `cedar_current_user_id()` | Get current user ID |

### Authorization Functions

| Function | Description |
|----------|-------------|
| `cedar_is_authorized(principal_type, principal_id, action_type, action_id, resource_type, resource_id, context)` | Full authorization check |
| `cedar_check(action, resource_type, resource_id, context)` | Simple check using session user |
| `cedar_check_owner(action, resource_type, resource_id, owner_id)` | Check with owner bypass |
| `cedar_has_role(role_id)` | Check if current user has role |
| `cedar_in_group(group_id)` | Check if current user is in group |

### Entity Management Functions

| Function | Description |
|----------|-------------|
| `cedar_add_entity(type, id, display_name, attributes)` | Add or update an entity |
| `cedar_add_user(user_id, display_name, roles[], groups[], attributes)` | Add user with memberships |
| `cedar_add_parent(child_type, child_id, parent_type, parent_id)` | Add entity to parent |
| `cedar_remove_parent(child_type, child_id, parent_type, parent_id)` | Remove from parent |
| `cedar_entity_in(child_type, child_id, parent_type, parent_id)` | Check membership (transitive) |
| `cedar_get_ancestors(type, id)` | Get all ancestor entities |
| `cedar_get_descendants(type, id)` | Get all descendant entities |

### Policy Management Functions

| Function | Description |
|----------|-------------|
| `cedar_permit(principal_type, principal_id, action_id, resource_type, resource_id, conditions, description, priority)` | Create permit policy |
| `cedar_forbid(...)` | Create forbid policy |
| `cedar_permit_in(principal_in_type, principal_in_id, ...)` | Permit for group/role members |

### Views

| View | Description |
|------|-------------|
| `cedar_effective_permissions` | Human-readable policy list |
| `cedar_user_memberships` | Users with their roles/groups |

## Examples

### Multi-tenant Application

```sql
-- Add organization as an entity type
INSERT INTO cedar_entity_types (name) VALUES ('Organization');

-- Users belong to organizations
SELECT cedar_add_entity('Organization', 'org-1', 'Acme Corp');
SELECT cedar_add_user('alice', 'Alice', '{}', '{}');
SELECT cedar_add_parent('User', 'alice', 'Organization', 'org-1');

-- Resources belong to organizations
SELECT cedar_add_entity('Document', 'doc-1', 'Secret Doc', '{"org": "org-1"}');
SELECT cedar_add_parent('Document', 'doc-1', 'Organization', 'org-1');

-- Users can only access resources in their org
SELECT cedar_permit(
    NULL, NULL,  -- Any principal
    'read',      -- Action
    NULL, NULL,  -- Any resource type/id
    '{}',        -- No conditions (hierarchy handles it)
    'Users can read resources in their org'
);

-- RLS policy using hierarchy
CREATE POLICY org_isolation ON documents
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM cedar_get_ancestors('Document', id::text) a
            JOIN cedar_get_ancestors('User', cedar_current_user_id()) u
            ON a.ancestor_type = u.ancestor_type AND a.ancestor_id = u.ancestor_id
            WHERE a.ancestor_type = 'Organization'
        )
    );
```

### Attribute-Based Access Control

```sql
-- Set user attributes
SELECT cedar_add_entity('User', 'alice', 'Alice',
    '{"department": "engineering", "clearance": 3}');

-- Policy with conditions
SELECT cedar_permit(
    'User', NULL,           -- Any user
    'read',                 -- Read action
    'SecretDoc', NULL,      -- SecretDoc resources
    '{"principal.clearance": 3}',  -- Must have clearance 3
    'Users with clearance 3 can read secret docs'
);
```

### Time-Based Access

```sql
-- Add context when checking
SELECT cedar_is_authorized(
    'User', 'alice',
    'Action', 'access',
    'Building', 'hq',
    '{"hour": 14}'::jsonb  -- Current hour
);

-- Policy that only allows access during business hours
-- (You'd check the hour in application code or use a custom function)
```

## Performance Considerations

1. **Indexes**: The extension creates indexes on frequently queried columns
2. **STABLE functions**: Authorization functions are marked STABLE for query optimization
3. **Caching**: Consider using `pg_stat_statements` to identify slow policy evaluations
4. **Hierarchy depth**: Deep hierarchies may impact performance; consider flattening

## Integration with Supabase

```sql
-- Use Supabase auth.uid() as the user ID
CREATE OR REPLACE FUNCTION cedar_supabase_check(
    p_action text,
    p_resource_type text,
    p_resource_id text
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT cedar_is_authorized(
        'User',
        auth.uid()::text,
        'Action',
        p_action,
        p_resource_type,
        p_resource_id,
        '{}'::jsonb
    );
$$;

-- Use in RLS
CREATE POLICY supabase_rls ON my_table
    FOR SELECT
    USING (cedar_supabase_check('read', 'MyTable', id::text));
```

## License

MIT License
