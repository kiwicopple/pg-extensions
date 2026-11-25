# Client Library Guide

Complete guide to using `@supabase/reactive` in your applications.

## Installation

```bash
npm install @supabase/reactive
# or
yarn add @supabase/reactive
# or
pnpm add @supabase/reactive
```

## Requirements

- `@supabase/supabase-js` v2.x
- React 18+ (for React hooks)
- Reactive SQL extension installed on your Supabase project

---

## React Hooks

### useReactive

The primary hook for reactive data fetching.

```typescript
function useReactive<T>(
  query: PostgrestFilterBuilder<T>,
  options?: ReactiveOptions<T>
): ReactiveResult<T>
```

#### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | `PostgrestFilterBuilder` | A Supabase query (e.g., `supabase.from('tasks').select('*')`) |
| `options` | `ReactiveOptions` | Configuration options |

#### Options

```typescript
interface ReactiveOptions<T> {
  // Enable optimistic updates (default: false)
  optimistic?: boolean;

  // Callback when initial data loads
  onData?: (data: T[]) => void;

  // Callback when a row is inserted
  onInsert?: (record: T) => void;

  // Callback when a row is updated
  onUpdate?: (newRecord: T, oldRecord: T) => void;

  // Callback when a row is deleted
  onDelete?: (record: T) => void;

  // Callback on any error
  onError?: (error: Error) => void;

  // Custom equality function for deduplication
  isEqual?: (a: T, b: T) => boolean;
}
```

#### Return Value

```typescript
interface ReactiveResult<T> {
  // Current data array
  data: T[];

  // Loading state (true during initial fetch)
  loading: boolean;

  // Error state
  error: Error | null;

  // Insert a new record
  insert: (record: Partial<T>) => Promise<T>;

  // Update an existing record
  update: (id: string, changes: Partial<T>) => Promise<T>;

  // Delete a record
  delete: (id: string) => Promise<void>;

  // Manually refetch data
  refetch: () => Promise<void>;

  // Cleanup subscription
  unsubscribe: () => void;
}
```

---

## Basic Usage

### Simple Query

```typescript
import { useReactive } from '@supabase/reactive';
import { supabase } from './supabase';

function TaskList() {
  const { data: tasks, loading, error } = useReactive(
    supabase.from('tasks').select('*')
  );

  if (loading) return <div>Loading...</div>;
  if (error) return <div>Error: {error.message}</div>;

  return (
    <ul>
      {tasks.map(task => (
        <li key={task.id}>{task.title}</li>
      ))}
    </ul>
  );
}
```

### With Filters

```typescript
function ActiveTasks() {
  const { data: tasks } = useReactive(
    supabase
      .from('tasks')
      .select('*')
      .eq('completed', false)
      .order('created_at', { ascending: false })
  );

  return <TaskList tasks={tasks} />;
}
```

### With Joins

```typescript
function TasksWithComments() {
  const { data: tasks } = useReactive(
    supabase
      .from('tasks')
      .select(`
        *,
        comments (
          id,
          text,
          author:users(name)
        )
      `)
  );

  return <TaskList tasks={tasks} />;
}
```

---

## Mutations

### Insert

```typescript
function AddTaskForm() {
  const { insert } = useReactive(supabase.from('tasks').select('*'));
  const [title, setTitle] = useState('');

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    try {
      await insert({ title, completed: false });
      setTitle('');
    } catch (error) {
      console.error('Failed to add task:', error);
    }
  };

  return (
    <form onSubmit={handleSubmit}>
      <input
        value={title}
        onChange={(e) => setTitle(e.target.value)}
        placeholder="Task title"
      />
      <button type="submit">Add</button>
    </form>
  );
}
```

### Update

```typescript
function TaskItem({ task }: { task: Task }) {
  const { update } = useReactive(supabase.from('tasks').select('*'));

  const toggleComplete = async () => {
    await update(task.id, { completed: !task.completed });
  };

  const rename = async (newTitle: string) => {
    await update(task.id, { title: newTitle });
  };

  return (
    <div>
      <input
        type="checkbox"
        checked={task.completed}
        onChange={toggleComplete}
      />
      <EditableText value={task.title} onSave={rename} />
    </div>
  );
}
```

