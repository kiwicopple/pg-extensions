\echo Use "CREATE EXTENSION pg_cedar" to load this file. \quit

/*
 * MIT License
 *
 * Copyright (c) 2024 pg_cedar contributors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

-- ============================================================================
-- pg_cedar: Cedar-compatible Authorization for PostgreSQL
-- ============================================================================
--
-- This extension provides Cedar-style authorization that works seamlessly
-- with PostgreSQL Row-Level Security (RLS) policies.
--
-- Cedar Concepts:
--   - Principal: Entity making a request (User, Role, Group)
--   - Action: Operation being performed (read, write, delete, etc.)
--   - Resource: Object being accessed (Document::123, Photo::456)
--   - Policy: Rule that permits or forbids an action
--   - Context: Additional attributes for the request
--
-- ============================================================================


-- ============================================================================
-- SECTION 1: ENUM TYPES
-- ============================================================================

-- Policy effect: whether to permit or forbid
create type cedar_effect as enum ('permit', 'forbid');


-- ============================================================================
-- SECTION 2: CORE TABLES
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Entity Types Registry
-- ----------------------------------------------------------------------------
-- Stores the types of entities (e.g., User, Role, Group, Document, Photo)
create table cedar_entity_types (
    name text primary key,
    description text,
    created_at timestamptz default now()
);

comment on table cedar_entity_types is 'Registry of entity types in the Cedar authorization system';

-- Insert default entity types
insert into cedar_entity_types (name, description) values
    ('User', 'Individual user accounts'),
    ('Role', 'Roles that can be assigned to users'),
    ('Group', 'Groups of users or other entities'),
    ('Resource', 'Generic resource type');


-- ----------------------------------------------------------------------------
-- Entities
-- ----------------------------------------------------------------------------
-- Stores all entities (principals and resources) in the system
create table cedar_entities (
    entity_type text not null references cedar_entity_types(name) on delete cascade,
    entity_id text not null,
    display_name text,
    attributes jsonb default '{}',
    created_at timestamptz default now(),
    primary key (entity_type, entity_id)
);

comment on table cedar_entities is 'All entities (principals and resources) in the authorization system';
comment on column cedar_entities.entity_type is 'Type of entity (User, Role, Group, etc.)';
comment on column cedar_entities.entity_id is 'Unique identifier within the entity type';
comment on column cedar_entities.attributes is 'Additional attributes as JSONB for flexible metadata';

create index idx_cedar_entities_type on cedar_entities(entity_type);


-- ----------------------------------------------------------------------------
-- Entity Relationships (Hierarchy)
-- ----------------------------------------------------------------------------
-- Stores parent-child relationships between entities (e.g., User in Group)
create table cedar_entity_parents (
    child_type text not null,
    child_id text not null,
    parent_type text not null,
    parent_id text not null,
    created_at timestamptz default now(),
    primary key (child_type, child_id, parent_type, parent_id),
    foreign key (child_type, child_id) references cedar_entities(entity_type, entity_id) on delete cascade,
    foreign key (parent_type, parent_id) references cedar_entities(entity_type, entity_id) on delete cascade
);

comment on table cedar_entity_parents is 'Hierarchical relationships between entities (e.g., User in Group)';

create index idx_cedar_entity_parents_child on cedar_entity_parents(child_type, child_id);
create index idx_cedar_entity_parents_parent on cedar_entity_parents(parent_type, parent_id);


-- ----------------------------------------------------------------------------
-- Actions
-- ----------------------------------------------------------------------------
-- Stores available actions in the system
create table cedar_actions (
    action_type text not null default 'Action',
    action_id text not null,
    description text,
    created_at timestamptz default now(),
    primary key (action_type, action_id)
);

comment on table cedar_actions is 'Available actions in the authorization system';

-- Insert common actions
insert into cedar_actions (action_id, description) values
    ('read', 'Read/view a resource'),
    ('write', 'Create or update a resource'),
    ('delete', 'Delete a resource'),
    ('list', 'List resources'),
    ('share', 'Share a resource with others'),
    ('admin', 'Administrative access');


-- ----------------------------------------------------------------------------
-- Action Hierarchy
-- ----------------------------------------------------------------------------
-- Stores parent-child relationships between actions (e.g., admin includes write)
create table cedar_action_parents (
    child_type text not null default 'Action',
    child_id text not null,
    parent_type text not null default 'Action',
    parent_id text not null,
    created_at timestamptz default now(),
    primary key (child_type, child_id, parent_type, parent_id),
    foreign key (child_type, child_id) references cedar_actions(action_type, action_id) on delete cascade,
    foreign key (parent_type, parent_id) references cedar_actions(action_type, action_id) on delete cascade
);

comment on table cedar_action_parents is 'Hierarchical relationships between actions';


-- ----------------------------------------------------------------------------
-- Policies
-- ----------------------------------------------------------------------------
-- Stores authorization policies
create table cedar_policies (
    policy_id text primary key default gen_random_uuid()::text,
    effect cedar_effect not null,
    description text,

    -- Principal specification (NULL means any)
    principal_type text,
    principal_id text,
    principal_in_type text,  -- For "principal in Group::"admins""
    principal_in_id text,

    -- Action specification (NULL means any)
    action_type text default 'Action',
    action_id text,

    -- Resource specification (NULL means any)
    resource_type text,
    resource_id text,
    resource_in_type text,  -- For "resource in Folder::"shared""
    resource_in_id text,

    -- Condition (JSONB for flexible conditions)
    -- Supports: {"attribute": "value"}, {"principal.attr": "value"}, etc.
    conditions jsonb default '{}',

    -- Policy ordering (lower = higher priority)
    priority int default 100,

    -- Metadata
    enabled boolean default true,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

comment on table cedar_policies is 'Authorization policies defining who can do what on which resources';
comment on column cedar_policies.effect is 'Whether this policy permits or forbids the action';
comment on column cedar_policies.principal_type is 'Type of principal (NULL = any)';
comment on column cedar_policies.principal_id is 'Specific principal ID (NULL = any of type)';
comment on column cedar_policies.principal_in_type is 'Principal must be in this entity type';
comment on column cedar_policies.principal_in_id is 'Principal must be in this specific entity';
comment on column cedar_policies.conditions is 'Additional conditions as JSONB';
comment on column cedar_policies.priority is 'Policy priority (lower = higher priority)';

create index idx_cedar_policies_principal on cedar_policies(principal_type, principal_id) where enabled;
create index idx_cedar_policies_action on cedar_policies(action_type, action_id) where enabled;
create index idx_cedar_policies_resource on cedar_policies(resource_type, resource_id) where enabled;
create index idx_cedar_policies_enabled on cedar_policies(enabled, priority);


-- ============================================================================
-- SECTION 3: HELPER FUNCTIONS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Get all ancestors of an entity (transitive closure)
-- ----------------------------------------------------------------------------
create or replace function cedar_get_ancestors(
    p_entity_type text,
    p_entity_id text
)
returns table(ancestor_type text, ancestor_id text)
language sql
stable
as $$
    with recursive ancestors as (
        -- Base case: direct parents
        select parent_type, parent_id
        from cedar_entity_parents
        where child_type = p_entity_type and child_id = p_entity_id

        union

        -- Recursive case: parents of parents
        select ep.parent_type, ep.parent_id
        from cedar_entity_parents ep
        inner join ancestors a on ep.child_type = a.parent_type and ep.child_id = a.parent_id
    )
    select parent_type as ancestor_type, parent_id as ancestor_id from ancestors;
$$;

comment on function cedar_get_ancestors is 'Get all ancestors of an entity (transitive closure of parent relationships)';


-- ----------------------------------------------------------------------------
-- Get all descendants of an entity (transitive closure)
-- ----------------------------------------------------------------------------
create or replace function cedar_get_descendants(
    p_entity_type text,
    p_entity_id text
)
returns table(descendant_type text, descendant_id text)
language sql
stable
as $$
    with recursive descendants as (
        -- Base case: direct children
        select child_type, child_id
        from cedar_entity_parents
        where parent_type = p_entity_type and parent_id = p_entity_id

        union

        -- Recursive case: children of children
        select ep.child_type, ep.child_id
        from cedar_entity_parents ep
        inner join descendants d on ep.parent_type = d.child_type and ep.parent_id = d.child_id
    )
    select child_type as descendant_type, child_id as descendant_id from descendants;
$$;

comment on function cedar_get_descendants is 'Get all descendants of an entity (transitive closure of child relationships)';


-- ----------------------------------------------------------------------------
-- Check if entity is in another entity (direct or transitive)
-- ----------------------------------------------------------------------------
create or replace function cedar_entity_in(
    p_child_type text,
    p_child_id text,
    p_parent_type text,
    p_parent_id text
)
returns boolean
language sql
stable
as $$
    select exists(
        select 1 from cedar_get_ancestors(p_child_type, p_child_id)
        where ancestor_type = p_parent_type and ancestor_id = p_parent_id
    ) or (p_child_type = p_parent_type and p_child_id = p_parent_id);
$$;

comment on function cedar_entity_in is 'Check if an entity is in another entity (direct or through ancestors)';


-- ----------------------------------------------------------------------------
-- Get action ancestors (for action hierarchy)
-- ----------------------------------------------------------------------------
create or replace function cedar_get_action_ancestors(
    p_action_type text,
    p_action_id text
)
returns table(ancestor_type text, ancestor_id text)
language sql
stable
as $$
    with recursive ancestors as (
        select parent_type, parent_id
        from cedar_action_parents
        where child_type = p_action_type and child_id = p_action_id

        union

        select ap.parent_type, ap.parent_id
        from cedar_action_parents ap
        inner join ancestors a on ap.child_type = a.parent_type and ap.child_id = a.parent_id
    )
    select parent_type as ancestor_type, parent_id as ancestor_id from ancestors;
$$;


-- ============================================================================
-- SECTION 4: POLICY EVALUATION FUNCTIONS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Evaluate conditions against context
-- ----------------------------------------------------------------------------
create or replace function cedar_evaluate_conditions(
    p_conditions jsonb,
    p_context jsonb,
    p_principal_attrs jsonb default '{}',
    p_resource_attrs jsonb default '{}'
)
returns boolean
language plpgsql
stable
as $$
declare
    v_key text;
    v_value jsonb;
    v_actual jsonb;
begin
    -- Empty conditions always match
    if p_conditions is null or p_conditions = '{}'::jsonb then
        return true;
    end if;

    -- Check each condition
    for v_key, v_value in select * from jsonb_each(p_conditions)
    loop
        -- Handle principal.* conditions
        if v_key like 'principal.%' then
            v_actual := p_principal_attrs -> substring(v_key from 11);
        -- Handle resource.* conditions
        elsif v_key like 'resource.%' then
            v_actual := p_resource_attrs -> substring(v_key from 10);
        -- Handle context.* conditions
        elsif v_key like 'context.%' then
            v_actual := p_context -> substring(v_key from 9);
        -- Direct context lookup
        else
            v_actual := p_context -> v_key;
        end if;

        -- Check equality
        if v_actual is distinct from v_value then
            return false;
        end if;
    end loop;

    return true;
end;
$$;

comment on function cedar_evaluate_conditions is 'Evaluate policy conditions against context and entity attributes';


-- ----------------------------------------------------------------------------
-- Core authorization check function
-- ----------------------------------------------------------------------------
create or replace function cedar_is_authorized(
    p_principal_type text,
    p_principal_id text,
    p_action_type text,
    p_action_id text,
    p_resource_type text,
    p_resource_id text,
    p_context jsonb default '{}'
)
returns boolean
language plpgsql
stable
as $$
declare
    v_policy record;
    v_principal_attrs jsonb;
    v_resource_attrs jsonb;
    v_has_permit boolean := false;
    v_principal_matches boolean;
    v_action_matches boolean;
    v_resource_matches boolean;
begin
    -- Get principal attributes
    select attributes into v_principal_attrs
    from cedar_entities
    where entity_type = p_principal_type and entity_id = p_principal_id;

    v_principal_attrs := coalesce(v_principal_attrs, '{}'::jsonb);

    -- Get resource attributes
    select attributes into v_resource_attrs
    from cedar_entities
    where entity_type = p_resource_type and entity_id = p_resource_id;

    v_resource_attrs := coalesce(v_resource_attrs, '{}'::jsonb);

    -- Evaluate policies in priority order
    for v_policy in
        select * from cedar_policies
        where enabled = true
        order by priority asc, effect desc  -- forbid takes precedence at same priority
    loop
        -- Check principal match
        v_principal_matches := (
            -- Any principal
            (v_policy.principal_type is null and v_policy.principal_id is null and
             v_policy.principal_in_type is null)
            or
            -- Exact principal match
            (v_policy.principal_type = p_principal_type and
             (v_policy.principal_id is null or v_policy.principal_id = p_principal_id))
            or
            -- Principal in group/role
            (v_policy.principal_in_type is not null and
             cedar_entity_in(p_principal_type, p_principal_id,
                           v_policy.principal_in_type, v_policy.principal_in_id))
        );

        if not v_principal_matches then
            continue;
        end if;

        -- Check action match
        v_action_matches := (
            -- Any action
            v_policy.action_id is null
            or
            -- Exact action match
            (v_policy.action_type = p_action_type and v_policy.action_id = p_action_id)
            or
            -- Action hierarchy (check if requested action is descendant)
            exists(
                select 1 from cedar_get_action_ancestors(p_action_type, p_action_id)
                where ancestor_type = v_policy.action_type and ancestor_id = v_policy.action_id
            )
        );

        if not v_action_matches then
            continue;
        end if;

        -- Check resource match
        v_resource_matches := (
            -- Any resource
            (v_policy.resource_type is null and v_policy.resource_id is null and
             v_policy.resource_in_type is null)
            or
            -- Exact resource match
            (v_policy.resource_type = p_resource_type and
             (v_policy.resource_id is null or v_policy.resource_id = p_resource_id))
            or
            -- Resource in container
            (v_policy.resource_in_type is not null and
             cedar_entity_in(p_resource_type, p_resource_id,
                           v_policy.resource_in_type, v_policy.resource_in_id))
        );

        if not v_resource_matches then
            continue;
        end if;

        -- Check conditions
        if not cedar_evaluate_conditions(v_policy.conditions, p_context,
                                         v_principal_attrs, v_resource_attrs) then
            continue;
        end if;

        -- Policy matches! Check effect
        if v_policy.effect = 'forbid' then
            return false;  -- Explicit deny
        else
            v_has_permit := true;
        end if;
    end loop;

    -- Default deny if no permit found
    return v_has_permit;
end;
$$;

comment on function cedar_is_authorized is 'Core authorization check: returns true if the action is permitted';


-- ============================================================================
-- SECTION 5: RLS-COMPATIBLE HELPER FUNCTIONS
-- ============================================================================
-- These functions are optimized for use in RLS policies

-- ----------------------------------------------------------------------------
-- Check authorization using current session user
-- ----------------------------------------------------------------------------
create or replace function cedar_check(
    p_action text,
    p_resource_type text,
    p_resource_id text,
    p_context jsonb default '{}'
)
returns boolean
language sql
stable
as $$
    select cedar_is_authorized(
        'User',
        current_setting('cedar.user_id', true),
        'Action',
        p_action,
        p_resource_type,
        p_resource_id,
        p_context
    );
$$;

comment on function cedar_check is 'RLS-friendly authorization check using session user (set cedar.user_id)';


-- ----------------------------------------------------------------------------
-- Check if current user can perform action on resource (by owner)
-- ----------------------------------------------------------------------------
create or replace function cedar_check_owner(
    p_action text,
    p_resource_type text,
    p_resource_id text,
    p_owner_id text
)
returns boolean
language plpgsql
stable
as $$
declare
    v_user_id text;
begin
    v_user_id := current_setting('cedar.user_id', true);

    -- Owner always has access
    if v_user_id = p_owner_id then
        return true;
    end if;

    -- Otherwise check policies
    return cedar_is_authorized(
        'User', v_user_id,
        'Action', p_action,
        p_resource_type, p_resource_id,
        '{}'::jsonb
    );
end;
$$;

comment on function cedar_check_owner is 'Authorization check that also grants access to resource owners';


-- ----------------------------------------------------------------------------
-- Check if current user has role
-- ----------------------------------------------------------------------------
create or replace function cedar_has_role(
    p_role_id text
)
returns boolean
language sql
stable
as $$
    select cedar_entity_in(
        'User',
        current_setting('cedar.user_id', true),
        'Role',
        p_role_id
    );
$$;

comment on function cedar_has_role is 'Check if current session user has a specific role';


-- ----------------------------------------------------------------------------
-- Check if current user is in group
-- ----------------------------------------------------------------------------
create or replace function cedar_in_group(
    p_group_id text
)
returns boolean
language sql
stable
as $$
    select cedar_entity_in(
        'User',
        current_setting('cedar.user_id', true),
        'Group',
        p_group_id
    );
$$;

comment on function cedar_in_group is 'Check if current session user is in a specific group';


-- ----------------------------------------------------------------------------
-- Get current user ID from session
-- ----------------------------------------------------------------------------
create or replace function cedar_current_user_id()
returns text
language sql
stable
as $$
    select current_setting('cedar.user_id', true);
$$;

comment on function cedar_current_user_id is 'Get the current Cedar user ID from session settings';


-- ----------------------------------------------------------------------------
-- Set current user ID in session
-- ----------------------------------------------------------------------------
create or replace function cedar_set_user(p_user_id text)
returns void
language sql
as $$
    select set_config('cedar.user_id', p_user_id, false);
$$;

comment on function cedar_set_user is 'Set the current Cedar user ID for the session';


-- ============================================================================
-- SECTION 6: POLICY MANAGEMENT FUNCTIONS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Add a permit policy
-- ----------------------------------------------------------------------------
create or replace function cedar_permit(
    p_principal_type text default null,
    p_principal_id text default null,
    p_action_id text default null,
    p_resource_type text default null,
    p_resource_id text default null,
    p_conditions jsonb default '{}',
    p_description text default null,
    p_priority int default 100
)
returns text
language sql
as $$
    insert into cedar_policies (
        effect, principal_type, principal_id, action_type, action_id,
        resource_type, resource_id, conditions, description, priority
    ) values (
        'permit', p_principal_type, p_principal_id, 'Action', p_action_id,
        p_resource_type, p_resource_id, p_conditions, p_description, p_priority
    )
    returning policy_id;
$$;

comment on function cedar_permit is 'Create a permit policy';


-- ----------------------------------------------------------------------------
-- Add a forbid policy
-- ----------------------------------------------------------------------------
create or replace function cedar_forbid(
    p_principal_type text default null,
    p_principal_id text default null,
    p_action_id text default null,
    p_resource_type text default null,
    p_resource_id text default null,
    p_conditions jsonb default '{}',
    p_description text default null,
    p_priority int default 100
)
returns text
language sql
as $$
    insert into cedar_policies (
        effect, principal_type, principal_id, action_type, action_id,
        resource_type, resource_id, conditions, description, priority
    ) values (
        'forbid', p_principal_type, p_principal_id, 'Action', p_action_id,
        p_resource_type, p_resource_id, p_conditions, p_description, p_priority
    )
    returning policy_id;
$$;

comment on function cedar_forbid is 'Create a forbid policy';


-- ----------------------------------------------------------------------------
-- Add a permit policy for principal in group/role
-- ----------------------------------------------------------------------------
create or replace function cedar_permit_in(
    p_principal_in_type text,
    p_principal_in_id text,
    p_action_id text default null,
    p_resource_type text default null,
    p_resource_id text default null,
    p_conditions jsonb default '{}',
    p_description text default null,
    p_priority int default 100
)
returns text
language sql
as $$
    insert into cedar_policies (
        effect, principal_in_type, principal_in_id, action_type, action_id,
        resource_type, resource_id, conditions, description, priority
    ) values (
        'permit', p_principal_in_type, p_principal_in_id, 'Action', p_action_id,
        p_resource_type, p_resource_id, p_conditions, p_description, p_priority
    )
    returning policy_id;
$$;

comment on function cedar_permit_in is 'Create a permit policy for principals in a group or role';


-- ----------------------------------------------------------------------------
-- Add an entity
-- ----------------------------------------------------------------------------
create or replace function cedar_add_entity(
    p_entity_type text,
    p_entity_id text,
    p_display_name text default null,
    p_attributes jsonb default '{}'
)
returns void
language sql
as $$
    insert into cedar_entities (entity_type, entity_id, display_name, attributes)
    values (p_entity_type, p_entity_id, p_display_name, p_attributes)
    on conflict (entity_type, entity_id) do update
    set display_name = coalesce(excluded.display_name, cedar_entities.display_name),
        attributes = cedar_entities.attributes || excluded.attributes;
$$;

comment on function cedar_add_entity is 'Add or update an entity in the authorization system';


-- ----------------------------------------------------------------------------
-- Add entity to parent (group/role membership)
-- ----------------------------------------------------------------------------
create or replace function cedar_add_parent(
    p_child_type text,
    p_child_id text,
    p_parent_type text,
    p_parent_id text
)
returns void
language sql
as $$
    insert into cedar_entity_parents (child_type, child_id, parent_type, parent_id)
    values (p_child_type, p_child_id, p_parent_type, p_parent_id)
    on conflict do nothing;
$$;

comment on function cedar_add_parent is 'Add an entity to a parent (e.g., add user to group)';


-- ----------------------------------------------------------------------------
-- Remove entity from parent
-- ----------------------------------------------------------------------------
create or replace function cedar_remove_parent(
    p_child_type text,
    p_child_id text,
    p_parent_type text,
    p_parent_id text
)
returns void
language sql
as $$
    delete from cedar_entity_parents
    where child_type = p_child_type and child_id = p_child_id
      and parent_type = p_parent_type and parent_id = p_parent_id;
$$;

comment on function cedar_remove_parent is 'Remove an entity from a parent';


-- ----------------------------------------------------------------------------
-- Quick setup: Add user with roles/groups
-- ----------------------------------------------------------------------------
create or replace function cedar_add_user(
    p_user_id text,
    p_display_name text default null,
    p_roles text[] default '{}',
    p_groups text[] default '{}',
    p_attributes jsonb default '{}'
)
returns void
language plpgsql
as $$
declare
    v_role text;
    v_group text;
begin
    -- Add user entity
    perform cedar_add_entity('User', p_user_id, p_display_name, p_attributes);

    -- Add role memberships
    foreach v_role in array p_roles loop
        perform cedar_add_entity('Role', v_role, v_role, '{}');
        perform cedar_add_parent('User', p_user_id, 'Role', v_role);
    end loop;

    -- Add group memberships
    foreach v_group in array p_groups loop
        perform cedar_add_entity('Group', v_group, v_group, '{}');
        perform cedar_add_parent('User', p_user_id, 'Group', v_group);
    end loop;
end;
$$;

comment on function cedar_add_user is 'Add a user with optional role and group memberships';


-- ============================================================================
-- SECTION 7: UTILITY VIEWS
-- ============================================================================

-- View of all effective permissions
create or replace view cedar_effective_permissions as
select
    p.policy_id,
    p.effect,
    p.description,
    coalesce(p.principal_type || '::' || p.principal_id,
             'in ' || p.principal_in_type || '::' || p.principal_in_id,
             '*') as principal,
    coalesce(p.action_type || '::' || p.action_id, '*') as action,
    coalesce(p.resource_type || '::' || p.resource_id,
             'in ' || p.resource_in_type || '::' || p.resource_in_id,
             '*') as resource,
    p.conditions,
    p.priority,
    p.enabled
from cedar_policies p
order by p.priority, p.effect desc;

comment on view cedar_effective_permissions is 'Human-readable view of all authorization policies';


-- View of user memberships
create or replace view cedar_user_memberships as
select
    e.entity_id as user_id,
    e.display_name as user_name,
    array_agg(distinct case when p.parent_type = 'Role' then p.parent_id end)
        filter (where p.parent_type = 'Role') as roles,
    array_agg(distinct case when p.parent_type = 'Group' then p.parent_id end)
        filter (where p.parent_type = 'Group') as groups
from cedar_entities e
left join cedar_entity_parents p on e.entity_type = p.child_type and e.entity_id = p.child_id
where e.entity_type = 'User'
group by e.entity_id, e.display_name;

comment on view cedar_user_memberships is 'View of users with their role and group memberships';
