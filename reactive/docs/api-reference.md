# API Reference

Complete reference for all SQL functions and TypeScript APIs.

---

## SQL Functions

### reactive.enable_realtime()

Enable realtime broadcasts for a table.

```sql
FUNCTION reactive.enable_realtime(
    p_table_schema TEXT,
    p_table_name TEXT
) RETURNS VOID
```

**Parameters:**
- `p_table_schema` - Schema containing the table (e.g., `'public'`)
- `p_table_name` - Name of the table

**Example:**
```sql
SELECT reactive.enable_realtime('public', 'tasks');
```

**Notes:**
- Creates an `AFTER INSERT OR UPDATE OR DELETE` trigger
- Trigger name: `reactive_broadcast_{schema}_{table}`
- Safe to call multiple times (drops existing trigger first)

---

### reactive.disable_realtime()

Disable realtime broadcasts for a table.

```sql
FUNCTION reactive.disable_realtime(
    p_table_schema TEXT,
    p_table_name TEXT
) RETURNS VOID
```

**Parameters:**
- `p_table_schema` - Schema containing the table
- `p_table_name` - Name of the table

**Example:**
```sql
SELECT reactive.disable_realtime('public', 'tasks');
```

---

### reactive.subscribe()

Register a subscription to receive changes.

```sql
FUNCTION reactive.subscribe(
    p_table_schema TEXT,
    p_table_name TEXT,
    p_filters JSONB DEFAULT NULL
) RETURNS TEXT
```

**Parameters:**
- `p_table_schema` - Schema containing the table
- `p_table_name` - Name of the table
- `p_filters` - Optional client-side filters (stored for reference)

**Returns:** The topic/channel name to subscribe to (e.g., `'reactive:user:abc123...'`)

**Example:**
```sql
SELECT reactive.subscribe('public', 'tasks');
-- Returns: 'reactive:user:550e8400-e29b-41d4-a716-446655440000'

SELECT reactive.subscribe('public', 'tasks', '{"status": "active"}');
```

**Errors:**
- `'Authentication required'` - No authenticated user
- `'Permission denied for {schema}.{table}'` - User lacks `can_subscribe` permission

---

### reactive.unsubscribe()

Remove a subscription.

```sql
FUNCTION reactive.unsubscribe(
    p_table_schema TEXT,
    p_table_name TEXT
) RETURNS VOID
```

**Parameters:**
- `p_table_schema` - Schema containing the table
- `p_table_name` - Name of the table

**Example:**
```sql
SELECT reactive.unsubscribe('public', 'tasks');
```

---

### reactive.heartbeat()

Update the `last_seen_at` timestamp for all user's subscriptions.

```sql
FUNCTION reactive.heartbeat() RETURNS VOID
```

**Example:**
```sql
SELECT reactive.heartbeat();
```

**Notes:**
- Call periodically (e.g., every 30 seconds) to keep subscriptions active
- Subscriptions with old `last_seen_at` may be cleaned up by maintenance jobs

---

### reactive.can_subscribe()

Check if current user can subscribe to a table.

```sql
FUNCTION reactive.can_subscribe(
    p_table_schema TEXT,
    p_table_name TEXT,
    p_group_id UUID DEFAULT NULL
) RETURNS BOOLEAN
```

**Parameters:**
- `p_table_schema` - Schema containing the table
- `p_table_name` - Name of the table
- `p_group_id` - Optional group ID to check permission within

**Returns:** `true` if user has permission, `false` otherwise

**Example:**
```sql
SELECT reactive.can_subscribe('public', 'tasks');
-- Returns: true

SELECT reactive.can_subscribe('public', 'admin_logs');
-- Returns: false (if user lacks permission)
```

---

### reactive.user_is_group_member()

Check if current user is a member of a group.

```sql
FUNCTION reactive.user_is_group_member(p_group_id UUID) RETURNS BOOLEAN
```

**Parameters:**
- `p_group_id` - The group ID to check

**Returns:** `true` if user is a member, `false` otherwise

**Example:**
```sql
SELECT reactive.user_is_group_member('550e8400-e29b-41d4-a716-446655440000');
```

---

### reactive.user_has_group_role()

Check if current user has a specific role in a group.

```sql
FUNCTION reactive.user_has_group_role(
    p_group_id UUID,
    p_role TEXT
) RETURNS BOOLEAN
```

**Parameters:**
- `p_group_id` - The group ID
- `p_role` - The role to check (e.g., `'admin'`, `'member'`)

**Returns:** `true` if user has the role, `false` otherwise

**Example:**
```sql
SELECT reactive.user_has_group_role('550e8400-...', 'admin');
```

---

### reactive.get_user_groups()

Get all groups and roles for the current user.

```sql
FUNCTION reactive.get_user_groups()
RETURNS TABLE(group_id UUID, group_name TEXT, role TEXT)
```

**Returns:** A table with columns:
- `group_id` - UUID of the group
- `group_name` - Name of the group
- `role` - User's role in that group

**Example:**
```sql
SELECT * FROM reactive.get_user_groups();
```

**Output:**
| group_id | group_name | role |
|----------|------------|------|
| 550e8400-... | Engineering | admin |
| 6ba7b810-... | Marketing | member |

---

### reactive.get_user_topic()

Get the Realtime topic/channel for a user.

```sql
FUNCTION reactive.get_user_topic(p_user_id UUID DEFAULT NULL) RETURNS TEXT
```

**Parameters:**
- `p_user_id` - User ID (defaults to `auth.uid()` if not provided)

**Returns:** Topic string in format `'reactive:user:{user_id}'`

