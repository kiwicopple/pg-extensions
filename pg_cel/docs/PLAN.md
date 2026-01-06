# CEL Authorization PostgreSQL Extension - Implementation Plan

## Overview

This document outlines the plan for creating a CEL (Common Expression Language) compatible authorization PostgreSQL extension that developers can use for fine-grained access control, particularly within Row Level Security (RLS) policies.

## Goals

1. **CEL-Compatible Syntax**: Support common CEL expressions for authorization decisions
2. **RLS Integration**: All functions must be usable inside RLS policies (STABLE/IMMUTABLE)
3. **JWT Support**: Parse and validate JWT claims (common in modern auth systems like Supabase Auth)
4. **RBAC Support**: Role-based access control primitives
5. **ABAC Support**: Attribute-based access control using CEL expressions
6. **Pure PL/pgSQL**: No external dependencies, compatible with Trusted Language Extensions (TLE)

---

## Architecture

### Extension Structure

```
pg_cel/
├── pg_cel.control              # Extension metadata
├── pg_cel--0.0.1.sql           # Main extension (v0.0.1)
├── docs/
│   ├── PLAN.md                 # This file
│   └── USAGE.md                # Usage examples
└── tests/
    └── test_pg_cel.sql         # Test suite
```

### Core Components

```
┌─────────────────────────────────────────────────────────────────┐
│                         pg_cel Extension                         │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │  JWT Functions  │  │  CEL Evaluator  │  │ Policy Manager  │  │
│  │                 │  │                 │  │                 │  │
│  │ - cel.jwt()     │  │ - cel.eval()    │  │ - cel.check()   │  │
│  │ - cel.claim()   │  │ - cel.match()   │  │ - cel.permit()  │  │
│  │ - cel.claims()  │  │ - cel.test()    │  │ - cel.deny()    │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
│                                                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │ RBAC Functions  │  │ ABAC Functions  │  │ Helper Functions│  │
│  │                 │  │                 │  │                 │  │
│  │ - cel.has_role()│  │ - cel.has_attr()│  │ - cel.current() │  │
│  │ - cel.has_any() │  │ - cel.attr_in() │  │ - cel.context() │  │
│  │ - cel.has_all() │  │ - cel.compare() │  │ - cel.debug()   │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Implementation Plan

### Phase 1: Core Infrastructure

#### 1.1 Schema Setup
- Create `cel` schema for namespacing all functions
- Optional: Create configuration table for extension settings

#### 1.2 JWT Parsing Functions

```sql
-- Extract the full JWT payload from request headers (Supabase-compatible)
cel.jwt() -> jsonb

-- Get a specific claim from the JWT
cel.claim(claim_name text) -> text
cel.claim(claim_name text, default_value text) -> text

-- Get nested claim using dot notation: 'app_metadata.role'
cel.claim_path(path text) -> jsonb

-- Get all claims as JSONB
cel.claims() -> jsonb

-- Get the authenticated user's ID (sub claim)
cel.uid() -> uuid
cel.user_id() -> uuid  -- alias
```

#### 1.3 Context Functions

```sql
-- Get current request context
cel.current_user_id() -> uuid
cel.current_role() -> text
cel.current_roles() -> text[]

-- Set/get custom context variables (for testing)
cel.set_context(key text, value text) -> void
cel.get_context(key text) -> text
```

### Phase 2: CEL Expression Evaluator

#### 2.1 Supported CEL Syntax

The evaluator will support a subset of CEL that covers common authorization patterns:

```cel
# Comparison operators
resource.owner_id == request.auth.uid
resource.status in ['active', 'pending']
request.auth.claims.role == 'admin'

# Logical operators
resource.public || resource.owner_id == request.auth.uid
request.auth.claims.role == 'admin' && resource.tenant_id == request.auth.claims.tenant_id

# Collection operations
'admin' in request.auth.claims.roles
resource.tags.exists(t, t == 'public')
request.auth.claims.permissions.all(p, p.startsWith('read:'))

# String operations
resource.name.startsWith('public_')
resource.email.endsWith('@company.com')
resource.path.matches('^/api/v[0-9]+/')

# Null checks
resource.deleted_at == null
has(resource.metadata.special_flag)
```

#### 2.2 CEL Evaluation Functions

```sql
-- Evaluate a CEL expression with context
cel.eval(
    expression text,
    context jsonb DEFAULT '{}'
) -> boolean

-- Evaluate with resource and request objects (common pattern)
cel.eval_policy(
    expression text,
    resource jsonb,
    request jsonb DEFAULT NULL  -- uses current request if NULL
) -> boolean

