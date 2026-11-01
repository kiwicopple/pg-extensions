import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type pg from 'pg'
import { RbacClient } from '../../src/rbac'
import type { RbacSqlClient } from '../../src/rbac'
import { sqlTransport } from '../../src/transport/sql'
import { PermissionsError, isRbacError } from '../../src/lib/errors'
import { REST_URL, authHeaders, ownerPool, servicePool, userToken } from './helpers'

// Shared database: another test file may run FGA tests at the same time. This file
// cleans only the RBAC tables, and uses names with the prefix rbac_t_.
let owner: pg.Pool
let service: pg.Pool
let admin: RbacSqlClient

async function resetRbac() {
  await owner.query(
    'truncate permissions.rbac_assignments, permissions.rbac_role_inherits, permissions.rbac_role_permissions, permissions.rbac_role_closure, permissions.rbac_roles cascade',
  )
}

const READ = 'rbac_t_documents.read'
const EDIT = 'rbac_t_documents.edit'
const VIEWER = 'rbac_t_viewer'
const EDITOR = 'rbac_t_editor'
const ACME = 'rbac_t_acme'
const ALICE = 'rbac_t_alice'
const BOB = 'rbac_t_bob'

beforeAll(async () => {
  owner = ownerPool()
  service = servicePool()
  admin = new RbacClient({ transport: sqlTransport(service) })
  await resetRbac()
})

afterAll(async () => {
  await resetRbac()
  await service?.end()
  await owner?.end()
})

/** Returns the data of a result and checks that it has no error. */
function ok<T>(result: { data: T | null; error: PermissionsError | null }): T {
  expect(result.error).toBeNull()
  return result.data as T
}

/** Returns the error of a result and checks that it has no data. */
function failed(result: { data: unknown; error: PermissionsError | null }): PermissionsError {
  expect(result.data).toBeNull()
  expect(result.error).toBeInstanceOf(PermissionsError)
  return result.error as PermissionsError
}

