# pg_cel

A CEL (Common Expression Language) compatible authorization extension for PostgreSQL, designed to work seamlessly with Row Level Security (RLS) policies.

## Overview

`pg_cel` provides a set of PostgreSQL functions that enable fine-grained access control using patterns inspired by Google's [Common Expression Language](https://github.com/google/cel-spec). It's built specifically for modern authentication systems like Supabase Auth, Firebase, or any JWT-based auth provider.

## Features

- **JWT Parsing**: Extract claims from JWT tokens in request headers
- **CEL Expression Evaluation**: Evaluate authorization expressions using CEL-like syntax
- **RBAC Functions**: Role-based access control helpers
- **ABAC Functions**: Attribute-based access control for complex policies
- **RLS-Compatible**: All functions are designed to work inside PostgreSQL RLS policies
- **Pure PL/pgSQL**: No external dependencies, works with Trusted Language Extensions (TLE)

## Installation

### Using dbdev (database.dev)

```bash
# Install the extension
dbdev install pg_cel

# Enable in your database
psql -c "CREATE EXTENSION pg_cel;"
```

### Manual Installation

```sql
CREATE EXTENSION pg_cel;
```

## Quick Start

### 1. Basic Owner Check

```sql
-- Enable RLS on your table
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

-- Create a policy that only allows owners to access their documents
CREATE POLICY "owner_access" ON documents
    FOR ALL
    USING (cel.is_owner(owner_id));
```

### 2. Role-Based Access

```sql
-- Allow admins full access, users can only read
CREATE POLICY "admin_full_access" ON users
    FOR ALL
    USING (cel.has_role('admin'));

CREATE POLICY "user_read_own" ON users
    FOR SELECT
    USING (cel.is_owner(id));
```

### 3. Complex Policies with CEL Expressions

```sql
-- Allow access if: public OR owner OR admin
CREATE POLICY "document_access" ON documents
    FOR SELECT
    USING (
        cel.eval(
            'resource.public == true || resource.owner_id == request.auth.uid || "admin" in request.auth.roles',
            jsonb_build_object('resource', jsonb_build_object(
                'public', is_public,
                'owner_id', owner_id
            ))
        )
    );
```

## API Reference

### JWT Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `cel.jwt()` | `jsonb` | Get the full JWT payload |
| `cel.claim(name text)` | `text` | Get a specific claim value |
| `cel.claim_path(path text)` | `jsonb` | Get nested claim (e.g., `'app_metadata.role'`) |
| `cel.claims()` | `jsonb` | Get all claims as JSONB |
| `cel.uid()` | `uuid` | Get the authenticated user's ID (`sub` claim) |

### RBAC Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `cel.has_role(role text)` | `boolean` | Check if user has a specific role |
| `cel.has_any_role(roles text[])` | `boolean` | Check if user has any of the roles |
| `cel.has_all_roles(roles text[])` | `boolean` | Check if user has all roles |
| `cel.get_roles()` | `text[]` | Get user's roles from JWT |
| `cel.has_permission(perm text)` | `boolean` | Check for a specific permission |
| `cel.can(action, resource)` | `boolean` | Check action permission on resource type |

### ABAC Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `cel.is_owner(owner_id)` | `boolean` | Check if current user owns the resource |
| `cel.attr_equals(val, expected)` | `boolean` | Compare attribute values |
| `cel.attr_in(val, allowed[])` | `boolean` | Check if value is in allowed list |
| `cel.attr_matches_claim(val, path)` | `boolean` | Compare resource attr with JWT claim |

### Policy Helpers

| Function | Returns | Description |
|----------|---------|-------------|
| `cel.policy_owner_only(owner_id)` | `boolean` | Owner-only access |
| `cel.policy_role_required(role)` | `boolean` | Require specific role |
| `cel.policy_owner_or_role(id, role)` | `boolean` | Owner OR role access |
| `cel.policy_tenant_match(tenant_id)` | `boolean` | Multi-tenant isolation |
| `cel.policy_not_expired(expires_at)` | `boolean` | Time-based expiration |
| `cel.policy_all(...)` | `boolean` | AND multiple conditions |
| `cel.policy_any(...)` | `boolean` | OR multiple conditions |

### CEL Evaluation

| Function | Returns | Description |
|----------|---------|-------------|
| `cel.eval(expr, context)` | `boolean` | Evaluate a CEL expression |
| `cel.test(expr, context)` | `jsonb` | Test expression with debug info |

## CEL Expression Syntax

The evaluator supports a subset of CEL syntax:

```cel
# Comparison
resource.owner_id == request.auth.uid
resource.priority > 5
resource.status != 'deleted'

# Logical operators
condition1 && condition2
condition1 || condition2
!condition

# Membership
'admin' in request.auth.roles
resource.status in ['active', 'pending']

# String functions
resource.name.startsWith('public_')
resource.email.endsWith('@company.com')

# Null checks
resource.deleted_at == null
has(resource.metadata)
```

## Examples

### Multi-Tenant SaaS Application

```sql
-- Isolate data by tenant
CREATE POLICY "tenant_isolation" ON resources
    FOR ALL
    USING (cel.policy_tenant_match(tenant_id));
```

### Content Publishing System

```sql
-- Published content is public, drafts only for authors/editors
CREATE POLICY "content_access" ON articles
    FOR SELECT
    USING (
        cel.policy_any(
            status = 'published',
            cel.is_owner(author_id),
            cel.has_role('editor')
        )
    );
```

### Hierarchical Permissions

```sql
-- Admins > Managers > Users
CREATE POLICY "hierarchical_access" ON sensitive_data
    FOR ALL
    USING (
        cel.has_any_role(ARRAY['admin', 'manager'])
    );
```

### Time-Limited Access

```sql
-- Access only during valid time window
CREATE POLICY "time_limited" ON promotions
    FOR SELECT
    USING (
        cel.policy_all(
            cel.policy_within_window(starts_at, ends_at),
            is_active
        )
    );
```

## Supabase Integration

`pg_cel` is designed to work with Supabase Auth. The JWT functions automatically read from the `request.jwt.claims` provided by PostgREST/Supabase.

```sql
-- Works automatically with Supabase Auth
CREATE POLICY "supabase_policy" ON profiles
    FOR ALL
    USING (cel.uid() = id);
```

## Performance Considerations

- All functions are marked as `STABLE` or `IMMUTABLE` for optimal RLS performance
- JWT parsing is cached per-transaction
- CEL expressions are evaluated efficiently without dynamic SQL

## Security

- CEL expressions are parsed, not executed as SQL (no SQL injection risk)
- Expression complexity is limited to prevent DoS
- Relies on upstream JWT validation (Supabase Auth, etc.)

## Requirements

- PostgreSQL 14+
- For Supabase: Works out of the box with Supabase Auth

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please see the [PLAN.md](docs/PLAN.md) for the implementation roadmap.
