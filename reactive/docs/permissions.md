# Permissions & RBAC Guide

Complete guide to configuring access control for the Reactive extension.

## Overview

The Reactive extension uses a Role-Based Access Control (RBAC) system with three levels:

1. **Groups**: Organizational units (teams, tenants, workspaces)
2. **Roles**: User's position within a group (owner, admin, member, viewer)
3. **Permissions**: What roles can do on which tables

```
User ──belongs to──> Group (with Role) ──grants──> Permission ──on──> Table
```

---

## Groups

Groups represent organizational units in your application. Examples:
- Teams in a project management app
- Organizations in a B2B SaaS
- Workspaces in a collaboration tool

### Creating Groups

```sql
-- Create a group
INSERT INTO reactive.groups (name, metadata)
VALUES ('Engineering Team', '{"department": "engineering"}')
RETURNING *;

-- Create multiple groups
INSERT INTO reactive.groups (name) VALUES
  ('Marketing'),
  ('Sales'),
  ('Support');
```

### Group Metadata

Store custom attributes in the `metadata` JSONB column:

```sql
INSERT INTO reactive.groups (name, metadata)
VALUES ('Acme Corp', '{
  "plan": "enterprise",
  "seats": 100,
  "features": ["sso", "audit_logs"],
  "billing_email": "billing@acme.com"
}');
```

---

## Roles

Roles define a user's position within a group. The standard roles are:

| Role | Description | Typical Permissions |
|------|-------------|---------------------|
| `owner` | Full control | All permissions, can delete group |
| `admin` | Administrative | Manage members, settings, all data |
| `member` | Standard user | CRUD on assigned resources |
| `viewer` | Read-only | View data only |

### Adding Users to Groups

```sql
-- Add user as a member
INSERT INTO reactive.group_users (group_id, user_id, role)
VALUES ('group-uuid', 'user-uuid', 'member');

-- Promote user to admin
UPDATE reactive.group_users
SET role = 'admin'
WHERE group_id = 'group-uuid' AND user_id = 'user-uuid';

-- Remove user from group
DELETE FROM reactive.group_users
WHERE group_id = 'group-uuid' AND user_id = 'user-uuid';
```

### Custom Roles

You can define custom roles beyond the standard four:

```sql
-- Add user with custom role
INSERT INTO reactive.group_users (group_id, user_id, role)
VALUES ('group-uuid', 'user-uuid', 'billing_admin');

-- Create permission for custom role
INSERT INTO reactive.permissions (role, table_name, can_subscribe)
VALUES ('billing_admin', 'invoices', true);
```

### Auto-Adding Users to Groups

Automatically add new users to a default group:

```sql
-- Create trigger function
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  -- Add to default group as member
  INSERT INTO reactive.group_users (group_id, user_id, role)
  VALUES (
    '00000000-0000-0000-0000-000000000001',  -- default group
    NEW.id,
    'member'
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Attach to auth.users
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
```

---

## Permissions

Permissions control what roles can do on which tables.

### Permission Columns

| Column | Description |
|--------|-------------|
| `group_id` | Scope to specific group (NULL = all groups) |
| `role` | Role this permission applies to |
| `table_schema` | Schema name (`public`, `*` for all) |
| `table_name` | Table name (`*` for all tables) |
| `can_select` | Can read data via queries |
| `can_insert` | Can insert new rows |
| `can_update` | Can update existing rows |
| `can_delete` | Can delete rows |
| `can_subscribe` | Can receive realtime updates |
| `row_filter` | SQL expression for row-level filtering |

### Basic Permission Examples

```sql
-- Members can subscribe to tasks
INSERT INTO reactive.permissions (role, table_name, can_subscribe)
VALUES ('member', 'tasks', true);

-- Admins can subscribe to all tables
INSERT INTO reactive.permissions (role, table_name, can_subscribe)
VALUES ('admin', '*', true);

-- Viewers can only read (no subscribe)
INSERT INTO reactive.permissions (role, table_name, can_select)
VALUES ('viewer', 'tasks', true);
```

### Group-Scoped Permissions

Limit permissions to a specific group:

```sql
-- Only Engineering group members can subscribe to deployments
INSERT INTO reactive.permissions (group_id, table_name, can_subscribe)
SELECT id, 'deployments', true
FROM reactive.groups
WHERE name = 'Engineering Team';
```

### Schema-Scoped Permissions

Control access across schemas:

```sql
-- Members can subscribe to all tables in 'app' schema
INSERT INTO reactive.permissions (role, table_schema, table_name, can_subscribe)
VALUES ('member', 'app', '*', true);

-- Admins can subscribe to anything in any schema
INSERT INTO reactive.permissions (role, table_schema, table_name, can_subscribe)
VALUES ('admin', '*', '*', true);
```

---

## Row-Level Filtering

Row filters control which specific rows a user can receive updates for.

### Common Patterns

#### Owner-based Filtering

Users only see rows they own:

```sql
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', 'documents', true, 'owner_id = auth.uid()');
```

#### Group-based Filtering

Users see rows belonging to their group:

```sql
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', 'projects', true, 'group_id IN (SELECT group_id FROM reactive.group_users WHERE user_id = auth.uid())');
```

#### Status-based Filtering

Users only see published content:

```sql
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('viewer', 'articles', true, 'status = ''published''');
```

#### Combined Filters

```sql
-- Members see their own drafts OR any published article
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', 'articles', true,
  '(owner_id = auth.uid()) OR (status = ''published'')');
```

### How Row Filters Work

1. When a row changes, the trigger fires
2. For each subscriber, their permissions are checked
3. If a `row_filter` exists, it's evaluated against the row data
4. Only if the filter returns `true` is the change broadcast to that user

