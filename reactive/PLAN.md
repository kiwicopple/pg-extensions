# Reactive Extension for Supabase - Architecture Plan

## Overview

A PostgreSQL extension that enables real-time data synchronization via Supabase Realtime Broadcast. Tables in the `reactive` schema automatically capture changes and broadcast them to connected users based on permissions.

## Goals

1. **Automatic CDC**: Every table in the `reactive` schema has triggers to capture INSERT, UPDATE, DELETE
2. **Realtime Broadcast**: Changes are sent via Supabase Realtime Broadcast (using `pg_net` + Supabase HTTP API or direct `pg_notify`)
3. **UUID Tracking**: Every row has a unique identifier for change tracking
4. **Scalable Permissions**: RBAC system to control who receives which changes
5. **Per-User Rooms**: Each user gets a unique channel for their subscribed changes

---

## Architecture Options

### Option A: Database-Driven Broadcast via `pg_notify`

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│  Table Change   │───>│  Trigger fires   │───>│  pg_notify()        │
│  (INSERT/etc)   │    │  checks perms    │    │  to 'realtime'      │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
                                                        │
                                                        v
┌─────────────────────────────────────────────────────────────────────┐
│                    Supabase Realtime Server                         │
│  (listens to pg_notify, routes to user channels via Broadcast)      │
└─────────────────────────────────────────────────────────────────────┘
                                                        │
                                                        v
                              ┌─────────────────────────────────────┐
                              │  Client WebSocket (per-user room)   │
                              └─────────────────────────────────────┘
```

**Pros**: Native PostgreSQL, low latency, no external dependencies
**Cons**: `pg_notify` has 8KB payload limit, requires Supabase Realtime to listen

### Option B: HTTP Broadcast via `pg_net`

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│  Table Change   │───>│  Trigger fires   │───>│  pg_net.http_post() │
│  (INSERT/etc)   │    │  checks perms    │    │  to Realtime API    │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
                                                        │
                                                        v
┌─────────────────────────────────────────────────────────────────────┐
│           Supabase Realtime Broadcast API                           │
│           POST /api/broadcast { channel, event, payload }           │
└─────────────────────────────────────────────────────────────────────┘
```

**Pros**: No payload limit, works with any Realtime setup, more flexible
**Cons**: Requires `pg_net` extension, HTTP overhead, async (non-blocking but slight delay)

### Recommendation: Hybrid Approach

Use `pg_notify` for small payloads (< 7KB) and `pg_net` for larger payloads. This maximizes performance while handling edge cases.

---

## Schema Design

### Core Tables

```sql
-- Schema for all reactive tables and metadata
CREATE SCHEMA IF NOT EXISTS reactive;

-- Permissions/RBAC table
CREATE TABLE reactive.permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Who has the permission
    user_id UUID,                    -- specific user (NULL = applies to roles)
    role TEXT,                       -- role name (e.g., 'authenticated', 'admin')

    -- What they can access
    table_name TEXT NOT NULL,        -- table in reactive schema
    row_filter TEXT,                 -- optional: SQL expression for row-level filtering

    -- Permission type
    can_read BOOLEAN DEFAULT false,  -- receive changes for this table
    can_write BOOLEAN DEFAULT false, -- can modify (separate from read)

    -- Constraints
    CONSTRAINT valid_subject CHECK (user_id IS NOT NULL OR role IS NOT NULL),
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Index for fast permission lookups
CREATE INDEX idx_permissions_user ON reactive.permissions(user_id);
CREATE INDEX idx_permissions_role ON reactive.permissions(role);
CREATE INDEX idx_permissions_table ON reactive.permissions(table_name);

-- Subscription tracking (optional: for managing active subscriptions)
CREATE TABLE reactive.subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    table_name TEXT NOT NULL,
    room_id TEXT NOT NULL,           -- unique room/channel identifier
    filters JSONB,                   -- client-specified filters
    created_at TIMESTAMPTZ DEFAULT now(),
    expires_at TIMESTAMPTZ,          -- optional TTL

    UNIQUE(user_id, table_name)
);

-- Audit log for debugging/monitoring (optional)
CREATE TABLE reactive.broadcast_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name TEXT NOT NULL,
    operation TEXT NOT NULL,         -- INSERT, UPDATE, DELETE
    row_id UUID NOT NULL,
    payload JSONB,
    broadcast_at TIMESTAMPTZ DEFAULT now(),
    target_users UUID[]              -- who received this
);
```

