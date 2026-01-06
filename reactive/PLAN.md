# Reactive Extension for Supabase - Architecture Plan

## Overview

A PostgreSQL extension + TypeScript client library (`@supabase/reactive`) that enables real-time data synchronization via Supabase Realtime Broadcast from Database. Tables in the `reactive` schema automatically capture changes and broadcast them to connected users based on RBAC permissions.

## Decisions Made

| Decision | Choice |
|----------|--------|
| **Broadcast Method** | `realtime.broadcast_changes()` (Database Broadcast via WAL) |
| **Permission Model** | RBAC with Groups (similar to supabase-tenant-rbac) |
| **Room Structure** | Per-User Room |
| **Client SDK** | `@supabase/reactive` with `useReactive()` hook |

---

## Architecture

```
┌─────────────────┐    ┌──────────────────────┐    ┌─────────────────────────────┐
│  Table Change   │───>│  Trigger fires       │───>│ realtime.broadcast_changes()│
│  (INSERT/etc)   │    │  (per-user topics)   │    │ inserts to realtime.messages│
└─────────────────┘    └──────────────────────┘    └─────────────────────────────┘
                                                              │
                                                              v
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         Supabase Realtime Server                                │
│  (reads WAL from realtime.messages, routes to user topics via Broadcast)        │
│  RLS on realtime.messages controls authorization                                │
└─────────────────────────────────────────────────────────────────────────────────┘
                                                              │
                                                              v
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    @supabase/reactive Client Library                            │
│  useReactive(query) → wraps any Supabase query to make it reactive              │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Key Components

1. **Database Extension** (`reactive` schema)
   - RBAC tables (groups, group_users, permissions)
   - Trigger functions using `realtime.broadcast_changes()`
   - Helper functions for subscription management

2. **Client Library** (`@supabase/reactive`)
   - `useReactive(query)` - React hook that makes any query reactive
   - Automatic subscription management
   - Optimistic updates support

---

## Schema Design

### RBAC Tables (inspired by supabase-tenant-rbac)

```sql
CREATE SCHEMA IF NOT EXISTS reactive;

-- Groups/Tenants that users belong to
CREATE TABLE reactive.groups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Junction table: users <-> groups with roles
CREATE TABLE reactive.group_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID NOT NULL REFERENCES reactive.groups(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'member',  -- owner, admin, member, viewer
    created_at TIMESTAMPTZ DEFAULT now(),

    UNIQUE(group_id, user_id)
);

-- Permissions: what roles can do on which tables
CREATE TABLE reactive.permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Scope (at least one required)
    group_id UUID REFERENCES reactive.groups(id) ON DELETE CASCADE,
    role TEXT,                              -- applies to users with this role

    -- Target
    table_schema TEXT NOT NULL DEFAULT 'public',
    table_name TEXT NOT NULL,               -- '*' for all tables

    -- Actions
    can_select BOOLEAN DEFAULT false,
    can_insert BOOLEAN DEFAULT false,
    can_update BOOLEAN DEFAULT false,
    can_delete BOOLEAN DEFAULT false,
    can_subscribe BOOLEAN DEFAULT false,    -- receive realtime updates

    -- Row-level filter (SQL expression evaluated against row data)
    row_filter TEXT,                        -- e.g., 'owner_id = auth.uid()'

    created_at TIMESTAMPTZ DEFAULT now(),

    CONSTRAINT valid_scope CHECK (group_id IS NOT NULL OR role IS NOT NULL)
);

-- Active subscriptions (tracks who is listening to what)
CREATE TABLE reactive.subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    group_id UUID REFERENCES reactive.groups(id) ON DELETE CASCADE,
    table_schema TEXT NOT NULL DEFAULT 'public',
    table_name TEXT NOT NULL,
    topic TEXT NOT NULL,                    -- the realtime topic/channel
    filters JSONB,                          -- client-specified filters
    created_at TIMESTAMPTZ DEFAULT now(),
    last_seen_at TIMESTAMPTZ DEFAULT now(),

    UNIQUE(user_id, table_schema, table_name)
);