### Delete

```typescript
function TaskItem({ task }: { task: Task }) {
  const { delete: remove } = useReactive(supabase.from('tasks').select('*'));

  const handleDelete = async () => {
    if (confirm('Delete this task?')) {
      await remove(task.id);
    }
  };

  return (
    <div>
      {task.title}
      <button onClick={handleDelete}>Delete</button>
    </div>
  );
}
```

---

## Optimistic Updates

Enable instant UI feedback while mutations are in flight:

```typescript
function TaskList() {
  const { data: tasks, insert, update, delete: remove } = useReactive(
    supabase.from('tasks').select('*'),
    { optimistic: true }  // Enable optimistic updates
  );

  // UI updates immediately, then syncs with server
  const quickAdd = () => insert({ title: 'New task' });

  return (
    <div>
      <button onClick={quickAdd}>Quick Add</button>
      {tasks.map(task => (
        <TaskItem key={task.id} task={task} />
      ))}
    </div>
  );
}
```

### How Optimistic Updates Work

1. **Insert**: A temporary record with a generated ID is added to `data` immediately
2. **Update**: The local record is updated immediately
3. **Delete**: The record is removed from `data` immediately
4. **On Success**: The temporary record is replaced with the server response
5. **On Error**: The change is rolled back and `onError` is called

### Handling Rollbacks

```typescript
const { insert } = useReactive(
  supabase.from('tasks').select('*'),
  {
    optimistic: true,
    onError: (error) => {
      // Show toast notification
      toast.error(`Operation failed: ${error.message}`);
    }
  }
);
```

---

## Event Callbacks

React to real-time changes from other clients:

```typescript
function CollaborativeEditor() {
  const { data: docs } = useReactive(
    supabase.from('documents').select('*'),
    {
      onInsert: (doc) => {
        toast.info(`New document: ${doc.title}`);
      },
      onUpdate: (newDoc, oldDoc) => {
        if (newDoc.id === currentDocId) {
          // Another user edited the current document
          showConflictDialog(newDoc, oldDoc);
        }
      },
      onDelete: (doc) => {
        if (doc.id === currentDocId) {
          // Current document was deleted
          navigate('/documents');
        }
      }
    }
  );

  // ...
}
```

---

## TypeScript Support

### Type Inference

Types are inferred from your Supabase query:

```typescript
// Types are inferred from your database schema
const { data: tasks } = useReactive(
  supabase.from('tasks').select('id, title, completed')
);
// tasks is typed as { id: string; title: string; completed: boolean }[]
```

### Explicit Types

For complex queries, you can provide explicit types:

```typescript
interface TaskWithComments {
  id: string;
  title: string;
  comments: {
    id: string;
    text: string;
  }[];
}

const { data: tasks } = useReactive<TaskWithComments>(
  supabase.from('tasks').select('id, title, comments(id, text)')
);
```

### Database Types

Use generated types from Supabase CLI:

```typescript
import { Database } from './database.types';

type Task = Database['public']['Tables']['tasks']['Row'];

const { data: tasks } = useReactive<Task>(
  supabase.from('tasks').select('*')
);
```

---

## Non-React Usage

### createReactive

For non-React applications (Vue, Svelte, vanilla JS):

```typescript
import { createReactive } from '@supabase/reactive';

const reactive = createReactive(
  supabase,
  'tasks',
  () => supabase.from('tasks').select('*'),
  {
    onData: (data) => console.log('Initial data:', data),
    onInsert: (record) => console.log('Inserted:', record),
    onUpdate: (newRecord, oldRecord) => console.log('Updated:', newRecord),
    onDelete: (record) => console.log('Deleted:', record),
  }
);

// Access data
console.log(reactive.data);

// Mutations
await reactive.insert({ title: 'New task' });
await reactive.update('task-id', { completed: true });
await reactive.delete('task-id');

// Cleanup when done
reactive.unsubscribe();
```

### Vue Composable Example