### Reactive Table Requirements

Every table in the `reactive` schema must have:

```sql
-- Required columns for reactive tables
id UUID PRIMARY KEY DEFAULT gen_random_uuid(),  -- or gen_random_uuid_v7()
created_at TIMESTAMPTZ DEFAULT now(),
updated_at TIMESTAMPTZ DEFAULT now()
```

---

## Permission Models (Choose One)

### Model 1: Simple RBAC

Users are assigned roles, roles have permissions on tables.

```sql
-- Example: authenticated users can read tasks
INSERT INTO reactive.permissions (role, table_name, can_read)
VALUES ('authenticated', 'tasks', true);

-- Example: admins can read everything
INSERT INTO reactive.permissions (role, table_name, can_read, can_write)
VALUES ('admin', '*', true, true);
```

**Permission Check:**
```sql
CREATE OR REPLACE FUNCTION reactive.can_receive_changes(
    p_user_id UUID,
    p_user_role TEXT,
    p_table_name TEXT,
    p_row JSONB DEFAULT NULL
) RETURNS BOOLEAN AS $$
DECLARE
    v_allowed BOOLEAN := false;
    v_permission RECORD;
BEGIN
    -- Check user-specific permissions first
    SELECT * INTO v_permission
    FROM reactive.permissions
    WHERE (user_id = p_user_id OR role = p_user_role OR role = '*')
      AND (table_name = p_table_name OR table_name = '*')
      AND can_read = true
    LIMIT 1;

    IF v_permission IS NOT NULL THEN
        -- Apply row filter if exists
        IF v_permission.row_filter IS NOT NULL AND p_row IS NOT NULL THEN
            EXECUTE format('SELECT %s', v_permission.row_filter)
            USING p_row
            INTO v_allowed;
        ELSE
            v_allowed := true;
        END IF;
    END IF;

    RETURN v_allowed;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### Model 2: Row-Level Ownership

Each row has an owner, changes are broadcast to the owner.

```sql
-- Add owner column to reactive tables
owner_id UUID REFERENCES auth.users(id)

-- Broadcast logic sends to owner_id's room
```

### Model 3: Tenant/Organization Based

Multi-tenant model where changes broadcast to all users in the same org.

```sql
-- Add tenant column
tenant_id UUID NOT NULL

-- Broadcast to all users with matching tenant_id
```

### Recommendation: Hybrid Model

Combine Model 1 (RBAC) with Model 2 (ownership):

1. **RBAC** controls whether a user can subscribe to a table at all
2. **Row filters** (including ownership) control which specific rows they receive
3. **Room structure** is per-user with server-side filtering

---

## Room/Channel Architecture

### Option A: Per-User Room

Each user has a unique room: `reactive:user:{user_id}`

```
User A (user_123) subscribes to room: reactive:user:user_123
User B (user_456) subscribes to room: reactive:user:user_456

Trigger fires → checks who should receive → broadcasts to each user's room
```

**Pros**: Maximum isolation, simple client logic
**Cons**: Server must track and broadcast to multiple rooms per change

### Option B: Per-Table Room with Client Filtering

Each table has a room: `reactive:table:{table_name}`

```
All users subscribe to: reactive:table:tasks
Trigger fires → broadcasts to table room with metadata
Client filters based on their permissions
```

**Pros**: Single broadcast per change, simpler server logic
**Cons**: Exposes data (client must filter), less secure

### Option C: Per-Table-Per-User Room (Hybrid)

Room format: `reactive:{table}:{user_id}`

```
User A subscribes to: reactive:tasks:user_123
User B subscribes to: reactive:tasks:user_456

