# SQL Extension Reference

Complete guide to the database components of the Reactive extension.

## Schema Overview

The extension creates a `reactive` schema with the following tables and functions:

```
reactive/
├── Tables
│   ├── groups           # Organizational units/tenants
│   ├── group_users      # User membership with roles
│   ├── permissions      # RBAC permission rules
│   └── subscriptions    # Active subscription tracking
│
└── Functions
    ├── enable_realtime()        # Enable broadcasts for a table
    ├── disable_realtime()       # Disable broadcasts for a table
    ├── subscribe()              # Register a subscription
    ├── unsubscribe()            # Remove a subscription
    ├── can_subscribe()          # Check subscription permission
    ├── user_is_group_member()   # Check group membership
    ├── user_has_group_role()    # Check user's role in group
    ├── get_user_groups()        # List user's groups and roles
    └── get_user_topic()         # Get user's Realtime channel
```

## Tables

### reactive.groups

Represents organizational units, teams, or tenants.

```sql
CREATE TABLE reactive.groups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);
```

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `name` | TEXT | Display name for the group |
| `metadata` | JSONB | Custom metadata (settings, config, etc.) |
| `created_at` | TIMESTAMPTZ | Creation timestamp |
| `updated_at` | TIMESTAMPTZ | Last update timestamp |

**Example:**
```sql
INSERT INTO reactive.groups (name, metadata)
VALUES ('Acme Corp', '{"plan": "pro", "seats": 50}');
```

### reactive.group_users

Links users to groups with their assigned roles.

```sql
CREATE TABLE reactive.group_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID NOT NULL REFERENCES reactive.groups(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'member',
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(group_id, user_id)
);
```

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `group_id` | UUID | Reference to groups table |
| `user_id` | UUID | Reference to auth.users |
| `role` | TEXT | Role within the group |
| `created_at` | TIMESTAMPTZ | When user joined the group |

**Standard Roles:**
- `owner` - Full control, can delete group
- `admin` - Can manage members and settings
- `member` - Standard access
- `viewer` - Read-only access

**Example:**
```sql
-- Add user as admin
INSERT INTO reactive.group_users (group_id, user_id, role)
VALUES ('group-uuid', 'user-uuid', 'admin');
```

### reactive.permissions

Defines what roles can do on which tables.

```sql
CREATE TABLE reactive.permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID REFERENCES reactive.groups(id) ON DELETE CASCADE,
    role TEXT,
    table_schema TEXT NOT NULL DEFAULT 'public',
    table_name TEXT NOT NULL,
    can_select BOOLEAN DEFAULT false,
    can_insert BOOLEAN DEFAULT false,
    can_update BOOLEAN DEFAULT false,
    can_delete BOOLEAN DEFAULT false,
    can_subscribe BOOLEAN DEFAULT false,
    row_filter TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT valid_scope CHECK (group_id IS NOT NULL OR role IS NOT NULL)
);
```

| Column | Type | Description |
|--------|------|-------------|
| `group_id` | UUID | Scope to specific group (optional) |
| `role` | TEXT | Scope to users with this role (optional) |
| `table_schema` | TEXT | Schema name (`public`, `*` for all) |
| `table_name` | TEXT | Table name (`*` for all tables) |
| `can_select` | BOOLEAN | Can read data |
| `can_insert` | BOOLEAN | Can insert rows |
| `can_update` | BOOLEAN | Can update rows |
| `can_delete` | BOOLEAN | Can delete rows |
| `can_subscribe` | BOOLEAN | Can receive realtime updates |
| `row_filter` | TEXT | SQL expression for row-level filtering |

**Examples:**
```sql
-- All members can subscribe to tasks
INSERT INTO reactive.permissions (role, table_name, can_subscribe)
VALUES ('member', 'tasks', true);

-- Admins can subscribe to all tables
INSERT INTO reactive.permissions (role, table_name, can_subscribe)
VALUES ('admin', '*', true);

-- Users only receive updates for rows they own
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', 'documents', true, 'owner_id = auth.uid()');

-- Specific group permission
INSERT INTO reactive.permissions (group_id, table_name, can_subscribe)
VALUES ('group-uuid', 'projects', true);
```

### reactive.subscriptions

Tracks active subscriptions for routing broadcasts.

```sql
CREATE TABLE reactive.subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    group_id UUID REFERENCES reactive.groups(id) ON DELETE CASCADE,
    table_schema TEXT NOT NULL DEFAULT 'public',
    table_name TEXT NOT NULL,
    topic TEXT NOT NULL,
    filters JSONB,
    created_at TIMESTAMPTZ DEFAULT now(),
    last_seen_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(user_id, table_schema, table_name)
);
```

**Note:** This table is managed automatically by `subscribe()` and `unsubscribe()` functions. You typically don't need to interact with it directly.

---

## Functions

### reactive.enable_realtime()

Enable realtime broadcasts for a table.

```sql
FUNCTION reactive.enable_realtime(
    p_table_schema TEXT,
    p_table_name TEXT
) RETURNS VOID
```

**Example:**
```sql
SELECT reactive.enable_realtime('public', 'tasks');
SELECT reactive.enable_realtime('public', 'comments');
```