**Example:**
```sql
SELECT reactive.get_user_topic();
-- Returns: 'reactive:user:550e8400-e29b-41d4-a716-446655440000'

SELECT reactive.get_user_topic('6ba7b810-9dad-11d1-80b4-00c04fd430c8');
-- Returns: 'reactive:user:6ba7b810-9dad-11d1-80b4-00c04fd430c8'
```

---

## TypeScript API

### useReactive (React Hook)

```typescript
function useReactive<T extends { id: string }>(
  query: PostgrestFilterBuilder<any, any, T[]> | null,
  options?: ReactiveOptions<T>
): ReactiveResult<T>
```

#### ReactiveOptions

```typescript
interface ReactiveOptions<T> {
  /**
   * Enable optimistic updates for mutations.
   * When true, UI updates immediately before server confirmation.
   * @default false
   */
  optimistic?: boolean;

  /**
   * Called when initial data is loaded.
   */
  onData?: (data: T[]) => void;

  /**
   * Called when a record is inserted (by any client).
   */
  onInsert?: (record: T) => void;

  /**
   * Called when a record is updated (by any client).
   */
  onUpdate?: (newRecord: T, oldRecord: T) => void;

  /**
   * Called when a record is deleted (by any client).
   */
  onDelete?: (record: T) => void;

  /**
   * Called when an error occurs.
   */
  onError?: (error: Error) => void;

  /**
   * Custom equality function for deduplication.
   * @default (a, b) => a.id === b.id
   */
  isEqual?: (a: T, b: T) => boolean;
}
```

#### ReactiveResult

```typescript
interface ReactiveResult<T> {
  /**
   * Current data array. Empty array during loading.
   */
  data: T[];

  /**
   * True during initial data fetch.
   */
  loading: boolean;

  /**
   * Error from query or subscription, null if none.
   */
  error: Error | null;

  /**
   * Insert a new record.
   * @param record - Partial record data (id is auto-generated)
   * @returns The inserted record from the server
   * @throws PostgrestError on failure
   */
  insert: (record: Partial<T>) => Promise<T>;

  /**
   * Update an existing record.
   * @param id - Record ID
   * @param changes - Fields to update
   * @returns The updated record from the server
   * @throws PostgrestError on failure
   */
  update: (id: string, changes: Partial<T>) => Promise<T>;

  /**
   * Delete a record.
   * @param id - Record ID to delete
   * @throws PostgrestError on failure
   */
  delete: (id: string) => Promise<void>;

  /**
   * Manually refetch data from the server.
   * Useful after connection issues or manual sync.
   */
  refetch: () => Promise<void>;

  /**
   * Cleanup subscription and stop receiving updates.
   * Called automatically on component unmount.
   */
  unsubscribe: () => void;
}
```

---

### createReactive (Non-React)

```typescript
function createReactive<T extends { id: string }>(
  supabase: SupabaseClient,
  tableName: string,
  queryBuilder: () => PostgrestFilterBuilder<any, any, T[]>,
  options?: ReactiveOptions<T>
): ReactiveInstance<T>
```

#### ReactiveInstance

```typescript
interface ReactiveInstance<T> {
  /**
   * Current data array (not reactive - check after callbacks).
   */
  data: T[];

  /**
   * Current loading state.
   */
  loading: boolean;

  /**
   * Current error state.
   */
  error: Error | null;

  /**
   * Insert a new record.
   */
  insert: (record: Partial<T>) => Promise<T>;

  /**
   * Update an existing record.
   */
  update: (id: string, changes: Partial<T>) => Promise<T>;

  /**
   * Delete a record.
   */
  delete: (id: string) => Promise<void>;

  /**
   * Manually refetch data.
   */
  refetch: () => Promise<void>;

  /**
   * Cleanup subscription. MUST be called when done.
   */
  unsubscribe: () => void;
}
```

---

## Broadcast Payload Format

When a change is broadcast, the payload has this structure:

```typescript
interface BroadcastPayload<T> {
  /**
   * The type of operation that triggered the broadcast.
   */
  event: 'INSERT' | 'UPDATE' | 'DELETE';

  /**
   * The schema containing the table.
   */
  schema: string;

  /**
   * The table name.
   */
  table: string;

  /**
   * The new record (for INSERT and UPDATE).
   * Null for DELETE.
   */
  new: T | null;

  /**
   * The old record (for UPDATE and DELETE).
   * Null for INSERT.
   */
  old: T | null;
}
```

**Example payloads:**

INSERT:
```json
{
  "event": "INSERT",
  "schema": "public",
  "table": "tasks",
  "new": { "id": "abc123", "title": "New Task", "completed": false },
  "old": null
}
```

UPDATE:
```json
{
  "event": "UPDATE",
  "schema": "public",
  "table": "tasks",
  "new": { "id": "abc123", "title": "Updated Task", "completed": true },
  "old": { "id": "abc123", "title": "New Task", "completed": false }
}
```

DELETE:
```json
{
  "event": "DELETE",
  "schema": "public",
  "table": "tasks",
  "new": null,
  "old": { "id": "abc123", "title": "Updated Task", "completed": true }
}
```

---

## Error Codes

### SQL Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `Authentication required` | `auth.uid()` is null | Ensure user is logged in |
| `Permission denied for {table}` | Missing `can_subscribe` permission | Add permission to `reactive.permissions` |

### Client Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `Subscription failed` | Server rejected subscription | Check permissions, ensure extension is installed |
| `Connection lost` | WebSocket disconnected | Client auto-reconnects; call `refetch()` if needed |
| `Mutation failed` | Insert/update/delete rejected | Check RLS policies, constraints |

---

## RLS Policy Reference

Required RLS policy for `realtime.messages`:

```sql
CREATE POLICY "Users can receive their broadcasts"
ON realtime.messages
FOR SELECT
TO authenticated
USING (topic = reactive.get_user_topic());
```

This ensures users can only read broadcasts on their own topic.
