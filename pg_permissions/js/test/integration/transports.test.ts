import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import pg from 'pg'
import { sqlTransport } from '../../src/transport/sql'
import { postgrestTransport } from '../../src/transport/postgrest'
import { PermissionsError, isFgaError, isRbacError } from '../../src/lib/errors'
import { PG_URL, REST_URL, authHeaders, ownerPool, resetDatabase, servicePool, serviceToken, userToken } from './helpers'

const MODEL = {
  schema_version: '1.1',
  type_definitions: [
    { type: 'user' },
    {
      type: 'document',
      relations: { viewer: { this: {} } },
      metadata: { relations: { viewer: { directly_related_user_types: [{ type: 'user' }] } } },
    },
  ],
}

let owner: pg.Pool
let service: pg.Pool

beforeAll(async () => {
  owner = ownerPool()
  service = servicePool()
  await resetDatabase(owner)
  const sql = sqlTransport(service)
  await sql.rpc('rbac_create_role', { role: 'editor', permissions: ['documents.edit'] }, 'void')
  await sql.rpc('rbac_assign_role', { user_id: 'alice', role: 'editor', scope: 'acme' }, 'void')
  await sql.rpc('fga_write_authorization_model', { model: MODEL }, 'scalar')
  await sql.rpc('fga_write_tuple', { subject: 'user:alice', relation: 'viewer', object: 'document:1' }, 'void')
  await sql.rpc('fga_write_tuple', { subject: 'user:alice', relation: 'viewer', object: 'document:2' }, 'void')
})

afterAll(async () => {
  await service?.end()
  await owner?.end()
})

describe('sql transport on one shared connection', () => {
  it('keeps subjects apart across two transports over the same pg.Client', async () => {
    const client = new pg.Client({ connectionString: PG_URL, options: '-c role=service_role' })
    await client.connect()
    try {
      const a = sqlTransport(client)
      const b = sqlTransport(client)
      const results = await Promise.all([
        a.withSubject({ id: 'alice' }).rpc('current_subject_id', {}, 'scalar'),
        b.withSubject({ id: 'bob' }).rpc('current_subject_id', {}, 'scalar'),
        a.withSubject({ id: 'carol' }).rpc('current_subject_id', {}, 'scalar'),
      ])
      expect(results).toEqual(['alice', 'bob', 'carol'])
    } finally {
      await client.end()
    }
  })
})

describe('sql transport (service_role)', () => {
  it('reads each shape', async () => {
    const sql = sqlTransport(service)
    expect(await sql.rpc('rbac_user_permissions', { user_id: 'alice', scope: 'acme' }, 'scalar')).toEqual(['documents.edit'])
    expect(await sql.rpc('rbac_users_with_role', { role: 'editor', scope: 'acme' }, 'set')).toEqual(['alice'])
    expect(
      await sql.rpc('fga_list_users', { object: 'document:1', relation: 'viewer', user_filters: ['user'] }, 'set'),
    ).toEqual(['user:alice'])
    expect(
      await sql.rpc('fga_check', { subject: 'user:alice', relation: 'viewer', object: 'document:1', context: {} }, 'scalar'),
    ).toBe(true)
    const page = await sql.rpc<{ tuples: unknown[]; continuation_token: string }>(
      'fga_read',
      { object: 'document:1', page_size: 10 },
      'record',
    )
    expect(page.tuples).toHaveLength(1)
    expect(page.continuation_token).toBe('')
    const models = await sql.rpc<Array<{ id: string; created_at: unknown }>>('fga_read_authorization_models', {}, 'rows')
    expect(models).toHaveLength(1)
    expect(await sql.rpc('delete_subject', { subject_type: 'user', subject_id: 'nobody' }, 'scalar')).toBe('0')
  })

  it('maps rbac and openfga errors', async () => {
    const sql = sqlTransport(service)
    const rbac = await sql.rpc('rbac_assign_role', { user_id: 'anne', role: 'admn' }, 'void').catch((e: unknown) => e)
    expect(isRbacError(rbac, 'unknown_role')).toBe(true)
    expect((rbac as PermissionsError).reason).toEqual({ model: 'rbac', code: 'unknown_role', context: { role: 'admn' } })
    expect((rbac as PermissionsError).hint).toBeTruthy()
    const fga = await sql
      .rpc('fga_check', { subject: 'user:anne', relation: 'viewr', object: 'document:1' }, 'scalar')
      .catch((e: unknown) => e)
    expect(isFgaError(fga, 'validation_error')).toBe(true)
    expect((fga as PermissionsError).code).toBe('22023')
  })

  it('maps a privilege error (42501) with a null reason', async () => {
    const e = (await sqlTransport(service).rpc('fga_delete_store', {}, 'void').catch((x: unknown) => x)) as PermissionsError
    expect(e).toBeInstanceOf(PermissionsError)
    expect(e.code).toBe('42501')
    expect(e.reason).toBeNull()
  })

  it('withSubject runs current-subject functions as the subject', async () => {
    const alice = sqlTransport(service).withSubject({ id: 'alice', role: 'authenticated' })
    expect(await alice.rpc('current_subject_id', {}, 'scalar')).toBe('alice')
    expect(await alice.rpc('rbac_has_permission', { permission: 'documents.edit', scope: 'acme' }, 'scalar')).toBe(true)
    expect(await alice.rpc('rbac_scopes_with_permission', { permission: 'documents.edit' }, 'scalar')).toEqual(['acme'])
    expect(await alice.rpc('fga_list_object_ids_current', { type: 'document', relation: 'viewer' }, 'set')).toEqual([
      '1',
      '2',
    ])
    // The subject transport rejects admin calls before sending SQL.
    await expect(alice.rpc('rbac_user_permissions', { user_id: 'alice' }, 'scalar')).rejects.toThrow(/admin function/)
    // The settings end with the transaction.
    expect(await sqlTransport(service).rpc('current_subject_id', {}, 'scalar')).toBeNull()
  })

  it('withSubject works on a single pg Client', async () => {
    const client = await owner.connect()
    try {
      const bob = sqlTransport(client).withSubject({ id: 'bob' })
      expect(await bob.rpc('current_subject_id', {}, 'scalar')).toBe('bob')
      expect(await bob.rpc('rbac_has_role', { role: 'editor', scope: 'acme' }, 'scalar')).toBe(false)
    } finally {
      client.release()
    }
  })
})