-- Indexes for performance
CREATE INDEX idx_group_users_user ON reactive.group_users(user_id);
CREATE INDEX idx_group_users_group ON reactive.group_users(group_id);
CREATE INDEX idx_permissions_group ON reactive.permissions(group_id);
CREATE INDEX idx_permissions_role ON reactive.permissions(role);
CREATE INDEX idx_subscriptions_user ON reactive.subscriptions(user_id);
CREATE INDEX idx_subscriptions_table ON reactive.subscriptions(table_schema, table_name);
```

### Helper Functions

```sql
-- Check if user is member of a group
CREATE OR REPLACE FUNCTION reactive.user_is_group_member(p_group_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM reactive.group_users
        WHERE group_id = p_group_id
          AND user_id = auth.uid()
    );
$$;

-- Check if user has specific role in group
CREATE OR REPLACE FUNCTION reactive.user_has_group_role(p_group_id UUID, p_role TEXT)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM reactive.group_users
        WHERE group_id = p_group_id
          AND user_id = auth.uid()
          AND role = p_role
    );
$$;

-- Get all groups and roles for current user
CREATE OR REPLACE FUNCTION reactive.get_user_groups()
RETURNS TABLE(group_id UUID, group_name TEXT, role TEXT)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT g.id, g.name, gu.role
    FROM reactive.group_users gu
    JOIN reactive.groups g ON g.id = gu.group_id
    WHERE gu.user_id = auth.uid();
$$;

