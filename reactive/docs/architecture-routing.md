# Architecture: Change Routing

This document explains how the Reactive extension determines which users receive which changes.

## TL;DR

**Not all changes go to all users.** Each change is evaluated against:
1. Active subscriptions (who is listening?)
2. Permissions (who is allowed?)
3. Row filters (does this specific row match?)

Only users who pass all three checks receive the broadcast.

---

## The Routing Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           DATA CHANGE OCCURS                                │
│                    (INSERT, UPDATE, or DELETE on table)                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TRIGGER FIRES                                       │
│                  reactive.broadcast_table_changes()                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    STEP 1: FIND SUBSCRIBERS                                 │
│                                                                             │
│   SELECT user_id, topic FROM reactive.subscriptions                         │
│   WHERE table_schema = 'public' AND table_name = 'tasks'                    │
│                                                                             │
│   Result: List of users who called subscribe() on this table                │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    STEP 2: CHECK PERMISSIONS                                │
│                                                                             │
│   For each subscriber, check reactive.permissions:                          │
│   - Does their role have can_subscribe = true for this table?               │
│   - Or does their group have can_subscribe = true?                          │
│                                                                             │
│   Filter out users without permission                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    STEP 3: APPLY ROW FILTERS                                │
│                                                                             │
│   For each remaining user, if permission has row_filter:                    │
│   - Evaluate: Does this specific row match the filter?                      │
│   - Example: row_filter = 'owner_id = auth.uid()'                           │
│     → Only broadcast if row.owner_id == subscriber.user_id                  │
│                                                                             │
│   Filter out users whose row_filter returns false                           │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    STEP 4: BROADCAST TO EACH USER                           │
│                                                                             │
│   FOR EACH authorized user:                                                 │
│       PERFORM realtime.broadcast_changes(                                   │
│           user.topic,     -- 'reactive:user:{user_id}'                      │
│           operation,      -- INSERT/UPDATE/DELETE                           │
│           ...                                                               │
│       )                                                                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SUPABASE REALTIME                                        │
│                                                                             │
│   Reads from realtime.messages (WAL)                                        │
│   Routes each message to the specific user's WebSocket                      │
│   RLS policy ensures users only see their own topic                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Concrete Example

### Setup

```sql
-- Users
-- User A: id = 'aaaa-aaaa-aaaa-aaaa'
-- User B: id = 'bbbb-bbbb-bbbb-bbbb'
-- User C: id = 'cccc-cccc-cccc-cccc'

-- Both users are members in the same group
INSERT INTO reactive.group_users (group_id, user_id, role) VALUES
  ('group-1', 'aaaa-aaaa-aaaa-aaaa', 'member'),
  ('group-1', 'bbbb-bbbb-bbbb-bbbb', 'member'),
  ('group-1', 'cccc-cccc-cccc-cccc', 'viewer');

-- Permission: members can subscribe, but only see rows they own
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', 'tasks', true, 'owner_id = auth.uid()');

-- Note: 'viewer' role has NO permission to subscribe

-- User A subscribes to tasks
SELECT reactive.subscribe('public', 'tasks');  -- as User A
-- Creates: subscriptions row for User A

-- User B subscribes to tasks
SELECT reactive.subscribe('public', 'tasks');  -- as User B
-- Creates: subscriptions row for User B

-- User C tries to subscribe
SELECT reactive.subscribe('public', 'tasks');  -- as User C
-- ERROR: Permission denied (viewer role has no can_subscribe)
```

### Scenario: User A Creates a Task

```sql
-- User A inserts a task they own
INSERT INTO tasks (id, title, owner_id)
VALUES ('task-1', 'My Task', 'aaaa-aaaa-aaaa-aaaa');
```

**Trigger evaluates:**

| User | Subscribed? | Has Permission? | Row Filter Passes? | Receives Broadcast? |
|------|-------------|-----------------|-------------------|---------------------|
| User A | ✅ Yes | ✅ member role | ✅ owner_id = User A | ✅ **YES** |
| User B | ✅ Yes | ✅ member role | ❌ owner_id ≠ User B | ❌ **NO** |
| User C | ❌ No | ❌ viewer role | N/A | ❌ **NO** |

**Result:** Only User A receives the broadcast.

### Scenario: User B Creates a Task

```sql
-- User B inserts a task they own
INSERT INTO tasks (id, title, owner_id)
VALUES ('task-2', 'Another Task', 'bbbb-bbbb-bbbb-bbbb');
```

**Trigger evaluates:**

| User | Subscribed? | Has Permission? | Row Filter Passes? | Receives Broadcast? |
|------|-------------|-----------------|-------------------|---------------------|
| User A | ✅ Yes | ✅ member role | ❌ owner_id ≠ User A | ❌ **NO** |
| User B | ✅ Yes | ✅ member role | ✅ owner_id = User B | ✅ **YES** |
| User C | ❌ No | ❌ viewer role | N/A | ❌ **NO** |

**Result:** Only User B receives the broadcast.

### Scenario: Shared Task (No Row Filter)

If we had a different permission without row filter:

```sql
-- Everyone can see all tasks (no row filter)
INSERT INTO reactive.permissions (role, table_name, can_subscribe)
VALUES ('member', 'shared_tasks', true);
-- Note: No row_filter means all rows pass
```

