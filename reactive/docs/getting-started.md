# Getting Started

This guide walks you through setting up the Reactive extension from scratch.

## Prerequisites

- A Supabase project (local or hosted)
- Basic familiarity with PostgreSQL and Supabase

## Step 1: Install the Extension

Run the SQL extension in your Supabase project:

```sql
-- Option 1: Direct SQL execution
\i reactive--0.0.1.sql

-- Option 2: Via Supabase Dashboard
-- Copy the contents of reactive--0.0.1.sql into the SQL Editor and run
```

This creates:
- The `reactive` schema
- RBAC tables (`groups`, `group_users`, `permissions`)
- Subscription tracking table
- Helper functions and triggers

## Step 2: Create a Group

Groups are organizational units that users belong to. Every user needs to be in at least one group to receive broadcasts.

```sql
-- Create a group for your app
INSERT INTO reactive.groups (id, name)
VALUES ('00000000-0000-0000-0000-000000000001', 'My App')
RETURNING *;
```

## Step 3: Add Users to the Group

When users sign up, add them to the group with a role:

```sql
-- Add a user as a member
INSERT INTO reactive.group_users (group_id, user_id, role)
VALUES (
  '00000000-0000-0000-0000-000000000001',  -- group_id
  'USER_UUID_HERE',                          -- user_id from auth.users
  'member'                                   -- role: owner, admin, member, viewer
);
```

**Tip**: Automate this with a database trigger on `auth.users`:

```sql
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO reactive.group_users (group_id, user_id, role)
  VALUES ('00000000-0000-0000-0000-000000000001', NEW.id, 'member');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
```

## Step 4: Create a Table

Create any table you want to make reactive:

```sql
CREATE TABLE public.tasks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  completed BOOLEAN DEFAULT false,
  owner_id UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;

-- Basic RLS policy
CREATE POLICY "Users can manage their own tasks"
ON public.tasks
FOR ALL
TO authenticated
USING (owner_id = auth.uid())
WITH CHECK (owner_id = auth.uid());
```

## Step 5: Enable Reactive on the Table

```sql
-- Enable realtime broadcasts
SELECT reactive.enable_realtime('public', 'tasks');
```

This creates a trigger that broadcasts changes to subscribed users.

## Step 6: Set Up Permissions

Grant the `member` role permission to subscribe to task changes:

```sql
INSERT INTO reactive.permissions (role, table_schema, table_name, can_subscribe)
VALUES ('member', 'public', 'tasks', true);
```

For row-level filtering (users only see their own tasks):

```sql
INSERT INTO reactive.permissions (role, table_schema, table_name, can_subscribe, row_filter)
VALUES ('member', 'public', 'tasks', true, 'owner_id = auth.uid()');
```

## Step 7: Install the Client Library

```bash
npm install @supabase/reactive
# or
yarn add @supabase/reactive
# or
pnpm add @supabase/reactive
```

## Step 8: Use in Your React App

```typescript
import { createClient } from '@supabase/supabase-js';
import { useReactive } from '@supabase/reactive';

const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
);

function TaskList() {
  const {
    data: tasks,
    loading,
    error,
    insert,
    update,
    delete: remove
  } = useReactive(
    supabase.from('tasks').select('*').order('created_at', { ascending: false }),
    { optimistic: true }
  );

  if (loading) return <div>Loading...</div>;
  if (error) return <div>Error: {error.message}</div>;

  const addTask = async () => {
    await insert({
      title: 'New Task',
      owner_id: (await supabase.auth.getUser()).data.user?.id
    });
  };

  const toggleTask = async (task: Task) => {
    await update(task.id, { completed: !task.completed });
  };

  const deleteTask = async (id: string) => {
    await remove(id);
  };

  return (
    <div>
      <button onClick={addTask}>Add Task</button>
      <ul>
        {tasks.map(task => (
          <li key={task.id}>
            <input
              type="checkbox"
              checked={task.completed}
              onChange={() => toggleTask(task)}
            />
            {task.title}
            <button onClick={() => deleteTask(task.id)}>Delete</button>
          </li>
        ))}
      </ul>
    </div>
  );
}
```

## What Happens Under the Hood

1. **Initial Load**: `useReactive` fetches the initial data and registers a subscription with the server
2. **Subscription**: The client connects to the user's unique Realtime channel (`reactive:user:{user_id}`)
3. **Change Detection**: When data changes, the database trigger fires
4. **Permission Check**: The trigger checks which users should receive the change
5. **Broadcast**: The change is broadcast to authorized users via `realtime.broadcast_changes()`
6. **Client Update**: The client receives the change and updates the local state

## Next Steps

- [Permissions Guide](./permissions.md) - Learn about RBAC and access control
- [Client Library](./client-library.md) - Deep dive into the React hooks
- [API Reference](./api-reference.md) - Complete function documentation
