# Reactive Extension Documentation

Developer documentation for the Supabase Reactive extension.

## Overview

The Reactive extension enables real-time data synchronization for Supabase applications. It provides:

- **Automatic CDC**: Database triggers capture INSERT, UPDATE, DELETE operations
- **Realtime Broadcast**: Changes are pushed to connected clients via Supabase Realtime
- **RBAC Permissions**: Fine-grained control over who receives which changes
- **Per-User Channels**: Secure, isolated channels for each user

## Architecture

```
┌─────────────┐     ┌─────────────────┐     ┌──────────────────────────┐
│ Your Table  │────>│ Trigger fires   │────>│ realtime.broadcast_changes│
└─────────────┘     └─────────────────┘     └──────────────────────────┘
                                                       │
                                                       v
                           ┌───────────────────────────────────────────┐
                           │        Supabase Realtime Server           │
                           │   (reads WAL, routes to user channels)    │
                           └───────────────────────────────────────────┘
                                                       │
                                                       v
                           ┌───────────────────────────────────────────┐
                           │     @supabase/reactive Client Library     │
                           │        useReactive() React Hook           │
                           └───────────────────────────────────────────┘
```

## Documentation

| Document | Description |
|----------|-------------|
| [Getting Started](./getting-started.md) | Quick start guide |
| [Architecture: Routing](./architecture-routing.md) | **How changes route to users** |
| [SQL Extension](./sql-extension.md) | Database setup and configuration |
| [Permissions](./permissions.md) | RBAC and access control |
| [Client Library](./client-library.md) | TypeScript/React integration |
| [API Reference](./api-reference.md) | Complete function reference |

## Quick Example

### 1. Enable reactive on a table

```sql
-- Enable realtime broadcasts for your table
SELECT reactive.enable_realtime('public', 'tasks');

-- Grant subscription permission to authenticated users
INSERT INTO reactive.permissions (role, table_schema, table_name, can_subscribe)
VALUES ('member', 'public', 'tasks', true);
```

### 2. Subscribe from your React app

```typescript
import { useReactive } from '@supabase/reactive';

function TaskList() {
  const { data: tasks, insert, update, delete: remove } = useReactive(
    supabase.from('tasks').select('*'),
    { optimistic: true }
  );

  return (
    <ul>
      {tasks.map(task => (
        <li key={task.id}>{task.title}</li>
      ))}
    </ul>
  );
}
```

### 3. Changes sync automatically

When any client inserts, updates, or deletes a task, all subscribed clients receive the change in real-time.

## Requirements

- Supabase project with Realtime enabled
- PostgreSQL 14+
- `realtime` schema with `broadcast_changes` function (included in Supabase)

## Installation

```sql
-- Run the reactive extension SQL
\i reactive--0.0.1.sql
```

Or via dbdev:

```bash
dbdev install reactive
```