-- Test an expression (returns detailed result for debugging)
cel.test(
    expression text,
    context jsonb DEFAULT '{}'
) -> jsonb  -- {result: bool, error: text, trace: jsonb}
```

#### 2.3 Expression Parsing Strategy

Since we're limited to PL/pgSQL, implement a simplified recursive descent parser:

1. **Tokenizer**: Split expression into tokens
2. **Parser**: Build simple AST as JSONB
3. **Evaluator**: Walk AST and evaluate against context

Support these token types:
- Identifiers: `resource`, `request.auth.uid`
- Operators: `==`, `!=`, `<`, `>`, `<=`, `>=`, `in`, `&&`, `||`, `!`
- Literals: strings, numbers, booleans, null
- Functions: `startsWith`, `endsWith`, `matches`, `has`, `exists`, `all`

### Phase 3: RBAC Functions

#### 3.1 Role Check Functions

```sql
-- Check if current user has a specific role
cel.has_role(role_name text) -> boolean

-- Check if user has any of the specified roles
cel.has_any_role(role_names text[]) -> boolean
cel.has_any_role(VARIADIC role_names text[]) -> boolean

-- Check if user has all specified roles
cel.has_all_roles(role_names text[]) -> boolean

-- Get user's roles from JWT claims
cel.get_roles() -> text[]
cel.get_roles(claim_path text) -> text[]  -- custom claim path
```

#### 3.2 Permission Check Functions

```sql
-- Check specific permission
cel.has_permission(permission text) -> boolean

-- Check with resource type
cel.can(action text, resource_type text) -> boolean

-- Examples:
-- cel.can('read', 'documents')
-- cel.can('write', 'users')
-- cel.has_permission('documents:read')
```

### Phase 4: ABAC Functions

#### 4.1 Attribute Comparison Functions

```sql
-- Check if a resource attribute matches a condition
cel.attr_equals(
    resource_value anyelement,
    expected_value anyelement
) -> boolean

-- Check if resource attribute is in a list
cel.attr_in(
    resource_value anyelement,
    allowed_values anyarray
) -> boolean

-- Compare with user attribute from JWT
cel.attr_matches_claim(
    resource_attr anyelement,
    claim_path text
) -> boolean
```

#### 4.2 Ownership Functions

```sql
-- Check if current user owns the resource
cel.is_owner(owner_id uuid) -> boolean
cel.is_owner(owner_id text) -> boolean

-- Check ownership with custom user ID field
cel.is_owner(owner_id uuid, user_id_claim text) -> boolean
```

### Phase 5: RLS Policy Helpers

#### 5.1 Pre-built Policy Functions

```sql
-- Owner-only access
cel.policy_owner_only(owner_id uuid) -> boolean

-- Role-based access
cel.policy_role_required(required_role text) -> boolean
cel.policy_roles_any(required_roles text[]) -> boolean

-- Combined owner OR role
cel.policy_owner_or_role(owner_id uuid, role text) -> boolean

-- Tenant isolation
cel.policy_tenant_match(tenant_id uuid) -> boolean
cel.policy_tenant_match(tenant_id uuid, claim_path text) -> boolean

-- Public + authenticated access
cel.policy_public_or_authenticated(is_public boolean) -> boolean

-- Time-based access
cel.policy_not_expired(expires_at timestamptz) -> boolean
cel.policy_within_window(start_at timestamptz, end_at timestamptz) -> boolean
```

#### 5.2 Composite Policy Builder

```sql
-- Build complex policies from simple rules
cel.policy_all(VARIADIC conditions boolean[]) -> boolean  -- AND
cel.policy_any(VARIADIC conditions boolean[]) -> boolean  -- OR

-- Example usage in RLS:
-- CREATE POLICY "users_policy" ON users
-- USING (
--     cel.policy_any(
--         cel.is_owner(id),
--         cel.has_role('admin'),
--         cel.policy_tenant_match(tenant_id)
--     )
-- );
```

### Phase 6: Stored Policies (Optional)

#### 6.1 Policy Storage Table

```sql
CREATE TABLE cel.policies (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text UNIQUE NOT NULL,
    description text,
    expression text NOT NULL,
    resource_type text,
    action text,  -- 'select', 'insert', 'update', 'delete', '*'
    enabled boolean DEFAULT true,
    priority int DEFAULT 0,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);
```

#### 6.2 Policy Management Functions

```sql
-- Create/update a stored policy
cel.create_policy(
    name text,
    expression text,
    resource_type text DEFAULT '*',
    action text DEFAULT '*',
    description text DEFAULT NULL
) -> uuid

-- Evaluate a stored policy
cel.check_policy(policy_name text, context jsonb) -> boolean

-- Check all applicable policies for a resource/action
cel.authorize(
    resource_type text,
    action text,
    context jsonb DEFAULT '{}'
) -> boolean
```

---

## RLS Integration Examples

### Example 1: Simple Owner-Based Access

```sql
-- Enable RLS
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

-- Policy using pg_cel
CREATE POLICY "documents_owner_policy" ON documents
    FOR ALL
    USING (cel.is_owner(owner_id))
    WITH CHECK (cel.is_owner(owner_id));
