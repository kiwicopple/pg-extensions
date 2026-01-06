# pg_abac - Attribute-Based Access Control PostgreSQL Extension

## Overview

`pg_abac` is a PostgreSQL Trusted Language Extension (TLE) that implements Attribute-Based Access Control (ABAC) directly in the database. It provides a flexible, policy-driven authorization system that works seamlessly with PostgreSQL's Row Level Security (RLS).

## ABAC Core Concepts

ABAC makes access decisions based on four categories of attributes:

1. **Subject** - The entity requesting access (user, role, service)
2. **Resource** - The object being accessed (table, row, field)
3. **Action** - The operation being performed (SELECT, INSERT, UPDATE, DELETE)
4. **Environment** - Contextual conditions (time, IP, location, session data)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Application Layer                         │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                     pg_abac Extension                            │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   Check Functions (RLS-compatible)          ││
│  │  • abac_check()      - Main policy evaluator                ││
│  │  • abac_has_role()   - Role-based checks                    ││
│  │  • abac_has_attr()   - Attribute existence check            ││
│  │  • abac_attr_eq()    - Attribute equality check             ││
│  │  • abac_attr_in()    - Attribute in set check               ││
│  │  • abac_time_check() - Time-based access                    ││
│  │  • abac_evaluate_policy() - Full policy evaluation          ││
│  └─────────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   Core Tables                               ││
│  │  • abac_subjects     - Subject definitions & attributes     ││
│  │  • abac_policies     - Policy definitions                   ││
│  │  • abac_attributes   - Attribute catalog                    ││
│  │  • abac_policy_rules - Policy rule conditions               ││
│  └─────────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   Management Functions                      ││
│  │  • abac_create_policy()    - Create new policy              ││
│  │  • abac_add_subject_attr() - Assign attribute to subject    ││
│  │  • abac_grant_role()       - Assign role to subject         ││
│  │  • abac_audit_log()        - Log access decisions           ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                    PostgreSQL RLS Policies                       │
│   USING (abac_check(current_user_id(), 'documents', 'read'))    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Implementation Plan

### Phase 1: Core Schema & Types

**Files to create:**
- `pg_abac.control`
- `pg_abac--0.0.1.sql`

#### 1.1 Enums and Types

```sql
-- Action types
CREATE TYPE abac.action_type AS ENUM ('select', 'insert', 'update', 'delete', 'all');

-- Comparison operators for rules
CREATE TYPE abac.comparison_op AS ENUM ('eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'in', 'not_in', 'contains', 'regex');

-- Policy effect
CREATE TYPE abac.policy_effect AS ENUM ('allow', 'deny');

-- Attribute value type
CREATE TYPE abac.attr_type AS ENUM ('string', 'number', 'boolean', 'array', 'json', 'timestamp');
```

#### 1.2 Core Tables

```sql
-- Attribute definitions catalog
CREATE TABLE abac.attributes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    attr_type abac.attr_type NOT NULL DEFAULT 'string',
    category TEXT NOT NULL CHECK (category IN ('subject', 'resource', 'action', 'environment')),
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Subject attributes (links subjects to their attributes)
CREATE TABLE abac.subject_attributes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_id TEXT NOT NULL,  -- Flexible: could be user_id, role, etc.
    attribute_name TEXT NOT NULL REFERENCES abac.attributes(name),
    attribute_value JSONB NOT NULL,
    valid_from TIMESTAMPTZ DEFAULT now(),
    valid_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(subject_id, attribute_name)
);

-- Policy definitions
CREATE TABLE abac.policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    resource_type TEXT NOT NULL,  -- Table/resource this applies to
    action abac.action_type NOT NULL DEFAULT 'all',
    effect abac.policy_effect NOT NULL DEFAULT 'allow',
    priority INTEGER DEFAULT 0,  -- Higher = evaluated first
    enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Policy rules (conditions that must be met)
CREATE TABLE abac.policy_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id UUID NOT NULL REFERENCES abac.policies(id) ON DELETE CASCADE,
    attribute_name TEXT NOT NULL,
    attribute_category TEXT NOT NULL CHECK (attribute_category IN ('subject', 'resource', 'environment')),
    operator abac.comparison_op NOT NULL DEFAULT 'eq',
    compare_value JSONB NOT NULL,
    is_required BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Audit log for access decisions
CREATE TABLE abac.audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_id TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id TEXT,
    action abac.action_type NOT NULL,
    decision abac.policy_effect NOT NULL,
    policy_id UUID REFERENCES abac.policies(id),
    context JSONB,
    evaluated_at TIMESTAMPTZ DEFAULT now()
);
```

