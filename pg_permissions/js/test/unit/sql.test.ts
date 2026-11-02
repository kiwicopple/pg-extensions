import { describe, expect, expectTypeOf, it } from 'vitest'
import type { Transport } from '../../src/lib/types'
import { buildCall, sqlTransport, toPermissionsError } from '../../src/transport/sql'
import { PermissionsError, PermissionsFetchError } from '../../src/lib/errors'

type Query = { conn: string; text: string; values: unknown[] | undefined }

/** A fake `query()`: records each statement, answers from `respond`. */
function fakeDb(respond: (text: string, values?: unknown[]) => { rows: any[] } | Error = () => ({ rows: [] })) {
  const log: Query[] = []
  const conn = (name: string) => ({
    async query(text: string, values?: unknown[]) {
      log.push({ conn: name, text, values })
      await Promise.resolve()
      const r = respond(text, values)
      if (r instanceof Error) throw r
      return r
    },
  })
  return { log, conn }
}

function pgError(fields: { message: string; code: string; detail?: string; hint?: string }) {
  return Object.assign(new Error(fields.message), fields, { severity: 'ERROR' })
}

describe('buildCall', () => {
  it('builds named, cast arguments in catalog order, from the allow-list only', () => {
    expect(buildCall('"permissions"', 'rbac_has_permission', { scope: 'acme', permission: 'p' }, 'scalar')).toEqual({
      text: 'select "permissions".rbac_has_permission(permission => $1::text, scope => $2::text) as value',
      values: ['p', 'acme'],
    })
  })

  it('omits undefined arguments and keeps null', () => {
    expect(buildCall('"permissions"', 'rbac_assign_role', { user_id: 'u', role: 'r', scope: undefined }, 'void').text).toBe(
      'select "permissions".rbac_assign_role(user_id => $1::text, role => $2::text)',
    )
    expect(buildCall('"permissions"', 'rbac_assign_role', { user_id: 'u', role: 'r', scope: null }, 'void').values).toEqual([
      'u',
      'r',
      null,
    ])
  })

  it('sends jsonb as JSON text and text[] as arrays', () => {
    const { text, values } = buildCall(
      '"permissions"',
      'fga_check',
      { subject: 'user:a', relation: 'viewer', object: 'doc:1', context: { ip: '1.2.3.4' }, contextual_tuples: null },
      'scalar',
    )
    expect(text).toBe(
      'select "permissions".fga_check(subject => $1::text, relation => $2::text, object => $3::text, contextual_tuples => $4::jsonb, context => $5::jsonb) as value',
    )
    expect(values).toEqual(['user:a', 'viewer', 'doc:1', null, '{"ip":"1.2.3.4"}'])
    expect(buildCall('"permissions"', 'rbac_create_role', { role: 'r', permissions: ['a', 'b'] }, 'void').values).toEqual([
      'r',
      ['a', 'b'],
    ])
  })

  it('builds each shape', () => {
    expect(buildCall('"permissions"', 'fga_list_objects_current', { type: 't', relation: 'r' }, 'set').text).toBe(
      'select value from "permissions".fga_list_objects_current(type => $1::text, relation => $2::text) as t(value)',
    )
    expect(buildCall('"permissions"', 'fga_read', { page_size: 10 }, 'record').text).toBe(
      'select * from "permissions".fga_read(page_size => $1::int)',
    )
    expect(buildCall('"permissions"', 'fga_read_authorization_models', {}, 'rows').text).toBe(
      'select * from "permissions".fga_read_authorization_models()',
    )
  })

  it('refuses unknown functions and arguments', () => {
    expect(() => buildCall('"permissions"', 'pg_sleep', {}, 'scalar')).toThrow(/unknown function 'pg_sleep'/)
    expect(() => buildCall('"permissions"', 'toString', {}, 'scalar')).toThrow(/unknown function/)
    expect(() => buildCall('"permissions"', 'rbac_scopes_with_permission', { permission: 'p', plan_time_guard: true }, 'scalar')).toThrow(
      /no argument 'plan_time_guard'/,
    )
    expect(() => buildCall('"permissions"', 'rbac_has_role', { 'role) or true; --': 'x' }, 'scalar')).toThrow(/no argument/)
  })
})