-- Check if user can subscribe to table changes
CREATE OR REPLACE FUNCTION reactive.can_subscribe(
    p_table_schema TEXT,
    p_table_name TEXT,
    p_group_id UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_user_id UUID;
    v_allowed BOOLEAN := false;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN false;
    END IF;

    -- Check permissions
    SELECT true INTO v_allowed
    FROM reactive.permissions p
    LEFT JOIN reactive.group_users gu ON (
        p.group_id = gu.group_id AND gu.user_id = v_user_id
    )
    WHERE p.can_subscribe = true
      AND (p.table_schema = p_table_schema OR p.table_schema = '*')
      AND (p.table_name = p_table_name OR p.table_name = '*')
      AND (
          -- Group-based permission
          (p.group_id IS NOT NULL AND gu.user_id IS NOT NULL AND
           (p_group_id IS NULL OR p.group_id = p_group_id))
          OR
          -- Role-based permission (matches user's role in any group)
          (p.role IS NOT NULL AND EXISTS (
              SELECT 1 FROM reactive.group_users gu2
              WHERE gu2.user_id = v_user_id AND gu2.role = p.role
          ))
      )
    LIMIT 1;

    RETURN COALESCE(v_allowed, false);
END;
$$;

-- Generate topic name for a user (per-user room)
CREATE OR REPLACE FUNCTION reactive.get_user_topic(p_user_id UUID DEFAULT NULL)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT 'reactive:user:' || COALESCE(p_user_id, auth.uid())::text;
$$;
```

---

## Trigger System

### Generic Broadcast Trigger

Uses Supabase's built-in `realtime.broadcast_changes()` function:

```sql
CREATE OR REPLACE FUNCTION reactive.broadcast_table_changes()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_row_data RECORD;
    v_row_id UUID;
    v_subscriber RECORD;
    v_topic TEXT;
    v_row_json JSONB;
BEGIN
    -- Determine the row data based on operation
    IF TG_OP = 'DELETE' THEN
        v_row_data := OLD;
        v_row_id := OLD.id;
    ELSE
        v_row_data := NEW;
        v_row_id := NEW.id;
    END IF;

    v_row_json := to_jsonb(v_row_data);

    -- Find all subscribers who should receive this change
    FOR v_subscriber IN
        SELECT DISTINCT s.user_id, s.topic
        FROM reactive.subscriptions s
        JOIN reactive.permissions p ON (
            (p.table_schema = TG_TABLE_SCHEMA OR p.table_schema = '*')
            AND (p.table_name = TG_TABLE_NAME OR p.table_name = '*')
            AND p.can_subscribe = true
        )
        LEFT JOIN reactive.group_users gu ON (
            p.group_id = gu.group_id AND gu.user_id = s.user_id
        )
        WHERE s.table_schema = TG_TABLE_SCHEMA
          AND s.table_name = TG_TABLE_NAME
          AND (
              -- Group-based permission check
              (p.group_id IS NOT NULL AND gu.user_id IS NOT NULL)
              OR
              -- Role-based permission check
              (p.role IS NOT NULL AND EXISTS (
                  SELECT 1 FROM reactive.group_users gu2
                  WHERE gu2.user_id = s.user_id AND gu2.role = p.role
              ))
          )
          -- Apply row filter if defined
          AND (
              p.row_filter IS NULL
              OR reactive.evaluate_row_filter(p.row_filter, v_row_json, s.user_id)
          )
    LOOP
        -- Broadcast to user's topic using Supabase's built-in function
        PERFORM realtime.broadcast_changes(
            v_subscriber.topic,                      -- topic
            TG_OP,                                   -- event (INSERT, UPDATE, DELETE)
            TG_OP,                                   -- operation
            TG_TABLE_NAME,                           -- table
            TG_TABLE_SCHEMA,                         -- schema
            CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE NEW END,  -- new record
            CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD END   -- old record
        );
    END LOOP;

    -- Return appropriate row
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Helper to evaluate row filters safely
CREATE OR REPLACE FUNCTION reactive.evaluate_row_filter(
    p_filter TEXT,
    p_row JSONB,
    p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    -- Simple filter evaluation (expand as needed)
    -- Supports: owner_id = $user_id, group_id = $group_id, etc.

    IF p_filter IS NULL OR p_filter = '' THEN
        RETURN true;
    END IF;

    -- Handle common patterns
    IF p_filter = 'owner_id = auth.uid()' THEN
        RETURN (p_row->>'owner_id')::uuid = p_user_id;
    END IF;

    -- For more complex filters, use dynamic SQL (with caution)
    -- This is a simplified version - production should sanitize more
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;
```

### Setup Trigger Helper

```sql
CREATE OR REPLACE FUNCTION reactive.enable_realtime(
    p_table_schema TEXT,
    p_table_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_trigger_name TEXT;
    v_full_table TEXT;
BEGIN
    v_trigger_name := 'reactive_broadcast_' || p_table_schema || '_' || p_table_name;
    v_full_table := quote_ident(p_table_schema) || '.' || quote_ident(p_table_name);

    -- Drop existing trigger if exists
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', v_trigger_name, v_full_table);

    -- Create trigger
    EXECUTE format($trigger$
        CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON %s
        FOR EACH ROW
        EXECUTE FUNCTION reactive.broadcast_table_changes()
    $trigger$, v_trigger_name, v_full_table);

    RAISE NOTICE 'Enabled realtime for %.%', p_table_schema, p_table_name;
END;
$$;

-- Disable realtime for a table
CREATE OR REPLACE FUNCTION reactive.disable_realtime(
    p_table_schema TEXT,
    p_table_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_trigger_name TEXT;
    v_full_table TEXT;
BEGIN
    v_trigger_name := 'reactive_broadcast_' || p_table_schema || '_' || p_table_name;
    v_full_table := quote_ident(p_table_schema) || '.' || quote_ident(p_table_name);

    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', v_trigger_name, v_full_table);

    RAISE NOTICE 'Disabled realtime for %.%', p_table_schema, p_table_name;
END;
$$;
```

---

## Subscription Management

```sql
-- Subscribe to table changes (called by client)
CREATE OR REPLACE FUNCTION reactive.subscribe(
    p_table_schema TEXT,
    p_table_name TEXT,
    p_filters JSONB DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID;
    v_topic TEXT;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    -- Check permission
    IF NOT reactive.can_subscribe(p_table_schema, p_table_name) THEN
        RAISE EXCEPTION 'Permission denied for %.%', p_table_schema, p_table_name;
    END IF;

    -- Generate user's topic
    v_topic := reactive.get_user_topic(v_user_id);

    -- Upsert subscription
    INSERT INTO reactive.subscriptions (user_id, table_schema, table_name, topic, filters)
    VALUES (v_user_id, p_table_schema, p_table_name, v_topic, p_filters)
    ON CONFLICT (user_id, table_schema, table_name)
    DO UPDATE SET
        filters = p_filters,
        last_seen_at = now();

    RETURN v_topic;
END;
$$;

-- Unsubscribe from table changes
CREATE OR REPLACE FUNCTION reactive.unsubscribe(
    p_table_schema TEXT,
    p_table_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    DELETE FROM reactive.subscriptions
    WHERE user_id = auth.uid()
      AND table_schema = p_table_schema
      AND table_name = p_table_name;
END;
$$;

-- Heartbeat to keep subscription alive
CREATE OR REPLACE FUNCTION reactive.heartbeat()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE reactive.subscriptions
    SET last_seen_at = now()
    WHERE user_id = auth.uid();
END;
$$;
```

---

## RLS Policies for realtime.messages

```sql
-- Allow authenticated users to receive broadcasts on their topic
CREATE POLICY "Users can receive their broadcasts"
ON realtime.messages
FOR SELECT
TO authenticated
USING (
    -- User can only read messages on their own topic
    topic = reactive.get_user_topic()
);
```

---

## Client Library: @supabase/reactive

### Core API Design

```typescript
// @supabase/reactive

import { SupabaseClient, PostgrestFilterBuilder } from '@supabase/supabase-js';

interface ReactiveOptions<T> {
  // Called when data is initially loaded
  onData?: (data: T[]) => void;
  // Called on INSERT
  onInsert?: (record: T) => void;
  // Called on UPDATE
  onUpdate?: (newRecord: T, oldRecord: T) => void;
  // Called on DELETE
  onDelete?: (record: T) => void;
  // Enable optimistic updates
  optimistic?: boolean;
}

interface ReactiveQuery<T> {
  data: T[];
  loading: boolean;
  error: Error | null;
  // Mutate methods with optional optimistic updates
  insert: (record: Partial<T>) => Promise<T>;
  update: (id: string, changes: Partial<T>) => Promise<T>;
  delete: (id: string) => Promise<void>;
  // Manual refresh
  refetch: () => Promise<void>;
  // Cleanup
  unsubscribe: () => void;
}

// Main hook for React
function useReactive<T>(
  query: PostgrestFilterBuilder<T>,
  options?: ReactiveOptions<T>
): ReactiveQuery<T>;

// Non-React version
function createReactive<T>(
  supabase: SupabaseClient,
  query: PostgrestFilterBuilder<T>,
  options?: ReactiveOptions<T>
): ReactiveQuery<T>;
```

### Usage Example

```typescript
import { useReactive } from '@supabase/reactive';
import { supabase } from './supabase';

function TaskList() {
  const { data: tasks, loading, insert, update, delete: remove } = useReactive(
    supabase.from('tasks').select('*').eq('status', 'active'),
    {
      optimistic: true,
      onInsert: (task) => console.log('New task:', task),
      onUpdate: (newTask, oldTask) => console.log('Updated:', oldTask, '->', newTask),
      onDelete: (task) => console.log('Deleted:', task),
    }
  );

  if (loading) return <div>Loading...</div>;

  return (
    <ul>
      {tasks.map(task => (
        <li key={task.id}>
          {task.title}
          <button onClick={() => update(task.id, { status: 'done' })}>Done</button>
          <button onClick={() => remove(task.id)}>Delete</button>
        </li>
      ))}
      <button onClick={() => insert({ title: 'New Task' })}>Add Task</button>
    </ul>
  );
}
```

### Implementation Sketch

```typescript
// packages/reactive/src/useReactive.ts

import { useEffect, useState, useCallback, useRef } from 'react';
import type { SupabaseClient, RealtimeChannel } from '@supabase/supabase-js';

export function useReactive<T extends { id: string }>(
  supabase: SupabaseClient,
  tableName: string,
  queryBuilder: () => any,
  options: ReactiveOptions<T> = {}
): ReactiveQuery<T> {
  const [data, setData] = useState<T[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);
  const channelRef = useRef<RealtimeChannel | null>(null);
  const topicRef = useRef<string | null>(null);

  // Initial data fetch and subscription setup
  useEffect(() => {
    let mounted = true;

    async function setup() {
      try {
        // 1. Register subscription with server
        const { data: topic, error: subError } = await supabase.rpc('reactive_subscribe', {
          p_table_schema: 'public',
          p_table_name: tableName,
          p_filters: null,
        });

        if (subError) throw subError;
        topicRef.current = topic;

        // 2. Fetch initial data
        const { data: initialData, error: fetchError } = await queryBuilder();
        if (fetchError) throw fetchError;

        if (mounted) {
          setData(initialData || []);
          setLoading(false);
          options.onData?.(initialData || []);
        }

        // 3. Set up realtime subscription
        channelRef.current = supabase
          .channel(topic)
          .on('broadcast', { event: 'INSERT' }, ({ payload }) => {
            if (!mounted) return;
            const newRecord = payload.new as T;
            setData(prev => [...prev, newRecord]);
            options.onInsert?.(newRecord);
          })
          .on('broadcast', { event: 'UPDATE' }, ({ payload }) => {
            if (!mounted) return;
            const newRecord = payload.new as T;
            const oldRecord = payload.old as T;
            setData(prev => prev.map(item =>
              item.id === newRecord.id ? newRecord : item
            ));
            options.onUpdate?.(newRecord, oldRecord);
          })
          .on('broadcast', { event: 'DELETE' }, ({ payload }) => {
            if (!mounted) return;
            const deletedRecord = payload.old as T;
            setData(prev => prev.filter(item => item.id !== deletedRecord.id));
            options.onDelete?.(deletedRecord);
          })
          .subscribe();

      } catch (err) {
        if (mounted) {
          setError(err as Error);
          setLoading(false);
        }
      }
    }

    setup();

    // Cleanup
    return () => {
      mounted = false;
      if (channelRef.current) {
        supabase.removeChannel(channelRef.current);
      }
      // Unsubscribe from server
      supabase.rpc('reactive_unsubscribe', {
        p_table_schema: 'public',
        p_table_name: tableName,
      });
    };
  }, [tableName]);

  // Mutation methods
  const insert = useCallback(async (record: Partial<T>) => {
    if (options.optimistic) {
      const optimisticRecord = { ...record, id: crypto.randomUUID() } as T;
      setData(prev => [...prev, optimisticRecord]);
    }

    const { data: inserted, error } = await supabase
      .from(tableName)
      .insert(record)
      .select()
      .single();

    if (error) {
      // Rollback optimistic update
      if (options.optimistic) {
        setData(prev => prev.filter(item => item.id !== (record as any).id));
      }
      throw error;
    }

    return inserted;
  }, [tableName, options.optimistic]);

  const update = useCallback(async (id: string, changes: Partial<T>) => {
    if (options.optimistic) {
      setData(prev => prev.map(item =>
        item.id === id ? { ...item, ...changes } : item
      ));
    }

    const { data: updated, error } = await supabase
      .from(tableName)
      .update(changes)
      .eq('id', id)
      .select()
      .single();

    if (error) throw error;
    return updated;
  }, [tableName, options.optimistic]);

  const remove = useCallback(async (id: string) => {
    let removedItem: T | undefined;

    if (options.optimistic) {
      setData(prev => {
        removedItem = prev.find(item => item.id === id);
        return prev.filter(item => item.id !== id);
      });
    }

    const { error } = await supabase
      .from(tableName)
      .delete()
      .eq('id', id);

    if (error) {
      // Rollback
      if (options.optimistic && removedItem) {
        setData(prev => [...prev, removedItem!]);
      }
      throw error;
    }
  }, [tableName, options.optimistic]);

  const refetch = useCallback(async () => {
    setLoading(true);
    const { data: freshData, error } = await queryBuilder();
    if (error) {
      setError(error);
    } else {
      setData(freshData || []);
    }
    setLoading(false);
  }, [queryBuilder]);

  const unsubscribe = useCallback(() => {
    if (channelRef.current) {
      supabase.removeChannel(channelRef.current);
      channelRef.current = null;
    }
  }, []);

  return {
    data,
    loading,
    error,
    insert,
    update,
    delete: remove,
    refetch,
    unsubscribe,
  };
}
```

---

## Implementation Phases

### Phase 1: Core SQL Extension
- [ ] Create `reactive` schema
- [ ] Create RBAC tables (groups, group_users, permissions)
- [ ] Create subscriptions table
- [ ] Create helper functions (user_is_group_member, can_subscribe, etc.)
- [ ] Create broadcast trigger function
- [ ] Create enable_realtime/disable_realtime helpers
- [ ] Set up RLS on realtime.messages

### Phase 2: Testing with Sample App
- [ ] Create sample table with reactive enabled
- [ ] Set up test permissions
- [ ] Test broadcast flow end-to-end
- [ ] Verify RLS authorization works

### Phase 3: TypeScript Client Library
- [ ] Set up package structure (`packages/reactive`)
- [ ] Implement core `createReactive` function
- [ ] Implement React `useReactive` hook
- [ ] Add optimistic update support
- [ ] Add TypeScript types

### Phase 4: Documentation & Examples
- [ ] README for SQL extension
- [ ] README for client library
- [ ] Example: Todo app
- [ ] Example: Collaborative document

### Phase 5: Advanced Features (Future)
- [ ] Subscription TTL and cleanup cron
- [ ] Audit logging
- [ ] Rate limiting
- [ ] Offline support / conflict resolution
- [ ] Vue/Svelte adapters

---

## File Structure

```
reactive/
├── PLAN.md                              # This file
├── README.md                            # Extension documentation
├── reactive--0.0.1.sql                  # Main SQL extension
├── reactive.control                     # Extension control file
│
├── packages/
│   └── reactive/                        # @supabase/reactive npm package
│       ├── package.json
│       ├── tsconfig.json
│       ├── src/
│       │   ├── index.ts
│       │   ├── createReactive.ts
│       │   ├── useReactive.ts           # React hook
│       │   └── types.ts
│       └── README.md
│
└── examples/
    ├── todo-app/                        # Example React app
    └── setup.sql                        # Sample tables + permissions
```

---

## Open Questions (Deferred)

1. **Initial Sync**: Should `useReactive` fetch initial data, or expect it to be passed in?
   - Current: Fetches initial data automatically

2. **Large Payloads**: What if a row exceeds limits?
   - Could send just ID and let client fetch
   - Or use `pg_net` HTTP fallback

3. **Offline Support**: How to handle reconnection and sync?
   - Future: Add conflict resolution, last-write-wins or vector clocks

4. **Heartbeat Frequency**: How often should clients send heartbeat?
   - Suggestion: Every 30 seconds

5. **Subscription Cleanup**: Cron job to remove stale subscriptions?
   - Suggestion: Remove subscriptions not seen in 24 hours