#### 1.3 Indexes for Performance

```sql
CREATE INDEX idx_subject_attrs_subject ON abac.subject_attributes(subject_id);
CREATE INDEX idx_subject_attrs_name ON abac.subject_attributes(attribute_name);
CREATE INDEX idx_policies_resource ON abac.policies(resource_type) WHERE enabled = true;
CREATE INDEX idx_policy_rules_policy ON abac.policy_rules(policy_id);
CREATE INDEX idx_audit_log_subject ON abac.audit_log(subject_id, evaluated_at DESC);
```

---

### Phase 2: RLS-Compatible Check Functions

These functions are designed to be efficient and work inside RLS policies.

#### 2.1 Session Context Functions

```sql
-- Get current subject ID from session
-- Users should set this via: SET LOCAL abac.subject_id = 'user-123';
CREATE OR REPLACE FUNCTION abac.current_subject_id()
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        current_setting('abac.subject_id', true),
        current_user
    );
$$;

-- Get current session context as JSONB
CREATE OR REPLACE FUNCTION abac.session_context()
RETURNS JSONB
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        current_setting('abac.context', true)::jsonb,
        '{}'::jsonb
    );
$$;
```

#### 2.2 Basic Attribute Check Functions

```sql
-- Check if subject has a specific attribute
CREATE OR REPLACE FUNCTION abac.has_attr(
    p_subject_id TEXT,
    p_attribute_name TEXT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM abac.subject_attributes
        WHERE subject_id = p_subject_id
          AND attribute_name = p_attribute_name
          AND (valid_until IS NULL OR valid_until > now())
    );
$$;

-- Get attribute value for a subject
CREATE OR REPLACE FUNCTION abac.get_attr(
    p_subject_id TEXT,
    p_attribute_name TEXT
)
RETURNS JSONB
LANGUAGE sql STABLE
AS $$
    SELECT attribute_value
    FROM abac.subject_attributes
    WHERE subject_id = p_subject_id
      AND attribute_name = p_attribute_name
      AND (valid_until IS NULL OR valid_until > now())
    LIMIT 1;
$$;

-- Check if attribute equals a value
CREATE OR REPLACE FUNCTION abac.attr_eq(
    p_subject_id TEXT,
    p_attribute_name TEXT,
    p_value JSONB
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM abac.subject_attributes
        WHERE subject_id = p_subject_id
          AND attribute_name = p_attribute_name
          AND attribute_value = p_value
          AND (valid_until IS NULL OR valid_until > now())
    );
$$;

-- Check if attribute value is in a set
CREATE OR REPLACE FUNCTION abac.attr_in(
    p_subject_id TEXT,
    p_attribute_name TEXT,
    p_values JSONB  -- Should be an array
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM abac.subject_attributes
        WHERE subject_id = p_subject_id
          AND attribute_name = p_attribute_name
          AND attribute_value <@ p_values
          AND (valid_until IS NULL OR valid_until > now())
    );
$$;
```

#### 2.3 Role-Based Check Functions

```sql
-- Check if subject has a specific role
CREATE OR REPLACE FUNCTION abac.has_role(
    p_subject_id TEXT,
    p_role TEXT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT abac.attr_eq(p_subject_id, 'role', to_jsonb(p_role))
        OR abac.attr_in(p_subject_id, 'roles', jsonb_build_array(p_role));
$$;

-- Check if subject has any of the specified roles
CREATE OR REPLACE FUNCTION abac.has_any_role(
    p_subject_id TEXT,
    p_roles TEXT[]
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM abac.subject_attributes sa
        WHERE sa.subject_id = p_subject_id
          AND sa.attribute_name IN ('role', 'roles')
          AND (
              sa.attribute_value::text = ANY(SELECT to_jsonb(r)::text FROM unnest(p_roles) r)
              OR sa.attribute_value ?| p_roles
          )
          AND (sa.valid_until IS NULL OR sa.valid_until > now())
    );
$$;

-- Check if subject has all specified roles
CREATE OR REPLACE FUNCTION abac.has_all_roles(
    p_subject_id TEXT,
    p_roles TEXT[]
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT (
        SELECT COUNT(DISTINCT r)
        FROM unnest(p_roles) r
        WHERE abac.has_role(p_subject_id, r)
    ) = array_length(p_roles, 1);
$$;
```

