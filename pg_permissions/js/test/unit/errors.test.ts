import { describe, expect, it } from 'vitest'
import {
  PermissionsError,
  PermissionsFetchError,
  PermissionsHttpError,
  isFgaError,
  isPermissionsError,
  isRbacError,
  parseDetail,
} from '../../src/lib/errors'

// The DETAIL strings from pg_permissions/docs/errors-and-limits.md.
const FGA_FIXTURES: Array<[string, number, string]> = [
  ['openfga:2000 validation_error', 2000, 'validation_error'],
  ['openfga:2001 authorization_model_not_found', 2001, 'authorization_model_not_found'],
  ['openfga:2002 authorization_model_resolution_too_complex', 2002, 'authorization_model_resolution_too_complex'],
  ['openfga:2003 invalid_write_input', 2003, 'invalid_write_input'],
  ['openfga:2004 cannot_allow_duplicate_tuples_in_one_request', 2004, 'cannot_allow_duplicate_tuples_in_one_request'],
  ['openfga:2007 invalid_continuation_token', 2007, 'invalid_continuation_token'],
  ['openfga:2017 write_failed_due_to_invalid_input', 2017, 'write_failed_due_to_invalid_input'],
  ['openfga:2020 latest_authorization_model_not_found', 2020, 'latest_authorization_model_not_found'],
  ['openfga:2021 type_not_found', 2021, 'type_not_found'],
  ['openfga:2022 relation_not_found', 2022, 'relation_not_found'],
  ['openfga:2027 invalid_tuple', 2027, 'invalid_tuple'],
  ['openfga:2047 type_invalid_pattern', 2047, 'type_invalid_pattern'],
  ['openfga:2050 relations_invalid_pattern', 2050, 'relations_invalid_pattern'],
  ['openfga:2053 exceeded_entity_limit', 2053, 'exceeded_entity_limit'],
  ['openfga:2056 invalid_authorization_model', 2056, 'invalid_authorization_model'],
  ['openfga:2057 unsupported_schema_version', 2057, 'unsupported_schema_version'],
]

const RBAC_FIXTURES: Array<[string, string, Record<string, string>]> = [
  ["rbac:role_exists role='viewer'", 'role_exists', { role: 'viewer' }],
  ['rbac:name_overlap', 'name_overlap', {}],
  ["rbac:unknown_role role='admn'", 'unknown_role', { role: 'admn' }],
  ["rbac:role_in_use role='viewer'", 'role_in_use', { role: 'viewer' }],
  ['rbac:null_argument argument=role', 'null_argument', { argument: 'role' }],
  ['rbac:null_argument argument=user_id', 'null_argument', { argument: 'user_id' }],
]

describe('parseDetail', () => {
  it.each(FGA_FIXTURES)('parses %s', (detail, code, name) => {
    expect(parseDetail(detail)).toEqual({ model: 'openfga', code, name })
  })

  it.each(RBAC_FIXTURES)('parses %s', (detail, code, context) => {
    expect(parseDetail(detail)).toEqual({ model: 'rbac', code, context })
  })

  it('unquotes SQL literals from format(%L)', () => {
    expect(parseDetail("rbac:unknown_role role='it''s'")).toEqual({
      model: 'rbac',
      code: 'unknown_role',
      context: { role: "it's" },
    })
    expect(parseDetail("rbac:unknown_role role=E'a\\\\b'")).toEqual({
      model: 'rbac',
      code: 'unknown_role',
      context: { role: 'a\\b' },
    })
    expect(parseDetail("rbac:x a='one two' b=3")).toEqual({
      model: 'rbac',
      code: 'x',
      context: { a: 'one two', b: '3' },
    })
  })

  it('keeps the code when the context is malformed', () => {
    expect(parseDetail("rbac:unknown_role role='unterminated")).toEqual({
      model: 'rbac',
      code: 'unknown_role',
      context: {},
    })
  })

  it('returns null for other details', () => {
    expect(parseDetail(null)).toBeNull()
    expect(parseDetail(undefined)).toBeNull()
    expect(parseDetail('')).toBeNull()
    expect(parseDetail('Key (id)=(1) already exists.')).toBeNull()
    expect(parseDetail('openfga:abc validation_error')).toBeNull()
    expect(parseDetail('rbac:')).toBeNull()
  })
})