```typescript
// useReactive.ts
import { ref, onMounted, onUnmounted } from 'vue';
import { createReactive } from '@supabase/reactive';

export function useReactive<T>(supabase, table, queryBuilder, options = {}) {
  const data = ref<T[]>([]);
  const loading = ref(true);
  const error = ref<Error | null>(null);
  let reactive: ReturnType<typeof createReactive> | null = null;

  onMounted(() => {
    reactive = createReactive(supabase, table, queryBuilder, {
      ...options,
      onData: (d) => {
        data.value = d;
        loading.value = false;
      },
      onInsert: (r) => data.value.push(r),
      onUpdate: (newR) => {
        const idx = data.value.findIndex(i => i.id === newR.id);
        if (idx !== -1) data.value[idx] = newR;
      },
      onDelete: (r) => {
        data.value = data.value.filter(i => i.id !== r.id);
      },
      onError: (e) => error.value = e,
    });
  });

  onUnmounted(() => {
    reactive?.unsubscribe();
  });

  return {
    data,
    loading,
    error,
    insert: (r) => reactive?.insert(r),
    update: (id, c) => reactive?.update(id, c),
    delete: (id) => reactive?.delete(id),
  };
}
```

---

## Advanced Patterns

### Multiple Queries on Same Table

```typescript
function Dashboard() {
  // Active tasks
  const { data: activeTasks } = useReactive(
    supabase.from('tasks').select('*').eq('completed', false)
  );

  // Completed tasks (separate subscription)
  const { data: completedTasks } = useReactive(
    supabase.from('tasks').select('*').eq('completed', true)
  );

  return (
    <div>
      <h2>Active ({activeTasks.length})</h2>
      <TaskList tasks={activeTasks} />

      <h2>Completed ({completedTasks.length})</h2>
      <TaskList tasks={completedTasks} />
    </div>
  );
}
```

### Conditional Subscriptions

```typescript
function UserTasks({ userId }: { userId: string | null }) {
  // Only subscribe when userId is available
  const { data: tasks } = useReactive(
    userId
      ? supabase.from('tasks').select('*').eq('owner_id', userId)
      : null  // Pass null to disable subscription
  );

  if (!userId) return <div>Please log in</div>;

  return <TaskList tasks={tasks ?? []} />;
}
```

### Manual Refetch

```typescript
function TaskList() {
  const { data, refetch, loading } = useReactive(
    supabase.from('tasks').select('*')
  );

  return (
    <div>
      <button onClick={refetch} disabled={loading}>
        {loading ? 'Refreshing...' : 'Refresh'}
      </button>
      {data.map(task => <TaskItem key={task.id} task={task} />)}
    </div>
  );
}
```

---

## Error Handling

### Query Errors

```typescript
function TaskList() {
  const { data, error, refetch } = useReactive(
    supabase.from('tasks').select('*')
  );

  if (error) {
    return (
      <div className="error">
        <p>Failed to load tasks: {error.message}</p>
        <button onClick={refetch}>Retry</button>
      </div>
    );
  }

  return <ul>{data.map(t => <li key={t.id}>{t.title}</li>)}</ul>;
}
```

### Mutation Errors

```typescript
function AddTask() {
  const { insert } = useReactive(supabase.from('tasks').select('*'));
  const [error, setError] = useState<string | null>(null);

  const handleAdd = async () => {
    try {
      setError(null);
      await insert({ title: 'New Task' });
    } catch (err) {
      setError(err.message);
    }
  };

  return (
    <div>
      {error && <p className="error">{error}</p>}
      <button onClick={handleAdd}>Add Task</button>
    </div>
  );
}
```

---

## Performance Tips

1. **Use specific selects**: Only select columns you need
   ```typescript
   // Good
   supabase.from('tasks').select('id, title')

   // Avoid
   supabase.from('tasks').select('*')
   ```

2. **Add filters server-side**: Filter data in the query, not client-side
   ```typescript
   // Good
   supabase.from('tasks').select('*').eq('completed', false)

   // Avoid
   const { data } = useReactive(supabase.from('tasks').select('*'));
   const activeTasks = data.filter(t => !t.completed);
   ```

3. **Use pagination for large datasets**: Limit the number of rows
   ```typescript
   supabase.from('tasks').select('*').range(0, 49)  // First 50 rows
   ```

4. **Clean up subscriptions**: The hook handles this automatically, but ensure components unmount properly