#### 2.4 Time-Based Check Functions

```sql
-- Check if current time is within allowed window
CREATE OR REPLACE FUNCTION abac.time_in_range(
    p_start_time TIME,
    p_end_time TIME
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT LOCALTIME BETWEEN p_start_time AND p_end_time;
$$;

-- Check if current date is within allowed range
CREATE OR REPLACE FUNCTION abac.date_in_range(
    p_start_date DATE,
    p_end_date DATE
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT CURRENT_DATE BETWEEN p_start_date AND p_end_date;
$$;

-- Check if current day is in allowed weekdays (0=Sunday, 6=Saturday)
CREATE OR REPLACE FUNCTION abac.is_weekday_allowed(
    p_allowed_days INTEGER[]
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT EXTRACT(DOW FROM CURRENT_DATE)::INTEGER = ANY(p_allowed_days);
$$;
```

#### 2.5 Resource Ownership Functions

```sql
-- Check if subject owns a resource (common pattern)
CREATE OR REPLACE FUNCTION abac.is_owner(
    p_subject_id TEXT,
    p_owner_id TEXT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT p_subject_id = p_owner_id;
$$;

-- Check if subject is owner using current session
CREATE OR REPLACE FUNCTION abac.is_owner(
    p_owner_id TEXT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT abac.current_subject_id() = p_owner_id;
$$;
```

---

### Phase 3: Policy Evaluation Engine

#### 3.1 Main Policy Check Function

