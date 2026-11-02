// A Node server with pg_permissions over SQL.
//
//   pnpm build
//   DATABASE_URL=postgres://... node examples/node-server.ts
//
// The role of the connection must have `execute` on the admin
// functions. On Supabase, connect as `postgres` or set
// `options: '-c role=service_role'`. See the privileges sections of
// docs/rbac.md and docs/fga.md.

import pg from 'pg'
import { createServerClient } from 'permissions'

// Optional: narrow the names, so that a typo is a type error.
type Names = {
  permissions: 'documents.read' | 'documents.edit'
  roles: 'viewer' | 'editor'
}

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient<Names>(pool)

async function main(): Promise<void> {
  // Roles cannot change after creation. Create them once, for
  // example in a migration.
  const viewer = await permissions.rbac.admin.createRole({
    role: 'viewer',
    permissions: ['documents.read'],
  })
  if (viewer.error && viewer.error.reason?.code !== 'role_exists') {
    throw viewer.error
  }

  const editor = await permissions.rbac.admin.createRole({
    role: 'editor',
    permissions: ['documents.edit'],
    inherits: ['viewer'],
  })
  if (editor.error && editor.error.reason?.code !== 'role_exists') {
    throw editor.error
  }

  // Give alice the editor role in the scope 'acme' (an organization
  // id, for example).
  await permissions.rbac.admin.assignRole({
    userId: 'alice',
    role: 'editor',
    scope: 'acme',
  })

  // Admin calls take an explicit user.
  const { data: perms } = await permissions.rbac.admin.userPermissions({
    userId: 'alice',
    scope: 'acme',
  })
  // ['documents.edit', 'documents.read']
  console.log('alice in acme:', perms)

  // as() runs the current-subject checks as alice, as the browser
  // client does over PostgREST. role: 'authenticated' uses the
  // privileges of a signed-in user.
  const alice = permissions.as({ id: 'alice', role: 'authenticated' })

  const { data: canEdit, error } = await alice.rbac.hasPermission({
    permission: 'documents.edit',
    scope: 'acme',
  })
  if (error) throw error
  console.log('alice can edit in acme:', canEdit) // true

  const { data: scopes } = await alice.rbac.scopesWithPermission({
    permission: 'documents.read',
  })
  console.log('alice can read in:', scopes) // ['acme']

  // When a user account is deleted, delete its assignments and
  // tuples.
  const { data: deleted } = await permissions.admin.deleteSubject({
    type: 'user',
    id: 'alice',
  })
  console.log('rows deleted:', deleted)
}

main()
  .catch((error: unknown) => {
    console.error(error)
    process.exitCode = 1
  })
  .finally(() => pool.end())