```

### Example 2: Role-Based Access

```sql
CREATE POLICY "admin_full_access" ON users
    FOR ALL
    USING (cel.has_role('admin'));

CREATE POLICY "users_read_own" ON users
    FOR SELECT
    USING (cel.is_owner(id) OR cel.has_role('admin'));
```

### Example 3: CEL Expression-Based Policy

```sql
CREATE POLICY "documents_cel_policy" ON documents
    FOR SELECT
    USING (
        cel.eval(
            'resource.public == true || resource.owner_id == request.auth.uid || "admin" in request.auth.roles',
            jsonb_build_object(
                'resource', jsonb_build_object(
                    'public', is_public,
                    'owner_id', owner_id
                )
            )
        )
    );
```

### Example 4: Multi-Tenant with Department Access

```sql
CREATE POLICY "tenant_department_policy" ON resources
    FOR ALL
    USING (
        cel.policy_all(
            cel.policy_tenant_match(tenant_id),
            cel.attr_in(department, cel.claim_path('app_metadata.departments')::text[])
        )
    );
```

### Example 5: Time-Windowed Access

```sql
CREATE POLICY "scheduled_content" ON content
    FOR SELECT
    USING (
        cel.policy_all(
            cel.policy_within_window(publish_at, expire_at),
            cel.policy_any(
                cel.is_owner(author_id),
                cel.has_role('editor'),
                is_published
            )
        )
    );
```

---

## Function Volatility for RLS Compatibility

All functions must be marked appropriately for RLS:

| Function Type | Volatility | Reason |
|--------------|------------|--------|
| JWT parsing | STABLE | Reads from session, consistent within transaction |
| Role checks | STABLE | Depends on JWT which is stable per request |
| Attribute comparisons | IMMUTABLE | Pure comparison functions |
| Policy evaluation | STABLE | May read JWT/context |
| Time-based checks | STABLE | Uses current_timestamp |

---

## Security Considerations

1. **SQL Injection Prevention**: All CEL expressions are parsed, not executed as SQL
2. **JWT Validation**: Rely on upstream validation (e.g., Supabase Auth, PostgREST)
3. **Expression Complexity Limits**: Implement max depth/complexity to prevent DoS
4. **No Dynamic SQL**: CEL evaluator uses pure PL/pgSQL logic, no EXECUTE
5. **Audit Logging**: Optional logging of policy evaluations for compliance

---

## Testing Strategy

### Unit Tests
- JWT parsing with various claim structures
- CEL expression parsing and evaluation
- Each RBAC/ABAC function
- Edge cases: null values, empty arrays, missing claims

### Integration Tests
- RLS policies with pg_cel functions
- Multi-table scenarios
- Performance benchmarks

### Test File Structure

```sql
-- tests/test_pg_cel.sql
BEGIN;
SELECT plan(50);  -- Using pgTAP

-- JWT tests
SELECT is(cel.claim('sub'), 'user-123', 'Can extract sub claim');
SELECT is(cel.uid()::text, 'user-123', 'uid() returns sub as uuid');

-- Role tests
SELECT ok(cel.has_role('admin'), 'Admin role check');
SELECT ok(NOT cel.has_role('superadmin'), 'Missing role check');

-- CEL evaluation tests
SELECT ok(cel.eval('1 == 1'), 'Simple equality');
SELECT ok(cel.eval('"admin" in roles', '{"roles": ["admin", "user"]}'::jsonb), 'In operator');

SELECT * FROM finish();
ROLLBACK;
```

---

## Implementation Order

1. **Week 1**: Core infrastructure
   - Schema setup
   - JWT parsing functions
   - Basic context functions

2. **Week 2**: RBAC functions
   - Role checking
   - Permission checking
   - Pre-built policy helpers

3. **Week 3**: CEL evaluator
   - Tokenizer
   - Parser
   - Basic expression evaluation

4. **Week 4**: Advanced features
   - ABAC functions
   - Stored policies (optional)
   - Full CEL operator support

5. **Week 5**: Testing & documentation
   - Comprehensive test suite
   - Usage documentation
   - Performance optimization

---

## Dependencies

- **Required**: PostgreSQL 14+ (for improved JSON handling)
- **Optional**: pgTAP (for testing)
- **No external dependencies**: Pure PL/pgSQL implementation

---

## Future Enhancements

1. **Policy Caching**: Cache compiled CEL expressions
2. **Policy Inheritance**: Hierarchical policies
3. **Audit Trail**: Log all policy evaluations
4. **Policy Simulation**: Test policies without enforcement
5. **IDE Integration**: VS Code extension for CEL syntax highlighting
6. **Performance Metrics**: Track policy evaluation times

---

## References

- [CEL Specification](https://github.com/google/cel-spec)
- [PostgreSQL RLS Documentation](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- [Supabase Auth](https://supabase.com/docs/guides/auth)
- [Google IAM CEL](https://cloud.google.com/iam/docs/conditions-overview)