describe('RbacClient on the SQL transport (service_role)', () => {
  it('creates roles with inheritance', async () => {
    expect(ok(await admin.admin.createRole({ role: VIEWER, permissions: [READ] }))).toBeNull()
    expect(ok(await admin.admin.createRole({ role: EDITOR, permissions: [EDIT], inherits: [VIEWER] }))).toBeNull()
  })

  it('assigns roles in a scope and app-wide, and is idempotent', async () => {
    expect(ok(await admin.admin.assignRole({ userId: ALICE, role: EDITOR, scope: ACME }))).toBeNull()
    expect(ok(await admin.admin.assignRole({ userId: ALICE, role: EDITOR, scope: ACME }))).toBeNull()
    expect(ok(await admin.admin.assignRole({ userId: ALICE, role: VIEWER }))).toBeNull()
    expect(ok(await admin.admin.assignRole({ userId: BOB, role: VIEWER, scope: ACME }))).toBeNull()
    expect(ok(await admin.admin.assignRole({ userId: BOB, role: VIEWER, scope: null }))).toBeNull()
    expect(ok(await admin.admin.unassignRole({ userId: BOB, role: VIEWER, scope: null }))).toBeNull()
  })

  it('lists the permissions of a user, with inheritance', async () => {
    expect(ok(await admin.admin.userPermissions({ userId: ALICE, scope: ACME }))).toEqual([EDIT, READ])
    expect(ok(await admin.admin.userPermissions({ userId: ALICE }))).toEqual([READ])
    expect(ok(await admin.admin.userPermissions({ userId: ALICE, scope: null }))).toEqual([READ])
    expect(ok(await admin.admin.userPermissions({ userId: BOB, scope: ACME }))).toEqual([READ])
    expect(ok(await admin.admin.userPermissions({ userId: BOB }))).toEqual([])
    expect(ok(await admin.admin.userPermissions({ userId: 'rbac_t_nobody', scope: ACME }))).toEqual([])
  })

  it('lists the users of a role, with inheritance', async () => {
    expect(ok(await admin.admin.usersWithRole({ role: VIEWER, scope: ACME })).sort()).toEqual([ALICE, BOB])
    expect(ok(await admin.admin.usersWithRole({ role: EDITOR, scope: ACME }))).toEqual([ALICE])
    expect(ok(await admin.admin.usersWithRole({ role: VIEWER }))).toEqual([ALICE])
    expect(ok(await admin.admin.usersWithRole({ role: EDITOR }))).toEqual([])
    expect(ok(await admin.admin.usersWithRole({ role: 'rbac_t_unknown' }))).toEqual([])
  })

  it('checks the current subject with withSubject()', async () => {
    const alice = new RbacClient({ transport: sqlTransport(service).withSubject({ id: ALICE }) })
    const bob = new RbacClient({ transport: sqlTransport(service).withSubject({ id: BOB }) })
    expect(ok(await alice.hasPermission({ permission: EDIT, scope: ACME }))).toBe(true)
    expect(ok(await alice.hasPermission({ permission: READ, scope: ACME }))).toBe(true)
    expect(ok(await alice.hasPermission({ permission: EDIT }))).toBe(false)
    expect(ok(await alice.hasPermission({ permission: EDIT, scope: null }))).toBe(false)
    expect(ok(await alice.hasPermission({ permission: READ }))).toBe(true)
    expect(ok(await alice.hasPermission({ permission: 'rbac_t_unknown' }))).toBe(false)
    expect(ok(await alice.hasRole({ role: EDITOR, scope: ACME }))).toBe(true)
    expect(ok(await alice.hasRole({ role: VIEWER, scope: ACME }))).toBe(true)
    expect(ok(await alice.hasRole({ role: EDITOR }))).toBe(false)
    expect(ok(await alice.hasRole({ role: VIEWER }))).toBe(true)
    expect(ok(await alice.scopesWithPermission({ permission: EDIT }))).toEqual([ACME])
    expect(ok(await alice.scopesWithPermission({ permission: 'rbac_t_unknown' }))).toEqual([])
    expect(ok(await bob.hasPermission({ permission: EDIT, scope: ACME }))).toBe(false)
    expect(ok(await bob.hasPermission({ permission: READ, scope: ACME }))).toBe(true)
    expect(ok(await bob.hasRole({ role: VIEWER }))).toBe(false)
    expect(ok(await bob.scopesWithPermission({ permission: READ }))).toEqual([ACME])
  })

  it('answers false and [] without a subject', async () => {
    const none = new RbacClient({ transport: sqlTransport(service) })
    expect(ok(await none.hasPermission({ permission: READ }))).toBe(false)
    expect(ok(await none.hasRole({ role: VIEWER, scope: ACME }))).toBe(false)
    expect(ok(await none.scopesWithPermission({ permission: READ }))).toEqual([])
  })

  it('removes an assignment', async () => {
    const alice = new RbacClient({ transport: sqlTransport(service).withSubject({ id: ALICE }) })
    expect(ok(await admin.admin.unassignRole({ userId: ALICE, role: EDITOR, scope: ACME }))).toBeNull()
    expect(ok(await admin.admin.unassignRole({ userId: ALICE, role: EDITOR, scope: ACME }))).toBeNull() // idempotent
    expect(ok(await alice.hasPermission({ permission: EDIT, scope: ACME }))).toBe(false)
    expect(ok(await admin.admin.userPermissions({ userId: ALICE, scope: ACME }))).toEqual([])
    expect(ok(await admin.admin.assignRole({ userId: ALICE, role: EDITOR, scope: ACME }))).toBeNull()
    expect(ok(await alice.hasPermission({ permission: EDIT, scope: ACME }))).toBe(true)
  })

  it('returns role_exists, with code 23505 and the role in the context', async () => {
    const e = failed(await admin.admin.createRole({ role: VIEWER, permissions: [] }))
    expect(isRbacError(e, 'role_exists')).toBe(true)
    expect(e.code).toBe('23505')
    expect(e.reason).toEqual({ model: 'rbac', code: 'role_exists', context: { role: VIEWER } })
    expect(e.hint).toBeTruthy()
  })

  it('returns name_overlap for a role that is a permission, and a permission that is a role', async () => {
    const asPermission = failed(await admin.admin.createRole({ role: 'rbac_t_x', permissions: [VIEWER] }))
    expect(isRbacError(asPermission, 'name_overlap')).toBe(true)
    expect(asPermission.code).toBe('22023')
    expect(asPermission.reason).toEqual({ model: 'rbac', code: 'name_overlap', context: {} })
    const self = failed(await admin.admin.createRole({ role: 'rbac_t_self', permissions: ['rbac_t_self'] }))
    expect(isRbacError(self, 'name_overlap')).toBe(true)
    const asRole = failed(await admin.admin.createRole({ role: READ, permissions: [] }))
    expect(isRbacError(asRole, 'name_overlap')).toBe(true)
  })

  it('returns unknown_role from createRole, assignRole and dropRole', async () => {
    const create = failed(await admin.admin.createRole({ role: 'rbac_t_y', permissions: [], inherits: ['rbac_t_nope'] }))
    expect(isRbacError(create, 'unknown_role')).toBe(true)
    expect(create.code).toBe('22023')
    expect(create.reason).toEqual({ model: 'rbac', code: 'unknown_role', context: { role: 'rbac_t_nope' } })
    const assign = failed(await admin.admin.assignRole({ userId: ALICE, role: 'rbac_t_edtor' }))
    expect(assign.reason).toEqual({ model: 'rbac', code: 'unknown_role', context: { role: 'rbac_t_edtor' } })
    expect(assign.hint).toContain(EDITOR)
    const drop = failed(await admin.admin.dropRole({ role: 'rbac_t_nope' }))
    expect(drop.reason).toEqual({ model: 'rbac', code: 'unknown_role', context: { role: 'rbac_t_nope' } })
  })

  it('returns role_in_use, with code 2BP01, when another role inherits the role', async () => {
    const e = failed(await admin.admin.dropRole({ role: VIEWER }))
    expect(isRbacError(e, 'role_in_use')).toBe(true)
    expect(e.code).toBe('2BP01')
    expect(e.reason).toEqual({ model: 'rbac', code: 'role_in_use', context: { role: VIEWER } })
    expect(e.hint).toContain(EDITOR)
  })

  it('returns null_argument for each null argument', async () => {
    const cases: Array<[Promise<{ data: unknown; error: PermissionsError | null }>, string]> = [
      [admin.admin.createRole({ role: null as never, permissions: [] }), 'role'],
      [admin.admin.createRole({ role: 'rbac_t_z', permissions: null as never }), 'permissions'],
      [admin.admin.createRole({ role: 'rbac_t_z', permissions: [], inherits: null as never }), 'inherits'],
      [admin.admin.assignRole({ userId: null as never, role: VIEWER }), 'user_id'],
      [admin.admin.unassignRole({ userId: null as never, role: VIEWER }), 'user_id'],
      [admin.admin.unassignRole({ userId: ALICE, role: null as never }), 'role'],
    ]
    for (const [pending, argument] of cases) {
      const e = failed(await pending)
      expect(isRbacError(e, 'null_argument')).toBe(true)
      expect(e.code).toBe('22004')
      expect(e.reason).toEqual({ model: 'rbac', code: 'null_argument', context: { argument } })
    }
  })

  it('throws the error with throwOnError', async () => {
    const strict = new RbacClient({ transport: sqlTransport(service), throwOnError: true })
    const e = await strict.admin.dropRole({ role: 'rbac_t_nope' }).catch((x: unknown) => x)
    expect(isRbacError(e, 'unknown_role')).toBe(true)
    expect(ok(await strict.hasPermission({ permission: READ }))).toBe(false)
  })

  it('returns 42501 with a null reason for an admin call as authenticated', async () => {
    const asUser = new RbacClient({
      transport: sqlTransport(service).withSubject({ id: ALICE, role: 'authenticated' }),
    }) as unknown as RbacSqlClient
    const e = failed(await asUser.admin.assignRole({ userId: ALICE, role: VIEWER }))
    expect(e.code).toBe('42501')
    expect(e.reason).toBeNull()
    // The client checks still work as authenticated.
    expect(ok(await asUser.hasPermission({ permission: READ }))).toBe(true)
  })

  it('drops roles, children first, with their assignments', async () => {
    expect(ok(await admin.admin.dropRole({ role: EDITOR }))).toBeNull()
    expect(ok(await admin.admin.userPermissions({ userId: ALICE, scope: ACME }))).toEqual([])
    expect(ok(await admin.admin.usersWithRole({ role: EDITOR, scope: ACME }))).toEqual([])
    expect(ok(await admin.admin.dropRole({ role: VIEWER }))).toBeNull()
    expect(ok(await admin.admin.userPermissions({ userId: ALICE }))).toEqual([])
    const again = failed(await admin.admin.dropRole({ role: VIEWER }))
    expect(isRbacError(again, 'unknown_role')).toBe(true)
  })
})