```sql
-- Example: User A owns row, User B does not
-- Row filter: owner_id = auth.uid()

-- INSERT into tasks (owner_id = 'user-a-id', title = 'My Task')
--
-- For User A: filter evaluates to TRUE → receives broadcast
-- For User B: filter evaluates to FALSE → no broadcast
```

---

## Permission Hierarchy

Permissions are evaluated with the following precedence:

1. **User-specific permissions** (via group membership)
2. **Role-based permissions** (applies to all users with that role)
3. **Wildcard permissions** (`*` table or schema)

### Example Hierarchy

```sql
-- Base: all members can subscribe to tasks
INSERT INTO reactive.permissions (role, table_name, can_subscribe)
VALUES ('member', 'tasks', true);

-- Override: Engineering group members can also subscribe to deployments
INSERT INTO reactive.permissions (group_id, table_name, can_subscribe)
SELECT id, 'deployments', true FROM reactive.groups WHERE name = 'Engineering';

-- Admin wildcard: admins can subscribe to everything
INSERT INTO reactive.permissions (role, table_name, can_subscribe)
VALUES ('admin', '*', true);
```

---

## Checking Permissions

### From SQL

```sql
-- Check if current user can subscribe to a table
SELECT reactive.can_subscribe('public', 'tasks');

-- Check group membership
SELECT reactive.user_is_group_member('group-uuid');

-- Check specific role
SELECT reactive.user_has_group_role('group-uuid', 'admin');

-- List all user's groups and roles
SELECT * FROM reactive.get_user_groups();
```

### From Client (via RPC)

```typescript
// Check subscription permission
const { data: canSubscribe } = await supabase.rpc('can_subscribe', {
  p_table_schema: 'public',
  p_table_name: 'tasks'
});

if (canSubscribe) {
  // Subscribe to changes
}

// Get user's groups
const { data: groups } = await supabase.rpc('get_user_groups');
console.log(groups);
// [{ group_id: '...', group_name: 'Acme', role: 'admin' }]
```

---

## Multi-Tenant Patterns

### Pattern 1: One Group per Tenant

Each tenant/customer is a separate group:

```sql
-- Create tenant
INSERT INTO reactive.groups (name, metadata)
VALUES ('Customer ABC', '{"tenant_id": "abc123"}');

-- Add users to tenant
INSERT INTO reactive.group_users (group_id, user_id, role)
VALUES ('tenant-group-id', 'user-id', 'member');

-- Permission: members can subscribe to their tenant's data
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', 'projects', true,
  'tenant_id IN (SELECT (metadata->>''tenant_id'') FROM reactive.groups g
   JOIN reactive.group_users gu ON g.id = gu.group_id
   WHERE gu.user_id = auth.uid())');
```

### Pattern 2: Shared Tables with Row Filtering

All tenants share tables, rows are filtered by tenant:

```sql
-- All tenants in one group with tenant_id on rows
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', '*', true, 'tenant_id = (auth.jwt()->''user_metadata''->>''tenant_id'')::uuid');
```

### Pattern 3: Schema per Tenant

Each tenant has their own schema:

```sql
-- Create schema for tenant
CREATE SCHEMA tenant_abc;

-- Permission for that tenant's schema
INSERT INTO reactive.permissions (group_id, table_schema, table_name, can_subscribe)
SELECT g.id, 'tenant_abc', '*', true
FROM reactive.groups g
WHERE g.metadata->>'tenant_id' = 'abc';
```

---

## Security Best Practices

### 1. Default Deny

Start with no permissions and explicitly grant access:

```sql
-- Don't create wildcard permissions for 'member' role
-- Instead, explicitly list allowed tables
INSERT INTO reactive.permissions (role, table_name, can_subscribe)
VALUES
  ('member', 'tasks', true),
  ('member', 'comments', true),
  ('member', 'notifications', true);
```

### 2. Use Row Filters for Sensitive Data

Always filter sensitive tables:

```sql
-- Users only see their own data
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', 'user_settings', true, 'user_id = auth.uid()');

-- Users only see team data
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', 'team_secrets', true,
  'team_id IN (SELECT group_id FROM reactive.group_users WHERE user_id = auth.uid())');
```

### 3. Separate Read and Subscribe Permissions

A user might be able to query data but not receive real-time updates:

```sql
-- Viewers can read but not subscribe
INSERT INTO reactive.permissions (role, table_name, can_select)
VALUES ('viewer', 'audit_logs', true);
-- No can_subscribe = no realtime updates
```

### 4. Audit Permission Changes

Track who modifies permissions:

```sql
-- Add audit columns to permissions table
ALTER TABLE reactive.permissions
ADD COLUMN created_by UUID REFERENCES auth.users(id),
ADD COLUMN updated_at TIMESTAMPTZ DEFAULT now(),
ADD COLUMN updated_by UUID REFERENCES auth.users(id);

-- Trigger to track changes
CREATE OR REPLACE FUNCTION audit_permission_changes()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  NEW.updated_by = auth.uid();
  IF TG_OP = 'INSERT' THEN
    NEW.created_by = auth.uid();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER audit_permissions
  BEFORE INSERT OR UPDATE ON reactive.permissions
  FOR EACH ROW EXECUTE FUNCTION audit_permission_changes();
```

### 5. Regular Permission Reviews

Periodically audit permissions:

```sql
-- Find overly permissive wildcards
SELECT * FROM reactive.permissions
WHERE table_name = '*' OR table_schema = '*';

-- Find unused permissions (no matching subscriptions)
SELECT p.*
FROM reactive.permissions p
LEFT JOIN reactive.subscriptions s ON (
  s.table_schema = p.table_schema AND s.table_name = p.table_name
)
WHERE s.id IS NULL;
```