**What it does:**
1. Creates an `AFTER INSERT OR UPDATE OR DELETE` trigger on the table
2. The trigger calls `reactive.broadcast_table_changes()` for each row change
3. Changes are broadcast to subscribed users via `realtime.broadcast_changes()`

### reactive.disable_realtime()

Disable realtime broadcasts for a table.

```sql
FUNCTION reactive.disable_realtime(
    p_table_schema TEXT,
    p_table_name TEXT
) RETURNS VOID
```

**Example:**
```sql
SELECT reactive.disable_realtime('public', 'tasks');
```

### reactive.subscribe()

Register a subscription (called by client library).

```sql
FUNCTION reactive.subscribe(
    p_table_schema TEXT,
    p_table_name TEXT,
    p_filters JSONB DEFAULT NULL
) RETURNS TEXT  -- Returns the topic to subscribe to
```

**Example:**
```sql
-- Subscribe to tasks table
SELECT reactive.subscribe('public', 'tasks');
-- Returns: 'reactive:user:abc123-...'

-- Subscribe with filters
SELECT reactive.subscribe('public', 'tasks', '{"status": "active"}');
```

### reactive.unsubscribe()

Remove a subscription.

```sql
FUNCTION reactive.unsubscribe(
    p_table_schema TEXT,
    p_table_name TEXT
) RETURNS VOID
```

### reactive.can_subscribe()

Check if current user can subscribe to a table.

```sql
FUNCTION reactive.can_subscribe(
    p_table_schema TEXT,
    p_table_name TEXT,
    p_group_id UUID DEFAULT NULL
) RETURNS BOOLEAN
```

**Example:**
```sql
SELECT reactive.can_subscribe('public', 'tasks');
-- Returns: true/false
```

### reactive.user_is_group_member()

Check if current user is a member of a group.

```sql
FUNCTION reactive.user_is_group_member(p_group_id UUID) RETURNS BOOLEAN
```

### reactive.user_has_group_role()

Check if current user has a specific role in a group.

```sql
FUNCTION reactive.user_has_group_role(
    p_group_id UUID,
    p_role TEXT
) RETURNS BOOLEAN
```

**Example:**
```sql
SELECT reactive.user_has_group_role('group-uuid', 'admin');
```

### reactive.get_user_groups()

Get all groups and roles for the current user.

```sql
FUNCTION reactive.get_user_groups()
RETURNS TABLE(group_id UUID, group_name TEXT, role TEXT)
```

**Example:**
```sql
SELECT * FROM reactive.get_user_groups();
-- Returns:
-- group_id                              | group_name | role
-- --------------------------------------+------------+-------
-- 123e4567-e89b-12d3-a456-426614174000 | Acme Corp  | admin
-- 987fcdeb-51a2-3bc4-d567-890123456789 | Side Proj  | member
```

### reactive.get_user_topic()

Get the Realtime topic/channel for a user.

```sql
FUNCTION reactive.get_user_topic(p_user_id UUID DEFAULT NULL) RETURNS TEXT
```

**Example:**
```sql
SELECT reactive.get_user_topic();
-- Returns: 'reactive:user:abc123-def456-...'
```

---

## Trigger Function

### reactive.broadcast_table_changes()

The core trigger function that handles broadcasting changes.

**How it works:**

1. Captures the operation type (INSERT, UPDATE, DELETE)
2. Gets the row data (NEW for insert/update, OLD for delete)
3. Queries `subscriptions` joined with `permissions` to find authorized recipients
4. For each recipient, calls `realtime.broadcast_changes()` with their topic
5. Row filters are evaluated to ensure users only receive authorized rows

**Broadcast payload structure:**
```json
{
  "table": "tasks",
  "schema": "public",
  "operation": "UPDATE",
  "new": { "id": "...", "title": "Updated", ... },
  "old": { "id": "...", "title": "Original", ... }
}
```

---

## RLS Integration

The extension requires an RLS policy on `realtime.messages` to authorize broadcasts:

```sql
CREATE POLICY "Users can receive their broadcasts"
ON realtime.messages
FOR SELECT
TO authenticated
USING (topic = reactive.get_user_topic());
```

This ensures users can only read messages on their own topic.

---

## Performance Considerations

### Indexes

The extension creates indexes for optimal performance:

```sql
CREATE INDEX idx_group_users_user ON reactive.group_users(user_id);
CREATE INDEX idx_group_users_group ON reactive.group_users(group_id);
CREATE INDEX idx_permissions_group ON reactive.permissions(group_id);
CREATE INDEX idx_permissions_role ON reactive.permissions(role);
CREATE INDEX idx_subscriptions_user ON reactive.subscriptions(user_id);
CREATE INDEX idx_subscriptions_table ON reactive.subscriptions(table_schema, table_name);
```

### Subscription Cleanup

Stale subscriptions (where clients disconnected without calling `unsubscribe()`) should be periodically cleaned:

```sql
-- Remove subscriptions not seen in 24 hours
DELETE FROM reactive.subscriptions
WHERE last_seen_at < now() - interval '24 hours';
```

Consider setting up a cron job (via `pg_cron` or external scheduler) to run this periodically.

### Heartbeat

Clients should periodically call `reactive.heartbeat()` to keep subscriptions alive:

```sql
FUNCTION reactive.heartbeat() RETURNS VOID
```

The client library handles this automatically (default: every 30 seconds).