```sql
-- Main ABAC check function - use in RLS policies
CREATE OR REPLACE FUNCTION abac.check(
    p_resource_type TEXT,
    p_action abac.action_type,
    p_resource_context JSONB DEFAULT '{}'::jsonb
)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_subject_id TEXT;
    v_decision BOOLEAN := false;
    v_policy RECORD;
    v_rule_match BOOLEAN;
BEGIN
    v_subject_id := abac.current_subject_id();

    -- Iterate through applicable policies by priority
    FOR v_policy IN
        SELECT p.*
        FROM abac.policies p
        WHERE p.enabled = true
          AND p.resource_type = p_resource_type
          AND (p.action = p_action OR p.action = 'all')
        ORDER BY p.priority DESC, p.created_at ASC
    LOOP
        -- Check if all required rules match
        v_rule_match := abac.evaluate_policy_rules(
            v_policy.id,
            v_subject_id,
            p_resource_context
        );

        IF v_rule_match THEN
            -- First matching policy determines the decision
            v_decision := (v_policy.effect = 'allow');

            -- Optional: Log the decision
            -- PERFORM abac.log_decision(v_subject_id, p_resource_type, p_action, v_policy.id, v_decision);

            RETURN v_decision;
        END IF;
    END LOOP;

    -- Default deny if no policy matched
    RETURN false;
END;
$$;

-- Evaluate all rules for a policy
CREATE OR REPLACE FUNCTION abac.evaluate_policy_rules(
    p_policy_id UUID,
    p_subject_id TEXT,
    p_resource_context JSONB
)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_rule RECORD;
    v_attr_value JSONB;
    v_match BOOLEAN;
BEGIN
    FOR v_rule IN
        SELECT * FROM abac.policy_rules
        WHERE policy_id = p_policy_id
    LOOP
        -- Get attribute value based on category
        CASE v_rule.attribute_category
            WHEN 'subject' THEN
                v_attr_value := abac.get_attr(p_subject_id, v_rule.attribute_name);
            WHEN 'resource' THEN
                v_attr_value := p_resource_context -> v_rule.attribute_name;
            WHEN 'environment' THEN
                v_attr_value := abac.get_environment_attr(v_rule.attribute_name);
        END CASE;

        -- Evaluate the comparison
        v_match := abac.compare_values(
            v_attr_value,
            v_rule.operator,
            v_rule.compare_value
        );

        -- If required rule doesn't match, policy doesn't apply
        IF v_rule.is_required AND NOT COALESCE(v_match, false) THEN
            RETURN false;
        END IF;
    END LOOP;

    RETURN true;
END;
$$;

-- Compare values using specified operator
CREATE OR REPLACE FUNCTION abac.compare_values(
    p_actual JSONB,
    p_operator abac.comparison_op,
    p_expected JSONB
)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p_actual IS NULL THEN
        RETURN false;
    END IF;

    CASE p_operator
        WHEN 'eq' THEN RETURN p_actual = p_expected;
        WHEN 'neq' THEN RETURN p_actual <> p_expected;
        WHEN 'gt' THEN RETURN (p_actual::text)::numeric > (p_expected::text)::numeric;
        WHEN 'gte' THEN RETURN (p_actual::text)::numeric >= (p_expected::text)::numeric;
        WHEN 'lt' THEN RETURN (p_actual::text)::numeric < (p_expected::text)::numeric;
        WHEN 'lte' THEN RETURN (p_actual::text)::numeric <= (p_expected::text)::numeric;
        WHEN 'in' THEN RETURN p_actual <@ p_expected;
        WHEN 'not_in' THEN RETURN NOT (p_actual <@ p_expected);
        WHEN 'contains' THEN RETURN p_actual @> p_expected;
        WHEN 'regex' THEN RETURN (p_actual::text) ~ (p_expected::text);
        ELSE RETURN false;
    END CASE;
END;
$$;

-- Get environment attributes (time, etc.)
CREATE OR REPLACE FUNCTION abac.get_environment_attr(
    p_attr_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    CASE p_attr_name
        WHEN 'current_time' THEN RETURN to_jsonb(LOCALTIME);
        WHEN 'current_date' THEN RETURN to_jsonb(CURRENT_DATE);
        WHEN 'current_timestamp' THEN RETURN to_jsonb(now());
        WHEN 'day_of_week' THEN RETURN to_jsonb(EXTRACT(DOW FROM CURRENT_DATE)::INTEGER);
        WHEN 'ip_address' THEN RETURN to_jsonb(COALESCE(current_setting('abac.ip_address', true), ''));
        ELSE
            -- Check session context for custom environment attributes
            RETURN abac.session_context() -> p_attr_name;
    END CASE;
END;
$$;
```

---

### Phase 4: Management Functions

#### 4.1 Subject Management

```sql
-- Add/update attribute for a subject
CREATE OR REPLACE FUNCTION abac.set_subject_attr(
    p_subject_id TEXT,
    p_attribute_name TEXT,
    p_attribute_value JSONB,
    p_valid_until TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_id UUID;
BEGIN
    INSERT INTO abac.subject_attributes (subject_id, attribute_name, attribute_value, valid_until)
    VALUES (p_subject_id, p_attribute_name, p_attribute_value, p_valid_until)
    ON CONFLICT (subject_id, attribute_name)
    DO UPDATE SET
        attribute_value = EXCLUDED.attribute_value,
        valid_until = EXCLUDED.valid_until
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- Remove attribute from subject
CREATE OR REPLACE FUNCTION abac.remove_subject_attr(
    p_subject_id TEXT,
    p_attribute_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM abac.subject_attributes
    WHERE subject_id = p_subject_id
      AND attribute_name = p_attribute_name;

    RETURN FOUND;
END;
$$;

-- Grant role to subject (convenience function)
CREATE OR REPLACE FUNCTION abac.grant_role(
    p_subject_id TEXT,
    p_role TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_roles JSONB;
BEGIN
    -- Get current roles
    v_current_roles := COALESCE(abac.get_attr(p_subject_id, 'roles'), '[]'::jsonb);

    -- Add new role if not exists
    IF NOT v_current_roles @> to_jsonb(p_role) THEN
        v_current_roles := v_current_roles || to_jsonb(p_role);
        PERFORM abac.set_subject_attr(p_subject_id, 'roles', v_current_roles);
    END IF;
END;
$$;

-- Revoke role from subject
CREATE OR REPLACE FUNCTION abac.revoke_role(
    p_subject_id TEXT,
    p_role TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_roles JSONB;
BEGIN
    v_current_roles := COALESCE(abac.get_attr(p_subject_id, 'roles'), '[]'::jsonb);
    v_current_roles := v_current_roles - p_role;
    PERFORM abac.set_subject_attr(p_subject_id, 'roles', v_current_roles);
END;
$$;
```