Trigger fires → looks up subscribers → broadcasts to relevant rooms
```

**Pros**: Good balance of isolation and efficiency
**Cons**: More complex subscription management

### Recommendation: Per-User Room (Option A)

1. **Security**: Server-side filtering means users never see unauthorized data
2. **Simplicity**: Client just connects to their room, receives all authorized changes
3. **Scalability**: Supabase Realtime handles the fan-out efficiently

---

## Trigger Implementation

### Generic Trigger Function

```sql
CREATE OR REPLACE FUNCTION reactive.broadcast_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_table_name TEXT;
    v_operation TEXT;
    v_row_data JSONB;
    v_row_id UUID;
    v_payload JSONB;
    v_user_id UUID;
    v_subscribers RECORD;
BEGIN
    v_table_name := TG_TABLE_NAME;
    v_operation := TG_OP;

    -- Get row data based on operation
    IF TG_OP = 'DELETE' THEN
        v_row_data := to_jsonb(OLD);
        v_row_id := OLD.id;
    ELSE
        v_row_data := to_jsonb(NEW);
        v_row_id := NEW.id;

        -- Update the updated_at timestamp for UPDATE operations
        IF TG_OP = 'UPDATE' THEN
            NEW.updated_at := now();
        END IF;
    END IF;

    -- Build payload
    v_payload := jsonb_build_object(
        'table', v_table_name,
        'operation', v_operation,
        'row_id', v_row_id,
        'data', v_row_data,
        'timestamp', extract(epoch from now())
    );

    -- Find all users who should receive this change
    FOR v_subscribers IN
        SELECT DISTINCT s.user_id, s.room_id
        FROM reactive.subscriptions s
        JOIN reactive.permissions p ON (
            p.table_name = v_table_name OR p.table_name = '*'
        )
        WHERE s.table_name = v_table_name
          AND p.can_read = true
          AND (p.user_id = s.user_id OR p.role IS NOT NULL)
          -- Add row filter check here
    LOOP
        -- Broadcast to user's room
        PERFORM pg_notify(
            'realtime:broadcast',
            jsonb_build_object(
                'channel', v_subscribers.room_id,
                'event', v_operation,
                'payload', v_payload
            )::text
        );
    END LOOP;

    -- Return appropriate row
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### Auto-Trigger Creation

```sql
CREATE OR REPLACE FUNCTION reactive.setup_table_triggers(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_trigger_name TEXT;
BEGIN
    v_trigger_name := 'reactive_broadcast_' || p_table_name;

    -- Drop existing trigger if exists
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON reactive.%I', v_trigger_name, p_table_name);

    -- Create new trigger
    EXECUTE format($trigger$
        CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON reactive.%I
        FOR EACH ROW
        EXECUTE FUNCTION reactive.broadcast_changes()
    $trigger$, v_trigger_name, p_table_name);
END;
$$ LANGUAGE plpgsql;
```

### Event Trigger for Auto-Setup

```sql
-- Automatically setup triggers when tables are created in reactive schema
CREATE OR REPLACE FUNCTION reactive.on_table_created()
RETURNS event_trigger AS $$
DECLARE
    obj RECORD;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        IF obj.schema_name = 'reactive' AND obj.object_type = 'table' THEN
            PERFORM reactive.setup_table_triggers(obj.object_identity);
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Note: Event triggers require superuser, may not work in hosted Supabase
-- Alternative: Manual trigger setup via helper function
```

---

## Client Integration

### Subscription Flow

```javascript
// Client-side: Subscribe to changes
const channel = supabase.channel('reactive:user:' + userId)
  .on('broadcast', { event: '*' }, (payload) => {
    console.log('Change received:', payload)
    // Handle INSERT, UPDATE, DELETE
  })
  .subscribe()

// Register subscription with server (creates room mapping)
await supabase.rpc('reactive_subscribe', {
  table_name: 'tasks',
  filters: { owner_id: userId }
})
```

### Server-Side Subscription Function