Now when a shared task is created:

| User | Subscribed? | Has Permission? | Row Filter Passes? | Receives Broadcast? |
|------|-------------|-----------------|-------------------|---------------------|
| User A | ✅ Yes | ✅ member role | ✅ (no filter) | ✅ **YES** |
| User B | ✅ Yes | ✅ member role | ✅ (no filter) | ✅ **YES** |
| User C | ❌ No | ❌ viewer role | N/A | ❌ **NO** |

**Result:** Both User A and User B receive the broadcast.

---

## The SQL Behind It

Here's the actual query the trigger runs to find recipients:

```sql
-- Simplified version of the trigger's routing query
SELECT DISTINCT s.user_id, s.topic
FROM reactive.subscriptions s
-- Join to check permissions
JOIN reactive.permissions p ON (
    (p.table_schema = TG_TABLE_SCHEMA OR p.table_schema = '*')
    AND (p.table_name = TG_TABLE_NAME OR p.table_name = '*')
    AND p.can_subscribe = true
)
-- Join to verify user has the required role/group
LEFT JOIN reactive.group_users gu ON (
    p.group_id = gu.group_id AND gu.user_id = s.user_id
)
WHERE
    -- User is subscribed to this table
    s.table_schema = TG_TABLE_SCHEMA
    AND s.table_name = TG_TABLE_NAME
    -- User has permission (via group or role)
    AND (
        (p.group_id IS NOT NULL AND gu.user_id IS NOT NULL)
        OR
        (p.role IS NOT NULL AND EXISTS (
            SELECT 1 FROM reactive.group_users gu2
            WHERE gu2.user_id = s.user_id AND gu2.role = p.role
        ))
    )
    -- Row filter passes (if defined)
    AND (
        p.row_filter IS NULL
        OR reactive.evaluate_row_filter(p.row_filter, row_data, s.user_id)
    )
```

---

## Common Patterns

### Pattern 1: Private Data (Owner Only)

Each user sees only their own data.

```sql
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', 'user_settings', true, 'user_id = auth.uid()');
```

```
User A changes their settings → Only User A receives broadcast
User B changes their settings → Only User B receives broadcast
```

### Pattern 2: Team/Group Data

Users see data belonging to their team.

```sql
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', 'team_tasks', true,
  'team_id IN (SELECT group_id FROM reactive.group_users WHERE user_id = auth.uid())');
```

```
Task created in Team Alpha:
  → All Team Alpha members receive broadcast
  → Team Beta members do NOT receive broadcast
```

### Pattern 3: Public Data (Broadcast to All)

All subscribers see all changes (like a public feed).

```sql
INSERT INTO reactive.permissions (role, table_name, can_subscribe)
VALUES ('member', 'announcements', true);
-- No row_filter = all rows pass
```

```
New announcement created → ALL subscribed members receive broadcast
```

### Pattern 4: Hierarchical Access

Admins see everything, members see their own.

```sql
-- Admins see all
INSERT INTO reactive.permissions (role, table_name, can_subscribe)
VALUES ('admin', 'tasks', true);

-- Members see only their own
INSERT INTO reactive.permissions (role, table_name, can_subscribe, row_filter)
VALUES ('member', 'tasks', true, 'owner_id = auth.uid()');
```

```
User A (member) creates task:
  → User A receives broadcast (owner)
  → All admins receive broadcast (no filter)
  → Other members do NOT receive broadcast
```

---

## Performance Considerations

### Subscription Table Size

The trigger queries `subscriptions` on every change. Keep it lean:

```sql
-- Index for fast lookups
CREATE INDEX idx_subscriptions_table
ON reactive.subscriptions(table_schema, table_name);

-- Periodically clean stale subscriptions
DELETE FROM reactive.subscriptions
WHERE last_seen_at < now() - interval '24 hours';
```

### Row Filter Complexity

Complex row filters run for every subscriber on every change:

```sql
-- FAST: Simple equality
row_filter = 'owner_id = auth.uid()'

-- SLOWER: Subquery (runs once per subscriber)
row_filter = 'team_id IN (SELECT group_id FROM reactive.group_users WHERE user_id = auth.uid())'

-- SLOWEST: Complex joins (avoid if possible)
row_filter = 'EXISTS (SELECT 1 FROM complex_view WHERE ...)'
```

**Optimization:** For complex team-based filtering, consider denormalizing the team_id check into a simpler pattern.

### High-Traffic Tables

For tables with many changes per second:

1. **Batch broadcasts** - Group multiple changes
2. **Selective triggers** - Only trigger on specific columns
3. **Async processing** - Use `pg_net` for non-blocking broadcasts

---

## Summary

| Component | Purpose |
|-----------|---------|
| `subscriptions` table | Tracks who is listening to what tables |
| `permissions` table | Defines who is allowed to receive what |
| `row_filter` column | Fine-grained row-level access control |
| Trigger function | Evaluates all three for each change |
| Per-user topics | Ensures broadcasts go only to intended recipients |

**The key insight:** Broadcasting happens server-side in the trigger. The database decides who gets what, not the client. This ensures security - users can't subscribe to data they shouldn't see.