describe('PermissionsError', () => {
  it('has the PostgrestError fields and a parsed reason', () => {
    const e = new PermissionsError({
      message: "unknown role 'admn'",
      details: "rbac:unknown_role role='admn'",
      hint: 'No roles exist yet: create it first.',
      code: '22023',
    })
    expect(e).toBeInstanceOf(Error)
    expect(e.name).toBe('PermissionsError')
    expect(e.message).toBe("unknown role 'admn'")
    expect(e.details).toBe("rbac:unknown_role role='admn'")
    expect(e.hint).toBe('No roles exist yet: create it first.')
    expect(e.code).toBe('22023')
    expect(e.reason).toEqual({ model: 'rbac', code: 'unknown_role', context: { role: 'admn' } })
    expect(JSON.parse(JSON.stringify(e))).toEqual({
      name: 'PermissionsError',
      message: "unknown role 'admn'",
      details: "rbac:unknown_role role='admn'",
      hint: 'No roles exist yet: create it first.',
      code: '22023',
    })
  })

  it('has a null reason for plain Postgres errors', () => {
    const e = new PermissionsError({ message: 'permission denied for function fga_check', code: '42501' })
    expect(e.reason).toBeNull()
    expect(e.details).toBeNull()
    expect(e.hint).toBeNull()
  })

  it('has fetch and http subclasses', () => {
    const cause = new TypeError('fetch failed')
    const f = new PermissionsFetchError('Failed to send a request', cause)
    expect(f).toBeInstanceOf(PermissionsError)
    expect(f.name).toBe('PermissionsFetchError')
    expect(f.cause).toBe(cause)
    expect(f.details).toBe('fetch failed')
    expect(f.code).toBe('')

    const h = new PermissionsHttpError(502, 'Bad Gateway', '<html>')
    expect(h).toBeInstanceOf(PermissionsError)
    expect(h.name).toBe('PermissionsHttpError')
    expect(h.status).toBe(502)
    expect(h.body).toBe('<html>')
    expect(h.message).toBe('HTTP 502 Bad Gateway')
  })
})

describe('guards', () => {
  const rbac = new PermissionsError({ message: 'm', details: "rbac:role_in_use role='viewer'", code: '2BP01' })
  const fga = new PermissionsError({ message: 'm', details: 'openfga:2001 authorization_model_not_found', code: '22023' })
  const pg = new PermissionsError({ message: 'm', code: '57014' })

  it('isPermissionsError', () => {
    expect(isPermissionsError(rbac)).toBe(true)
    expect(isPermissionsError(new PermissionsFetchError('x', null))).toBe(true)
    expect(isPermissionsError(new Error('x'))).toBe(false)
    expect(isPermissionsError({ message: 'x', code: '1' })).toBe(false)
    expect(isPermissionsError(null)).toBe(false)
  })

  it('isRbacError', () => {
    expect(isRbacError(rbac)).toBe(true)
    expect(isRbacError(rbac, 'role_in_use')).toBe(true)
    expect(isRbacError(rbac, 'unknown_role')).toBe(false)
    expect(isRbacError(fga)).toBe(false)
    expect(isRbacError(pg)).toBe(false)
    if (isRbacError(rbac)) expect(rbac.reason.context.role).toBe('viewer')
  })

  it('isFgaError', () => {
    expect(isFgaError(fga)).toBe(true)
    expect(isFgaError(fga, 2001)).toBe(true)
    expect(isFgaError(fga, 'authorization_model_not_found')).toBe(true)
    expect(isFgaError(fga, 2000)).toBe(false)
    expect(isFgaError(fga, 'validation_error')).toBe(false)
    expect(isFgaError(rbac)).toBe(false)
    expect(isFgaError(pg)).toBe(false)
  })
})
