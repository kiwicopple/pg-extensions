import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type pg from 'pg'
import { createClient, createServerClient } from '../../src'
import type { AuthorizationModel, PermissionsServerClient, Result } from '../../src'
import { REST_URL, anonToken, ownerPool, resetDatabase, servicePool, userToken } from './helpers'

// The end-to-end story: a server sets up RBAC and FGA with createServerClient,
// a browser checks with createClient over PostgREST, the server checks the
// same as() the user, then deletes the user.

type Names = { permissions: 'documents.read' | 'documents.edit'; roles: 'viewer' | 'editor' }

const MODEL: AuthorizationModel = {
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
let server: PermissionsServerClient<Names>

function ok<T>(result: Result<T>): T {
  expect(result.error).toBeNull()
  return result.data as T
}

/** The browser client of `sub`, as with supabase-js: the anon key, and the user's token. */
function browser(sub: string) {
  // Plain PostgREST has no /rest/v1 prefix: restUrl replaces <url>/rest/v1.
  return createClient<Names>(REST_URL, anonToken(), {
    restUrl: REST_URL,
    accessToken: async () => userToken(sub),
  })
}

beforeAll(async () => {
  owner = ownerPool()
  service = servicePool()
  // Shared database: start from empty RBAC and FGA state.
  await resetDatabase(owner)
  server = createServerClient<Names>(service)

  ok(await server.rbac.admin.createRole({ role: 'viewer', permissions: ['documents.read'] }))
  ok(await server.rbac.admin.createRole({ role: 'editor', permissions: ['documents.edit'], inherits: ['viewer'] }))
  ok(await server.rbac.admin.assignRole({ userId: 'alice', role: 'editor', scope: 'acme' }))
  ok(await server.rbac.admin.assignRole({ userId: 'bob', role: 'viewer', scope: 'acme' }))

  ok(await server.fga.admin.writeAuthorizationModel(MODEL))
  ok(
    await server.fga.admin.write({
      writes: [
        { user: 'user:alice', relation: 'viewer', object: 'document:1' },
        { user: 'user:alice', relation: 'viewer', object: 'document:2' },
        { user: 'user:bob', relation: 'viewer', object: 'document:2' },
      ],
    }),
  )
})

afterAll(async () => {
  if (owner) await resetDatabase(owner)
  await service?.end()
  await owner?.end()
})

describe('umbrella: createServerClient + createClient', () => {
  it('the browser client checks for the user of the access token, over PostgREST', async () => {
    const alice = browser('alice')
    expect('admin' in alice.rbac).toBe(false)
    expect('admin' in alice.fga).toBe(false)
    expect(ok(await alice.rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' }))).toBe(true)
    expect(ok(await alice.rbac.hasPermission({ permission: 'documents.read', scope: 'acme' }))).toBe(true)
    expect(ok(await alice.rbac.hasPermission({ permission: 'documents.edit' }))).toBe(false)
    expect(ok(await alice.rbac.hasRole({ role: 'viewer', scope: 'acme' }))).toBe(true)
    expect(ok(await alice.rbac.scopesWithPermission({ permission: 'documents.edit' }))).toEqual(['acme'])
    expect(ok(await alice.fga.check({ relation: 'viewer', object: 'document:1' }))).toBe(true)
    expect(ok(await alice.fga.check({ relation: 'viewer', object: 'document:3' }))).toBe(false)
    expect(ok(await alice.fga.listObjects({ type: 'document', relation: 'viewer' })).sort()).toEqual([
      'document:1',
      'document:2',
    ])
    expect(ok(await alice.fga.listObjects({ type: 'document', relation: 'viewer', idsOnly: true })).sort()).toEqual([
      '1',
      '2',
    ])

    const bob = browser('bob')
    expect(ok(await bob.rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' }))).toBe(false)
    expect(ok(await bob.fga.check({ relation: 'viewer', object: 'document:1' }))).toBe(false)
  })

  it('without an access token, the anon key gives no subject', async () => {
    const anon = createClient<Names>(REST_URL, anonToken(), { restUrl: REST_URL, accessToken: async () => null })
    expect(ok(await anon.rbac.hasPermission({ permission: 'documents.read', scope: 'acme' }))).toBe(false)
    expect(ok(await anon.fga.listObjects({ type: 'document', relation: 'viewer' }))).toEqual([])
  })

  it('server.as() gives the same answers over SQL', async () => {
    for (const role of [undefined, 'authenticated']) {
      const alice = server.as({ id: 'alice', role })
      expect('admin' in alice.rbac).toBe(false)
      expect('admin' in alice.fga).toBe(false)
      expect(ok(await alice.rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' }))).toBe(true)
      expect(ok(await alice.rbac.hasPermission({ permission: 'documents.edit' }))).toBe(false)
      expect(ok(await alice.rbac.hasRole({ role: 'viewer', scope: 'acme' }))).toBe(true)
      expect(ok(await alice.rbac.scopesWithPermission({ permission: 'documents.edit' }))).toEqual(['acme'])
      expect(ok(await alice.fga.check({ relation: 'viewer', object: 'document:1' }))).toBe(true)
      expect(ok(await alice.fga.check({ relation: 'viewer', object: 'document:3' }))).toBe(false)
      expect(ok(await alice.fga.listObjects({ type: 'document', relation: 'viewer' })).sort()).toEqual([
        'document:1',
        'document:2',
      ])
    }
  })

  it('admin.deleteSubject removes the user: every check is then false', async () => {
    const deleted = ok(await server.admin.deleteSubject({ type: 'user', id: 'alice' }))
    expect(typeof deleted).toBe('number')
    // One RBAC assignment and two tuples.
    expect(deleted).toBe(3)
    expect(ok(await server.admin.deleteSubject({ type: 'user', id: 'alice' }))).toBe(0)

    const alice = browser('alice')
    expect(ok(await alice.rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' }))).toBe(false)
    expect(ok(await alice.fga.check({ relation: 'viewer', object: 'document:1' }))).toBe(false)
    expect(ok(await alice.fga.listObjects({ type: 'document', relation: 'viewer' }))).toEqual([])
    const asAlice = server.as({ id: 'alice' })
    expect(ok(await asAlice.rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' }))).toBe(false)
    expect(ok(await asAlice.fga.check({ relation: 'viewer', object: 'document:1' }))).toBe(false)
    expect(ok(await server.rbac.admin.usersWithRole({ role: 'editor', scope: 'acme' }))).toEqual([])

    // Bob is not affected.
    expect(ok(await browser('bob').fga.check({ relation: 'viewer', object: 'document:2' }))).toBe(true)
    expect(ok(await server.as({ id: 'bob' }).rbac.hasRole({ role: 'viewer', scope: 'acme' }))).toBe(true)
  })

  it('currentSubjectId and currentSubjectType: the browser client, per token', async () => {
    const alice = browser('alice')
    expect(ok(await alice.currentSubjectId())).toBe('alice')
    expect(ok(await alice.currentSubjectType())).toBe('user')
    const anon = createClient<Names>(REST_URL, anonToken(), { restUrl: REST_URL })
    expect(ok(await anon.currentSubjectId())).toBeNull()
    expect(ok(await anon.currentSubjectType())).toBe('user')
  })

  it('currentSubjectId and currentSubjectType: the server client and as()', async () => {
    expect(ok(await server.currentSubjectId())).toBeNull()
    expect(ok(await server.currentSubjectType())).toBe('user')
    for (const role of [undefined, 'authenticated']) {
      const alice = server.as({ id: 'alice', role })
      expect(ok(await alice.currentSubjectId())).toBe('alice')
      expect(ok(await alice.currentSubjectType())).toBe('user')
      const team = server.as({ id: 'alice', type: 'team', role })
      expect(ok(await team.currentSubjectId())).toBe('alice')
      expect(ok(await team.currentSubjectType())).toBe('team')
    }
  })
})