#### 4.2 Policy Management

```sql
-- Create a new policy
CREATE OR REPLACE FUNCTION abac.create_policy(
    p_name TEXT,
    p_resource_type TEXT,
    p_action abac.action_type DEFAULT 'all',
    p_effect abac.policy_effect DEFAULT 'allow',
    p_description TEXT DEFAULT NULL,
    p_priority INTEGER DEFAULT 0
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_id UUID;
BEGIN
    INSERT INTO abac.policies (name, resource_type, action, effect, description, priority)
    VALUES (p_name, p_resource_type, p_action, p_effect, p_description, p_priority)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- Add rule to policy
CREATE OR REPLACE FUNCTION abac.add_policy_rule(
    p_policy_id UUID,
    p_attribute_name TEXT,
    p_attribute_category TEXT,
    p_operator abac.comparison_op,
    p_compare_value JSONB,
    p_is_required BOOLEAN DEFAULT true
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_id UUID;
BEGIN
    INSERT INTO abac.policy_rules (
        policy_id, attribute_name, attribute_category,
        operator, compare_value, is_required
    )
    VALUES (
        p_policy_id, p_attribute_name, p_attribute_category,
        p_operator, p_compare_value, p_is_required
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- Enable/disable policy
CREATE OR REPLACE FUNCTION abac.set_policy_enabled(
    p_policy_id UUID,
    p_enabled BOOLEAN
)
RETURNS VOID
LANGUAGE sql
AS $$
    UPDATE abac.policies
    SET enabled = p_enabled, updated_at = now()
    WHERE id = p_policy_id;
$$;
```

---

### Phase 5: Convenience Functions for RLS

These are simplified wrapper functions designed specifically for common RLS patterns.

```sql
-- Simple check: can current user perform action on resource type?
CREATE OR REPLACE FUNCTION abac.can(
    p_action TEXT,
    p_resource_type TEXT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT abac.check(p_resource_type, p_action::abac.action_type);
$$;

-- Check with resource context
CREATE OR REPLACE FUNCTION abac.can_access(
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id TEXT,
    p_owner_id TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT abac.check(
        p_resource_type,
        p_action::abac.action_type,
        jsonb_build_object(
            'resource_id', p_resource_id,
            'owner_id', p_owner_id
        )
    );
$$;

-- Shorthand: current user is admin?
CREATE OR REPLACE FUNCTION abac.is_admin()
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT abac.has_role(abac.current_subject_id(), 'admin');
$$;

-- Shorthand: current user is owner or admin?
CREATE OR REPLACE FUNCTION abac.is_owner_or_admin(
    p_owner_id TEXT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT abac.is_owner(p_owner_id) OR abac.is_admin();
$$;

-- Check department access
CREATE OR REPLACE FUNCTION abac.same_department(
    p_resource_department TEXT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT abac.attr_eq(
        abac.current_subject_id(),
        'department',
        to_jsonb(p_resource_department)
    );
$$;

-- Check tenant access (multi-tenancy)
CREATE OR REPLACE FUNCTION abac.same_tenant(
    p_resource_tenant_id TEXT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT abac.attr_eq(
        abac.current_subject_id(),
        'tenant_id',
        to_jsonb(p_resource_tenant_id)
    );
$$;
```

---

## Usage Examples

### Example 1: Basic RLS with ABAC