```sql
CREATE OR REPLACE FUNCTION reactive.subscribe(
    p_table_name TEXT,
    p_filters JSONB DEFAULT NULL
) RETURNS TEXT AS $$
DECLARE
    v_user_id UUID;
    v_room_id TEXT;
BEGIN
    -- Get current user from auth context
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    -- Check if user has permission to subscribe to this table
    IF NOT reactive.can_receive_changes(v_user_id, 'authenticated', p_table_name) THEN
        RAISE EXCEPTION 'Permission denied for table %', p_table_name;
    END IF;

    -- Generate room ID
    v_room_id := 'reactive:user:' || v_user_id::text;

    -- Create or update subscription
    INSERT INTO reactive.subscriptions (user_id, table_name, room_id, filters)
    VALUES (v_user_id, p_table_name, v_room_id, p_filters)
    ON CONFLICT (user_id, table_name)
    DO UPDATE SET filters = p_filters, created_at = now();

    RETURN v_room_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## Implementation Phases

### Phase 1: Core Schema & Permissions
- [ ] Create `reactive` schema
- [ ] Create `permissions` table
- [ ] Create `subscriptions` table
- [ ] Create permission check functions

### Phase 2: Trigger System
- [ ] Create generic broadcast trigger function
- [ ] Create helper to setup triggers on tables
- [ ] Test with sample table

### Phase 3: Broadcast Integration
- [ ] Implement `pg_notify` broadcasting
- [ ] Test with Supabase Realtime locally
- [ ] Add `pg_net` fallback for large payloads (optional)

### Phase 4: Client SDK / Helper Functions
- [ ] Create `subscribe` RPC function
- [ ] Create `unsubscribe` RPC function
- [ ] Document client integration

### Phase 5: Utilities & Polish
- [ ] Add audit logging (optional)
- [ ] Add subscription TTL/cleanup
- [ ] Performance testing
- [ ] Documentation

---

## Open Questions

1. **Supabase Realtime Integration**: How exactly does Supabase Realtime listen to `pg_notify`? Do we need a specific channel name format?

2. **RLS Integration**: Should we leverage existing RLS policies instead of a separate permissions table? Could check `has_table_privilege()` or parse RLS policies.

3. **Payload Size**: What happens when a row exceeds `pg_notify`'s 8KB limit? Options:
   - Send just the row ID and let client fetch
   - Use `pg_net` for large payloads
   - Truncate payload with flag for client to fetch full data

4. **Initial Data Sync**: When a user subscribes, should they receive current data or only future changes? Could add a `sync_initial` parameter.

5. **Conflict Resolution**: For offline-first scenarios, how do we handle conflicts? Consider adding vector clocks or last-write-wins timestamp.

6. **Rate Limiting**: Should we add rate limiting to prevent broadcast storms?

---

## Alternative: Leverage Supabase Realtime Postgres Changes

Supabase already has built-in Postgres Changes that listen to WAL via logical replication. Consider:

```javascript
supabase
  .channel('reactive-changes')
  .on('postgres_changes',
    { event: '*', schema: 'reactive', table: 'tasks' },
    (payload) => console.log(payload)
  )
  .subscribe()
```

**Question**: Can we build on top of this with just a permissions layer, rather than rebuilding CDC?

This would simplify to:
1. A permissions table
2. A subscription registration function
3. Client-side SDK that sets up Postgres Changes subscriptions
4. Row-level filtering via RLS

This may be a simpler starting point that leverages existing Supabase infrastructure.

---

## Decision Points Needed

Before implementation, please decide:

1. **Broadcast Method**: `pg_notify` vs `pg_net` vs Postgres Changes
2. **Permission Model**: Simple RBAC vs Row Ownership vs Hybrid
3. **Room Structure**: Per-User vs Per-Table vs Per-Table-Per-User
4. **RLS Integration**: Separate permissions table vs leverage existing RLS
5. **Initial Sync**: Include initial data on subscribe or changes only

---

## File Structure

```
reactive/
├── PLAN.md                           # This file
├── README.md                         # Usage documentation
├── reactive--0.0.1.sql              # Main extension SQL
├── reactive.control                  # Extension control file
└── examples/
    ├── sample_table.sql             # Example reactive table
    └── client_usage.js              # Example client code
```