describe('postgrest transport', () => {
  const asAlice = () => postgrestTransport(REST_URL, { headers: authHeaders(userToken('alice')) })

  it('calls the client functions as the JWT subject', async () => {
    const t = asAlice()
    expect(await t.rpc('current_subject_id', {}, 'scalar')).toBe('alice')
    expect(await t.rpc('current_subject_type', {}, 'scalar')).toBe('user')
    expect(await t.rpc('rbac_has_permission', { permission: 'documents.edit', scope: 'acme' }, 'scalar')).toBe(true)
    expect(await t.rpc('rbac_has_permission', { permission: 'documents.edit' }, 'scalar')).toBe(false)
    expect(await t.rpc('rbac_has_role', { role: 'editor', scope: 'acme' }, 'scalar')).toBe(true)
    expect(await t.rpc('rbac_scopes_with_permission', { permission: 'documents.edit' }, 'scalar')).toEqual(['acme'])
    expect(await t.rpc('rbac_scopes_with_permission', { permission: 'nothing' }, 'scalar')).toEqual([])
    expect(await t.rpc('fga_check_current', { relation: 'viewer', object: 'document:1' }, 'scalar')).toBe(true)
    expect(await t.rpc('fga_list_objects_current', { type: 'document', relation: 'viewer' }, 'set')).toEqual([
      'document:1',
      'document:2',
    ])
    expect(await t.rpc('fga_list_object_ids_current', { type: 'document', relation: 'viewer' }, 'set')).toEqual(['1', '2'])
  })

  it('answers for anon without a token', async () => {
    const t = postgrestTransport(REST_URL)
    expect(await t.rpc('current_subject_id', {}, 'scalar')).toBeNull()
    expect(await t.rpc('fga_list_objects_current', { type: 'document', relation: 'viewer' }, 'set')).toEqual([])
  })

  it('passes DETAIL and HINT through as details and hint', async () => {
    const e = (await asAlice()
      .rpc('fga_check_current', { relation: 'viewr', object: 'document:1' }, 'scalar')
      .catch((x: unknown) => x)) as PermissionsError
    expect(e).toBeInstanceOf(PermissionsError)
    expect(e.code).toBe('22023')
    expect(e.details).toBe('openfga:2000 validation_error')
    expect(e.hint).toMatch(/Did you mean 'viewer'/)
    expect(e.reason).toEqual({ model: 'openfga', code: 2000, name: 'validation_error' })
  })

  it('refuses admin functions even with a service_role token', async () => {
    const t = postgrestTransport(REST_URL, { headers: authHeaders(serviceToken()) })
    await expect(t.rpc('rbac_assign_role', { user_id: 'mallory', role: 'editor' }, 'void')).rejects.toThrow(/admin function/)
  })
})
