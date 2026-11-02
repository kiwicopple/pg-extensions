/** The SQL type of an argument. The SQL transport casts each parameter to it. */
export type ArgType = 'text' | 'text[]' | 'jsonb' | 'int'

export interface FunctionSpec {
  /** Granted to PUBLIC: answers for the current subject only. Only these can go over PostgREST. */
  public: boolean
  /** The argument names (as in the catalog) and their types. A name not listed here is refused. */
  args: Readonly<Record<string, ArgType>>
}

/**
 * Every `permissions.*` function that the library can call, from
 * pg_permissions--0.1.0.sql. The transports refuse any other name, and any
 * argument name not listed. This is what keeps user strings out of SQL
 * identifiers. The `plan_time_guard` arguments of `rbac_scopes_with_permission`
 * and of `cedar_is_authorized_current` are deliberately absent: they must
 * never be sent.
 */
export const FUNCTIONS: Readonly<Record<string, FunctionSpec>> = {
  // Shared
  current_subject_id: { public: true, args: {} },
  current_subject_type: { public: true, args: {} },
  delete_subject: { public: false, args: { subject_type: 'text', subject_id: 'text' } },

  // RBAC admin
  rbac_create_role: { public: false, args: { role: 'text', permissions: 'text[]', inherits: 'text[]' } },
  rbac_drop_role: { public: false, args: { role: 'text' } },
  rbac_assign_role: { public: false, args: { user_id: 'text', role: 'text', scope: 'text' } },
  rbac_unassign_role: { public: false, args: { user_id: 'text', role: 'text', scope: 'text' } },
  rbac_user_permissions: { public: false, args: { user_id: 'text', scope: 'text' } },
  rbac_users_with_role: { public: false, args: { role: 'text', scope: 'text' } },

  // RBAC current subject
  rbac_has_permission: { public: true, args: { permission: 'text', scope: 'text' } },
  rbac_has_role: { public: true, args: { role: 'text', scope: 'text' } },
  rbac_scopes_with_permission: { public: true, args: { permission: 'text' } },

  // FGA admin
  fga_write_authorization_model: { public: false, args: { model: 'jsonb' } },
  fga_read_authorization_model: { public: false, args: { model_id: 'text' } },
  fga_read_authorization_models: { public: false, args: {} },
  fga_delete_store: { public: false, args: {} },
  fga_write: { public: false, args: { writes: 'jsonb', deletes: 'jsonb', model_id: 'text' } },
  fga_write_tuple: { public: false, args: { subject: 'text', relation: 'text', object: 'text' } },
  fga_delete_tuple: { public: false, args: { subject: 'text', relation: 'text', object: 'text' } },
  fga_read: {
    public: false,
    args: { object: 'text', relation: 'text', subject: 'text', page_size: 'int', continuation_token: 'text' },
  },
  fga_check: {
    public: false,
    args: {
      subject: 'text',
      relation: 'text',
      object: 'text',
      contextual_tuples: 'jsonb',
      model_id: 'text',
      context: 'jsonb',
    },
  },
  fga_list_objects: {
    public: false,
    args: {
      subject: 'text',
      type: 'text',
      relation: 'text',
      contextual_tuples: 'jsonb',
      model_id: 'text',
      context: 'jsonb',
    },
  },
  fga_list_users: {
    public: false,
    args: {
      object: 'text',
      relation: 'text',
      user_filters: 'text[]',
      contextual_tuples: 'jsonb',
      model_id: 'text',
      context: 'jsonb',
    },
  },

  // FGA current subject
  fga_check_current: { public: true, args: { relation: 'text', object: 'text' } },
  fga_list_objects_current: { public: true, args: { type: 'text', relation: 'text' } },
  fga_list_object_ids_current: { public: true, args: { type: 'text', relation: 'text' } },

  // Cedar admin
  cedar_put_policy: { public: false, args: { policy_id: 'text', policy: 'text', policy_json: 'jsonb' } },
  cedar_delete_policy: { public: false, args: { policy_id: 'text' } },
  cedar_policies: { public: false, args: {} },
  cedar_put_template: { public: false, args: { template_id: 'text', template: 'text', template_json: 'jsonb' } },
  cedar_link_template: {
    public: false,
    args: { policy_id: 'text', template_id: 'text', principal: 'text', resource: 'text' },
  },
  cedar_delete_template: { public: false, args: { template_id: 'text' } },
  cedar_templates: { public: false, args: {} },
  cedar_put_entities: { public: false, args: { entities: 'jsonb' } },
  cedar_delete_entities: { public: false, args: { uids: 'jsonb' } },
  cedar_read_entities: { public: false, args: { type: 'text', ids: 'text[]' } },
  cedar_is_authorized: {
    public: false,
    args: { principal: 'text', action: 'text', resource: 'text', context: 'jsonb', entities: 'jsonb' },
  },

  // Cedar current subject. `plan_time_guard` of `cedar_is_authorized_current` is deliberately absent.
  cedar_is_authorized_current: { public: true, args: { action: 'text', resource: 'text', resource_attrs: 'jsonb' } },
  cedar_list_resources_current: { public: true, args: { action: 'text', resource_type: 'text' } },
}

/** Looks up a function and checks the argument names. Throws a plain `Error` for an unknown function or argument. */
export function getFunctionSpec(fn: string, args: Record<string, unknown>, transport: string): FunctionSpec {
  const spec = Object.prototype.hasOwnProperty.call(FUNCTIONS, fn) ? FUNCTIONS[fn] : undefined
  if (!spec) throw new Error(`permissions (${transport}): unknown function '${fn}'`)
  for (const name of Object.keys(args)) {
    if (!Object.prototype.hasOwnProperty.call(spec.args, name)) {
      const valid = Object.keys(spec.args)
      throw new Error(
        `permissions (${transport}): ${fn} has no argument '${name}'. Arguments: ${valid.length ? valid.join(', ') : '(none)'}.`,
      )
    }
  }
  return spec
}

/** Copies `args` without the `undefined` values, so the SQL defaults apply. */
export function definedArgs(args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const key of Object.keys(args)) {
    if (args[key] !== undefined) out[key] = args[key]
  }
  return out
}