describe('sqlTransport', () => {
  it('reads each shape', async () => {
    const { conn } = fakeDb((text) => {
      if (text.includes('as value')) return { rows: [{ value: true }] }
      if (text.includes('t(value)')) return { rows: [{ value: 'a' }, { value: 'b' }] }
      if (text.includes('select *')) return { rows: [{ tuples: [], continuation_token: '' }] }
      return { rows: [{ rbac_drop_role: '' }] }
    })
    const t = sqlTransport(conn('c'))
    expect(t.kind).toBe('sql')
    expect(await t.rpc('rbac_has_role', { role: 'r' }, 'scalar')).toBe(true)
    expect(await t.rpc('rbac_users_with_role', { role: 'r' }, 'set')).toEqual(['a', 'b'])
    expect(await t.rpc('fga_read', {}, 'record')).toEqual({ tuples: [], continuation_token: '' })
    expect(await t.rpc('fga_read_authorization_models', {}, 'rows')).toEqual([{ tuples: [], continuation_token: '' }])
    expect(await t.rpc('rbac_drop_role', { role: 'r' }, 'void')).toBeNull()
  })

  it('uses the schema option, and refuses a bad schema name', async () => {
    const { log, conn } = fakeDb(() => ({ rows: [{ value: 'u' }] }))
    await sqlTransport(conn('c'), { schema: 'authz' }).rpc('current_subject_id', {}, 'scalar')
    expect(log[0]?.text).toBe('select "authz".current_subject_id() as value')
    expect(() => sqlTransport(conn('c'), { schema: 'x"; drop' })).toThrow(/invalid schema/)
  })

  it('maps Postgres errors to PermissionsError', async () => {
    const { conn } = fakeDb(() =>
      pgError({
        message: "unknown role 'admn'",
        code: '22023',
        detail: "rbac:unknown_role role='admn'",
        hint: 'Create it first.',
      }),
    )
    const e = (await sqlTransport(conn('c'))
      .rpc('rbac_assign_role', { user_id: 'u', role: 'admn' }, 'void')
      .catch((x: unknown) => x)) as PermissionsError
    expect(e).toBeInstanceOf(PermissionsError)
    expect(e.message).toBe("unknown role 'admn'")
    expect(e.details).toBe("rbac:unknown_role role='admn'")
    expect(e.hint).toBe('Create it first.')
    expect(e.code).toBe('22023')
    expect(e.reason).toEqual({ model: 'rbac', code: 'unknown_role', context: { role: 'admn' } })
  })

  it('maps connection errors to PermissionsFetchError', () => {
    const cause = Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' })
    const e = toPermissionsError(cause)
    expect(e).toBeInstanceOf(PermissionsFetchError)
    expect((e as PermissionsFetchError).cause).toBe(cause)
  })

  it('treats Node errno codes as connection errors, not Postgres errors', () => {
    for (const code of ['EPIPE', 'EPERM', 'EBADF']) {
      const cause = Object.assign(new Error(`write ${code}`), { code, errno: -32, syscall: 'write' })
      const e = toPermissionsError(cause)
      expect(e).toBeInstanceOf(PermissionsFetchError)
      expect((e as PermissionsFetchError).cause).toBe(cause)
    }
  })

  it('maps a real-shaped DatabaseError (SQLSTATE + severity) to PermissionsError', () => {
    // node-postgres: DatabaseError extends Error, with severity, code, detail, hint, ...
    const cause = Object.assign(new Error('permission denied for function x'), {
      name: 'error',
      length: 100,
      severity: 'ERROR',
      code: '42501',
      detail: undefined,
      hint: undefined,
      routine: 'aclcheck_error',
    })
    const e = toPermissionsError(cause)
    expect(e).toBeInstanceOf(PermissionsError)
    expect(e).not.toBeInstanceOf(PermissionsFetchError)
    expect((e as PermissionsError).code).toBe('42501')
  })

  it('rejects (does not throw synchronously) for an unknown function', async () => {
    const { log, conn } = fakeDb()
    const t = sqlTransport(conn('c'))
    const p = t.rpc('nope', {}, 'scalar')
    await expect(p).rejects.toThrow(/unknown function/)
    const s = t.withSubject({ id: 'alice' }).rpc('nope', {}, 'scalar')
    await expect(s).rejects.toThrow(/unknown function/)
    expect(log).toHaveLength(0)
  })
})