```sql
-- Create a documents table
CREATE TABLE documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    content TEXT,
    owner_id TEXT NOT NULL,
    department TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Enable RLS
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

-- Policy: Users can read their own documents
CREATE POLICY documents_select_own ON documents
    FOR SELECT
    USING (abac.is_owner(owner_id));

-- Policy: Users can read department documents if they have permission
CREATE POLICY documents_select_dept ON documents
    FOR SELECT
    USING (
        abac.same_department(department)
        AND abac.can('select', 'documents')
    );

-- Policy: Admins can do anything
CREATE POLICY documents_admin ON documents
    FOR ALL
    USING (abac.is_admin())
    WITH CHECK (abac.is_admin());
```

### Example 2: Setting Up User Context

```sql
-- In your application, before executing queries:
BEGIN;
SET LOCAL abac.subject_id = 'user-123';
SET LOCAL abac.context = '{"ip_address": "192.168.1.1", "client": "web"}';

-- Now queries will use this context for ABAC checks
SELECT * FROM documents;

COMMIT;
```

### Example 3: Creating Policies via SQL

```sql
-- Create policy: Only editors can update documents
SELECT abac.create_policy(
    'editors_can_update_documents',
    'documents',
    'update',
    'allow',
    'Allow users with editor role to update documents'
);

-- Add rule: subject must have 'editor' role
SELECT abac.add_policy_rule(
    (SELECT id FROM abac.policies WHERE name = 'editors_can_update_documents'),
    'roles',
    'subject',
    'contains',
    '"editor"'::jsonb
);

-- Assign editor role to a user
SELECT abac.grant_role('user-456', 'editor');
```

### Example 4: Time-Based Access

```sql
-- Create policy: Access only during business hours
SELECT abac.create_policy(
    'business_hours_only',
    'sensitive_reports',
    'select',
    'allow',
    'Allow access only during business hours'
);

-- Add time rule
SELECT abac.add_policy_rule(
    (SELECT id FROM abac.policies WHERE name = 'business_hours_only'),
    'current_time',
    'environment',
    'gte',
    '"09:00:00"'::jsonb
);

SELECT abac.add_policy_rule(
    (SELECT id FROM abac.policies WHERE name = 'business_hours_only'),
    'current_time',
    'environment',
    'lte',
    '"17:00:00"'::jsonb
);
```

---

## File Structure

```
pg_abac/
├── pg_abac.control                    # Extension metadata
├── pg_abac--0.0.1.sql                 # Initial version (full install)
├── README.md                          # Usage documentation
└── examples/
    ├── basic_rls.sql                  # Basic RLS examples
    ├── multi_tenant.sql               # Multi-tenancy example
    └── time_based_access.sql          # Time-based access example
```

---

## Performance Considerations

1. **Function Stability**: All check functions marked as `STABLE` to allow query optimization
2. **Indexed Lookups**: Key columns indexed for fast attribute lookups
3. **Minimal Joins**: Simple functions avoid complex joins for RLS efficiency
4. **Caching**: PostgreSQL's query cache helps with repeated policy checks
5. **Short-Circuit Evaluation**: Policy evaluation stops at first match

---

## Security Considerations

1. **Schema Isolation**: All ABAC tables in `abac` schema
2. **Function Security**: Functions use `SECURITY INVOKER` by default
3. **Audit Trail**: Optional audit logging for compliance
4. **No Dynamic SQL**: Avoid SQL injection through parameterized queries
5. **Default Deny**: If no policy matches, access is denied

---

## Version Roadmap

### v0.0.1 (Initial)
- Core schema and types
- Basic attribute check functions
- Simple policy evaluation
- RLS convenience functions

### v0.0.2 (Planned)
- Hierarchical roles support
- Policy inheritance
- Bulk attribute operations
- Performance optimizations

### v0.0.3 (Planned)
- Attribute caching
- Policy simulation/testing functions
- Migration helpers
- Advanced audit logging

---

## Implementation Checklist

- [ ] Create `pg_abac.control` file
- [ ] Create `abac` schema
- [ ] Implement enum types
- [ ] Implement core tables with indexes
- [ ] Implement session context functions
- [ ] Implement basic attribute check functions
- [ ] Implement role-based check functions
- [ ] Implement time-based check functions
- [ ] Implement policy evaluation engine
- [ ] Implement management functions
- [ ] Implement RLS convenience functions
- [ ] Create README with examples
- [ ] Create example files
- [ ] Test with Supabase local environment
