# pg_cedar Extension Plan

## Overview

Create a Cedar-compatible authorization PostgreSQL extension that developers can use for fine-grained access control with Row-Level Security (RLS) support.

## Goals

1. Provide Cedar-style authorization primitives in PostgreSQL
2. Enable policy-based access control with permit/forbid semantics
3. Support hierarchical relationships (users in groups, resources in folders)
4. Create RLS-compatible functions that are efficient for row-level checks

## Architecture

### Data Model

```
┌─────────────────┐     ┌─────────────────┐
│ cedar_entities  │────▶│ cedar_entity_   │
│                 │     │ parents         │
│ - entity_type   │     │                 │
│ - entity_id     │     │ - child_type/id │
│ - attributes    │     │ - parent_type/id│
└─────────────────┘     └─────────────────┘
        │
        ▼
┌─────────────────┐     ┌─────────────────┐
│ cedar_policies  │     │ cedar_actions   │
│                 │     │                 │
│ - effect        │     │ - action_type   │
│ - principal_*   │     │ - action_id     │
│ - action_*      │     └─────────────────┘
│ - resource_*    │
│ - conditions    │
└─────────────────┘
```

### Core Tables

| Table | Purpose |
|-------|---------|
| `cedar_entity_types` | Registry of entity types (User, Role, Group, etc.) |
| `cedar_entities` | All principals and resources with JSONB attributes |
| `cedar_entity_parents` | Hierarchical relationships between entities |
| `cedar_actions` | Available actions (read, write, delete, etc.) |
| `cedar_policies` | Authorization rules with permit/forbid effects |

### Key Functions

#### RLS-Compatible (STABLE)

- `cedar_check(action, resource_type, resource_id)` - Main RLS check
- `cedar_check_owner(action, resource_type, resource_id, owner_id)` - Check with owner bypass
- `cedar_has_role(role_id)` - Role membership check
- `cedar_in_group(group_id)` - Group membership check

#### Policy Evaluation

- `cedar_is_authorized(principal, action, resource, context)` - Full authorization check
- `cedar_evaluate_conditions(conditions, context, attrs)` - Condition evaluation
- `cedar_entity_in(child, parent)` - Transitive membership check

#### Management

- `cedar_permit(...)` / `cedar_forbid(...)` - Create policies
- `cedar_add_user(...)` - Add users with roles/groups
- `cedar_add_entity(...)` / `cedar_add_parent(...)` - Entity management

## Implementation Steps

1. **Create extension structure**
   - Control file with metadata
   - Main SQL file with version

2. **Define types and tables**
   - `cedar_effect` enum (permit/forbid)
   - Entity tables with indexes
   - Policy table with flexible conditions

3. **Implement hierarchy functions**
   - Recursive CTEs for ancestor/descendant traversal
   - Transitive membership checks

4. **Implement policy evaluation**
   - Priority-based evaluation
   - Condition matching against JSONB context
   - Default deny semantics

5. **Create RLS helpers**
   - Session-based user identification
   - Owner bypass patterns
   - Efficient stable functions

## Usage Example

```sql
-- Setup
CREATE EXTENSION pg_cedar;
SELECT cedar_add_user('alice', 'Alice', ARRAY['admin'], ARRAY['eng']);
SELECT cedar_permit_in('Role', 'admin', 'write', 'Document', NULL);

-- RLS Policy
CREATE POLICY doc_access ON documents
    FOR ALL USING (cedar_check('read', 'Document', id::text));
```

## Files

```
pg_cedar/
├── pg_cedar.control          # Extension metadata
├── pg_cedar--0.0.1.sql       # Main implementation
└── README.md                 # Documentation
```