describe('RbacClient on PostgREST', () => {
  const alice = () =>
    new RbacClient(REST_URL, { headers: authHeaders(userToken(ALICE)), schema: 'permissions' })

  beforeAll(async () => {
    await resetRbac()
    ok(await admin.admin.createRole({ role: VIEWER, permissions: [READ] }))
    ok(await admin.admin.createRole({ role: EDITOR, permissions: [EDIT], inherits: [VIEWER] }))
    ok(await admin.admin.assignRole({ userId: ALICE, role: EDITOR, scope: ACME }))
    ok(await admin.admin.assignRole({ userId: ALICE, role: VIEWER }))
  })

  it('has no admin namespace', () => {
    expect('admin' in alice()).toBe(false)
  })

  it('checks permissions and roles for the JWT subject', async () => {
    const rbac = alice()
    expect(ok(await rbac.hasPermission({ permission: EDIT, scope: ACME }))).toBe(true)
    expect(ok(await rbac.hasPermission({ permission: EDIT }))).toBe(false)
    expect(ok(await rbac.hasPermission({ permission: EDIT, scope: null }))).toBe(false)
    expect(ok(await rbac.hasPermission({ permission: READ }))).toBe(true)
    expect(ok(await rbac.hasRole({ role: VIEWER, scope: ACME }))).toBe(true)
    expect(ok(await rbac.hasRole({ role: EDITOR }))).toBe(false)
  })

  it('lists scopes without the guard argument', async () => {
    const rbac = alice()
    expect(ok(await rbac.scopesWithPermission({ permission: EDIT }))).toEqual([ACME])
    expect(ok(await rbac.scopesWithPermission({ permission: 'rbac_t_unknown' }))).toEqual([])
  })

  it('answers false and [] for another subject and for anon', async () => {
    const bob = new RbacClient(REST_URL, { headers: authHeaders(userToken(BOB)) })
    expect(ok(await bob.hasPermission({ permission: READ }))).toBe(false)
    expect(ok(await bob.scopesWithPermission({ permission: READ }))).toEqual([])
    const anon = new RbacClient(REST_URL)
    expect(ok(await anon.hasRole({ role: VIEWER }))).toBe(false)
  })

  it('returns a PermissionsError for a bad schema', async () => {
    const rbac = new RbacClient(REST_URL, { headers: authHeaders(userToken(ALICE)), schema: 'rbac_t_nope' })
    const e = failed(await rbac.hasRole({ role: VIEWER }))
    expect(e).toBeInstanceOf(PermissionsError)
  })
})