describe('withSubject', () => {
  it('runs the call in a transaction on a dedicated pool client', async () => {
    const { log, conn } = fakeDb((text) => (text.includes('as value') ? { rows: [{ value: true }] } : { rows: [] }))
    const released: unknown[] = []
    const pool = {
      ...conn('pool'),
      async connect() {
        return { ...conn('client'), release: (err?: unknown) => void released.push(err ?? 'ok') }
      },
    }
    const alice = sqlTransport(pool).withSubject({ id: 'alice', role: 'authenticated' })
    expect(alice.kind).toBe('subject')
    expect(await alice.rpc('rbac_has_permission', { permission: 'p' }, 'scalar')).toBe(true)
    expect(log.map((q) => [q.conn, q.text])).toEqual([
      ['client', 'begin'],
      ['client', 'set local role "authenticated"'],
      [
        'client',
        "select set_config('permissions.subject_id', $1, true), set_config('permissions.subject_type', $2, true), set_config('request.jwt.claims', '', true)",
      ],
      ['client', 'select "permissions".rbac_has_permission(permission => $1::text) as value'],
      ['client', 'commit'],
    ])
    expect(log[2]?.values).toEqual(['alice', 'user'])
    expect(released).toEqual(['ok'])
  })

  it('passes the subject type and omits set role without a role', async () => {
    const { log, conn } = fakeDb()
    await sqlTransport(conn('c'))
      .withSubject({ id: 'eng', type: 'team' })
      .rpc('fga_list_objects_current', { type: 'doc', relation: 'viewer' }, 'set')
    expect(log.map((q) => q.text)).not.toContain(expect.stringContaining('set local role'))
    expect(log[1]?.values).toEqual(['eng', 'team'])
  })

  it('rolls back on error and releases the client', async () => {
    const { log, conn } = fakeDb((text) =>
      text.includes('fga_check_current') ? pgError({ message: 'bad', code: '22023', detail: 'openfga:2000 validation_error' }) : { rows: [] },
    )
    const released: unknown[] = []
    const pool = {
      ...conn('pool'),
      async connect() {
        return { ...conn('client'), release: (err?: unknown) => void released.push(err ?? 'ok') }
      },
    }
    const e = await sqlTransport(pool)
      .withSubject({ id: 'alice' })
      .rpc('fga_check_current', { relation: 'viewr', object: 'doc:1' }, 'scalar')
      .catch((x: unknown) => x)
    expect(e).toBeInstanceOf(PermissionsError)
    expect(log.map((q) => q.text.split(' ')[0])).toEqual(['begin', 'select', 'select', 'rollback'])
    expect(log.map((q) => q.text)).not.toContain('commit')
    expect(released).toEqual(['ok'])
  })

  it('destroys the client when the rollback fails', async () => {
    const rollbackError = new Error('connection lost')
    const { conn } = fakeDb((text) =>
      text === 'rollback' ? rollbackError : text.includes('rbac_has_role') ? pgError({ message: 'x', code: '57014' }) : { rows: [] },
    )
    const released: unknown[] = []
    const pool = {
      ...conn('pool'),
      async connect() {
        return { ...conn('client'), release: (err?: unknown) => void released.push(err ?? 'ok') }
      },
    }
    const e = (await sqlTransport(pool)
      .withSubject({ id: 'a' })
      .rpc('rbac_has_role', { role: 'r' }, 'scalar')
      .catch((x: unknown) => x)) as PermissionsError
    expect(e.code).toBe('57014')
    expect(released).toEqual([rollbackError])
  })

  it('validates the role as an identifier', () => {
    const { conn } = fakeDb()
    const t = sqlTransport(conn('c'))
    expect(() => t.withSubject({ id: 'a', role: 'authenticated; drop table x' })).toThrow(/invalid role/)
    expect(() => t.withSubject({ id: 'a', role: '"x"' })).toThrow(/invalid role/)
    expect(() => t.withSubject({ id: 'a', role: 'service_role' })).not.toThrow()
  })

  it('rejects an empty subject id at withSubject()', () => {
    const { log, conn } = fakeDb()
    const t = sqlTransport(conn('c'))
    expect(() => t.withSubject({ id: '' })).toThrow(/subject id/)
    expect(() => t.withSubject({ id: undefined as never })).toThrow(/subject id/)
    expect(log).toHaveLength(0)
  })

  it('marks a pool client broken on a connection error (EPIPE), not on a Postgres error', async () => {
    const epipe = Object.assign(new Error('write EPIPE'), { code: 'EPIPE' })
    const { conn } = fakeDb((text) => (text.includes('rbac_has_role') ? epipe : { rows: [] }))
    const released: unknown[] = []
    const pool = {
      ...conn('pool'),
      async connect() {
        return { ...conn('client'), release: (err?: unknown) => void released.push(err ?? 'ok') }
      },
    }
    const e = await sqlTransport(pool)
      .withSubject({ id: 'a' })
      .rpc('rbac_has_role', { role: 'r' }, 'scalar')
      .catch((x: unknown) => x)
    expect(e).toBeInstanceOf(PermissionsFetchError)
    expect(released).toHaveLength(1)
    expect(released[0]).toBe(e)
  })

  it('shares one queue between transports over the same single connection', async () => {
    const { log, conn } = fakeDb((text) => (text.includes('as value') ? { rows: [{ value: 'x' }] } : { rows: [] }))
    const client = { ...conn('client'), connectionParameters: {}, async connect() {} }
    const a = sqlTransport(client as never)
    const b = sqlTransport(client as never)
    await Promise.all([
      a.withSubject({ id: 'alice' }).rpc('current_subject_id', {}, 'scalar'),
      b.withSubject({ id: 'bob' }).rpc('current_subject_id', {}, 'scalar'),
      b.rpc('current_subject_type', {}, 'scalar'),
    ])
    expect(log.map((q) => q.text.split(' ')[0] + (q.values?.length ? `:${String(q.values[0])}` : ''))).toEqual([
      'begin',
      'select:alice',
      'select',
      'commit',
      'begin',
      'select:bob',
      'select',
      'commit',
      'select',
    ])
  })

  it('poisons a single connection when the rollback fails', async () => {
    const rollbackError = new Error('connection lost')
    const { log, conn } = fakeDb((text) =>
      text === 'rollback' ? rollbackError : text.includes('rbac_has_role') ? pgError({ message: 'x', code: '57014' }) : { rows: [] },
    )
    const client = { ...conn('client'), connectionParameters: {}, async connect() {} }
    const a = sqlTransport(client as never)
    const e = (await a
      .withSubject({ id: 'a' })
      .rpc('rbac_has_role', { role: 'r' }, 'scalar')
      .catch((x: unknown) => x)) as PermissionsFetchError
    expect(e).toBeInstanceOf(PermissionsFetchError)
    expect(e.message).toMatch(/Replace the connection/)
    expect(e.cause).toBe(rollbackError)
    const before = log.length
    // Later calls fail without touching the connection, from any transport over it.
    for (const t of [a, sqlTransport(client as never)]) {
      await expect(t.rpc('current_subject_id', {}, 'scalar')).rejects.toBeInstanceOf(PermissionsFetchError)
      await expect(t.withSubject({ id: 'b' }).rpc('current_subject_id', {}, 'scalar')).rejects.toThrow(/Replace the connection/)
    }
    expect(log).toHaveLength(before)
  })

  it('does not poison a single connection when the rollback succeeds', async () => {
    const { conn } = fakeDb((text) =>
      text.includes('rbac_has_role') ? pgError({ message: 'x', code: '57014' }) : text.includes('as value') ? { rows: [{ value: 1 }] } : { rows: [] },
    )
    const client = { ...conn('client'), connectionParameters: {}, async connect() {} }
    const t = sqlTransport(client as never)
    const e = (await t.withSubject({ id: 'a' }).rpc('rbac_has_role', { role: 'r' }, 'scalar').catch((x: unknown) => x)) as PermissionsError
    expect(e.code).toBe('57014')
    expect(await t.rpc('current_subject_id', {}, 'scalar')).toBe(1)
  })

  it('serializes calls on a single connection so transactions do not interleave', async () => {
    const { log, conn } = fakeDb((text) => (text.includes('as value') ? { rows: [{ value: 'x' }] } : { rows: [] }))
    const client = { ...conn('client'), connectionParameters: {}, async connect() {} }
    const t = sqlTransport(client as never)
    await Promise.all([
      t.withSubject({ id: 'a' }).rpc('current_subject_id', {}, 'scalar'),
      t.rpc('current_subject_type', {}, 'scalar'),
      t.withSubject({ id: 'b' }).rpc('current_subject_id', {}, 'scalar'),
    ])
    expect(log.map((q) => q.text.split(' ')[0] + (q.values?.length ? `:${String(q.values[0])}` : ''))).toEqual([
      'begin',
      'select:a',
      'select',
      'commit',
      'select',
      'begin',
      'select:b',
      'select',
      'commit',
    ])
  })
})

describe('transport kinds (types)', () => {
  it('types sqlTransport as sql and withSubject as subject', () => {
    const t = sqlTransport({ query: async () => ({ rows: [] }) })
    expectTypeOf(t.kind).toEqualTypeOf<'sql'>()
    expectTypeOf(t.withSubject({ id: 'a' })).toEqualTypeOf<Transport<'subject'>>()
  })
})
